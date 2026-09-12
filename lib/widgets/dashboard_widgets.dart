// lib/widgets/dashboard_widgets.dart
// ════════════════════════════════════════════════════════════════════════════════
// GMWF · Premium Dashboard Components — Production Redesign v3
// Design system: 8pt grid · Blue=primary · Green=money · Purple=donations
// All Material Icons (rounded) · Consistent stroke · No random colors
// ════════════════════════════════════════════════════════════════════════════════
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import 'package:rxdart/rxdart.dart';
import '../theme/app_theme.dart';
import '../services/donations_local_storage.dart';
import '../services/local_storage_service.dart';
import '../services/home_dashboard_service.dart';
import '../services/branch_record_service.dart';
import '../pages/donations/donations_shared.dart' as don;
import '../theme/role_theme_provider.dart';


// ── Design System Tokens ──────────────────────────────────────────────────────
class DS {
  // Spacing — strict 8pt grid
  static const double s1 = 8.0;
  static const double s2 = 16.0;
  static const double s3 = 24.0;
  static const double s4 = 32.0;

  // Semantic colors — Role Based Decisions
  static const Color zakat        = Color(0xFF16A34A); // Green — Zakat (Revenue/Money)
  static const Color nonZakat     = Color(0xFF2563EB); // Blue — Non-Zakat (Standard Operations)
  static const Color gmwf         = Color(0xFFEAB308); // Yellow — GMWF (Free/Internal)
  static const Color danger       = Color(0xFFDC2626); // Red — Alerts / Critical

  // UI Utilities
  static const Color blue        = Color(0xFF2563EB); 
  static const Color blueMuted   = Color(0xFFEFF6FF); 
  static const Color green       = Color(0xFF16A34A); 
  static const Color greenMuted  = Color(0xFFDCFCE7); 
  static const Color purple      = Color(0xFF7C3AED); 
  static const Color purpleMuted = Color(0xFFF5F3FF); 
  static const Color orange      = Color(0xFFEA580C); 
  static const Color orangeMuted = Color(0xFFFFF7ED); 
  static const Color neutral     = Color(0xFF6B7280); 
  static const Color neutralBg   = Color(0xFFF9FAFB); 
  static const Color border      = Color(0xFFE5E7EB); 

  // Typography sizes
  static const double h1 = 40.0;
  static const double h2 = 18.0;
  static const double body = 13.0;
  static const double caption = 11.0;

  // Corner radii
  static const double r1 = 8.0;
  static const double r2 = 16.0;
  static const double r3 = 20.0;
  static const double r4 = 24.0;
}

// ── Dashboard Filter System ──────────────────────────────────────────────────

enum TimeRange { today, yesterday, week, biweek, month, thisMonth, custom }

class DashboardFilter {
  final TimeRange timeRange;
  final String branchId; // 'all' or specific ID
  final String? patientType; // 'zakat', 'non-zakat', 'gmwf', null for all
  final bool multiDayMedicineOnly; // multi-day course (daysOfMedicine > 1)
  final DateTimeRange? customRange;

  const DashboardFilter({
    this.timeRange = TimeRange.today,
    this.branchId = 'all',
    this.patientType,
    this.multiDayMedicineOnly = false,
    this.customRange,
  });

  DashboardFilter copyWith({
    TimeRange? timeRange,
    String? branchId,
    String? patientType,
    bool? multiDayMedicineOnly,
    DateTimeRange? customRange,
  }) {
    return DashboardFilter(
      timeRange: timeRange ?? this.timeRange,
      branchId: branchId ?? this.branchId,
      patientType: patientType ?? this.patientType,
      multiDayMedicineOnly: multiDayMedicineOnly ?? this.multiDayMedicineOnly,
      customRange: customRange ?? this.customRange,
    );
  }
}

class DashboardController extends ValueNotifier<DashboardFilter> {
  DashboardController([DashboardFilter? value])
      : super(value ?? const DashboardFilter());

  void setTimeRange(TimeRange range) => value = value.copyWith(timeRange: range);
  void setBranch(String id) => value = value.copyWith(branchId: id);
  void setPatientType(String? type) => value = value.copyWith(patientType: type);
  void setMultiDayMedicineOnly(bool val) => value = value.copyWith(multiDayMedicineOnly: val);
  void toggleMultiDayMedicineOnly() => value = value.copyWith(multiDayMedicineOnly: !value.multiDayMedicineOnly);
  void setCustomRange(DateTimeRange range) =>
      value = value.copyWith(timeRange: TimeRange.custom, customRange: range);
  void resetFilters() => value = const DashboardFilter();
}

// Global instance for convenience, though preferred to pass via context or provider
final dashboardController = DashboardController();
String fmtPKR(int n) {
  if (n >= 10000000) return 'PKR ${(n / 10000000).toStringAsFixed(1)}Cr';
  if (n >= 100000)   return 'PKR ${(n / 100000).toStringAsFixed(1)}L';
  if (n >= 1000)     return 'PKR ${(n / 1000).toStringAsFixed(1)}K';
  return 'PKR $n';
}

String fmtNum(int n) {
  if (n >= 10000000) return '${(n / 10000000).toStringAsFixed(1)}Cr';
  if (n >= 100000)   return '${(n / 100000).toStringAsFixed(1)}L';
  if (n >= 1000)     return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

String fmtPKRDouble(double n) {
  if (n >= 10000000) return 'PKR ${(n / 10000000).toStringAsFixed(1)}Cr';
  if (n >= 100000)   return 'PKR ${(n / 100000).toStringAsFixed(1)}L';
  if (n >= 1000)     return 'PKR ${(n / 1000).toStringAsFixed(1)}K';
  return 'PKR ${n.toStringAsFixed(0)}';
}

// ── Firestore data model ──────────────────────────────────────────────────────
class BranchStats {
  final int zakat, nonZakat, gmwf, dasterkhwaan, dasterkhwaanServed,
      donations, dispensed, prescribed, dispensaryRevenue, employeeAttendance;
  final int zakatRevenue, nonZakatRevenue, gmwfRevenue;

  const BranchStats({
    this.zakat = 0, this.nonZakat = 0, this.gmwf = 0,
    this.dasterkhwaan = 0, this.dasterkhwaanServed = 0,
    this.donations = 0, this.dispensed = 0, this.prescribed = 0,
    this.dispensaryRevenue = 0,
    this.employeeAttendance = 0,
    this.zakatRevenue = 0, this.nonZakatRevenue = 0, this.gmwfRevenue = 0,
  });

  int get tokens          => zakat + nonZakat + gmwf;
  // Improved performance score: revenue-weighted + patient footprint + food service
  int get performanceScore => (totalRevenue ~/ 100) + tokens + dasterkhwaan;
  int get dasterkhwaanPending => (dasterkhwaan - dasterkhwaanServed).clamp(0, 9999);
  // int get dispensaryRevenue  => zakat * 20 + nonZakat * 100; // DEPRECATED: use field
  int get dasterkhwaanRevenue => dasterkhwaan * 10;
  int get totalRevenue => dispensaryRevenue + dasterkhwaanRevenue + donations;
}

DateTimeRange _resolveFilter(DashboardFilter? filter) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (filter == null) return DateTimeRange(start: today, end: today);
  switch (filter.timeRange) {
    case TimeRange.today:
      return DateTimeRange(start: today, end: today);
    case TimeRange.yesterday:
      final yest = today.subtract(const Duration(days: 1));
      return DateTimeRange(start: yest, end: yest);
    case TimeRange.week:
      return DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
    case TimeRange.biweek:
      return DateTimeRange(start: today.subtract(const Duration(days: 13)), end: today);
    case TimeRange.month:
      return DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today);
    case TimeRange.thisMonth:
      return DateTimeRange(start: DateTime(now.year, now.month, 1), end: today);
    case TimeRange.custom:
      return filter.customRange ?? DateTimeRange(start: today, end: today);
  }
}

// ── In-memory stats cache (5-minute TTL) ─────────────────────────────────────
// Prevents repeated Firestore reads when the overview rebuilds due to filter
// changes, tab switches, or ValueListenableBuilder refreshes.
_StatsCacheEntry? _statsCacheGet(String key) {
  final entry = _statsCache[key];
  if (entry == null) return null;
  if (DateTime.now().difference(entry.cachedAt) > const Duration(minutes: 5)) {
    _statsCache.remove(key);
    return null;
  }
  return entry;
}

void _statsCachePut(String key, BranchStats stats) {
  _statsCache[key] = _StatsCacheEntry(stats, DateTime.now());
}

void invalidateDashboardCache() => _statsCache.clear();

final Map<String, _StatsCacheEntry> _statsCache = {};

class _StatsCacheEntry {
  final BranchStats stats;
  final DateTime cachedAt;
  const _StatsCacheEntry(this.stats, this.cachedAt);
}

String _statsCacheKey(String branchId, DashboardFilter? filter) {
  final range = filter == null ? 'today' : filter.timeRange.name;
  final branch = branchId;
  final custom = filter?.customRange != null
      ? '_${filter!.customRange!.start.toIso8601String()}_${filter.customRange!.end.toIso8601String()}'
      : '';
  final pType = filter?.patientType != null ? '_${filter!.patientType}' : '';
  final multi = filter?.multiDayMedicineOnly == true ? '_multiDay' : '';
  return '$branch|$range$custom$pType$multi';
}

BranchStats? statsCacheGet(String key) => _statsCacheGet(key)?.stats;
String statsCacheKey(String branchId, DashboardFilter? filter) => _statsCacheKey(branchId, filter);

bool _isMatchingBranchLocal(String docBranchId, String targetBranchId) {
  final b1 = docBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
  final b2 = targetBranchId.toLowerCase().trim().replaceAll(' ', '_').replaceAll('-', '_');
  if (b2 == 'all' || b2 == 'global' || b2.isEmpty) return true;
  if (b1.isEmpty) {
    // If docBranchId is empty, default to matching karachi
    return b2 == 'karachi';
  }
  if (b1 == b2) return true;
  if (b2 == 'karachi') {
    return b1.contains('karachi') || b1.contains('haji') || b1.contains('kapaya') || b1.contains('saddar');
  }
  if (b2.contains('karachi') || b2.contains('haji') || b2.contains('saddar') || b2.contains('kapaya')) {
    if (b2.contains('haji')) return b1.contains('haji');
    if (b2.contains('saddar') || b2.contains('kapaya')) return b1.contains('saddar') || b1.contains('kapaya') || (b1 == 'karachi');
    return b1.contains('karachi');
  }
  return b1 == b2 || b1.contains(b2) || b2.contains(b1);
}

Future<BranchStats> fetchBranchStats(String originalBranchId, {DashboardFilter? filter}) async {
  final cacheKey = _statsCacheKey(originalBranchId, filter);
  final cached = _statsCacheGet(cacheKey);
  if (cached != null) {
    return cached.stats;
  }
  final range = _resolveFilter(filter);
  try {
    final branchId = originalBranchId.toLowerCase().trim();
    DateTime start = range.start;
    DateTime end = range.end;
    if (end.isBefore(start)) {
      final tmp = start;
      start = end;
      end = tmp;
    }

    if (end.difference(start).inDays > 90) {
      start = end.subtract(const Duration(days: 90));
    }

    final dayKeysDmyy = <String>{};
    final dayKeysYmd = <String>{};
    final dfDmyy = DateFormat('ddMMyy');
    final dfYmd = DateFormat('yyyy-MM-dd');
    final daysCount = end.difference(start).inDays;
    for (int i = 0; i <= daysCount; i++) {
      final d = start.add(Duration(days: i));
      dayKeysDmyy.add(dfDmyy.format(d));
      dayKeysYmd.add(dfYmd.format(d));
    }

    int z = 0, nz = 0, gm = 0, das = 0, served = 0, dispensed = 0, dispRev = 0;
    int zRev = 0, nzRev = 0, gmRev = 0;
    double donTotal = 0;

    final onlyMulti = filter?.multiDayMedicineOnly == true;
    final pType = filter?.patientType?.toLowerCase().replaceAll('-', '').replaceAll('_', '').trim();
    final isMatchAll = branchId.isEmpty || branchId == 'all' || branchId == 'global';

    // 1. Tokens & dispensary revenue from LocalStorageService.entriesBox
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final box = Hive.box(LocalStorageService.entriesBox);
      final Map<String, Map<String, dynamic>> entryMap = {};

      for (final k in box.keys) {
        final val = box.get(k);
        if (val is! Map) continue;
        final e = Map<String, dynamic>.from(val);
        final status = e['status']?.toString().toLowerCase();
        final syncStatus = e['syncStatus']?.toString().toLowerCase();
        if (status == 'deleted' || syncStatus == 'deleted' || status == 'void' || status == 'cancelled') continue;

        final b = (e['branchId'] as String? ?? '').toLowerCase().trim();
        if (!isMatchAll && !_isMatchingBranchLocal(b, branchId)) continue;

        final dk = e['dateKey']?.toString().trim() ?? '';
        final rawDate = e['createdAt'] ?? e['date'] ?? e['timestamp'];
        bool dateMatches = dayKeysDmyy.contains(dk) || dayKeysYmd.contains(dk);

        if (!dateMatches && rawDate != null) {
          DateTime? dt;
          if (rawDate is Timestamp) {
            dt = rawDate.toDate().toLocal();
          } else if (rawDate is DateTime) {
            dt = rawDate.toLocal();
          } else if (rawDate is int) {
            dt = DateTime.fromMillisecondsSinceEpoch(rawDate).toLocal();
          } else {
            final s = rawDate.toString().trim();
            for (final ymd in dayKeysYmd) {
              if (s.contains(ymd)) { dateMatches = true; break; }
            }
            if (!dateMatches) {
              for (final dmyy in dayKeysDmyy) {
                if (s.contains(dmyy)) { dateMatches = true; break; }
              }
            }
            if (!dateMatches) {
              dt = DateTime.tryParse(s)?.toLocal();
            }
          }
          if (!dateMatches && dt != null) {
            final dateOnly = DateTime(dt.year, dt.month, dt.day);
            dateMatches = !dateOnly.isBefore(start) && !dateOnly.isAfter(end);
          }
        }

        // Serial check fallback (e.g. 050926-SADD-010)
        if (!dateMatches) {
          final rawSerial = (e['serial'] ?? e['id'] ?? e['tokenNumber'] ?? k).toString().trim();
          for (final dmyy in dayKeysDmyy) {
            if (rawSerial.contains(dmyy)) { dateMatches = true; break; }
          }
        }

        if (!dateMatches) continue;

        final rawSerial = (e['serial'] ?? e['id'] ?? e['tokenNumber'] ?? k).toString().trim().toLowerCase();
        final parts = rawSerial.split('-');
        final sNum = parts.length > 1 ? parts.last : rawSerial;
        final canonicalKey = parts.length > 2
            ? '${parts[0]}-${parts[1]}-${parts[2]}'
            : (parts.length > 1 ? '${parts[0]}-${parts[1]}' : sNum);
        entryMap['$b|$dk|$canonicalKey'] = e;
      }

      for (final val in entryMap.values) {
        final rawType = (val['queueType'] ?? val['category'] ?? val['type'] ?? '').toString().toLowerCase();
        final normType = rawType.replaceAll('-', '').replaceAll('_', '').trim();
        final days = (val['daysOfMedicine'] as num?)?.toInt() ?? 1;
        final status = val['status']?.toString().toLowerCase();

        if (onlyMulti && days <= 1) continue;
        if (pType != null && pType.isNotEmpty && !normType.contains(pType)) continue;

        if (normType.contains('zakat') && !normType.contains('non')) {
          z++;
          final rev = 20 * days;
          dispRev += rev;
          zRev += rev;
        } else if (normType.contains('nonzakat') || normType.contains('non_zakat') || normType.contains('non')) {
          nz++;
          final rev = 100 * days;
          dispRev += rev;
          nzRev += rev;
        } else if (normType.contains('gmwf')) {
          gm++;
          final rev = 0 * days;
          dispRev += rev;
          gmRev += rev;
        } else if (normType.contains('dasterkhwan') || normType.contains('food') || normType.contains('rashan')) {
          das++;
        }

        if (status == 'dispensed' || status == 'completed') {
          dispensed++;
        }
      }
    }

    // 2. Dispensed counts from dispensary box
    if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
      final dispBox = Hive.box(LocalStorageService.dispensaryBox);
      int localDispCount = 0;
      for (final raw in dispBox.values) {
        if (raw is! Map) continue;
        final d = Map<String, dynamic>.from(raw);
        final b = (d['branchId'] as String? ?? '').toLowerCase().trim();
        if (!isMatchAll && !_isMatchingBranchLocal(b, branchId)) continue;
        final dk = d['dateKey']?.toString() ?? '';
        if (dayKeysDmyy.contains(dk) || dayKeysYmd.contains(dk)) {
          localDispCount++;
        }
      }
      if (localDispCount > dispensed) {
        dispensed = localDispCount;
      }
    }

    // 2b. Dasterkhwaan tokens (food tokens issued & served)
    if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
      final tokenBox = Hive.box(LocalStorageService.dasterkhwaanTokensBox);
      for (final raw in tokenBox.values) {
        if (raw is! Map) continue;
        final t = Map<String, dynamic>.from(raw);
        final b = (t['branchId'] as String? ?? '').toLowerCase().trim();
        if (!isMatchAll && !_isMatchingBranchLocal(b, branchId)) continue;
        final dk = t['dateKey']?.toString() ?? '';
        final rawDate = t['time'] ?? t['dateKey'] ?? t['timestamp'];
        bool matchesDate = dayKeysYmd.contains(dk) || dayKeysDmyy.contains(dk);
        if (!matchesDate && rawDate != null) {
          DateTime? dt;
          if (rawDate is Timestamp) dt = rawDate.toDate().toLocal();
          else if (rawDate is DateTime) dt = rawDate.toLocal();
          else if (rawDate is String) dt = DateTime.tryParse(rawDate)?.toLocal();
          if (dt != null) {
            final dateOnly = DateTime(dt.year, dt.month, dt.day);
            matchesDate = !dateOnly.isBefore(start) && !dateOnly.isAfter(end);
          }
        }
        if (matchesDate) {
          das++;
          if (t['served'] == true) {
            served++;
          }
        }
      }
    }

    // 3. Donations aggregation
    final donBoxName = Hive.isBoxOpen(LocalStorageService.donationsBox)
        ? LocalStorageService.donationsBox
        : (Hive.isBoxOpen(DonationsLocalStorage.donationsBox) ? DonationsLocalStorage.donationsBox : null);
    if (donBoxName != null) {
      final donBox = Hive.box(donBoxName);
      final seenReceipts = <String>{};
      for (final raw in donBox.values) {
        if (raw is! Map) continue;
        final val = Map<String, dynamic>.from(raw);
        final status = val['status']?.toString().toLowerCase();
        final syncStatus = val['syncStatus']?.toString().toLowerCase();
        if (status == 'deleted' || syncStatus == 'deleted') continue;

        final b = (val['branchId'] as String? ?? '').toLowerCase().trim();
        if (!isMatchAll && !_isMatchingBranchLocal(b, branchId)) continue;

        final rawDate = val['date'] ?? val['createdAt'] ?? val['timestamp'];
        bool matchesDate = false;
        if (rawDate != null) {
          DateTime? dt;
          if (rawDate is Timestamp) {
            dt = rawDate.toDate().toLocal();
          } else if (rawDate is DateTime) {
            dt = rawDate.toLocal();
          } else if (rawDate is int) {
            dt = DateTime.fromMillisecondsSinceEpoch(rawDate).toLocal();
          } else {
            final s = rawDate.toString().trim();
            for (final ymd in dayKeysYmd) {
              if (s.contains(ymd)) { matchesDate = true; break; }
            }
            if (!matchesDate) {
              for (final dmyy in dayKeysDmyy) {
                if (s.contains(dmyy)) { matchesDate = true; break; }
              }
            }
            if (!matchesDate) {
              dt = DateTime.tryParse(s)?.toLocal();
            }
          }
          if (!matchesDate && dt != null) {
            final dateOnly = DateTime(dt.year, dt.month, dt.day);
            matchesDate = !dateOnly.isBefore(start) && !dateOnly.isAfter(end);
          }
        }
        if (!matchesDate) continue;

        final payMethod = val['paymentMethod']?.toString().toLowerCase() ?? '';
        if (payMethod == 'bank_deposit') continue;

        final receiptNo = val['receiptNo']?.toString() ?? '';
        final clean = don.cleanReceiptNumber(receiptNo);
        if (clean.isNotEmpty && seenReceipts.contains(clean)) continue;
        if (clean.isNotEmpty) seenReceipts.add(clean);

        final amt = val['amount'];
        final amtDouble = (amt is num) ? amt.toDouble() : (double.tryParse(amt?.toString() ?? '0') ?? 0.0);
        donTotal += amtDouble;
      }
    }

    // 4. Fallback to branch day cache if tokens are empty
    if (z == 0 && nz == 0 && gm == 0 && das == 0) {
      try {
        final targetBranches = isMatchAll
            ? LocalStorageService.getLocalBranchesList().map((b) => b['id'] as String).toList()
            : [branchId];
        for (final b in targetBranches) {
          for (final dk in dayKeysDmyy) {
            final cachedDocs = LocalStorageService.getBranchDayCache(b, dk, 'dispensary');
            if (cachedDocs != null) {
              for (final val in cachedDocs) {
                final rawType = val['type']?.toString().toLowerCase() ?? '';
                final normType = rawType.replaceAll('-', '').replaceAll('_', '').trim();
                final days = (val['daysOfMedicine'] as num?)?.toInt() ?? 1;
                if (onlyMulti && days <= 1) continue;
                if (pType != null && pType.isNotEmpty && !normType.contains(pType)) continue;

                if (normType.contains('zakat') && !normType.contains('non')) {
                  z++;
                  final rev = 20 * days;
                  dispRev += rev;
                  zRev += rev;
                } else if (normType.contains('non')) {
                  nz++;
                  final rev = 100 * days;
                  dispRev += rev;
                  nzRev += rev;
                } else if (normType.contains('gmwf')) {
                  gm++;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    // 5. Local numbers are final (Pure local-first architecture — 0 Firestore reads)
    final result = BranchStats(
      zakat: z, nonZakat: nz, gmwf: gm,
      dispensed: dispensed, prescribed: 0,
      dasterkhwaan: das, dasterkhwaanServed: served, 
      donations: donTotal.toInt(),
      dispensaryRevenue: dispRev,
      zakatRevenue: zRev, nonZakatRevenue: nzRev, gmwfRevenue: gmRev,
    );
    _statsCachePut(cacheKey, result);
    return result;
  } catch (e) {
    debugPrint('[fetchBranchStats] Error ($e). Using local Hive stats fallback.');
    final localResult = await fetchLocalBranchStats(originalBranchId, range.start);
    _statsCachePut(cacheKey, localResult);
    return localResult;
  }
}



Stream<BranchStats> streamBranchStats(String originalBranchId, {DashboardFilter? filter}) {
  final range = _resolveFilter(filter);
  final start = range.start;
  final end   = range.end;
  final isOnlyToday = !end.difference(start).isNegative &&
      end.difference(start).inDays == 0 &&
      start.day == DateTime.now().day &&
      start.month == DateTime.now().month &&
      start.year == DateTime.now().year;

  // ── TODAY-ONLY: read entirely from Hive, zero Firestore reads ─────────────
  // The Hive boxes are kept fresh by SyncService + ServerSyncManager (30-min
  // downloads + real-time LAN push). We watch for changes and recompute.
  if (isOnlyToday) {
    return _streamTodayStatsFromHive(originalBranchId, filter: filter);
  }

  // ── HISTORICAL / MULTI-DAY: use cached Firestore fetch ────────────────────
  // fetchBranchStats() has an in-memory 5-minute cache so rapid rebuilds are
  // free; only the first call per TTL window hits Firestore.
  return Stream.fromFuture(fetchBranchStats(originalBranchId, filter: filter))
      .handleError((e) {
    debugPrint('[streamBranchStats] Error: $e');
    return const BranchStats();
  });
}

/// Builds today's [BranchStats] purely from Hive, reacting to any box change.
Stream<BranchStats> _streamTodayStatsFromHive(String branchId, {DashboardFilter? filter}) async* {
  BranchStats _compute() {
    final today     = LocalStorageService.getTodayDateKey();          // ddMMyy
    final todayDash = DateFormat('yyyy-MM-dd').format(DateTime.now()); // yyyy-MM-dd

    int z = 0, nz = 0, gm = 0, dispensed = 0, dispRev = 0;
    int zRev = 0, nzRev = 0, gmRev = 0;
    double donTotal = 0;

    final onlyMulti = filter?.multiDayMedicineOnly == true;
    final pType = filter?.patientType;

    // ── Tokens (entries box) ────────────────────────────────────────────────
    final entries = LocalStorageService.getLocalEntries(branchId)
        .where((e) => (e['dateKey'] ?? '') == today)
        .toList();

    for (final e in entries) {
      final days = (e['daysOfMedicine'] as num?)?.toInt() ?? 1;
      if (onlyMulti && days <= 1) continue;

      final rawQt = (e['queueType'] ?? e['category'] ?? e['type'] ?? '').toString().toLowerCase().trim();
      final qt = rawQt.replaceAll('-', '').replaceAll('_', '').trim();
      final normFilter = pType?.toLowerCase().replaceAll('-', '').replaceAll('_', '').trim();
      if (normFilter != null && normFilter.isNotEmpty && !qt.contains(normFilter)) continue;

      if (qt.contains('nonzakat') || qt.contains('non')) {
        nz++;
        dispRev += 100 * days;
        nzRev   += 100 * days;
      } else if (qt.contains('gmwf')) {
        gm++;
      } else {
        z++;
        dispRev += 20 * days;
        zRev    += 20 * days;
      }
    }

    // ── Dispensed (dispensary box) ──────────────────────────────────────────
    dispensed = LocalStorageService.getLocalDispensaryRecords(branchId, dateKey: today).length;

    // ── Donations (donations box) ───────────────────────────────────────────
    final seenReceipts = <String>{};
    final donBox = Hive.box(LocalStorageService.donationsBox);
    for (final raw in donBox.values) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final recBranch = data['branchId']?.toString().toLowerCase().trim() ?? '';
      if (recBranch != branchId.toLowerCase().trim()) continue;
      final date = data['date']?.toString() ?? '';
      if (date != todayDash) continue;
      final syncStatus = data['syncStatus']?.toString().toLowerCase() ?? '';
      final status = data['status']?.toString().toLowerCase() ?? '';
      if (syncStatus == 'deleted' || status == 'deleted') continue;
      final payMethod = data['paymentMethod']?.toString().toLowerCase() ?? '';
      if (payMethod == 'bank_deposit') continue;
      final receiptNo = data['receiptNo']?.toString() ?? '';
      final clean = don.cleanReceiptNumber(receiptNo);
      if (seenReceipts.contains(clean)) continue;
      seenReceipts.add(clean);
      final amt = data['amount'];
      donTotal += (amt is num) ? amt.toDouble() : (double.tryParse(amt?.toString() ?? '0') ?? 0.0);
    }

    // ── Food Tokens (dasterkhwaan_tokens box) ──────────────────────────────
    int das = 0, dasServed = 0;
    if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
      final tokenBox = Hive.box(LocalStorageService.dasterkhwaanTokensBox);
      for (final raw in tokenBox.values) {
        if (raw is! Map) continue;
        final t = Map<String, dynamic>.from(raw);
        final recBranch = t['branchId']?.toString().toLowerCase().trim() ?? '';
        if (recBranch.isNotEmpty && recBranch != branchId.toLowerCase().trim()) continue;
        final date = t['dateKey']?.toString() ?? '';
        if (date != todayDash && date != today) continue;
        das++;
        if (t['served'] == true) dasServed++;
      }
    }

    return BranchStats(
      zakat: z, nonZakat: nz, gmwf: gm,
      dispensed: dispensed, prescribed: 0,
      dasterkhwaan: das, dasterkhwaanServed: dasServed,
      donations: donTotal.toInt(),
      dispensaryRevenue: dispRev,
      zakatRevenue: zRev, nonZakatRevenue: nzRev, gmwfRevenue: gmRev,
    );
  }

  // Emit an initial value immediately
  yield _compute();

  // Merge watch streams from the relevant boxes and recompute on any change
  final streams = <Stream>[];
  if (Hive.isBoxOpen(LocalStorageService.entriesBox)) streams.add(Hive.box(LocalStorageService.entriesBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) streams.add(Hive.box(LocalStorageService.dispensaryBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.donationsBox)) streams.add(Hive.box(LocalStorageService.donationsBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) streams.add(Hive.box(LocalStorageService.dasterkhwaanTokensBox).watch());

  if (streams.isNotEmpty) {
    await for (final _ in Rx.merge(streams)) {
      yield _compute();
    }
  }
}


Future<BranchStats> fetchAllBranchesStats(List<String> ids, {DashboardFilter? filter}) async {
  if (ids.isEmpty) return const BranchStats();
  return fetchBranchStats('all', filter: filter);
}

Stream<BranchStats> _streamCombinedTodayStatsFromHive(List<String> ids, {DashboardFilter? filter}) async* {
  BranchStats _compute() {
    if (ids.isEmpty) return const BranchStats();
    final targetSet = ids.map((i) => i.toLowerCase().trim()).toSet();
    final matchAll = targetSet.isEmpty || targetSet.contains('all');

    final today     = LocalStorageService.getTodayDateKey();          // ddMMyy
    final todayDash = DateFormat('yyyy-MM-dd').format(DateTime.now()); // yyyy-MM-dd

    int z = 0, nz = 0, gm = 0, dispensed = 0, dispRev = 0;
    int zRev = 0, nzRev = 0, gmRev = 0;
    double donTotal = 0;

    final onlyMulti = filter?.multiDayMedicineOnly == true;
    final pType = filter?.patientType;

    // ── 1. Tokens (entries box) ──────────────────────────────────────────────
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final entriesBox = Hive.box(LocalStorageService.entriesBox);
      for (final raw in entriesBox.values) {
        if (raw is! Map) continue;
        final e = Map<String, dynamic>.from(raw);
        if ((e['dateKey'] ?? '') != today) continue;
        final bId = (e['branchId'] as String?)?.toLowerCase().trim() ?? '';
        if (!matchAll && !targetSet.contains(bId)) continue;

        final days = (e['daysOfMedicine'] as num?)?.toInt() ?? 1;
        if (onlyMulti && days <= 1) continue;

        final rawQt = (e['queueType'] ?? e['category'] ?? e['type'] ?? '').toString().toLowerCase().trim();
        final qt = rawQt.replaceAll('-', '').replaceAll('_', '').trim();
        final normFilter = pType?.toLowerCase().replaceAll('-', '').replaceAll('_', '').trim();
        if (normFilter != null && normFilter.isNotEmpty && !qt.contains(normFilter)) continue;

        if (qt.contains('nonzakat') || qt.contains('non')) {
          nz++;
          dispRev += 100 * days;
          nzRev   += 100 * days;
        } else if (qt.contains('gmwf')) {
          gm++;
          gmRev += 0 * days;
        } else {
          z++;
          dispRev += 20 * days;
          zRev    += 20 * days;
        }
      }
    }

    // ── 2. Dispensed (dispensary box) ─────────────────────────────────────────
    if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
      final dispBox = Hive.box(LocalStorageService.dispensaryBox);
      for (final raw in dispBox.values) {
        if (raw is! Map) continue;
        final d = Map<String, dynamic>.from(raw);
        if ((d['dateKey'] ?? '') != today) continue;
        final bId = (d['branchId'] as String?)?.toLowerCase().trim() ?? '';
        if (!matchAll && !targetSet.contains(bId)) continue;
        dispensed++;
      }
    }

    // ── 3. Donations (donations box) ──────────────────────────────────────────
    if (Hive.isBoxOpen(LocalStorageService.donationsBox)) {
      final seenReceipts = <String>{};
      final donBox = Hive.box(LocalStorageService.donationsBox);
      for (final raw in donBox.values) {
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final recBranch = data['branchId']?.toString().toLowerCase().trim() ?? '';
        if (!matchAll && !targetSet.contains(recBranch)) continue;

        final date = data['date']?.toString() ?? '';
        if (date != todayDash) continue;
        final syncStatus = data['syncStatus']?.toString().toLowerCase() ?? '';
        final status = data['status']?.toString().toLowerCase() ?? '';
        if (syncStatus == 'deleted' || status == 'deleted') continue;
        final payMethod = data['paymentMethod']?.toString().toLowerCase() ?? '';
        if (payMethod == 'bank_deposit') continue;
        final receiptNo = data['receiptNo']?.toString() ?? '';
        final clean = don.cleanReceiptNumber(receiptNo);
        if (seenReceipts.contains(clean)) continue;
        seenReceipts.add(clean);
        final amt = data['amount'];
        donTotal += (amt is num) ? amt.toDouble() : (double.tryParse(amt?.toString() ?? '0') ?? 0.0);
      }
    }

    // ── 4. Food Tokens (dasterkhwaan_tokens box) ───────────────────────────
    int das = 0, dasServed = 0;
    if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) {
      final tokenBox = Hive.box(LocalStorageService.dasterkhwaanTokensBox);
      for (final raw in tokenBox.values) {
        if (raw is! Map) continue;
        final t = Map<String, dynamic>.from(raw);
        final recBranch = t['branchId']?.toString().toLowerCase().trim() ?? '';
        if (!matchAll && !targetSet.contains(recBranch)) continue;
        final date = t['dateKey']?.toString() ?? '';
        if (date != todayDash && date != today) continue;
        das++;
        if (t['served'] == true) dasServed++;
      }
    }

    return BranchStats(
      zakat: z, nonZakat: nz, gmwf: gm,
      dispensed: dispensed, prescribed: 0,
      dasterkhwaan: das, dasterkhwaanServed: dasServed,
      donations: donTotal.toInt(),
      dispensaryRevenue: dispRev,
      zakatRevenue: zRev, nonZakatRevenue: nzRev, gmwfRevenue: gmRev,
    );
  }

  yield _compute();

  final streams = <Stream>[];
  if (Hive.isBoxOpen(LocalStorageService.entriesBox)) streams.add(Hive.box(LocalStorageService.entriesBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) streams.add(Hive.box(LocalStorageService.dispensaryBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.donationsBox)) streams.add(Hive.box(LocalStorageService.donationsBox).watch());
  if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanTokensBox)) streams.add(Hive.box(LocalStorageService.dasterkhwaanTokensBox).watch());

  if (streams.isNotEmpty) {
    await for (final _ in Rx.merge(streams)) {
      yield _compute();
    }
  }
}

Stream<BranchStats> streamAllBranchesStats(List<String> ids, {DashboardFilter? filter}) {
  if (ids.isEmpty) return Stream.value(const BranchStats());
  final isOnlyToday = (filter == null || filter.timeRange == TimeRange.today);
  if (isOnlyToday) {
    return _streamCombinedTodayStatsFromHive(ids, filter: filter);
  }
  
  final streams = ids.map((id) => streamBranchStats(id, filter: filter)).toList();
  return Rx.combineLatestList(streams).map((results) {
    int z = 0, nz = 0, gm = 0, das = 0, dasServed = 0, don = 0, disp = 0, presc = 0, dispRev = 0;
    int zRev = 0, nzRev = 0, gmRev = 0;
    for (final r in results) {
      final s = r;
      z += s.zakat; nz += s.nonZakat; gm += s.gmwf;
      das += s.dasterkhwaan; dasServed += s.dasterkhwaanServed;
      don += s.donations; disp += s.dispensed; presc += s.prescribed;
      dispRev += s.dispensaryRevenue;
      zRev += s.zakatRevenue; nzRev += s.nonZakatRevenue; gmRev += s.gmwfRevenue;
    }
    return BranchStats(
      zakat: z, nonZakat: nz, gmwf: gm,
      dasterkhwaan: das, dasterkhwaanServed: dasServed,
      donations: don, dispensed: disp, prescribed: presc,
      dispensaryRevenue: dispRev,
      zakatRevenue: zRev, nonZakatRevenue: nzRev, gmwfRevenue: gmRev,
    );
  });
}

// ════════════════════════════════════════════════════════════════════════════════
// PRIMITIVES — Animations, Shimmer loader, etc.
// ════════════════════════════════════════════════════════════════════════════════

class DashLoadingCard extends StatelessWidget {
  final RoleThemeData t;
  final double height;
  const DashLoadingCard({super.key, required this.t, this.height = 160});

  @override
  Widget build(BuildContext context) => Shimmer.fromColors(
    baseColor: DS.border,
    highlightColor: Colors.white,
    child: Container(
      height: height, width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DS.r3),
      ),
    ),
  );
}

typedef AnimatedCount = _AnimatedCount;

class _AnimatedCount extends StatefulWidget {
  final int value;
  final TextStyle style;
  final String prefix, suffix;
  const _AnimatedCount({
    required this.value,
    required this.style,
    this.prefix = '',
    this.suffix = '',
  });
  @override State<_AnimatedCount> createState() => _AnimatedCountState();
}

class _AnimatedCountState extends State<_AnimatedCount>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, _) {
      final v = (widget.value * _anim.value).toInt();
      String s;
      if (widget.value >= 10000000) {
        s = '${(v / 10000000).toStringAsFixed(1)}Cr';
      } else if (widget.value >= 100000) s = '${(v / 100000).toStringAsFixed(1)}L';
      else if (widget.value >= 1000) s = '${(v / 1000).toStringAsFixed(1)}K';
      else s = NumberFormat('#,##0', 'en_US').format(v);
      return Text('${widget.prefix}$s${widget.suffix}', style: widget.style);
    },
  );
}

typedef AnimatedProgressBar = _AnimatedProgressBar;

class _AnimatedProgressBar extends StatefulWidget {
  final double value;
  final Color color;
  final Color? backgroundColor;
  final double height;
  const _AnimatedProgressBar({
    required this.value,
    required this.color,
    this.height = 6,
    this.backgroundColor,
  });
  @override State<_AnimatedProgressBar> createState() => _AnimatedProgressBarState();
}

class _AnimatedProgressBarState extends State<_AnimatedProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, _) => ClipRRect(
      borderRadius: BorderRadius.circular(widget.height),
      child: LinearProgressIndicator(
        value: (widget.value * _anim.value).clamp(0.0, 1.0),
        minHeight: widget.height,
        backgroundColor: widget.backgroundColor ?? widget.color.withValues(alpha: 0.12),
        valueColor: AlwaysStoppedAnimation(widget.color),
      ),
    ),
  );
}

// ── Donut chart (kept intact — it's good) ────────────────────────────────────
class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final double progress;
  _DonutPainter({required this.values, required this.colors, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold(0.0, (a, b) => a + b);
    if (total == 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 6;
    const strokeW = 40.0;
    const gap = 0.022;
    double startAngle = -pi / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke ..strokeWidth = strokeW ..strokeCap = StrokeCap.butt;

    for (int i = 0; i < values.length; i++) {
      if (values[i] == 0) continue;
      final sweep = (values[i] / total) * 2 * pi * progress - gap;
      if (sweep <= 0) { startAngle += (values[i] / total) * 2 * pi * progress; continue; }
      paint.color = colors[i];
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          startAngle + gap / 2, sweep, false, paint);
      final pct = (values[i] / total * 100).round();
      if (pct >= 5 && progress > 0.65) {
        final midAngle = startAngle + gap / 2 + sweep / 2;
        final lx = center.dx + radius * cos(midAngle);
        final ly = center.dy + radius * sin(midAngle);
        final tp = TextPainter(
          text: TextSpan(text: '$pct%',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
      }
      startAngle += (values[i] / total) * 2 * pi * progress;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.progress != progress;
}

class _AnimatedDonut extends StatefulWidget {
  final List<double> values;
  final List<Color> colors;
  final Widget center;
  final double size;
  const _AnimatedDonut({required this.values, required this.colors,
      required this.center, this.size = 190});
  @override State<_AnimatedDonut> createState() => _AnimatedDonutState();
}

class _AnimatedDonutState extends State<_AnimatedDonut>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1300), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, _) => SizedBox(
      width: widget.size, height: widget.size,
      child: Stack(alignment: Alignment.center, children: [
        CustomPaint(size: Size(widget.size, widget.size),
            painter: _DonutPainter(values: widget.values, colors: widget.colors, progress: _anim.value)),
        widget.center,
      ]),
    ),
  );
}

// ── Animated distribution bar ─────────────────────────────────────────────────
class _AnimatedDistBar extends StatefulWidget {
  final int zakat, nonZakat, gmwf;
  final Color colorZ, colorNZ, colorG;
  const _AnimatedDistBar({required this.zakat, required this.nonZakat, required this.gmwf,
      required this.colorZ, required this.colorNZ, required this.colorG});
  @override State<_AnimatedDistBar> createState() => _AnimatedDistBarState();
}

class _AnimatedDistBarState extends State<_AnimatedDistBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1000), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final total = widget.zakat + widget.nonZakat + widget.gmwf;
    if (total == 0) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Row(children: [
          if (widget.zakat > 0)    Expanded(flex: widget.zakat,    child: Container(height: 6, color: widget.colorZ)),
          if (widget.nonZakat > 0) Expanded(flex: widget.nonZakat, child: Container(height: 6, color: widget.colorNZ)),
          if (widget.gmwf > 0)     Expanded(flex: widget.gmwf,     child: Container(height: 6, color: widget.colorG)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// DESIGN-SYSTEM COMPONENTS
// ════════════════════════════════════════════════════════════════════════════════

/// Consistent H2 section heading with accent bar + optional action
class DashSection extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final RoleThemeData t;

  const DashSection(this.title, {super.key, required this.t,
      this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: 4, height: 22,
          decoration: BoxDecoration(
              color: t.accent, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: DS.s1),
      Text(title, style: TextStyle(
          color: t.textPrimary, fontSize: DS.h2,
          fontWeight: FontWeight.w800, letterSpacing: -0.3)),
      const Spacer(),
      if (actionLabel != null && onAction != null)
        TextButton(
          onPressed: onAction,
          style: TextButton.styleFrom(
            foregroundColor: t.accent,
            padding: const EdgeInsets.symmetric(horizontal: DS.s1, vertical: 4),
          ),
          child: Text(actionLabel!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
    ],
  );
}

/// Backward-compatible alias kept for any screens still using `DashHeading`
class DashHeading extends StatelessWidget {
  final String text;
  final RoleThemeData t;
  const DashHeading(this.text, {super.key, required this.t});

  @override
  Widget build(BuildContext context) => DashSection(text, t: t);
}

// ════════════════════════════════════════════════════════════════════════════════
// A. REVENUE HERO CARD — Most prominent element
// Blue → Indigo gradient, H1 total revenue, 3 source pills
// ════════════════════════════════════════════════════════════════════════════════

class RevenueHeroCard extends StatefulWidget {
  final BranchStats s;
  final String? label;     // e.g. "All Branches – Today"
  const RevenueHeroCard({super.key, required this.s, this.label});

  @override State<RevenueHeroCard> createState() => _RevenueHeroCardState();
}

class _RevenueHeroCardState extends State<RevenueHeroCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 700), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(DS.s3),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1E40AF), Color(0xFF2563EB), Color(0xFF3B82F6)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(DS.r4),
          boxShadow: [BoxShadow(
            color: DS.blue.withValues(alpha: 0.30),
            blurRadius: 32, offset: const Offset(0, 12),
          )],
        ),
        child: Stack(children: [
          // Decorative circles
          Positioned(right: -24, top: -24, child: Container(width: 140, height: 140,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06)))),
          Positioned(right: 60, bottom: -10, child: Container(width: 70, height: 70,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.04)))),

          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Label row
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: DS.s1, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(DS.r1)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.trending_up_rounded, color: Colors.white, size: 12),
                  const SizedBox(width: 5),
                  Text(widget.label ?? 'Today\'s Revenue',
                      style: const TextStyle(color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                ]),
              ),
              const Spacer(),
              Text(DateFormat('d MMM yyyy').format(DateTime.now()),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12)),
            ]),

            const SizedBox(height: DS.s2),

            // H1 Revenue
            _AnimatedCount(
              value: s.totalRevenue,
              prefix: 'PKR ',
              style: const TextStyle(
                  color: Colors.white, fontSize: DS.h1,
                  fontWeight: FontWeight.w900, letterSpacing: -1.5, height: 1.0),
            ),
            const SizedBox(height: 4),
            Text('Total Revenue (Dispensary + Dasterkhwaan + Donations)',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: DS.caption)),

            const SizedBox(height: DS.s2),

            // 3 source pills
            LayoutBuilder(builder: (_, c) {
              final isWide = c.maxWidth > 480;
              final pills = [
                _revPill(Icons.local_pharmacy_rounded, 'Dispensary',
                    s.dispensaryRevenue, const Color(0xFF93C5FD)),
                _revPill(Icons.restaurant_rounded, 'Dasterkhwaan',
                    s.dasterkhwaanRevenue, const Color(0xFF6EE7B7)),
                _revPill(Icons.volunteer_activism_rounded, 'Donations',
                    s.donations, const Color(0xFFC4B5FD)),
              ];
              if (isWide) {
                return Row(children: [
                  for (int i = 0; i < pills.length; i++) ...[
                    if (i > 0) Container(width: 1, height: 40,
                        color: Colors.white.withValues(alpha: 0.2),
                        margin: const EdgeInsets.symmetric(horizontal: DS.s2)),
                    Expanded(child: pills[i]),
                  ],
                ]);
              }
              return Column(
                  children: pills.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: DS.s1), child: p)).toList());
            }),
          ]),
        ]),
      ),
    );
  }

  Widget _revPill(IconData icon, String label, int amount, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(DS.r1)),
            child: Icon(icon, color: color, size: 14)),
        const SizedBox(width: DS.s1),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.70),
              fontSize: DS.caption, fontWeight: FontWeight.w500)),
          _AnimatedCount(value: amount, prefix: 'PKR ',
              style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w800)),
        ]),
      ]);
}

// ════════════════════════════════════════════════════════════════════════════════
// B. OPERATIONS OVERVIEW ROW
// [Total Patients] [Meals Issued] [Meals Served] [Completion %]
// ════════════════════════════════════════════════════════════════════════════════

class OperationsOverviewRow extends StatelessWidget {
  final BranchStats s;
  const OperationsOverviewRow({super.key, required this.s});

  @override
  Widget build(BuildContext context) {
    final completionPct = s.tokens > 0
        ? (s.dispensed / s.tokens * 100).clamp(0, 100).toDouble()
        : 0.0;

    final tiles = [
      _OpsTile(
        icon: Icons.people_rounded,
        iconColor: DS.blue, iconBg: DS.blueMuted,
        value: fmtNum(s.tokens), label: 'Total Patients',
        isEmpty: s.tokens == 0,
      ),
      _OpsTile(
        icon: Icons.restaurant_rounded,
        iconColor: DS.orange, iconBg: DS.orangeMuted,
        value: fmtNum(s.dasterkhwaan), label: 'Tokens Issued',
        isEmpty: s.dasterkhwaan == 0,
      ),
      _OpsTile(
        icon: Icons.done_all_rounded,
        iconColor: DS.green, iconBg: DS.greenMuted,
        value: fmtNum(s.dasterkhwaanServed), label: 'Tokens Served',
        isEmpty: s.dasterkhwaanServed == 0,
      ),
      _OpsTile(
        icon: Icons.track_changes_rounded,
        iconColor: DS.purple, iconBg: DS.purpleMuted,
        value: '${completionPct.toStringAsFixed(0)}%',
        label: 'Completion',
        progressValue: completionPct / 100,
        progressColor: DS.purple,
      ),
    ];

    return LayoutBuilder(builder: (_, c) {
      final cols = c.maxWidth < 480 ? 2 : 4;
      return GridView.count(
        crossAxisCount: cols,
        crossAxisSpacing: DS.s2, mainAxisSpacing: DS.s2,
        childAspectRatio: cols == 2 ? 1.55 : 1.60,
        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        children: tiles,
      );
    });
  }
}

class _OpsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor, iconBg;
  final String value, label;
  final bool isEmpty;
  final double? progressValue;
  final Color? progressColor;

  const _OpsTile({
    required this.icon, required this.iconColor, required this.iconBg,
    required this.value, required this.label,
    this.isEmpty = false, this.progressValue, this.progressColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(DS.s2),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(DS.r2),
      border: Border.all(color: DS.border),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 10, offset: const Offset(0, 3))],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(padding: const EdgeInsets.all(DS.s1),
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(DS.r1)),
            child: Icon(icon, color: iconColor, size: 16)),
        const Spacer(),
        if (isEmpty)
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(DS.r1)),
              child: const Text('—', style: TextStyle(color: Color(0xFFD97706), fontSize: 10, fontWeight: FontWeight.w700))),
      ]),
      const Spacer(),
      Text(value, style: TextStyle(
          fontSize: value.length > 5 ? 18 : 24,
          fontWeight: FontWeight.w900,
          color: isEmpty ? DS.neutral : iconColor, height: 1.1)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: DS.caption, color: DS.neutral,
          fontWeight: FontWeight.w500)),
      if (progressValue != null) ...[
        const SizedBox(height: 8),
        _AnimatedProgressBar(value: progressValue!, color: progressColor ?? DS.purple, height: 4),
      ],
    ]),
  );
}

// ════════════════════════════════════════════════════════════════════════════════
// C. FINANCIAL SOURCES ROW — Zakat / Non-Zakat / GMWF
// ════════════════════════════════════════════════════════════════════════════════

class FinancialSourcesRow extends StatelessWidget {
  final BranchStats s;
  final RoleThemeData t;
  const FinancialSourcesRow({super.key, required this.s, required this.t});

  @override
  Widget build(BuildContext context) {
    final total = s.tokens;
    return Container(
      padding: const EdgeInsets.all(DS.s2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: DS.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Row(children: [
          Container(padding: const EdgeInsets.all(DS.s1),
              decoration: BoxDecoration(color: DS.blueMuted, borderRadius: BorderRadius.circular(DS.r1)),
              child: const Icon(Icons.account_balance_rounded, color: DS.blue, size: 16)),
          const SizedBox(width: DS.s1),
          const Text('Patient Financial Sources',
              style: TextStyle(color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('$total total', style: const TextStyle(color: DS.neutral, fontSize: 12)),
        ]),

        const SizedBox(height: DS.s2),

        // Distribution bar (if there's data)
        if (total > 0) ...[
          _AnimatedDistBar(zakat: s.zakat, nonZakat: s.nonZakat, gmwf: s.gmwf,
              colorZ: t.zakat, colorNZ: t.nonZakat, colorG: t.gmwf),
          const SizedBox(height: DS.s2),
        ],

        // 3 source tiles
        LayoutBuilder(builder: (_, c) {
          final isWide = c.maxWidth > 480;
          final items = [
            _SrcTile(color: t.zakat, label: 'Zakat',
                count: s.zakat, revenue: s.zakat * 20,
                rateLabel: '@ PKR 20', total: total),
            _SrcTile(color: t.nonZakat, label: 'Non-Zakat',
                count: s.nonZakat, revenue: s.nonZakat * 100,
                rateLabel: '@ PKR 100', total: total),
            _SrcTile(color: t.gmwf, label: 'GMWF',
                count: s.gmwf, revenue: 0,
                rateLabel: 'Free', total: total),
          ];
          if (isWide) {
            return Row(children: <Widget>[
              Expanded(child: items[0]),
              const SizedBox(width: DS.s2),
              Expanded(child: items[1]),
              const SizedBox(width: DS.s2),
              Expanded(child: items[2]),
            ]);
          }
          return Column(children: [
            Row(children: [Expanded(child: items[0]), const SizedBox(width: DS.s2), Expanded(child: items[1])]),
            const SizedBox(height: DS.s2),
            items[2],
          ]);
        }),

        // Empty state
        if (total == 0) _EmptyOpsState(
          icon: Icons.people_outline_rounded,
          message: 'No patients registered today',
          hint: 'Check back once registration begins at your branch',
        ),
      ]),
    );
  }
}

class _SrcTile extends StatelessWidget {
  final Color color;
  final String label, rateLabel;
  final int count, revenue, total;
  const _SrcTile({required this.color, required this.label, required this.count,
      required this.revenue, required this.rateLabel, required this.total});

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (count / total * 100).round() : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.s2, vertical: DS.s1 + 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(DS.r1 + 4),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(DS.r1)),
            child: Text('$pct%', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 6),
        _AnimatedCount(value: count,
            style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900, height: 1.1)),
        Text('patients', style: TextStyle(color: color.withValues(alpha: 0.65), fontSize: DS.caption)),
        const SizedBox(height: 4),
        Text(revenue > 0 ? fmtPKR(revenue) : rateLabel,
            style: TextStyle(color: const Color(0xFF374151), fontSize: 12, fontWeight: FontWeight.w600)),
        Text(rateLabel, style: const TextStyle(color: DS.neutral, fontSize: DS.caption)),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// D. EMPTY OPERATIONS STATE — Helpful, not dead
// ════════════════════════════════════════════════════════════════════════════════

class _EmptyOpsState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final VoidCallback? onPrimary;
  final String primaryLabel;

  const _EmptyOpsState({
    required this.icon,
    required this.message,
    this.hint,
    this.onPrimary,
    this.primaryLabel = '',
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: DS.s3),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(padding: const EdgeInsets.all(DS.s2),
          decoration: BoxDecoration(color: DS.neutralBg, shape: BoxShape.circle),
          child: Icon(icon, size: 32, color: DS.neutral)),
      const SizedBox(height: DS.s2),
      Text(message, style: const TextStyle(color: Color(0xFF111827),
          fontSize: 14, fontWeight: FontWeight.w600)),
      if (hint != null) ...[
        const SizedBox(height: 6),
        Text(hint!, textAlign: TextAlign.center,
            style: const TextStyle(color: DS.neutral, fontSize: 12)),
      ],
      if (onPrimary != null) ...[
        const SizedBox(height: DS.s2),
        FilledButton.icon(
          onPressed: onPrimary,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: Text(primaryLabel),
          style: FilledButton.styleFrom(
            backgroundColor: DS.blue,
            padding: const EdgeInsets.symmetric(horizontal: DS.s3, vertical: DS.s1),
          ),
        ),
      ],
    ]),
  );
}

// ════════════════════════════════════════════════════════════════════════════════
// E. COMPACT HERO BANNER — 35% smaller than original
// ════════════════════════════════════════════════════════════════════════════════

class HeroBanner extends StatefulWidget {
  final RoleThemeData t;
  final String username;
  final String roleLabel;
  final BranchStats stats;

  const HeroBanner({
    super.key, required this.t, required this.username,
    required this.roleLabel, required this.stats,
  });
  @override State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 600), vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.stats;
    final completionPct = s.tokens > 0
        ? (s.dispensed / s.tokens * 100).clamp(0, 100).toDouble()
        : 0.0;

    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: double.infinity,
        // Reduced padding: was 28, now 16/20 → ~35% height reduction
        padding: const EdgeInsets.fromLTRB(DS.s2 + 4, DS.s2, DS.s2 + 4, DS.s2),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [widget.t.accent, widget.t.accentLight],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(DS.r3),
          boxShadow: [BoxShadow(
            color: widget.t.accent.withValues(alpha: 0.30),
            blurRadius: 24, offset: const Offset(0, 8),
          )],
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Role badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: DS.s1, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(DS.r1)),
              child: Text(widget.roleLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 10,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
            const SizedBox(height: 6),
            // Username
            Text(widget.username,
                style: const TextStyle(color: Colors.white, fontSize: 20,
                    fontWeight: FontWeight.w800, height: 1.1),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(DateFormat('EEE, d MMM').format(DateTime.now()),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.70), fontSize: 12)),
          ])),
          const SizedBox(width: DS.s2),
          // Two compact stat chips
          Row(mainAxisSize: MainAxisSize.min, children: [
            _statChip(Icons.people_rounded, fmtNum(s.tokens), 'Patients'),
            const SizedBox(width: DS.s1),
            _statChip(Icons.track_changes_rounded,
                '${completionPct.toStringAsFixed(0)}%', 'Done'),
          ]),
        ]),
      ),
    );
  }

  Widget _statChip(IconData icon, String value, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: DS.s1),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(DS.r1 + 4),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: Colors.white, size: 14),
      const SizedBox(height: 3),
      Text(value, style: const TextStyle(color: Colors.white,
          fontSize: 15, fontWeight: FontWeight.w900, height: 1.0)),
      Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.70), fontSize: 10)),
    ]),
  );
}

// ════════════════════════════════════════════════════════════════════════════════
// F. BRANCH PERFORMANCE TABLE — collapsible rows, replaces card list
// ════════════════════════════════════════════════════════════════════════════════

class BranchPerformanceTable extends StatefulWidget {
  final RoleThemeData t;
  final List<Map<String, dynamic>> branches; // [{'id', 'name', 'location?'}]
  final void Function(String)? onGoToBranch;
  final String selectedTab; // NEW parameter: 'overall', 'dispensary', 'tokens', 'donations'

  const BranchPerformanceTable({
    super.key,
    required this.t,
    required this.branches,
    this.onGoToBranch,
    required this.selectedTab,
  });

  @override
  State<BranchPerformanceTable> createState() => _BranchPerformanceTableState();
}

class _BranchPerformanceTableState extends State<BranchPerformanceTable> {
  final Map<String, BranchStats> _latestStats = {}; // Local cache for sorting
  final Set<String> _expanded = {};
  String _sortBy = 'tokens'; 
  bool _ascending = false;

  @override
  void initState() {
    super.initState();
    dashboardController.addListener(_onFilterChanged);
    _resetSortKey();
  }

  @override
  void didUpdateWidget(BranchPerformanceTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab != widget.selectedTab) {
      _resetSortKey();
    }
  }

  void _resetSortKey() {
    switch (widget.selectedTab) {
      case 'overall':
        _sortBy = 'tokens';
        break;
      case 'dispensary':
        _sortBy = 'tokens';
        break;
      case 'tokens':
        _sortBy = 'dasterkhwaan';
        break;
      case 'donations':
        _sortBy = 'donations';
        break;
    }
    _ascending = false;
  }

  @override
  void dispose() {
    dashboardController.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  Map<String, double> _getDonationSplit(String branchId) {
    double jamia = 0;
    double gmwf = 0;
    try {
      final list = DonationsLocalStorage.getAllDonations(branchId);
      for (var d in list) {
        final amt = (d.amount > 0 ? d.amount : d.probableAmount) ?? 0.0;
        if (d.categoryId == 'jamia') {
          jamia += amt;
        } else if (d.categoryId == 'gmwf') {
          gmwf += amt;
        }
      }
    } catch (_) {}
    return {'jamia': jamia, 'gmwf': gmwf};
  }

  List<Map<String, dynamic>> get _sortedBranches {
    final list = List<Map<String, dynamic>>.from(widget.branches);
    list.sort((a, b) {
      final idA = a['id'] as String;
      final idB = b['id'] as String;
      final sa = _latestStats[idA] ?? const BranchStats();
      final sb = _latestStats[idB] ?? const BranchStats();

      int compare = 0;
      switch (_sortBy) {
        case 'tokens': compare = sa.tokens.compareTo(sb.tokens); break;
        case 'revenue': compare = sa.totalRevenue.compareTo(sb.totalRevenue); break;
        case 'donations': compare = sa.donations.compareTo(sb.donations); break;
        case 'zkat':
        case 'zakat': compare = sa.zakat.compareTo(sb.zakat); break;
        case 'nonZakat': compare = sa.nonZakat.compareTo(sb.nonZakat); break;
        case 'gmwf': compare = sa.gmwf.compareTo(sb.gmwf); break;
        case 'dispensaryRevenue': compare = sa.dispensaryRevenue.compareTo(sb.dispensaryRevenue); break;
        case 'dasterkhwaan': compare = sa.dasterkhwaan.compareTo(sb.dasterkhwaan); break;
        case 'dasterkhwaanServed': compare = sa.dasterkhwaanServed.compareTo(sb.dasterkhwaanServed); break;
        case 'dasterkhwaanRevenue': compare = sa.dasterkhwaanRevenue.compareTo(sb.dasterkhwaanRevenue); break;
        case 'jamia': {
          final ja = _getDonationSplit(idA)['jamia'] ?? 0.0;
          final jb = _getDonationSplit(idB)['jamia'] ?? 0.0;
          compare = ja.compareTo(jb);
          break;
        }
        case 'gmwf_general': {
          final ga = _getDonationSplit(idA)['gmwf'] ?? 0.0;
          final gb = _getDonationSplit(idB)['gmwf'] ?? 0.0;
          compare = ga.compareTo(gb);
          break;
        }
      }
      return _ascending ? compare : -compare;
    });
    return list;
  }

  void _toggleSort(String key) {
    setState(() {
      if (_sortBy == key) {
        _ascending = !_ascending;
      } else { _sortBy = key; _ascending = false; }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final sorted = _sortedBranches;
    final topId = sorted.isNotEmpty ? sorted.first['id'] : null;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: DS.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(children: [
        // Table header
        Container(
          padding: const EdgeInsets.fromLTRB(DS.s2, DS.s1 + 4, DS.s2, DS.s1 + 4),
          decoration: const BoxDecoration(
              color: DS.neutralBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(DS.r2))),
          child: Row(children: [
            const Expanded(flex: 3, child: Text('Branch', style: TextStyle(
                color: DS.neutral, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5))),
            if (widget.selectedTab == 'overall') ...[
              _headerCell('Patients', 'tokens', flex: 2),
              _headerCell('Disp. Rev', 'dispensaryRevenue', flex: 2),
              _headerCell('Donations', 'donations', flex: 2),
              _headerCell('Food Rev', 'dasterkhwaanRevenue', flex: 2, sortable: false),
              _headerCell('Total Rev', 'revenue', flex: 2),
            ] else if (widget.selectedTab == 'dispensary') ...[
              _headerCell('Zakat P.', 'zakat', flex: 2),
              _headerCell('Non-Zakat', 'nonZakat', flex: 2),
              _headerCell('GMWF P.', 'gmwf', flex: 2),
              _headerCell('Revenue', 'dispensaryRevenue', flex: 2),
            ] else if (widget.selectedTab == 'tokens') ...[
              _headerCell('Issued', 'dasterkhwaan', flex: 2),
              _headerCell('Served', 'dasterkhwaanServed', flex: 2),
              _headerCell('Rate', 'rate', flex: 2, sortable: false),
              _headerCell('Revenue', 'dasterkhwaanRevenue', flex: 2),
            ] else if (widget.selectedTab == 'donations') ...[
              _headerCell('Total Don.', 'donations', flex: 2),
              _headerCell('Jamia Share', 'jamia', flex: 2),
              _headerCell('GMWF Gen.', 'gmwf_general', flex: 2),
            ],
            const SizedBox(width: 24), // expand chevron space
          ]),
        ),
        Container(height: 1, color: DS.border),

        // Rows with individual StreamBuilders for real-time independence
        ...sorted.asMap().entries.map((entry) {
          final i = entry.key;
          final b = entry.value;
          final id = b['id'] as String;
          final name = b['name'] as String;
          final isExpanded = _expanded.contains(id);
          final isLast = i == sorted.length - 1;

          return StreamBuilder<BranchStats>(
            stream: streamBranchStats(id, filter: dashboardController.value),
            builder: (context, snapshot) {
              final s = snapshot.data ?? const BranchStats();
              // Update local cache silently for sorting in next rebuild
              if (snapshot.hasData) {
                _latestStats[id] = s;
              }
              
              final isTop = id == topId && s.tokens > 0;

              return _BranchTableRow(
                t: t, name: name, branchId: id, stats: s,
                isExpanded: isExpanded,
                isLast: isLast,
                isTop: isTop,
                selectedTab: widget.selectedTab,
                onTap: () => setState(() {
                  if (isExpanded) {
                    _expanded.remove(id);
                  } else {
                    _expanded.add(id);
                  }
                }),
              );
            }
          );
        }),

        // Empty state
        if (sorted.isEmpty)
          Padding(
            padding: const EdgeInsets.all(DS.s4),
            child: _EmptyOpsState(
              icon: Icons.store_outlined,
              message: 'No branches matched',
              hint: 'Try adjusting your filters',
            ),
          ),
      ]),
    );
  }

  Widget _headerCell(String label, String key, {int flex = 1, bool sortable = true}) {
    final active = _sortBy == key;
    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: sortable ? () => _toggleSort(key) : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: TextStyle(
                color: active ? DS.blue : DS.neutral,
                fontSize: 11, fontWeight: FontWeight.w700)),
            if (sortable && active) ...[
              const SizedBox(width: 2),
              Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  size: 10, color: DS.blue),
            ],
          ],
        ),
      ),
    );
  }
}

class _BranchTableRow extends StatelessWidget {
  final RoleThemeData t;
  final String name;
  final String branchId;
  final BranchStats? stats;
  final bool isExpanded, isLast, isTop;
  final VoidCallback onTap;
  final String selectedTab;

  const _BranchTableRow({
    required this.t, required this.name, required this.branchId, required this.stats,
    required this.isExpanded, required this.isLast, required this.isTop, required this.onTap,
    required this.selectedTab,
  });

  @override
  Widget build(BuildContext context) {
    final s = stats ?? const BranchStats();

    double branchJamia = 0;
    double branchGmwf = 0;
    if (selectedTab == 'donations') {
      try {
        final list = DonationsLocalStorage.getAllDonations(branchId);
        for (var d in list) {
          final amt = (d.amount > 0 ? d.amount : d.probableAmount) ?? 0.0;
          if (d.categoryId == 'jamia') {
            branchJamia += amt;
          } else if (d.categoryId == 'gmwf') {
            branchGmwf += amt;
          }
        }
      } catch (_) {}
    }

    return Column(children: [
      InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(DS.s2, DS.s2 - 4, DS.s2, DS.s2 - 4),
          decoration: BoxDecoration(
            color: isTop ? DS.green.withValues(alpha: 0.05) : (isExpanded ? DS.blueMuted.withValues(alpha: 0.5) : Colors.transparent),
            border: isLast && !isExpanded ? null
                : const Border(bottom: BorderSide(color: DS.border, width: 0.5)),
          ),
          child: Row(children: [
            // Branch name
            Expanded(flex: 3, child: Row(children: [
              if (isTop) const Icon(Icons.stars_rounded, color: DS.green, size: 14),
              if (isTop) const SizedBox(width: 4),
              Container(width: 6, height: 6,
                  decoration: BoxDecoration(
                      color: s.tokens > 0 ? DS.green : DS.border,
                      shape: BoxShape.circle)),
              const SizedBox(width: DS.s1),
              Expanded(child: Text(name,
                  style: TextStyle(color: t.textPrimary, fontSize: 13,
                      fontWeight: isExpanded || isTop ? FontWeight.w700 : FontWeight.w600),
                  overflow: TextOverflow.ellipsis)),
            ])),
            if (selectedTab == 'overall') ...[
              // Patients
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.tokens,
                  style: const TextStyle(color: DS.blue, fontSize: 13,
                      fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ))),
              // Dispensary Revenue
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.dispensaryRevenue),
                  style: const TextStyle(color: DS.blue, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
              // Donations
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.donations),
                  style: const TextStyle(color: DS.purple, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
              // Food Revenue
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.dasterkhwaanRevenue),
                  style: const TextStyle(color: DS.orange, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
              // Total Revenue
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.totalRevenue),
                  style: const TextStyle(color: DS.green, fontSize: 12,
                      fontWeight: FontWeight.w800)))),
            ] else if (selectedTab == 'dispensary') ...[
              // Zakat
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.zakat,
                  style: const TextStyle(color: DS.green, fontSize: 13,
                      fontWeight: FontWeight.w700)))),
              // Non-Zakat
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.nonZakat,
                  style: const TextStyle(color: DS.blue, fontSize: 13,
                      fontWeight: FontWeight.w700)))),
              // GMWF
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.gmwf,
                  style: const TextStyle(color: DS.orange, fontSize: 13,
                      fontWeight: FontWeight.w700)))),
              // Revenue
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.dispensaryRevenue),
                  style: const TextStyle(color: DS.green, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
            ] else if (selectedTab == 'tokens') ...[
              // Issued
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.dasterkhwaan,
                  style: const TextStyle(color: DS.orange, fontSize: 13,
                      fontWeight: FontWeight.w700)))),
              // Served
              Expanded(flex: 2, child: Center(child: _AnimatedCount(value: s.dasterkhwaanServed,
                  style: const TextStyle(color: DS.green, fontSize: 13,
                      fontWeight: FontWeight.w700)))),
              // Rate
              Expanded(flex: 2, child: Center(child: Text(
                  '${s.dasterkhwaan > 0 ? (s.dasterkhwaanServed * 100 ~/ s.dasterkhwaan) : 0}%',
                  style: const TextStyle(color: DS.neutral, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
              // Food Revenue
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.dasterkhwaanRevenue),
                  style: const TextStyle(color: DS.green, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
            ] else if (selectedTab == 'donations') ...[
              // Total donations
              Expanded(flex: 2, child: Center(child: Text(fmtNum(s.donations),
                  style: const TextStyle(color: DS.purple, fontSize: 12,
                      fontWeight: FontWeight.w800)))),
              // Jamia
              Expanded(flex: 2, child: Center(child: Text(fmtNum(branchJamia.toInt()),
                  style: const TextStyle(color: DS.blue, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
              // GMWF
              Expanded(flex: 2, child: Center(child: Text(fmtNum(branchGmwf.toInt()),
                  style: const TextStyle(color: DS.green, fontSize: 12,
                      fontWeight: FontWeight.w700)))),
            ],
            // Chevron
            AnimatedRotation(
              turns: isExpanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 250),
              child: const Icon(Icons.chevron_right_rounded, color: DS.neutral, size: 20),
            ),
          ]),
        ),
      ),

      // Expanded detail panel
      AnimatedCrossFade(
        firstChild: const SizedBox.shrink(),
        secondChild: _BranchDetailPanel(t: t, s: s, branchId: branchId, selectedTab: selectedTab),
        crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 280),
      ),

      if (isExpanded && !isLast)
        const Divider(height: 1, color: DS.border),
    ]);
  }
}

class _BranchDetailPanel extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  final String branchId;
  final String selectedTab;

  const _BranchDetailPanel({required this.t, required this.s, required this.branchId, required this.selectedTab});

  @override
  Widget build(BuildContext context) {
    if (selectedTab == 'dispensary') {
      return Container(
        padding: const EdgeInsets.fromLTRB(DS.s3, DS.s2, DS.s3, DS.s2),
        color: DS.blueMuted.withValues(alpha: 0.25),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Clinical Breakdown:', style: TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            _detailChip(t.zakat, 'Zakat Patients', s.zakat, 'PKR ${fmtNum(s.zakat * 20)}'),
            const SizedBox(width: DS.s1),
            _detailChip(t.nonZakat, 'Non-Zakat', s.nonZakat, 'PKR ${fmtNum(s.nonZakat * 100)}'),
            const SizedBox(width: DS.s1),
            _detailChip(t.gmwf, 'GMWF', s.gmwf, 'Free'),
          ]),
          if (s.tokens > 0) ...[
            const SizedBox(height: DS.s2),
            _AnimatedDistBar(zakat: s.zakat, nonZakat: s.nonZakat, gmwf: s.gmwf,
                colorZ: t.zakat, colorNZ: t.nonZakat, colorG: t.gmwf),
          ],
        ]),
      );
    } else if (selectedTab == 'tokens') {
      return Container(
        padding: const EdgeInsets.fromLTRB(DS.s3, DS.s2, DS.s3, DS.s2),
        color: DS.orangeMuted.withValues(alpha: 0.25),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.restaurant_rounded, size: 13, color: DS.orange),
            const SizedBox(width: 6),
            const Text('Food Service Progress:', style: TextStyle(color: DS.neutral, fontSize: 12)),
            const Spacer(),
            Text('${s.dasterkhwaanServed} / ${s.dasterkhwaan} served',
                style: const TextStyle(color: DS.orange, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          _AnimatedProgressBar(
              value: s.dasterkhwaan > 0 ? s.dasterkhwaanServed / s.dasterkhwaan : 0,
              color: DS.orange, height: 6),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Pending Tokens: ${s.dasterkhwaanPending}', style: const TextStyle(color: DS.neutral, fontSize: 11)),
              Text('Total Food Revenue: PKR ${fmtNum(s.dasterkhwaanRevenue)}', style: const TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          )
        ]),
      );
    } else if (selectedTab == 'donations') {
      final branchDonations = DonationsLocalStorage.getAllDonations(branchId).take(5).toList();
      return Container(
        padding: const EdgeInsets.fromLTRB(DS.s3, DS.s2, DS.s3, DS.s2),
        color: DS.purpleMuted.withValues(alpha: 0.25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recent Branch Contributions:', style: TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (branchDonations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text('No donations recorded recently', style: TextStyle(color: Colors.grey, fontSize: 11, fontStyle: FontStyle.italic)),
              )
            else
              ...branchDonations.map((d) => Padding(
                padding: const EdgeInsets.only(bottom: 6.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('${d.donorName} (${d.categoryId.toUpperCase()})',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                        overflow: TextOverflow.ellipsis),
                    ),
                    Text('PKR ${NumberFormat('#,###').format(d.amount)}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: DS.purple, fontFamily: 'DMMono')),
                  ],
                ),
              )),
          ],
        ),
      );
    }

    // Default/Overall
    return Container(
      padding: const EdgeInsets.fromLTRB(DS.s3, DS.s2, DS.s3, DS.s2),
      color: DS.blueMuted.withValues(alpha: 0.25),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _detailChip(t.zakat, 'Zakat', s.zakat, 'PKR ${fmtNum(s.zakat * 20)}'),
          const SizedBox(width: DS.s1),
          _detailChip(t.nonZakat, 'Non-Zakat', s.nonZakat, 'PKR ${fmtNum(s.nonZakat * 100)}'),
          const SizedBox(width: DS.s1),
          _detailChip(t.gmwf, 'GMWF', s.gmwf, 'Free'),
        ]),
        const SizedBox(height: DS.s2),
        Row(children: [
          const Icon(Icons.restaurant_rounded, size: 13, color: DS.orange),
          const SizedBox(width: 6),
          const Text('Food Service:', style: TextStyle(color: DS.neutral, fontSize: 12)),
          const SizedBox(width: 6),
          Text('${s.dasterkhwaanServed} / ${s.dasterkhwaan} served',
              style: const TextStyle(color: DS.orange, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        _AnimatedProgressBar(
            value: s.dasterkhwaan > 0 ? s.dasterkhwaanServed / s.dasterkhwaan : 0,
            color: DS.orange, height: 5),
      ]),
    );
  }

  Widget _detailChip(Color color, String label, int count, String revenue) =>
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.s1, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DS.r1),
          border: Border.all(color: color.withValues(alpha: 0.20)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
          _AnimatedCount(value: count,
              style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w900)),
          Text(revenue, style: TextStyle(color: color.withValues(alpha: 0.75), fontSize: 10)),
        ]),
      ));
}

// ════════════════════════════════════════════════════════════════════════════════
// G. CHAIRMAN INSIGHTS CARD (kept — used in legacy screens if needed)
// ════════════════════════════════════════════════════════════════════════════════

class ChairmanInsightsCard extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  final String topBranchName;
  final String topBranchLocation;
  final int topBranchRevenue;
  final int topBranchPatients;
  final int targetRevenue;

  const ChairmanInsightsCard({
    super.key, required this.t, required this.s,
    required this.topBranchName, this.topBranchLocation = '',
    required this.topBranchRevenue, required this.topBranchPatients,
    this.targetRevenue = 21000000,
  });

  @override
  Widget build(BuildContext context) => RevenueHeroCard(s: s);
}

// ════════════════════════════════════════════════════════════════════════════════
// H. BENTO STATS GRID (backward compat — wraps new components)
// ════════════════════════════════════════════════════════════════════════════════

class BentoStatsGrid extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  final int branchCount;
  final String topBranchName;
  final int targetRevenue;

  const BentoStatsGrid({
    super.key, required this.t, required this.s,
    required this.branchCount, required this.topBranchName,
    this.targetRevenue = 21000000,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      OperationsOverviewRow(s: s),
      const SizedBox(height: DS.s2),
      FinancialSourcesRow(s: s, t: t),
    ]);
  }
}

// ── KPI Tiles Row (backward compat) ──────────────────────────────────────────
class KpiTilesRow extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  final int branchCount;
  const KpiTilesRow({super.key, required this.t, required this.s, required this.branchCount});

  @override
  Widget build(BuildContext context) => OperationsOverviewRow(s: s);
}

// ── Top Branch Banner ─────────────────────────────────────────────────────────
class TopBranchBanner extends StatelessWidget {
  final RoleThemeData t;
  final String branchName;
  final int revenue;
  final int patients;
  final int donations;
  final int foodTokens;
  final VoidCallback? onTap;
  const TopBranchBanner({super.key, required this.t, required this.branchName,
      required this.revenue, required this.patients, required this.donations, required this.foodTokens, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.s3, vertical: DS.s2),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
        begin: Alignment.centerLeft, end: Alignment.centerRight,
      ),
      borderRadius: BorderRadius.circular(DS.r2),
      boxShadow: [BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.30),
          blurRadius: 20, offset: const Offset(0, 8))],
    ),
    child: Row(children: [
      Container(padding: const EdgeInsets.all(DS.s1 + 4),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(DS.r1 + 4)),
          child: const Icon(Icons.emoji_events_rounded, color: Colors.white, size: 24)),
      const SizedBox(width: DS.s2),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: DS.s1, vertical: 3),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.20),
              borderRadius: BorderRadius.circular(DS.r1)),
          child: const Text('TOP PERFORMING BRANCH – TODAY',
              style: TextStyle(color: Colors.white, fontSize: 9,
                  fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        ),
        const SizedBox(height: DS.s1),
        Text(branchName, style: const TextStyle(
            color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.1)),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: 4),
          Text(fmtPKR(revenue), style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: DS.s2),
          const Icon(Icons.volunteer_activism_rounded, color: Colors.white70, size: 14),
          const SizedBox(width: 4),
          Text(fmtNum(donations), style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: DS.s2),
          const Icon(Icons.restaurant_rounded, color: Colors.white70, size: 14),
          const SizedBox(width: 4),
          Text(fmtNum(foodTokens), style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: DS.s2),
          const Icon(Icons.people_rounded, color: Colors.white70, size: 14),
          const SizedBox(width: 4),
          Text('$patients patients', style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ])),
    ]),
  ));
}

class ExecutiveTopBranchFetcher extends StatelessWidget {
  final RoleThemeData t;
  final List<Map<String, dynamic>> branches;
  final void Function(String)? onGoToBranch;
  const ExecutiveTopBranchFetcher({super.key, required this.t, required this.branches, this.onGoToBranch});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DashboardFilter>(
    valueListenable: dashboardController,
    builder: (context, filter, child) {
      return FutureBuilder<Map<String, dynamic>>(
        future: _findTop(filter),
        builder: (_, snap) {
          if (!snap.hasData) return DashLoadingCard(t: t, height: 88);
          final d = snap.data!;
          if ((d['tokens'] as int) == 0 && (d['revenue'] as int) == 0) return const SizedBox.shrink();
          return TopBranchBanner(
            t: t, branchName: d['name'] as String,
            revenue: d['revenue'] as int, patients: d['tokens'] as int,
            donations: d['donations'] as int, foodTokens: d['food'] as int,
            onTap: onGoToBranch != null ? () => onGoToBranch!(d['id'] as String) : null,
          );
        },
      );
    },
  );

  Future<Map<String, dynamic>> _findTop(DashboardFilter filter) async {
    Map<String, dynamic> best = {
      'name': '', 'tokens': 0, 'revenue': 0,
      'donations': 0, 'food': 0, 'score': -1.0
    };
    for (final b in branches) {
      final s = await fetchBranchStats(b['id'] as String, filter: filter);
      if (s.performanceScore.toDouble() > (best['score'] as double)) {
        best = {
          'name': b['name'],
          'tokens': s.tokens,
          'revenue': s.totalRevenue,
          'donations': s.donations,
          'food': s.dasterkhwaan,
          'score': s.performanceScore.toDouble(),
        };
      }
    }
    return best;
  }
}

// ── Peak Records Banner ──────────────────────────────────────────────────────
class PeakRecordsBanner extends StatelessWidget {
  final RoleThemeData t;
  final String branchId;
  const PeakRecordsBanner({super.key, required this.t, this.branchId = 'all'});

  @override
  Widget build(BuildContext context) {
    final records = BranchRecordService.getBranchRecords(branchId);
    final isDark = t.isDarkCanvas;
    final count = records.peakRecord.count;
    final dateStr = records.peakRecord.dateFormatted.isNotEmpty
        ? records.peakRecord.dateFormatted
        : "No history yet";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.s2, vertical: DS.s2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(
          color: records.isNewRecordToday
              ? const Color(0xFFF59E0B)
              : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
          width: records.isNewRecordToday ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: records.isNewRecordToday
                ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.emoji_events_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: DS.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'ALL-TIME PEAK SINGLE-DAY RECORD',
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                      ),
                    ),
                    if (records.isNewRecordToday) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'BROKEN TODAY!',
                          style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w900, color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$count',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Patients dealt',
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.3)),
            ),
            child: Text(
              dateStr,
              style: const TextStyle(
                color: Color(0xFFD97706),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// I. GRAND TOTALS CARD — Simplified, references RevenueHeroCard data
// ════════════════════════════════════════════════════════════════════════════════

class GrandTotalsCard extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  const GrandTotalsCard({super.key, required this.t, required this.s});

  @override
  Widget build(BuildContext context) => RevenueHeroCard(s: s,
      label: 'All Branches – Today');
}

// ════════════════════════════════════════════════════════════════════════════════
// J. PATIENT DISTRIBUTION CARD — Donut chart with detail legend
// ════════════════════════════════════════════════════════════════════════════════

class PatientDistributionCard extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  const PatientDistributionCard({super.key, required this.t, required this.s});

  @override
  Widget build(BuildContext context) {
    final total = s.tokens;
    final zPct = total > 0 ? (s.zakat / total * 100).round() : 0;
    final nPct = total > 0 ? (s.nonZakat / total * 100).round() : 0;
    final gPct = total > 0 ? (s.gmwf / total * 100).round() : 0;

    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: DS.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.all(DS.s1),
              decoration: BoxDecoration(color: DS.blueMuted, borderRadius: BorderRadius.circular(DS.r1)),
              child: const Icon(Icons.pie_chart_rounded, color: DS.blue, size: 16)),
          const SizedBox(width: DS.s1),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Patient Type Distribution',
                style: TextStyle(color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w700)),
            Text('Today · Total across all branches',
                style: const TextStyle(color: DS.neutral, fontSize: DS.caption)),
          ]),
        ]),
        const SizedBox(height: DS.s2 + 4),

        if (total == 0)
          _EmptyOpsState(
            icon: Icons.people_outline_rounded,
            message: 'No patients today',
            hint: 'Patient data will appear once registration begins',
          )
        else
          LayoutBuilder(builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 580;
            final donut = _AnimatedDonut(
              size: isDesktop ? 210 : 190,
              values: [s.zakat.toDouble(), s.nonZakat.toDouble(), s.gmwf.toDouble()],
              colors: [t.zakat, t.nonZakat, t.gmwf],
              center: Column(mainAxisSize: MainAxisSize.min, children: [
                _AnimatedCount(value: total,
                    style: TextStyle(color: t.textPrimary,
                        fontSize: isDesktop ? 34 : 28, fontWeight: FontWeight.w900)),
                Text('patients', style: const TextStyle(color: DS.neutral, fontSize: 12)),
              ]),
            );

            final legend = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _legendItem(t.zakat, 'Zakat', s.zakat, zPct, 'PKR ${fmtNum(s.zakat * 20)}', '@ PKR 20'),
              const SizedBox(height: DS.s1 + 4),
              _legendItem(t.nonZakat, 'Non-Zakat', s.nonZakat, nPct, 'PKR ${fmtNum(s.nonZakat * 100)}', '@ PKR 100'),
              const SizedBox(height: DS.s1 + 4),
              _legendItem(t.gmwf, 'GMWF', s.gmwf, gPct, 'Free', 'No charge'),
            ]);

            if (isDesktop) {
              return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                donut, const SizedBox(width: DS.s4), Expanded(child: legend),
              ]);
            }
            return Column(children: [Center(child: donut), const SizedBox(height: DS.s3), legend]);
          }),
      ]),
    );
  }

  Widget _legendItem(Color color, String label, int count, int pct, String rev, String rate) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.s2, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(DS.r1 + 4),
          border: Border.all(color: color.withValues(alpha: 0.20)),
        ),
        child: Row(children: [
          Container(width: 10, height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: DS.s1 + 4),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
            Text('$count patients  ·  $rev',
                style: const TextStyle(color: DS.neutral, fontSize: 11)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: DS.s1 + 2, vertical: 4),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(DS.r1)),
            child: Text('$pct%', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

// ════════════════════════════════════════════════════════════════════════════════
// K. EXECUTIVE GLOBAL OVERVIEW GRID
// ════════════════════════════════════════════════════════════════════════════════

class GlobalOverviewGrid extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  final int branchCount;

  const GlobalOverviewGrid({
    super.key,
    required this.t,
    required this.s,
    required this.branchCount,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row([
          _tile(
            label: 'Total Revenue',
            value: s.totalRevenue,
            prefix: 'PKR ',
            icon: Icons.payments_rounded,
            color: t.accent,
            itemCount: s.donations > 0 ? 'Inc. Donations' : null,
          ),
          _tile(
            label: 'Total Patients',
            value: s.tokens,
            icon: Icons.people_alt_rounded,
            color: DS.blue,
            itemCount: '$branchCount Branches',
          ),
        ]),
        const SizedBox(height: DS.s2),
        _row([
          _tile(
            label: 'Food Tokens',
            value: s.dasterkhwaan,
            icon: Icons.restaurant_rounded,
            color: DS.orange,
            itemCount: '${s.dasterkhwaanServed} served',
          ),
          _tile(
            label: 'Donations',
            value: s.donations,
            prefix: 'PKR ',
            icon: Icons.volunteer_activism_rounded,
            color: DS.purple,
            itemCount: 'Today',
          ),
        ]),
      ],
    );
  }

  Widget _row(List<Widget> children) => Row(
        children: [
          children[0],
          const SizedBox(width: DS.s2),
          children[1],
        ],
      );

  Widget _tile({
    required String label,
    required int value,
    String? prefix,
    required IconData icon,
    required Color color,
    String? itemCount,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(DS.s2 + 2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(DS.r2),
          border: Border.all(color: DS.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(DS.s1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(DS.r1),
                  ),
                  child: Icon(icon, color: color, size: 16),
                ),
                const Spacer(),
                if (itemCount != null)
                  Text(
                    itemCount,
                    style: TextStyle(
                      color: DS.neutral,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: DS.s2),
            _AnimatedCount(
              value: value,
              prefix: prefix ?? '',
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: DS.neutral,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// L. SERVICE REVENUE CARD
// ════════════════════════════════════════════════════════════════════════════════

class ServiceRevenueCard extends StatelessWidget {
  final RoleThemeData t;
  final BranchStats s;
  const ServiceRevenueCard({super.key, required this.t, required this.s});

  @override
  Widget build(BuildContext context) {
    const dasColor = DS.orange;
    const donColor = DS.purple;
    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: DS.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Services & Donations',
            style: TextStyle(color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: DS.s2),
        _svcRow(Icons.restaurant_rounded, dasColor, 'Dasterkhwaan – Meals',
            '${s.dasterkhwaan} issued · ${s.dasterkhwaanServed} served · × PKR 10',
            s.dasterkhwaanRevenue),
        const SizedBox(height: DS.s1),
        Divider(height: 1, color: DS.border),
        const SizedBox(height: DS.s1),
        _svcRow(Icons.volunteer_activism_rounded, donColor, 'Donations Collected',
            'Cash & transfers · today', s.donations),
        const SizedBox(height: DS.s2),
        Divider(height: 1, color: DS.border),
        const SizedBox(height: DS.s1 + 4),
        Row(children: [
          const Text('Services Total', style: TextStyle(
              color: DS.neutral, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          _AnimatedCount(value: s.dasterkhwaanRevenue + s.donations, prefix: 'PKR ',
              style: TextStyle(color: t.accent, fontSize: 16, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _svcRow(IconData icon, Color color, String title, String sub, int amount) =>
      Row(children: [
        Container(padding: const EdgeInsets.all(DS.s1 + 2),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(DS.r1)),
            child: Icon(icon, color: color, size: 18)),
        const SizedBox(width: DS.s1 + 4),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: DS.neutral, fontSize: DS.caption)),
        ])),
        _AnimatedCount(value: amount, prefix: 'PKR ',
            style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800)),
      ]);
}

// ════════════════════════════════════════════════════════════════════════════════
// L. BRANCH SUMMARY CARD (kept — backward compat, used standalone)
// ════════════════════════════════════════════════════════════════════════════════

class BranchSummaryCard extends StatelessWidget {
  final RoleThemeData t;
  final String branchId;
  final String branchName;
  final String? location;
  final int? revenueTarget;

  const BranchSummaryCard({
    super.key, required this.t, required this.branchId,
    required this.branchName, this.location, this.revenueTarget = 3000000,
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<BranchStats>(
    future: fetchBranchStats(branchId),
    builder: (_, snap) {
      final loading = snap.connectionState == ConnectionState.waiting;
      final s = snap.data ?? const BranchStats();
      final target = revenueTarget ?? 3000000;
      final achPct = target > 0
          ? (s.totalRevenue / target * 100).clamp(0, 100).toDouble() : 0.0;

      if (loading) return DashLoadingCard(t: t, height: 90);
      return AnimatedOpacity(
        opacity: 1.0, duration: const Duration(milliseconds: 400),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(DS.r2),
            border: Border.all(color: DS.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(DS.s2, DS.s2 - 2, DS.s2 - 2, DS.s2 - 2),
              decoration: const BoxDecoration(
                color: DS.neutralBg,
                borderRadius: BorderRadius.vertical(top: Radius.circular(DS.r2)),
              ),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(branchName, style: const TextStyle(
                      color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w900)),
                  if (location != null && location!.isNotEmpty)
                    Text(location!, style: const TextStyle(color: DS.neutral, fontSize: 10)),
                ])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: DS.blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(DS.r1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.people_alt_rounded, size: 12, color: DS.blue),
                      const SizedBox(width: 4),
                      _AnimatedCount(value: s.tokens,
                        style: const TextStyle(color: DS.blue, fontSize: 13, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ]),
            ),
            Container(height: 0.5, color: DS.border),

            // Body
            Padding(
              padding: const EdgeInsets.all(DS.s2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Revenue progress
                Row(children: [
                  Icon(Icons.payments_rounded, size: 12, color: t.accent),
                  const SizedBox(width: 6),
                  const Text('Revenue', style: TextStyle(color: DS.neutral, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _AnimatedCount(value: s.totalRevenue, prefix: 'PKR ',
                      style: TextStyle(color: t.accent, fontSize: 13, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 8),
                _AnimatedProgressBar(value: achPct / 100, color: t.accent),
                const SizedBox(height: 6),
                
                // Patient Distribution Spark
                if (s.tokens > 0) ...[
                  const SizedBox(height: 4),
                  _AnimatedDistBar(zakat: s.zakat, nonZakat: s.nonZakat, gmwf: s.gmwf,
                      colorZ: t.zakat, colorNZ: t.nonZakat, colorG: t.gmwf),
                  const SizedBox(height: 12),
                ],

                // Condensed Footer stats
                Row(children: [
                   _svcIcon(Icons.restaurant_rounded, DS.orange, '${s.dasterkhwaan}'),
                   const SizedBox(width: 12),
                   _svcIcon(Icons.volunteer_activism_rounded, DS.purple, fmtPKR(s.donations)),
                ]),
              ]),
            ),
          ]),
        ),
      );
    },
  );

  Widget _svcIcon(IconData icon, Color color, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color.withValues(alpha: 0.7), size: 13),
      const SizedBox(width: 4),
      Text(value, style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
    ],
  );


  Widget _typeCol(IconData icon, Color color, String label, int count) =>
      Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: DS.neutral, fontSize: 10)),
        const SizedBox(height: 2),
        _AnimatedCount(value: count,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
      ]);

  Widget _svcChip(IconData icon, Color color, String label, String value) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(DS.r1)),
            child: Icon(icon, color: color, size: 13)),
        const SizedBox(width: DS.s1),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: DS.neutral, fontSize: 11, fontWeight: FontWeight.w600)),
          Text(value, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
      ]);
}

// ════════════════════════════════════════════════════════════════════════════════
// M. DONATIONS SUMMARY CARD
// ════════════════════════════════════════════════════════════════════════════════

class DonationsSummaryCard extends StatelessWidget {
  final RoleThemeData t;
  final List<Map<String, dynamic>> branches;
  final int totalDonations;
  const DonationsSummaryCard({super.key, required this.t,
      required this.branches, required this.totalDonations});

  @override
  Widget build(BuildContext context) {
    final activeBranches = branches.where((b) => (b['donations'] as int) > 0).toList();
    return Container(
      padding: const EdgeInsets.all(DS.s2 + 4),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(DS.r2),
        border: Border.all(color: DS.purple.withValues(alpha: 0.25)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.all(DS.s1),
              decoration: BoxDecoration(color: DS.purpleMuted,
                  borderRadius: BorderRadius.circular(DS.r1)),
              child: const Icon(Icons.volunteer_activism_rounded, color: DS.purple, size: 18)),
          const SizedBox(width: DS.s1),
          const Text('Donations Collected',
              style: TextStyle(color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          _AnimatedCount(value: totalDonations, prefix: 'PKR ',
              style: const TextStyle(color: DS.purple, fontSize: 18, fontWeight: FontWeight.w900)),
        ]),

        if (activeBranches.isEmpty) ...[
          const SizedBox(height: DS.s2),
          _EmptyOpsState(
            icon: Icons.volunteer_activism_outlined,
            message: 'No donations recorded today',
            hint: 'Donations will appear here once collected at any branch',
          ),
        ] else ...[
          const SizedBox(height: DS.s2),
          const Divider(height: 1, color: DS.border),
          const SizedBox(height: DS.s1 + 4),
          ...activeBranches.map((b) => Padding(
            padding: const EdgeInsets.only(bottom: DS.s1),
            child: Row(children: [
              Container(width: 6, height: 6,
                  decoration: const BoxDecoration(color: DS.purple, shape: BoxShape.circle)),
              const SizedBox(width: DS.s1),
              Expanded(child: Text(b['name'] as String,
                  style: const TextStyle(color: Color(0xFF374151), fontSize: 13))),
              Text(fmtPKR(b['donations'] as int),
                  style: const TextStyle(color: DS.purple, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          )),
        ],
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// N. BRANCH PERFORMANCE HEADER (backward compat)
// ════════════════════════════════════════════════════════════════════════════════

class BranchPerformanceHeader extends StatelessWidget {
  final RoleThemeData t;
  final int branchCount;
  const BranchPerformanceHeader({super.key, required this.t, required this.branchCount});

  @override
  Widget build(BuildContext context) => Row(children: [
    const Text('Branch Performance', style: TextStyle(
        color: Color(0xFF111827), fontSize: DS.h2, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
    const Spacer(),
    Text('$branchCount branches', style: const TextStyle(color: DS.neutral, fontSize: 13)),
  ]);
}

// ════════════════════════════════════════════════════════════════════════════════
// L. GLOBAL FILTER BAR — Decision driven filtering
// ════════════════════════════════════════════════════════════════════════════════

class GlobalFilterBar extends StatelessWidget {
  final DashboardController controller;
  final List<Map<String, dynamic>> branches;

  const GlobalFilterBar({
    super.key,
    required this.controller,
    this.branches = const [],
  });

  static String formatRangeLabel(DashboardFilter filter) {
    final range = _resolveFilter(filter);
    final df = DateFormat('d MMM yyyy');
    if (range.start.year == range.end.year &&
        range.start.month == range.end.month &&
        range.start.day == range.end.day) {
      if (range.start.day == DateTime.now().day &&
          range.start.month == DateTime.now().month &&
          range.start.year == DateTime.now().year) {
        return 'Today (${DateFormat('d MMM').format(range.start)})';
      }
      return df.format(range.start);
    }
    final daysCount = range.end.difference(range.start).inDays + 1;
    return '${DateFormat('d MMM').format(range.start)} - ${df.format(range.end)} ($daysCount Days)';
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    return ValueListenableBuilder<DashboardFilter>(
      valueListenable: controller,
      builder: (context, filter, child) {
        final isFiltered = filter.timeRange != TimeRange.today ||
            (filter.branchId.isNotEmpty && filter.branchId != 'all') ||
            filter.patientType != null ||
            filter.multiDayMedicineOnly;

        final activeBranchName = filter.branchId.isEmpty || filter.branchId == 'all'
            ? 'All Branches'
            : (branches.firstWhere((b) => b['id'] == filter.branchId, orElse: () => <String, dynamic>{'name': filter.branchId})['name'] ?? filter.branchId);

        final rangeText = formatRangeLabel(filter);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => DashboardFilterDialog(
                      controller: controller,
                      branches: branches,
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: isFiltered ? t.accent.withValues(alpha: 0.12) : t.bgCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isFiltered ? t.accent : t.bgRule,
                      width: isFiltered ? 1.4 : 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 15,
                        color: isFiltered ? t.accent : t.textSecondary,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'Filters',
                        style: TextStyle(
                          color: isFiltered ? t.accent : t.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: isFiltered
                              ? t.accent.withValues(alpha: 0.18)
                              : (t.isDarkCanvas ? Colors.white10 : const Color(0xFFF1F5F9)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$rangeText · $activeBranchName${filter.patientType != null ? ' · ${filter.patientType!.toUpperCase()}' : ''}${filter.multiDayMedicineOnly ? ' · 2+ Days' : ''}',
                          style: TextStyle(
                            color: isFiltered ? t.accent : t.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: isFiltered ? t.accent : t.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isFiltered) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'Reset Filters',
                child: InkWell(
                  onTap: controller.resetFilters,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                    ),
                    child: const Icon(Icons.restart_alt_rounded, size: 15, color: Colors.redAccent),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class DashboardFilterDialog extends StatelessWidget {
  final DashboardController controller;
  final List<Map<String, dynamic>> branches;

  const DashboardFilterDialog({
    super.key,
    required this.controller,
    this.branches = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final showBranchSelector = branches.length > 1;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ValueListenableBuilder<DashboardFilter>(
        valueListenable: controller,
        builder: (context, filter, _) {
          final isFiltered = filter.timeRange != TimeRange.today ||
              (filter.branchId.isNotEmpty && filter.branchId != 'all') ||
              filter.patientType != null ||
              filter.multiDayMedicineOnly;

          return Container(
            width: 640,
            constraints: const BoxConstraints(maxWidth: 700),
            decoration: BoxDecoration(
              color: t.bgCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: t.bgRule, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dialog Top Bar
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.tune_rounded, size: 18, color: t.accent),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Dashboard Data Filters',
                              style: TextStyle(
                                color: t.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              GlobalFilterBar.formatRangeLabel(filter),
                              style: TextStyle(
                                color: t.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isFiltered)
                        TextButton.icon(
                          onPressed: controller.resetFilters,
                          icon: const Icon(Icons.restart_alt_rounded, size: 15),
                          label: const Text('Reset All', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.close_rounded, size: 20, color: t.textSecondary),
                        splashRadius: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(color: t.bgRule, height: 1),
                  const SizedBox(height: 16),

                  // Section 1: Time Range Presets
                  _buildSectionLabel(Icons.calendar_today_rounded, 'Time Range & Date Presets', t),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _timeChip('Today', TimeRange.today, filter.timeRange, t),
                      _timeChip('Yesterday', TimeRange.yesterday, filter.timeRange, t),
                      _timeChip('7 Days', TimeRange.week, filter.timeRange, t),
                      _timeChip('14 Days', TimeRange.biweek, filter.timeRange, t),
                      _timeChip('30 Days', TimeRange.month, filter.timeRange, t),
                      _timeChip('This Month', TimeRange.thisMonth, filter.timeRange, t),
                      _customDateChip(context, filter, t),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Section 2: Branches (if multiple)
                  if (showBranchSelector) ...[
                    _buildSectionLabel(Icons.location_on_rounded, 'Selected Branch', t),
                    const SizedBox(height: 10),
                    Builder(
                      builder: (context) {
                        final filteredBranches = branches.where((b) {
                          final id = (b['id'] ?? '').toString().toLowerCase().trim();
                          final name = (b['name'] ?? '').toString().toLowerCase().trim();
                          return id.isNotEmpty && id != 'all' && id != 'global' && name != 'all' && name != 'global';
                        }).toList();

                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _branchChip('all', 'All Branches', filter.branchId, t),
                            ...filteredBranches.map((b) => _branchChip(b['id'] ?? '', b['name'] ?? '', filter.branchId, t)),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                  ],

                  // Section 3: Patient Classification
                  _buildSectionLabel(Icons.category_rounded, 'Patient Classification', t),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _typeChip('All Patients', null, filter.patientType, DS.neutral),
                      _typeChip('Zakat', 'zakat', filter.patientType, DS.zakat),
                      _typeChip('Non-Zakat', 'non-zakat', filter.patientType, DS.nonZakat),
                      _typeChip('GMWF', 'gmwf', filter.patientType, DS.gmwf),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Section 4: Dispensary Course Filter
                  _buildSectionLabel(Icons.medication_liquid_rounded, 'Dispensary Course Filter', t),
                  const SizedBox(height: 10),
                  _buildMultiDayCourseChip(filter, t),
                  const SizedBox(height: 22),

                  // Apply & Close
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.check_rounded, size: 16),
                        label: const Text('Apply & Close', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionLabel(IconData icon, String title, RoleThemeData t) {
    return Row(
      children: [
        Icon(icon, size: 13, color: DS.neutral),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            color: DS.neutral,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _timeChip(String label, TimeRange value, TimeRange activeValue, RoleThemeData t) {
    final active = value == activeValue;
    return InkWell(
      onTap: () => controller.setTimeRange(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? t.accent : DS.neutralBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? t.accent : DS.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? Colors.white : DS.neutral,
          ),
        ),
      ),
    );
  }

  Widget _customDateChip(BuildContext context, DashboardFilter filter, RoleThemeData t) {
    final active = filter.timeRange == TimeRange.custom;
    final label = active && filter.customRange != null
        ? 'Custom (${filter.customRange!.end.difference(filter.customRange!.start).inDays + 1}d) 📅'
        : 'Custom Range 📅';

    return InkWell(
      onTap: () async {
        final currentRange = controller.value.customRange ?? _resolveFilter(controller.value);
        final range = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 365)),
          initialDateRange: currentRange,
        );
        if (range != null) {
          controller.setCustomRange(range);
        } else {
          controller.setTimeRange(TimeRange.custom);
        }
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? t.accent : DS.neutralBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? t.accent : DS.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? Colors.white : DS.neutral,
          ),
        ),
      ),
    );
  }

  Widget _branchChip(String branchId, String branchName, String activeBranchId, RoleThemeData t) {
    final active = (branchId == 'all' && (activeBranchId.isEmpty || activeBranchId == 'all' || activeBranchId == 'global')) ||
        (branchId != 'all' && branchId.toLowerCase().trim() == activeBranchId.toLowerCase().trim());
    return InkWell(
      onTap: () => controller.setBranch(branchId),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? DS.blue : DS.neutralBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? DS.blue : DS.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_rounded, size: 12, color: active ? Colors.white : DS.neutral),
            const SizedBox(width: 5),
            Text(
              branchName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? Colors.white : DS.neutral,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(String label, String? value, String? activeValue, Color color) {
    final active = value == activeValue;
    return InkWell(
      onTap: () => controller.setPatientType(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : DS.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : DS.neutral,
            fontSize: 11,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildMultiDayCourseChip(DashboardFilter filter, RoleThemeData t) {
    final active = filter.multiDayMedicineOnly;
    return InkWell(
      onTap: controller.toggleMultiDayMedicineOnly,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF0284C7) : const Color(0xFF0284C7).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? const Color(0xFF0284C7) : const Color(0xFF0284C7).withValues(alpha: 0.3),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.check_circle_rounded : Icons.medication_rounded,
              size: 14,
              color: active ? Colors.white : const Color(0xFF0284C7),
            ),
            const SizedBox(width: 6),
            Text(
              'Multi-Day Course (2+ Days)',
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFF0284C7),
                fontSize: 11,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// M. ACTIONABLE KPI CARD — Premium data display
// ════════════════════════════════════════════════════════════════════════════════

class ActionableKPICard extends StatelessWidget {
  final String label;
  final String value;
  final String? prefix;
  final IconData icon;
  final Color color;
  final String? insight;
  final bool isPrimary;
  final String? trend;

  const ActionableKPICard({
    super.key,
    required this.label,
    required this.value,
    this.prefix,
    required this.icon,
    required this.color,
    this.insight,
    this.isPrimary = false,
    this.trend,
  });

  @override
  Widget build(BuildContext context) {
    final Color mainColor = color;
    final LinearGradient gradient = LinearGradient(
      colors: [
        mainColor,
        Color.lerp(mainColor, Colors.black, 0.32)!,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final Color glowColor = mainColor.withValues(alpha: 0.30);
    final Color labelColor = Colors.white.withValues(alpha: 0.75);
    final Color valueColor = Colors.white;
    final Color prefixColor = Colors.white.withValues(alpha: 0.7);
    final Color iconBgColor = Colors.white.withValues(alpha: 0.15);
    final Color iconColor = Colors.white;
    final Color insightBgColor = Colors.white.withValues(alpha: 0.15);
    final Color insightTextColor = Colors.white;

    return Container(
      padding: EdgeInsets.all(isPrimary ? 20 : 16),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: glowColor,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -20,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: iconBgColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: iconColor, size: isPrimary ? 24 : 18),
                  ),
                  const Spacer(),
                  if (trend != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        trend!,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                label,
                style: TextStyle(color: labelColor, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.2),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (prefix != null)
                    Text(
                      prefix!,
                      style: TextStyle(color: prefixColor, fontSize: isPrimary ? 20 : 14, fontWeight: FontWeight.w700),
                    ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: TextStyle(
                          color: valueColor,
                          fontSize: isPrimary ? 32 : 24,
                          fontWeight: FontWeight.w900,
                          height: 1.1,
                          fontFamily: 'DMMono',
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (insight != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: insightBgColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    insight!,
                    style: TextStyle(color: insightTextColor, fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// N. DASHBOARD SECTION HEADER
// ════════════════════════════════════════════════════════════════════════════════

class DashSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  const DashSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DS.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(color: DS.neutral, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (actions != null) ...actions!,
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// Backward-compat shims for widgets still referenced in older screens
// ════════════════════════════════════════════════════════════════════════════════

// _KpiCard shim
class _KpiCard extends StatelessWidget {
  final RoleThemeData t;
  final IconData icon;
  final Color color;
  final String label;
  final Widget child;
  const _KpiCard({required this.t, required this.icon, required this.color,
      required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(DS.s2),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(DS.r2),
      border: Border.all(color: color.withValues(alpha: 0.20)),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 12, offset: const Offset(0, 3))],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.all(DS.s1),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(DS.r1)),
          child: Icon(icon, color: color, size: 18)),
      const Spacer(), child,
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: DS.neutral, fontSize: DS.caption)),
    ]),
  );
}