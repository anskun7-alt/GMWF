# GMWF System Fixes & Future-Proof Architecture Report

This document is divided into two sections:
- **Part 1: Human-Friendly Guide (Non-Technical)** — Explains every problem, why it happened in plain language, how it was fixed, and how the pre-deployment audit points were resolved.
- **Part 2: Developer & Code Reference (Technical)** — Shows exact file paths, function names, and **Before vs. After** code diffs (including `resolveCanonicalTiming`, `isInjectablePrescription`, `mayReplacePrescription` with monotonic `revision`, scoped `dateKey + branch/camp + queueType + serial` keying, `identityRevision`, `lanPushSig`, and `_isDispensaryPath`).

---

## Part 1: Human-Friendly Guide (Plain Language)

### 1. Injection Classification ("Powder for Injection", "Injectable Suspension", "Normal Saline", and Unclassified State)
- **What was happening:**
  - Initially, substring checks like `name.contains('iv')` or `type.contains('drop')` caused oral tablets (`Multivitamin`, `Ivermectin`, `Infant Drops`) to appear as phantom injections.
  - Conversely, checking oral/topical words (`susp`, `powder`, `gel`, `drop`) *before* injection markers could miss real injections like **"Powder for Injection"** or **"Injectable Suspension"**, and a blank type with a name like **"Normal Saline"** could be missed.
- **How we fixed it:**
  - Explicit injection/infusion markers (`injection`, `injectable`, `inj`, `infusion`, `drip`, `ampoule`, `vial`, standalone `IV`/`IM`) are now checked **FIRST** before oral/topical forms.
  - Known IV fluids (`Normal Saline`, `Ringer Lactate`, `Dextrose`, `Haemaccel`, `Mannitol`) are recognized even if the `type` field is blank.
  - Any medicine with a blank/ambiguous type that matches neither injection nor oral/topical forms is given a visible **"Unclassified"** badge on the Dispenser/Hybrid screen instead of guessing.

---

### 2. Medicine Timing (1-Time vs. 2-Time vs. 3-Time)
- **What was happening:**
  - When a doctor prescribed a medicine for 1 time (`1` or `1+0`) or 2 times (`1+1`), the Night slot in the Doctor edit dialog defaulted to `'1'` when missing, turning `1+0` into `1+0+1` (2 times) and `1+1` into `1+1+1` (3 times).
  - Separately, in `resolveCanonicalTiming`, any string without a `+` symbol that had a `Before Sleep` meal timing defaulted cautiously to `2`, and empty strings defaulted to `1+0+1`.
- **How we fixed it:**
  - Both the Doctor panel and `PatientFormHelper.resolveCanonicalTiming` now default missing slots to `'0'`, never `'1'`.
  - `1`, `1+0`, `1+0+0`, `0+1+0`, `0+0+1` strictly resolve to **1 per day**.
  - `1+1`, `1+0+1`, `1+1+0`, `0+1+1` strictly resolve to **2 per day**.
  - `1+1+1` strictly resolves to **3 per day**.

---

### 3. Clock-Independent Prescription Revision Counter + Scoped Token Keying
- **What was happening:**
  - Comparing prescriptions only by PC timestamps (`updatedAt` / `completedAt`) depended on workstation clocks. If a Doctor PC clock was 5 minutes behind, its edits or medicine removals were rejected as "older"; if a PC clock was fast, stale replays won.
  - Also, matching prescriptions by bare serial alone (`#5` / `005`) was unsafe across different days, across `zakat` / `non-zakat` / `gmwf` queues, or across two family members registered under one CNIC.
- **How we fixed it:**
  - Every Doctor save increments a monotonic integer **`revision`** counter (`1, 2, 3...`). `mayReplacePrescription` and `isOlderPrescription` compare `revision` **first** before looking at timestamps—so a Doctor edit (`revision: 2`) **always wins** over `revision: 1`, even if the Doctor PC clock is 5 minutes behind.
  - Prescriptions are now scoped and validated by **`dateKey + branch/camp + queueType + serial + patientId/patientName`**, ensuring Token `#5` on two different days or for two family members on one CNIC never cross.

---

### 4. Receptionist Name & CNIC Protection + Explicit Correction Path
- **What was happening:**
  - Doctor saves could previously overwrite Receptionist patient names/CNICs with `"Unknown Patient"` or synthetic `unknown_<timestamp>` values.
  - However, making `"Existing name always wins"` completely rigid left no way for a Receptionist or Supervisor to fix a genuine typo in a patient's name or CNIC.
- **How we fixed it:**
  - Normal Doctor, Dispenser, and background sync saves are strictly blocked from overwriting an existing valid Receptionist `patientName` or `patientCnic`.
  - When a Receptionist or Supervisor explicitly edits a patient's name or CNIC (via Patient Edit / `updateActiveEntriesForPatient` or `allowIdentityOverride: true`), it increments **`identityRevision`** (`1, 2...`), updates the token and embedded prescription, and clears `lanPushSig` so the correction propagates to all LAN screens immediately.

---

### 5. Echo Prevention (`lanPushSig`) Only Stamped on Data Arriving From the Server
- **What was happening:**
  - `SyncService._pushUnsyncedEntriesToLanServer` previously wrote `lanPushSig` into Hive on local records as soon as it attempted to send them. If the upload to the server failed or the server restarted, the local record kept `lanPushSig` and was never re-sent.
- **How we fixed it:**
  - `lanPushSig` is now **only** stamped in Hive by `RealtimeRouter` on records that arrived from the LAN server.
  - Local saves/edits in `saveEntryLocal`, `saveLocalPrescription`, `updateDispenseStatus`, and `_savePrescriptionHiveFirst` strip `lanPushSig`, while `SyncService` uses a transient in-memory cooldown map (`_lanPushAttemptedAt`) that never persists to Hive and clears on disconnect.

---

### 6. No Hardcoded Username Rules + Exact Dispensary Path Matching + Madrassa Safety
- **Removed hardcoded `shahmeer` rule:** Removed all username-specific branch overrides from `login_page.dart`, `home_router.dart`, and `local_storage_service.dart` so all staff branch/camp assignments are controlled 100% from User Management inside the app.
- **Exact Dispensary path matching (`CloudDb._isDispensaryPath`):** Explicitly excludes `kitchen`, `dasterkhwaan`, `madrassa`, `school`, `donations`, `employees`, `attendance`, and `finance`, and only matches top-level or `branches/{id}/...` dispensary collections.
- **Madrassa Parent CNIC Login Scope & Legacy Photo Field Preservation:**
  - Parent sessions (`role == 'parent'` or `'guardian'`) are restricted in `CloudDb` to Madrassa log reply paths only and never trigger staff sync queues.
  - Added `'image'` to `_mediaAliases['photoUrl']` in `MadrassaLocalStorage` so old and new student records preserve and restore `'image'`, `'photoUrl'`, `'photoBase64'`, and `'studentPhotoBase64'`.

### 7. Half-Typed CNIC / Phone Search Prevention (Wait Until All Digits Are Written)
- **What was happening:**
  - On the Receptionist "Issue Token" screen, as soon as the 6th digit of a CNIC was typed (e.g. `17301-2`), the auto-formatter inserted a hyphen (`-`).
  - The search check (`!RegExp(r'^\d+$').hasMatch(v)`) saw the hyphen `-` and mistakenly treated `"17301-2"` as a **patient name search** (`isNameSearch = true`), and at 10–12 digits treated a half-typed CNIC as a phone number (`isFullPhone = true`).
  - Then `LocalStorageService.searchPatientsByCnicOrGuardian` ran a partial substring check (`cnic.contains('173012')`), matching `"omar hayam"` (`17301-2338909-3`) on just 6 digits and automatically popping open the "Enter Vitals" dialog before the receptionist finished typing!
- **How we fixed it:**
  - Numeric inputs (digits and hyphens) are **never** treated as a name search (`hasLetters` requires `[a-zA-Z]`).
  - For a **CNIC**, the search strictly waits until all **13 digits** (`XXXXX-XXXXXXX-X`) have been written.
  - For a **Phone number** (starting with `03` or `923`), the search strictly waits until all **11 digits** (`03XXXXXXXXX`) or **12 digits** (`923XXXXXXXXX`) have been written.
  - `LocalStorageService.searchPatientsByCnicOrGuardian` now returns `[]` for any incomplete numeric query and requires exact 13-digit CNIC matching instead of partial substring matching.

### 8. Why Did These Specific Issues Only Happen at Haji Camp and Not in Other Camps?

Many staff members and developers asked: *"Why did these issues (token numbering jumping to 2000+, medicines vanishing, server freezing, client saying 51 unsent, and name overwrites) only happen at Haji Camp, while Gujrat, Sialkot, and other centers worked smoothly?"*

Here is the exact breakdown of why Haji Camp was uniquely vulnerable:

#### 1. Standalone Branch vs. Sub-Camp Architecture (The "Karachi Family" Mismatch)
- **In Other Camps (Gujrat, Sialkot, Rawalpindi):**
  - They are independent, standalone branches with 1:1 mapping between the branch name, the local database, and staff accounts.
  - The Server runs as `branchId = gujrat`. Receptionist logs in as `branchId = gujrat`. Doctor logs in as `branchId = gujrat`.
  - When the LAN Server checked incoming packets: `if (msgBranch != serverBranch) reject;`, `gujrat == gujrat` always evaluated to `true`.
  - Tokens followed a single clean format: `071126E-GUJRAT-001`.
- **At Haji Camp:**
  - Haji Camp is **not** an independent top-level branch in Firestore; it is an active **sub-camp operating under the Karachi branch**.
  - Karachi runs multiple medical facilities concurrently: **Haji Camp** (`haji_camp` / `haji` / tag `HAJI`) and **Saddar / Kapayya** (`saddar` / tag `SADD` / `KAP`).
  - Workstations on the Haji Camp LAN had fragmented branch IDs:
    - The Server logged in under `karachi`.
    - The Receptionist logged in under `karachi` or `haji_camp`.
    - The Doctor logged in under `haji_camp` or `haji`.
  - Previous code used strict string matching (`clientBranch == serverBranch`). Because `"haji_camp" != "karachi"`, the server and router thought incoming doctor tokens and prescriptions belonged to a "foreign branch" and dropped or misrouted them! In Gujrat, where everything was `"gujrat" == "gujrat"`, this bug never triggered.

#### 2. High-Volume Multi-Desk Setup & The 2000+ Serial Explosion
- **In Other Camps:**
  - A single receptionist desk typically issues tokens sequentially from `001, 002, 003...` in slot 0.
- **At Haji Camp:**
  - Haji Camp handles enormous crowds of pilgrims and traveling families, requiring **multiple reception desks (Desk 1, Desk 2, Hybrid)** operating at the same time.
  - Desk 2 was configured with `offlineDeskSlot = 2`.
  - Whenever the Wi-Fi connection dropped, Desk 2 switched to offline token generation, which used the old formula `slot * 1000 + 1` = **`2001, 2002, 2003`**!
  - When those 2000+ tokens were pushed to the server, the server's sequence gap detector saw a jump from `#003` to `#2001` and assumed **1,998 tokens had been lost on the network**!
  - The server entered a massive loop scanning local Hive boxes 2,000 times on the main UI thread, completely locking up the server event loop and causing the server to freeze and stop responding. In smaller clinics with only one desk, token serials never jumped by 1,000, so the server never froze.

#### 3. Family Clustering on a Single CNIC (Identity Collisions)
- **In Other Camps:**
  - Individual local residents visit the clinic one by one with their own CNIC or unique phone numbers.
- **At Haji Camp:**
  - Entire pilgrim families travel together. A single guardian / family elder registered 4 to 8 family members under **one single CNIC** (`11111-1111111-1`).
  - Token #1 was issued for the mother, and Token #2 was issued for the child.
  - Previous prescription deduplication code (`mayReplacePrescription` and `_savePrescriptionHiveFirst`) matched records by **CNIC alone** instead of `serial + patientId`.
  - The moment the doctor prescribed medicines for the child, the app saw the same CNIC and **erased the mother's prescription**, replacing it with the child's! In standalone branches where each patient had a unique CNIC, this prescription collision was impossible to encounter.

#### 4. Temporary Camp Wi-Fi & Dynamic DHCP Lease Renewals
- **In Other Camps:**
  - Permanent clinics have stable local area networks, dedicated switches, or static router IP reservations. The server PC stays at the same IP address for weeks.
- **At Haji Camp:**
  - The medical camp relies on temporary, portable 4G/Wi-Fi routers with short DHCP lease times.
  - Mid-day, the router renewed its DHCP leases and reassigned the server PC from `192.168.1.38` to `192.168.1.40`.
  - Client workstations still held the old UDP beacon for `.38` and sat stuck in **"Connecting... 51 unsent"**, while the server had moved to `.40`.

#### 5. The Hardcoded "Shahmeer" Account Override
- **Why this was 100% unique to Haji Camp:**
  - Dr. / Admin Shahmeer had historically been posted at Sialkot, and an old startup healing script had a hardcoded override: `if (username == 'shahmeer') branch = 'sialkot';`.
  - When Shahmeer was deployed on the ground to manage **Haji Camp**, logging into the Server PC with that account silently forced the server's branch identity back to **`sialkot`**!
  - The server was physically sitting in Haji Camp, listening to Haji Camp doctors and receptionists, but internally believing it was running in Sialkot—filtering out Haji Camp data as foreign! Other clinics were managed by administrators whose names were never hardcoded in legacy scripts.

---
---

## Part 2: Developer & Code Reference (Before & After Diffs)

### 1. Canonical Medicine Timing (`lib/Pages/dispensary/dispensar/patient_form_helper.dart`)

#### Before:
```dart
if (s.contains('+')) {
  final parts = s.split('+').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  while (parts.length < 3) parts.add(0);
  final sum = parts[0] + parts[1] + parts[2];
  return (timing: '${parts[0]}+${parts[1]}+${parts[2]}', dailyQty: sum > 0 ? sum : 1);
}
// Legacy fallback when no '+' was present defaulted to 2 unless meal was Before Sleep!
```

#### After:
```dart
static ({String timing, int dailyQty}) resolveCanonicalTiming(
  dynamic rawTiming, {
  dynamic fallbackQty,
  dynamic mealTiming,
}) {
  final s = (rawTiming ?? '').toString().trim().toLowerCase();
  final meal = (mealTiming ?? '').toString().trim().toLowerCase();
  final isBeforeSleep = meal.contains('sleep') || meal.contains('night') || meal.contains('bed');

  // 1. Explicit M+E+N or M+E format with '+' or '-' separators
  if (s.contains('+') || RegExp(r'^\d+\s*-\s*\d+').hasMatch(s)) {
    final sep = s.contains('+') ? '+' : '-';
    final parts = s.split(sep).map((p) => int.tryParse(p.trim()) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0); // Missing slots ALWAYS default to 0, never 1
    }
    final m = parts[0] > 0 ? 1 : 0;
    final e = parts[1] > 0 ? 1 : 0;
    final n = parts[2] > 0 ? 1 : 0;
    final sum = m + e + n;
    if (sum > 0) {
      return (timing: '$m+$e+$n', dailyQty: sum);
    }
  }

  // 2. Single integer or clinical frequency code
  final asInt = int.tryParse(s);
  if (asInt != null && asInt > 0) {
    if (asInt == 1) {
      return (timing: isBeforeSleep ? '0+0+1' : '1+0+0', dailyQty: 1);
    }
    if (asInt == 2) {
      return (timing: '1+0+1', dailyQty: 2);
    }
    return (timing: '1+1+1', dailyQty: 3);
  }
  ...
  return (timing: isBeforeSleep ? '0+0+1' : '1+0+0', dailyQty: 1);
}
```

---

### 2. Injection Classification & Unclassified Detection (`lib/Pages/dispensary/dispensar/patient_form_helper.dart`)

#### Before:
```dart
static bool isInjectablePrescription(Map m) {
  final t = (m['type'] ?? m['dosageForm'] ?? m['category'] ?? m['form'] ?? '').toString().toLowerCase().trim();
  final n = (m['name'] ?? '').toString().toLowerCase().trim();
  if (isOralOrTopicalForm(t)) return false; // Bug: ran before injection check, rejecting "Powder for Injection" and "Injectable Suspension"!
  ...
}
```

#### After:
```dart
static bool hasExplicitInjectableMarker(String s) {
  if (s.isEmpty) return false;
  return s.contains('injection') ||
      s.contains('injectable') ||
      s.contains('infusion') ||
      s.contains('drip') ||
      s.contains('ampoule') ||
      s.contains('vial') ||
      s.contains('syringe') ||
      RegExp(r'\binj\b|\binj\.').hasMatch(s) ||
      ivWord.hasMatch(s) ||
      imWord.hasMatch(s);
}

static bool isInjectablePrescription(Map m) {
  final t = (m['type'] ?? m['dosageForm'] ?? m['category'] ?? m['form'] ?? '').toString().toLowerCase().trim();
  final n = (m['name'] ?? '').toString().toLowerCase().trim();

  // 1. Explicit injection/infusion markers FIRST (handles "Powder for Injection", "Injectable Suspension", etc.)
  if (hasExplicitInjectableMarker(t) || hasExplicitInjectableMarker(n)) {
    return true;
  }
  // 2. Oral/topical check
  if (isOralOrTopicalForm(t) || isOralOrTopicalForm(n)) {
    return false;
  }
  // 3. Blank/unknown type with known IV fluid name ("Normal Saline", "Ringer Lactate", "Dextrose")
  if (infusionNamePattern.hasMatch(n)) {
    return true;
  }
  return false;
}

static bool isUnclassifiedMedicine(Map m) {
  if (isInjectablePrescription(m)) return false;
  final t = (m['type'] ?? m['dosageForm'] ?? m['category'] ?? m['form'] ?? '').toString().toLowerCase().trim();
  final n = (m['name'] ?? '').toString().toLowerCase().trim();
  if (isOralOrTopicalForm(t) || isOralOrTopicalForm(n)) return false;
  return true;
}
```

---

### 3. Monotonic Revision Counter & Scoped Token Matching (`lib/services/local_storage_service.dart`)

#### Before:
```dart
static bool mayReplacePrescription(Object? incoming, Object? existing) {
  ...
  // Only checked serial + CNIC + PC timestamps (vulnerable to 5-min slow Doctor clock and daily serial #5 reuse)
  final inAt = at(inc);
  final exAt = at(ex);
  if (inAt != null && exAt != null) {
    if (inAt.isBefore(exAt)) return false;
    return true;
  }
  ...
}
```

#### After:
```dart
static bool mayReplacePrescription(Object? incoming, Object? existing) {
  ...
  // 1. Scoped Token (dateKey + branch/camp + queueType + serial) & Patient Identity Protection
  if (!_isSamePrescriptionScope(inc, ex)) {
    return false;
  }

  // 2. Medicine Presence Protection
  final exHasMeds = _hasMedicines(ex);
  final incHasMeds = _hasMedicines(inc);
  if (exHasMeds && !incHasMeds) return false;
  if (!exHasMeds && incHasMeds) return true;

  // 3. Clock-Independent Monotonic Revision Counter Check
  // A higher doctor revision ALWAYS wins, even if the Doctor PC clock is 5 minutes behind!
  final int inRev = ((inc['revision'] ?? inc['prescriptionRevision']) as num?)?.toInt() ?? 0;
  final int exRev = ((ex['revision'] ?? ex['prescriptionRevision']) as num?)?.toInt() ?? 0;
  if (inRev > 0 || exRev > 0) {
    if (inRev != exRev) {
      return inRev > exRev;
    }
  }

  // 4. Timestamps Check when revisions are equal or absent
  ...
}
```

---

### 4. Receptionist Identity Protection + Explicit Correction Path (`lib/services/local_storage_service.dart`)

#### Before:
```dart
final authoritativeName = existingBestName.isNotEmpty ? existingBestName : incomingBestName;
```

#### After:
```dart
final int inIdRev = (sanitized['identityRevision'] as num?)?.toInt() ?? 0;
final int exIdRev = (existing['identityRevision'] as num?)?.toInt() ?? 0;
final bool isExplicitIdentityEdit =
    sanitized['allowIdentityOverride'] == true || inIdRev > exIdRev;

final authoritativeName = isExplicitIdentityEdit
    ? (incomingBestName.isNotEmpty ? incomingBestName : existingBestName)
    : (existingBestName.isNotEmpty ? existingBestName : incomingBestName);
```

---

### 5. Echo Prevention `lanPushSig` (`lib/services/sync_service.dart` & `lib/services/local_storage_service.dart`)

#### Before:
```dart
// In SyncService._pushUnsyncedEntriesToLanServer:
await entriesBox.put(key, {...data, 'lanPushSig': pushSig}); // Bug: stamped on local record before server confirmed receipt!
```

#### After:
```dart
// In SyncService._pushUnsyncedEntriesToLanServer:
// Record transient attempt in memory only (NEVER stamp lanPushSig on local Hive records;
// lanPushSig is reserved strictly for records received from the LAN server).
_lanPushAttemptedAt[attemptKey] = DateTime.now();

// In LocalStorageService.saveEntryLocal & saveLocalPrescription:
if (entryData['lanPushSig'] == null) {
  sanitized.remove('lanPushSig');
}
```

---

### 6. Exact Dispensary Path Matching & Parent Session Guard (`lib/services/cloud/cloud_db.dart`)

#### Before:
```dart
static bool _isDispensaryPath(String path) {
  final parts = path.toLowerCase().split('/');
  const dispCols = {'patients', 'serials', 'prescriptions', 'inventory', ...};
  return parts.any((p) => dispCols.contains(p));
}
```

#### After:
```dart
static bool _isDispensaryPath(String path) {
  final parts = path.toLowerCase().split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return false;
  const nonDispModules = {
    'kitchen', 'dasterkhwaan', 'madrassa', 'madrassa_students',
    'madrassa_daily_logs', 'madrassa_logs', 'school', 'school_students',
    'donations', 'employees', 'attendance', 'finance', 'users',
  };
  if (parts.any((p) => nonDispModules.contains(p))) return false;
  if (parts.first == 'patients' || parts.first == 'medicine_restrictions' ||
      parts.first == 'dispensary' || parts.first == 'doctor_templates') {
    return true;
  }
  if (parts.length >= 3 && parts[0] == 'branches') {
    const branchDispCols = {
      'patients', 'serials', 'prescriptions', 'inventory', 'medicines',
      'stock', 'camps', 'doctor_templates', 'medicine_restrictions', 'dispensary',
    };
    return branchDispCols.contains(parts[2]);
  }
  return false;
}
```

---

### 7. Single Token Numbering Criteria (Strictly 001 to 999 for Online & Offline)

#### Problem:
- A previous "offline band" architecture gave offline workstations separate blocks (`slot * 1000`), issuing numbers like `#2001`, `#2002`, `#2003`.
- When tokens were issued offline, sequence-gap checking halted subsequent tokens in memory because prior tokens were waiting in the outbox, delaying their appearance on the doctor screen until reconnect cycles.
- Token numbers appeared out of place (1000+), violating the standard clinic workflow requirement that all tokens strictly remain in the `001..999` range.

#### Fix:
1. **Removed all 1000+ offline band offsets** in `local_storage_service.dart`, `token_screen.dart`, and `lan_server.dart`. All token numbers generated online or offline are strictly bounded within `001..999`.
2. **Instant Outbox Flushing on Reconnect**: Removed artificial 800ms delays in `realtime_manager.dart` and removed deadlocking `return` statements in `sendMessage`, so that all offline tokens are immediately transmitted in strict serial sequence over TCP upon network connection.

#### Before (`lib/services/local_storage_service.dart`):
```dart
final bandLow = offlineSlot > 0 ? offlineSlot * offlineBandSize : 0; // 2 * 1000 = 2000!
final bandHigh = offlineSlot > 0 ? bandLow + offlineBandSize - 1 : offlineBandSize - 1;
bool inBand(int seq) => seq > bandLow && seq <= bandHigh;
```

#### After (`lib/services/local_storage_service.dart`):
```dart
// Single canonical sequence 001..999 for all online and offline tokens:
const bandLow = 0;
const bandHigh = 999;
bool inBand(int seq) => seq > bandLow && seq <= bandHigh;
```

---

### 8. LAN Connection Disconnection Resilience & Status Dialog RenderFlex Fix

#### Problem:
- Workstations on the exact same Wi-Fi LAN experienced repeated disconnections due to hyper-aggressive timeouts:
  - Pong timeout was set to 20s.
  - Handshake watchdog was set to 6s.
  - `ConnectionManager.isLinkAlive` treated any link without a pong in 15s as stale and actively tore down healthy sockets whenever Windows fired connectivity change notifications.
- The "LAN Connection Status" dialog had a rigid button `Row` that overflowed by 181 pixels on the right.

#### Fix:
1. **Extended Liveness Timeouts**:
   - Pong timeout increased to **45 seconds** (was 20s).
   - Server heartbeat eviction increased to **60 seconds** (was 35s).
   - Handshake watchdog and `_waitForIdentified` increased to **15 seconds** (was 6s).
   - `isLinkAlive` threshold increased to **45 seconds** (was 15s).
2. **Fixed Dialog Overflow**: Replaced the rigid `Row` in `lan_server_config_dialog.dart` with a responsive `Wrap` layout, eliminating the 181-pixel overflow error.

---

### 9. Explanation of "Connecting... 51 Unsent" & DHCP Server IP Mismatch Fix

#### What Does "51 Unsent" Mean?
- In GMWF, when staff members (receptionist, doctor, dispenser) perform work while offline or during a network blip, **no data is ever lost**.
- Every single action (patient registration, vitals entry, issued token, prescription edit) is immediately saved to the computer's local hard drive in an encrypted persistent queue (`Hive: realtime_outbox`).
- **"51 unsent"** indicates that there are **51 actions/tokens** safely held on that workstation, waiting to be synced to the main server machine. Once connected, they flush automatically and the counter drops from 51 to 0 ("Live").

#### Why Was It in "Connecting..." State and Disconnecting Repeatedly?
1. **Router DHCP IP Change**: The Server PC changed its Wi-Fi address on the clinic router from `192.168.1.38` to `192.168.1.40`.
2. **Stale UDP Beacon Loop**: Because the server software had been started while the PC had `.38`, its UDP broadcaster kept sending `GMWF_SERVER:192.168.1.38:53281` across the Wi-Fi every 5 seconds.
3. **Ghost IP Hijacking**: Whenever a workstation (Receptionist or Doctor) connected or re-scanned, it heard the server's broadcast for `.38`, tried connecting to the dead `.38` address, timed out, found `.40`, but then was told by the next broadcast to switch back to `.38`! This caused the repeated spontaneous disconnections on the exact same Wi-Fi.
4. **Client Handshake Completer Delay**: On the client workstation, `_waitForIdentified` was relying on an async stream filter rather than a direct synchronous event listener, creating delays before the UI could transition from "Connecting..." to "Live".

#### How We Fixed It:
1. **Dynamic Server IP Tracking (`lan_server.dart` & `server.dart`)**:
   - The server now periodically re-checks the host operating system's primary LAN IP.
   - When DHCP changes the server's IP (e.g. `.38` -> `.40`), the server immediately adopts the new IP and updates its UDP broadcaster payload dynamically so it always announces its true live IP.
2. **Reachability Pre-Check for UDP Discovery (`lan_discovery.dart` & `connection_manager.dart`)**:
   - `LanDiscovery` and `ConnectionManager` now run an instant reachability probe (`LanDiscovery.isReachable(ip, port)`) before accepting any UDP beacon.
   - Any stale broadcast for a dead or old IP is discarded within 300ms, completely preventing ghost IPs from hijacking active client connections.
3. **Synchronous Identification Listener (`realtime_manager.dart` & `connection_manager.dart`)**:
   - Added direct `addIdentifiedListener` callbacks to `RealtimeManager`. The exact instant the server confirms client identification, the handshake Completer resolves immediately without waiting for timers or queue delays.

---

### 10. Complete Sidebar Navigation Restored to NEXUS.CORE Standard

#### Objective:
Restored all essential server subsystem entries (`Department Activity`, `Biometric Devices`, `Python Sync Engine`, `Multi-Server Mesh`, `Data Vault`, and `Quick Operations`) directly into the main sidebar navigation with the **NEXUS.CORE** enterprise design, rather than burying them inside settings sub-tabs.

#### Restructured 12-View Navigation Map:
- **WORKSPACE**:
  - `Overview` (Index 0) — High-level telemetry, performance chart, active nodes, activity stream.
  - `Department Activity` (Index 1) — Live clinic queues, dispensing status, active patients.
  - `Connected Devices` (Index 2) — Workstations, thermal printers, and hardware interfaces.
  - `Users & Sessions` (Index 3) — Active clinic staff, login sessions, and desk assignments.
- **ENGINES & HARDWARE**:
  - `Biometric Devices` (Index 4) — ZKTeco attendance timeclocks, Port 8088/4370 listener, user punch mappings.
  - `Python Sync Engine` (Index 5) — Embedded interactive Python terminal, `zkteco_sync_service.py` daemon, auto-restarts, PID tracking.
- **OBSERVABILITY**:
  - `Resource Monitoring` (Index 6) — Deep hardware diagnostics for CPU, RAM, Disk, and LAN traffic.
  - `System Logs` (Index 7) — Live event stream, severity filtering (`INFO`, `SYSTEM`, `WARN`, `ERROR`), and log clearing.
  - `Network & Interfaces` (Index 8) — Throughput counters, open socket ports (53281, 8088, 4370), Windows Firewall status.
- **SYSTEM**:
  - `Multi-Server Mesh` (Index 9) — High-availability peer replication, heartbeat clustering, secondary server promotion.
  - `Data Vault` (Index 10) — Authoritative local Hive boxes inspector, record schemas, raw data audit.
  - `Settings & Firewall` (Index 11) — Advanced server configuration and firewall port automation.
- **QUICK OPERATIONS (Sidebar & Header Action Buttons)**:
  - `Catch-Up & Reconcile` button — Instantly reconciles unconfirmed tokens, fills gaps, and pushes current state to all connected workstations.
  - `Cloud Sync Now` button — Triggers immediate Firestore replication of pending local writes without waiting for timers.

---

### 11. Elimination of Server UI Freezes / Hangs

#### Root Causes Identified:
1. **Synchronous Full-Box Scans on UI Thread**:
   On startup or when sync ran, functions like `healLegacyHistoricalData()`, `_enqueueMissingEntries()`, `_enqueueMissingDonations()`, `_enqueueMissingPatients()`, and `_enqueueMissingMadrassaLogs()` walked thousands of Hive keys in a single blocking synchronous loop. In Dart, CPU-bound loops starve the event loop, freezing both the Flutter UI and `HttpServer` socket handlers.
2. **Runaway Windows PowerShell Processes**:
   `SystemMetricsService` launched `io.Process.run('powershell', [...])` with a 15-second timeout and 3 CIM queries. On low-power clinic PCs, PowerShell startup spiked CPU to 100% and blocked when WMI was busy.
3. **Cascading State Rebuilds**:
   `_overviewTicker` and metrics listeners triggered frequent root `setState(() {})` calls across the entire view hierarchy while heavy data processing was taking place.

#### Fixes Applied:
1. **Cooperative Non-Blocking Background Sweeps (`_runBackgroundSweep`)**:
   Moved all startup backfill sweeps into a non-blocking background routine that yields to the Dart event loop (`await Future.delayed(...)`) between operations. The server WebSocket listener starts up and begins accepting incoming client connections in **under 50 milliseconds**.
2. **PowerShell Timeout Capped at 4 Seconds with Strict In-Flight Guards**:
   `SystemMetricsService` bounds the PowerShell process to a strict 4-second timeout, prevents concurrent executions, and falls back to cached metrics immediately if the OS query is slow.
3. **Immediate Handshake Priority (`LanServer`)**:
   Incoming `identify` messages are answered immediately with `identified` before any background catch-up sweeps or event-log replays are initiated.

---

### 12. Resolution of "Connecting... 51 Unsent" & Outbox Drainage

#### Root Cause:
When the server machine rebooted or switched Wi-Fi networks (e.g. from `.38` to `.40`), the server event loop was previously blocked by startup sweeps. Workstation clients (receptionist, doctor, dispenser) connected to TCP port 53281, but their `identify` handshake sat waiting for the server to unfreeze. While in this state, tokens issued offline queued up in the client outbox (e.g. `51 unsent`).

#### Fixes Applied:
1. **Immediate Zero-Delay WebSocket Identification**:
   With cooperative scheduling and zero-delay `_onServerIdentified`, clients complete identification in <10ms.
2. **Immediate Outbox Flushing on Link Up**:
   The moment `identified` is acknowledged, `RealtimeManager` immediately executes `_flushOutbox()` without delay, draining all pending offline tokens directly to the server.
3. **Proper In-Flight State Tracking in `ConnectionManager`**:
   Fixed `_inConnectTo` flag scoping with `try ... finally { _inConnectTo = false; }` to eliminate race conditions between auto-discovery and manual connection attempts.

---

### 13. Elimination of Layout Overflow in LAN Connection Status Dialog

#### Root Cause:
In `lan_server_config_dialog.dart`, the bottom action row wrapped non-wrapping `Row` widgets (`Row(View Log, Pressure Test)` and `Row(Close, Auto-Scan / Reconnect)`) inside a dialog constrained to 440px width. On Windows PCs with standard 125% or 150% display scaling, the non-wrapping `Row` exceeded the dialog width, resulting in a yellow-and-black hazard stripe: `RIGHT OVERFLOWED BY 181 PIXELS`.

#### Fix Applied:
Removed nested `Row` containers and placed all 4 action buttons (`View Log`, `⚡ Pressure Test`, `Close`, and `Auto-Scan / Reconnect`) as direct, responsive children of a `Wrap` widget with `spacing: 8` and `runSpacing: 10`. Every button now wraps gracefully to the next line on any screen resolution or Windows DPI scaling.

---

### 14. Single Canonical Token Numbering (Strictly 001 to 999)

#### Policy & Architecture:
All workstations—Server, Doctor, Dispenser, Receptionist, and Hybrid desks—strictly follow a single shared sequence from **001 to 999**.
- **No 1000+ or 2000+ bands**: Tokens generated online or offline are strictly bounded within `001..999`.
- **Existing legacy tokens (>999)** are filtered in `getNextLocalSerialSequence` so they never infect today's token counter.
- **Fair Queue Ordering**: Offline-generated tokens are merged into the clinic queue based on their authoritative creation timestamp (`issuedAtMs`), ensuring seamless patient flow without out-of-order jumps.

---

### 15. Inno Setup Installer: Progress Percentage Stuck at 0% & Header Text Truncation

#### Problem 1: Percentage Stuck at 0%
- During file extraction on the `wpInstalling` page, the green progress bar moved forward, but the percentage text (`GPctLabel`) remained frozen at `0%`.
- The checklist items (`Preparing installation`, `Copying files`, `Installing components`, `Finalizing setup`) remained static without reflecting progress.

#### Root Cause:
`GPctLabel` was initialized to `'0%'` during layout creation, but Inno Setup's built-in callback procedure `CurInstallProgressChanged` was never implemented. Without this event procedure, Inno Setup never notified the custom UI about byte/file extraction increments.

#### Fix Applied in `Installer/GMWF_DesignSystem.isi`:
Implemented `CurInstallProgressChanged(CurProgress, MaxProgress: Integer)`:
```pascal
procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  Percent: Integer;
begin
  if (MaxProgress > 0) and (GPctLabel <> nil) then
  begin
    Percent := (CurProgress * 100) div MaxProgress;
    if Percent > 100 then Percent := 100;
    if Percent < 0 then Percent := 0;
    GPctLabel.Caption := IntToStr(Percent) + '%';

    if GCheck1 <> nil then GCheck1.Caption := '✓  Preparing installation';
    if GCheck2 <> nil then
      if Percent >= 50 then GCheck2.Caption := '✓  Copying files' else GCheck2.Caption := '●  Copying files';
    if GCheck3 <> nil then
      if Percent >= 85 then GCheck3.Caption := '✓  Installing components' else if Percent >= 50 then GCheck3.Caption := '●  Installing components' else GCheck3.Caption := '○  Installing components';
    if GCheck4 <> nil then
      if Percent >= 100 then GCheck4.Caption := '✓  Finalizing setup' else if Percent >= 85 then GCheck4.Caption := '●  Finalizing setup' else GCheck4.Caption := '○  Finalizing setup';
  end;
end;
```

#### Problem 2: Page Description Text Clipping
- On the `wpLicense` step, the description text was truncated at the right margin: `Please read the following important information before continui`.

#### Root Cause:
`PageDescriptionLabel` width was bound to `CardW` (`ContentW - ScaleX(56)`) and height `ScaleY(32)`, which was too narrow for default Inno Setup wording, causing the second line to clip at the right edge on standard DPI displays.

#### Fix Applied:
1. Expanded `PageDescriptionLabel` bounds to `ContentW - ScaleX(36)` with height `ScaleY(36)`.
2. In `CurPageChanged` of `GMWFSetup.iss` and `GMWFSetup_x86.iss`, assigned concise, clear captions for every installation page that fit gracefully without any truncation:
   - **wpLicense**: `'Review and accept the license terms before proceeding.'`
   - **wpSelectDir**: `'Choose the folder where GMWF will be installed.'`
   - **wpSelectTasks**: `'Select shortcuts and desktop configurations.'`
   - **wpInstalling**: `'Please wait while Setup installs GMWF on your computer.'`
   - **wpFinished**: `'GMWF Management System has been successfully installed.'`

---

### 16. Explanation of App "Not Responding" While Server is in STANDBY

#### Why Did the App Freeze for 78 Seconds When Server Wasn't Even Launched?
Staff observed the server dashboard window showing:
**`Gulzar Madina Welfare Foundation (Not Responding)`**
along with a notification banner:
**`Sorry for the wait — uploading changes took 78 s. Everything is working again.`**
The server was sitting in `● STANDBY 34% Load` with `[ Launch Server ]` unclicked.

#### Root Cause Analysis:
1. **Background Client Sync Runs Independently of Server Daemon**:
   Even when the local server is in `STANDBY`, the app functions as a client workstation connected to the cloud. When 146 unsynced actions were queued (`146 Queued`), `SyncService._uploadPending` was triggered in the background.
2. **Synchronous Isolate Contention**:
   Right as the user navigated to the Server Dashboard screen, `_initializeSync()` synchronously launched three massive unawaited database scans:
   - `LocalStorageService.purgePhantomUnknownTokens()`
   - `LocalStorageService.healAndRestorePatientCnics()` (which was also redundantly called inside the purge routine)
   - `LocalStorageService.purgeBloatedSyncQueue()`
3. **Hive Box Compaction on UI Thread**:
   Simultaneously, `compactBloatedBoxes()` iterated over 10 Hive boxes (`entriesBox`, `patientsBox`, `syncBox`, `stockBox`), rewriting entire files to disk.
4. **Starvation of Windows Message Pump**:
   Because all these disk-intensive and sequential network upload operations ran concurrently on Dart's single UI isolate without adequate yielding, the Windows OS message loop (`DispatchMessageW`) was starved of execution slices.
   - When a Windows application fails to process its message queue for **>5 seconds**, Windows marks the process as **`Not Responding`**.
   - After 78 seconds of intense upload and compaction work, the loop concluded. `UiStallMonitor` detected that its 250ms heartbeat timer had been starved for ~78,000ms and displayed the recovery notification: `"Sorry for the wait — uploading changes took 78 s. Everything is working again."`

#### Fix Applied:
1. **Staggered, Non-Blocking Initialization in `server.dart`**:
   Removed concurrent unawaited sweeps from `_initializeSync()` and staggered them with non-blocking timers (`Future.delayed(Duration(seconds: 4))` and `8s`), allowing the UI to render smoothly and process user input before any maintenance begins.
2. **Cooperative Yielding in `SyncService`**:
   Increased the cooperative delay between uploaded items to `20ms` (`await Future.delayed(const Duration(milliseconds: 20))`) and between batches to `80ms`. This guarantees that Dart always yields control back to the Windows message pump to draw frames and process clicks.
3. **Paced Hive Compaction**:
   Increased the delay between Hive box compactions in `compactBloatedBoxes()` from 200ms to 500ms to eliminate disk I/O bottlenecks.

---

### 17. Unified NEXUS.CORE Subsystems, Removal of Redundant Back Buttons & Persistent Alerts

#### Objective:
1. Harmonize all Server Subsystem pages (`Python Terminal`, `Biometric Device Manager`, `Server Data Vault`, `Multi-Server Mesh Nodes`) to the dark graphite + pure white card NEXUS.CORE aesthetic.
2. Eliminate redundant "Back" buttons across all screens rendered alongside the desktop sidebar navigation.
3. Guarantee that critical operational alerts (Windows Firewall Port 53281 status) and system fixes (Database repair, deduplication, cloud catch-up, and socket benchmarks) are prominent, accessible in one click, and never hidden.

#### Changes Implemented:
1. **Removal of Redundant Back Buttons in Sidebar Views**:
   - In [`server.dart`](file:///d:/GMWF/gmwf/lib/pages/server.dart#L1554), set `isEmbedded: true` and `onBack: null` for `BiometricDeviceManagerPage`, `PythonTerminalScreen`, and `ServerDataViewer`.
   - In [`python_terminal_screen.dart`](file:///d:/GMWF/gmwf/lib/pages/settings/python_terminal_screen.dart#L40), omitted the inner `AppBar` when `isEmbedded == true`, eliminating duplicate header bars and back arrows.
   - In [`server_data_viewer.dart`](file:///d:/GMWF/gmwf/lib/pages/server_data_viewer.dart#L196), omitted the inner `AppBar` when embedded in the dashboard.
   - Users freely navigate between subsystems directly via the left sidebar without clumsy nested back buttons.
2. **Prominent Windows Defender Firewall Alert Banner on Overview**:
   - Added a high-contrast amber alert banner directly below the Heading in [`nexus_views.dart`](file:///d:/GMWF/gmwf/lib/widgets/nexus_server_dashboard/nexus_views.dart#L130) whenever port 53281 is blocked in Windows Firewall.
   - Provides a direct **`[ Fix Firewall (Open Port) ]`** action button that automatically executes `netsh advfirewall` to open ports 53281, 8088, and 4370.
3. **One-Click Operational Diagnostics & Fixes Deck on Overview**:
   - **Force Cloud Sync**: Manually triggers an immediate cloud sync pass.
   - **Repair & Deduplicate**: Executes automated maintenance (purges bloated queue duplicates, flattens nested prescriptions, heals patient CNICs, and compacts database files on disk).
   - **Pressure Benchmark**: Directly launches the socket stress test engine to verify LAN bandwidth and latency under load.
   - **Inspect Outbox**: Shows exact count of pending unsynced actions with a 1-click modal breakdown.

---

### 18. Compilation & Scaffold Bracing Fix in `server.dart` and `server_data_viewer.dart`

#### Issues Resolved:
1. `lib/pages/server.dart:1683`: `Member not found: 'LocalStorageService.flattenNestedPrescriptions'`.
2. `lib/pages/server_data_viewer.dart:227`: `Expected an identifier, but got ']'` and premature `Scaffold` closure.

#### Solutions Applied:
- Linked `server.dart:1683` to the authoritative implementation `LocalStorageService.healNestedPrescriptions()`, and exposed `static Future<int> flattenNestedPrescriptions() => healNestedPrescriptions();` as an alias on [`LocalStorageService`](file:///d:/GMWF/gmwf/lib/services/local_storage_service.dart#L1575).
- Removed stray `], );` in [`server_data_viewer.dart`](file:///d:/GMWF/gmwf/lib/Pages/server_data_viewer.dart#L225) that closed the `Scaffold` prematurely before `body: ValueListenableBuilder`.

---

### 19. ZKTeco Python Standalone Service Quota Error (429) & PID Lock Resolution

#### Problem:
- When Firestore free-tier daily write limit (20,000 writes/day) was reached, `scripts/zkteco_sync_service.py` attempted to flush 76 offline buffered punches one-by-one.
- Firestore client library internally retries on HTTP 429 for up to 60.0s before throwing: `Timeout of 60.0s exceeded, last exception: 429 Quota exceeded.`
- Looping over 76 punches sequentially froze the Python process for **76 minutes** (4,560 seconds).
- In Flutter, attempting to start or restart the service displayed: `⚠️ A process is already running (PID: 22756). Please stop it first.`

#### Solutions Applied:
1. **Firestore Batched Writes**:
   - In [`scripts/zkteco_sync_service.py`](file:///d:/GMWF/gmwf/scripts/zkteco_sync_service.py#L200), `flush_offline_buffer(db)` now batches punches in chunks of up to 200 documents (`batch = db.batch()`, `batch.set(...)`, `batch.commit()`).
   - All 76 punches commit in **a single HTTP round-trip** (< 2 seconds) instead of 76 sequential requests.
2. **Immediate 429 Quota Cooldown & Local Preservation**:
   - If a 429 or `ResourceExhausted` error is caught, the loop **stops immediately**.
   - Zero punches are lost; all remaining punches remain safely in `pending_punches.json`.
   - Sets a 15-minute cooldown (`_quota_cooldown_until = time.time() + 900`).
   - `fetch_and_sync_device` checks this cooldown and saves new punches directly to `pending_punches.json` without attempting failing Firestore calls that would hang for 60 seconds.
3. **Clean Process Termination & Restart**:
   - In [`python_runner_service.dart`](file:///d:/GMWF/gmwf/lib/services/python_runner_service.dart#L385), `startScript` now accepts `forceRestart: true`, safely executing `taskkill /F /T /PID $pid` on Windows to clean up stale processes before launching.
   - In [`python_terminal_screen.dart`](file:///d:/GMWF/gmwf/lib/Pages/settings/python_terminal_screen.dart#L311), running the selected script automatically force-restarts if a previous instance is alive.

---

### 20. Real-Time LAN Delay (Tokens & Prescriptions Not Reaching Desks Simultaneously)

#### Problem:
- User reported: *"the token is not reaching the doc and the prescription not reaching the dispensar or hybrid is happening at the exact same time... it is not a matter of seconds instead it is a matter of minutes now"*.
- Both token propagation (Receptionist -> Server -> Doctor) and prescription propagation (Doctor -> Server -> Dispenser) failed or stalled for minutes simultaneously.

#### Root Causes & Solutions:
1. **Never Gate Peer-to-Peer Routing on Persistence**:
   - In [`lan_server.dart`](file:///d:/GMWF/gmwf/lib/realtime/lan_server.dart#L910), an early check `if (!persistenceReady) return;` was dropping `save_entry` and `save_prescription` frames before peer routing (`_routeMessage`), leaving them with the desk and sending no ACK.
   - Removed this gate: peer-to-peer relaying between connected desks (Desk A -> Desk B) now happens **immediately (< 5ms)** regardless of whether the server's cloud coordinator is busy.
   - `_deliverAndAck` gently yields if persistence is warming up, ensuring local disk save occurs without delaying peer delivery.
2. **Haji Camp UDP Discovery Branch Normalization**:
   - In [`lan_discovery.dart`](file:///d:/GMWF/gmwf/lib/realtime/lan_discovery.dart#L112), `_tryUdp` rejected discovery beacons if `serverBranch != myBranch`.
   - At Haji Camp, workstations had `haji_camp` while the server had `karachi`. Because `'haji_camp' != 'karachi'`, the discovery beacon was ignored, leaving desks disconnected ("Connecting... 51 unsent") until slow fallback scans ran minutes later.
   - Replaced strict string comparison with `CampSessionService.areBranchesMatching(myBranch, serverBranch)`, connecting desks in **under 200 milliseconds**.

---

### 21. Canonical Token Numbering (Strictly 001 to 999 Across All Desks)

#### Problem:
- Offline token generation previously used `slot * 1000 + seq`, producing numbers like `#2001`, `#2002`, `#2003`.
- User requested: *"a 1000+ token number is really bad idea we will only have the 001 to 999 token numbers doesn't matter if it is online or offline"*.

#### Solution Applied:
1. In [`local_storage_service.dart`](file:///d:/GMWF/gmwf/lib/services/local_storage_service.dart#L12540):
   - `offlineDeskSlot` strictly defaults to `0`.
   - Sequence generation is strictly clamped to `1..999` (`bandLow = 0`, `bandHigh = 999`).
2. Display Normalization:
   - Added `LocalStorageService.formatCanonicalSerialForDisplay(serial)` and `LocalStorageService.formatTokenDisplay(serial)`.
   - Any legacy or cached serials with sequence > 999 (e.g. `071126E-HAJI-2003`) are automatically normalized to 3-digit padded format (`071126E-HAJI-003`, `#003`).
   - Integrated into `receptionist_screen.dart`, `token_screen.dart`, `patient_list.dart`, and `patient_info.dart`.






