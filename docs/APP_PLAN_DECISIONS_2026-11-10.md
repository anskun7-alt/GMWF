# GMWF: Whole-App Rethink and Decisions (10 Nov 2026)

This builds on `APP_REVIEW_2026-11-10.md` (the findings) and `docs/STABILITY_PLAN.md` (the earlier big plan).
It does three things:

1. Steps back and looks at what the problems have in common
2. Lists where the proposed fixes **contradict each other** or the existing design
3. Gives you the choices to make before anything else is changed

---

## 1. Where things stand right now

| Area | State in the code today |
|---|---|
| Dosage / timing | ✅ Fixed (timing box, Urdu slot names, 4th dose, repeat default). **Not yet tried in the running app.** |
| Stock never below 0 | ⚠️ **Partly applied this session, paused for your decision** (details in section 4, D1) |
| Hang / lag / crash | Not changed |
| Donations / food-token uploads | Not changed |
| Inventory edge cases | Not changed (apart from the stock-floor work) |
| Zakat | **Not reviewed.** The problem has not been described yet. |

The project is **not a git repo**, so there is no one-click undo. Every file changed this session is listed in section 6.

---

## 2. The problems share a few root causes

Looking across all the findings, nearly every bug comes from one of five patterns:

1. **Two copies of the same number that can disagree.**
   - The desk's local stock vs the cloud stock.
   - Pending changes counted in two places (the refresh double-subtraction).
   - The day total for tokens vs the individual token documents.

   Every negative stock value, every drift, and the token count mismatch come from this.
2. **Silent failure.**
   - Errors are caught and only `debugPrint`-ed, which is invisible in release builds.
   - Records are then marked "synced" anyway.

   This is why uploads *seem* fine but aren't, and why nobody can prove where the problem is.
3. **More than one route to the cloud.**
   - Desk direct, LAN server, hourly batch, SDK writes, REST writes.
   - Each route has its own once-only/id rules, so when a device switches route (LAN drops, role changes), a change is either sent twice or not at all.
4. **Too much work on the UI thread.**
   - Whole-history scans and hidden tabs rebuilding on every event, plus listeners that leak.
   - This is the lag, and the leaks eventually cause the crashes.
5. **Defaults that quietly decide for the user.**
   - Pre-filled 1+0+1, BD on repeat, the unit dropdown independent of the stock unit, the full shortfall deducted.

   Each is harmless alone but produces wrong data at volume.

**What this means for the plan:** fixing symptoms one by one works, but a fix in one place can hide or worsen another, as the next section shows. Each fix should be checked against these five patterns.

---

## 3. Contradictions and conflicts between fixes

| # | Conflict | Why it matters | Resolution |
|---|---|---|---|
| C1 | **"Stock never below 0" vs finding the real bugs** | Negative cloud stock is currently the *only visible symptom* of double-deductions (4.1, 4.2, 4.6). Flooring at 0 hides them, and stock silently ends up wrong in the other direction (too high after the next restock). | Floor at 0 **and** record each correction (`negativeCorrectedFrom` field, already in the applied code). Fix 4.1 / 4.2 / 4.6 in the same wave so the floor is a safety net, not a cover-up. |
| C2 | **"Deduct only what the desk has" vs stale desk stock** | A LAN desk's local stock can be *lower* than the cloud (a restock not yet received). The desk then sends a smaller deduction than was actually given, and the cloud ends up *higher* than the shelf. | Acceptable only if the Insufficient-Stock dialog is the gate: if staff choose "Dispense Available", the patient really got less, so deducting less is correct. Needs confirming that staff always see that dialog when the desk is short. |
| C3 | **Stock floor uses Firestore SDK transactions vs the app's REST "one writer" design** | The team moved cloud writes from the SDK to REST because SDK writes hung or duplicated on Windows (see the `cloud_db.dart` comments). The floor uses an SDK transaction. Transactions don't queue offline (they fail cleanly, with a 20 s timeout), but they also bypass `QuotaService` accounting. Phase 5 of STABILITY_PLAN aims for "one writer". | Either keep (cost: one read per deduction, plus a write only when the value is negative) or route it through the server only (server-side floor). Your call: **D1**. |
| C4 | **Inventory 4.1 "delete the pending-changes block" vs hourly sync** | `downloadInventory` and `saveAllLocalStockItems` both add the same queued changes, so they are subtracted twice. But they read the ids slightly differently: `pendingStockChanges` also looks inside `data`. Deleting the "wrong" one could stop counting some held changes. | Keep **one** counting place: the `pendingStockChanges` version, which handles more cases. Remove the duplicate in `saveAllLocalStockItems`, not the other way round as first suggested. |
| C5 | **Uploads 3.1 (let token failures retry) vs 3.4 (Office Boy re-counts)** | Making failures retry is right, but without 3.4 the sweep re-queues under a new id and `totalTokens` is counted twice. | Ship 3.1 and 3.4 together, never 3.1 alone. |
| C6 | **Uploads 3.2 (dispensary-role desks upload again) vs the LAN design** | The design says "the LAN server uploads dispensary data". Re-enabling the desk pass must not let dispensary items leak out from desks. | Safe only because a later check (`sync_service.dart:2348`) already drops dispensary items on LAN desks. Add a test for it. |
| C7 | **Uploads 3.3 (read from server, not cache) vs quota and Windows SDK hangs** | Server reads cost quota and can hang on a half-working Wi-Fi. | Use them only in the 3 places that decide "already uploaded?", with a timeout. Treat a timeout as "not uploaded", so it retries. |
| C8 | **Lag 2.3 (remember the next serial) vs token numbering** | A stale cached serial could hand out a duplicate number. STABILITY_PLAN says the server owns token numbers online. | Clear the cache on **every** entries change, including LAN-received ones. Use it only for the *estimate* shown on screen, never for the issued number. |
| C9 | **Lag 2.2 (hidden tabs stop rebuilding) vs Hybrid desk logic in `build()`** | If any logic (auto-next, alerts, sound) runs inside a hidden tab's build, it would pause while the tab is hidden. | Check each builder before swapping. Only the list and summary UI is skipped. |
| C10 | **Dosage defaults disagree** | A new medicine starts at **1+0+1**. A repeated old visit now defaults to **1+0+0**. | Pick one rule (**D3**). |
| C11 | **"Current version works" vs code that isn't on clinic PCs yet** | STABILITY_PLAN Phase 2a+3 (5 Nov) is marked "NOT yet on real PCs". If the clinic runs an older build, the code already differs from the working version, and every fix stacks on top of untested changes. | Confirm which build the clinic runs (**D4**) before shipping anything. |
| C13 | **Office Boy writes with the Firestore SDK; the rest of the app writes through REST** | Two uploaders for the same data: the SDK may send a "timed-out" write later, while the queue sends it again. Fixing only the queue (3.1) leaves the double count. | Move the Office Boy and Kitchen token writes onto the queue path (section 6.3). |
| C12 | **Small-fix track vs STABILITY_PLAN phases 2–8 (~30 days of redesign)** | Both touch the same sync and realtime files. Doing both at once means constant conflicts and no clear "working" baseline. | Choose one track (**D2**). |

---

## 4. Decisions for you

### D1. Stock never below 0: which approach? (work is half-done and paused)

What is already in the code:
- **Desk:** a dispense deducts only what is actually in stock. A shortfall is no longer sent to the cloud (`patient_form.dart`).
- **Cloud floor:** after any stock deduction lands, a small transaction sets the medicine to 0 if it went negative, and records the old value in `negativeCorrectedFrom` (`stock_floor.dart`, hooked into the 3 upload paths: `sync_service.dart`, `server.dart`, `server_sync_manager.dart`).
- **Cleanup of existing negatives:** every inventory download looks for negative medicines and sets them to 0. Kitchen stock is cleaned the same way when it loads.
- **Kitchen:** cooking can no longer write a negative quantity or overwrite a stock record. Kitchen stock always displays ≥ 0 (`cook_dialog.dart`, `kitchen.dart`, `stock_item.dart`).
- Local (offline) stock already never went below 0. That was unchanged and correct.
- **Checks:** the analyzer found no errors. 88 inventory-related tests passed. 5 failed in areas this change doesn't touch: dispense status, peak-count and `lanPushSig`. The `lanPushSig` one was already failing before. The other 4 look date-dependent but are not proven unrelated.

The options:
- **A (recommended): keep it, and fix the double-count bugs (4.1, 4.2, 4.6) in the same wave.** Negatives stop at the source, the floor catches anything left, and `negativeCorrectedFrom` shows which medicines drifted.
- **B: keep only the desk and display parts, and remove the cloud floor.** This stays fully inside the REST design (C3), but the cloud can still go negative from double-counts.
- **C: undo all of it** and do it later inside a bigger stock redesign.

### D2. Which track?
- **Track 1 (recommended): stabilise in place.**
  - Small, behaviour-preserving fixes in waves (section 5).
  - Each wave is tested on the clinic setup before the next one.
  - STABILITY_PLAN phases 2–8 are paused.
- **Track 2: continue STABILITY_PLAN** (sequenced event log, one writer, and so on) and fold the fixes into it. Bigger, slower, cleaner at the end, but riskier for a version you say works.
- **Track 3: only the reported issues.** Dosage (done), zakat, negative stock, uploads. Nothing else.

### D3. Timing default for new medicines
- **Keep 1+0+1 pre-filled** (doctors used to it; typing now replaces it correctly).
- **Start empty** (an empty box saves as once a day, the same as the repeat default).

### D4. Which build is in the clinic?
Is it the 7 Nov installer, which includes the 5 Nov STABILITY_PLAN changes? Or an older one? This decides what "the working version" means.

### D5. Zakat
Describe what goes wrong (wrong amount, wrong token type, missing in reports, not uploading…) so it can be traced like the dosage issue.

### D6. Food-token ID format (upload 3.5)
Adding a device suffix stops two PCs overwriting each other's tokens, but it changes the ID format that serve and reverse rely on. Do it now (with testing) or later?

---

## 5. Proposed waves (Track 1)

Each wave is a few small changes. Each one is tested on the clinic setup before the next.

**Wave 0: verify what is already done (no new code)**
- Dosage clinic checks (type 100 → 1+0+0, 0+0+1 → رات).
- The stock-floor decision (D1).
- Confirm the clinic build (D4).

**Wave 1: stop data loss and wrong numbers**
- Inventory: 4.1 (count pending changes once, per C4), 4.2 (combine deductions per medicine), 4.3 (Dasterkhwaan adjust as an increment), 4.4 (kitchen unit lock).
- Uploads: the whole food-token and donation package in section 6.3 (this covers 3.1 + 3.4 together per C5, 3.2 per C6, 3.3 per C7, 3.5 per D6, and 3.6).

**Wave 2: stop the crashes and the worst lag**
- 2.1 (listener leak), 2.6 (log noise), 2.2 (hidden tabs, after the C9 check), 2.3 (serial estimate, per C8).

**Wave 3: remaining correctness**
- Inventory 4.5 (supervisor approval), 4.11 (skip expired batches), 4.13 (text quantities), 4.8 (name matching).
- Lag 2.4, 2.5.

**Wave 4: needs a test or decision first**
- 2.7 startup freeze (add timing marks first), 2.8, 2.9, 4.6 (LAN-drop test), 4.7 (medicine id change).

**After every wave:**
- Run the analyzer and tests.
- Check on one clinic PC that the main flows work as before: issue token → doctor → dispense → stock → upload.

---

## 6. Office Boy data "nowhere in the cloud": traced

Traced from the Office Boy screen (`office_boy.dart`) through the LAN server and the cloud queue to every screen that reads it back.

### 6.1 Where it writes vs where it is read: **paths match**
- **Write:** `branches/{branch}/dasterkhwaan/{yyyy-MM-dd}` (day totals) and `…/{yyyy-MM-dd}/tokens/{dst_branch_date_n}` (one doc per token).
  - The branch is normalised to lowercase (`karachi`, `gujrat`, …) by `sanitizeBranchId` before writing (`office_boy.dart:528`).
- **Read:** the Office Boy history tab, Kitchen, Download/Export, the home dashboard and the HQ overview all read the same `branches/{lowercase}/dasterkhwaan/{yyyy-MM-dd}` path.
  - The dashboard also tries the old `ddMMyy` date format and the Karachi camp variants.
- So in the normal case **it is not reading from the wrong place.**
- Two edge cases can still put data in an unexpected place:
  - **`sanitizeBranchId` falls back to `karachi`** when the branch cannot be worked out (`local_storage_service.dart:5604-5640`). An Office Boy PC with a missing or unrecognised branch silently writes into **Karachi's** cloud data, and the user's own branch shows nothing. *Needs a check on the affected PC: what branch does its user record have?*
  - **The LAN server's date fallback.** If a token event ever reaches the server without a date, the server uses its dispensary date key (`ddMMyy`, `server.dart:_todayKey`) instead of `yyyy-MM-dd`. The kitchen and history screens never read that format. The Office Boy screen always sends the date, so this is only a fallback risk.

### 6.2 Why it doesn't reach the cloud: the real causes
| # | Cause | What staff see | Evidence |
|---|---|---|---|
| T1 🔴 | **The Office Boy screen writes with the Firestore SDK, not the app's REST uploader.** Day totals use a 4 s timeout; the token docs use 6 s (`office_boy.dart:631`, `:655`). The app moved everything else off SDK writes because on Windows they hang or are sent much later (`cloud_db.dart` comments). | Totals appear, token list empty; or the data turns up hours later; or the count is doubled. | Code confirmed |
| T2 🔴 | **Day total written, token docs timed out → no retry queued** (`office_boy.dart:670-672`; only logged). Tokens stay "pending" locally until the screen is reopened or the once-per-session sweep runs. That sweep re-sends them under a new batch id, so `totalTokens` is **counted again**. | "Added but not in the cloud", later "count is too high". | Code confirmed |
| T3 🔴 | **The cloud queue marks tokens synced even when their upload failed** (`sync_service.dart:4347-4351`). Over 500 tokens in one batch always fails. | Tokens never appear, and nothing retries. | Code confirmed |
| T4 🟠 | **Two PCs can give food tokens the same ID** (`dst_branch_date_n`, numbered from each PC's own local box, `office_boy.dart:539-560`; the same in `kitchen.dart`). | Fewer token docs than the count; one PC's tokens overwritten. | Code confirmed; how often it happens needs confirming |
| T5 🟠 | **A LAN copy marked as "not mine".** When a PC receives tokens over LAN it marks them `lanReceived` and never uploads them (correct). The issuing PC ignores its own echo by connection id (`realtime_manager.dart:2065`). After a reconnect the id can change, and the issuer's own tokens could then be marked "not mine" and never re-sent. | Tokens issued around a LAN reconnect never reach the cloud. | Needs confirmation |
| T6 🔴 | **Failures are invisible.** Only `debugPrint`, nothing in `gmwf_sync.log`. | Nobody can tell what failed. | Code confirmed |

**Donations** (same review, sections 3.2 / 3.3 of the findings):
- Donations taken while a receptionist, doctor or stock role is logged in on that PC never upload (`sync_service.dart:1954`).
- On a poor connection the queue can read Firestore's offline copy, decide "already uploaded" and drop the donation.
- Office Boy donation boxes use `DonationBoxStorage` with the same queue, so the same two causes apply.

### 6.3 Proposed fix (all in Wave 1, shipped together)
1. **Office Boy and Kitchen token writes go through the same queue/REST path as everything else:**
   - Save locally.
   - Queue one `save_dasterkhwan_tokens` item with a fixed batch id.
   - Upload immediately.
   - No more SDK direct write → removes T1 and T2 and the double count.
2. **Token docs uploaded in chunks of ≤ 450, and a failure goes to the normal retry.** Never marked synced unless written (T3). Retrying can't double the totals: `appliedBatches` already guards them.
3. **Token IDs get a short device suffix** (D6). The number shown on screen stays the same (T4).
4. **The issuer is identified by device id, not connection id**, so its own tokens are never marked "not mine" (T5).
5. **Every upload failure for donations and tokens is written to `gmwf_sync.log`,** with an on-screen "N waiting to upload" badge on the Office Boy screen (T6).
6. **Donations:** desks with a dispensary role keep uploading donations and food tokens (3.2), and the "already uploaded?" check reads the server, not the offline copy (3.3).
7. **A branch must be known before writing.** If `sanitizeBranchId` would fall back to `karachi` for a non-Karachi user, block issuing with a clear message instead of writing into Karachi.

### 6.4 How to confirm on the Office Boy PC (before fixing)
- In Firestore, open `branches/<branch>/dasterkhwaan/<today yyyy-MM-dd>`:
  - Compare `totalTokens` with the number of docs in `tokens`. Fewer docs → T1, T2, T3 or T4.
  - Also look under `branches/karachi/dasterkhwaan/<today>` for that PC's `issuedBy` name. Found there → the branch fallback.
- In the Hive box `dasterkhwaan_tokens` on that PC: tokens with `syncStatus: pending` → not uploaded. `lanReceived: true` on tokens this PC issued → T5.
- In the Hive box `sync_queue`: `sync_save_dasterkhwan_tokens_…` items stuck with `lastError`.

---

## 7. Files changed in this session (stock floor, D1)

| File | Change |
|---|---|
| `lib/services/stock_floor.dart` | **New.** `repair`, `repairAll`, `repairCollection` |
| `lib/services/sync_service.dart` | Import; floor after `_incrementStockOnce` when the amount is negative |
| `lib/realtime/server_sync_manager.dart` | Import; floor after `update_inventory` when the delta is negative |
| `lib/pages/server.dart` | Import; floor after `update_inventory` (batched and single) |
| `lib/pages/dispensary/dispensar/patient_form.dart` | Shortfall and fallback deduct only what is in stock |
| `lib/pages/dasterkhwaan/widgets/cook_dialog.dart` | Missing stock doc: merge + increment instead of overwrite; floor after cooking |
| `lib/pages/dasterkhwaan/kitchen.dart` | Floor after adjust; clean negatives on load; local value never below 0 |
| `lib/models/stock_item.dart` | Kitchen stock shows ≥ 0 |
| `lib/services/local_storage_service.dart` | Import; negative-stock cleanup on each inventory download |

Earlier (dosage, other conversation): `formatters.dart`, `patient_form_helper.dart`, `patient_form.dart`, `doctor_screen.dart`, plus tests `dose_timing_formatter_test.dart`, `urdu_dose_slots_test.dart`.
