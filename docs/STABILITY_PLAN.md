# GMWF Dispensary — Stability, Sync & Performance Plan

_Written 5 Nov 2026 from a full code audit of: LAN realtime (desk ⇄ server), queues and local
storage, and cloud (Firestore) sync. Revised the same day for real clinic conditions (wired LAN,
patients physically waiting in line). Line numbers refer to the code as of that date._

Goal: **every patient is seen in the order they got their token, no token is ever late, lost or
duplicated, and no screen hangs** — across online/offline, branches, camps, sessions and users —
while keeping the reception → doctor → dispenser workflow exactly as staff use it today.

---

## 1. The real-life requirement

A patient who got token 1 must never be called after the patient with token 2. "It arrives a bit
later and then sorts correctly" is **not good enough**: if #1 is late by even 30 seconds, the doctor
may already have called #2. So the fix is not better sorting — it is making sure that **a token
exists on every desk before the patient even has the slip in hand**, and that a desk can never
call "next" while it is missing a token.

---

## 2. On a wired LAN, why would a token be late or lost at all?

Cables don't lose packets — but this app has software reasons that make tokens late, misnumbered
or missing. Found in the code:

| # | Real cause (wired LAN) | Evidence | Effect in the clinic |
|---|---|---|---|
| L1 | **Desk waits only 1.5 s for a token number.** If the server answers slower, the desk silently treats itself as offline. | `realtime_manager.dart:1171-1193` (`reserveSerial` timeout 1500 ms), `token_screen.dart:1384-1410` | Patient gets an offline-block number (1001+) or a locally-guessed number while the server is merely busy. **Most likely cause of "1 after 2" today.** |
| L2 | **The server PC is too busy to answer quickly.** All message handling runs on the same thread as the 8,000-line dashboard: every packet triggers a full screen rebuild, a 5-second catch-up scans the database per desk, PowerShell runs every 3 min, and every missed lookup scans the whole box. | `server.dart:1157-1164, 4987, 6032-6195`, `system_metrics_service.dart:96`, `local_storage_service.dart:7373-7382` | On an i3/4 GB PC, a token message can wait seconds in line → L1 timeout, late arrival on doctor/dispenser screens. |
| L3 | **The slip is printed before the server has the token.** The desk saves locally, puts the message in its outbox and prints; delivery happens afterwards. | `token_screen.dart:1430-1484` | Patient is already in the waiting area while the doctor's screen doesn't have them yet. |
| L4 | **Dead connections are noticed late.** A desk that slept, a cable re-plugged, a switch rebooted or Windows NIC power-saving leaves a "half-open" socket; the server thinks it delivered. Recovery waits for the next catch-up. | `lan_server.dart:925-930, 854-860`; 30 s pong timeout | A desk silently misses tokens for up to ~30 s or more. |
| L5 | **Resends get stuck.** The server ignores a resend while the first copy is still being processed; after 20 un-ACKed sends the message is parked and retried only every 5 minutes. | `lan_server.dart:690`, `realtime_manager.dart:128, 1491-1494, 1597-1601` | A token stuck for ~5 minutes. |
| L6 | **Server restart / crash / "Not Responding" killed by staff.** The replay of recent messages is only in memory (10 min). | `lan_server.dart:73, 844-879` | Desks that were reconnecting miss events until the 30-min full resync. |
| L7 | **Several paths deliver the same token** (live forward, 5 s catch-up, 30-min resync, cloud pull), unordered, and late copies can overwrite newer state. | `server.dart:6046-6058`, `local_storage_service.dart:6674-6684` | Out-of-order arrival; a late "waiting" copy can undo "in consultation"/"dispensed". |

**Conclusion:** on a wired LAN, delivery should take **< 50 ms**. Every "late token" is caused by
L1–L7, all of which are fixable in software (plus a few site settings in section 6).

---

## 3. Root causes (whole system)

| # | Root cause | Causes |
|---|---|---|
| R1 | Token creation is "local first, tell the server later" | L1, L3, out-of-order tokens, offline numbers while online |
| R2 | No single ordered event history per branch | L6, L7, late/missing data on desks, catch-up storms |
| R3 | Updates not idempotent (stock "+N/−N" without operation id; cloud `increment`/`.add()` retried) | Double or lost stock, duplicate logs |
| R4 | No "newer wins" rule for token state | Late copies roll status back, erase dispenses |
| R5 | Many writers per record (screens, router, server, every desk to cloud), several key spellings | Duplicate tokens, drift, races, wasted quota |
| R6 | Heavy work on the UI thread | L2, "Not Responding", missed heartbeats → reconnect → catch-up |

---

## 4. Target design for the clinic

1. **The server PC issues and owns every token (online).** Reception sends one `create_token`
   request. The server, in one step: assigns the number, saves the token, appends it to the branch
   event log, broadcasts it to all desks, and replies to reception with the saved token.
   **Reception prints the slip only after that reply** (normally 10–50 ms on wired LAN). The
   request is idempotent (same `requestId` → same token), so a retry never makes two tokens.
2. **Token number = order of arrival.** Because only the server numbers online tokens, number
   order *is* the order patients came. Queues sort by that (and by server-time for the rare
   offline token — see 4.7).
3. **Every desk applies events in server order** (`seq` 1, 2, 3 …). If a desk receives seq 105
   but its last was 103, it immediately fetches 104 (single event, not a full catch-up).
4. **A desk never calls "next" while behind.** The server's latest `seq` rides on every heartbeat
   (every 2 s). The doctor's "Next patient" and the dispenser's auto-select first check
   `mySeq == serverSeq`; if not, they fetch the missing events (milliseconds) before choosing.
   This makes "#2 called before #1" impossible while connected.
5. **Fast failure detection, honest offline mode.** Heartbeat every 2 s, dead connection detected
   in ~6 s, automatic reconnect + catch-up from last `seq`. A slow server does **not** mean offline:
   reception shows "Waiting for server…" for up to ~5 s and retries. Offline mode is entered only
   when the connection is actually down, and the screen shows a clear **OFFLINE** banner.
6. **Every event has an `eventId` + `updatedAt`; applying twice does nothing; state only moves
   forward** (`waiting < called < in_consultation < prescribed < dispensed`; `cancelled` never
   overrides `dispensed`).
7. **Offline tokens (rare, real outages only):** numbered from the PC's own block (1001+, 2001+ …)
   and stamped with server-corrected issue time. When they reach the server they are placed in the
   queue **by issue time** among the others, so an offline patient keeps their real place in line.
   The slip shows a desk letter (e.g. `A-003`) so it looks normal to the patient.
8. **One writer per layer:** on each PC only the router writes incoming events; screens only read.
   One canonical key per token. Only the server PC uploads branch data to the cloud.
9. **The server's message handling never waits for the screen:** the token path runs before any
   UI work; dashboard refreshes are batched (max ~1/s); heavy scans run in a background isolate.
   Target: token round-trip < 100 ms on the i3/4 GB server with 6 desks busy.
10. **Visible health on every desk:** a small indicator — green "Live", amber "Catching up (3)",
    red "Offline – 2 unsent". Staff know immediately if a desk is behind.

---

## 5. The plan — phased, each phase shippable on its own

Effort = rough working days for one developer, including testing.

### Phase 0 — Done today (verify on a test setup before clinic use)
- Dispense was blocked for every normal patient (`status == completed` treated as dispensed) → fixed.
- Prescription changed mid-dispense: detected via any path; dispense refused if the list changed during the confirm dialogs; deduction uses exactly the confirmed list.
- Sibling/guardian restriction false positives fixed; expiry clears the right record; doctor desk sends name/guardian/phone.
- Token numbering: shared server sequence online + server-assigned offline block per PC (replaced the broken 1–499 / 501–999 ranges).
- Gap-detection regression (1000-serial scan + endless catch-up loop) → fixed.

### Phase 1 — Token flow through the server: no late, no out-of-order tokens (≈ 5–6 days) — **first**

> **Status (5 Nov 2026): implemented, analyzer clean, NOT yet tested on real PCs.** What was built:
> - Number request re-sent with the same `requestId` for up to 6 s while the link is up (server
>   answers repeats with the same number); offline numbering only when the link is actually down.
> - Reception shows the token number only after the server's ACK (server ACKs after saving and
>   forwarding to desks); otherwise a clear "not confirmed yet" / "OFFLINE" message.
>   _Implemented as reserve + confirmed `save_entry` (existing outbox/ACK path) rather than a new
>   single `create_token` message — same guarantee, less new protocol._
> - Fair order in doctor, dispenser and reception queues (`lib/utils/token_order.dart`); new
>   tokens carry `issuedAtMs` (server-corrected) and `issuedOffline`.
> - Server tracks each desk's unconfirmed tokens and returns the count in every pong; the doctor's
>   auto-select waits (max 4 s, while requesting a catch-up) when its desk is behind.
> - App-bar pill on every screen: Live / Sending (n) / Catching up (n) / Offline – n unsent / Update required.
> - Server: dashboard repaint batched to ≤ 1/s; PowerShell machine metrics every 30 min (app memory every
>   1 min, no process); fallback UDP beacon 30 s.
> - Dead links: desk ping 5 s / dead after 20 s (was 10 s / 30 s); server evicts silent sockets after
>   35 s (was 60 s). _Not yet the 6 s target: needs Phase 2 (server work off the UI thread) first,
>   otherwise a busy server makes every desk drop at once._
> - Protocol version 3; server refuses older desks with "Update required".
> - Not changed yet: the 5 s server catch-up (still the safety net until Phase 2's event log),
>   dispenser auto-select does not wait when behind (doctor order drives it), "received" vs "saved"
>   two-stage ACK and failed-box backoff (moved to Phase 2).
| Item | Fix |
|---|---|
| `create_token` request (replaces reserve-then-send) | Server assigns number + saves + logs + broadcasts + replies in one handler, under the branch lock. Idempotent by `requestId`. Reception prints after the reply. |
| 1.5 s timeout → silent offline numbering (L1) | Reception waits up to ~5 s with "Waiting for server…", retries same `requestId`. Offline numbering only when the socket is actually closed / heartbeat lost. |
| Server too slow to answer (L2) | Token/prescription/dispense messages handled first, before any dashboard work; `_addLog` `setState` batched (≤ 1/s); remove PowerShell metrics; remove duplicate UDP broadcaster (`server.dart:724`); in-memory serial index so lookups never scan the box. |
| Dead connections noticed late (L4) | Heartbeat 2 s both ways, dead after 3 missed (~6 s); TCP keep-alive; reconnect then catch up from last `seq`. |
| Resends stuck for 5 min (L5) | Server sends an immediate "received" ACK and a "saved" ACK; desk backs off (1, 2, 4 s …) instead of parking critical messages; no 5-minute failed box for tokens/prescriptions/dispenses. |
| Desk calling "next" while behind | Heartbeat carries server `seq`; "Next patient"/auto-select first ensures the desk is up to date. |
| Health indicator | Live / Catching up / Offline + unsent count on reception, doctor, dispenser screens and per-desk on the server dashboard. |
| Fair queue order | All queues: online tokens by number (= server order); offline tokens merged by server-corrected issue time. Doctor `patient_queue.dart:342-353`, dispenser `dispense_queue.dart:372-381`, reception `receptionist_screen.dart:1458-1464`, auto-next `patient_queue.dart:976`, `dispense_queue.dart:391-393`. |
| Version gate | Bump `protocolVersion` so old desk builds are refused with "Update this PC" (`lan_server.dart:498-504`). |

### Phase 2a + 3 (part) — done 5 Nov 2026 (analyzer clean, unit/socket tests pass, NOT yet on real PCs)
Removes the causes of data arriving "after 30 minutes" and the worst corruption paths, without the
full event-log rewrite:
- **Desk router:** a failed apply now also undoes the version it recorded (resends were dropped as
  "stale" and ACKed → data only at the 30-min resync); a resend arriving while the first copy is
  still being applied is not ACKed (`realtime_router.dart` `routeMessage`).
- **Desk outbox:** tokens, prescriptions, dispenses, patients and deletes are never parked in the
  failed box (it was retried every 5 min); deletes no longer dropped after 12 h / day change.
- **Server CPU:** today's token list for the 5 s catch-up is built once and shared by all desks,
  rebuilt only when the entries box changes (was rebuilt per desk, per tick, for up to 6 Karachi ids);
  dispense handler no longer scans the whole entries box per dispense.
- **Server consistency:** all events for one token (entry/prescription/dispense/status) run one
  after another (`_withTokenLock`); dispense save errors are no longer swallowed (no false ACK).
- **Status only moves forward** in `saveEntryLocal` unless the change is newer (`updatedAt`);
  a late cancellation never cancels a dispensed patient.
- **Prescriptions box:** an older or empty copy never replaces a newer prescription.
- **Stock:** each "+N" applied once per operation id (persistent `applied_stock_ops`, desks and
  server); catch-up/replay copies are snapshots, never "+N again"; `_quantityDelta` never stored;
  two restocks of one medicine are both sent (outbox) and both queued for the cloud.
- Tests: `test/token_order_test.dart`, `test/token_numbering_and_restrictions_test.dart`,
  `test/lan_token_protocol_test.dart`, `test/late_message_protection_test.dart`.

Also done (same day, round 3):
- **Cloud queue:** an item is deleted after upload only if no newer edit was merged into it
  meanwhile (`enqueuedAt` revision); a failed upload never writes an older copy over a newer one.
- **Cloud uploads:** failures writing a token's dispense/prescription copies (and dispense-record
  writes) are no longer swallowed — the item retries instead of being deleted as uploaded.
- **Upload passes:** hung-pass watchdog 150 s (> 120 s item limit) and pass generation, so two
  passes never upload the same items at once.
- **Syringe/needle auto-count:** "iv" only as a word (Multivitamin, Ivermectin, Rivotril, Ativan no
  longer count as injections); syrups (incl. names like "Syr. Brufen") never picked as syringes;
  fallback never picks an out-of-stock syringe (`PatientFormHelper`).
- **Dispense queue** no longer writes names / "Token #…" placeholders into the shared token cache.
- **Midnight:** one rule for doctor queue, dispense queue and server catch-up — until 06:00 a token
  from yesterday stays only if issued within the last 8 h (late session), so abandoned morning
  tokens / replays don't resurface (`CampSessionService.isLateNightCarryOver`).
- Tests: `test/syringe_and_midnight_test.dart`.

Round 4 (same day) — queue flood and cloud backlog (screenshot: 5,959 queued, 3 days old,
"Paused (step 3)", 1,865 LAN msg/min):
- **One cloud item per token on the server** (`_enqueueTokenState`): save_entry (two keys),
  save_prescription, update_serial_status, `sync_presc_`, `sync_dispense_` all merge into
  `sync_serial_<branch>_<serial>` holding the token's latest full state. ~9 → ~3 cloud writes
  per patient. Camps folded to one branch id so a token never gets two items.
- **Upload when settled:** a token item uploads once dispensed, or unchanged 10 min (max 45 min
  after queueing); manual force sync uploads everything.
- **Backlog compaction at server start** (`_compactTokenQueue`): merges the existing per-type
  items per token (oldest first + the server's stored copy), then backfill.
- **Server upload pass:** an item changed during upload is not deleted; a failed/timed-out batch
  marks its items as tried; marking tokens synced no longer scans the whole entries box.
- **Cloud stock increments once per txId** (desk SyncService and server): increment + marker doc
  `inventory_applied_tx/{txId}` in one atomic commit; marker checked only on retries.
- **Rate limits:** a short 429 / contention waits 20 s and retries; only a real "quota" message
  pauses until the daily reset (it used to pause for every 429).
- **LAN flood:** catch-up resends of a token a desk doesn't confirm back off 6 s → 12 → … → 5 min
  (were every 6 s forever, ×3 frames); a once-a-minute traffic breakdown (type / desk /
  catch-up vs live) is written to the server log.
- Reception screen + doctor auto-next use the same midnight rule; collision copies are no longer
  merged away (or merged onto the other patient), and a patientId mismatch alone (child vs
  guardian id, "unknown_" placeholder) is no longer treated as a collision.
- Not applicable after checking: "Karachi token pull reads the wrong doc" and the server-queue
  findings citing `lib/realtime/server_sync_manager.dart` — that file is dead code; the live
  server already reads all camp documents.

Important for the free Firestore plan: the 20k writes/day limit is shared by ALL branches. Even
at ~3 writes per patient, several busy branches can exceed it; the Blaze (pay-as-you-go) plan
costs about $0.18 per 100k writes.

Still open (next): persistent sequenced event log (below); single cloud writer per branch
(desks still upload some data themselves); branch-id canonicalisation for local storage;
discovery (Phase 7).
Build machine: CMake picks GitHub Desktop's `git.cmd`, which breaks the sentry-native download —
install Git for Windows (or put a real `git.exe` first in PATH).

### Phase 2 — Sequenced event log: guaranteed delivery of everything (≈ 5–7 days)
Extends Phase 1's log from tokens to **all** events and replaces the 10-min memory replay,
serial-level ACKs, 5 s per-desk catch-up scans and most of the 30-min resync (also the biggest
CPU cost on the server).
- Server: persistent Hive `branch_event_log` (`seq → eventId, type, serial, data, updatedAt, origin`), appended inside the per-serial lock; ACK to the sender only after it is saved (fixes `server.dart:5351-5412` swallowing save failures and `lan_server.dart:799-803` ACKing parked messages).
- Desk: `last_applied_seq`; on connect `catch_up_from(seq)` streamed in order in pages of ~200; ACK by seq.
- Covers prescriptions, dispenses, status changes, patient edits, deletes, restrictions, stock, attendance.
- Outbox never discards unsent items at day change / after 12 h (`realtime_manager.dart:1454-1463, 1539-1561`).
- Handler timeout (15 s) so one stuck handler can't block the rest (`lan_server.dart:788`).
- Token-number gap detection removed (the `seq` gap check replaces it).
- Log kept 7 days; a desk older than that gets a full snapshot.

### Phase 3 — Stop data corruption (≈ 4–5 days)
| Item | Where | Fix |
|---|---|---|
| Stock deltas applied twice / lost on LAN | `realtime_router.dart:1106-1127`, `server.dart:5620-5626, 6224-6238`, outbox dedupe `realtime_manager.dart:830-838` | `opId` per stock change; persistent `applied_ops`; strip `_quantityDelta` before storing; never apply deltas from catch-up/replay; deltas exempt from "keep last per id" dedupe. |
| Stock increments / logs duplicated in the cloud | `sync_service.dart:3096, 3123, 3166-3201` | Transaction guarded by `applied_tx/{opId}`; `.doc(opId).set()` instead of `.add()`. |
| Late message overwrites dispense on the server | `server.dart:5119-5134` (lock only for `save_entry`) | One per-serial lock for all token events; re-read inside the lock. |
| Status rollback | `local_storage_service.dart:6674-6684`, `realtime_router.dart:629` | Status precedence + `updatedAt`; missing status = "no change". |
| Older prescription overwrites newer | `saveLocalPrescription` `:8286-8297`; `server.dart:5308-5329` | `mayReplacePrescription` before every write and enqueue. |
| Cloud queue item deleted with newer edits merged in | `sync_service.dart:2493, 5051, 5089, 5124` | Delete/put only if the item's revision is unchanged. |
| Failed cloud sub-writes swallowed | `sync_service.dart:2860-2889, 3050-3055` | Rethrow (deterministic-id merges are safe to retry). |
| Two upload passes at once | `sync_service.dart:1887, 2172, 5063` | Single-flight upload; watchdog longer than item timeout. |
| Server cloud queue loses ops | server sync queue dedupe key, 24 h expiry, `.update()` on new medicine | Key by `opId`; never expire unsent data; `set(merge)`. |
| Dispensary items deleted assuming LAN has them | `sync_service.dart:2313-2315, 2117`; `queue_self_healing_service.dart:330` | Delete only after the server ACKed; otherwise forward. |

### Phase 4 — Queue & dispensing correctness (≈ 4–5 days)
| Item | Fix |
|---|---|
| Midnight: tokens vanish from doctor/reception queues | One shared "active shift date keys" rule in all queues + server; "before 06:00 include yesterday" only for branches with a night/evening shift. |
| Duplicate records under different branch spellings | Canonical branch id (`karachi` + campId); one key format; migration merging existing duplicates; strict branch matching (no `contains()`), no "missing ⇒ Karachi" default. |
| Screens writing to Hive | Doctor/dispenser screens stop writing incoming events (`patient_queue.dart:442, 484-499`, `patient_list.dart:151-237`, `dispensar_screen.dart:599`). |
| Collision guard hides patients | Require `entryUid` before declaring a collision; show collisions with a warning badge. |
| Shared index mutated / stale caches | `getLocalEntries` returns copies; fix `dispense_queue.dart:144-174`; replace time-based caches with a box version counter. |
| dateKey / camp / session errors | Shift date as default; keep stored dateKey; `-KAP-` (Saddar vs Karianwala); sessions from configured windows; receptionist `'-M-'` checks. |
| Syringe auto-deduction | Stop `syr.`/`iv` substring matching (syrups, Multivitamin, Ivermectin matched); use inventory type; same transaction as medicines. |
| Double dispense across counters | Server-arbitrated `begin_dispense(serial)` (like `create_token`): only one counter gets it; offline → local check + warning. |

### Phase 5 — Cloud sync: one writer, no overwrites, low quota (≈ 4–5 days)
- Only the server PC uploads branch data; desks upload only when no LAN server exists.
- Restriction dates from the issuer's timestamp, not each receiver's clock.
- Pulls: delta on `updatedAt`, never overwrite `pendingSync` records, last-write-wins by server time; fix `_downloadInventory` `max(local, cloud)`; fix Karachi token pull (`serials/{today}` vs `_haji`/`_saddar`); stop 30-min full pulls of patients/prescriptions.
- HTTP 429 → short backoff, not "pause until tomorrow" (`cloud_db.dart:231-232`).
- Unknown branch/camp → park + alert, never default to Karachi / `camps.first`.
- Delete the dead temp-serial path (`serials_service.issueAtomicSerialTransaction`).

### Phase 6 — Remaining performance on the i3 / 4 GB server (≈ 2–3 days)
(Phase 1 already takes the token path off the slow parts.)
- Index rebuild, compaction, sync-queue scans in a background isolate; compaction at a quiet hour.
- Dispenser memo that never hits (`patient_list.dart:472`), debounce that never fires during floods (`:295-305`).
- `patient_history.dart`: pre-filter that can miss visits; `lookupSerialInBox` misses above 500 records.

### Phase 7 — Discovery & identity (≈ 2 days)
- UDP beacon carries branch id + server id; desks join only their branch's server; a second server on the same branch shows a blocking warning.
- Detect cloned PCs (same client id); merge the two reconnect loops (`realtime_manager.dart:1105-1118`, `connection_manager.dart:173-186`).
- Offline block assigned at connection handshake (not first token); manual override in Settings.

### Phase 8 — Test harness & rollout (≈ 3 days to set up, then ongoing)
Automated scenarios (extend `gmwf_pressure_test`); all must pass before release:
1. **Fairness:** 3 reception desks issue 300 tokens/hour; doctor auto-next must always pick the lowest waiting token; zero inversions.
2. **Slow server:** server CPU artificially pegged → tokens still numbered by the server (no offline numbers), slip waits, no inversions.
3. Cable pulled on a doctor desk for 20 s mid-session → desk shows Offline, reconnects, catches up before allowing "Next".
4. Server killed mid-burst and restarted → no lost or duplicated tokens/dispenses/stock.
5. Messages duplicated / reordered / replayed 3× → identical final state.
6. Doctor edits prescription while dispenser confirms → dispense refused, then succeeds after review.
7. Two counters dispense the same token within 200 ms → exactly one succeeds.
8. Real outage: server off 30 min, two reception desks issue offline tokens → unique numbers, merged by issue time.
9. Midnight crossing; Karachi Saddar + Haji Camp; Karianwala `KAP`.
10. Internet down 2 days → every cloud item uploaded once.
11. Load on i3/4 GB, 6 desks: token round-trip < 100 ms p95, server CPU < 30 %, RAM < 400 MB, no UI stall > 100 ms.

Rollout: test PC set → one small branch for a week → all branches. All PCs on the same build (enforced by protocol version).

---

## 6. Site setup checklist (removes the physical causes)

- Server PC: **static IP**, wired, on a **UPS together with the network switch**.
- All clinic PCs: Windows sleep/hibernate **off**, NIC "Allow the computer to turn off this device to save power" **off**, Windows Update active hours set to clinic hours.
- Only **one GMWF server PC per branch network**.
- Desks wired (not Wi-Fi) where possible; one decent unmanaged gigabit switch, no daisy-chained hubs.
- Server PC runs nothing else heavy during clinic hours (no browser with many tabs, no antivirus full scan scheduled in clinic hours).

---

## 7. The six open points from the token-numbering fix

| Point | Risk | Resolution in this plan |
|---|---|---|
| New PC that never reached the server has no offline block | Small | Block assigned at connection handshake (Phase 7); no-block offline tokens marked "unconfirmed". |
| Offline tokens show 4 digits / sort last | Real (fairness) | Merged by issue time (Phase 1); slip shows desk letter style `A-003`. |
| Max 9 desk PCs | Low | Reuse a slot only after 7+ days unseen, else warn; widen to 5 digits if ever needed. |
| Today's 501, 502 … tokens | None after today | Counters are per date/session; clears itself. |
| Firestore temp-serial path | Dormant, dangerous if revived | Deleted (Phase 5). |
| Every PC needs the new build | Real | Protocol version bump refuses old desks (Phase 1). |

---

## 8. Order and timeline

1. **Week 1:** Phase 1 (tokens through the server, fairness, health indicator, version gate) — this alone removes "1 after 2" on the wired LAN.
2. **Week 2:** Phase 2 (event log for everything) + start Phase 3.
3. **Week 3:** Phase 3 (corruption) + Phase 4 (queues, dispensing).
4. **Week 4:** Phase 5 (cloud) + Phase 6/7 + Phase 8 scenario suite; pilot branch.
5. **Week 5:** roll out to all branches.

Until Phase 1 ships: apply the site checklist (section 6), keep the server PC on and connected,
don't run two server PCs on one network.
