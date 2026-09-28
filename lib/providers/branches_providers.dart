// lib/providers/branches_providers.dart
//
// Traditional Riverpod providers (no code-generation) for the Branches screen.
// Each provider is intentionally narrow: it manages one piece of state so that
// only the widgets that depend on it rebuild when it changes.

import 'dart:async';
import 'dart:io' as io;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/local_storage_service.dart';
import '../services/finance_local_storage.dart';
import '../services/serials_service.dart';
import '../services/camp_session_service.dart';
import '../services/quota_service.dart';

import 'package:rxdart/rxdart.dart';
import 'package:flutter/foundation.dart';
import '../realtime/realtime_manager.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Branches list – streams all branches from local Hive storage.
//    If a specific branchId is provided (supervisor mode) it filters to that one.
// ─────────────────────────────────────────────────────────────────────────────

/// Holds the optional branchId for single-branch (supervisor) mode.
/// Set this from the widget before watching [branchesListProvider].
final singleBranchIdProvider = StateProvider<String?>((ref) => null);

/// Holds the active branchId tab selected externally (e.g. from Dashboard performance table).
final selectedBranchTabIdProvider = StateProvider<String?>((ref) => null);

List<Map<String, dynamic>> _getLocalBranchesList(String? singleId) {
  final merged = FinanceLocalStorage.getAllBranches([]);
  try {
    if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
      final box = Hive.box(LocalStorageService.branchesBox);
      for (final val in box.values) {
        if (val is Map) {
          final id = (val['id'] ?? '').toString().trim();
          final name = (val['name'] ?? id).toString().trim();
          if (id.isNotEmpty && id.toLowerCase() != 'all' && id.toLowerCase() != 'global') {
            if (!merged.any((b) => (b['id'] ?? '').toString().toLowerCase() == id.toLowerCase())) {
              merged.add({'id': id, 'name': name.isNotEmpty ? name : id});
            }
          }
        }
      }
    }
  } catch (_) {}
  try {
    if (Hive.isBoxOpen('local_branches')) {
      final box = Hive.box('local_branches');
      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          final id = (val['id'] ?? key.toString().replaceAll('branch:', '')).toString().trim();
          final name = (val['name'] ?? id).toString().trim();
          if (id.isNotEmpty && id.toLowerCase() != 'all' && id.toLowerCase() != 'global') {
            if (!merged.any((b) => (b['id'] ?? '').toString().toLowerCase() == id.toLowerCase())) {
              merged.add({'id': id, 'name': name.isNotEmpty ? name : id});
            }
          }
        }
      }
    }
  } catch (_) {}

  if (singleId != null) {
    merged.retainWhere((b) => (b['id'] ?? '').toString().toLowerCase() == singleId.toLowerCase());
  }

  merged.sort((a, b) =>
      ((a['name'] ?? '') as String).compareTo((b['name'] ?? '') as String));
  if (singleId == null && merged.length > 1) {
    merged.insert(0, {'id': 'all', 'name': 'All Branches'});
  }
  return merged;
}

/// Streams the list of branches as [{id, name}] maps, sorted by name, backed by local Hive storage.
final branchesListProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) async* {
  final singleId = ref.watch(singleBranchIdProvider);
  yield _getLocalBranchesList(singleId);

  final streams = <Stream<dynamic>>[];
  try {
    if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
      streams.add(Hive.box(LocalStorageService.branchesBox).watch());
    }
  } catch (_) {}
  try {
    if (Hive.isBoxOpen('local_branches')) {
      streams.add(Hive.box('local_branches').watch());
    }
  } catch (_) {}

  if (streams.isNotEmpty) {
    await for (final _ in Rx.merge(streams).debounceTime(const Duration(milliseconds: 200))) {
      yield _getLocalBranchesList(singleId);
    }
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. Date range filter
// ─────────────────────────────────────────────────────────────────────────────

class DateRange {
  final DateTime? start;
  final DateTime? end;
  const DateRange({this.start, this.end});
  bool get isToday => start == null && end == null;
  DateRange copyWith({DateTime? start, DateTime? end}) =>
      DateRange(start: start ?? this.start, end: end ?? this.end);
}

final branchDateRangeProvider =
    StateProvider<DateRange>((ref) => const DateRange());

// ─────────────────────────────────────────────────────────────────────────────
// 3. Dispensary-list filter chips
// ─────────────────────────────────────────────────────────────────────────────

/// Selected type filter: null = All, 'zakat', 'non-zakat', 'gmwf'
final branchTypeFilterProvider = StateProvider<String?>((ref) => null);

/// Selected sub-dispensary facility filter: null = All, 'kapayya', 'haji_camp'
final branchSubDispensaryFilterProvider = StateProvider<String?>((ref) => null);

/// Selected shift filter: null = All, 'day', 'night'
final branchShiftFilterProvider = StateProvider<String?>((ref) => null);

final branchMultiDayFilterProvider = StateProvider<bool>((ref) => false);

final branchMultiVisitFilterProvider = StateProvider<bool>((ref) => false);

/// Selected stage filter: 'all', 'waiting_doctor', 'waiting_dispensary', 'dispensed'
final branchStageFilterProvider = StateProvider<String>((ref) => 'all');

/// Selected token category filter: 'all', 'vitals', 'normal'
final branchTokenCategoryFilterProvider = StateProvider<String>((ref) => 'all');

// ─────────────────────────────────────────────────────────────────────────────
// 4. Reverted-patient IDs  (patients whose frequent-flag has been dismissed)
// ─────────────────────────────────────────────────────────────────────────────

final revertedPatientIdsProvider =
    StateProvider<Set<String>>((ref) => const {});

// ─────────────────────────────────────────────────────────────────────────────
// 5. Per-branch dispensary data + sync/error state
//
//    We use a Notifier family so each branch has its own isolated state.
//    The notifier owns the full load + background-sync pipeline so branches.dart
//    never needs to touch ValueNotifier maps or StreamSubscription bookkeeping.
// ─────────────────────────────────────────────────────────────────────────────

class DispensaryState {
  final List<Map<String, dynamic>> records;
  final bool isSyncing;
  final String? error;

  const DispensaryState({
    this.records = const [],
    this.isSyncing = false,
    this.error,
  });

  DispensaryState copyWith({
    List<Map<String, dynamic>>? records,
    bool? isSyncing,
    String? error,
    bool clearError = false,
  }) =>
      DispensaryState(
        records: records ?? this.records,
        isSyncing: isSyncing ?? this.isSyncing,
        error: clearError ? null : (error ?? this.error),
      );
}

class DispensaryNotifier
    extends AutoDisposeFamilyNotifier<DispensaryState, String> {
  StreamSubscription? _todaySubscription;
  String? _subscribedTodayKey;
  static final Map<String, DateTime> _lastFirestoreFetch = {};

  // The branchId is available as `arg` from the family provider, normalized to lowercase.
  String get branchId => arg.toLowerCase().trim();

  @override
  DispensaryState build(String arg) {
    ref.onDispose(() {
      _todaySubscription?.cancel();
    });

    final dateRange = ref.watch(branchDateRangeProvider);
    final DateTime effectiveStart;
    final DateTime effectiveEnd;
    if (dateRange.start != null && dateRange.end != null) {
      effectiveStart = dateRange.start!;
      effectiveEnd = dateRange.end!.add(const Duration(days: 1));
    } else {
      final now = DateTime.now();
      effectiveStart = DateTime(now.year, now.month, now.day);
      effectiveEnd = DateTime(now.year, now.month, now.day + 1);
    }

    Future.microtask(() => load(effectiveStart, effectiveEnd));
    return const DispensaryState(isSyncing: true);
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  Future<void> load(DateTime start, DateTime end) async {
    state = state.copyWith(isSyncing: true, clearError: true, records: []);

    final days = _dateStrings(start, end);
    final todayKey = DateFormat('ddMMyy').format(DateTime.now());

    final initialList = <Map<String, dynamic>>[];
    final missingDays = <String>[];

    for (final day in days) {
      if (day == todayKey) {
        missingDays.add(day);
        continue;
      }
      final cached =
          LocalStorageService.getBranchDayCache(branchId, day, 'dispensary');
      if (cached != null) {
        initialList.addAll(cached);
      } else {
        missingDays.add(day);
      }
    }

    // Emit cached data immediately so the UI is not blank while we fetch
    state = state.copyWith(records: List.from(initialList));

    if (missingDays.isEmpty) {
      state = state.copyWith(isSyncing: false);
      await _computeVisitsAndEmit(initialList);
      return;
    }

    await _runBackgroundSync(missingDays, todayKey, initialList);
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  Future<void> _runBackgroundSync(
    List<String> missingDays,
    String todayKey,
    List<Map<String, dynamic>> currentList,
  ) async {
    try {
      final hasToday = missingDays.contains(todayKey);
      final pastMissing = missingDays.where((d) => d != todayKey).toList();

      if (hasToday) {
        await _setupTodayListener(todayKey, currentList);
      } else {
        _todaySubscription?.cancel();
        _subscribedTodayKey = null;
      }

      if (pastMissing.isNotEmpty) {
        // Fetch raw docs for all past missing days in parallel
        final Map<String, List<Map<String, dynamic>>> rawDocsMap = {};
        await Future.wait(pastMissing.map((day) async {
          try {
            final docs = await _fetchDispensaryDocsForDay(day);
            for (final d in docs) {
              d['_syncDayKey'] = day;
            }
            rawDocsMap[day] = docs;
          } catch (e) {
            state = state.copyWith(
                error: 'Failed to fetch raw docs for day $day: $e');
          }
        }));

        final allRawDocs = rawDocsMap.values.expand((l) => l).toList();

        List<Map<String, dynamic>> enrichedAll;
        try {
          enrichedAll =
              await LocalStorageService.enrichRawDocs(branchId, allRawDocs);
        } catch (_) {
          enrichedAll = _fallbackEnrich(allRawDocs);
        }

        final displayFormat = DateFormat('dd MMM yyyy');
        final enrichedByDay = <String, List<Map<String, dynamic>>>{};
        for (final d in enrichedAll) {
          final day = d['_syncDayKey'] as String? ?? todayKey;
          d.remove('_syncDayKey');
          d['dispenseDate'] = displayFormat
              .format(_parseDispensedAt(d['dispensedAt'], day));
          d['type'] = _resolveType(d);
          enrichedByDay.putIfAbsent(day, () => []).add(d);
        }

        for (final day in pastMissing) {
          final dayEnriched = enrichedByDay[day] ?? [];
          await LocalStorageService.putBranchDayCache(
              branchId, day, 'dispensary', dayEnriched);
          currentList.addAll(dayEnriched);
        }

        await _computeVisitsAndEmit(currentList);
      }
    } catch (e) {
      state = state.copyWith(error: 'Background sync failed: $e');
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<void> _setupTodayListener(
      String todayKey, List<Map<String, dynamic>> currentList) async {
    // One-shot fetch first to populate immediately
    await _fetchAndMergeToday(todayKey, currentList);

    if (_subscribedTodayKey == todayKey) return; // already subscribed

    _todaySubscription?.cancel();
    _subscribedTodayKey = todayKey;

    final streams = <Stream<dynamic>>[];
    try {
      if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
        streams.add(Hive.box(LocalStorageService.dispensaryBox).watch());
      }
    } catch (_) {}
    try {
      streams.add(RealtimeManager().messageStream);
    } catch (_) {}

    if (streams.isNotEmpty) {
      _todaySubscription = Rx.merge(streams)
          .debounceTime(const Duration(milliseconds: 300))
          .listen((_) async {
        try {
          await _fetchAndMergeToday(todayKey, List.from(state.records));
        } catch (e) {
          debugPrint('[DispensaryNotifier] today local listener notice: $e');
        }
      });
    }
  }

  Future<void> _fetchAndMergeToday(
      String todayKey, List<Map<String, dynamic>> currentList) async {
    try {
      final rawDocs = await _fetchDispensaryDocsForDay(todayKey);

      List<Map<String, dynamic>> enrichedToday;
      try {
        enrichedToday =
            await LocalStorageService.enrichRawDocs(branchId, rawDocs);
      } catch (_) {
        enrichedToday = _fallbackEnrich(rawDocs);
      }

      final displayFormat = DateFormat('dd MMM yyyy');
      final todayDisplayStr =
          displayFormat.format(LocalStorageService.parseDdMMyy(todayKey));
      for (final d in enrichedToday) {
        d['dispenseDate'] = todayDisplayStr;
        d['type'] = _resolveType(d);
      }

      currentList.removeWhere((item) => item['dispenseDate'] == todayDisplayStr);
      currentList.addAll(enrichedToday);
      await _computeVisitsAndEmit(currentList);
    } catch (e) {
      print('[DispensaryNotifier] _fetchAndMergeToday error: $e');
    }
  }

  Future<void> _computeVisitsAndEmit(
      List<Map<String, dynamic>> list) async {
    try {
      final visitCountMap = <String, int>{};

      // When no date filter — compute visit count over rolling 7-day window
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final visitStart = today.subtract(const Duration(days: 7));
      final visitDays =
          _dateStrings(visitStart, today.add(const Duration(days: 1)));

      final dayDocsList = await Future.wait(visitDays.map((day) async {
        final cached =
            LocalStorageService.getBranchDayCache(branchId, day, 'dispensary');
        return cached ?? await _fetchDispensaryDocsCached(day);
      }));

      for (final dayDocs in dayDocsList) {
        for (final doc in dayDocs) {
          final pid = _resolvePatientId(doc);
          if (pid.isEmpty) continue;
          visitCountMap.update(pid, (v) => v + 1, ifAbsent: () => 1);
        }
      }

      for (final e in list) {
        final pid = e['patientId']?.toString() ?? '';
        e['totalVisits'] = visitCountMap[pid] ?? 0;
      }

      state = state.copyWith(records: List.from(list));
    } catch (e, stack) {
      print('[DispensaryNotifier] _computeVisitsAndEmit error: $e');
      try {
        final file = io.File('e:/GMWF/gmwf/debug_branches.txt');
        await file.writeAsString('\n=== ERROR IN _computeVisitsAndEmit ===\n$e\n$stack\n', mode: io.FileMode.append);
      } catch (_) {}
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchDispensaryDocsCached(
      String dayKey) async {
    try {
      final cached =
          LocalStorageService.getBranchDayCache(branchId, dayKey, 'dispensary');
      if (cached != null) return cached;
      final docs = await _fetchDispensaryDocsForDay(dayKey);
      await LocalStorageService.putBranchDayCache(
          branchId, dayKey, 'dispensary', docs);
      return docs;
    } catch (e, stack) {
      print('[DispensaryNotifier] _fetchDispensaryDocsCached error: $e');
      try {
        final file = io.File('e:/GMWF/gmwf/debug_branches.txt');
        await file.writeAsString('\n=== ERROR IN _fetchDispensaryDocsCached ===\n$e\n$stack\n', mode: io.FileMode.append);
      } catch (_) {}
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchDispensaryDocsForDay(
      String dayKey) async {
    if (branchId != 'all' && branchId != 'global') {
      return _fetchDispensaryDocsForBranch(dayKey, branchId);
    }

    final branchIds = <String>{};
    // Seed with all known registered local branches
    for (final b in _getLocalBranchesList(null)) {
      final id = (b['id'] ?? '').toString().toLowerCase().trim();
      if (id.isNotEmpty && id != 'all' && id != 'global') {
        branchIds.add(id);
      }
    }
    branchIds.addAll(['karachi', 'gujrat', 'sialkot', 'rawalpindi', 'jalalpur_jattan']);

    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.any((r) => r != ConnectivityResult.none)) {
        final snap = await FirebaseFirestore.instance
            .collection('branches')
            .get()
            .timeout(const Duration(seconds: 4));
        branchIds.addAll(snap.docs.map((d) => d.id.toLowerCase().trim()));
      }
    } catch (_) {}

    if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
      final box = Hive.box(LocalStorageService.dispensaryBox);
      for (final value in box.values) {
        if (value is Map) {
          final id = value['branchId']?.toString().toLowerCase().trim() ?? '';
          if (id.isNotEmpty && id != 'all' && id != 'global') branchIds.add(id);
        }
      }
    }

    final results = await Future.wait(
      branchIds.where((id) => id != 'all' && id != 'global').map(
            (id) => _fetchDispensaryDocsForBranch(dayKey, id),
          ),
    );
    final merged = <String, Map<String, dynamic>>{};
    for (final records in results) {
      for (final record in records) {
        final serial = (record['serial'] ?? record['id'] ?? '').toString().trim().toLowerCase();
        final key = '${record['branchId'] ?? ''}|$serial';
        if (serial.isNotEmpty) merged[key] = record;
      }
    }
    return merged.values.toList();
  }

  Future<List<Map<String, dynamic>>> _fetchDispensaryDocsForBranch(
      String dayKey, String targetBranchId) async {
    final Map<String, Map<String, dynamic>> combined = {};
    final activeStatuses = {
      'waiting',
      'pending',
      'prescribed',
      'completed',
      'dispensed',
      'waiting_to_dispense',
      'waiting_for_dispense'
    };

    bool isMatchingBranch(String docBranchId, String targetId, String serial) {
      final b1 = docBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      final b2 = targetId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
      if (b2 == 'all' || b2 == 'global' || b2.isEmpty) return true;

      final sUpper = serial.toUpperCase();
      if (b2 == 'karachi' || b2.contains('karachi') || b2.contains('saddar') || b2.contains('haji')) {
        if (b1.contains('karachi') || b1.contains('haji') || b1.contains('saddar') || b1.contains('kap')) return true;
        if (sUpper.contains('SADD') || sUpper.contains('HAJI') || sUpper.contains('KAP') || sUpper.contains('HC')) return true;
      }
      if (b2.contains('gujrat') || b2 == 'grt' || b2 == 'gjt') {
        if (b1.contains('gujrat') || b1.contains('grt') || b1.contains('gjt')) return true;
        if (sUpper.contains('GRT') || sUpper.contains('GJT')) return true;
      }
      if (b2.contains('sialkot') || b2 == 'skt') {
        if (b1.contains('sialkot') || b1.contains('skt')) return true;
        if (sUpper.contains('SKT')) return true;
      }
      if (b2.contains('jalalpur') || b2 == 'jlj') {
        if (b1.contains('jalalpur') || b1.contains('jlj') || b1.contains('jpj')) return true;
        if (sUpper.contains('JLJ') || sUpper.contains('JPJ')) return true;
      }
      if (b2.contains('rawalpindi') || b2 == 'rwp') {
        if (b1.contains('rawalpindi') || b1.contains('rwp')) return true;
        if (sUpper.contains('RWP')) return true;
      }
      if (b1.isEmpty) {
        return b2 == 'karachi';
      }
      return b1 == b2 || b1.contains(b2) || b2.contains(b1);
    }

    String cleanSerialKey(String raw) {
      var s = raw.trim().toLowerCase();
      for (final prefix in [
        'karachi-',
        'gujrat-',
        'sialkot-',
        'rawalpindi-',
        'grt-',
        'skt-',
        'rwp-',
      ]) {
        if (s.startsWith(prefix)) {
          s = s.substring(prefix.length);
          break;
        }
      }
      if (s.contains('_')) {
        final p = s.split('_');
        if (p.length > 2 &&
            (p[0] == 'karachi' || p[0] == 'gujrat' || p[0] == 'sialkot')) {
          s = p.sublist(2).join('_');
        }
      }
      return s;
    }

    String getNumericSuffix(String raw) {
      final parts = raw.trim().split(RegExp(r'[-_]'));
      return parts.isNotEmpty ? parts.last.toLowerCase() : raw.toLowerCase();
    }

    void mergeIntoCombined(Map<String, dynamic> incoming, {String? keyHint}) {
      final rawS = (incoming['serial'] ?? incoming['id'] ?? keyHint ?? '').toString().trim().toLowerCase();
      if (rawS.isEmpty) return;
      final cleanS = cleanSerialKey(rawS);
      final numSuffix = getNumericSuffix(cleanS);

      // Find if an existing entry matches exact serial or numeric suffix with same camp
      String targetKey = cleanS;
      if (!combined.containsKey(targetKey)) {
        for (final k in combined.keys) {
          if (k == cleanS || k.endsWith('-$cleanS') || cleanS.endsWith('-$k')) {
            targetKey = k;
            break;
          }
          if (numSuffix.isNotEmpty && numSuffix.length >= 2) {
            final kSuffix = getNumericSuffix(k);
            if (kSuffix == numSuffix) {
              final kIsSadd = k.contains('sadd');
              final sIsSadd = cleanS.contains('sadd');
              final kIsHaji = k.contains('haji');
              final sIsHaji = cleanS.contains('haji');
              if ((kIsSadd && sIsSadd) || (kIsHaji && sIsHaji) || (!kIsSadd && !kIsHaji && !sIsSadd && !sIsHaji)) {
                targetKey = k;
                break;
              }
            }
          }
        }
      }

      final existing = combined[targetKey];
      if (existing == null) {
        combined[targetKey] = Map<String, dynamic>.from(incoming);
      } else {
        final merged = Map<String, dynamic>.from(existing);
        incoming.forEach((k, v) {
          if (v == null || v == '') return;
          final strV = v.toString().trim();
          final isIncomingUnknown = strV.toLowerCase() == 'unknown' || strV.toLowerCase() == 'unknown patient';
          final existingVal = merged[k];
          final existingStr = existingVal?.toString().trim() ?? '';
          final isExistingUnknown = existingVal == null || existingStr.isEmpty || existingStr.toLowerCase() == 'unknown' || existingStr.toLowerCase() == 'unknown patient';

          if (isExistingUnknown && !isIncomingUnknown) {
            merged[k] = v;
          } else if (existingVal == null || existingStr.isEmpty) {
            merged[k] = v;
          }
        });
        final exSerial = (merged['serial'] ?? '').toString();
        final inSerial = (incoming['serial'] ?? '').toString();
        if (inSerial.length > exSerial.length) {
          merged['serial'] = inSerial;
        }
        combined[targetKey] = merged;
      }
    }

    // 1. Cached day records
    try {
      final cached = LocalStorageService.getBranchDayCache(targetBranchId, dayKey, 'dispensary');
      if (cached != null) {
        for (final d in cached) {
          final map = Map<String, dynamic>.from(d);
          map['branchId'] ??= targetBranchId;
          mergeIntoCombined(map);
        }
      }
    } catch (_) {}

    // 2. Local entriesBox (receptionist registered patient entries with full patient data)
    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        for (final k in eBox.keys) {
          final val = eBox.get(k);
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
            final s = (d['serial'] ?? k).toString();
            final dk = (d['dateKey'] ?? '').toString().trim();
            final status = (d['dispenseStatus'] ?? d['status'] ?? '').toString().toLowerCase().trim();
            final matchBranch = isMatchingBranch(b, targetBranchId, s);
            if (matchBranch && dk == dayKey && (status.isEmpty || activeStatuses.contains(status) || status.contains('waiting') || status.contains('prescribed') || status.contains('dispensed'))) {
              mergeIntoCombined(d, keyHint: k.toString());
            }
          }
        }
      }
    } catch (_) {}

    // 3. Local dispensaryBox (dispense records)
    try {
      if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
        final dBox = Hive.box(LocalStorageService.dispensaryBox);
        for (final k in dBox.keys) {
          final val = dBox.get(k);
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            d['branchId'] ??= targetBranchId;
            final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
            final s = (d['serial'] ?? k).toString();
            final dk = (d['dateKey'] ?? d['date'] ?? '').toString().trim();
            final matchBranch = isMatchingBranch(b, targetBranchId, s);
            if (matchBranch && (dk == dayKey || dk.isEmpty)) {
              mergeIntoCombined(d, keyHint: k.toString());
            }
          }
        }
      }
    } catch (_) {}

    // 4. Local prescriptionsBox (clinical consultation records & vitals)
    try {
      if (Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
        final pBox = Hive.box(LocalStorageService.prescriptionsBox);
        for (final k in pBox.keys) {
          final val = pBox.get(k);
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
            final s = (d['serial'] ?? k).toString();
            final dk = (d['dateKey'] ?? d['date'] ?? '').toString().trim();
            final matchBranch = isMatchingBranch(b, targetBranchId, s);
            if (matchBranch && (dk == dayKey || dk.isEmpty)) {
              mergeIntoCombined(d, keyHint: k.toString());
            }
          }
        }
      }
    } catch (_) {}

    // 5. Enrich missing patient demographics from local_patients (patientsBox)
    try {
      if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        final patBox = Hive.box(LocalStorageService.patientsBox);
        for (final entry in combined.values) {
          final pName = (entry['patientName'] ?? entry['name'] ?? '').toString().trim();
          final isUnknown = pName.isEmpty || pName.toLowerCase() == 'unknown' || pName.toLowerCase() == 'unknown patient';
          if (isUnknown) {
            final pCnic = (entry['patientCnic'] ?? entry['cnic'] ?? entry['guardianCnic'] ?? '').toString().replaceAll('-', '').replaceAll(' ', '').trim();
            final pId = (entry['patientId'] ?? entry['id'] ?? '').toString().trim();
            Map<String, dynamic>? foundPatient;
            if (pCnic.isNotEmpty && pCnic != '0000000000000' && patBox.containsKey(pCnic)) {
              final raw = patBox.get(pCnic);
              if (raw is Map) foundPatient = Map<String, dynamic>.from(raw);
            }
            if (foundPatient == null && pId.isNotEmpty && patBox.containsKey(pId)) {
              final raw = patBox.get(pId);
              if (raw is Map) foundPatient = Map<String, dynamic>.from(raw);
            }
            if (foundPatient != null) {
              entry['patientName'] ??= foundPatient['name'] ?? foundPatient['patientName'];
              entry['name'] ??= foundPatient['name'] ?? foundPatient['patientName'];
              entry['patientCnic'] ??= foundPatient['cnic'] ?? foundPatient['patientCnic'];
              entry['cnic'] ??= foundPatient['cnic'] ?? foundPatient['patientCnic'];
              entry['patientPhone'] ??= foundPatient['phone'] ?? foundPatient['contactPhone'];
              entry['phone'] ??= foundPatient['phone'] ?? foundPatient['contactPhone'];
              entry['age'] ??= foundPatient['age'] ?? foundPatient['patientAge'];
              entry['gender'] ??= foundPatient['gender'] ?? foundPatient['patientGender'];
            }
          }
        }
      }
    } catch (_) {}

    // 6. Network sync with Firestore to fill in any online registered tokens / remote updates
    try {
      if (QuotaService.isQuotaExhausted) {
        return combined.values.toList();
      }

      final fetchKey = '$targetBranchId-$dayKey';
      final lastFetch = _lastFirestoreFetch[fetchKey];
      final isRecentlyFetched = lastFetch != null &&
          DateTime.now().difference(lastFetch).inSeconds < 120;
      final hasUnknownPatients = combined.values.any((e) {
        final name = (e['patientName'] ?? e['name'] ?? '').toString().trim().toLowerCase();
        return name.isEmpty || name == 'unknown' || name == 'unknown patient';
      });

      // Quota Protection: If all patient data is already locally known and complete,
      // and we checked Firestore within the last 2 minutes, avoid unnecessary reads.
      if (isRecentlyFetched && !hasUnknownPatients && combined.isNotEmpty) {
        return combined.values.toList();
      }

      final connectivity = await Connectivity().checkConnectivity();
      final hasNetwork = connectivity.any((r) => r != ConnectivityResult.none);
      if (hasNetwork) {
        _lastFirestoreFetch[fetchKey] = DateTime.now();
        // Standalone branches check: Gujrat might be stored in Firestore as 'gujrat' or 'grt', Sialkot as 'sialkot' or 'skt'
        final candidateBranches = <String>{};
        if (targetBranchId.isEmpty || targetBranchId == 'all') {
          candidateBranches.addAll(['karachi', 'gujrat', 'sialkot', 'rawalpindi', 'jalalpur_jattan']);
        } else {
          final t = targetBranchId.toLowerCase().trim();
          candidateBranches.add(t);
          if (t == 'gujrat' || t == 'grt' || t == 'gjt') {
            candidateBranches.addAll(['gujrat', 'grt']);
          } else if (t == 'sialkot' || t == 'skt') {
            candidateBranches.addAll(['sialkot', 'skt']);
          } else if (t == 'rawalpindi' || t == 'rwp') {
            candidateBranches.addAll(['rawalpindi', 'rwp']);
          } else if (t == 'jalalpur_jattan' || t == 'jalalpur' || t == 'jlj') {
            candidateBranches.addAll(['jalalpur_jattan', 'jalalpur', 'jlj']);
          }
        }

        final queues = ['zakat', 'non-zakat', 'gmwf'];
        final List<QueryDocumentSnapshot<Map<String, dynamic>>> allFetchedDocs = [];

        for (final firestoreBranch in candidateBranches) {
          final dateDocIds = CampSessionService.getAllCampDateDocIds(
            branchId: firestoreBranch,
            dateKey: dayKey,
          );
          final serialDocs = await Future.wait<List<QueryDocumentSnapshot<Map<String, dynamic>>>>([
            for (final dateDocId in dateDocIds)
              for (final q in queues)
                FirebaseFirestore.instance
                    .collection('branches/$firestoreBranch/serials/$dateDocId/$q')
                    .get()
                    .timeout(const Duration(seconds: 4))
                    .then((snap) => snap.docs)
                    .catchError((e) {
                      if (QuotaService.isQuotaError(e)) {
                        QuotaService.recordQuotaExceeded(error: e);
                      }
                      return <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                    }),
          ]);
          for (final docs in serialDocs) {
            allFetchedDocs.addAll(docs);
          }
        }

        bool newlyDownloaded = false;
        for (final doc in allFetchedDocs) {
          final d = Map<String, dynamic>.from(doc.data());
          d['id'] = doc.id;
          d['branchId'] ??= targetBranchId;
          final status = (d['status'] ?? d['dispenseStatus'] ?? '').toString().toLowerCase().trim();
          final isDeleted = d['isDeleted'] == true ||
              status == 'deleted' ||
              status == 'void' ||
              status == 'cancelled';
          if (!isDeleted) {
            mergeIntoCombined(d, keyHint: doc.id);
            newlyDownloaded = true;

            // DOWNLOAD ONCE & PERSIST: Cache into local entriesBox so future reads use local Hive
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final eBox = Hive.box(LocalStorageService.entriesBox);
                final s = (d['serial'] ?? doc.id).toString().trim();
                final b = (d['branchId'] ?? targetBranchId).toString().toLowerCase().trim();
                if (s.isNotEmpty) {
                  final eKey = '$b-$s';
                  final existing = eBox.get(eKey);
                  if (existing is Map) {
                    final mergedE = Map<String, dynamic>.from(existing);
                    d.forEach((k, v) {
                      if (v != null && v.toString().isNotEmpty) mergedE[k] = v;
                    });
                    eBox.put(eKey, mergedE);
                  } else {
                    eBox.put(eKey, d);
                  }
                }
              }
            } catch (_) {}
          }
        }

        // Cache the full day's results locally in Hive so repeat queries hit 0 quota
        if (newlyDownloaded) {
          await LocalStorageService.putBranchDayCache(
            targetBranchId,
            dayKey,
            'dispensary',
            combined.values.toList(),
          );
        }
      }
    } catch (e) {
      if (QuotaService.isQuotaError(e)) {
        QuotaService.recordQuotaExceeded(error: e);
      }
    }

    return combined.values.toList();
  }

  // ── Static utility helpers ──────────────────────────────────────────────────

  static List<String> _dateStrings(DateTime start, DateTime end) {
    final df = DateFormat('ddMMyy');
    final days = <String>[];
    for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
      days.add(df.format(d));
    }
    return days;
  }

  static DateTime _parseDispensedAt(dynamic raw, String dateKeyFallback) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is String && raw.isNotEmpty) {
      try {
        return DateTime.parse(raw);
      } catch (_) {}
    }
    try {
      return LocalStorageService.parseDdMMyy(dateKeyFallback);
    } catch (_) {
      return DateTime.now();
    }
  }

  static String _resolvePatientId(Map<String, dynamic> data) {
    for (final key in ['patientId', 'id', 'uid']) {
      final v = data[key]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  static String _resolveType(Map<String, dynamic> data) {
    final raw =
        (data['queueType'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    switch (raw) {
      case 'zakat':
        return 'zakat';
      case 'non-zakat':
        return 'non-zakat';
      case 'gmwf':
        return 'gmwf';
      default:
        return 'Unknown';
    }
  }

  static List<Map<String, dynamic>> _fallbackEnrich(
      List<Map<String, dynamic>> rawDocs) {
    String firstNonEmpty(List<dynamic> candidates) {
      for (final c in candidates) {
        final s = c?.toString().trim() ?? '';
        if (s.isNotEmpty && s != 'null' && s != 'N/A') return s;
      }
      return '';
    }

    return rawDocs.map((d) => {
          ...d,
          'name': firstNonEmpty(
              [d['patientName'], d['name'], 'Unknown']),
          'phone': d['phone']?.toString() ?? 'N/A',
          'age': d['age']?.toString() ??
              d['patientAge']?.toString() ??
              'N/A',
          'gender': d['gender']?.toString() ??
              d['patientGender']?.toString() ??
              'N/A',
          'displayCnic': firstNonEmpty([
            d['patientCnic'],
            d['cnic'],
            d['guardianCnic'],
            'N/A',
          ]),
          'isChild':
              (d['guardianCnic'] ?? '').toString().isNotEmpty &&
                  (d['patientCnic'] ?? d['cnic'] ?? '').toString().isEmpty,
          'doctorName': firstNonEmpty(
              [d['doctorName'], d['prescribedBy'], 'Unknown']),
          'dispenserName': firstNonEmpty(
              [d['dispenserName'], d['dispensedBy'], 'Unknown']),
          'tokenBy': firstNonEmpty(
              [d['createdByName'], d['tokenBy'], d['createdBy'], 'Unknown']),
          'daysOfMedicine':
              (d['daysOfMedicine'] as num?)?.toInt() ?? 1,
          'frequentFlag': d['frequentFlag'] ?? false,
        }).toList();
  }
}

/// Family provider: one [DispensaryNotifier] per branchId.
final dispensaryProvider = AutoDisposeNotifierProviderFamily<DispensaryNotifier,
    DispensaryState, String>(DispensaryNotifier.new);

/// Streams the serials count summary for a given branchId, automatically
/// reacting to date range, sub-dispensary, and shift changes.
final serialsSummaryProvider = StreamProvider.family<Map<String, int>, String>((ref, branchId) {
  final dateRange = ref.watch(branchDateRangeProvider);
  final subFilter = ref.watch(branchSubDispensaryFilterProvider);
  final shiftFilter = ref.watch(branchShiftFilterProvider);
  
  // Calculate effectiveStart and effectiveEnd
  final DateTime effectiveStart;
  final DateTime effectiveEnd;
  if (dateRange.start != null && dateRange.end != null) {
    effectiveStart = dateRange.start!;
    effectiveEnd = dateRange.end!.add(const Duration(days: 1));
  } else {
    final now = DateTime.now();
    effectiveStart = DateTime(now.year, now.month, now.day);
    effectiveEnd = DateTime(now.year, now.month, now.day + 1);
  }
  
  return serialsCountStream(
    branchId, 
    effectiveStart, 
    effectiveEnd, 
    subDispensary: subFilter,
    shift: shiftFilter,
  );
});

/// Streams the full breakdown matrix (Saddar vs Haji Camp, Day vs Night) for executive comparison.
final facilityShiftBreakdownProvider = StreamProvider.family<Map<String, Map<String, int>>, String>((ref, branchId) {
  final dateRange = ref.watch(branchDateRangeProvider);
  final DateTime effectiveStart;
  final DateTime effectiveEnd;
  if (dateRange.start != null && dateRange.end != null) {
    effectiveStart = dateRange.start!;
    effectiveEnd = dateRange.end!.add(const Duration(days: 1));
  } else {
    final now = DateTime.now();
    effectiveStart = DateTime(now.year, now.month, now.day);
    effectiveEnd = DateTime(now.year, now.month, now.day + 1);
  }

  return facilityShiftBreakdownStream(branchId, effectiveStart, effectiveEnd);
});
