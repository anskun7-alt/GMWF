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
    } catch (e, stack) {
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
          if (id.isNotEmpty) branchIds.add(id);
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

    // 1. Local-first search: prefer Hive / cached data before any network fetch.
    try {
      final cached = LocalStorageService.getBranchDayCache(targetBranchId, dayKey, 'dispensary');
      if (cached != null) {
        for (final d in cached) {
          final map = Map<String, dynamic>.from(d);
          map['branchId'] ??= targetBranchId;
          final s = (map['serial'] ?? map['id'] ?? '').toString().trim().toLowerCase();
          if (s.isNotEmpty) combined[s] = map;
        }
      }
    } catch (_) {}

    try {
      if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
        final dBox = Hive.box(LocalStorageService.dispensaryBox);
        for (final k in dBox.keys) {
          final val = dBox.get(k);
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            d['branchId'] ??= targetBranchId;
            final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
            final dk = (d['dateKey'] ?? d['date'] ?? '').toString().trim();
            final matchBranch = targetBranchId == 'all' || targetBranchId.isEmpty || b == targetBranchId || b.isEmpty;
            if (matchBranch && (dk == dayKey || dk.isEmpty)) {
              final s = (d['serial'] ?? d['id'] ?? k).toString().trim().toLowerCase();
              if (s.isNotEmpty && !combined.containsKey(s)) combined[s] = d;
            }
          }
        }
      }
    } catch (_) {}

    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        for (final k in eBox.keys) {
          final val = eBox.get(k);
          if (val is Map) {
            final d = Map<String, dynamic>.from(val);
            final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
            final dk = (d['dateKey'] ?? '').toString().trim();
            final status = (d['dispenseStatus'] ?? d['status'] ?? '').toString().toLowerCase().trim();
            final matchBranch = targetBranchId == 'all' || targetBranchId.isEmpty || b == targetBranchId || b.isEmpty;
            if (matchBranch && dk == dayKey && (status.isEmpty || activeStatuses.contains(status) || status.contains('waiting') || status.contains('prescribed') || status.contains('dispensed'))) {
              final s = (d['serial'] ?? d['id'] ?? k).toString().trim().toLowerCase();
              final parts = s.split('-');
              final canonical = parts.length > 2 ? '${parts[1]}-${parts[2]}' : (parts.length > 1 ? '${parts[0]}-${parts[1]}' : s);
                final existingKey = combined.containsKey(s)
                  ? s
                  : (combined.containsKey(canonical) ? canonical : s);
                final existing = combined[existingKey];
                combined[existingKey] = {...?existing, ...d};
            }
          }
        }
      }
    } catch (_) {}

    // If local data is already populated, return it without hitting Firestore
    if (combined.isNotEmpty) {
      return combined.values.toList();
    }

    final connectivity = await Connectivity().checkConnectivity();
    final hasNetwork = connectivity.any((r) => r != ConnectivityResult.none);
    if (!hasNetwork) {
      return combined.values.toList();
    }

    // 2. FALLBACK: Only fetch remote data when local data is completely empty.
    final firestoreBranch = (targetBranchId.isEmpty || targetBranchId == 'all') ? 'karachi' : targetBranchId;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches/$firestoreBranch/dispensary/$dayKey/$dayKey')
          .get()
          .timeout(const Duration(seconds: 4));
      for (final doc in snap.docs) {
        final d = Map<String, dynamic>.from(doc.data());
        d['id'] = doc.id;
        d['branchId'] ??= firestoreBranch;
        final s = (d['serial'] ?? doc.id).toString().trim().toLowerCase();
        if (s.isNotEmpty && !combined.containsKey(s)) combined[s] = d;
      }
    } catch (_) {}

    try {
      final queues = ['zakat', 'non-zakat', 'gmwf'];
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
                .timeout(const Duration(seconds: 3))
                .then((snap) => snap.docs)
                .catchError((_) => <QueryDocumentSnapshot<Map<String, dynamic>>>[]),
      ]);
      for (final docs in serialDocs) {
        for (final doc in docs) {
          final d = Map<String, dynamic>.from(doc.data());
          d['id'] = doc.id;
          d['branchId'] ??= targetBranchId;
          final status = (d['status'] ?? d['dispenseStatus'] ?? '').toString().toLowerCase().trim();
          final s = (d['serial'] ?? doc.id).toString().trim().toLowerCase();
          final isDeleted = d['isDeleted'] == true ||
              status == 'deleted' ||
              status == 'void' ||
              status == 'cancelled';
          if (s.isNotEmpty &&
              !isDeleted) {
            combined[s] = {...?combined[s], ...d};
          }
        }
      }
    } catch (_) {}

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
