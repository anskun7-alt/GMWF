# Stock test on real PCs (after the 2026-11-19 stock rebuild)

**Setup:** install the new version on **all** PCs of one test branch first. Pick 2 test medicines, A and B. Write down their figures before you start.

At each step, look at medicine A on the **Doctor** screen ("Avail") and on the **Dispensar** stock table. The two must match: Doctor = Dispensar − medicines reserved by saved, not-yet-dispensed prescriptions.

## 1. First start (one-time repair)
1. Start each PC once and log in.
2. Check that the Doctor and Dispensar figures for A and B match.
3. Check that no medicine with a blank name is listed.

## 2. LAN, all PCs connected to the server
1. Doctor prescribes A: 2 per day × 3 days, then saves.
   - Doctor shows A as 6 lower ("reserved").
   - Dispensar's shelf figure is unchanged.
2. Dispensar dispenses that token. Within a few seconds:
   - both screens show A 6 lower than at the start;
   - the reservation is gone.
3. Press dispense again on the same token, or reopen it.
   - Nothing more may be taken.
4. Add stock to A: +50 on the Dispensar.
   - Every PC shows +50 within a few seconds.
5. Edit A's **name or price only**.
   - The quantity must not change on any PC.

## 3. Out of stock
1. Set B to 0: Update Stock → edit quantity → 0.
2. On the Doctor screen, B must be greyed "Out of stock" and must not be selectable.
3. Prescribe more of A than is available.
   - Saving must be refused with a red message.

## 4. Offline from the LAN
1. Unplug one Dispensar PC from the LAN (keep it running).
2. Dispense 1 token with A on it.
3. Plug it back in. Within a minute:
   - every PC shows A reduced **once**, not twice.

## 5. No LAN server, cloud only (two PCs with internet)
1. Dispense on PC 1.
2. Within about 2 minutes, PC 2 shows the change.

## 6. Branch with camps (e.g. Karachi)
1. Dispense A in Saddar.
   - Haji Camp's figure for A must not change.
2. Doctor and Dispensar in the same camp show the same figure.

## 7. Next day
1. Restart all PCs.
2. The figures still match and nothing is reserved from yesterday.

**If anything differs,** note:
- the step number;
- the medicine;
- the figure on each PC;
- which PC is the LAN server.

Then send me those notes.
