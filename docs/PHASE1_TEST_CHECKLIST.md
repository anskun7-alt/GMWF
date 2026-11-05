# Phase 1 — Manual test checklist (real PCs)

Run on a **test network**, not in a live clinic. All PCs must run the **same new build**.
Setup: 1 server PC, 2 reception PCs (R1, R2), 1 doctor PC (D), 1 dispenser PC (P). Wired LAN.
Use a test branch / test patients.

Tick each line. If anything fails, note the time, the PC and what the status pill showed.

## A. Version gate
- [ ] A1. Start the server with the new build. Start one PC with an **old** build → its status pill shows **Update required** / it does not connect. Server log shows "Protocol version mismatch".
- [ ] A2. Update that PC → it connects, pill shows **Live**.

## B. Normal flow (server up)
- [ ] B1. R1 issues a token → green toast "Token … issued" appears; the number is **not** a 4-digit (1001+) number.
- [ ] B2. The token appears on D within ~1 s of the green toast (before the patient could walk over).
- [ ] B3. R1 and R2 each issue 10 tokens as fast as possible, alternating → numbers 1–20 with **no duplicates and no gaps**, all on D in order.
- [ ] B4. D's auto-select always picks the **lowest waiting** number. Prescribe 5 in a row — never skips a lower one.
- [ ] B5. Status pill on R1, R2, D, P shows **Live** when idle.

## C. Busy / slow server
- [ ] C1. On the server PC open several heavy programs (or run a CPU stress tool) so it is at ~100 % CPU. Issue tokens from R1:
  - token still gets a normal server number (not 1001+), reception waits up to a few seconds;
  - if it takes > 5 s, the orange "not confirmed yet" toast appears — and the token **still** reaches D shortly after.
- [ ] C2. No token number is skipped or duplicated during C1.

## D. Cable pulled on a desk
- [ ] D1. Unplug D's cable for 30 s. Within ~20–25 s D's pill shows **Offline**/**Searching**.
- [ ] D2. While D is unplugged, issue 3 tokens from R1 (they get green toasts — the server has them).
- [ ] D3. Plug D back in → pill goes **Catching up (n)** → **Live**; all 3 tokens appear in the right order.
- [ ] D4. If D had no patient selected, it does **not** auto-select a later token before the 3 missing ones arrived.

## E. Server down (real outage)
- [ ] E1. Stop the GMWF server (or unplug the server PC). R1 and R2 pills show **Offline**.
- [ ] E2. Issue 3 tokens on R1 and 3 on R2, alternating → orange **OFFLINE** toasts; R1 numbers are in one block (e.g. 1001, 1002, 1003), R2 in another (e.g. 2001 …). **No duplicates.**
- [ ] E3. Pill on R1/R2 shows **Offline – n unsent**.
- [ ] E4. Start the server again → R1/R2 pills go **Sending (n)** → **Live**; all 6 offline tokens appear on D.
- [ ] E5. On D the 6 offline tokens are placed by the **time they were issued** among any tokens issued before/after the outage — not all at the end.
- [ ] E6. After the outage, the next online token continues the normal sequence (e.g. 21), not 1004 or 2004.

## F. New PC (no offline block yet)
- [ ] F1. Install the build on a fresh PC, connect it to the server, issue one token (it now has a block).
- [ ] F2. (Known limit) A PC that has **never** connected and goes straight offline numbers from the shared count — avoid in clinics; connect every new PC once before use.

## G. Dispensing (Tier 1 fixes)
- [ ] G1. Prescribe a patient on D → P can dispense it (no "already dispensed by another desk" error).
- [ ] G2. Open a patient on P, change the prescription on D before P clicks Dispense → amber "Prescription Modified" banner; P must confirm the change.
- [ ] G3. Open the confirm dialog on P, then change the prescription on D, then confirm on P → "The doctor changed this prescription… Nothing was dispensed"; dispense again after review works.
- [ ] G4. Two dispenser PCs open the same patient → the second sees "Parallel Counter Warning".

## H. Restrictions (Tier 1 fix)
- [ ] H1. Give child Ali (guardian CNIC G) a 5-day prescription. Token for Ali tomorrow → blocked.
- [ ] H2. Token for Ali's sister Sara (same guardian) → **not** blocked.
- [ ] H3. Token for the guardian himself → not blocked by Ali's restriction.

## H2. Doctor actions that move a patient backwards (status only moves forward now)
- [ ] H2-1. Doctor opens a patient, then **skips** them → patient shows as skipped on D and on the server/other desks.
- [ ] H2-2. Doctor re-opens / recalls the skipped patient → works, patient can be prescribed.
- [ ] H2-3. Any "return to queue" / "send back" button the doctor uses → patient goes back to waiting on **all** desks (not just D). If it bounces back to the old status on another desk, report it.

## H3. Clocks and late messages
- [ ] H3-1. On every PC: Windows Settings → Time → "Set time automatically" ON; all PCs show the same time (± 1 min).
- [ ] H3-2. Doctor edits a prescription twice quickly → P shows the **second** edit, never the first one again.
- [ ] H3-3. Restock a medicine (+100) on one PC; check the quantity on 2 other PCs. Pull a desk's cable for 30 s and plug back → quantity unchanged (not +200).
- [ ] H3-4. Restock the same medicine twice quickly (+10, +20) → +30 on every PC.

## I. Server load
- [ ] I1. With 4–6 desks working for 30 min, server Task Manager: GMWF CPU mostly < 30 %, no "Not Responding".
- [ ] I2. Server dashboard log still updates (about once a second).
