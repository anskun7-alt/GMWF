# School ERP — plan (2026-11-14)

Scope: rebuild the School module (`lib/pages/school/`) into a complete ERP for
Taleem o Tarbiyat School System, Gujrat. Covers library, students/enrollment,
daily log, the deduction-based fee system, and the data/sync faults found in the
audit. Model: the standard school-ERP shape (openSIS / Fedena / Gibbon style —
academic year → class → section → enrollment; fee heads → monthly fee sheet →
append-only payments → receipts; library catalogue → loans) adapted to our
Hive + Firestore + sync-queue stack. `docs/school_erp_schema.sql` already
sketches that shape in Postgres; we reuse its rules (append-only money,
one enrollment per student per year, unique admission no.) not its tech.

Status markers: **[DECIDE]** = needs an answer before that phase is built.

## 0. Ground rules (decided 2026-11-14)

1. **Madrassa is not touched.** No file under `lib/pages/madrassa/` is edited, and no madrassa
   behaviour changes. Madrassa bugs found in the audit are only listed (§2) so School does not repeat them.
2. **School is self-contained and fully renamed.** Logic copied from madrassa becomes school code with
   school names: `SchoolFeeEngine` (not `MadrassaFeeLogic`), `SchoolFeeConfig`, `SchoolDailyLog`,
   `SchoolHoliday`, `SchoolBranchId.normalize` (own copy of the branch-alias map), and so on.
   School code **never imports** `pages/madrassa/**`. Shared services (`LocalStorageService`,
   `SyncService`, `CloudDb`) get **new school-specific entry points** only; existing madrassa paths
   in them stay byte-identical.
3. **Madrassa is mentioned only in comments,** so the history stays clear:
   `// Adapted from madrassa MadrassaFeeLogic.calculateStudentFee (2026-11). Diverges: month close, versioned config.`
4. **Data names are school-only:** Hive boxes `local_school_*`, Firestore `branches/{b}/school_*`, sync
   actions `save_school_*`, audit types `school_*`. No madrassa keys are shared.
5. **The one madrassa read we keep:** "Transfer from Madrassa" at admission reads madrassa student
   records (read-only) through one adapter, `SchoolMadrassaTransferReader`. It does not write back.
   The madrassa student is **not** marked as transferred, because that would edit madrassa data.
   The school record stores `transferredFromMadrassaId` for traceability.
6. **UI follows `gmwf_ui`** (§3.7). The old `school_theme.dart` and `SoftPalette`/`RoleThemeProvider`
   usage are removed from the School module.

---

## 1. The fee form (حلف نامہ) — translation

Title: *Affidavit — Taleem o Tarbiyat School System, Gujrat.* Rules:

1. Fee at admission is Rs 12,000.
2. Fee can become Rs 0 only by following the rules below.
3. Child comes to school **on time every day** → after one month, Rs 2,000 off.
4. **No leave for the whole month** → Rs 2,000 off.
5. Child's **diary** (school work) is learnt, and parents **signed and wrote remarks** → Rs 2,000 off.
6. Child's **behaviour with teachers** is excellent → Rs 2,000 off.
7. **Uniform complete and clean** → Rs 2,000 off.
8. **Monthly parents' meeting (PTM)** at month end, where the child's progress is shared; for the child's
   **best monthly academic performance** → Rs 2,000 off.
9. Every two months: Bazm-e-Adab, speech gala, training and field trip — **participation compulsory,
   absence not allowed.**

Closing: with parents' and students' cooperation, education becomes free.

### Form vs. the list you gave

| # | Form | Your list | Match |
|---|---|---|---|
| 1 | On time daily (punctuality) | — | **form only** |
| 2 | No leave all month (attendance) | Attendance | yes |
| 3 | Diary learnt + parent signature | Diary + parent signature | yes |
| 4 | Behaviour | Behaviour | yes |
| 5 | Uniform | Uniform | yes |
| 6 | PTM + monthly performance | PTM | yes (form ties it to performance) |
| 7 | — | Message reply | **list only** |

**Decided (2026-11-14):** "diary + parent signature" and "message reply" are the same rule. The six
rules, Rs 2,000 each = Rs 12,000:

1. Attendance  2. On-time arrival  3. Message reply (diary read and signed by parent)
4. Behaviour  5. PTM attended  6. Uniform

Also from the form: it says the 12,000 is the fee "at admission"; you described it as the monthly
fee that reaches 0. Plan assumes **monthly**, with a separate one-time admission fee head (default 0)
so both readings are supported.

---

## 2. What is broken today (audit summary)

### P0 — data loss / corruption
- **Library returns never sync** — written to Hive only; the next pull restores the remote
  `borrowed` loan while the local copy count stays incremented. Loans and stock drift.
- **Grades all save under id `''`** — `SchoolGrade.toMap()` drops `id`; every re-save collides on
  one Hive key and Firestore `.doc('')`. Marks also bleed across exams (controllers keyed by student only).
- **Pull overwrites pending local edits** for loans, attendance, grades, fees, homerooms (LWW only
  applied to students/teachers/books).
- **Queued student upload re-stamps `lastModified`** → the oldest offline edit wins.
- **Fees:** discount never reduces the total (`copyWith` bug), stored status stale, `paidAmount`
  replaced not accumulated, receipt no. collides (`REC-` + 6 ms digits), no month picker → past
  months/arrears unreachable.

### P1 — functional
- Library: no edit safety (edit resets `availableCopies = totalCopies` even with books out), no
  delete/unlist, borrower is free text, return date can precede issue date.
- Students: roll no. typed by hand, **no uniqueness check**; no B-form/CNIC duplicate check; no
  gender control (everyone saved "Male"); no status control (left/graduated/suspended unreachable);
  edit wipes `transferredFromMadrassaId` and resets parent-verified; no try/catch on save (dialog sticks);
  madrassa transfer doesn't mark the madrassa record.
- Branch id: students saved under the *normalized* branch, read under the *raw* one → students can vanish;
  HQ is forced to `gujrat`.
- Every save except students blocks ~20 s offline (no connectivity check); grade save does it per student.
- Teacher edit drops homeroom fields locally; moving a homeroom leaves the old class assigned.
- Section D missing from grading, fees, homeroom (hard-coded A–C).

### P2 — permission loopholes
- Any role without "teacher" (e.g. `staff`) gets the full executive view; missing role defaults to
  "School Admin". Teacher limits are UI-only (any grade selectable; library edit not gated;
  teacher matched by name substring). Teacher tab indexes in `module_registry.dart` open the wrong tabs.

### P3 — placeholders
- "Save & Print Receipt", "Export Fee Report", "Print Report Card" do nothing. Hard-coded school
  phone/address, `'July 2026'`, tuition fallback 3500, `gujrat` default.

### Madrassa fee bugs we must NOT copy
- One `current` config → changing a fee **retroactively changes every past month** (no month close).
- PTM "joined after PTM" exemption uses *today's* month, not the fee month.
- PTM reschedule entries never parse (`'Day 15'` → `int.tryParse` null).
- PTM migration overwrites the new day's whole log.
- Unmarked day = absent for everyone; Islamic holidays block logging but still count as working days.
- Shallow day-log merge drops local unsynced edits; concurrent installments lost; unrounded doubles
  leave Rs 0.43 "partial" balances; past months with no cached logs show full fee due.

---

## 3. Target design

### 3.1 Shared foundations (do first — everything depends on it)
- **One branch-id function** used by every school read *and* write (reuse madrassa `normalizeBranch`);
  HQ gets a branch picker instead of silent `gujrat`.
- **Write helper** `SchoolStore.write(collection, id, map)`: stamps `lastModified` (device time +
  `updatedBy`), writes Hive, enqueues, returns immediately; uploader never re-stamps. Online write is
  fire-and-forget behind a connectivity check + 5 s timeout. Removes all 20 s hangs.
- **Pull merge**: LWW on `lastModified` for *every* collection; never overwrite a `pending` local record;
  day documents merged **per student, per field**.
- **IDs**: `<PREFIX>-<branch>-<millis>-<4 random>` for documents; human numbers (admission no.,
  receipt no., accession no.) from a **per-branch counter** issued with a device suffix when offline
  (e.g. `GRT-R-000123` online, `GRT-R-D2-0045` offline) — unique without a server round-trip.
- **Audit log** entry for every create/edit/status change/payment, with before → after values.
- **Sections** from config (A–D+), never hard-coded.
- **Roles** (server rules + UI): Principal/School Admin (all), Accountant (fees only), Teacher
  (own homeroom class: daily log, grades; read-only students), Librarian (library). Unknown role → no access.
  Teacher identity by user id, not name.
- **Soft delete everywhere**: nothing is hard-deleted; records get `status` + `statusDate` + reason.

### 3.2 Library
- **Edit book**: title, author, ISBN, category, total copies, shelf/location, language.
  - `availableCopies` is **derived** = `totalCopies − active loans`, never typed. Total copies cannot be
    reduced below copies currently out (error says how many are out).
  - Edit history in audit log (fixes typos without losing trail).
- **Unlist (no delete)**: `status: listed | unlisted`, `unlistedAt`, `unlistedBy`, reason
  (lost / damaged / withdrawn / duplicate entry).
  - Unlisted books hidden from catalogue and cannot be issued; visible under an "Unlisted" filter;
    **Relist** button.
  - Unlisting a book with copies out: allowed, but outstanding loans stay returnable; warning shown.
  - "Duplicate entry" reason lets staff merge mistakes without deleting.
- **Issue**: pick borrower from **student/teacher records** (search by name/admission no.), outsider
  keeps manual CNIC/phone with validation. Limit per borrower (config, default 2). Block if borrower
  already has an overdue book. Copy count from a fresh read.
- **Return**: date ≥ issue date and ≤ today; goes through the write helper (fixes P0 sync bug);
  condition (ok / damaged / lost — lost reduces total copies with audit).
- **Overdue**: list + optional fine per day (config, default 0); fine can be added to the student's
  fee sheet as an "other charge".
- Later (optional): per-copy accession numbers + barcode.

**Added 2026-11-14 (user):**
- **Book cover images**: same `MediaUploadTile` + compaction pipeline used for student photos.
  The cover is compressed to a thumbnail and stored on the book. A placeholder cover is generated
  from the title (initials on an indigo tint) when no image exists.
- **Members management**: a Members tab listing every borrower (students and teachers linked from
  their records, plus outsiders as their own member records). Each member gets a profile with:
  - contact details, editable (outsiders fully; students and teachers link back to their record);
  - books out now, overdue items, full borrowing history and fines;
  - a status (active / blocked), plus a per-member limit override.
  - Outsider members are stored as `school_library_members/{id}`, not as free text on each loan.
- **Full redesign as an inventory screen**, replacing today's plain list rows:
  - **Top strip**: KPI tiles for titles, copies, out now, overdue and members.
  - **Catalogue**: a dense, sortable inventory table on desktop, with cover thumbnail, title (Urdu-aware),
    author, category, shelf, a stock bar (available / total, colour-coded), status and row actions.
    Phones get a cover grid instead.
  - **Toolbar**: search, category and stock filters (in stock / low / out / unlisted) and a grid/table toggle.
  - **Detail panel**: clicking a book opens a side panel with the cover, details, copy status, current
    borrowers and loan history, plus Issue / Edit / Unlist / Relist actions. Nothing opens in a new screen.
  - **Tabs**: Catalogue · Loans (issued / overdue / returned) · Members.
  - Built from the `gmwf_ui` School kit and global components (`GKpiTile`, `GFilterBar`, data table,
    `SchoolBookTile`), in Scholar Indigo, LTR and Urdu RTL.
  - Fixes seen in the current screen: an empty "By •" when there is no author (hide it, or show
    "Unknown author"), and Urdu titles aligned correctly.

### 3.3 Students & enrollment
- **Admission no.** auto-generated per branch counter (editable only by Principal, uniqueness enforced).
  **Roll no.** per class-section per academic year, auto-suggested, unique within section.
- **Duplicate checks** before save: same B-form, or same father CNIC + same name, or same name + father
  name + DOB → show the match, allow "it's a sibling" / "open existing".
- **Siblings**: link by father CNIC (guardian record shared); sibling list on profile.
- Missing fields: **gender**, status, blood group (optional), emergency contact.
- **Edit**: every field; keeps madrassa link, parent-verified flag, documents; audit before/after.
  Class/section change mid-year recorded as a dated transfer (affects which teacher logs them).
- **Status lifecycle** with *effective date*: `active → suspended → active`, `active → left | graduated`,
  `left → rejoined`. Status history drives fee proration (same rule as madrassa `_isStudentActiveOnDate`).
  No delete; "Entered by mistake" = status `void` (excluded from everything, kept for audit).
- **Madrassa transfer** is read-only (see §0.5). It stores `transferredFromMadrassaId` and `transferredAt`
  on the school student. The madrassa side is left alone.
- **Academic year + promotion**: year record (e.g. 2026-27); end-of-year bulk promote by class with
  per-student hold-back; graduated for final class.
- Save is wrapped in try/catch; dialog never sticks; feedback shown on the parent screen.
- Admission form PDF + fee affidavit (the Urdu form) printable from the profile, school details from
  branch settings (not hard-coded).

### 3.4 Daily log (feeds the fee)
One document per class-section per day: `branches/{b}/school_daily_logs/{yyyy-MM-dd}`, entries per
student, merged per field. Per student per day:

| Field | Values | Who marks |
|---|---|---|
| attendance | present / absent / leave (approved) / leave requested | class teacher |
| onTime | true / false (only if present) | class teacher |
| uniform | true / false / waived (on leave) | class teacher |
| behaviour | good / needs improvement + note | class teacher |
| parentReplied | diary read + parent signed/replied: true / false | class teacher (parent app later) |

- **Edit window**: today and the past 3 days for teachers; Principal any day in an *open* month;
  nobody after **month close** (3.5). Every edit audited.
- **Unmarked day ≠ absent for fee**: a day with no log saved is "not recorded" and excluded from the
  denominator, but the month **cannot be closed** while working days are unrecorded (close screen lists them).
- **Holidays**: one list (manual + Sundays + configured weekly off) used by *both* the log screen and fee maths.
- **PTM**: dated per month (default: last Saturday — form says month end), reschedulable *per month*;
  attendance at PTM recorded on the PTM record, not the day log. Joined after PTM / PTM cancelled → credit given.
- **Bimonthly events** (Bazm-e-Adab, speech gala, training, field trip): event records with
  compulsory attendance list; absences flagged on the parent report. **No fee effect** (decided).

### 3.5 Fee system (copy madrassa structure, fix its faults)
**Config per branch, versioned by month** (`school_fee_config/{yyyy-MM}`):
`baseFee 12000`, six rules each `{key, label, amount 2000, mode}`, `admissionFee`, `enableFees`, `ptmDate`,
`roundTo 1`. Editing creates/edits **only the open month**; closed months keep their snapshot. Rule amounts
must sum to `baseFee` (integer check).

**Monthly calculation** per student (pure function, unit-tested):
```
activeDays   = working days in month the student was active (status history, join date)
recorded     = working days that have a saved log
base         = baseFee × activeDays / workingDays           (pro-rated for joiners/leavers)
rule credit  = amount × qualifyingDays / recordedActiveDays  (pro-rated — decided)
             for attendance, on-time, message reply, behaviour, uniform
PTM credit   = amount × activeDays / workingDays if attended (or joined after / cancelled)
due          = round(max(0, base − Σ credits))
```
- Sunday/holidays excluded both sides; logs on non-working days ignored.
- **Approved leave counts as present** (decided): leave days qualify for attendance, on-time, uniform
  (waived) and behaviour. Message reply still needs an actual reply. Pending (unapproved) leave = absent.
- Absent day: no attendance, on-time, uniform or behaviour credit; message reply still allowed.
- Whole rupees only; same rounding everywhere.

**Month close** (Principal/Accountant): validates every working day recorded, freezes a **fee sheet**
per student `school_fee_sheets/{yyyy-MM}_{studentId}`: base, each rule's credit with counts, due,
config snapshot. After close, logs/config for that month are read-only; corrections = **adjustment
entry** (reason + approver), never a silent recompute. Before close, sheets show as "provisional" live.

**Payments** (append-only): `school_fee_payments/{id}` `{studentId, months[], amount, method, receiptNo,
by, at}`. Installments add up; allocation oldest month first; overpayment becomes **credit** carried to
next month (never dropped). Reversal = negative entry with reason, Principal only.
Balance = Σ sheets due + adjustments + admission/other charges − Σ payments. Arrears visible across months.
Concession (welfare): per-student % or fixed, dated, approved, shown as its own line.

**Outputs**: printable receipt (sequential no.), monthly fee slip/challan per student showing the six
rules ✓/✗ (motivates parents — the point of the form), defaulters list, collection report per day/month,
CSV/PDF export.

### 3.6 Grades, attendance of teachers, homeroom (fix-only in this round)
Grade id bug, marks bleed, marks ≤ total validation, attachment stored once (not per student),
report card PDF; homeroom move clears old class; teacher edit keeps homeroom fields.

### 3.7 Look and theme: Scholar Indigo on `gmwf_ui` (decided)

`gmwf_ui` rule: there are **no per-module themes**. Every screen follows the user's theme choice
(GMWF, Nexus or Twilight, each light or dark). A module's identity comes from `brandOverride` plus
its own kit. School therefore gets:

| Role | Value |
|---|---|
| Brand (light) | **Scholar Indigo `#2E3A8C`**, new `indigo` swatch in `gmwf_ui/tokens/tokens.json` |
| Brand (dark) | derived by `GColor.accentOnDark` (≈ `#8E9BEF`); the generator's contrast check must pass |
| Brand soft | `GColor.tint` of brand (≈ `#ECEEFB` light) for selected rows and chips |
| Accent | GMWF gold, unchanged (`gold500` `#CB9B14`): fee amounts, highlights |
| Status | shared `gmwf_ui` success / warning / danger / info, unchanged: present, leave, absent, late |
| Module icon | graduation cap from the logo (`GIcons.student`, Material `school`), on a `GModuleTile` |
| Canvas, type, radius, motion | whatever the user's theme says; nothing school-specific |

**Work in `gmwf_ui`** (package rules: the generator, the guard test and the module-rules test must stay green):
1. Add an `indigo` 50–950 swatch to `tokens.json`, with `indigo.800 = #2E3A8C`. Run `dart run tool/generate.dart`, which produces
   `GPalette.indigo*` and checks contrast in both modes. Add a module colour token `school → indigo.800`.
2. New **School kit** `package:gmwf_ui/school.dart`, shaped like the dispensary/donations kits:
   - `shared/`: `SchoolStudentHeader`, `SchoolFeeRuleStrip` (the six rules ✓/✗ with Rs amounts; the
     motivational heart of the form), `SchoolFeeSheetCard`, `SchoolLogRow` (one student's day: P/A/L,
     on-time, uniform, behaviour, reply), `SchoolStatusChip`, `SchoolReceiptTemplate`.
   - role folders: `principal/`, `accountant/`, `teacher/`, `librarian/`, each `Principal*`, `Accountant*`, …
   - gallery pages in `example/` in all 3 themes × light/dark, phone and desktop, LTR and Urdu RTL.
   - Directional icons through `GIcons` + `iconsRtl` (they mirror in Urdu).

**Work in `gmwf` (School only):**
- `school_dashboard.dart` wraps the module in
  `Theme(data: GTheme.forChoice(userChoice, darkModeOn: dark, brandOverride: GPalette.indigo800))`,
  so School respects the user's theme while showing indigo.
- Navigation moves to `AppShell` / `AppSidebar` (role decides items, not layout).
- Delete `pages/school/theme/school_theme.dart`. Bring the School folder's guard counts to zero:
  `SoftPalette.*`, `Color(0x…)`, ad-hoc `TextStyle(`, `Icons.*`.
- Screens use `context.comfort.*`, `GText.*`, `Gsp`/`Gr`, and `GText.urdu` for Urdu text, including the
  printed affidavit form.
- Note: School is the **first** GMWF screen set on `gmwf_ui`. This pulls School's part of redesign
  Wave 5 forward. Madrassa's part stays where it is.

---

## 4. Edge cases checklist (each gets a test)
- Joins on the 20th; leaves on the 10th; suspended for a week; rejoins next month.
- Month with 3 holidays + PTM moved twice; PTM on a holiday; PTM cancelled.
- Student on approved leave all month; absent all month (due = pro-rated base, nothing credited).
- Day never logged; two teachers log the same day on two offline PCs (per-field merge).
- Config changed mid-month → only open month affected; closed months unchanged.
- Class change mid-month (two class logs combine for the student).
- Payment before month close, then a log correction lowers the due → becomes credit.
- Two PCs taking installments for the same month offline → both kept (append-only).
- Receipt numbers generated offline on two PCs → no clash.
- Book total edited below copies out → blocked; unlisted book with loans out → still returnable.
- Same B-form entered twice; siblings with same father CNIC; madrassa → school transfer.
- Student marked "void" (entered by mistake) → excluded from rolls, fees, reports.
- Teacher tries another class / fee screen → denied by rules, not just hidden.

## 5. Phases
| Phase | Content | Depends on |
|---|---|---|
| 0 | Foundations 3.1 + P0 bug fixes (sync merge, grade id, library return sync, branch id, offline hangs) | — |
| 0b | `gmwf_ui`: indigo swatch, School kit skeleton + gallery; School shell on `AppShell` with indigo `brandOverride` | — |
| 1 | Library edit / unlist / borrower linking (built on the kit) | 0, 0b |
| 2 | Students: edit, status lifecycle, duplicates, admission no., siblings, academic year | 0, 0b |
| 3 | Daily log with six fee fields, holidays, PTM, edit window | 2 |
| 4 | Fee engine, monthly config, month close, payments, receipts, slips, reports | 3 |
| 5 | Roles hardening, promotion, grades/report card fixes, events; delete `school_theme.dart` | 2 |

Each phase:
- ships unit tests for the maths and merges, plus widget tests for its screens;
- gets a clean `flutter analyze` run in `gmwf`, and `flutter test` in `gmwf_ui`;
- includes a `git diff`/file check that nothing under `lib/pages/madrassa/` changed.

Every screen a phase rewrites moves to `gmwf_ui` in that same phase. There is no separate restyle pass.

### Progress
**2026-11-14: Phase 0 + 0b built**

What changed:
- New `lib/pages/school/core/`:
  - `SchoolBranchId`: one branch rule; reads tolerate aliases.
  - `SchoolIds`: collision-free ids.
  - `SchoolStore`: stamp → Hive merge → queue → return, so saves never wait on the network; plus audit with before/after.
  - `SchoolMerge`: LWW for every collection, never overwrites pending edits, merges day logs per student.
  - `SchoolMadrassaTransferReader`: read-only.
- School code no longer imports madrassa code. All 33 madrassa files are byte-identical (SHA-256 checked).
- P0 bugs fixed:
  - library return sync;
  - copies derived from loans;
  - return date ≥ issue date;
  - book total can't go below the copies out;
  - grade id kept and marks keyed per exam;
  - marks validated;
  - fee discount and status derived;
  - receipt id unique;
  - paid amount validated;
  - queued student upload keeps its own `lastModified`;
  - backfill covers books, loans, homerooms and audit;
  - teacher edit keeps homeroom fields;
  - homeroom move releases the old class.
- `gmwf_ui`: indigo swatch, School kit (`package:gmwf_ui/school.dart`), gallery page, 43 tests.
  Dark-mode brand overrides are now raised to 4.5:1 contrast globally (this affects every brand override).
- School runs inside `SchoolThemeScope` (user theme + indigo). Standalone navigation is now `AppShell`.
- Tests: `sandbox/school_phase0_test.dart`, 21 passing.

**2026-11-17: Phase 1 (library) built, plus the Urdu phonetic keyboard**

Library:
- New `lib/pages/school/library/`: models, pure `LibraryRules`, `SchoolLibraryService`, dialogs, and three tab views.
- `views/school_library_view.dart` was rebuilt as an inventory screen:
  - KPI strip (titles / copies / out / overdue / members);
  - Catalogue as a table or cover grid, with search, category and stock filters, sorting, and a book detail side panel;
  - Loans tab with filters and Return;
  - Members tab with profiles, access settings (block, custom limit, notes) and outsider members.
- Book covers use `MediaUploadTile`, compressed to a 360×520 JPEG.
- Unlist/relist replaces delete.
- Issue rules: stock, unlisted, blocked, inactive, limit, overdue block, same-book duplicate, due date within 90 days.
- Returns record a condition (good / damaged / lost). A lost copy lowers the total; when the last copy is lost, the book is unlisted.
- Optional late fines.
- Duplicate-book prompt offers "add copies to the existing book".
- Old free-text loans are linked to students or teachers by roll number / employee id or a unique name. Otherwise they show as "Unlinked" members.
- New collections `school_library_members` and `school_library_settings` live in the loans box under the `mem__` / `cfg__` key prefixes, and are included in pull and backfill.
- New `gmwf_ui` icons: bookIssue, bookReturn, memberAdd, block, shelf, image, library, overdue, unlist.

Urdu phonetic keyboard:
- `core/urdu_phonetic.dart` and `widgets/urdu_phonetic_scope.dart`: InPage/CRULP-style mapping (a→ا, Shift+s→ص, …).
- Switched with **Ctrl+Shift+K** (Ctrl+Shift+U was already taken) or a floating اردو/EN button. Long-press the button for the key map.
- Applies to every text field while School is open, including dialogs. Number, phone, email and password fields, paste and IME composition are left alone.
- The choice is remembered per device.

Tests:
- `sandbox/school_library_test.dart`: 16 tests.
- `sandbox/school_urdu_phonetic_test.dart`: 7 tests.
- With Phase 0's 21, all 44 School tests pass. `gmwf_ui`'s 130 tests pass.

Still open, moved to later phases:
- Linking an "Unlinked" legacy borrower to a member record.
- Right-aligning fields while Urdu mode is on (Urdu text currently flows RTL inside left-aligned fields).
- A barcode / per-copy accession register.
- Sequential receipt numbers come in Phase 4.
- Payments are still replaced, not accumulated (Phase 4).
- Grade attachments are still copied into every student's record (Phase 5).
- Role hardening (Phase 5).
- Screens inside the frame still use the old `SchoolTheme` colours until each one is rebuilt.

**Phase 2: students and enrollment (done 2026-11-17)**
- `students/student_rules.dart` (pure rules):
  - Status lifecycle with effective dates:
    - active → suspended / left / graduated / void;
    - suspended → active;
    - left → rejoin;
    - void → restore, and graduated → undo, are Principal only.
  - The old status "dropped" reads as "left".
  - `isActiveOn(day)` replays the history; Phase 4 will use it for fee proration.
  - Academic year runs April to March ("2026-27").
  - Admission numbers `GRT-0001`, issued per branch. Old typed numbers are ignored by the series.
    Only Principal / School Admin can edit one.
  - Roll numbers are unique per class-section-year and suggested automatically.
  - Duplicate checks: same B-Form; same name + father's CNIC; same name + father + DOB.
  - Siblings are found by father's CNIC, or by father's name + phone when there is no CNIC.
  - Field validation: phone 11 digits, CNIC and B-Form 13 digits, DOB not in the future and child at least 2 at admission.
- `students/school_student_service.dart`:
  - `save()`:
    - assigns the admission number and academic year on a new admission;
    - checks numbers only when they are new or changed, so old shared numbers can still be edited;
    - warns about duplicates, with an override;
    - keeps the madrassa link, status and history (the form cannot change status);
    - records a dated class/section move;
    - writes an audit entry.
  - `changeStatus()` appends to `statusHistory` and audits `STUDENT_STATUS`.
- **Admission form:**
  - auto admission number (locked unless Principal) and suggested roll number that follows the class;
  - gender, blood group and emergency contact;
  - the parent-verified tick now starts unticked and is kept on edit;
  - one save path with try/catch, field errors shown inline, and a "different child — save" duplicate dialog;
  - layout overflows fixed.
- **Student screen** rebuilt in the library style:
  - KPIs: active (girls / boys), new this month, suspended, left & graduated;
  - search across name, father, admission number, CNIC, B-Form and phone;
  - class, section and status filters; roster table, or cards on phones;
  - a profile panel (side panel or bottom sheet) with student and guardian facts, siblings, and status and class history;
  - actions: Edit, Change status, Admission slip, Documents;
  - a banner when an admission number is used twice (for example after two devices worked offline).
- **HQ branch picker** (`core/school_branches.dart`): HQ chooses among branches that have a school, and the choice is remembered on the device. Views reload per branch.
- Library members now link by admission number. The overview no longer counts void records.
- **Tests:** `sandbox/school_students_test.dart` has 17 tests. All 61 School tests pass, and `flutter analyze` shows 0 errors.
- Not done yet: year-end promotion (Phase 5) and the printable fee affidavit (Phase 4).

**Phase 3: daily log (done 2026-11-17)**
- `daily/daily_models.dart`:
  - `SchoolFeeRule`, the six rules;
  - `SchoolAttendance`: P / A / L approved / LR requested, and it still reads old "P", "late" and biometric values;
  - `SchoolDayEntry`: attendance, on time, uniform, behaviour + note, parent replied, punch time, class that day, updatedAt/By;
  - calendar settings (weekly days off, start time + grace, teacher edit days, allow leave), holidays and PTM.
- `daily/daily_rules.dart`:
  - credits: approved leave = present, leave requested = absent, absent earns only the reply, an unmarked day earns nothing and is not counted;
  - late is read from the biometric punch time unless set by hand;
  - working days skip weekly days off and holidays;
  - edit window: teachers today + N days (default 3) and only their class; Principal any day of an open month; nobody on future days, non-working days or closed months;
  - default PTM is the last working Saturday;
  - PTM credit: attended, joined after the PTM, or cancelled;
  - `summarize()` gives each student's month counts (the input for the Phase 4 fee engine);
  - `unrecordedDays()` lists working days with unmarked students.
- `daily/school_daily_service.dart`:
  - `saveDay()` writes only the changed students, keeps biometric fields, and audits;
  - holidays are added or removed with `active: false`, and refused on a day that already has marks;
  - PTM can be scheduled, moved (history kept), cancelled, or have who came recorded.
  - Stored in the existing day log (`school_attendance`), plus a new `school_calendar` collection (`cal__` keys in the logs box).
- **Screens:**
  - Day: a marking grid with P/A/L/LR and tick/cross columns;
  - Month: each student's counts per rule plus unmarked days;
  - Calendar: a colour-coded month, holidays, PTM and school-day settings.
- **Sync fix (sync_service, School part only):** the upload backfill skips keys that belong to another collection in a shared box. Before, library member, settings and calendar records could have been uploaded into the wrong collection.
- **Tests:** `sandbox/school_daily_test.dart` has 10 tests.

**ERP redesign (2026-11-17, user: "look like an ERP, not a mobile app")**
- Kit: `widgets/erp/school_erp.dart`:
  - `SchoolErpPage`: breadcrumbs, title + actions, underlined tabs with counts, stat strip, body;
  - `SchoolErpStatStrip`, `SchoolErpCard`, `SchoolErpToolbar`, `SchoolErpFilter`;
  - `SchoolErpTable` (sortable columns, sticky header, paging footer, selected row);
  - `SchoolErpDetailPanel`, `SchoolErpFacts` and `SchoolErpMasterDetail` (table + right-hand record panel; bottom sheet on narrow screens).
- The sidebar is grouped Overview / Academics / Staff / Finance / Library / Administration. Tab ids keep their old index, so deep links still work.
- Rebuilt on the kit: Dashboard (new `school_erp_dashboard_view.dart`, which replaces the Overview and Principal dashboard screens), Students, Daily log, Staff attendance, Teachers, Library and Audit log (now with area tabs and a before → after panel).
- Grades and Fees only got the ERP page header (`_legacyPage` in `school_dashboard.dart`). Their insides are rebuilt in Phase 5 and Phase 4.
- `school_overview_view.dart` and `school_principal_dashboard_view.dart` are no longer used. Delete them with `school_theme.dart` in Phase 5.
- Visual preview without login: `sandbox/school_preview_main.dart` (launch config "school-preview", port 8790) seeds demo data in the browser.
- **Tests:** all 71 School tests pass.

**2026-11-17 (later): Library rebuilt on the ERP kit, space pass, Phase 4 checked and tested**

- Library: Catalogue, Loans and Members are now `SchoolErpTable` grids (44 px rows, sortable, paged) with `SchoolErpDetailPanel` record panels. The cover grid stays as a second view.
- Space: `SchoolErpStatStrip` is one slim bar instead of big KPI cards, and the `SchoolErpPage` header is compact. Every School screen gets this.
- App sidebar: School sections sit straight under "School" (no second Overview, no "Taleem-wa-Tarbiyat School" level).
- Phase 4 (fees): the engine in `school/fees/` (per-month settings, pro-rated credits, month close with blockers, append-only payments and reversals, sequential receipts `GRT-R-2026-00001`, adjustments for closed months, concessions) and the Fees screen on the ERP kit were already written. This pass removed the double page header on Fees, fixed a stat-strip overflow, and added `sandbox/school_fees_test.dart` (12 tests).
- Tests: 83 School tests pass.

New requirements from the user (2026-11-17), planned as **Phase 6: consistency and theme**:
- One structured type scale and spacing across all School screens (no random big/small text). Old screens (grades, admission form, etc.) move to the same tokens.
- School follows the app theme the user picks (GMWF / Nexus / Twilight, light or dark). The default for school users is **Nexus**, changeable in Settings. This replaces the fixed Scholar Indigo `brandOverride`.

**2026-11-19: Phase 5 & Phase 6 completed**

Phase 5 (roles hardening, year-end promotion, grades/report card ERP rebuild, bimonthly events, cleanup):
- **Roles hardening:** `core/school_roles.dart` + tightened `SchoolAuthHelper` (strict role resolution, unknown role → no access, teacher identity matched by user id / email / employee id instead of partial names, homeroom lookup checks all configured sections A–D); tightened library and teacher management write checks (`sandbox/school_roles_test.dart`, 6 tests).
- **Dead files removed:** deleted legacy `school_theme.dart`, `school_overview_view.dart`, and `school_principal_dashboard_view.dart`, plus `_legacyPage` in `school_dashboard.dart`.
- **Year-end bulk promotion:** pure `students/promotion_rules.dart`, `SchoolStudentService.promoteBatch()`, and ERP `students/widgets/student_promotion_dialog.dart` (launched from Students header for Principal / School Admin). Supports per-student promote / hold back / graduate (final class `10th`) / skip, target academic year, destination section/stream, collision-free roll assignment, class/status history, and batch audit logging.
- **Bimonthly compulsory events (report-only, no fee effect):** `events/event_models.dart`, `events/school_event_service.dart` (`school_events` collection under `evt__` in logs box), and new **Events** tab in Daily log (`daily/views/daily_events_tab.dart`). Tracks Bazm-e-Adab, speech gala, training, and field trips; cancels instead of deleting; flags missed events on student report cards without affecting fees.
- **Grades & report cards ERP rebuild:** pure `grades/grade_rules.dart`, role-enforced `grades/school_grade_service.dart`, and real printable PDF `grades/grade_report_pdf.dart` (single student or whole class, with bimonthly event flags and dynamic branch name). Exam attachments are stored once in `school_grade_attachments` (`gatt__` in grades box) instead of copied onto every student's grade doc. Rebuilt `views/school_grading_view.dart` on the ERP kit with Marks entry (all sections A–D, Excel auto-fill, live % & grade, strict `marks <= total` validation) and Report cards tabs.
- **Sync backfill hardening (`sync_service.dart`, School section only):** guards shared boxes (`logsBox`, `gradesBox`, `feesBox`) so infixed collections never double-upload into plain collections, and adds `events` and `gradeAttachments` to backfill.

Phase 6 (consistency & theme):
- **App theme integration (`UserThemeService` + `SchoolThemeScope`):** removed fixed Scholar Indigo `brandOverride`. School now follows the user's selected `GThemeChoice` (GMWF / Nexus / Twilight, light or dark) in Settings, defaulting to **Nexus** for school roles (Principal, School Admin, Teacher, Librarian, School Accountant) while executives keep their own GMWF default.
- **Design-token & typography consistency:** migrated all remaining legacy School files (`school_enrollment_dialog.dart`, `school_homeroom_dialog.dart`, `school_teacher_dialog.dart`, `student_slip_dialogs.dart`, `school_about_view.dart`, `school_dashboard.dart` sign-out dialog, and `school_admission_pdf_service.dart`) onto `gmwf_ui` (`context.comfort`, `GText`, `GText.urdu`, `Gsp`, `Gr`, `GIcons`) and dynamic branch names. Guard counts in `lib/pages/school/` for `SoftPalette`, `context.adapt`, `design/design_system.dart`, and raw `Icons.*` are now **0**.
- **Preview & tests:** updated `sandbox/school_preview_main.dart` (added Grades & Reports, seeded grades & bimonthly event, added GMWF/Nexus/Twilight theme switcher defaulting to Nexus). Added `sandbox/school_phase5_6_test.dart` (10 tests covering promotion, events, grades/attachments/PDF, theme defaults/overrides, zero-legacy guard, and widget smoke tests). Madrassa folder verified byte-identical (33 files, unchanged SHA-256).

## 6. Decisions
| Question | Decision |
|---|---|
| Six rules | Attendance, on-time, message reply (= diary signed), behaviour, PTM, uniform — Rs 2,000 each |
| Credit mode | Pro-rated per qualifying day |
| Approved leave | Counts as present |
| Bimonthly events | Report only, no fee effect |
| Rs 12,000 | Monthly fee (assumed); one-time admission fee head exists, default 0 — confirm if different |
| Madrassa | Not touched; school code self-contained and renamed; madrassa only in comments |
| Look | Desktop ERP kit on `gmwf_ui`; follows user's app theme (GMWF / Nexus / Twilight, light/dark), defaulting to **Nexus** for school users (Phase 6, replaces fixed Scholar Indigo) |
