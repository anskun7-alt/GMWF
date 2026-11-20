# Dispensary stock — mismatch audit and rebuild plan (2026-11-19)

## Progress (2026-11-19)
- **Stock book built** in `lib/services/stock/`:
  - `stock_pool.dart`: the one pool rule;
  - `stock_movement.dart`;
  - `stock_ledger.dart`: base + rev + baseOps, plus movements stored by opId;
  - `stock_reader.dart`: the only read API, with StockMath for line units;
  - `stock_actions.dart`: restock / setCounted / addBatch / saveDetails / deleteBatch / dispense, once per token;
  - `stock_cloud.dart`: one Firestore transaction per batch, skipping opIds already in `lastOps`, plus `rev`;
  - `stock_sync.dart`: LAN `stock_moves` / `stock_snapshot` / `stock_details` / `stock_checksum`, the uploader rule, cloud listeners, the weekly check and `StockDriftLog`;
  - `stock_repair.dart`: the one-time repair `stock_repair_v1` and the quarantine list.
- **Wired in:**
  - `realtime_router.dart` and `server.dart`: stock messages, dispense movements, older-version messages turned into movements, register writes details only, no StockFloor on dispensary stock;
  - `local_storage_service.dart`: old function names kept as wrappers over the stock book; the Karachi heal/restore routines are retired;
  - `sync_service.dart`: start-up and LAN reconnect;
  - `patient_form.dart`: dispense, syringes/needles, the stock check;
  - `request.dart`: register / add stock / edit / delete approvals;
  - `dispensar_screen.dart`;
  - the dispensar inventory screens, proforma sheet, ledger and master proforma rename.
- **Tests:** `sandbox/stock_ledger_test.dart` (15) passes, plus the hourly, inventory-queue, syringe, sync-bugs, requests and e2e suites (67 in total).
- **Not done yet:**
  - checking in the real app with several PCs (LAN + cloud);
  - a screen for the weekly report and the quarantine list (the data is in Hive boxes `stock_drift_log` / `stock_quarantine` and in the inventory audit log).
- **All PCs of a branch must be updated together.** Older versions are still understood, but their absolute writes are not prevented on their side.

## The rule the user set
- One stock figure per **stock pool**:
  - a branch without camps has one pool;
  - a branch with camps has one pool per camp.
- Doctor and dispensar always show the **same** figure for the same pool.
- A medicine the dispensar does not have must not be offered to the doctor.

## Why the figures drift today

### A. Several devices own a full copy of the number, and changes reach them by many routes
Each change takes a different route, and some routes apply it twice, overwrite it or lose it.

1. **Double cloud deduction on the server PC.**
   - `patient_form` queues `update_inventory`. The `enqueueSync` guard in `local_storage_service.dart:3324` skips it only on non-server PCs.
   - The LAN server then queues the same dispense again (`server.dart:5810` → `7386-7489`), with a different key and txId and no self-sender check.
   - Restock does the same thing (`server.dart:7583`), so it is added twice.
2. **Double count when a desk is offline from the LAN but online to the cloud.** It uploads the change itself, and later its outbox resends the change to the server, which uploads it again.
3. **Absolute overwrites:**
   - the inventory edit dialog (`inventory.dart:5630-5689`), the admin edit (`inventory_update.dart:414-453`) and the proforma edit (`master_proforma_service.dart:2833-2861`) send full items that include `quantity`;
   - the server's inventory catch-up pushes absolute snapshots, and desks overwrite their local value with them (`realtime_router.dart:1213-1251`).

   These overwrites wipe deductions other PCs made in the meantime.
4. **Re-applied deltas.**
   - The hourly aggregate (`hourly_dispensary_sync.dart:191`) and queue compaction (`local_storage_service.dart:3106-3118`) give the summed delta a **new** txId.
   - A source change that had already landed in the cloud without an acknowledgement is then applied a second time.
   - The cloud marker is only checked on retries (`sync_service.dart:5460`, `server.dart:9243`).
5. **Lost deltas:** a second `update_inventory` with the same queue key replaces the first instead of adding to it (`local_storage_service.dart:3464-3523`).
6. **Download merge** (`saveAllLocalStockItems`):
   - the remote copy always wins, because the Timestamp-vs-ISO comparison never parses;
   - each PC adds back only its own unsent changes, so other PCs' held changes (up to 70 minutes) are invisible;
   - several camp collections are written into one Hive box keyed only by medicine id, so the last collection read wins.
7. **Karachi heal/restore routines** copy Saddar or generic quantities into Haji (`local_storage_service.dart:11248-11537`).
8. **The 0-floor** (`stock_floor.dart`) resets a negative cloud figure to 0. When changes arrive out of order, that difference is lost for good.

### B. Each screen counts differently, even from the same data
- **Doctor panel:** adds up every batch with the same name/type/dose. When its camp filter finds nothing, it falls back to the whole branch and then to all branches. With no patient camp, it picks the first camp.
- **Dispensar table and `getAllLocalStockItems`:** keep only the newest copy of a batch and do not add copies together. Dispense does not bump `updatedAt`, so the copy that was never deducted can be the one shown.
- **Dispense:** adds up loose name matches with no branch filter and an incomplete camp filter. It can deduct from a batch that neither screen shows.
- **patient_queue (editing a prescription)** and **template_screen** each have their own rules again. template_screen even adds fake stock (`quantity: 140`).

### C. Why the doctor prescribes what the dispensar does not have
This follows from A and B. On top of that, the doctor's "reserved" figure keeps stock reserved all day if a dispense event is missed, and the session quantity is not multiplied by days.

## The rebuild

### 1. One stock core: `lib/services/stock/`
- **`stock_pool.dart`**
  - The pool key is `branch` or `branch/camp`. This is the one rule, in place of the fuzzy `matchesCamp`/`getCampInventoryPath` guesses for stock.
  - A batch is identified by `poolKey|medicineId`. Hive keys include the pool, so the same id in two camps can no longer collide.
- **`stock_movement.dart`**
  - Every change is a movement: `{opId (uuid at origin), pool, medicineId, delta, kind: dispense|restock|adjust|count, at, by, device, ref (token serial/line)}`.
  - Movements are stored **by opId**. Applying the same movement twice is impossible, and the order does not matter.
- **`stock_ledger.dart`**
  - Per batch it stores `base` (the last confirmed cloud figure) plus the set of movements not yet in that base. On screen, quantity = base + those movements.
  - When the cloud confirms a movement, it moves into base. This replaces `pendingStockChanges`, the timestamp guessing and the floor.
- **`stock_reader.dart`**
  - The **only** read API, used by the doctor panel, prescription edit, templates, the dispensar table, update stock, the ledger and dispense.
  - It always uses the same grouping (formula/type/dose; batches added together, FEFO order) and the same strict pool filter.
  - It also exposes `reserved` and `available = onShelf − reserved`.

### 2. One writer per route, idempotent everywhere
- Screens never `box.put` stock. They call `StockLedger.record(movement)`.
- Over LAN, the movement (with its opId) goes to the server. The server applies it once per opId and rebroadcasts **the movement**, not a snapshot.
  - Catch-up sends the base figures plus the open movements, merged by opId. It never overwrites with an absolute figure.
- Cloud upload has exactly one uploader per movement:
  - created while linked to the LAN server → the server uploads it;
  - created with no LAN link → the device uploads it and marks it `inCloud`;
  - when that device later sends the movement to the server, the server applies it locally but does not upload it again.
- In the cloud, the increment and its marker are always written in one transaction. The hourly batching stays, to keep the write quota low.
  - An aggregate's id is derived from its sorted source opIds, so a retry can never get a new id.
- A "set quantity" (stock count or edit) becomes an `adjust` movement: delta = counted − what that PC saw. Name/price edits never touch quantity.

### 3. Doctor ↔ dispensar
- Doctor shows `available` from the same reader. A medicine with 0 available is greyed out ("Out of stock at <camp>") and cannot be added. A template line with no stock is flagged.
- Reserved = today's saved but undispensed prescription lines for that pool. A reservation is released on dispense, cancel or end of day.
- Dispense rechecks `available` at the moment of dispensing.

### 4. Clean-up of current wrong figures
- Remove the Karachi heal/restore copiers, the StockFloor reset, the template fake stock and the all-branch fallbacks.
- One-time **stock count per pool**, entered as `count` movements, so every PC starts from the same true figure.

### 4b. One-time repair (runs once per PC, once per pool) — user, 2026-11-19
- **Version flag.** `stock_repair_v1|<pool>` is kept in `app_flags` on each PC, and `inventory_meta/repair_v1` is kept per pool in the cloud. The repair never runs twice for the same pool.
- **Order:** it runs only after the new stock core is installed, otherwise the drift comes straight back.
- **Steps on each PC, for each pool:**
  1. Upload or settle that PC's queued stock changes first, so nothing is lost.
  2. Remove junk records:
     - entries with no name or a corrupt name;
     - duplicate copies left behind by the old two-key storage (`stock:<id>` + `<id>`);
     - Karachi ghost copies created by the heal/restore routines;
     - records filed under a camp the branch doesn't have.

     Junk with quantity 0 is deleted outright. Junk that still holds stock goes to a `stock_quarantine` list with its quantity, so nobody loses medicine silently and an admin can merge or remove it.
  3. Rebuild that pool's local stock from one source:
     - the LAN server's figures if the PC is on the LAN;
     - otherwise the cloud collection for that pool, read with nothing else mixed in.
  4. Save the flag and write a short report (removed / quarantined / changed counts) to the audit log.
- **Cloud side:** the first PC to repair a pool cleans that pool's cloud collection the same way (junk docs out, wrong-camp docs moved, negative figures logged). It sets `repair_v1` so other PCs skip that step.
- **Limits:** this makes every PC **agree**. It cannot know the true shelf figure, because earlier double deductions are already baked into the cloud numbers. The physical stock count after the repair sets the true figures.

### 4c. Ongoing safety check (LAN server)
- **On every desk connect, plus a weekly timer:**
  - the desk sends a checksum of each pool (count + sum of quantities + hash of `id:qty`);
  - the server compares it with its own;
  - if it differs, the server sends that desk its base figures plus the open movements, merged by opId and never an absolute overwrite.

  Running it on every connect costs almost nothing, and catches drift the same day instead of after 15 days.
- **Weekly, the server compares its figures with the cloud per pool.**
  - A difference is logged as a `stock_drift` alert for admins with per-medicine detail.
  - It is fixed automatically only when it is fully explained by changes that are still queued.
  - Anything else waits for an admin to accept the fix, so a bug can't silently "fix" good stock.

### 5. Tests (`sandbox/stock_ledger_test.dart`)
- the same movement delivered through LAN, cloud and replay counts once;
- out-of-order delivery;
- two PCs dispensing offline, then syncing;
- the server-PC case;
- a catch-up does not erase local movements;
- doctor available equals dispensar available;
- a 0-available medicine is blocked at the doctor.
