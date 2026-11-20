// lib/pages/branches.dart

import 'dart:ui' as ui;
import 'package:gmwf/design/tokens/colors.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GComfortColorsContext;
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/shadows.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/camp_session_service.dart';
import '../services/user_theme_service.dart';
import '../providers/branches_providers.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';

import 'branches_register.dart';
import 'dispensary/patient_detail_screen.dart';
import '../services/local_storage_service.dart';
import '../services/branch_record_service.dart';
import '../utils/branch_labels.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _resolvePatientCampLabel(Map<String, dynamic> p, String branchId) {
  final parts = <String>[];
  final hasCamps = CampSessionService.hasCampsForBranch(branchId);

  // 1. Resolve Camp / Facility (only for multi-camp branches like Karachi)
  if (hasCamps) {
    final cId = (p['dispensaryId'] ?? p['campId'] ?? p['subDispensaryId'])?.toString().trim();
    if (cId != null && cId.isNotEmpty && cId != 'all' && cId != 'main') {
      final label = CampSessionService.getCampLabel(cId, branchId);
      if (label.isNotEmpty) parts.add(label);
    } else {
      final serial = (p['serial'] ?? p['id'] ?? '').toString();
      final sParts = serial.split('-');
      if (sParts.length > 2) {
        final tag = sParts[1].toUpperCase();
        if (tag == 'SADD' || tag == 'SAD' || tag == 'SADDAR' || tag == 'KAP' || tag == 'KAPAYYA') {
          parts.add('Saddar Dispensary');
        } else if (tag == 'HC' || tag == 'HAJI' || tag == 'HAJICAMP') {
          parts.add('Haji Camp Dispensary');
        } else if (tag.isNotEmpty) {
          parts.add(tag);
        }
      }
    }
  }

  // 2. Resolve Shift / Session
  final sess = (p['session'] ?? p['shift'] ?? p['campSession'])?.toString().toLowerCase().trim();
  if (sess == 'morning') {
    parts.add('🌅 Morning');
  } else if (sess == 'evening') {
    parts.add('🌆 Evening');
  } else if (sess == 'night') {
    parts.add('🌙 Night');
  } else if (sess != null && sess.isNotEmpty && sess != 'day' && sess != 'all') {
    parts.add(sess[0].toUpperCase() + sess.substring(1));
  } else {
    final dispAt = p['dispensedAt'] ?? p['createdAt'] ?? p['time'];
    DateTime? dt;
    if (dispAt is DateTime) {
      dt = dispAt;
    } else if (dispAt is String) {
      dt = DateTime.tryParse(dispAt);
    }
    if (dt != null) {
      if (dt.hour >= 6 && dt.hour < 14) {
        parts.add('🌅 Morning');
      } else if (dt.hour >= 14 && dt.hour < 22) {
        parts.add('🌆 Evening');
      } else {
        parts.add('🌙 Night');
      }
    }
  }

  if (parts.isEmpty) {
    final bName = branchId.isNotEmpty ? branchId[0].toUpperCase() + branchId.substring(1) : 'Main';
    parts.add('$bName Facility');
  }

  return parts.join(' • ');
}

String _formatCnic(String raw) {
  final clean = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (clean.length == 13) {
    return '${clean.substring(0, 5)}-${clean.substring(5, 12)}-${clean.substring(12)}';
  }
  return raw;
}

bool _isVitalsAllowedForBranchOrCamp(String branchId, {String? campId}) {
  final b = branchId.toLowerCase().trim();
  if (b.isEmpty || b == 'all' || b == 'global') return true;

  if (campId != null && campId.isNotEmpty && campId != 'all') {
    final camps = CampSessionService.getCampsForBranch(b, includeClosed: true);
    for (final c in camps) {
      final id = (c['id'] ?? '').toString().toLowerCase().trim();
      final tag = (c['dispensaryTag'] ?? c['tag'] ?? '').toString().toLowerCase().trim();
      if (id == campId.toLowerCase().trim() || tag == campId.toLowerCase().trim()) {
        if (c['allowVitalsToken'] != null) {
          final v = c['allowVitalsToken'];
          return v == true || v == 'true' || v == 1;
        }
      }
    }
  }

  return LocalStorageService.isVitalsTokenAllowed(b);
}

// ─────────────────────────────────────────────────────────────────────────────
// Branches Main Widget
// ─────────────────────────────────────────────────────────────────────────────

class Branches extends ConsumerStatefulWidget {
  final bool showRegisterButton;
  final String? branchId;
  final bool? isManager;
  final String? initialBranchId;
  final bool? flagReverted;

  const Branches({
    super.key,
    this.showRegisterButton = true,
    this.branchId,
    this.isManager,
    this.initialBranchId,
    this.flagReverted,
  });

  @override
  ConsumerState<Branches> createState() => _BranchesState();
}

class _BranchesState extends ConsumerState<Branches> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _recordStage(Map<String, dynamic> record) {
    final status = (record['status'] ?? '').toString().toLowerCase().trim();
    final dispenseStatus = (record['dispenseStatus'] ?? '').toString().toLowerCase().trim();

    if (status == 'dispensed' || dispenseStatus == 'dispensed' || record['dispensedAt'] != null) {
      return 'dispensed';
    }
    if (status == 'prescribed' ||
        status == 'completed' ||
        status == 'waiting_for_dispense' ||
        status == 'waiting_to_dispense' ||
        dispenseStatus == 'waiting_for_dispense' ||
        dispenseStatus == 'waiting_to_dispense' ||
        dispenseStatus == 'waiting') {
      return 'waiting_dispensary';
    }
    return 'waiting_doctor';
  }

  int _compareRecords(Map<String, dynamic> left, Map<String, dynamic> right) {
    String valueOf(Map<String, dynamic> record) {
      switch (_sortField) {
        case 'name':
          return (record['name'] ?? record['patientName'] ?? '').toString().toLowerCase();
        case 'status':
          return _recordStage(record);
        case 'type':
          return (record['type'] ?? record['queueType'] ?? '').toString().toLowerCase();
        case 'facility':
          return (record['campId'] ?? record['dispensaryId'] ?? record['dispensaryTag'] ?? '').toString().toLowerCase();
        case 'token':
        default:
          return (record['serial'] ?? record['id'] ?? '').toString().toLowerCase();
      }
    }

    final result = valueOf(left).compareTo(valueOf(right));
    return _sortAscending ? result : -result;
  }

  String? _selectedBranchId;
  String _selectedBranchName = 'Branch';
  String _searchQuery = '';
  String _sortField = 'token';
  bool _sortAscending = true;
  int _currentPage = 1;
  int _rowsPerPage = 10;
  String _chartRange = '7d'; // '7d', '14d', '30d', 'month'
  bool _showBarChart = false;
  String _selectedCampFilter = 'all'; // 'all', 'haji', 'saddar'
  // Hover changes repaint only the chart; a setState rebuilt the whole page
  // (patient search scan, peak record lookup) on every mouse move.
  final ValueNotifier<int?> _hoveredChartIndex = ValueNotifier<int?>(null);
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialId = widget.branchId ?? widget.initialBranchId ?? LocalStorageService.getActiveBranchId();
    if (initialId != null && initialId.isNotEmpty && initialId != 'all') {
      _selectedBranchId = initialId;
    }
  }

  @override
  void didUpdateWidget(Branches oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.branchId != oldWidget.branchId || widget.initialBranchId != oldWidget.initialBranchId) {
      final newId = widget.branchId ?? widget.initialBranchId;
      if (newId != null && newId.isNotEmpty && newId != 'all') {
        setState(() {
          _selectedBranchId = newId;
          _currentPage = 1;
        });
      }
    }
  }

  Map<String, dynamic>? _cachedPerfData;
  String? _cachedPerfKey;
  DateTime? _lastPerfComputeTime;

  Map<String, dynamic> _computeRealPerformanceData(String branchId, String range, {List<Map<String, dynamic>>? extraRecords}) {
    final curKey = '$branchId|$range|$_selectedCampFilter|${extraRecords?.length ?? 0}';
    final now = DateTime.now();
    if (_cachedPerfKey == curKey &&
        _cachedPerfData != null &&
        _lastPerfComputeTime != null &&
        now.difference(_lastPerfComputeTime!).inSeconds < 15) {
      return _cachedPerfData!;
    }

    int numDays = 7;
    if (range == '14d') numDays = 14;
    if (range == '30d') numDays = 30;
    if (range == 'month') numDays = now.day.clamp(1, 31);

    final days = <DateTime>[];
    for (int i = numDays - 1; i >= 0; i--) {
      days.add(DateTime(now.year, now.month, now.day).subtract(Duration(days: i)));
    }

    final tokensList = List<double>.filled(numDays, 0.0);
    final prescList = List<double>.filled(numDays, 0.0);
    final dispList = List<double>.filled(numDays, 0.0);

    final dfDdmmyy = DateFormat('ddMMyy');
    final dfYmd = DateFormat('yyyy-MM-dd');
    final dfLabel = DateFormat('d MMM');

    final dateIndexMap = <String, int>{};
    final labels = <String>[];
    for (int i = 0; i < days.length; i++) {
      dateIndexMap[dfDdmmyy.format(days[i])] = i;
      dateIndexMap[dfYmd.format(days[i])] = i;
      labels.add(dfLabel.format(days[i]));
    }

    final targetB = branchId.toLowerCase().trim();
    final seenSerials = <String>{};

    void processRecord(Map<dynamic, dynamic> val) {
      final b = (val['branchId'] ?? '').toString().toLowerCase().trim();
      if (targetB != 'all' && b.isNotEmpty && !b.contains(targetB) && !targetB.contains(b)) {
        return;
      }
      if (_selectedCampFilter != 'all') {
        final matches = CampSessionService.matchesCamp(
          selectedCamp: _selectedCampFilter,
          dispensaryId: val['dispensaryId']?.toString(),
          campId: val['campId']?.toString(),
          dispensaryTag: val['dispensaryTag']?.toString(),
          serial: (val['serial'] ?? val['tokenSerial'] ?? val['id'])?.toString(),
        );
        if (!matches) return;
      }

      final serial = (val['serial'] ?? val['tokenSerial'] ?? val['id'] ?? '').toString().trim().toUpperCase();
      if (serial.isNotEmpty) {
        // Serials are per-branch day counters: in the all-branches view the same
        // serial at two branches is two tokens.
        final dedupKey = (targetB == 'all' && b.isNotEmpty)
            ? '${LocalStorageService.sanitizeBranchId(b, fallback: b)}|$serial'
            : serial;
        if (!seenSerials.add(dedupKey)) return;
      }

      var dk = (val['dateKey'] ?? val['date'] ?? '').toString().trim();
      if (dk.contains('_')) {
        dk = dk.split('_')[0];
      }
      if (serial.isNotEmpty && (dk.isEmpty || dk.length != 6)) {
        final sdk = CampSessionService.getDateKeyFromSerial(serial);
        if (sdk.isNotEmpty) dk = sdk;
      }
      if (dk.length > 6) {
        try {
          final parsed = DateTime.tryParse(dk);
          if (parsed != null) {
            dk = dfDdmmyy.format(parsed);
          } else {
            final alt = DateFormat('dd-MM-yyyy').tryParse(dk) ??
                        DateFormat('dd/MM/yyyy').tryParse(dk) ??
                        DateFormat('dd MMM yyyy').tryParse(dk);
            if (alt != null) dk = dfDdmmyy.format(alt);
          }
        } catch (_) {}
      }
      if (dateIndexMap[dk] == null) {
        final tsStr = (val['dispensedAt'] ?? val['createdAt'] ?? val['timestamp'])?.toString();
        if (tsStr != null && tsStr.isNotEmpty) {
          final parsed = DateTime.tryParse(tsStr);
          if (parsed != null) {
            final altDk = dfDdmmyy.format(parsed);
            if (dateIndexMap.containsKey(altDk)) dk = altDk;
          }
        }
      }

      final idx = dateIndexMap[dk];
      if (idx != null) {
        tokensList[idx] += 1.0;
        final status = (val['status'] ?? '').toString().toLowerCase();
        final dStatus = (val['dispenseStatus'] ?? '').toString().toLowerCase();
        if (status == 'completed' || status == 'prescribed' || dStatus == 'dispensed' || val['dispensedAt'] != null) {
          prescList[idx] += 1.0;
        }
        if (dStatus == 'dispensed' || status == 'dispensed' || val['dispensedAt'] != null) {
          dispList[idx] += 1.0;
        }
      }
    }

    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final box = Hive.box(LocalStorageService.entriesBox);
        for (final val in box.values) {
          if (val is Map) processRecord(val);
        }
      }
    } catch (_) {}

    if (extraRecords != null) {
      for (final val in extraRecords) {
        processRecord(val);
      }
    }

    final result = {
      'tokens': tokensList,
      'prescriptions': prescList,
      'dispensary': dispList,
      'labels': labels,
    };
    _cachedPerfData = result;
    _cachedPerfKey = curKey;
    _lastPerfComputeTime = now;
    return result;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _hoveredChartIndex.dispose();
    super.dispose();
  }

  void _showDateRangePicker(BuildContext context, RoleThemeData t) async {
    final isDark = t.isDarkCanvas;
    final currentRange = ref.read(branchDateRangeProvider);
    final initialDateRange = DateTimeRange(
      start: currentRange.start ?? DateTime.now(),
      end: currentRange.end ?? DateTime.now(),
    );

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: initialDateRange,
      builder: (context, child) {
        return Theme(
          data: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: t.accent,
              brightness: isDark ? Brightness.dark : Brightness.light,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      ref.read(branchDateRangeProvider.notifier).state = DateRange(
        start: picked.start,
        end: picked.end,
      );
      setState(() => _currentPage = 1);
    }
  }

  void _showFilterModal(BuildContext context, RoleThemeData t) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final typeFilter = ref.watch(branchTypeFilterProvider);
            final shiftFilter = ref.watch(branchShiftFilterProvider);
            final mDay = ref.watch(branchMultiDayFilterProvider);
            final mVisit = ref.watch(branchMultiVisitFilterProvider);

            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Filter Records", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.textPrimary)),
                      TextButton(
                        onPressed: () {
                          ref.read(branchTypeFilterProvider.notifier).state = null;
                          ref.read(branchShiftFilterProvider.notifier).state = null;
                          ref.read(branchMultiDayFilterProvider.notifier).state = false;
                          ref.read(branchMultiVisitFilterProvider.notifier).state = false;
                          setState(() {
                            _sortField = 'token';
                            _sortAscending = true;
                            _currentPage = 1;
                          });
                          setModalState(() {});
                        },
                        child: Text("Reset All", style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text("Queue Type", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textSecondary)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildModalChip("All Types", typeFilter == null, () {
                        ref.read(branchTypeFilterProvider.notifier).state = null;
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                      _buildModalChip(BranchLabels.zakat(_selectedBranchId), typeFilter == 'zakat', () {
                        ref.read(branchTypeFilterProvider.notifier).state = 'zakat';
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                      _buildModalChip(BranchLabels.nonZakat(_selectedBranchId), typeFilter == 'non-zakat', () {
                        ref.read(branchTypeFilterProvider.notifier).state = 'non-zakat';
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                      _buildModalChip("GMWF", typeFilter == 'gmwf', () {
                        ref.read(branchTypeFilterProvider.notifier).state = 'gmwf';
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text("Sort Records", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textSecondary)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _sortField,
                          dropdownColor: t.bgCard,
                          style: TextStyle(fontSize: 13, color: t.textPrimary),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: true,
                            fillColor: t.bgCardAlt,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'token', child: Text('Token number')),
                            DropdownMenuItem(value: 'name', child: Text('Patient name')),
                            DropdownMenuItem(value: 'status', child: Text('Status')),
                            DropdownMenuItem(value: 'type', child: Text('Queue type')),
                            DropdownMenuItem(value: 'facility', child: Text('Facility')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _sortField = value;
                              _currentPage = 1;
                            });
                            setModalState(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: _sortAscending ? 'Ascending' : 'Descending',
                        onPressed: () {
                          setState(() {
                            _sortAscending = !_sortAscending;
                            _currentPage = 1;
                          });
                          setModalState(() {});
                        },
                        icon: Icon(_sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, color: t.accent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text("Shift", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textSecondary)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildModalChip("All Shifts", shiftFilter == null, () {
                        ref.read(branchShiftFilterProvider.notifier).state = null;
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                      _buildModalChip("Morning", shiftFilter == 'morning', () {
                        ref.read(branchShiftFilterProvider.notifier).state = 'morning';
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                      _buildModalChip("Evening", shiftFilter == 'evening', () {
                        ref.read(branchShiftFilterProvider.notifier).state = 'evening';
                        setModalState(() {});
                        setState(() => _currentPage = 1);
                      }, t),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilterChip(
                          label: const Text("Multi-Day Course"),
                          selected: mDay,
                          backgroundColor: t.bgCardAlt,
                          selectedColor: Color.alphaBlend(
                            t.accent.withValues(alpha: t.isDarkCanvas ? 0.22 : 0.14),
                            t.bgCard,
                          ),
                          checkmarkColor: t.accent,
                          side: BorderSide(color: mDay ? t.accent : t.bgRule),
                          labelStyle: TextStyle(
                            color: mDay ? t.accent : t.textPrimary,
                            fontSize: 12,
                            fontWeight: mDay ? FontWeight.w700 : FontWeight.w500,
                          ),
                          onSelected: (val) {
                            ref.read(branchMultiDayFilterProvider.notifier).state = val;
                            setModalState(() {});
                            setState(() => _currentPage = 1);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilterChip(
                          label: const Text("Frequent Visits (2+)"),
                          selected: mVisit,
                          backgroundColor: t.bgCardAlt,
                          selectedColor: Color.alphaBlend(
                            t.accent.withValues(alpha: t.isDarkCanvas ? 0.22 : 0.14),
                            t.bgCard,
                          ),
                          checkmarkColor: t.accent,
                          side: BorderSide(color: mVisit ? t.accent : t.bgRule),
                          labelStyle: TextStyle(
                            color: mVisit ? t.accent : t.textPrimary,
                            fontSize: 12,
                            fontWeight: mVisit ? FontWeight.w700 : FontWeight.w500,
                          ),
                          onSelected: (val) {
                            ref.read(branchMultiVisitFilterProvider.notifier).state = val;
                            setModalState(() {});
                            setState(() => _currentPage = 1);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: GColor.onAccent(t.accent),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Apply Filters", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildModalChip(String label, bool isSelected, VoidCallback onTap, RoleThemeData t) {
    final isDark = t.isDarkCanvas;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: Color.alphaBlend(
        t.accent.withValues(alpha: isDark ? 0.22 : 0.14),
        t.bgCard,
      ),
      labelStyle: TextStyle(
        color: isSelected ? t.accent : t.textSecondary,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
      backgroundColor: t.bgCardAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? t.accent : t.bgRule),
      ),
    );
  }

  bool get _isSupervisorUser {
    final role = LocalStorageService.getActiveUserRole().toLowerCase().trim();
    return role.contains('supervisor') || widget.isManager == true;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ValueListenableBuilder<Box>(
      valueListenable: UserThemeService.listenable(),
      builder: (context, _, child) {
        final t = RoleThemeScope.dataOf(context);
        final branchesAsync = ref.watch(branchesListProvider);

        return Scaffold(
          backgroundColor: t.bg,
          body: branchesAsync.when(
            loading: () => Center(child: CircularProgressIndicator(color: t.accent)),
            error: (e, _) => Center(child: Text('Error loading branches: $e', style: TextStyle(color: t.danger))),
            data: (branchMaps) {
              if (branchMaps.isEmpty) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.store_rounded, size: 48, color: t.bgRule),
                    const SizedBox(height: 16),
                    Text("No branches found", style: TextStyle(color: t.textTertiary, fontSize: 16)),
                    // Creating a branch: Chairman, CEO and Admin only (not the HQ Manager).
                    if (widget.showRegisterButton &&
                        const {'chairman', 'ceo', 'admin', 'global admin', 'super admin'}.contains(
                            (LocalStorageService.getActiveUserData()['role'] ?? '').toString().toLowerCase().trim())) ...[
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BranchesRegister())),
                        icon: const Icon(Icons.add_business_rounded),
                        label: const Text("Register New Branch"),
                      ),
                    ],
                  ]),
                );
              }

              // Resolve active branch
              var activeId = (widget.branchId != null && widget.branchId!.isNotEmpty && widget.branchId != 'all')
                  ? widget.branchId
                  : _selectedBranchId;
              if (activeId == null || activeId.isEmpty) {
                if (widget.initialBranchId != null && widget.initialBranchId!.isNotEmpty) {
                  activeId = widget.initialBranchId;
                }
              }
              if (activeId == null || activeId.isEmpty) {
                final externalTabId = ref.watch(selectedBranchTabIdProvider);
                if (externalTabId != null && externalTabId.isNotEmpty) {
                  activeId = externalTabId;
                }
              }
              if (activeId == null || activeId.isEmpty) {
                final localActive = LocalStorageService.getActiveBranchId();
                if (localActive != null && localActive.isNotEmpty) {
                  activeId = localActive;
                }
              }
              if (activeId == null || activeId.isEmpty) {
                activeId = branchMaps.first['id'] as String;
              }

              final matchIdx = branchMaps.indexWhere((m) {
                final id = (m['id'] as String).toLowerCase().trim();
                final target = activeId!.toLowerCase().trim();
                return id == target || id.contains(target) || target.contains(id);
              });

              final currentBranch = matchIdx != -1
                  ? branchMaps[matchIdx]
                  : {'id': activeId, 'name': activeId.toUpperCase()};
              final branchId = currentBranch['id'] as String;
              _selectedBranchName = currentBranch['name'] as String;

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isMobile = constraints.maxWidth < 650;
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: isMobile ? 12 : 24,
                      vertical: isMobile ? 14 : 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(context, t, branchMaps, branchId),
                        const SizedBox(height: 16),
                        _buildMetricsCards(context, t, branchId),
                        if (!_isSupervisorUser) ...[
                          const SizedBox(height: 16),
                          _buildMiddleSection(context, t, branchId),
                        ],
                        const SizedBox(height: 20),
                        _buildPatientRecordsSection(context, t, branchId),
                        const SizedBox(height: 36),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 1. Top Header Bar
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, RoleThemeData t, List<Map<String, dynamic>> branches, String currentBranchId) {
    final role = LocalStorageService.getActiveUserRole().toLowerCase().trim();
    final canSwitchBranches = widget.isManager != true ||
        role.contains('chairman') ||
        role.contains('hq manager') ||
      role.replaceAll(RegExp(r'[^a-z]'), '') == 'hqmanager' ||
        role.contains('global admin');
    final dateRange = ref.watch(branchDateRangeProvider);
    String dateRangeLabel = 'Today';
    if (dateRange.start != null && dateRange.end != null) {
      final df = DateFormat('dd MMM');
      dateRangeLabel = '${df.format(dateRange.start!)} - ${df.format(dateRange.end!)}';
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 900;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              "$_selectedBranchName Overview",
                              style: TextStyle(
                                fontSize: isNarrow ? 20 : 24,
                                fontWeight: FontWeight.w800,
                                color: t.textPrimary,
                                letterSpacing: -0.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (branches.length > 1 && canSwitchBranches) ...[
                            const SizedBox(width: 8),
                            PopupMenuButton<String>(
                              color: t.bgCard,
                              icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textSecondary),
                              tooltip: 'Switch Branch',
                              onSelected: (bId) {
                                setState(() {
                                  _selectedBranchId = bId;
                                  _currentPage = 1;
                                });
                                ref.read(selectedBranchTabIdProvider.notifier).state = bId;
                              },
                              itemBuilder: (ctx) => branches.map((b) => PopupMenuItem(
                                value: b['id'] as String,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.store_rounded,
                                      size: 16,
                                      color: b['id'] == currentBranchId ? t.accent : t.textSecondary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      b['name'] as String,
                                      style: TextStyle(
                                        fontWeight: b['id'] == currentBranchId ? FontWeight.bold : FontWeight.normal,
                                        color: b['id'] == currentBranchId ? t.accent : t.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              )).toList(),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Monitor performance and operations across all departments.",
                        style: TextStyle(fontSize: 13, color: t.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (!isNarrow) _buildHeaderActionButtons(context, t, dateRangeLabel, currentBranchId),
              ],
            ),
            if (isNarrow) ...[
              const SizedBox(height: 14),
              _buildHeaderActionButtons(context, t, dateRangeLabel, currentBranchId),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDatePresetChip(String label, bool isSelected, VoidCallback onTap, RoleThemeData t) {
    final isDark = t.isDarkCanvas;
    final fillColor = isSelected
        ? Color.alphaBlend(t.accent.withValues(alpha: isDark ? 0.22 : 0.12), t.bgCard)
        : t.bgCard;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? t.accent : t.bgRule,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected ? t.accent : t.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderActionButtons(BuildContext context, RoleThemeData t, String dateRangeLabel, String currentBranchId) {
    final range = ref.watch(branchDateRangeProvider);
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final isToday = range.isToday || (range.start != null && range.start!.isAtSameMomentAs(todayStart) && range.end != null && range.end!.isAtSameMomentAs(todayStart));
    
    final sevenDaysAgo = todayStart.subtract(const Duration(days: 7));
    final is7Days = !isToday && range.start != null && range.start!.isAtSameMomentAs(sevenDaysAgo);

    final monthStart = DateTime(now.year, now.month, 1);
    final isThisMonth = !isToday && range.start != null && range.start!.isAtSameMomentAs(monthStart);

    final thirtyDaysAgo = todayStart.subtract(const Duration(days: 30));
    final is30Days = !isToday && !is7Days && !isThisMonth && range.start != null && range.start!.isAtSameMomentAs(thirtyDaysAgo);

    final allTimeStart = DateTime(2025, 1, 1);
    final isAllTime = !isToday && range.start != null && range.start!.isAtSameMomentAs(allTimeStart);

    final isCustom = !isToday && !is7Days && !isThisMonth && !is30Days && !isAllTime;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDatePresetChip("Today", isToday, () {
            ref.read(branchDateRangeProvider.notifier).state = const DateRange();
            setState(() => _currentPage = 1);
          }, t),
          const SizedBox(width: 6),
          _buildDatePresetChip("7 Days", is7Days, () {
            ref.read(branchDateRangeProvider.notifier).state = DateRange(
              start: sevenDaysAgo,
              end: todayStart,
            );
            setState(() => _currentPage = 1);
          }, t),
          const SizedBox(width: 6),
          _buildDatePresetChip("This Month", isThisMonth, () {
            ref.read(branchDateRangeProvider.notifier).state = DateRange(
              start: monthStart,
              end: todayStart,
            );
            setState(() => _currentPage = 1);
          }, t),
          const SizedBox(width: 6),
          _buildDatePresetChip("30 Days", is30Days, () {
            ref.read(branchDateRangeProvider.notifier).state = DateRange(
              start: thirtyDaysAgo,
              end: todayStart,
            );
            setState(() => _currentPage = 1);
          }, t),
          const SizedBox(width: 6),
          _buildDatePresetChip("All Time", isAllTime, () {
            ref.read(branchDateRangeProvider.notifier).state = DateRange(
              start: allTimeStart,
              end: todayStart,
            );
            setState(() => _currentPage = 1);
          }, t),
          const SizedBox(width: 8),
          // Custom Date Range Selector
          OutlinedButton.icon(
            onPressed: () => _showDateRangePicker(context, t),
            icon: Icon(Icons.calendar_month_rounded, size: 13, color: isCustom ? t.accent : t.textSecondary),
            label: Text(
              isCustom ? dateRangeLabel : "Custom",
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isCustom ? FontWeight.w800 : FontWeight.w600,
                color: isCustom ? t.accent : t.textPrimary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: isCustom
                  ? Color.alphaBlend(
                      t.accent.withValues(alpha: t.isDarkCanvas ? 0.20 : 0.12),
                      t.bgCard,
                    )
                  : t.bgCard,
              side: BorderSide(color: isCustom ? t.accent : t.bgRule),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          // Sync & Refresh Button
          IconButton(
            onPressed: () {
              DispensaryNotifier.clearFetchCache();
              ref.invalidate(dispensaryProvider(currentBranchId));
              ref.invalidate(serialsSummaryProvider(currentBranchId));
              ref.invalidate(branchesListProvider);
              AppToast.show(message: 'Refreshing $_selectedBranchName data from Firestore...', kind: GToastKind.success);
              setState(() {});
            },
            icon: Icon(Icons.sync_rounded, size: 16, color: t.accent),
            tooltip: 'Sync & Refresh from Firestore',
            style: IconButton.styleFrom(
              backgroundColor: t.accent.withValues(alpha: 0.12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: t.accent.withValues(alpha: 0.3)),
              ),
              padding: const EdgeInsets.all(8),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 2. Top 4 KPI Summary Cards (Tokens, Prescriptions, Dispensary, Peak Record)
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildMetricsCards(BuildContext context, RoleThemeData t, String branchId) {
    final summaryAsync = ref.watch(serialsSummaryProvider(branchId));
    final data = summaryAsync.value ?? {};

    final totalTokens = data['total'] ?? 0;
    final zakatTokens = data['v1'] ?? 0;
    final nonZakatTokens = data['v2'] ?? 0;
    final gmwfTokens = data['v3'] ?? 0;

    final zakatAmount = zakatTokens * 20;
    final nonZakatAmount = nonZakatTokens * 100;
    final totalAmount = zakatAmount + nonZakatAmount;
    final fmtTotal = NumberFormat('#,###').format(totalAmount);
    final fmtZakat = NumberFormat('#,###').format(zakatAmount);
    final fmtNonZakat = NumberFormat('#,###').format(nonZakatAmount);

    final prescribed = data['presc_prescribed'] ?? 0;
    final waitingDoctor = data['presc_waiting'] ?? 0;

    final dispensed = data['disp_dispensed'] ?? 0;
    final pendingDisp = data['disp_pending'] ?? 0;

    final dateRange = ref.watch(branchDateRangeProvider);
    final now = DateTime.now();
    final isSingleDayToday = dateRange.start == null || (
      dateRange.start!.year == now.year &&
      dateRange.start!.month == now.month &&
      dateRange.start!.day == now.day &&
      (dateRange.end == null || (
        dateRange.end!.year == now.year &&
        dateRange.end!.month == now.month &&
        dateRange.end!.day == now.day
      ))
    );

    final subFilter = ref.watch(branchSubDispensaryFilterProvider);
    final effCamp = (_selectedCampFilter != 'all' && _selectedCampFilter.isNotEmpty)
        ? _selectedCampFilter
        : (subFilter != null && subFilter.isNotEmpty && subFilter != 'all' ? subFilter : null);

    final records = BranchRecordService.getBranchRecords(
      branchId,
      campId: effCamp,
      todayCount: isSingleDayToday ? totalTokens : null,
    );
    final peakCount = records.peakRecord.count;
    final peakDate = records.peakRecord.dateFormatted.isNotEmpty
        ? records.peakRecord.dateFormatted
        : "No history";

    final peakTitle = (effCamp != null && effCamp.isNotEmpty && effCamp != 'all')
        ? "${CampSessionService.getCampLabel(effCamp)} Peak"
        : "${_selectedBranchName.isNotEmpty ? _selectedBranchName : 'Branch'} Peak";

        return LayoutBuilder(
          builder: (context, constraints) {
            final c = context.comfort;
            final isWide = constraints.maxWidth >= 980;
            final isMedium = constraints.maxWidth >= 620;
            final cardWidth = isWide
                ? (constraints.maxWidth - 48) / 5
                : (isMedium ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth);

            final tokensColor = c.chart1;
            final revenueColor = c.chart2;
            final prescColor = c.chart3;
            final dispColor = c.info;
            final peakColor = c.chart4;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: cardWidth,
                  child: _buildKpiCard(
                    title: "Total Tokens",
                    mainCount: NumberFormat('#,###').format(totalTokens),
                    trendText: "Today",
                    isPositiveTrend: true,
                    badgeColor: tokensColor,
                    badgeIcon: Icons.people_alt_rounded,
                    subItems: [
                      {'label': BranchLabels.isKarachiBranch(branchId) ? BranchLabels.karachiZakatLabel : 'Zakat (Rs 20)', 'val': NumberFormat('#,###').format(zakatTokens)},
                      {'label': BranchLabels.isKarachiBranch(branchId) ? BranchLabels.karachiNonZakatLabel : 'Non-Zakat (Rs 100)', 'val': NumberFormat('#,###').format(nonZakatTokens)},
                      {'label': 'GMWF (Free)', 'val': NumberFormat('#,###').format(gmwfTokens)},
                    ],
                    t: t,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _buildKpiCard(
                    title: "Total Prescriptions",
                    mainCount: NumberFormat('#,###').format(prescribed),
                    trendText: "+8% vs yest",
                    isPositiveTrend: true,
                    badgeColor: prescColor,
                    badgeIcon: Icons.assignment_rounded,
                    subItems: [
                      {'label': 'Waiting', 'val': NumberFormat('#,###').format(waitingDoctor)},
                      {'label': 'Prescribed', 'val': NumberFormat('#,###').format(prescribed)},
                    ],
                    t: t,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _buildKpiCard(
                    title: "Total Dispensary",
                    mainCount: NumberFormat('#,###').format(dispensed),
                    trendText: "+5% vs yest",
                    isPositiveTrend: true,
                    badgeColor: dispColor,
                    badgeIcon: Icons.medication_liquid_rounded,
                    subItems: [
                      {'label': 'Pending', 'val': NumberFormat('#,###').format(pendingDisp)},
                      {'label': 'Dispensed', 'val': NumberFormat('#,###').format(dispensed)},
                    ],
                    t: t,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _buildKpiCard(
                    title: peakTitle,
                    mainCount: NumberFormat('#,###').format(peakCount),
                    trendText: records.isNewRecordToday ? "🔥 Record Broken Today!" : peakDate,
                    isPositiveTrend: true,
                    badgeColor: peakColor,
                    badgeIcon: Icons.emoji_events_rounded,
                    subItems: [
                      {'label': 'Record Date', 'val': peakDate},
                      {'label': 'Today Dealt', 'val': NumberFormat('#,###').format(totalTokens)},
                    ],
                    t: t,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _buildKpiCard(
                    title: "Total Token Collection",
                    mainCount: "PKR $fmtTotal",
                    trendText: "Revenue",
                    isPositiveTrend: true,
                    badgeColor: revenueColor,
                    badgeIcon: Icons.account_balance_wallet_rounded,
                    subItems: [
                      {'label': BranchLabels.text('Zakat Rec.', branchId), 'val': 'Rs $fmtZakat'},
                      {'label': BranchLabels.text('Non-Zakat Rec.', branchId), 'val': 'Rs $fmtNonZakat'},
                      {'label': 'Free Tokens', 'val': 'Rs 0'},
                    ],
                    t: t,
                  ),
                ),
              ],
            );
          },
        );
  }

  Widget _buildKpiCard({
    required String title,
    required String mainCount,
    required String trendText,
    required bool isPositiveTrend,
    required Color badgeColor,
    required IconData badgeIcon,
    required List<Map<String, String>> subItems,
    required RoleThemeData t,
  }) {
    final isDark = t.isDarkCanvas;
    final trendColor = isPositiveTrend
        ? (isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald)
        : (isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                badgeColor.withValues(alpha: isDark ? 0.08 : 0.04),
                t.bgCard,
              ),
              t.bgCard,
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: badgeColor.withValues(alpha: isDark ? 0.28 : 0.20),
            width: 1,
          ),
          boxShadow: GShadow.s2(isDark),
        ),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 2.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      badgeColor,
                      badgeColor.withValues(alpha: 0.45),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: isDark ? 0.18 : 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: badgeColor.withValues(alpha: isDark ? 0.36 : 0.28),
                            width: 1,
                          ),
                        ),
                        child: Icon(badgeIcon, color: badgeColor, size: 17),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      mainCount,
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w900,
                                        color: t.textPrimary,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ),
                                ),
                                if (trendText.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: trendColor.withValues(alpha: isDark ? 0.18 : 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isPositiveTrend ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                                          size: 10,
                                          color: trendColor,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          trendText,
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: trendColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.bgRule, width: 0.8),
                    ),
                    child: Row(
                      children: subItems.map((item) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    item['label'] ?? '',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: t.textTertiary),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    item['val'] ?? '0',
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: t.textPrimary),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 3. Middle Section (Performance Overview Multi-line Chart & Quick Actions)
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildMiddleSection(BuildContext context, RoleThemeData t, String branchId) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final perfCard = _buildPerformanceChartCard(context, t, branchId);
        final mixCard = _buildTokenMixAndPipelineCard(context, t, branchId);
        if (constraints.maxWidth >= 980) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: perfCard),
                const SizedBox(width: 14),
                Expanded(flex: 1, child: mixCard),
              ],
            ),
          );
        }
        return Column(
          children: [
            perfCard,
            const SizedBox(height: 14),
            mixCard,
          ],
        );
      },
    );
  }

  Widget _buildPerformanceChartCard(BuildContext context, RoleThemeData t, String branchId) {
    final isDark = t.isDarkCanvas;
    final dispState = ref.watch(dispensaryProvider(branchId));
    final perfData = _computeRealPerformanceData(branchId, _chartRange, extraRecords: dispState.records);
    final tokensData = (perfData['tokens'] as List<double>?) ?? [];
    final prescData = (perfData['prescriptions'] as List<double>?) ?? [];
    final dispData = (perfData['dispensary'] as List<double>?) ?? [];
    final labels = (perfData['labels'] as List<String>?) ?? [];

    final tokensTotal = tokensData.fold<double>(0.0, (a, b) => a + b).toInt();
    final prescTotal = prescData.fold<double>(0.0, (a, b) => a + b).toInt();
    final dispTotal = dispData.fold<double>(0.0, (a, b) => a + b).toInt();

    final c = context.comfort;
    final tokensColor = c.chart1;
    final prescColor = c.chart3;
    final dispColor = c.info;

    double maxY = 4;
    for (final v in [...tokensData, ...prescData, ...dispData]) {
      if (v > maxY) maxY = v;
    }
    maxY = (maxY * 1.18).ceilToDouble();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 1),
        boxShadow: GShadow.s1(isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Performance Overview',
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: t.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _selectedCampFilter == 'haji'
                          ? 'Haji Camp Dispensary Data'
                          : (_selectedCampFilter == 'saddar' ? 'Saddar Dispensary Data' : 'Collective Branch Performance'),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.accent),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.bgRule),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _chartModeButton(t, label: 'Trend', icon: Icons.show_chart_rounded, active: !_showBarChart, onTap: () => setState(() => _showBarChart = false)),
                    _chartModeButton(t, label: 'Bars', icon: Icons.bar_chart_rounded, active: _showBarChart, onTap: () => setState(() => _showBarChart = true)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _chartRange,
                  isDense: true,
                  dropdownColor: t.bgCard,
                  icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: t.textSecondary),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary),
                  items: const [
                    DropdownMenuItem(value: '7d', child: Text('Last 7 Days')),
                    DropdownMenuItem(value: '14d', child: Text('Last 14 Days')),
                    DropdownMenuItem(value: '30d', child: Text('Last 30 Days')),
                    DropdownMenuItem(value: 'month', child: Text('This Month')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _chartRange = val);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildTotalMetricBadge(label: 'Tokens', count: tokensTotal, color: tokensColor, icon: Icons.confirmation_number_outlined, t: t),
              _buildTotalMetricBadge(label: 'Prescriptions', count: prescTotal, color: prescColor, icon: Icons.medical_services_outlined, t: t),
              _buildTotalMetricBadge(label: 'Dispensed', count: dispTotal, color: dispColor, icon: Icons.medication_outlined, t: t),
              _buildTotalMetricBadge(label: 'Total Activity', count: tokensTotal + prescTotal + dispTotal, color: t.accent, icon: Icons.query_stats_rounded, t: t),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 215,
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 14, 14, 8),
            decoration: BoxDecoration(
              color: isDark ? t.bgCard : Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: tokensData.isEmpty
                ? Center(child: Text('No chart data for this period', style: TextStyle(color: t.textSecondary, fontSize: 12)))
                : (_showBarChart
                    ? _buildFlBarChart(t, labels, tokensData, prescData, dispData, tokensColor, prescColor, dispColor, maxY)
                    : _buildFlLineChart(t, labels, tokensData, prescData, dispData, tokensColor, prescColor, dispColor, maxY)),
          ),
        ],
      ),
    );
  }

  Widget _chartModeButton(RoleThemeData t, {required String label, required IconData icon, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: active ? t.accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? t.accent : t.textSecondary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: active ? t.accent : t.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _buildFlLineChart(
    RoleThemeData t,
    List<String> labels,
    List<double> tokensData,
    List<double> prescData,
    List<double> dispData,
    Color tokensColor,
    Color prescColor,
    Color dispColor,
    double maxY,
  ) {
    final step = labels.length > 10 ? (labels.length / 6).ceil() : 1;
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: t.bgRule, strokeWidth: 1, dashArray: [4, 4]),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              getTitlesWidget: (val, meta) {
                if (val == meta.max && val % 1 != 0) return const SizedBox.shrink();
                return Text(
                  val.toInt().toString(),
                  style: TextStyle(fontSize: 10, color: t.textTertiary, fontWeight: FontWeight.w600),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 1,
              getTitlesWidget: (val, _) {
                final i = val.toInt();
                if (i < 0 || i >= labels.length || i % step != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(labels[i], style: TextStyle(fontSize: 10, color: t.textSecondary, fontWeight: FontWeight.w600)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => t.bgCard,
            tooltipBorder: BorderSide(color: t.bgRule),
            getTooltipItems: (spots) => spots.map((s) {
              final name = s.barIndex == 0 ? 'Tokens' : (s.barIndex == 1 ? 'Prescribed' : 'Dispensed');
              return LineTooltipItem('$name: ${s.y.toInt()}', TextStyle(color: s.bar.color ?? t.textPrimary, fontWeight: FontWeight.w700, fontSize: 11.5));
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [for (var i = 0; i < tokensData.length; i++) FlSpot(i.toDouble(), tokensData[i])],
            isCurved: true,
            preventCurveOverShooting: true,
            color: tokensColor,
            barWidth: 2.6,
            dotData: FlDotData(show: tokensData.length <= 14),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tokensColor.withValues(alpha: 0.18), tokensColor.withValues(alpha: 0.0)],
              ),
            ),
          ),
          LineChartBarData(
            spots: [for (var i = 0; i < prescData.length; i++) FlSpot(i.toDouble(), prescData[i])],
            isCurved: true,
            preventCurveOverShooting: true,
            color: prescColor,
            barWidth: 2.2,
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: [for (var i = 0; i < dispData.length; i++) FlSpot(i.toDouble(), dispData[i])],
            isCurved: true,
            preventCurveOverShooting: true,
            color: dispColor,
            barWidth: 2.2,
            dashArray: [5, 3],
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }

  Widget _buildFlBarChart(
    RoleThemeData t,
    List<String> labels,
    List<double> tokensData,
    List<double> prescData,
    List<double> dispData,
    Color tokensColor,
    Color prescColor,
    Color dispColor,
    double maxY,
  ) {
    final step = labels.length > 10 ? (labels.length / 6).ceil() : 1;
    final barW = labels.length > 14 ? 6.0 : 12.0;
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: t.bgRule, strokeWidth: 1, dashArray: [4, 4]),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              getTitlesWidget: (val, meta) {
                if (val == meta.max && val % 1 != 0) return const SizedBox.shrink();
                return Text(val.toInt().toString(), style: TextStyle(fontSize: 10, color: t.textTertiary, fontWeight: FontWeight.w600));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (val, _) {
                final i = val.toInt();
                if (i < 0 || i >= labels.length || i % step != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(labels[i], style: TextStyle(fontSize: 10, color: t.textSecondary, fontWeight: FontWeight.w600)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => t.bgCard,
            tooltipBorder: BorderSide(color: t.bgRule),
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final name = rodIndex == 0 ? 'Tokens' : (rodIndex == 1 ? 'Prescribed' : 'Dispensed');
              return BarTooltipItem('$name: ${rod.toY.toInt()}', TextStyle(color: rod.color ?? t.textPrimary, fontWeight: FontWeight.w700, fontSize: 11.5));
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < tokensData.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 2,
              barRods: [
                BarChartRodData(toY: tokensData[i], color: tokensColor, width: barW, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                BarChartRodData(toY: i < prescData.length ? prescData[i] : 0, color: prescColor, width: barW, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                BarChartRodData(toY: i < dispData.length ? dispData[i] : 0, color: dispColor, width: barW, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTokenMixAndPipelineCard(BuildContext context, RoleThemeData t, String branchId) {
    final isDark = t.isDarkCanvas;
    final data = ref.watch(serialsSummaryProvider(branchId)).value ?? {};
    final total = data['total'] ?? 0;
    final zakat = data['v1'] ?? 0;
    final nonZakat = data['v2'] ?? 0;
    final gmwf = data['v3'] ?? 0;
    final prescribed = data['presc_prescribed'] ?? 0;
    final waiting = data['presc_waiting'] ?? 0;
    final dispensed = data['disp_dispensed'] ?? 0;
    final pendingDisp = data['disp_pending'] ?? 0;

    final c = context.comfort;
    final zakatColor = c.chart1;
    final nonZakatColor = c.chart2;
    final gmwfColor = c.chart3;
    final dispColor = c.info;
    final warnColor = c.chart4;

    final hasMix = total > 0;
    final prescPct = total > 0 ? (prescribed / total).clamp(0.0, 1.0) : 0.0;
    final dispPct = total > 0 ? (dispensed / total).clamp(0.0, 1.0) : 0.0;
    final queueCount = waiting + pendingDisp;
    final queuePct = total > 0 ? (queueCount / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 1),
        boxShadow: GShadow.s1(isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Token Mix & Pipeline', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: t.textPrimary)),
          const SizedBox(height: 2),
          Text('Category split & stage completion', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.textSecondary)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? t.bgCard : Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 112,
                  height: 112,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          centerSpaceRadius: 36,
                          sectionsSpace: hasMix ? 3 : 0,
                          sections: hasMix
                              ? [
                                  if (zakat > 0) PieChartSectionData(value: zakat.toDouble(), color: zakatColor, radius: 16, showTitle: false),
                                  if (nonZakat > 0) PieChartSectionData(value: nonZakat.toDouble(), color: nonZakatColor, radius: 16, showTitle: false),
                                  if (gmwf > 0) PieChartSectionData(value: gmwf.toDouble(), color: gmwfColor, radius: 16, showTitle: false),
                                ]
                              : [PieChartSectionData(value: 1, color: t.bgRule, radius: 15, showTitle: false)],
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(NumberFormat('#,###').format(total), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: t.textPrimary)),
                          Text('tokens', style: TextStyle(fontSize: 10, color: t.textSecondary)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    _mixPillChip(t, 'Zakat', zakat, zakatColor),
                    _mixPillChip(t, 'Non-Zakat', nonZakat, nonZakatColor),
                    _mixPillChip(t, 'Free', gmwf, gmwfColor),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _pipelineProgressRow(t, 'Doctor Prescribed', prescribed, total, prescPct, gmwfColor),
          const SizedBox(height: 10),
          _pipelineProgressRow(t, 'Medicine Dispensed', dispensed, total, dispPct, dispColor),
          const SizedBox(height: 10),
          _pipelineProgressRow(t, 'Active Queue (Wait + Disp)', queueCount, total, queuePct, warnColor),
        ],
      ),
    );
  }

  Widget _mixPillChip(RoleThemeData t, String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('$label  ', style: TextStyle(fontSize: 11, color: t.textSecondary, fontWeight: FontWeight.w600)),
          Text('$count', style: TextStyle(fontSize: 11, color: t.textPrimary, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _pipelineProgressRow(RoleThemeData t, String label, int count, int total, double pct, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.textSecondary)),
            Text('$count / $total (${(pct * 100).round()}%)', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: t.textPrimary)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 7,
            backgroundColor: t.bgCardAlt,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildTotalMetricBadge({
    required String label,
    required int count,
    required Color color,
    required IconData icon,
    required RoleThemeData t,
  }) {
    final isDark = t.isDarkCanvas;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: isDark ? 0.18 : 0.10), t.bgCard),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.38 : 0.28), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 7),
          Text(
            "$label: ",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary),
          ),
          Text(
            NumberFormat('#,###').format(count),
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w900, color: color),
          ),
        ],
      ),
    );
  }


  // ───────────────────────────────────────────────────────────────────────────
  // 4. All Branch Patient Records Section (Table, Filter Tabs, Search & Pagination)
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildPatientRecordsSection(BuildContext context, RoleThemeData t, String branchId) {
    final isDark = t.isDarkCanvas;
    final dispState = ref.watch(dispensaryProvider(branchId));
    final allList = List<Map<String, dynamic>>.from(dispState.records);

    // Deep search across local branch history when searching by name, token, CNIC, or phone
    if (_searchQuery.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final eBox = Hive.box(LocalStorageService.entriesBox);
      final q = _searchQuery.toLowerCase().trim();
      final qClean = q.replaceAll('-', '').replaceAll(' ', '');
      final existingSerials = allList
          .map((e) => (e['serial'] ?? e['tokenSerial'] ?? e['id'] ?? '').toString().toUpperCase().trim())
          .toSet();
      final normBranch = branchId.toLowerCase().trim();

      for (final k in eBox.keys) {
        final val = eBox.get(k);
        if (val is! Map) continue;
        final d = Map<String, dynamic>.from(val);
        final b = (d['branchId'] ?? '').toString().toLowerCase().trim();
        final matchBranch = normBranch == 'all' || normBranch.isEmpty || b == normBranch || b.isEmpty;
        if (!matchBranch) continue;

        final name = (d['patientName'] ?? d['name'] ?? '').toString().toLowerCase();
        final serial = (d['serial'] ?? d['tokenSerial'] ?? d['id'] ?? k).toString().toLowerCase();
        final cnic = (d['displayCnic'] ?? d['cnic'] ?? d['patientCnic'] ?? d['guardianCnic'] ?? '')
            .toString()
            .replaceAll('-', '')
            .replaceAll(' ', '');
        final phone = (d['phone'] ?? d['patientPhone'] ?? '').toString().replaceAll('-', '').replaceAll(' ', '');

        if (name.contains(q) || serial.contains(q) || (qClean.isNotEmpty && (cnic.contains(qClean) || phone.contains(qClean)))) {
          final upperSerial = (d['serial'] ?? d['tokenSerial'] ?? d['id'] ?? k).toString().toUpperCase().trim();
          if (!existingSerials.contains(upperSerial)) {
            existingSerials.add(upperSerial);
            d['name'] = d['patientName'] ?? d['name'] ?? 'Unknown';
            final dk = d['dateKey']?.toString() ?? '';
            if (dk.length == 6) {
              try {
                d['dispenseDate'] = DateFormat('dd MMM yyyy').format(LocalStorageService.parseDdMMyy(dk));
              } catch (_) {
                d['dispenseDate'] = dk;
              }
            } else {
              d['dispenseDate'] = d['date']?.toString() ?? dk;
            }
            d['type'] = (d['queueType'] ?? d['type'] ?? 'zakat').toString().toLowerCase();
            allList.add(d);
          }
        }
      }
    }

    final typeFilter = ref.watch(branchTypeFilterProvider);
    final shiftFilter = ref.watch(branchShiftFilterProvider);
    final mDay = ref.watch(branchMultiDayFilterProvider);
    final mVisit = ref.watch(branchMultiVisitFilterProvider);
    final stageFilter = ref.watch(branchStageFilterProvider);

    // Filter list
    final filtered = allList.where((p) {
      // Camp filter (dynamic matching for any branch camps)
      if (_selectedCampFilter != 'all') {
        final matches = CampSessionService.matchesCamp(
          selectedCamp: _selectedCampFilter,
          dispensaryId: p['dispensaryId']?.toString(),
          campId: p['campId']?.toString(),
          dispensaryTag: p['dispensaryTag']?.toString(),
          serial: (p['serial'] ?? p['id'])?.toString(),
        );
        if (!matches) return false;
      }

      // Type
      if (typeFilter != null && p['type']?.toString().toLowerCase() != typeFilter) return false;

      // Shift
      if (shiftFilter != null) {
        final sess = (p['session'] ?? p['shift'] ?? '').toString().toLowerCase().trim();
        if (sess.isNotEmpty && sess != shiftFilter) return false;
      }

      // Multi-Day
      if (mDay) {
        final days = (p['daysOfMedicine'] as num?)?.toInt() ?? 1;
        if (days <= 1) return false;
      }

      // Multi-Visit
      if (mVisit) {
        final visits = (p['totalVisits'] as num?)?.toInt() ?? 0;
        if (visits <= 1) return false;
      }

      // Search Query
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase().trim();
        final qClean = q.replaceAll('-', '').replaceAll(' ', '');
        final name = (p['name'] ?? '').toString().toLowerCase();
        final serial = (p['serial'] ?? p['id'] ?? '').toString().toLowerCase();
        final cnic = (p['displayCnic'] ?? p['cnic'] ?? p['patientCnic'] ?? p['guardianCnic'] ?? '')
            .toString()
            .toLowerCase()
            .replaceAll('-', '')
            .replaceAll(' ', '');
        final phone = (p['phone'] ?? p['patientPhone'] ?? '')
            .toString()
            .toLowerCase()
            .replaceAll('-', '')
            .replaceAll(' ', '');
        if (!name.contains(q) && !serial.contains(q) && !cnic.contains(qClean) && !phone.contains(qClean)) {
          return false;
        }
      }

      // Token Category Filter (Normal vs Vitals)
      final tokenCat = ref.watch(branchTokenCategoryFilterProvider);
      final isV = p['isVitalsOnly'] == true ||
          p['vitalsOnly'] == true ||
          (p['visitReason']?.toString().toLowerCase().contains('vitals') ?? false);
      if (tokenCat == 'vitals' && !isV) return false;
      if (tokenCat == 'normal' && isV) return false;

      // Stage Filter
      if (stageFilter == 'waiting_doctor') {
        return _recordStage(p) == 'waiting_doctor';
      } else if (stageFilter == 'waiting_dispensary') {
        return _recordStage(p) == 'waiting_dispensary';
      } else if (stageFilter == 'dispensed') {
        return _recordStage(p) == 'dispensed';
      }

      return true;
    }).toList()
      ..sort(_compareRecords);

    // Stage counts with camp filter applied
    final campFilteredAllList = allList.where((p) {
      if (_selectedCampFilter == 'all') return true;
      return CampSessionService.matchesCamp(
        selectedCamp: _selectedCampFilter,
        dispensaryId: p['dispensaryId']?.toString(),
        campId: p['campId']?.toString(),
        dispensaryTag: p['dispensaryTag']?.toString(),
        serial: (p['serial'] ?? p['id'])?.toString(),
      );
    }).toList();

    final waitingDoctorCount = campFilteredAllList.where((p) => _recordStage(p) == 'waiting_doctor').length;
    final waitingDispCount = campFilteredAllList.where((p) => _recordStage(p) == 'waiting_dispensary').length;
    final dispensedCount = campFilteredAllList.where((p) => _recordStage(p) == 'dispensed').length;
    final vitalsCount = campFilteredAllList.where((p) =>
        p['isVitalsOnly'] == true ||
        p['vitalsOnly'] == true ||
        (p['visitReason']?.toString().toLowerCase().contains('vitals') ?? false)).length;
    final normalCount = campFilteredAllList.length - vitalsCount;

    // Pagination slice
    final totalRecords = filtered.length;
    final totalPages = (totalRecords / _rowsPerPage).ceil().clamp(1, 999999);
    final safePage = _currentPage.clamp(1, totalPages);
    final startIndex = (safePage - 1) * _rowsPerPage;
    final endIndex = (startIndex + _rowsPerPage).clamp(0, totalRecords);
    final paginatedList = totalRecords > 0 ? filtered.sublist(startIndex, endIndex) : <Map<String, dynamic>>[];

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 1),
        boxShadow: GShadow.s1(isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title & Configuration Badge
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                "All Branch Patient Records",
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: t.textPrimary),
              ),
              Builder(builder: (context) {
                final allowsVitals = _isVitalsAllowedForBranchOrCamp(branchId, campId: _selectedCampFilter);
                final badgeColor = allowsVitals
                    ? (isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald)
                    : (isDark ? SoftPalette.softIndigo : SoftPalette.luminousIndigo);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor.withValues(alpha: isDark ? 0.38 : 0.28)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        allowsVitals ? Icons.monitor_heart_outlined : Icons.confirmation_number_outlined,
                        size: 13,
                        color: badgeColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        allowsVitals
                            ? "Dual Tokens: Vitals & Normal Allowed"
                            : "Normal Tokens Only (Vitals Tokens Disabled)",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: badgeColor,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (dispState.isSyncing)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.accent.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.8, color: t.accent),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Syncing',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.accent),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Dynamic Camp Selector for any branch configured with multiple camps
          if (CampSessionService.hasCampsForBranch(branchId) || branchId.toLowerCase().contains('karachi') || branchId.toLowerCase() == 'all') ...[
            Builder(
              builder: (context) {
                final rawCamps = CampSessionService.getCampsForBranch(branchId, includeClosed: false);
                final List<Map<String, String>> campOptions = [];
                if (rawCamps.isNotEmpty) {
                  for (final c in rawCamps) {
                    final cId = (c['id'] ?? '').toString().trim();
                    final cName = (c['name'] ?? c['id'] ?? '').toString().trim();
                    if (cId.isNotEmpty) {
                      campOptions.add({'id': cId.toLowerCase(), 'name': cName});
                    }
                  }
                } else if (branchId.toLowerCase().contains('karachi') || branchId.toLowerCase() == 'all') {
                  campOptions.addAll([
                    {'id': 'haji', 'name': 'Haji Camp Dispensary'},
                    {'id': 'saddar', 'name': 'Saddar Dispensary'},
                  ]);
                }

                if (campOptions.isEmpty) return const SizedBox.shrink();

                final colors = [
                  isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
                  isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
                  isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
                  isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
                  isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan,
                ];

                final bDisplayName = branchId == 'all' ? 'All' : _selectedBranchName;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildCampFilterChip('All $bDisplayName (Collective)', _selectedCampFilter == 'all', () {
                          setState(() { _selectedCampFilter = 'all'; _currentPage = 1; });
                          ref.read(branchSubDispensaryFilterProvider.notifier).state = null;
                        }, isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald, t),
                        for (int i = 0; i < campOptions.length; i++)
                          _buildCampFilterChip(
                            campOptions[i]['name']!,
                            _selectedCampFilter == campOptions[i]['id']!,
                            () {
                              final cid = campOptions[i]['id']!;
                              setState(() {
                                _selectedCampFilter = cid;
                                _currentPage = 1;
                              });
                              ref.read(branchSubDispensaryFilterProvider.notifier).state = cid;
                            },
                            colors[i % colors.length],
                            t,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                );
              },
            ),
          ],

          // Stage Pills & Search Row
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 850;

              final tokenCat = ref.watch(branchTokenCategoryFilterProvider);
              final allowsVitals = _isVitalsAllowedForBranchOrCamp(branchId, campId: _selectedCampFilter);
              final allRecCol = isDark ? SoftPalette.softLavender : SoftPalette.royalViolet;
              final vitalsCol = isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid;
              final normalCol = isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
              final waitDocCol = isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
              final waitDispCol = isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;
              final dispensedCol = isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;

              final filterPills = isNarrow
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildStageTabPill("All Records", allList.length, stageFilter == 'all' && tokenCat == 'all', () {
                            ref.read(branchStageFilterProvider.notifier).state = 'all';
                            ref.read(branchTokenCategoryFilterProvider.notifier).state = 'all';
                            setState(() => _currentPage = 1);
                          }, allRecCol, t),
                          if (allowsVitals || vitalsCount > 0) ...[
                            const SizedBox(width: 8),
                            _buildStageTabPill("🩺 Vitals ($vitalsCount)", vitalsCount, tokenCat == 'vitals', () {
                              ref.read(branchTokenCategoryFilterProvider.notifier).state = 'vitals';
                              setState(() => _currentPage = 1);
                            }, vitalsCol, t),
                          ],
                          const SizedBox(width: 8),
                          _buildStageTabPill("🎟️ Normal ($normalCount)", normalCount, tokenCat == 'normal', () {
                            ref.read(branchTokenCategoryFilterProvider.notifier).state = 'normal';
                            setState(() => _currentPage = 1);
                          }, normalCol, t),
                          const SizedBox(width: 8),
                          _buildStageTabPill("Waiting for Doctor", waitingDoctorCount, stageFilter == 'waiting_doctor', () {
                            ref.read(branchStageFilterProvider.notifier).state = 'waiting_doctor';
                            setState(() => _currentPage = 1);
                          }, waitDocCol, t),
                          const SizedBox(width: 8),
                          _buildStageTabPill("Waiting for Dispensary", waitingDispCount, stageFilter == 'waiting_dispensary', () {
                            ref.read(branchStageFilterProvider.notifier).state = 'waiting_dispensary';
                            setState(() => _currentPage = 1);
                          }, waitDispCol, t),
                          const SizedBox(width: 8),
                          _buildStageTabPill("Dispensed", dispensedCount, stageFilter == 'dispensed', () {
                            ref.read(branchStageFilterProvider.notifier).state = 'dispensed';
                            setState(() => _currentPage = 1);
                          }, dispensedCol, t),
                        ],
                      ),
                    )
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildStageTabPill("All Records", allList.length, stageFilter == 'all' && tokenCat == 'all', () {
                          ref.read(branchStageFilterProvider.notifier).state = 'all';
                          ref.read(branchTokenCategoryFilterProvider.notifier).state = 'all';
                          setState(() => _currentPage = 1);
                        }, allRecCol, t),
                        if (allowsVitals || vitalsCount > 0)
                          _buildStageTabPill("🩺 Vitals ($vitalsCount)", vitalsCount, tokenCat == 'vitals', () {
                            ref.read(branchTokenCategoryFilterProvider.notifier).state = 'vitals';
                            setState(() => _currentPage = 1);
                          }, vitalsCol, t),
                        _buildStageTabPill("🎟️ Normal ($normalCount)", normalCount, tokenCat == 'normal', () {
                          ref.read(branchTokenCategoryFilterProvider.notifier).state = 'normal';
                          setState(() => _currentPage = 1);
                        }, normalCol, t),
                        _buildStageTabPill("Waiting for Doctor", waitingDoctorCount, stageFilter == 'waiting_doctor', () {
                          ref.read(branchStageFilterProvider.notifier).state = 'waiting_doctor';
                          setState(() => _currentPage = 1);
                        }, waitDocCol, t),
                        _buildStageTabPill("Waiting for Dispensary", waitingDispCount, stageFilter == 'waiting_dispensary', () {
                          ref.read(branchStageFilterProvider.notifier).state = 'waiting_dispensary';
                          setState(() => _currentPage = 1);
                        }, waitDispCol, t),
                        _buildStageTabPill("Dispensed", dispensedCount, stageFilter == 'dispensed', () {
                          ref.read(branchStageFilterProvider.notifier).state = 'dispensed';
                          setState(() => _currentPage = 1);
                        }, dispensedCol, t),
                      ],
                    );

              final searchBarAndFilters = Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 38,
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.bgRule),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded, size: 16, color: t.textTertiary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              style: TextStyle(fontSize: 12, color: t.textPrimary),
                              decoration: InputDecoration(
                                hintText: "Search by token, patient name, CNIC, or phone...",
                                hintStyle: TextStyle(fontSize: 12, color: t.textTertiary),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: (val) {
                                setState(() {
                                  _searchQuery = val.trim();
                                  _currentPage = 1;
                                });
                              },
                            ),
                          ),
                          if (_searchQuery.isNotEmpty)
                            GestureDetector(
                              onTap: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _currentPage = 1;
                                });
                              },
                              child: Icon(Icons.close_rounded, size: 16, color: t.textSecondary),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _showFilterModal(context, t),
                    icon: Icon(Icons.tune_rounded, size: 14, color: t.textSecondary),
                    label: Text("Filters", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary)),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: t.bgCardAlt,
                      side: BorderSide(color: t.bgRule),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              );

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    filterPills,
                    const SizedBox(height: 12),
                    searchBarAndFilters,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: filterPills),
                  const SizedBox(width: 16),
                  SizedBox(width: 340, child: searchBarAndFilters),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // Records Table / Mobile Cards
          if (dispState.isSyncing && allList.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.accent)),
                  const SizedBox(width: 10),
                  Text('Loading branch records…', style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            )
          else if (filtered.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.calendar_today_outlined, size: 24, color: t.accent),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _searchQuery.isNotEmpty
                          ? "No matching records found for '$_searchQuery'"
                          : "No patient records for the selected period",
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _searchQuery.isNotEmpty
                          ? "Check your spelling or reset filters to see all branch records."
                          : "Today may have 0 tokens registered yet. Select a wider time window below to view recent clinic visits:",
                      style: TextStyle(color: t.textSecondary, fontSize: 12.5),
                      textAlign: TextAlign.center,
                    ),
                    if (_searchQuery.isEmpty) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () {
                              final now = DateTime.now();
                              final todayStart = DateTime(now.year, now.month, now.day);
                              ref.read(branchDateRangeProvider.notifier).state = DateRange(
                                start: todayStart.subtract(const Duration(days: 7)),
                                end: todayStart,
                              );
                              setState(() => _currentPage = 1);
                            },
                            icon: const Icon(Icons.date_range_rounded, size: 14),
                            label: const Text("View Last 7 Days"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: t.accent,
                              foregroundColor: GColor.onAccent(t.accent),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              final now = DateTime.now();
                              final todayStart = DateTime(now.year, now.month, now.day);
                              ref.read(branchDateRangeProvider.notifier).state = DateRange(
                                start: DateTime(now.year, now.month, 1),
                                end: todayStart,
                              );
                              setState(() => _currentPage = 1);
                            },
                            icon: const Icon(Icons.calendar_month_rounded, size: 14),
                            label: const Text("View This Month"),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: t.textPrimary,
                              backgroundColor: t.bgCardAlt,
                              side: BorderSide(color: t.bgRule),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              final now = DateTime.now();
                              final todayStart = DateTime(now.year, now.month, now.day);
                              ref.read(branchDateRangeProvider.notifier).state = DateRange(
                                start: DateTime(2025, 1, 1),
                                end: todayStart,
                              );
                              setState(() => _currentPage = 1);
                            },
                            icon: const Icon(Icons.history_rounded, size: 14),
                            label: const Text("View All Time"),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: t.textPrimary,
                              backgroundColor: t.bgCardAlt,
                              side: BorderSide(color: t.bgRule),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, tableConstraints) {
                if (tableConstraints.maxWidth < 750) {
                  return _buildMobilePatientRecordsList(context, t, paginatedList, branchId, startIndex: startIndex);
                }
                return _buildRecordsTable(context, t, paginatedList, branchId, startIndex: startIndex);
              },
            ),

          const SizedBox(height: 16),

          // Pagination Footer
          if (filtered.isNotEmpty)
            _buildPaginationFooter(context, t, totalRecords, safePage, totalPages, startIndex, endIndex),
        ],
      ),
    );
  }

  Widget _buildStageTabPill(String label, int count, bool isSelected, VoidCallback onTap, Color activeColor, RoleThemeData t) {
    final isDark = t.isDarkCanvas;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Color.alphaBlend(
                  activeColor.withValues(alpha: isDark ? 0.22 : 0.12),
                  t.bgCard,
                )
              : t.bgCardAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor.withValues(alpha: 0.65) : t.bgRule,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? activeColor : t.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected
                    ? activeColor.withValues(alpha: isDark ? 0.28 : 0.18)
                    : t.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: isSelected ? null : Border.all(color: t.bgRule, width: 0.8),
              ),
              child: Text(
                "$count",
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? activeColor : t.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showVisitDetailsDialog(BuildContext context, Map<String, dynamic> p, RoleThemeData t, String branchId) {
    final tokenSerial = (p['serial'] ?? p['id'] ?? 'TK-000').toString();
    final rawName = LocalStorageService.firstRealValue([p['patientName'], p['name'], p['fullName']]);
    final name = (rawName.isEmpty || rawName.toLowerCase() == 'unknown' || rawName.toLowerCase() == 'unknown patient')
        ? 'Unknown Patient'
        : rawName;
    final age = (p['age'] ?? p['patientAge'] ?? '').toString();
    final gender = (p['gender'] ?? p['patientGender'] ?? '').toString();
    final rawPhone = (p['phone'] ?? p['patientPhone'] ?? p['contactPhone'] ?? '').toString().trim();
    final hasPhone = rawPhone.isNotEmpty && rawPhone != 'N/A' && rawPhone != '-';

    final rawCnic = LocalStorageService.firstRealValue([p['displayCnic'], p['patientCnic'], p['cnic'], p['guardianCnic']]);
    final hasCnic = rawCnic.isNotEmpty && rawCnic != 'N/A' && rawCnic != '0000000000000' && rawCnic != '-';
    final formattedCnic = hasCnic ? _formatCnic(rawCnic) : '—';
    final isChild = p['isChild'] == true ||
        ((p['guardianCnic'] ?? '').toString().isNotEmpty && (p['patientCnic'] ?? p['cnic'] ?? '').toString().isEmpty);

    final isVitalsOnly = p['isVitalsOnly'] == true ||
        p['vitalsOnly'] == true ||
        (p['visitReason']?.toString().toLowerCase().contains('vitals') ?? false);

    final rawType = (p['queueType'] ?? p['type'] ?? p['category'] ?? '').toString().toLowerCase().trim();
    final type = (rawType.isEmpty || rawType == 'unknown')
        ? (tokenSerial.contains('-NZ-') || tokenSerial.contains('NZ') ? 'non-zakat' : (tokenSerial.contains('-G-') ? 'gmwf' : 'zakat'))
        : rawType;

    final isDark = t.isDarkCanvas;
    final stage = _recordStage(p);
    final statusColor = stage == 'dispensed'
        ? (isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald)
        : stage == 'waiting_dispensary'
            ? (isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue)
            : (isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold);
    final vitalsBadgeColor = isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid;
    final regularBannerColor = isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final statusLabel = stage == 'dispensed'
        ? 'Dispensed'
        : stage == 'waiting_dispensary'
            ? 'Waiting for Dispensary'
            : 'Waiting for Doctor';

    final campLabel = _resolvePatientCampLabel(p, branchId);
    final days = (p['daysOfMedicine'] as num?)?.toInt() ?? 1;

    // Extract vitals data
    final vitalsRaw = p['vitals'];
    final vitals = (vitalsRaw is Map) ? Map<String, dynamic>.from(vitalsRaw) : <String, dynamic>{};
    final docVitals = (vitals['doctorVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['doctorVitals'])
        : (p['doctorVitals'] is Map ? Map<String, dynamic>.from(p['doctorVitals']) : <String, dynamic>{});
    final recVitals = (vitals['receptionistVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['receptionistVitals'])
        : (p['receptionistVitals'] is Map ? Map<String, dynamic>.from(p['receptionistVitals']) : <String, dynamic>{});

    String? pickVital(String key, [List<String>? altKeys]) {
      final candidates = [key, ...?altKeys];
      for (final k in candidates) {
        final v = docVitals[k] ?? vitals[k] ?? recVitals[k] ?? p[k];
        if (v != null && v.toString().trim().isNotEmpty && v.toString().trim() != 'N/A' && v.toString().trim() != '-') {
          return v.toString().trim();
        }
      }
      return null;
    }

    final bpSys = pickVital('systolic', ['bp_sys', 'sys']);
    final bpDia = pickVital('diastolic', ['bp_dia', 'dia']);
    final rawBp = pickVital('bp');
    final bp = (bpSys != null && bpDia != null) ? '$bpSys/$bpDia' : rawBp;
    final sugar = pickVital('sugar', ['bloodSugar', 'bs', 'glucose']);
    final temp = pickVital('temp', ['temperature']);
    final weight = pickVital('weight', ['wt']);
    final pulse = pickVital('pulse', ['heartRate', 'hr']);

    // Clinical assessment
    final condition = pickVital('condition', ['complaint', 'patientCondition']) ?? (isVitalsOnly ? 'Vitals Inspection Checkup' : 'N/A');
    final diagnosis = pickVital('diagnosis') ?? (isVitalsOnly ? 'Vitals Check Completed' : 'N/A');
    final doctorName = pickVital('doctorName', ['doctor', 'drName']) ?? 'N/A';

    // Medicines
    final presRaw = p['prescription'];
    final presMap = (presRaw is Map) ? Map<String, dynamic>.from(presRaw) : <String, dynamic>{};
    final medsList = (presMap['medicines'] ?? p['medicines'] ?? p['prescriptions']);
    final List<Map<String, dynamic>> medicines = [];
    if (medsList is List) {
      for (final m in medsList) {
        if (m is Map) medicines.add(Map<String, dynamic>.from(m));
      }
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: t.bgCard,
        child: Container(
          width: 540,
          constraints: const BoxConstraints(maxHeight: 680),
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (isVitalsOnly ? vitalsBadgeColor : t.accent).withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isVitalsOnly ? Icons.monitor_heart_rounded : Icons.medical_services_rounded,
                      color: isVitalsOnly ? vitalsBadgeColor : t.accent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              tokenSerial,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: t.textPrimary),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: tokenSerial));
                                AppToast.showSnackBar(context, 
                                  SnackBar(content: Text('Copied $tokenSerial'), duration: const Duration(seconds: 1)),
                                );
                              },
                              child: Icon(Icons.copy_rounded, size: 14, color: t.textSecondary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          campLabel.isNotEmpty ? campLabel : 'Branch Token',
                          style: TextStyle(fontSize: 11, color: t.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    icon: Icon(Icons.close_rounded, size: 20, color: t.textSecondary),
                    splashRadius: 18,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Scrollable body
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Token Category Banner
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: (isVitalsOnly ? vitalsBadgeColor : regularBannerColor).withValues(alpha: isDark ? 0.16 : 0.10),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (isVitalsOnly ? vitalsBadgeColor : regularBannerColor).withValues(alpha: isDark ? 0.40 : 0.30),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isVitalsOnly ? Icons.monitor_heart_outlined : Icons.medication_rounded,
                              size: 18,
                              color: isVitalsOnly ? vitalsBadgeColor : regularBannerColor,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isVitalsOnly ? "Vitals Inspection Token" : "Regular Consultation Token ($days-Day Course)",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: isVitalsOnly ? vitalsBadgeColor : regularBannerColor,
                                    ),
                                  ),
                                  Text(
                                    isVitalsOnly
                                        ? "Registered specifically for vital screening. No medicine course prescribed."
                                        : "Standard clinical evaluation with prescribed medicine regimen.",
                                    style: TextStyle(fontSize: 11, color: t.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: isDark ? 0.20 : 0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Patient Demographics
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("PATIENT INFORMATION", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Full Name", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
                              ],
                            ),
                            Divider(height: 14, color: t.bgRule),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("CNIC", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Text(formattedCnic + (isChild ? ' (Guardian)' : ''), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary)),
                              ],
                            ),
                            Divider(height: 14, color: t.bgRule),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Age & Gender", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Text(
                                  [if (age.isNotEmpty && age != 'N/A') '$age yrs', if (gender.isNotEmpty && gender != 'N/A') gender].join(' • '),
                                  style: TextStyle(fontSize: 12, color: t.textPrimary),
                                ),
                              ],
                            ),
                            if (hasPhone) ...[
                              Divider(height: 14, color: t.bgRule),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("Phone", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                  Text(rawPhone, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary)),
                                ],
                              ),
                            ],
                            Divider(height: 14, color: t.bgRule),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Queue Category", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Text(BranchLabels.text(type.toUpperCase(), branchId), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Vitals Section
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("RECORDED VITALS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              children: [
                                _buildVitalPill("Blood Pressure", bp != null ? "$bp mmHg" : "—", Icons.favorite_rounded, isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral, t),
                                _buildVitalPill("Blood Sugar", sugar != null ? "$sugar mg/dL" : "—", Icons.bloodtype_rounded, isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold, t),
                                _buildVitalPill("Temperature", temp != null ? "$temp °C" : "—", Icons.thermostat_rounded, isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan, t),
                                _buildVitalPill("Weight", weight != null ? "$weight kg" : "—", Icons.scale_rounded, isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue, t),
                                _buildVitalPill("Pulse", pulse != null ? "$pulse bpm" : "—", Icons.monitor_heart_rounded, isDark ? SoftPalette.softLavender : SoftPalette.royalViolet, t),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Clinical Consultation & Diagnosis
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("DOCTOR CONSULTATION", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Condition", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Flexible(child: Text(condition, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary), textAlign: TextAlign.right)),
                              ],
                            ),
                            Divider(height: 14, color: t.bgRule),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Diagnosis", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                Flexible(child: Text(diagnosis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.accent), textAlign: TextAlign.right)),
                              ],
                            ),
                            if (doctorName != 'N/A') ...[
                              Divider(height: 14, color: t.bgRule),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("Consulting Doctor", style: TextStyle(fontSize: 12, color: t.textSecondary)),
                                  Text(doctorName, style: TextStyle(fontSize: 12, color: t.textPrimary)),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Medicines Section (if regular)
                      if (!isVitalsOnly) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("PRESCRIBED MEDICINES (${medicines.length})", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: t.textTertiary, letterSpacing: 0.5)),
                              const SizedBox(height: 8),
                              if (medicines.isEmpty)
                                Text("No medicines recorded in this token prescription", style: TextStyle(fontSize: 12, color: t.textSecondary, fontStyle: FontStyle.italic))
                              else
                                ...medicines.map((m) {
                                  final mName = (m['name'] ?? 'Medicine').toString();
                                  final mDose = (m['dosage'] ?? m['dose'] ?? '').toString();
                                  final mTiming = (m['timing'] ?? '').toString();
                                  final mQty = (m['quantity'] ?? '').toString();
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Icon(Icons.medication_outlined, size: 14, color: t.accent),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            "$mName ${mDose.isNotEmpty ? "($mDose)" : ""}",
                                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textPrimary),
                                          ),
                                        ),
                                        if (mTiming.isNotEmpty)
                                          Text(mTiming, style: TextStyle(fontSize: 11, color: t.textSecondary)),
                                        if (mQty.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 8),
                                            child: Text("Qty: $mQty", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent)),
                                          ),
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: t.textSecondary,
                      side: BorderSide(color: t.bgRule),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text("Close"),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(dialogCtx);
                      final pid = p['patientId']?.toString() ?? p['id']?.toString() ?? '';
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PatientDetailScreen(
                            patientId: pid,
                            isOnline: true,
                            localBox: Hive.box('local_patients'),
                            branchId: branchId,
                            doctorId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
                            isAdmin: true,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.person_outline, size: 16),
                    label: const Text("Full Profile"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: GColor.onAccent(t.accent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVitalPill(String label, String value, IconData icon, Color color, RoleThemeData t) {
    final isDark = t.isDarkCanvas;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.34 : 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: t.textSecondary)),
              Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: t.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordsTable(BuildContext context, RoleThemeData t, List<Map<String, dynamic>> records, String branchId, {int startIndex = 0}) {
    final isDark = t.isDarkCanvas;
    final vitalsBadgeColor = isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid;
    final normalBadgeColor = isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
    final phoneColor = isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final courseColor = isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral;

    Widget colHead(IconData icon, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13.5, color: t.textTertiary),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary)),
          ],
        );

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(Colors.transparent),
          headingRowHeight: 42,
          dividerThickness: 0.7,
          dataRowMinHeight: 50,
          dataRowMaxHeight: 56,
          columnSpacing: 22,
          horizontalMargin: 16,
          columns: [
            DataColumn(label: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textTertiary))),
            DataColumn(label: colHead(Icons.confirmation_number_outlined, 'Token')),
            DataColumn(label: colHead(Icons.layers_outlined, 'Mode')),
            DataColumn(label: colHead(Icons.person_outline_rounded, 'Patient')),
            DataColumn(label: colHead(Icons.badge_outlined, 'CNIC')),
            DataColumn(label: colHead(Icons.phone_outlined, 'Phone')),
            DataColumn(label: colHead(Icons.category_outlined, 'Type')),
            DataColumn(label: colHead(Icons.donut_large_rounded, 'Status')),
            DataColumn(label: colHead(Icons.local_hospital_outlined, 'Facility & Shift')),
            DataColumn(label: colHead(Icons.medication_outlined, 'Relations / Course')),
            DataColumn(label: colHead(Icons.more_horiz_rounded, 'Actions')),
          ],
          rows: records.asMap().entries.map((entry) {
            final rowIndex = startIndex + entry.key + 1;
            final p = entry.value;
            final pid = p['patientId']?.toString() ?? p['id']?.toString() ?? '';
            final tokenSerial = p['serial']?.toString() ?? p['id']?.toString() ?? 'TK-000';
            final rawName = LocalStorageService.firstRealValue([p['patientName'], p['name'], p['fullName']]);
            final name = (rawName.isEmpty || rawName.toLowerCase() == 'unknown' || rawName.toLowerCase() == 'unknown patient')
                ? 'Unknown Patient'
                : rawName;
            final age = (p['age'] ?? p['patientAge'] ?? '').toString();
            final gender = (p['gender'] ?? p['patientGender'] ?? '').toString();
            final rawPhone = (p['phone'] ?? p['patientPhone'] ?? p['contactPhone'] ?? '').toString().trim();
            final hasPhone = rawPhone.isNotEmpty && rawPhone != 'N/A' && rawPhone != '-';
            final stage = _recordStage(p);
            final statusColor = stage == 'dispensed'
              ? (isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald)
              : stage == 'waiting_dispensary'
                ? (isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue)
                : (isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold);
            final statusLabel = stage == 'dispensed'
              ? 'Dispensed'
              : stage == 'waiting_dispensary'
                ? 'Waiting for Dispensary'
                : 'Waiting for Doctor';

            final rawCnic = LocalStorageService.firstRealValue([p['displayCnic'], p['patientCnic'], p['cnic'], p['guardianCnic']]);
            final hasCnic = rawCnic.isNotEmpty && rawCnic != 'N/A' && rawCnic != '0000000000000' && rawCnic != '-';
            final formattedCnic = hasCnic ? _formatCnic(rawCnic) : '—';
            final isChild = p['isChild'] == true ||
                ((p['guardianCnic'] ?? '').toString().isNotEmpty && (p['patientCnic'] ?? p['cnic'] ?? '').toString().isEmpty);

            final rawType = (p['queueType'] ?? p['type'] ?? p['category'] ?? '').toString().toLowerCase().trim();
            final type = (rawType.isEmpty || rawType == 'unknown')
                ? (tokenSerial.contains('-NZ-') || tokenSerial.contains('NZ') ? 'non-zakat' : (tokenSerial.contains('-G-') ? 'gmwf' : 'zakat'))
                : rawType;

            final isVitalsOnly = p['isVitalsOnly'] == true ||
                p['vitalsOnly'] == true ||
                (p['visitReason']?.toString().toLowerCase().contains('vitals') ?? false);

            final c = context.comfort;
            Color typeColor;
            if (type == 'zakat') {
              typeColor = c.chart1;
            } else if (type == 'non-zakat') {
              typeColor = c.chart2;
            } else if (type == 'gmwf') {
              typeColor = c.chart3;
            } else {
              typeColor = t.textSecondary;
            }

            final campLabel = _resolvePatientCampLabel(p, branchId);
            final days = (p['daysOfMedicine'] as num?)?.toInt() ?? 1;
            final visits = (p['totalVisits'] as num?)?.toInt() ?? 1;
            final isFrequent = p['frequentFlag'] == true;

            return DataRow(
              cells: [
                // 1. Index #
                DataCell(
                  Text(
                    '#$rowIndex',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: t.textSecondary,
                    ),
                  ),
                ),

                // 2. Token #
                DataCell(
                  InkWell(
                    onTap: () => _showVisitDetailsDialog(context, p, t, branchId),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tokenSerial,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textPrimary),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.info_outline_rounded, size: 12, color: t.textTertiary),
                        ],
                      ),
                    ),
                  ),
                ),

                // 3. Token Type (Vitals Only vs Normal)
                DataCell(
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: (isVitalsOnly ? vitalsBadgeColor : normalBadgeColor).withValues(alpha: isDark ? 0.18 : 0.11),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: (isVitalsOnly ? vitalsBadgeColor : normalBadgeColor).withValues(alpha: isDark ? 0.40 : 0.30),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isVitalsOnly ? Icons.monitor_heart_outlined : Icons.confirmation_number_outlined,
                          size: 11,
                          color: isVitalsOnly ? vitalsBadgeColor : normalBadgeColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isVitalsOnly ? 'Vitals Only' : 'Normal',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: isVitalsOnly ? vitalsBadgeColor : normalBadgeColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 2. Patient Name & Age/Gender
                DataCell(
                  InkWell(
                    onTap: () => _showVisitDetailsDialog(context, p, t, branchId),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textPrimary)),
                              if (isFrequent) const Padding(padding: EdgeInsets.only(left: 4), child: Text('🔥', style: TextStyle(fontSize: 11))),
                            ],
                          ),
                          if (age.isNotEmpty && age != 'N/A' || gender.isNotEmpty && gender != 'N/A')
                            Text(
                              [
                                if (age.isNotEmpty && age != 'N/A') '$age yrs',
                                if (gender.isNotEmpty && gender != 'N/A') gender,
                              ].join(' • '),
                              style: TextStyle(fontSize: 10, color: t.textTertiary),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

                // 3. CNIC
                DataCell(
                  hasCnic
                      ? InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: rawCnic));
                            AppToast.clear();
                            AppToast.showSnackBar(context, 
                              SnackBar(
                                content: Text('Copied CNIC: $formattedCnic'),
                                duration: const Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.badge_outlined, size: 13, color: t.accent),
                                const SizedBox(width: 5),
                                Text(
                                  formattedCnic,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: t.textPrimary,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                if (isChild) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: t.accent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Guardian',
                                      style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: t.accent),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : Text('—', style: TextStyle(fontSize: 12, color: t.textTertiary)),
                ),

                // 4. Phone Number
                DataCell(
                  hasPhone
                      ? InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: rawPhone));
                            AppToast.clear();
                            AppToast.showSnackBar(context, 
                              SnackBar(
                                content: Text('Copied Phone: $rawPhone'),
                                duration: const Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.phone_rounded, size: 12, color: phoneColor),
                                const SizedBox(width: 5),
                                Text(
                                  rawPhone,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: t.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Text('—', style: TextStyle(fontSize: 12, color: t.textTertiary)),
                ),

                // 5. Type Badge
                DataCell(
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: typeColor.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: typeColor.withValues(alpha: isDark ? 0.38 : 0.30)),
                    ),
                    child: Text(
                      BranchLabels.text(type.toUpperCase(), branchId),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: typeColor),
                    ),
                  ),
                ),

                // 6. Status
                DataCell(
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: isDark ? 0.18 : 0.11),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: statusColor.withValues(alpha: isDark ? 0.42 : 0.34)),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: statusColor,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),

                // 7. Facility & Shift
                DataCell(
                  Text(campLabel, style: TextStyle(fontSize: 11, color: t.textSecondary)),
                ),

                // 8. Relations / Course (with Vitals Inspection Token badge)
                DataCell(
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (isVitalsOnly)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: vitalsBadgeColor.withValues(alpha: isDark ? 0.18 : 0.13),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: vitalsBadgeColor.withValues(alpha: isDark ? 0.44 : 0.38)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.monitor_heart_outlined, size: 11, color: vitalsBadgeColor),
                              const SizedBox(width: 4),
                              Text('Vitals Only', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: vitalsBadgeColor)),
                            ],
                          ),
                        )
                      else ...[
                        if (visits > 1)
                          Text('$visits+ Visits', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.textPrimary))
                        else
                          Text('1st Visit', style: TextStyle(fontSize: 11, color: t.textTertiary)),
                        if (days > 1)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: courseColor.withValues(alpha: isDark ? 0.18 : 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('$days d course', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: courseColor)),
                          ),
                      ],
                    ],
                  ),
                ),

                // 9. Actions
                DataCell(
                  PopupMenuButton<String>(
                    color: t.bgCard,
                    icon: Icon(Icons.more_vert_rounded, size: 18, color: t.textSecondary),
                    onSelected: (val) {
                      if (val == 'details') {
                        _showVisitDetailsDialog(context, p, t, branchId);
                      } else if (val == 'view') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PatientDetailScreen(
                              patientId: pid,
                              isOnline: true,
                              localBox: Hive.box('local_patients'),
                              branchId: branchId,
                              doctorId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
                              isAdmin: true,
                            ),
                          ),
                        );
                      } else if (val == 'copy') {
                        Clipboard.setData(ClipboardData(text: tokenSerial));
                        AppToast.clear();
                        AppToast.showSnackBar(context, 
                          SnackBar(
                            content: Text('Copied $tokenSerial'),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      } else if (val == 'copy_cnic' && hasCnic) {
                        Clipboard.setData(ClipboardData(text: rawCnic));
                        AppToast.clear();
                        AppToast.showSnackBar(context, 
                          SnackBar(
                            content: Text('Copied CNIC: $formattedCnic'),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      } else if (val == 'copy_phone' && hasPhone) {
                        Clipboard.setData(ClipboardData(text: rawPhone));
                        AppToast.clear();
                        AppToast.showSnackBar(context, 
                          SnackBar(
                            content: Text('Copied Phone: $rawPhone'),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'details',
                        child: Row(
                          children: [
                            Icon(Icons.assignment_outlined, size: 16),
                            SizedBox(width: 8),
                            Text("Visit & Vitals Details"),
                          ],
                        ),
                      ),
                      const PopupMenuItem(value: 'view', child: Row(children: [Icon(Icons.person_rounded, size: 16), SizedBox(width: 8), Text("View Profile")])),
                      const PopupMenuItem(value: 'copy', child: Row(children: [Icon(Icons.copy_rounded, size: 16), SizedBox(width: 8), Text("Copy Token")])),
                      if (hasCnic)
                        const PopupMenuItem(value: 'copy_cnic', child: Row(children: [Icon(Icons.badge_outlined, size: 16), SizedBox(width: 8), Text("Copy CNIC")])),
                      if (hasPhone)
                        const PopupMenuItem(value: 'copy_phone', child: Row(children: [Icon(Icons.phone_rounded, size: 16), SizedBox(width: 8), Text("Copy Phone")])),
                    ],
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMobilePatientRecordsList(BuildContext context, RoleThemeData t, List<Map<String, dynamic>> records, String branchId, {int startIndex = 0}) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: records.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return _buildMobilePatientCard(context, t, records[index], branchId, index: startIndex + index + 1);
      },
    );
  }

  Widget _buildMobilePatientCard(BuildContext context, RoleThemeData t, Map<String, dynamic> p, String branchId, {int? index}) {
    final isDark = t.isDarkCanvas;
    final vitalsBadgeColor = isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid;
    final normalBadgeColor = isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
    final phoneColor = isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final courseColor = isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral;

    final pid = p['patientId']?.toString() ?? p['id']?.toString() ?? '';
    final tokenSerial = p['serial']?.toString() ?? p['id']?.toString() ?? 'TK-000';
    final rawName = LocalStorageService.firstRealValue([p['patientName'], p['name'], p['fullName']]);
    final name = (rawName.isEmpty || rawName.toLowerCase() == 'unknown' || rawName.toLowerCase() == 'unknown patient')
        ? 'Unknown Patient'
        : rawName;
    final age = (p['age'] ?? p['patientAge'] ?? '').toString();
    final gender = (p['gender'] ?? p['patientGender'] ?? '').toString();
    final rawPhone = (p['phone'] ?? p['patientPhone'] ?? p['contactPhone'] ?? '').toString().trim();
    final hasPhone = rawPhone.isNotEmpty && rawPhone != 'N/A' && rawPhone != '-';
    final stage = _recordStage(p);
    final statusColor = stage == 'dispensed'
        ? (isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald)
        : stage == 'waiting_dispensary'
            ? (isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue)
            : (isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold);
    final statusLabel = stage == 'dispensed'
        ? 'Dispensed'
        : stage == 'waiting_dispensary'
            ? 'Waiting Dispensary'
            : 'Waiting Doctor';

    final rawCnic = LocalStorageService.firstRealValue([p['displayCnic'], p['patientCnic'], p['cnic'], p['guardianCnic']]);
    final hasCnic = rawCnic.isNotEmpty && rawCnic != 'N/A' && rawCnic != '0000000000000' && rawCnic != '-';
    final formattedCnic = hasCnic ? _formatCnic(rawCnic) : '—';
    final isChild = p['isChild'] == true ||
        ((p['guardianCnic'] ?? '').toString().isNotEmpty && (p['patientCnic'] ?? p['cnic'] ?? '').toString().isEmpty);

    final rawType = (p['queueType'] ?? p['type'] ?? p['category'] ?? '').toString().toLowerCase().trim();
    final type = (rawType.isEmpty || rawType == 'unknown')
        ? (tokenSerial.contains('-NZ-') || tokenSerial.contains('NZ') ? 'non-zakat' : (tokenSerial.contains('-G-') ? 'gmwf' : 'zakat'))
        : rawType;

    final isVitalsOnly = p['isVitalsOnly'] == true ||
        p['vitalsOnly'] == true ||
        (p['visitReason']?.toString().toLowerCase().contains('vitals') ?? false);

    final c = context.comfort;
    Color typeColor;
    if (type == 'zakat') {
      typeColor = c.chart1;
    } else if (type == 'non-zakat') {
      typeColor = c.chart2;
    } else if (type == 'gmwf') {
      typeColor = c.chart3;
    } else {
      typeColor = t.textSecondary;
    }

    final campLabel = _resolvePatientCampLabel(p, branchId);
    final days = (p['daysOfMedicine'] as num?)?.toInt() ?? 1;
    final visits = (p['totalVisits'] as num?)?.toInt() ?? 1;
    final isFrequent = p['frequentFlag'] == true;

    return Container(
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
        boxShadow: GShadow.s1(isDark),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Token # + Type Badge + Status + Details Button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (index != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: t.bgCard,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Text(
                            '#$index',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: t.textSecondary),
                          ),
                        ),
                      InkWell(
                        onTap: () => _showVisitDetailsDialog(context, p, t, branchId),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: t.accent.withValues(alpha: isDark ? 0.16 : 0.10),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: t.accent.withValues(alpha: isDark ? 0.38 : 0.30)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tokenSerial,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: t.accent),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.info_outline_rounded, size: 12, color: t.accent),
                            ],
                          ),
                        ),
                      ),
                      // Token Type (Vitals Only vs Normal)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: (isVitalsOnly ? vitalsBadgeColor : normalBadgeColor).withValues(alpha: isDark ? 0.18 : 0.11),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: (isVitalsOnly ? vitalsBadgeColor : normalBadgeColor).withValues(alpha: isDark ? 0.40 : 0.30),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isVitalsOnly ? Icons.monitor_heart_outlined : Icons.confirmation_number_outlined,
                              size: 10,
                              color: isVitalsOnly ? vitalsBadgeColor : normalBadgeColor,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isVitalsOnly ? 'Vitals Only' : 'Normal',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: isVitalsOnly ? vitalsBadgeColor : normalBadgeColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: typeColor.withValues(alpha: isDark ? 0.18 : 0.11),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: typeColor.withValues(alpha: isDark ? 0.38 : 0.28)),
                        ),
                        child: Text(
                          BranchLabels.text(type.toUpperCase(), branchId),
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: typeColor, letterSpacing: 0.3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  flex: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: isDark ? 0.18 : 0.11),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: statusColor.withValues(alpha: isDark ? 0.42 : 0.32)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Row 2: Patient Name & Age/Gender + Profile Navigation
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _showVisitDetailsDialog(context, p, t, branchId),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isFrequent) const Padding(padding: EdgeInsets.only(left: 4), child: Text('🔥', style: TextStyle(fontSize: 12))),
                          ],
                        ),
                        if ((age.isNotEmpty && age != 'N/A') || (gender.isNotEmpty && gender != 'N/A')) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (age.isNotEmpty && age != 'N/A') '$age yrs',
                              if (gender.isNotEmpty && gender != 'N/A') gender,
                            ].join(' • '),
                            style: TextStyle(fontSize: 11, color: t.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PatientDetailScreen(
                        patientId: pid,
                        isOnline: true,
                        localBox: Hive.box('local_patients'),
                        branchId: branchId,
                        doctorId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
                        isAdmin: true,
                      ),
                    ),
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.accent.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: t.accent.withValues(alpha: isDark ? 0.34 : 0.24)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("Profile", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent)),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward_ios_rounded, size: 10, color: t.accent),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Row 3: CNIC and Phone Badges
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (hasCnic)
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: rawCnic));
                      AppToast.clear();
                      AppToast.showSnackBar(context, 
                        SnackBar(
                          content: Text('Copied CNIC: $formattedCnic'),
                          duration: const Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: t.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.badge_outlined, size: 11, color: t.accent),
                          const SizedBox(width: 4),
                          Text(
                            formattedCnic,
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: t.textPrimary),
                          ),
                          if (isChild) ...[
                            const SizedBox(width: 4),
                            Text('(Guardian)', style: TextStyle(fontSize: 8, color: t.accent, fontWeight: FontWeight.bold)),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (hasPhone)
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: rawPhone));
                      AppToast.clear();
                      AppToast.showSnackBar(context, 
                        SnackBar(
                          content: Text('Copied Phone: $rawPhone'),
                          duration: const Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: t.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.phone_rounded, size: 11, color: phoneColor),
                          const SizedBox(width: 4),
                          Text(
                            rawPhone,
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: t.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // Row 4: Facility & Shift info + Course / Visit Tags (with Vitals Inspection Token badge)
            if (campLabel.isNotEmpty || visits > 1 || days > 1 || isVitalsOnly) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: t.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.bgRule.withValues(alpha: 0.7)),
                ),
                child: Row(
                  children: [
                    if (campLabel.isNotEmpty)
                      Expanded(
                        child: Text(
                          campLabel,
                          style: TextStyle(fontSize: 10, color: t.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (isVitalsOnly)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: vitalsBadgeColor.withValues(alpha: isDark ? 0.18 : 0.13),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('🩺 Vitals Only', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: vitalsBadgeColor)),
                      )
                    else ...[
                      if (visits > 1) ...[
                        if (campLabel.isNotEmpty) const SizedBox(width: 6),
                        Text('$visits+ Visits', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: t.textPrimary)),
                      ],
                      if (days > 1) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: courseColor.withValues(alpha: isDark ? 0.18 : 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('$days d course', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: courseColor)),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPaginationFooter(BuildContext context, RoleThemeData t, int totalRecords, int currentPage, int totalPages, int startIdx, int endIdx) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;

        if (isMobile) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "${startIdx + 1}–$endIdx of $totalRecords records",
                    style: TextStyle(fontSize: 11, color: t.textTertiary, fontWeight: FontWeight.w600),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _rowsPerPage,
                      dropdownColor: t.bgCard,
                      icon: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: t.textSecondary),
                      style: TextStyle(fontSize: 11, color: t.textPrimary),
                      items: const [
                        DropdownMenuItem(value: 10, child: Text("10 / page")),
                        DropdownMenuItem(value: 25, child: Text("25 / page")),
                        DropdownMenuItem(value: 50, child: Text("50 / page")),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _rowsPerPage = val;
                            _currentPage = 1;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded, size: 20),
                    onPressed: currentPage > 1 ? () => setState(() => _currentPage--) : null,
                    color: t.textSecondary,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Page $currentPage of $totalPages",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded, size: 20),
                    onPressed: currentPage < totalPages ? () => setState(() => _currentPage++) : null,
                    color: t.textSecondary,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                ],
              ),
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Showing info
            Text(
              "Showing ${startIdx + 1} to $endIdx of $totalRecords records",
              style: TextStyle(fontSize: 12, color: t.textTertiary),
            ),

            // Page buttons & Page Size selector
            Row(
              children: [
                // Page buttons
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded, size: 18),
                  onPressed: currentPage > 1 ? () => setState(() => _currentPage--) : null,
                  color: t.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                for (int p = 1; p <= totalPages && p <= 5; p++) ...[
                  InkWell(
                    onTap: () => setState(() => _currentPage = p),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p == currentPage ? t.accent.withValues(alpha: 0.15) : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: p == currentPage ? t.accent : Colors.transparent),
                      ),
                      child: Text(
                        "$p",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: p == currentPage ? FontWeight.bold : FontWeight.normal,
                          color: p == currentPage ? t.accent : t.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded, size: 18),
                  onPressed: currentPage < totalPages ? () => setState(() => _currentPage++) : null,
                  color: t.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                const SizedBox(width: 12),

                // Rows per page selector
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _rowsPerPage,
                    dropdownColor: t.bgCard,
                    icon: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: t.textSecondary),
                    style: TextStyle(fontSize: 11, color: t.textPrimary),
                    items: const [
                      DropdownMenuItem(value: 10, child: Text("10 / page")),
                      DropdownMenuItem(value: 25, child: Text("25 / page")),
                      DropdownMenuItem(value: 50, child: Text("50 / page")),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _rowsPerPage = val;
                          _currentPage = 1;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildCampFilterChip(String label, bool isSelected, VoidCallback onTap, Color color, RoleThemeData t) {
    final isDark = t.isDarkCanvas;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Color.alphaBlend(
                  color.withValues(alpha: isDark ? 0.22 : 0.12),
                  t.bgCard,
                )
              : t.bgCardAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? color : t.bgRule,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: isSelected ? color : t.textTertiary, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? color : t.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom Painters for Sparklines and Performance Charts
// ─────────────────────────────────────────────────────────────────────────────




class _PerformanceMultiLinePainter extends CustomPainter {
  final RoleThemeData theme;
  final Color tokensColor;
  final Color prescriptionsColor;
  final Color dispensaryColor;
  final List<double> tokensData;
  final List<double> prescriptionsData;
  final List<double> dispensaryData;
  final List<String> dateLabels;
  final int? hoveredIndex;

  const _PerformanceMultiLinePainter({
    required this.theme,
    required this.tokensColor,
    required this.prescriptionsColor,
    required this.dispensaryColor,
    required this.tokensData,
    required this.prescriptionsData,
    required this.dispensaryData,
    required this.dateLabels,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = theme.isDarkCanvas;
    final gridPaint = Paint()
      ..color = theme.bgRule.withValues(alpha: isDark ? 0.45 : 0.65)
      ..strokeWidth = 1;

    // Available chart curve height (leaving 26px for date labels at bottom)
    final h = size.height - 28;

    // Draw horizontal grid lines
    const gridLines = 4;
    final yStep = h / gridLines;
    for (int i = 0; i <= gridLines; i++) {
      final y = i * yStep;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (tokensData.isEmpty) return;

    double maxVal = 1.0;
    for (final v in [...tokensData, ...prescriptionsData, ...dispensaryData]) {
      if (v > maxVal) maxVal = v;
    }

    // Leave comfortable margin at top so point number badges never clip off
    List<double> normalize(List<double> raw) {
      return raw.map((v) => (1.0 - ((v / maxVal) * 0.68 + 0.16)).clamp(0.06, 0.94)).toList();
    }

    final normTokens = normalize(tokensData);
    final normPresc = normalize(prescriptionsData);
    final normDisp = normalize(dispensaryData);

    // Draw curves
    _drawSmoothCurve(canvas, size, h, normTokens, tokensColor, true);
    _drawSmoothCurve(canvas, size, h, normPresc, prescriptionsColor, true);
    _drawSmoothCurve(canvas, size, h, normDisp, dispensaryColor, true);

    // Draw bottom date labels
    if (dateLabels.isNotEmpty) {
      final int step = (dateLabels.length / 7).ceil().clamp(1, 10);
      final double xStep = size.width / (dateLabels.length - 1).clamp(1, 9999);

      for (int i = 0; i < dateLabels.length; i += step) {
        final tp = TextPainter(
          text: TextSpan(
            text: dateLabels[i],
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: theme.textSecondary.withValues(alpha: 0.85),
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        final double xPos = (i * xStep - (tp.width / 2)).clamp(2.0, size.width - tp.width - 2.0);
        tp.paint(canvas, Offset(xPos, size.height - 14));
      }
    }

    // Draw numbers on each point
    _drawPointNumbers(canvas, size, h, normTokens, normPresc, normDisp);

    // Draw hover indicator & inspection card if active
    _drawHoverTooltip(canvas, size, h, normTokens, normPresc, normDisp);
  }

  void _drawPointNumbers(
    Canvas canvas,
    Size size,
    double h,
    List<double> normTokens,
    List<double> normPresc,
    List<double> normDisp,
  ) {
    final int n = tokensData.length;
    if (n == 0) return;
    final double xStep = size.width / (n - 1).clamp(1, 9999);

    for (int i = 0; i < n; i++) {
      if (hoveredIndex == i) continue; // Hover tooltip renders full breakdown

      final x = i * xStep;
      final tVal = tokensData[i].toInt();
      final pVal = prescriptionsData[i].toInt();
      final dVal = dispensaryData[i].toInt();

      final yT = normTokens[i] * h;
      final yP = normPresc[i] * h;
      final yD = normDisp[i] * h;
      final minY = [yT, yP, yD].reduce((a, b) => a < b ? a : b);

      // Case 1: All three are zero
      if (tVal == 0 && pVal == 0 && dVal == 0) {
        _paintBadge(
          canvas: canvas,
          size: size,
          x: x,
          y: yT - 8,
          text: '0',
          textColor: theme.textTertiary.withValues(alpha: 0.55),
          bgColor: Colors.transparent,
          borderColor: Colors.transparent,
          isZero: true,
        );
        continue;
      }

      // Case 2: All three series are equal and > 0
      if (tVal == pVal && pVal == dVal) {
        _paintBadge(
          canvas: canvas,
          size: size,
          x: x,
          y: yT - 16,
          text: '$tVal',
          textColor: theme.textPrimary,
          bgColor: theme.bgCardAlt,
          borderColor: tokensColor.withValues(alpha: 0.70),
          isBold: true,
        );
        continue;
      }

      // Case 3: Only one series has activity (> 0)
      if (tVal > 0 && pVal == 0 && dVal == 0) {
        _paintBadge(
          canvas: canvas,
          size: size,
          x: x,
          y: yT - 15,
          text: 'T: $tVal',
          textColor: tokensColor,
          bgColor: theme.bgCard,
          borderColor: tokensColor.withValues(alpha: 0.60),
          isBold: true,
        );
        continue;
      }
      if (pVal > 0 && tVal == 0 && dVal == 0) {
        _paintBadge(
          canvas: canvas,
          size: size,
          x: x,
          y: yP - 15,
          text: 'Rx: $pVal',
          textColor: prescriptionsColor,
          bgColor: theme.bgCard,
          borderColor: prescriptionsColor.withValues(alpha: 0.60),
          isBold: true,
        );
        continue;
      }
      if (dVal > 0 && tVal == 0 && pVal == 0) {
        _paintBadge(
          canvas: canvas,
          size: size,
          x: x,
          y: yD - 15,
          text: 'D: $dVal',
          textColor: dispensaryColor,
          bgColor: theme.bgCard,
          borderColor: dispensaryColor.withValues(alpha: 0.60),
          isBold: true,
        );
        continue;
      }

      // Case 4: Multiple non-zero values that differ:
      // Render clean, non-overlapping multi-value pill above highest point
      final spans = <InlineSpan>[];
      if (tVal > 0) {
        spans.add(TextSpan(
          text: 'T:$tVal',
          style: TextStyle(
            color: tokensColor,
            fontWeight: FontWeight.w800,
            fontSize: 9.5,
          ),
        ));
      }
      if (pVal > 0) {
        if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ', style: TextStyle(fontSize: 8)));
        spans.add(TextSpan(
          text: 'Rx:$pVal',
          style: TextStyle(
            color: prescriptionsColor,
            fontWeight: FontWeight.w800,
            fontSize: 9.5,
          ),
        ));
      }
      if (dVal > 0) {
        if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ', style: TextStyle(fontSize: 8)));
        spans.add(TextSpan(
          text: 'D:$dVal',
          style: TextStyle(
            color: dispensaryColor,
            fontWeight: FontWeight.w800,
            fontSize: 9.5,
          ),
        ));
      }

      final tp = TextPainter(
        text: TextSpan(children: spans),
        textDirection: ui.TextDirection.ltr,
      )..layout();

      final pillW = tp.width + 10;
      final pillH = tp.height + 4;
      final pillX = (x - pillW / 2).clamp(4.0, size.width - pillW - 4.0);
      final pillY = (minY - 17).clamp(3.0, size.height - pillH - 3.0);

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(pillX, pillY, pillW, pillH),
        const Radius.circular(6),
      );
      canvas.drawRRect(
        rrect,
        Paint()..color = theme.bgCardAlt,
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = theme.bgRule.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      tp.paint(
        canvas,
        Offset(pillX + (pillW - tp.width) / 2, pillY + (pillH - tp.height) / 2),
      );
    }
  }

  void _drawHoverTooltip(
    Canvas canvas,
    Size size,
    double h,
    List<double> normTokens,
    List<double> normPresc,
    List<double> normDisp,
  ) {
    if (hoveredIndex == null) return;
    final int idx = hoveredIndex!;
    if (idx < 0 || idx >= tokensData.length) return;

    final double xStep = size.width / (tokensData.length - 1).clamp(1, 9999);
    final double x = idx * xStep;
    final isDark = theme.isDarkCanvas;

    // 1. Vertical indicator line
    final linePaint = Paint()
      ..color = theme.accent.withValues(alpha: isDark ? 0.50 : 0.35)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(x, 0), Offset(x, h), linePaint);

    final tVal = tokensData[idx].toInt();
    final pVal = prescriptionsData[idx].toInt();
    final dVal = dispensaryData[idx].toInt();

    final yT = normTokens[idx] * h;
    final yP = normPresc[idx] * h;
    final yD = normDisp[idx] * h;

    // Highlight circles on each series dot
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    ringPaint.color = tokensColor;
    canvas.drawCircle(Offset(x, yT), 5.5, ringPaint);
    ringPaint.color = prescriptionsColor;
    canvas.drawCircle(Offset(x, yP), 5.5, ringPaint);
    ringPaint.color = dispensaryColor;
    canvas.drawCircle(Offset(x, yD), 5.5, ringPaint);

    // 2. Floating Tooltip Card
    final dateStr = idx < dateLabels.length ? dateLabels[idx] : '';
    final tooltipSpan = TextSpan(
      children: [
        if (dateStr.isNotEmpty)
          TextSpan(
            text: '$dateStr\n',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: theme.textPrimary,
            ),
          ),
        TextSpan(
          text: 'Tokens: $tVal  ',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: tokensColor,
          ),
        ),
        TextSpan(
          text: 'Rx: $pVal  ',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: prescriptionsColor,
          ),
        ),
        TextSpan(
          text: 'Disp: $dVal',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: dispensaryColor,
          ),
        ),
      ],
    );

    final tp = TextPainter(
      text: tooltipSpan,
      textAlign: TextAlign.center,
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final cardW = tp.width + 16;
    final cardH = tp.height + 12;
    final cardX = (x - cardW / 2).clamp(6.0, size.width - cardW - 6.0);
    final minY = [yT, yP, yD].reduce((a, b) => a < b ? a : b);
    var cardY = minY - cardH - 12;
    if (cardY < 4) cardY = minY + 16;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cardX, cardY, cardW, cardH),
      const Radius.circular(8),
    );

    canvas.drawRRect(
      rrect.shift(const Offset(0, 3)),
      Paint()
        ..color = SoftPalette.gray900.withValues(alpha: isDark ? 0.45 : 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    canvas.drawRRect(
      rrect,
      Paint()..color = theme.bgCard,
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..color = theme.accent.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    tp.paint(
      canvas,
      Offset(cardX + (cardW - tp.width) / 2, cardY + (cardH - tp.height) / 2),
    );
  }

  void _paintBadge({
    required Canvas canvas,
    required Size size,
    required double x,
    required double y,
    required String text,
    required Color textColor,
    required Color bgColor,
    required Color borderColor,
    bool isZero = false,
    bool isBold = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: isZero ? 8.5 : (isBold ? 10.5 : 9.5),
          fontWeight: isZero ? FontWeight.w500 : (isBold ? FontWeight.w900 : FontWeight.w800),
          color: textColor,
          letterSpacing: -0.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final pillW = tp.width + (isZero ? 4 : 8);
    final pillH = tp.height + (isZero ? 2 : 4);
    final pillX = (x - pillW / 2).clamp(3.0, size.width - pillW - 3.0);
    final pillY = (y - pillH / 2).clamp(2.0, size.height - pillH - 2.0);

    if (bgColor != Colors.transparent) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(pillX, pillY, pillW, pillH),
        const Radius.circular(6),
      );
      canvas.drawRRect(rrect, Paint()..color = bgColor);
      if (borderColor != Colors.transparent) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = borderColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }
    }

    tp.paint(
      canvas,
      Offset(pillX + (pillW - tp.width) / 2, pillY + (pillH - tp.height) / 2),
    );
  }

  void _drawSmoothCurve(Canvas canvas, Size size, double h, List<double> normalizedPoints, Color color, bool fillArea) {
    if (normalizedPoints.isEmpty) return;

    final xStep = size.width / (normalizedPoints.length - 1).clamp(1, 9999);

    final path = Path();
    final fillPath = Path();

    path.moveTo(0, normalizedPoints[0] * h);
    fillPath.moveTo(0, h);
    fillPath.lineTo(0, normalizedPoints[0] * h);

    for (int i = 0; i < normalizedPoints.length - 1; i++) {
      final x1 = i * xStep;
      final y1 = normalizedPoints[i] * h;
      final x2 = (i + 1) * xStep;
      final y2 = normalizedPoints[i + 1] * h;

      final cx1 = x1 + (x2 - x1) / 2;
      final cy1 = y1;
      final cx2 = x1 + (x2 - x1) / 2;
      final cy2 = y2;

      path.cubicTo(cx1, cy1, cx2, cy2, x2, y2);
      fillPath.cubicTo(cx1, cy1, cx2, cy2, x2, y2);
    }

    fillPath.lineTo(size.width, h);
    fillPath.close();

    if (fillArea) {
      final gradientPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.22),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, h));
      canvas.drawPath(fillPath, gradientPaint);
    }

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, strokePaint);

    // Draw dots
    final dotPaint = Paint()..color = color;
    final dotRing = Paint()..color = theme.bgCard;
    for (int i = 0; i < normalizedPoints.length; i++) {
      final x = i * xStep;
      final y = normalizedPoints[i] * h;
      canvas.drawCircle(Offset(x, y), 3.6, dotRing);
      canvas.drawCircle(Offset(x, y), 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PerformanceMultiLinePainter oldDelegate) {
    return oldDelegate.theme != theme ||
        oldDelegate.tokensColor != tokensColor ||
        oldDelegate.prescriptionsColor != prescriptionsColor ||
        oldDelegate.dispensaryColor != dispensaryColor ||
        oldDelegate.hoveredIndex != hoveredIndex ||
        oldDelegate.tokensData != tokensData ||
        oldDelegate.prescriptionsData != prescriptionsData ||
        oldDelegate.dispensaryData != dispensaryData ||
        oldDelegate.dateLabels != dateLabels;
  }
}