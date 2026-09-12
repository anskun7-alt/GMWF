// lib/services/branch_record_service.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'local_storage_service.dart';

class SingleRecord {
  final int count;
  final String dateKey;
  final String dateFormatted;
  final bool isToday;

  const SingleRecord({
    this.count = 0,
    this.dateKey = '',
    this.dateFormatted = '',
    this.isToday = false,
  });

  Map<String, dynamic> toMap() => {
    'count': count,
    'dateKey': dateKey,
    'dateFormatted': dateFormatted,
  };

  factory SingleRecord.fromMap(Map<String, dynamic>? map, {bool isToday = false}) {
    if (map == null) return const SingleRecord();
    return SingleRecord(
      count: (map['count'] as num?)?.toInt() ?? 0,
      dateKey: (map['dateKey'] ?? '').toString(),
      dateFormatted: (map['dateFormatted'] ?? '').toString(),
      isToday: isToday,
    );
  }
}

class BranchRecordData {
  final String branchId;
  final SingleRecord peakRecord;
  final int todayTotal;
  final bool isNewRecordToday;

  const BranchRecordData({
    required this.branchId,
    this.peakRecord = const SingleRecord(),
    this.todayTotal = 0,
    this.isNewRecordToday = false,
  });
}

class BranchRecordService {
  static final Map<String, BranchRecordData> _memoryCache = {};
  static final Set<String> _pendingAsyncComputes = {};
  static DateTime? _lastComputeTime;

  /// Formats dateKey 'ddMMyy' (e.g. 240826) or ISO '2026-08-24' into '24-Aug-2026'
  static String formatDateKey(String dk) {
    if (dk.isEmpty) return '';
    if (dk.length == 6 && RegExp(r'^\d{6}$').hasMatch(dk)) {
      try {
        final day = int.parse(dk.substring(0, 2));
        final month = int.parse(dk.substring(2, 4));
        final year = 2000 + int.parse(dk.substring(4, 6));
        final dt = DateTime(year, month, day);
        return DateFormat('dd-MMM-yyyy').format(dt);
      } catch (_) {}
    }
    try {
      final dt = DateTime.tryParse(dk);
      if (dt != null) {
        return DateFormat('dd-MMM-yyyy').format(dt);
      }
    } catch (_) {}
    return dk;
  }

  static bool _isMatchingBranch(String docBranchId, String targetBranchId, String serial) {
    final b1 = docBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
    final b2 = targetBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
    if (b2 == 'all' || b2 == 'global' || b2.isEmpty) return true;

    final sUpper = serial.toUpperCase();
    if (b2 == 'karachi' || b2.contains('karachi') || b2.contains('saddar') || b2.contains('haji')) {
      if (b1.contains('karachi') || b1.contains('haji') || b1.contains('saddar') || b1.contains('kap')) return true;
      if (sUpper.contains('SADD') || sUpper.contains('HAJI') || sUpper.contains('KAP') || sUpper.contains('HC')) return true;
      if (b1.isEmpty) return true;
    }
    if (b2.contains('gujrat')) {
      if (b1.contains('gujrat') || b1.contains('grt')) return true;
      if (sUpper.contains('GRT') || sUpper.contains('GJT')) return true;
    }
    if (b2.contains('jalalpur')) {
      if (b1.contains('jalalpur') || b1.contains('jlj') || b1.contains('jpj')) return true;
      if (sUpper.contains('JLJ') || sUpper.contains('JPJ')) return true;
    }
    if (b2.contains('sialkot')) {
      if (b1.contains('sialkot') || b1.contains('skt')) return true;
      if (sUpper.contains('SKT')) return true;
    }
    if (b1.isEmpty) return true;
    return b1 == b2 || b1.contains(b2) || b2.contains(b1);
  }

  static bool _isMatchingCamp(String rawCamp, String serial, String? targetCamp) {
    if (targetCamp == null || targetCamp.isEmpty || targetCamp == 'all') return true;
    final t = targetCamp.toLowerCase().trim();
    final c = rawCamp.toLowerCase().trim();
    final sUpper = serial.toUpperCase();

    if (t.contains('saddar') || t.contains('kap') || t == 'sadd') {
      return c.contains('saddar') || c.contains('kap') || c == 'sadd' ||
          sUpper.contains('SADD') || sUpper.contains('SAD') || sUpper.contains('KAP');
    }
    if (t.contains('haji') || t == 'hc') {
      return c.contains('haji') || c == 'hc' ||
          sUpper.contains('HAJI') || sUpper.contains('HC');
    }
    return c == t || c.contains(t) || t.contains(c);
  }

  /// Retrieves the all-time peak single-day record for this dispensary/branch/camp.
  /// Uses the permanently open `branch_data_cache` Hive box (0ms, 0 RAM scan).
  /// Never requires the heavy `local_entries` box to remain open.
  static BranchRecordData getBranchRecords(
    String branchId, {
    String? campId,
    int? todayCount,
  }) {
    final normBranch = branchId.toLowerCase().trim();
    final normCamp = (campId != null && campId.isNotEmpty && campId != 'all') ? campId.toLowerCase().trim() : null;
    final cacheKey = '$normBranch|${normCamp ?? 'all'}';
    final peakStorageKey = 'branch_peak_record_$cacheKey';
    final todayDk = DateFormat('ddMMyy').format(DateTime.now());
    final todayFormatted = DateFormat('dd-MMM-yyyy').format(DateTime.now());

    final now = DateTime.now();

    // 1. Try fast in-memory cache first if recent
    if (_memoryCache.containsKey(cacheKey) &&
        _lastComputeTime != null &&
        now.difference(_lastComputeTime!).inSeconds < 15) {
      final cachedData = _memoryCache[cacheKey]!;
      // If todayCount is higher than cached data, update it dynamically
      if (todayCount != null && todayCount > cachedData.todayTotal) {
        return _applyTodayCount(normBranch, cacheKey, cachedData.peakRecord, todayCount, todayDk, todayFormatted);
      }
      return cachedData;
    }

    // 2. Read persistent peak from branch_data_cache (core box: permanently open, zero RAM penalty)
    SingleRecord? storedPeak;
    try {
      if (Hive.isBoxOpen(LocalStorageService.branchCacheBox)) {
        final bBox = Hive.box(LocalStorageService.branchCacheBox);
        final raw = bBox.get(peakStorageKey);
        if (raw is Map) {
          storedPeak = SingleRecord.fromMap(Map<String, dynamic>.from(raw));
        }
      }
    } catch (_) {}

    // 3. If persistent peak exists in branch_data_cache, evaluate against today
    if (storedPeak != null && storedPeak.count > 0) {
      final effectiveToday = todayCount ?? 0;
      return _applyTodayCount(normBranch, cacheKey, storedPeak, effectiveToday, todayDk, todayFormatted);
    }

    // 4. If no persistent peak exists yet:
    // If local_entries is currently open, compute it synchronously once and persist.
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final computed = _computeFromOpenEntriesBox(normBranch, normCamp, todayDk, todayFormatted);
      _persistPeakToBranchCache(peakStorageKey, computed.peakRecord);
      _memoryCache[cacheKey] = computed;
      _lastComputeTime = now;
      return computed;
    }

    // 5. If local_entries is closed, trigger a one-time background async load
    _triggerAsyncCompute(normBranch, normCamp, cacheKey, peakStorageKey, todayDk, todayFormatted);

    // Provide immediate fallback with today's count if available
    final initialCount = todayCount ?? 0;
    final fallbackRecord = SingleRecord(
      count: initialCount,
      dateKey: initialCount > 0 ? todayDk : '',
      dateFormatted: initialCount > 0 ? '$todayFormatted (Today)' : '',
      isToday: initialCount > 0,
    );

    final fallbackResult = BranchRecordData(
      branchId: normBranch,
      peakRecord: fallbackRecord,
      todayTotal: initialCount,
      isNewRecordToday: initialCount > 0,
    );
    _memoryCache[cacheKey] = fallbackResult;
    return fallbackResult;
  }

  static BranchRecordData _applyTodayCount(
    String normBranch,
    String cacheKey,
    SingleRecord basePeak,
    int todayCount,
    String todayDk,
    String todayFormatted,
  ) {
    final isNewRecord = todayCount > 0 && todayCount >= basePeak.count && basePeak.count > 0;
    final peakMax = todayCount > basePeak.count ? todayCount : basePeak.count;
    final isTodayPeak = peakMax == todayCount && todayCount > 0;

    final finalPeak = SingleRecord(
      count: peakMax,
      dateKey: isTodayPeak ? todayDk : basePeak.dateKey,
      dateFormatted: isTodayPeak
          ? '$todayFormatted (Today)'
          : (basePeak.dateFormatted.isNotEmpty ? basePeak.dateFormatted : formatDateKey(basePeak.dateKey)),
      isToday: isTodayPeak,
    );

    final result = BranchRecordData(
      branchId: normBranch,
      peakRecord: finalPeak,
      todayTotal: todayCount,
      isNewRecordToday: isNewRecord,
    );

    // If today set a new record, persist to branch_data_cache
    if (isNewRecord || todayCount > basePeak.count) {
      _persistPeakToBranchCache('branch_peak_record_$cacheKey', finalPeak);
    }

    _memoryCache[cacheKey] = result;
    _lastComputeTime = DateTime.now();
    return result;
  }

  static void _persistPeakToBranchCache(String storageKey, SingleRecord record) {
    try {
      if (Hive.isBoxOpen(LocalStorageService.branchCacheBox)) {
        Hive.box(LocalStorageService.branchCacheBox).put(storageKey, record.toMap());
      }
    } catch (e) {
      debugPrint('[BranchRecordService] Error persisting peak: $e');
    }
  }

  static BranchRecordData _computeFromOpenEntriesBox(
    String normBranch,
    String? normCamp,
    String todayDk,
    String todayFormatted,
  ) {
    final box = Hive.box(LocalStorageService.entriesBox);
    final Map<String, int> dailyCounts = {};

    for (final val in box.values) {
      if (val is! Map) continue;
      final status = (val['status'] ?? '').toString().toLowerCase().trim();
      final syncStatus = (val['syncStatus'] ?? '').toString().toLowerCase().trim();
      if (status == 'deleted' || syncStatus == 'deleted' || status == 'void' || status == 'cancelled') continue;

      final bId = (val['branchId'] ?? '').toString().toLowerCase().trim();
      final serial = (val['serial'] ?? val['id'] ?? '').toString().trim();

      if (!_isMatchingBranch(bId, normBranch, serial)) continue;

      final camp = (val['dispensaryId'] ?? val['campId'] ?? val['subDispensaryId'] ?? val['dispensaryTag'] ?? '').toString();
      if (!_isMatchingCamp(camp, serial, normCamp)) continue;

      var dk = (val['dateKey'] ?? '').toString().trim();
      if (dk.isEmpty) {
        final rawCreated = val['createdAt'] ?? val['time'] ?? val['timestamp'] ?? val['date'];
        if (rawCreated != null) {
          final dt = DateTime.tryParse(rawCreated.toString());
          if (dt != null) {
            dk = DateFormat('ddMMyy').format(dt);
          }
        }
      }
      if (dk.isEmpty && serial.length >= 6) {
        final prefix = serial.split('-').first;
        if (prefix.length == 6 && RegExp(r'^\d{6}$').hasMatch(prefix)) {
          dk = prefix;
        }
      }
      if (dk.isEmpty) continue;

      dailyCounts[dk] = (dailyCounts[dk] ?? 0) + 1;
    }

    int peakMax = 0;
    String peakDk = '';
    for (final entry in dailyCounts.entries) {
      if (entry.value > peakMax) {
        peakMax = entry.value;
        peakDk = entry.key;
      }
    }

    final todayCount = dailyCounts[todayDk] ?? 0;
    final isNewRecord = todayCount > 0 && todayCount >= peakMax && peakMax > 0;

    final peakRecord = SingleRecord(
      count: peakMax,
      dateKey: peakDk,
      dateFormatted: peakDk == todayDk ? '$todayFormatted (Today)' : formatDateKey(peakDk),
      isToday: peakDk == todayDk,
    );

    return BranchRecordData(
      branchId: normBranch,
      peakRecord: peakRecord,
      todayTotal: todayCount,
      isNewRecordToday: isNewRecord,
    );
  }

  static void _triggerAsyncCompute(
    String normBranch,
    String? normCamp,
    String cacheKey,
    String storageKey,
    String todayDk,
    String todayFormatted,
  ) {
    if (_pendingAsyncComputes.contains(cacheKey)) return;
    _pendingAsyncComputes.add(cacheKey);

    unawaited(() async {
      try {
        final box = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
        final computed = _computeFromOpenEntriesBox(normBranch, normCamp, todayDk, todayFormatted);
        _persistPeakToBranchCache(storageKey, computed.peakRecord);
        _memoryCache[cacheKey] = computed;
        _lastComputeTime = DateTime.now();
      } catch (e) {
        debugPrint('[BranchRecordService] Async peak compute warning: $e');
      } finally {
        _pendingAsyncComputes.remove(cacheKey);
      }
    }());
  }

  /// Manually update peak if today's count exceeded the record.
  static void updateTodayPeakIfExceeded(
    String branchId,
    int todayCount, {
    String? campId,
  }) {
    if (todayCount <= 0) return;
    getBranchRecords(branchId, campId: campId, todayCount: todayCount);
  }

  static void invalidateCache() {
    _memoryCache.clear();
    _lastComputeTime = null;
  }
}
