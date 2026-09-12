import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'package:hive/hive.dart';

import 'camp_session_service.dart';
import 'local_storage_service.dart';
import 'finance_local_storage.dart';
import '../realtime/realtime_manager.dart';

List<String> _dateStrings(DateTime start, DateTime end) {
  final df   = DateFormat('ddMMyy');
  final days = <String>[];
  for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
    days.add(df.format(d));
  }
  return days;
}

/// Single source of truth sequence integer parser from serial string.
/// Extracts the numerical sequence number regardless of prefix or hyphen format.
int parseSequenceFromSerial(String serial) {
  final s = serial.trim();
  if (s.isEmpty) return 999999;
  final parts = s.split('-');

  // 1. If temp format: X-ddMMyy-TAG-SEQ (e.g. X-160826-HAJI-003)
  if (parts.length >= 4 && parts[0].toUpperCase() == 'X') {
    final cleanSeq = parts[3].replaceAll(RegExp(r'[^\d]'), '');
    final numVal = int.tryParse(cleanSeq);
    if (numVal != null && cleanSeq.length <= 4) return numVal;
  }

  // 2. If branch-prefixed format: branchId-ddMMyy-TAG-SEQ (e.g. jalalpur_jattan-160826-HAJI-003)
  if (parts.length >= 4) {
    final lastPart = parts.last.replaceAll(RegExp(r'[^\d]'), '');
    final numVal = int.tryParse(lastPart);
    if (numVal != null && lastPart.length <= 4) return numVal;
  }

  // 3. Standard token serial format: ddMMyy-TAG-SEQ (e.g. 160826-HAJI-003)
  if (parts.length == 3 && RegExp(r'^\d{6}$').hasMatch(parts[0])) {
    final cleanSeq = parts[2].replaceAll(RegExp(r'[^\d]'), '');
    final numVal = int.tryParse(cleanSeq);
    if (numVal != null && cleanSeq.length <= 4) return numVal;
  }

  // 4. Any token format where the LAST hyphenated part is a 1-4 digit sequence (e.g. 001 to 9999)
  if (parts.length >= 2) {
    final lastPart = parts.last.replaceAll(RegExp(r'[^\d]'), '');
    final numVal = int.tryParse(lastPart);
    if (numVal != null && lastPart.isNotEmpty && lastPart.length <= 4) return numVal;
  }

  return 999999;
}

/// Issues a serial number atomically using a Firestore Transaction on:
///   branches/{branchId}/counters/{dateKey}_{dispensaryTag}
/// Returns a Map with the assigned serial, dateKey, and entryData written.
///
/// FIX 4: Idempotency guard. If [tokenData] carries a 'localId' or
/// 'originalTempSerial' (both are stable, client-generated identifiers for
/// a single logical token), a companion collection
/// (counters/{dateKey}_{tag}/_issued/{id}) records the result the first
/// time that id is processed. Any later call with the same id — e.g. a
/// duplicate call that slipped past Fix 1's sync-queue dedup — replays the
/// stored result instead of incrementing the counter again, so the serial
/// sequence never jumps by more than 1 per real token.
Future<Map<String, dynamic>> issueAtomicSerialTransaction({
  required String branchId,
  required String dispensaryTag,
  required String queueType,
  required Map<String, dynamic> tokenData,
  DateTime? time,
}) async {
  final normBranch = branchId.toLowerCase().trim();
  final normTag = dispensaryTag.trim().toUpperCase();
  final shiftInfo = CampSessionService.resolveShiftAndDateKey(time);
  final dateKey = shiftInfo.dateKey;
  final session = shiftInfo.session;

  final counterRef = FirebaseFirestore.instance
      .collection('branches')
      .doc(normBranch)
      .collection('counters')
      .doc('${dateKey}_$normTag');

  final db = FirebaseFirestore.instance;

  // Stable idempotency id for this logical token, if the caller supplied one.
  final idempotencyId =
      (tokenData['localId'] ?? tokenData['originalTempSerial'])?.toString().trim();
  final issuedRef = (idempotencyId != null && idempotencyId.isNotEmpty)
      ? counterRef.collection('_issued').doc(idempotencyId)
      : null;

  return await db.runTransaction((transaction) async {
    // FIX 4: Replay-check BEFORE reading/incrementing the counter. All reads
    // in a Firestore transaction must happen before any writes, so this get()
    // is safe to run first regardless of whether we end up short-circuiting.
    if (issuedRef != null) {
      final issuedSnap = await transaction.get(issuedRef);
      if (issuedSnap.exists) {
        final data = issuedSnap.data();
        final storedResult = data?['result'];
        if (storedResult is Map) {
          debugPrint(
              '[serials_service] ♻️ Idempotent replay for localId/originalTempSerial="$idempotencyId" '
              '— returning previously-issued serial "${storedResult['serial']}" instead of incrementing again.');
          return Map<String, dynamic>.from(storedResult);
        }
      }
    }

    final counterSnap = await transaction.get(counterRef);
    int currentSeq = 0;
    if (counterSnap.exists) {
      currentSeq = (counterSnap.data()?['lastSeq'] as num?)?.toInt() ?? 0;
    }
    final newSeq = currentSeq + 1;
    final seqPadded = newSeq.toString().padLeft(newSeq > 999 ? 4 : 3, '0');
    final serial = '$dateKey-$normTag-$seqPadded';

    transaction.set(counterRef, {
      'lastSeq': newSeq,
      'dateKey': dateKey,
      'dispensaryTag': normTag,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final entryData = Map<String, dynamic>.from(tokenData);
    entryData['serial'] = serial;
    entryData['dateKey'] = dateKey;
    entryData['session'] = session;
    entryData['queueType'] = queueType;
    entryData['branchId'] = normBranch;

    final campDocKey = CampSessionService.getCampDateDocId(
      branchId: normBranch,
      dateKey: dateKey,
      campId: entryData['campId']?.toString() ?? entryData['dispensaryId']?.toString(),
      dispensaryTag: dispensaryTag,
      serial: serial,
    );

    final tokenRef = db
        .collection('branches')
        .doc(normBranch)
        .collection('serials')
        .doc(campDocKey)
        .collection(queueType)
        .doc(serial);

    transaction.set(tokenRef, entryData, SetOptions(merge: true));

    final result = <String, dynamic>{
      'serial': serial,
      'dateKey': dateKey,
      'session': session,
      'seq': newSeq,
      'entryData': entryData,
    };

    // FIX 4: Record this id's result AFTER computing the serial, so a
    // subsequent duplicate call with the same localId/originalTempSerial
    // finds it and replays instead of re-incrementing.
    if (issuedRef != null) {
      transaction.set(issuedRef, {
        'result': result,
        'issuedAt': FieldValue.serverTimestamp(),
      });
    }

    return result;
  });
}

bool _matchesSubDispensary(Map<String, dynamic> data, String? subFilter, [String? docId]) {
  if (subFilter == null || subFilter.isEmpty || subFilter == 'all') return true;
  return CampSessionService.matchesCamp(
    selectedCamp: subFilter,
    dispensaryId: data['dispensaryId']?.toString(),
    campId: data['campId']?.toString(),
    dispensaryTag: data['dispensaryTag']?.toString(),
    serial: (data['serial'] ?? data['tokenSerial'] ?? data['id'] ?? data['tokenNumber'] ?? docId)?.toString(),
  );
}

bool _matchesShift(Map<String, dynamic> data, String? shiftFilter) {
  if (shiftFilter == null || shiftFilter.isEmpty || shiftFilter == 'all') return true;
  final normShift = shiftFilter.toLowerCase().trim();

  // 1. Check explicit session / shift / campSession / slot field
  final session = (data['session'] ?? data['shift'] ?? data['campSession'] ?? data['slot'] ?? '').toString().toLowerCase().trim();
  if (session == 'night') {
    return normShift == 'night';
  } else if (session == 'morning') {
    return normShift == 'morning' || normShift == 'day';
  } else if (session == 'evening') {
    return normShift == 'evening' || normShift == 'day';
  }

  // 2. Fallback to timestamp/hour (converted to local timezone)
  DateTime? dt;
  final ts = data['createdAt'] ?? data['timestamp'] ?? data['time'] ?? data['dispensedAt'] ?? data['date'] ?? data['lastUpdatedAt'];
  if (ts is Timestamp) {
    dt = ts.toDate().toLocal();
  } else if (ts is DateTime) {
    dt = ts.toLocal();
  } else if (ts is String) {
    dt = DateTime.tryParse(ts)?.toLocal();
  }

  if (dt != null) {
    final hour = dt.hour;
    final isNight = (hour >= 22 || hour < 6);
    final isMorning = (hour >= 6 && hour < 14);
    final isEvening = (hour >= 14 && hour < 22);

    if (normShift == 'night') return isNight;
    if (normShift == 'morning') return isMorning;
    if (normShift == 'evening') return isEvening;
    if (normShift == 'day') return !isNight;
  }

  // If no timestamp or session, default to morning/day
  return normShift == 'morning' || normShift == 'day';
}

Future<Map<String, int>> _getDailySerialsSummary(String branchId, String ds, String todayKey, [String? subDispensary, String? shift]) async {
  final normBranchId = branchId.toLowerCase().trim();
  final subKey = (subDispensary != null && subDispensary.isNotEmpty && subDispensary != 'all') ? subDispensary.toLowerCase().trim() : 'all';
  final shiftKey = (shift != null && shift.isNotEmpty && shift != 'all') ? shift.toLowerCase().trim() : 'all';
  final cacheKey = 'v2|$normBranchId|$subKey|$shiftKey|$ds|serials_summary';
  
  // 1. For past days, check Hive cache first
  if (ds != todayKey) {
    try {
      if (!Hive.isBoxOpen('branch_data_cache')) {
        await Hive.openBox('branch_data_cache');
      }
      final box = Hive.box('branch_data_cache');
      final cached = box.get(cacheKey) ?? (shiftKey == 'all' ? box.get('v2|$normBranchId|$subKey|$ds|serials_summary') : null);
      if (cached is Map) {
        return Map<String, int>.from(cached.cast<String, int>());
      }
    } catch (_) {}
  }
  
  // 2. LOCAL-FIRST: Count from local Hive boxes (entriesBox + dispensaryBox)
  final Map<String, Map<String, dynamic>> localTokenMap = {};
  final Set<String> zakatSerials = {};
  final Set<String> nonZakatSerials = {};
  final Set<String> gmwfSerials = {};

  void processLocalEntry(Map<String, dynamic> data, String fallbackId) {
    final status = (data['status'] ?? '').toString().toLowerCase().trim();
    final syncStatus = (data['syncStatus'] ?? '').toString().toLowerCase().trim();
    final isDeleted = data['isDeleted'] == true || status == 'deleted' || syncStatus == 'deleted' || status == 'void' || status == 'cancelled';
    if (isDeleted) return;

    if (!_matchesSubDispensary(data, subDispensary, fallbackId)) return;
    if (!_matchesShift(data, shift)) return;

    final rawSerial = (data['serial'] ?? data['tokenSerial'] ?? data['id'] ?? fallbackId).toString().trim();
    if (rawSerial.isEmpty) return;
    final upperSerial = rawSerial.toUpperCase();

    // Determine queue type
    final qt = (data['queueType'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    String resolvedQueue;
    if (qt.contains('non') || qt.contains('nz') || upperSerial.contains('NZ-')) {
      resolvedQueue = 'non-zakat';
    } else if (qt.contains('gmwf') || qt.contains('free') || upperSerial.contains('G-')) {
      resolvedQueue = 'gmwf';
    } else {
      resolvedQueue = 'zakat';
    }

    if (localTokenMap.containsKey(upperSerial)) return;
    localTokenMap[upperSerial] = data;

    if (resolvedQueue == 'zakat') {
      zakatSerials.add(upperSerial);
    } else if (resolvedQueue == 'non-zakat') {
      nonZakatSerials.add(upperSerial);
    } else {
      gmwfSerials.add(upperSerial);
    }
  }

  // Scan entriesBox
  try {
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final eBox = Hive.box(LocalStorageService.entriesBox);
      for (final k in eBox.keys) {
        final val = eBox.get(k);
        if (val is! Map) continue;
        final d = Map<String, dynamic>.from(val);
        final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
        final dk = (d['dateKey'] ?? d['date'] ?? '').toString().trim();
        final matchBranch = normBranchId == 'all' || normBranchId.isEmpty || b == normBranchId || b.isEmpty;
        if (matchBranch && dk == ds) {
          processLocalEntry(d, k.toString());
        }
      }
    }
  } catch (_) {}

  // Scan dispensaryBox
  try {
    if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
      final dBox = Hive.box(LocalStorageService.dispensaryBox);
      for (final k in dBox.keys) {
        final val = dBox.get(k);
        if (val is! Map) continue;
        final d = Map<String, dynamic>.from(val);
        final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
        final dk = (d['dateKey'] ?? d['date'] ?? '').toString().trim();
        final matchBranch = normBranchId == 'all' || normBranchId.isEmpty || b == normBranchId || b.isEmpty;
        if (matchBranch && dk == ds) {
          processLocalEntry(d, k.toString());
        }
      }
    }
  } catch (_) {}

  // 3. If local data found, compute summary from it
  if (localTokenMap.isNotEmpty) {
    return _buildSummaryFromTokenMap(localTokenMap, zakatSerials, nonZakatSerials, gmwfSerials, ds, todayKey, cacheKey);
  }

  // 4. FALLBACK: Only query Firestore if local Hive is completely empty for this day
  try {
    final queues = ['zakat', 'non-zakat', 'gmwf'];
    final dateDocs = CampSessionService.getAllCampDateDocIds(
      branchId: normBranchId,
      dateKey: ds,
      selectedCamp: subDispensary,
    );
    final futures = <Future<QuerySnapshot<Map<String, dynamic>>>>[];
    final queryQueues = <String>[];
    for (final docKey in dateDocs) {
      for (final q in queues) {
        futures.add(FirebaseFirestore.instance
            .collection('branches/$normBranchId/serials/$docKey/$q')
            .get()
            .timeout(const Duration(seconds: 4))
            .catchError((_) => FirebaseFirestore.instance
                .collection('_empty_')
                .limit(0)
                .get()));
        queryQueues.add(q);
      }
    }

    final snaps = await Future.wait(futures);

    for (int i = 0; i < snaps.length; i++) {
      final q = queryQueues[i];
      final snap = snaps[i];
      for (final doc in snap.docs) {
        final data = doc.data();
        final status = (data['status'] ?? '').toString().toLowerCase().trim();
        final syncStatus = (data['syncStatus'] ?? '').toString().toLowerCase().trim();
        final isDeleted = data['isDeleted'] == true || status == 'deleted' || syncStatus == 'deleted' || status == 'void' || status == 'cancelled';
        if (isDeleted) continue;

        if (!_matchesSubDispensary(data, subDispensary, doc.id)) continue;
        if (!_matchesShift(data, shift)) continue;

        final rawSerial = (data['serial'] ?? data['tokenSerial'] ?? data['id'] ?? data['tokenNumber'] ?? doc.id).toString().trim();
        final cleanNum = int.tryParse(rawSerial.replaceAll(RegExp(r'[^0-9]'), ''));
        final facilityKey = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? doc.reference.parent.parent?.id ?? '').toString().toLowerCase().trim();
        final prefix = q == 'non-zakat' ? 'NZ' : (q == 'zakat' ? 'Z' : 'G');
        final uniqueKey = (rawSerial.isNotEmpty && rawSerial.contains('-'))
            ? rawSerial
            : ((cleanNum != null && cleanNum > 0) ? '$facilityKey-$prefix-${cleanNum % 1000}' : '${facilityKey}_${q}_${doc.id}');

        if (localTokenMap.containsKey(uniqueKey)) continue;
        localTokenMap[uniqueKey] = data;

        if (q == 'zakat') zakatSerials.add(uniqueKey);
        else if (q == 'non-zakat') nonZakatSerials.add(uniqueKey);
        else gmwfSerials.add(uniqueKey);
      }
    }
  } catch (e) {
    debugPrint('[SerialsService] Firestore fallback query failed: $e');
  }

  return _buildSummaryFromTokenMap(localTokenMap, zakatSerials, nonZakatSerials, gmwfSerials, ds, todayKey, cacheKey);
}

Map<String, int> _buildSummaryFromTokenMap(
  Map<String, Map<String, dynamic>> tokenMap,
  Set<String> zakatSerials,
  Set<String> nonZakatSerials,
  Set<String> gmwfSerials,
  String ds,
  String todayKey,
  String cacheKey,
) {
  int pending = 0, dispensed = 0;
  int zakatRevenue = 0, nonZakatRevenue = 0;
  int prescWaiting = 0, prescPrescribed = 0;
  int dispPending = 0, dispDispensed = 0;

  for (final entry in tokenMap.entries) {
    final data = entry.value;
    final serial = entry.key;
    final daysOfMedicine = (data['daysOfMedicine'] as num?)?.toInt() ?? 1;

    if (zakatSerials.contains(serial)) {
      zakatRevenue += 20 * daysOfMedicine;
    } else if (nonZakatSerials.contains(serial)) {
      nonZakatRevenue += 100 * daysOfMedicine;
    }

    final status = (data['status'] ?? '').toString().toLowerCase().trim();
    final dispenseStatus = (data['dispenseStatus'] ?? '').toString().toLowerCase().trim();
    final hasPrescription = data['prescription'] is Map ||
        data['prescriptions'] is List ||
        data['prescriptionId'] != null;

    if (status == 'dispensed' || dispenseStatus == 'dispensed') {
      dispensed++;
      dispDispensed++;
      if (hasPrescription || status == 'dispensed') prescPrescribed++;
    } else if (status == 'completed' || status == 'prescribed' || hasPrescription) {
      prescPrescribed++;
      dispPending++;
    } else {
      pending++;
      prescWaiting++;
    }
  }

  final zakatCount = zakatSerials.length;
  final nonZakatCount = nonZakatSerials.length;
  final gmwfCount = gmwfSerials.length;

  final daySummary = {
    'v1': zakatCount,
    'v1_sub': zakatRevenue,
    'v2': nonZakatCount,
    'v2_sub': nonZakatRevenue,
    'v3': gmwfCount,
    'v3_sub': 0,
    'total': zakatCount + nonZakatCount + gmwfCount,
    'revenue': zakatRevenue + nonZakatRevenue,
    'pending': pending,
    'dispensed': dispensed,
    'presc_waiting': prescWaiting,
    'presc_prescribed': prescPrescribed,
    'disp_pending': dispPending,
    'disp_dispensed': dispDispensed,
  };

  if (ds != todayKey) {
    try {
      if (Hive.isBoxOpen('branch_data_cache')) {
        final box = Hive.box('branch_data_cache');
        box.put(cacheKey, daySummary);
      }
    } catch (_) {}
  }

  return daySummary;
}

Stream<Map<String, int>> serialsCountStream(String branchId, DateTime start, DateTime end, {String? subDispensary, String? shift}) {
  final normalizedBranch = branchId.toLowerCase().trim();
  if (normalizedBranch == 'all' || normalizedBranch == 'global') {
    final branchMaps = FinanceLocalStorage.getAllBranches([]);
    try {
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? '').toString().trim();
            final name = (val['name'] ?? id).toString().trim();
            if (id.isNotEmpty && id.toLowerCase() != 'all' && id.toLowerCase() != 'global') {
              if (!branchMaps.any((b) => (b['id'] ?? '').toString().toLowerCase() == id.toLowerCase())) {
                branchMaps.add({'id': id, 'name': name.isNotEmpty ? name : id});
              }
            }
          }
        }
      }
    } catch (_) {}
    final ids = branchMaps
        .map((b) => (b['id'] ?? '').toString().toLowerCase().trim())
        .where((id) => id.isNotEmpty && id != 'all' && id != 'global')
        .toSet()
        .toList();
    if (ids.isEmpty) return Stream.value(<String, int>{});
    return Rx.combineLatestList(ids.map((id) => _serialsCountStreamForBranch(
          id,
          start,
          end,
          subDispensary: subDispensary,
          shift: shift,
        ))).map((summaries) {
      final merged = <String, int>{};
      for (final summary in summaries) {
        summary.forEach((key, value) {
          merged[key] = (merged[key] ?? 0) + value;
        });
      }
      return merged;
    });
  }
  return _serialsCountStreamForBranch(branchId, start, end, subDispensary: subDispensary, shift: shift);
}

Stream<Map<String, int>> _serialsCountStreamForBranch(String branchId, DateTime start, DateTime end, {String? subDispensary, String? shift}) {
  final normBranchId = branchId.toLowerCase().trim();
  final subKey = (subDispensary != null && subDispensary.isNotEmpty && subDispensary != 'all') ? subDispensary.toLowerCase().trim() : 'all';
  final shiftKey = (shift != null && shift.isNotEmpty && shift != 'all') ? shift.toLowerCase().trim() : 'all';
  final days = _dateStrings(start, end);
  final todayKey = DateFormat('ddMMyy').format(DateTime.now());
  
  final hasToday = days.contains(todayKey);
  final pastDays = days.where((d) => d != todayKey).toList();

  // 1. Get initial cached summary from Hive immediately (0ms)
  Map<String, int>? initialCached;
  try {
    if (Hive.isBoxOpen('branch_data_cache')) {
      final box = Hive.box('branch_data_cache');
      final merged = <String, int>{};
      bool hasData = false;
      for (final ds in days) {
        final cacheKey = 'v2|$normBranchId|$subKey|$shiftKey|$ds|serials_summary';
        final cached = box.get(cacheKey) ?? (shiftKey == 'all' ? box.get('v2|$normBranchId|$subKey|$ds|serials_summary') : null);
        if (cached is Map) {
          hasData = true;
          cached.forEach((key, val) {
            if (val is num) {
              merged[key.toString()] = (merged[key.toString()] ?? 0) + val.toInt();
            }
          });
        }
      }
      if (hasData) {
        initialCached = merged;
      }
    }
  } catch (_) {}

  // 2. Fetch past days summaries in parallel
  final Future<Map<String, int>> pastSummaryFuture = () async {
    if (pastDays.isEmpty) return <String, int>{};
    final summaries = await Future.wait(
      pastDays.map((ds) => _getDailySerialsSummary(normBranchId, ds, todayKey, subDispensary, shift)),
    );
    final merged = <String, int>{};
    for (final summary in summaries) {
      summary.forEach((key, val) {
        merged[key] = (merged[key] ?? 0) + val;
      });
    }
    return merged;
  }();

  if (!hasToday) {
    var stream = Stream.fromFuture(pastSummaryFuture);
    if (initialCached != null) {
      stream = stream.startWith(initialCached);
    }
    return stream.asBroadcastStream();
  }

  // 3. Pure local-first today calculation — zero Firestore snapshots:
  final Future<Map<String, int>> Function() computeCombined = () async {
    final pastSummary = await pastSummaryFuture;
    final todaySummary = await _getDailySerialsSummary(normBranchId, todayKey, todayKey, subDispensary, shift);
    final merged = Map<String, int>.from(pastSummary);
    todaySummary.forEach((key, val) {
      merged[key] = (merged[key] ?? 0) + val;
    });
    return merged;
  };

  final streams = <Stream<dynamic>>[];
  try {
    if (Hive.isBoxOpen('branch_data_cache')) {
      streams.add(Hive.box('branch_data_cache').watch());
    }
  } catch (_) {}
  try {
    streams.add(RealtimeManager().messageStream);
  } catch (_) {}

  Stream<Map<String, int>> liveStream = Stream.fromFuture(computeCombined());
  if (streams.isNotEmpty) {
    final trigger = Rx.merge(streams)
        .debounceTime(const Duration(milliseconds: 500))
        .switchMap((_) => Stream.fromFuture(computeCombined()));
    liveStream = Rx.merge([liveStream, trigger]);
  }

  if (initialCached != null) {
    liveStream = liveStream.startWith(initialCached);
  }

  return liveStream.asBroadcastStream();
}

Stream<Map<String, Map<String, int>>> facilityShiftBreakdownStream(String branchId, DateTime start, DateTime end) {
  // OPTIMIZATION: Instead of launching 9 distinct streams (which spawned 27
  // concurrent Firestore listeners), we run a single unified stream for the
  // branch and compute the 9 sub-totals in memory!
  return _serialsCountStreamForBranch(branchId, start, end, subDispensary: 'all', shift: 'all').map((summary) {
    // If the branch stream already contains the breakdown or local cached counts
    final total = summary['total'] ?? 0;
    final pending = summary['pending'] ?? 0;
    final dispensed = summary['dispensed'] ?? 0;

    // Compute real detailed breakdown across the requested date range
    final normBranchId = branchId.toLowerCase().trim();
    final days = _dateStrings(start, end);
    final dateSet = days.toSet();

    int sMornTotal = 0, sEveTotal = 0, sNightTotal = 0;
    int hMornTotal = 0, hEveTotal = 0, hNightTotal = 0;

    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final box = Hive.box(LocalStorageService.entriesBox);
        for (final val in box.values) {
          if (val is! Map) continue;
          final b = (val['branchId'] ?? '').toString().toLowerCase().trim();
          if (normBranchId != 'all' && b.isNotEmpty && !b.contains(normBranchId) && !normBranchId.contains(b)) {
            continue;
          }
          final dk = (val['dateKey'] ?? val['date'] ?? '').toString().trim();
          if (dateSet.isNotEmpty && !dateSet.contains(dk)) continue;

          final serial = (val['serial'] ?? val['id'] ?? '').toString().toUpperCase();
          final camp = (val['campId'] ?? val['dispensaryId'] ?? val['dispensaryTag'] ?? '').toString().toLowerCase();
          final sess = (val['session'] ?? val['shift'] ?? '').toString().toLowerCase();

          final isHaji = serial.contains('-HAJI') || serial.contains('HAJI-') || camp.contains('haji');
          final isSaddar = serial.contains('-SADD') || serial.contains('SADD-') || camp.contains('saddar') || (!isHaji);

          final isEve = sess.contains('eve');
          final isNight = sess.contains('night');
          final isMorn = sess.contains('morn') || (!isEve && !isNight);

          if (isHaji) {
            if (isMorn) hMornTotal++;
            else if (isEve) hEveTotal++;
            else if (isNight) hNightTotal++;
            else hMornTotal++;
          } else if (isSaddar) {
            if (isMorn) sMornTotal++;
            else if (isEve) sEveTotal++;
            else if (isNight) sNightTotal++;
            else sMornTotal++;
          }
        }
      }
    } catch (_) {}

    final sTotal = sMornTotal + sEveTotal + sNightTotal;
    final hTotal = hMornTotal + hEveTotal + hNightTotal;

    final allMornTotal = sMornTotal + hMornTotal;
    final allEveTotal = sEveTotal + hEveTotal;
    final allNightTotal = sNightTotal + hNightTotal;
    final calculatedTotal = sTotal + hTotal;
    final effectiveAllTotal = calculatedTotal > 0 ? calculatedTotal : total;

    return {
      'saddar': {
        'morning': sMornTotal,
        'evening': sEveTotal,
        'night': sNightTotal,
        'day': sMornTotal + sEveTotal,
        'total': sTotal,
      },
      'haji_camp': {
        'morning': hMornTotal,
        'evening': hEveTotal,
        'night': hNightTotal,
        'day': hMornTotal + hEveTotal,
        'total': hTotal,
      },
      'all': {
        'morning': allMornTotal,
        'evening': allEveTotal,
        'night': allNightTotal,
        'day': allMornTotal + allEveTotal,
        'total': effectiveAllTotal,
      },
    };
  });
}

Future<Map<String, int>> serialsCountFuture(String branchId, DateTime start, DateTime end) async {
  final normBranchId = branchId.toLowerCase().trim();
  final days = _dateStrings(start, end);
  final todayKey = DateFormat('ddMMyy').format(DateTime.now());
  
  final daySummaries = await Future.wait(
    days.map((ds) => _getDailySerialsSummary(normBranchId, ds, todayKey)),
  );
  
  final merged = <String, int>{};
  for (final summary in daySummaries) {
    summary.forEach((key, val) {
      merged[key] = (merged[key] ?? 0) + val;
    });
  }
  return merged;
}