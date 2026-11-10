# GMWF App Review — 10 Nov 2026

One review covering everything checked so far:

1. Dosage / timing (already fixed, in code)
2. Hanging, lag and crashes
3. Donations and food tokens not uploading
4. Inventory flow
5. Zakat (still open)

The guiding rule: **the current version works; only fix what is broken, with small changes that don't alter how anything looks or how staff work.**

Status key: ✅ fixed in code · 🔴 confirmed problem, not fixed · 🟠 likely problem, needs a test to confirm · ⚪ fine as is

---

## 1. Dosage / timing — ✅ fixed (not yet tried in the running app, not committed)

**Staff report:** doctor prescribes 1+0+0, dispensary shows 1+0+1. **Verified: real.**

| # | Problem | Cause | Status |
|---|---|---|---|
| 1.1 | Doctor types 100, saved as 1+0+1 | Timing box is pre-filled with 1+0+1 and only keeps 3 digits, so anything typed after the default was thrown away (`formatters.dart:199`, default at `doctor_right_panel.dart:2381`, `patient_queue.dart:1176`). Introduced in v1.6.2 (14 Oct 2026). | ✅ Typing into a full box now starts a new timing: 100 → 1+0+0, 001 → 0+0+1, 1 → 1+0+0. Leaving the default untouched still gives 1+0+1. |
| 1.2 | Doctor and patient see different times of day | Doctor box is Morning/Evening/Night; patient Urdu line was صبح/دوپہر/شام (morning/noon/evening). Night medicines were labelled evening. | ✅ Urdu now صبح / شام / رات, from one shared helper `urduSlotLabels` in `patient_form_helper.dart`. Old prescriptions also display correctly (worked out on display). |
| 1.3 | 4-times-a-day showed only 3 times in Urdu | Shared Urdu line dropped the 4th slot. | ✅ 1+1+1+1 reads صبح، دوپہر، شام، رات. |
| 1.4 | Repeating an old visit set timing to twice a day | Old records with name only defaulted to BD (`doctor_screen.dart:927`). | ✅ Now defaults to 1+0+0; doctor can change it. |

**Notes**
- Prescriptions already saved as 1+0+1 by mistake stay that way until edited.
- Typing 5+ doses is still saved as 4 a day (left as is).
- Tests: `test/dose_timing_formatter_test.dart`, `test/urdu_dose_slots_test.dart` pass. One unrelated test (`lanPushSig` in `prescription_integrity_test.dart`) fails with or without these changes.
- **Clinic check:** prescribe 100 by typing at the end of the box → should show 1+0+0. Prescribe 0+0+1 → dispensary shows رات.

---

## 2. Hanging, lag and crashes — 🔴 not fixed

**Evidence from the clinic's own logs (`gmwf_perf.log`, `logs.rar`, 30 Oct):**
- Startup freezes of ~60 s and ~64 s.
- Freezes of 9–28 s during normal work, single screen redraws of 4–7 s.
- Receptionist list rebuilt 377 times over 3,709 tokens; next-serial estimate up to ~1 s.
- Crash log: 263× harmless WebSocket close error, 129× Hive box type error, 58× "Hive not initialised".

| # | Cause | Smallest safe fix | Risk |
|---|---|---|---|
| 2.1 🔴 | **Memory leak.** Listeners are added to Hive and never removed, because `box.listenable()` returns a new object every call. Doctor panel leaks once per patient opened. Also inventory, proforma, finance screens. (`doctor_right_panel.dart:180/184` vs `:845`, `inventory.dart:330/335` vs `:503`, `universal_proforma_sheet.dart:123/128` vs `:152`, `finance_page.dart:97/103` vs `:113`) | Store the listenable in a field and remove from that same object. | Very low |
| 2.2 🔴 | **Hidden tabs rebuild on every token save.** Hybrid desk keeps receptionist, doctor and dispenser tabs alive; all rebuild on each write → the 4–7 s freezes. (`hybrid_dispensary_screen.dart:875`) | Use the existing but unused `VisibleListenableBuilder` from `tab_visibility.dart`. Hidden tabs refresh when shown. | Low |
| 2.3 🔴 | **Next-serial estimate rescans all history** on every LAN event (`token_screen.dart:706` → `local_storage_service.dart:12573`). | Remember the result until tokens change; block overlapping calls. | Low |
| 2.4 🔴 | **Receptionist list filtered twice per LAN event**; cache key uses box length, which doesn't change on edits (`receptionist_screen.dart:299-305`, `:983`). | Key the cache on a change counter; skip the extra full-screen redraw. | Low–medium |
| 2.5 🔴 | **Sync queue cleanup runs every 30–45 s** over 567 items that can never be sent (`sync_service.dart:2292`, `local_storage_service.dart:2746`). | Skip when the queue hasn't changed in the last ~5 min. | Low |
| 2.6 🔴 | **Crash log/Sentry flooded** by a harmless WebSocket close error (`main.dart:142`); Sentry user context set on every rebuild (`home_router.dart:1711-1720`). | Add the error to the ignore list; set Sentry context once per login. | Very low |
| 2.7 🟠 | **~60 s startup freeze**, right after attendance boxes open. Likely ZKTeco punch backlog processed on the UI thread. | First add timing marks to confirm, then process punches in chunks / after the first screen. | Low |
| 2.8 🟠 | **`realtime_entity_versions` opened with two different types** at the same time (`realtime_router.dart:56` vs `local_storage_service.dart:810`) → 129 errors. | Open it untyped in both places. Re-enables a skipped check, so small behaviour change. | Low–medium |
| 2.9 🟠 | **Medicine restrictions re-downloaded on every LAN event** while the server link is down (`local_storage_service.dart:12117`). | Add the same cooldown `downloadTodayTokens` already has. | Low–medium |
| 2.10 | Two upload passes can start together (`server_sync_manager.dart:1469-1480`); home quick-actions scan the whole token box on every build (`home_snapshot_widgets.dart:2650`). | Set the flag before the first await; cache the count. | Low |

⚪ **Fine:** upload passes don't overlap in `sync_service`, entry index updates incrementally, most timers are cancelled properly, single-instance lock exists on Windows.

---

## 3. Donations and food tokens uploading — 🔴 not fixed

**Verdict:** most records do upload (saved locally, sent directly, retried from a queue every 15 s). They are lost or stuck in these specific cases, and the failure is invisible because errors only go to the debug console.

| # | Problem | Real-life scenario | Smallest safe fix |
|---|---|---|---|
| 3.1 🔴 | **Food tokens marked "synced" when the upload failed** (`sync_service.dart:4347-4367`; same for reversals at `:4423-4427`). | Busy day offline, >500 tokens → Firestore rejects the batch every time; day total looks right, individual tokens never arrive and are never retried. | Let the error reach the normal retry; split into batches of ≤450. Retry won't double-count (already guarded). |
| 3.2 🔴 | **No uploads at all while a dispensary role is logged in** on a LAN desk (`sync_service.dart:1954`). The LAN server doesn't upload other PCs' donations/tokens. | Donation taken on a PC where a receptionist is logged in waits until someone with another role logs in. | Continue the pass instead of returning; dispensary items are already filtered out later (`:2348`). |
| 3.3 🟠 | **Donation dropped on a poor connection.** Queue check reads Firestore's offline copy, thinks the donation is already in the cloud, marks it synced (`sync_service.dart:3373-3383`; same for edits `:3478`, tokens `:4282`). | Donation saved during a network drop never reaches the cloud, and is never retried. | Check against the server, not the offline cache. |
| 3.4 🔴 | **Office Boy: tokens not queued** when the day total saves but the tokens time out (`office_boy.dart:631-672`). Later recovery adds the count again. | Token count higher than tokens actually issued. | Queue the tokens with the same batch id on failure. |
| 3.5 🟠 | **Two PCs can give food tokens the same ID** (`office_boy.dart:560`, `kitchen.dart:687`). | Two counters issuing at once or while disconnected → one token overwrites the other. | Add a device suffix to the id (changes id format; test serve/reverse). |
| 3.6 🔴 | **Failures not logged to file** — only `debugPrint`, invisible in release builds. | Nobody can tell what failed. | Write to `gmwf_sync.log` on each failure. |
| 3.7 | Editing a donation: a cloud error (not a timeout) skips the local save too (`edit_donation_dialog.dart:217-224`). Food log dialog can hang offline (`food_log_screen.dart:553`, but the log is already queued). | | Minor. |

⚪ **Fine:** every create/edit/delete is queued, donation ids are unique, transient errors don't count against retries, bank slips carry no image (no 1 MB problem).

**How to check on a live PC**
- Hive `sync_queue`: keys `sync_save_donation_…` / `sync_save_dasterkhwan_tokens_…` stuck with `attempts` / `lastError` → 3.2 or quota.
- Hive `dead_letter_queue`: `deadLetterReason`.
- Firestore: compare `branches/{b}/dasterkhwaan/{date}.totalTokens` with the number of docs in its `tokens` subcollection. Fewer docs → 3.1/3.4/3.5; higher count than issued → 3.4.
- `gmwf_sync.log`: lines "still queued", "⛔ quota", "Cloud not reachable".

---

## 4. Inventory flow — 🔴 not fixed

**Overall:** the core design is sound. Cloud stock changes are atomic increments with a once-only marker per change, so plain retries don't double count. Problems are at the edges.

### High

| # | Problem | Real-life scenario | Smallest safe fix |
|---|---|---|---|
| 4.1 🔴 | **Refresh subtracts pending dispenses twice** (`local_storage_service.dart:11069-11076` and again in `saveAllLocalStockItems` `:9661-9671`). | On server/standalone PC, after a refresh stock looks lower than real → false "Insufficient Stock", wrong restock alerts, until the hourly upload. | Delete the block at `:11069-11076`. |
| 4.2 🔴 | **Same medicine deducted twice in one dispense, cloud gets only one** (`patient_form.dart:952-1014`, queue key `sync_inv_{branch}_{serial}_{medId}`). | Batch has 3, prescription needs 10 → two lines for the same medicine; cloud receives -7 or -3, local -10. Cloud stock drifts upward. | Sum deductions per medicine before queuing. |
| 4.3 🔴 | **Dasterkhwaan stock adjust overwrites with a stale number** (`stock.dart:477-489`). | Kitchen cooks (deducts) while stock screen is open → adjust erases the kitchen deduction. | Use `FieldValue.increment(delta)`. |
| 4.4 🔴 | **Kitchen unit mix-up** (`cook_dialog.dart:1641`, deduction `:1313`). | "500 gram" against rice stored in kg deducts 500 kg. | Lock the unit to the stock item's unit, or convert. |
| 4.5 🔴 | **Supervisor stock approval** reads then writes a fixed number, and for Karachi writes to the wrong collection (`request.dart:3077-3162`). | Dispenses during approval are lost; Karachi camp stock drifts. | Use increment + `getCampInventoryPath`; send the delta in the broadcast. |
| 4.6 🟠 | **Desk loses LAN but has internet → cloud deducted twice** (`local_storage_service.dart:3396`, `realtime_manager.dart:1859`, `server.dart:7386`). | Desk uploads directly; when LAN returns, server uploads the same dispense again with a different id. | Give each line one id on the desk and reuse it on the server. Test a LAN drop first. |

### Medium

- **4.7** Editing a medicine's name/dose/expiry creates a new id; queued dispenses for the old id recreate a nameless record with negative stock (`request.dart:3240-3257`).
- **4.8** Loose name matching: "Amoxicillin" matches "Amoxicillin + Clavulanic"; a stock record with an empty name matches everything (`patient_form.dart:828-840`).
- **4.9** Stock check before dispensing and the deduction use different filters (branch, missing id).
- **4.10** "Dispense Available" still deducts the full amount in the cloud → cloud negative, local 0.
- **4.11** Expired batches are dispensed first (FEFO doesn't skip expired) (`patient_form.dart:902-906`).
- **4.12** Medicine ledger "removed" is recalculated with a simpler formula, not recorded (`medicine_ledger.dart:491-499`).
- **4.13** Quantity stored as text crashes the stock download/restock (`local_storage_service.dart:9713`, `:9730`, `:9862`).
- **4.14** Doctor PCs may apply restock changes twice (`doctor_right_panel.dart:251-262`) — needs confirmation.
- **4.15** Cooking when the cloud read times out can overwrite stock with a negative number (`cook_dialog.dart:1308-1323`).

### Low

Reversing a token doesn't return stock (if allowed after dispense) · entry marked dispensed before stock is deducted (crash in between = no deduction) · clearing one branch's local stock clears Karachi too (local only) · substring branch matching · Dasterkhwaan item ids are the item name ("/" breaks save, "Rice" ≠ "rice") · Dasterkhwaan screens have no offline queue.

⚪ **Fine:** atomic once-only cloud increments; restock goes through the queue only; replayed dispense messages are handled once; two counters dispensing at once are locked; Insufficient Stock dialog exists; outbox never merges stock deltas; editing/deleting a cooking session restores ingredients atomically; local stock never shows below zero.

---

## 5. Zakat — ⚪ not reviewed yet

The earlier conversation pasted in did not include the zakat problem. Zakat logic appears across ~50 files (token tally, serials, receptionist, dashboards). **Needs:** a description of what goes wrong with zakat so it can be traced the same way as the dosage issue.

---

## Recommended order of work

**Batch 1 — lowest risk, biggest gain (a few lines each, no visible change):**
- Crashes/lag: 2.1 memory leak, 2.2 hidden tabs, 2.3 serial estimate, 2.6 log noise
- Uploads: 3.1 food-token retry + chunking, 3.2 dispensary-role desks upload donations/tokens, 3.6 failure logging
- Inventory: 4.1 double subtraction, 4.3 stale overwrite, 4.4 kitchen unit lock

**Batch 2 — small, test after:** 2.4, 2.5, 3.3, 3.4, 4.2, 4.5, 4.11, 4.13

**Needs a test or a decision first:** 2.7 startup freeze (add timing marks), 2.8, 2.9, 3.5 token id format, 4.6 LAN-drop double deduction, 4.7

**Before any of this ships:** try the dosage fixes in the running app (section 1 clinic checks).
