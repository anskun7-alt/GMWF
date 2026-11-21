import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/madrassa_config.dart';
import '../models/madrassa_fee_logic.dart';
import '../widgets/madrassa_common_widgets.dart';
import '../utils/madrassa_report_helper.dart';
import '../madrassa_strings.dart';
import '../student_fee_ledger.dart';
import '../widgets/madrassa_erp.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/sync_service.dart';
import '../../../design/design_system.dart';

/// Safely converts whatever Map-ish value comes back from Firestore / JSON
/// / local-storage into a proper `Map<String, dynamic>`.
Map<String, dynamic>? _asStringMap(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

class MonthlyReportView extends ConsumerStatefulWidget {
  final String branchId;
  final String? username;
  final String? role;

  const MonthlyReportView({
    super.key,
    required this.branchId,
    this.username,
    this.role,
  });

  @override
  ConsumerState<MonthlyReportView> createState() => _MonthlyReportViewState();
}

class _MonthlyReportViewState extends ConsumerState<MonthlyReportView> {
  int? _selectedYear;
  int? _selectedMonth;
  bool? _userShowDetailOverride;
  String _searchQuery = '';
  int? _downloadedYear;
  int? _downloadedMonth;
  // Cache for student fee calculations to improve performance
  final Map<String, Map<String, dynamic>> _feeCache = {};

  final ScrollController _verticalController = ScrollController();

  static const double _kRowHeight = 56;
  static const double _kHeaderHeight = 50;

  bool get _canManageDues {
    final r = (widget.role ?? '').toLowerCase().trim();
    final u = (widget.username ?? '').toLowerCase().trim();
    return r.contains('chairman') ||
        r.contains('hq') ||
        r.contains('manager') ||
        r.contains('ceo') ||
        r.contains('superadmin') ||
        r.contains('super_admin') ||
        r.contains('global_admin') ||
        r.contains('admin') ||
        u.contains('chairman') ||
        u.contains('hq');
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  // Helper to get cached fee for a student or compute if absent
  Map<String, dynamic> _getStudentFee({
    required String studentId,
    required dynamic studentSnap,
    required List<dynamic> monthLogs,
    required MadrassaConfig config,
    required int workingDays,
    required List<DateTime> holidays,
  }) {
    if (_feeCache.containsKey(studentId)) {
      return _feeCache[studentId]!;
    }
    final fee = MadrassaFeeLogic.calculateStudentFee(
      studentId: studentId,
      studentData: studentSnap is DocumentSnapshot
          ? (_asStringMap(studentSnap.data()) ?? <String, dynamic>{})
          : Map<String, dynamic>.from(studentSnap as Map),
      logs: monthLogs,
      config: config,
      totalWorkingDays: workingDays,
      holidays: holidays,
    );
    _feeCache[studentId] = fee;
    return fee;
  }

  String get _effectiveBranch => MadrassaLocalStorage.normalizeBranch(widget.branchId);

  @override
  void initState() {
    super.initState();
    MadrassaLocalStorage.downloadStudents(_effectiveBranch);
    MadrassaLocalStorage.downloadHolidays(_effectiveBranch);
  }

  @override
  Widget build(BuildContext context) {
    final configAsyncValue = ref.watch(madrassaConfigProvider(_effectiveBranch));
    final holidaysAsyncValue = ref.watch(madrassaHolidaysProvider(_effectiveBranch));

    return configAsyncValue.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => Scaffold(body: Center(child: Text('Error loading config: $e'))),
      data: (config) {
        final now = DateTime.now();
        final currentYear = _selectedYear ?? now.year;
        final currentMonth = _selectedMonth ?? now.month;

        final cachedHolidays = holidaysAsyncValue.value ?? [];
        final holidays = cachedHolidays
            .map<DateTime>((d) {
              final dateVal = d['date'];
              if (dateVal is Timestamp) return dateVal.toDate();
              if (dateVal is String) return DateTime.tryParse(dateVal) ?? DateTime.now();
              return DateTime.now();
            })
            .toList();

        final workingDays = MadrassaFeeLogic.getWorkingDaysCount(currentYear, currentMonth, holidays);
        final isFeeEnabled = (config.enableFees != false) && LocalStorageService.isMadrassaFeeEnabled(_effectiveBranch);

        final displayConfig = MadrassaConfig(
          id: config.id,
          year: currentYear,
          month: currentMonth,
          ptmDay: config.ptmDay,
          baseFee: config.baseFee,
          ptmDeduction: config.ptmDeduction,
          messageTotalDeduction: config.messageTotalDeduction,
          attendanceMaxDeduction: config.attendanceMaxDeduction,
          uniformMaxDeduction: config.uniformMaxDeduction,
          enableFees: isFeeEnabled,
          auditLog: config.auditLog,
        );

        if (_downloadedYear != currentYear || _downloadedMonth != currentMonth) {
          _downloadedYear = currentYear;
          _downloadedMonth = currentMonth;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            MadrassaLocalStorage.downloadLogsForMonth(_effectiveBranch, currentYear, currentMonth);
            MadrassaLocalStorage.downloadFeePaymentsForMonth(_effectiveBranch, currentYear, currentMonth);
          });
        }

        final studentsAsyncValue = ref.watch(madrassaStudentsProvider(_effectiveBranch));
        final logsAsyncValue = ref.watch(madrassaMonthlyLogsProvider((branchId: _effectiveBranch, year: currentYear, month: currentMonth)));
        final feePaymentsAsyncValue = ref.watch(madrassaFeePaymentsProvider((branchId: _effectiveBranch, year: currentYear, month: currentMonth)));

        return studentsAsyncValue.when(
          loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, st) => Scaffold(body: Center(child: Text('Error loading students: $e'))),
          data: (students) {
            final filteredStudents = students.where((s) {
              final name = (s['name']?.toString() ?? '').trim();
              final isDeleted = s['isDeleted'] == true ||
                  s['deleted'] == true ||
                  s['status']?.toString().toLowerCase() == 'deleted';
              if (name.isEmpty || isDeleted) return false;
              if (_searchQuery.isEmpty) return true;
              final roll = (s['rollNumber']?.toString() ?? '').toLowerCase();
              return name.toLowerCase().contains(_searchQuery) || roll.contains(_searchQuery);
            }).toList();

            return logsAsyncValue.when(
              loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
              error: (e, st) => Scaffold(body: Center(child: Text('Error loading logs: $e'))),
              data: (monthLogs) {
                _feeCache.clear();
                final payments = feePaymentsAsyncValue.value ?? {};

                final c = context.comfort;
                final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);

                return Scaffold(
                  backgroundColor: c.surfaceSunken,
                  body: LayoutBuilder(
                    builder: (context, constraints) {
                      final bool showDetail = _userShowDetailOverride ?? (constraints.maxWidth >= 1100);
                      final bool isMobile = constraints.maxWidth < GBreakpoint.mobile;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeader(context, displayConfig, students, monthLogs, currentYear, currentMonth, holidays, workingDays, showDetail, isDark),

                          // Warning Banner
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: c.warning.withValues(alpha: 0.1),
                                borderRadius: MadrassaErp.radius,
                                border: Border.all(color: c.warning.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: c.warning, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      context.isUrdu
                                          ? 'آرکائیو اور مکمل شدہ طلباء کو بلک ڈاؤن لوڈ سے خارج کر دیا گیا ہے۔ ان کی رپورٹس دستی طور پر ڈاؤن لوڈ کریں۔'
                                          : 'Archived and Completed students are excluded from bulk downloads and must be downloaded manually.',
                                      style: TextStyle(
                                        color: c.warning,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        fontFamilyFallback: const ['Noori'],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Search Bar
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: TextField(
                              style: TextStyle(color: c.textPrimary),
                              decoration: InputDecoration(
                                hintText: context.isUrdu ? 'طالب علم تلاش کریں (نام یا رول نمبر)...' : 'Search student by name or roll number...',
                                hintStyle: TextStyle(fontFamilyFallback: const ['Noori'], color: c.textMuted),
                                prefixIcon: Icon(Icons.search, color: c.textMuted),
                                filled: true,
                                fillColor: c.surface,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: MadrassaErp.radius,
                                  borderSide: BorderSide(color: c.border),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: MadrassaErp.radius,
                                  borderSide: BorderSide(color: c.brand, width: 2),
                                ),
                              ),
                                  onChanged: (val) {
                                    setState(() {
                                      _searchQuery = val.trim().toLowerCase();
                                    });
                                  },
                                ),
                              ),

                              Expanded(
                                child: isMobile
                                    ? ListView.builder(
                                        padding: const EdgeInsets.only(bottom: 24),
                                        itemCount: filteredStudents.length,
                                        itemBuilder: (context, i) {
                                          final s = filteredStudents[i];
                                          final sId = s['id']?.toString() ?? '';
                                          final fee = _getStudentFee(
                                            studentId: sId,
                                            studentSnap: s,
                                            monthLogs: monthLogs,
                                            config: displayConfig,
                                            workingDays: workingDays,
                                            holidays: holidays,
                                          );
                                          final payment = payments[sId];
                                          return _buildMobileStudentSummaryCard(
                                            context,
                                            s,
                                            fee,
                                            payment,
                                            displayConfig,
                                            monthLogs,
                                            holidays,
                                            currentYear,
                                            currentMonth,
                                            isDark,
                                          );
                                        },
                                      )
                                    : Padding(
                                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                                        child: filteredStudents.isEmpty
                                            ? _buildEmptyState(context, isDark)
                                            : _buildFrozenColumnTable(
                                                context,
                                                filteredStudents,
                                                payments,
                                                displayConfig,
                                                monthLogs,
                                                workingDays,
                                                holidays,
                                                currentYear,
                                                currentMonth,
                                                showDetail,
                                                isDark,
                                              ),
                                      ),
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    final c = context.comfort;
    final cardBg = c.surface;
    final borderColor = c.border;
    final textMuted = c.textMuted;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(vertical: 48),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 36, color: c.textMuted),
          const SizedBox(height: 10),
          Text('No students match your search', style: TextStyle(color: textMuted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildFrozenColumnTable(
    BuildContext context,
    List<dynamic> filteredStudents,
    Map<String, Map<String, dynamic>> payments,
    MadrassaConfig config,
    List<dynamic> logs,
    int workingDays,
    List<DateTime> holidays,
    int year,
    int month,
    bool showDetail,
    bool isDark,
  ) {
    final c = context.comfort;
    final cardBg = c.surface;
    final borderColor = c.border;

    final rows = List.generate(filteredStudents.length, (i) {
      final s = filteredStudents[i];
      final sId = s['id']?.toString() ?? '';
      final fee = _getStudentFee(
        studentId: sId,
        studentSnap: s,
        monthLogs: logs,
        config: config,
        workingDays: workingDays,
        holidays: holidays,
      );
      final data = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
      final payment = payments[sId];
      return (s: s, sId: sId, fee: fee, data: data, payment: payment);
    });

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double frozenWidth = 32.0 + 170.0 + 95.0; // 297.0
          final double availableScrollableWidth = (constraints.maxWidth - frozenWidth).clamp(0.0, 9999.0);
          final widths = _calculateColWidths(availableScrollableWidth, showDetail, config.enableFees);

          return SingleChildScrollView(
            controller: _verticalController,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Frozen panel ────────────────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    border: Border(right: BorderSide(color: borderColor, width: 1)),
                  ),
                  child: Column(
                    children: [
                      _frozenHeaderRow(context, isDark),
                      ...List.generate(rows.length, (i) => _frozenDataRow(context, i, rows[i].data, isDark)),
                    ],
                  ),
                ),
                // ── Scrollable panel ────────────────────────────────────────
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      children: [
                        _scrollableHeaderRow(context, showDetail, config.enableFees, widths, isDark),
                        ...List.generate(
                          rows.length,
                          (i) => _scrollableDataRow(
                            context,
                            i,
                            rows[i].s,
                            rows[i].fee,
                            rows[i].data,
                            rows[i].payment,
                            config,
                            logs,
                            holidays,
                            year,
                            month,
                            showDetail,
                            config.enableFees,
                            widths,
                            isDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Map<String, double> _calculateColWidths(double availableScrollableWidth, bool showDetail, bool isFeeEnabled) {
    final double baseDays = 95;
    final double baseP = 50;
    final double baseL = 50;
    final double baseA = 50;
    final double baseAtt = (showDetail && isFeeEnabled) ? 95 : 0;
    final double baseUni = 50;
    final double baseUniRs = (showDetail && isFeeEnabled) ? 95 : 0;
    final double baseMsg = 65;
    final double basePtm = 55;
    final double baseSavings = isFeeEnabled ? 95 : 0;
    final double baseActions = isFeeEnabled ? 180 : 70;

    final double totalBase = baseDays + baseP + baseL + baseA + baseAtt + baseUni + baseUniRs + baseMsg + basePtm + baseSavings + baseActions;

    double scale = 1.0;
    if (availableScrollableWidth > totalBase) {
      scale = availableScrollableWidth / totalBase;
    }

    return {
      'days': baseDays * scale,
      'p': baseP * scale,
      'l': baseL * scale,
      'a': baseA * scale,
      'att': baseAtt * scale,
      'uni': baseUni * scale,
      'uniRs': baseUniRs * scale,
      'msg': baseMsg * scale,
      'ptm': basePtm * scale,
      'savings': baseSavings * scale,
      'actions': baseActions * scale,
    };
  }

  Widget _frozenHeaderRow(BuildContext context, bool isDark) {
    final c = context.comfort;
    final headingBg = c.surfaceSunken;
    final borderColor = c.border;

    return Container(
      height: _kHeaderHeight,
      decoration: BoxDecoration(
        color: headingBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1.5)),
      ),
      child: Row(
        children: [
          _colCell(Text('#', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary))), 32.0, center: true),
          _colCell(Text(context.l.studentName, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary))), 170.0),
          _colCell(Text(context.l.rollNumber, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary))), 95.0),
        ],
      ),
    );
  }

  Widget _frozenDataRow(BuildContext context, int index, Map<String, dynamic> data, bool isDark) {
    final c = context.comfort;
    final borderColor = c.border;
    final textPrimary = c.textPrimary;
    final textMuted = c.textMuted;

    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _colCell(Text('${index + 1}', style: TextStyle(color: textMuted, fontSize: 12)), 32.0, center: true),
          _colCell(
            Text(
              data['name'] ?? '',
              style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary, fontSize: 13, fontFamilyFallback: const ['Noori']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            170.0,
          ),
          _colCell(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Text(
                '${data['rollNumber'] ?? '?'}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: c.brand,
                ),
              ),
            ),
            95.0,
          ),
        ],
      ),
    );
  }

  Widget _scrollableHeaderRow(
    BuildContext context,
    bool showDetail,
    bool isFeeEnabled,
    Map<String, double> widths,
    bool isDark,
  ) {
    final c = context.comfort;
    final headingBg = c.surfaceSunken;
    final borderColor = c.border;

    return Container(
      height: _kHeaderHeight,
      decoration: BoxDecoration(
        color: headingBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1.5)),
      ),
      child: Row(
        children: [
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'ماہ کے کل تعلیمی دن' : 'Academic / Working Days',
              child: Text(
                context.l.workingDays,
                style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            widths['days']!,
            center: true,
          ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'حاضر دن' : 'Present Days',
              child: Text('P', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w700, color: c.success, fontSize: 13))),
            ),
            widths['p']!,
            center: true,
          ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'رخصت کے دن' : 'Leave Days',
              child: Text('L', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w700, color: c.warning, fontSize: 13))),
            ),
            widths['l']!,
            center: true,
          ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'غیر حاضر دن' : 'Absent Days',
              child: Text('A', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w700, color: c.danger, fontSize: 13))),
            ),
            widths['a']!,
            center: true,
          ),
          if (showDetail && isFeeEnabled)
            _colCell(
              Tooltip(
                message: context.isUrdu ? 'حاضری پر رعایت' : 'Attendance Savings',
                child: Text(
                  context.l.attSavingsShort,
                  style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.textPrimary)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              widths['att']!,
              center: true,
            ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'یونیفارم کے دن' : 'Uniform Days',
              child: Text('U', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w700, color: c.brand, fontSize: 13))),
            ),
            widths['uni']!,
            center: true,
          ),
          if (showDetail && isFeeEnabled)
            _colCell(
              Tooltip(
                message: context.isUrdu ? 'یونیفارم پر رعایت' : 'Uniform Savings',
                child: Text(
                  context.l.uniSavingsShort,
                  style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.textPrimary)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              widths['uniRs']!,
              center: true,
            ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'پیغامات / روزانہ رپورٹ' : 'Parent Messages / Hadith Followup',
              child: Text(
                context.l.msgShort,
                style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w700, color: c.warning, fontSize: 13)),
              ),
            ),
            widths['msg']!,
            center: true,
          ),
          _colCell(
            Tooltip(
              message: context.isUrdu ? 'پی ٹی ایم میٹنگ (شریک / غیر حاضر)' : 'Parent-Teacher Meeting (Joined / Missed)',
              child: Text('PTM', style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary))),
            ),
            widths['ptm']!,
            center: true,
          ),
          if (isFeeEnabled)
            _colCell(
              Tooltip(
                message: context.isUrdu ? 'کل رعایت (حاضری + یونیفارم + میسج + پی ٹی ایم)' : 'Total Monthly Fee Savings / Discount',
                child: Text(
                  context.l.totalSavings,
                  style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: c.success, fontSize: 12.5)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              widths['savings']!,
              center: true,
            ),
          _colCell(
            Text(
              context.l.actions,
              style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: c.brand, fontSize: 13)),
            ),
            widths['actions']!,
            center: true,
          ),
        ],
      ),
    );
  }

  Widget _scrollableDataRow(
    BuildContext context,
    int index,
    dynamic s,
    Map<String, dynamic> fee,
    Map<String, dynamic> data,
    Map<String, dynamic>? payment,
    MadrassaConfig config,
    List<dynamic> logs,
    List<DateTime> holidays,
    int year,
    int month,
    bool showDetail,
    bool isFeeEnabled,
    Map<String, double> widths,
    bool isDark,
  ) {
    final c = context.comfort;
    final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
    final due = ((fee['amountDue'] as num?) ?? 0.0).toDouble();
    final borderColor = c.border;
    final textPrimary = c.textPrimary;

    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _colCell(Text('${fee['activeWorkingDays']}', style: TextStyle(fontSize: 12, color: textPrimary)), widths['days']!, center: true),
          _colCell(Text('${fee['present']}', style: TextStyle(color: context.adapt(SoftPalette.green550), fontWeight: FontWeight.bold, fontSize: 12)), widths['p']!, center: true),
          _colCell(Text('${fee['leave']}', style: TextStyle(color: context.adapt(SoftPalette.orange400), fontWeight: FontWeight.bold, fontSize: 12)), widths['l']!, center: true),
          _colCell(Text('${fee['absent']}', style: TextStyle(color: context.adapt(SoftPalette.red500), fontWeight: FontWeight.bold, fontSize: 12)), widths['a']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(((fee['attSavings'] as num?) ?? 0).toStringAsFixed(0), style: TextStyle(color: context.adapt(SoftPalette.green550), fontWeight: FontWeight.bold, fontSize: 12)), widths['att']!, center: true),
          _colCell(Text('${fee['uniform']}', style: TextStyle(color: isDark ? SoftPalette.teal300 : SoftPalette.teal550, fontWeight: FontWeight.bold, fontSize: 12)), widths['uni']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(((fee['uniSavings'] as num?) ?? 0).toStringAsFixed(0), style: TextStyle(color: context.adapt(SoftPalette.green550), fontWeight: FontWeight.bold, fontSize: 12)), widths['uniRs']!, center: true),
          _colCell(Text('${fee['message']}/${fee['activeWorkingDays']}', style: TextStyle(color: context.adapt(SoftPalette.orange400), fontWeight: FontWeight.bold, fontSize: 12)), widths['msg']!, center: true),
          _colCell(_tag(
            fee['ptm'] ? 'J' : 'M',
            isDark ? (fee['ptm'] ? SoftPalette.emerald700 : SoftPalette.red700) : (fee['ptm'] ? SoftPalette.green100m : SoftPalette.pink100m),
            isDark ? (fee['ptm'] ? SoftPalette.emerald200 : SoftPalette.red300) : (fee['ptm'] ? SoftPalette.green550 : SoftPalette.red500),
          ), widths['ptm']!, center: true),
          if (isFeeEnabled)
            _colCell(
              Text(((fee['totalSavings'] as num?) ?? 0).toStringAsFixed(0), style: TextStyle(color: context.adapt(SoftPalette.green550), fontWeight: FontWeight.bold, fontSize: 12)),
              widths['savings']!,
              center: true,
            ),
          _colCell(
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isFeeEnabled) ...[
                  _buildDuesCell(
                    context: context,
                    studentId: sId,
                    studentName: data['name']?.toString() ?? 'Student',
                    rollNumber: data['rollNumber']?.toString() ?? '?',
                    studentData: data,
                    config: config,
                    due: due,
                    payment: payment,
                    year: year,
                    month: month,
                    isDark: isDark,
                  ),
                  const SizedBox(width: 8),
                ],
                StudentExportMenu(
                  onPdf: () {
                    AppToast.showSnackBar(context, SnackBar(content: Text('Preparing report for ${data['name'] ?? 'student'}...')));
                    MadrassaReportHelper.exportIndividualPdf(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
                  },
                  onExcel: () {
                    AppToast.showSnackBar(context, SnackBar(content: Text('Preparing Excel report for ${data['name'] ?? 'student'}...')));
                    MadrassaReportHelper.exportIndividualExcel(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
                  },
                  onWhatsApp: () {
                    _sendMonthlyWhatsApp(s, fee, logs);
                  },
                ),
              ],
            ),
            widths['actions']!,
            center: true,
          ),
        ],
      ),
    );
  }

  Widget _buildDuesCell({
    required BuildContext context,
    required String studentId,
    required String studentName,
    required String rollNumber,
    required Map<String, dynamic> studentData,
    required MadrassaConfig config,
    required double due,
    required Map<String, dynamic>? payment,
    required int year,
    required int month,
    required bool isDark,
  }) {
    final status = payment?['status']?.toString().toLowerCase();
    final amountPaid = (payment?['amountPaid'] as num?)?.toDouble() ?? 0.0;
    final discount = (payment?['discount'] as num?)?.toDouble() ?? 0.0;
    final balanceDue = (payment?['balanceDue'] as num?)?.toDouble() ??
        ((status == 'paid' || due <= 0) ? 0.0 : (due - amountPaid - discount).clamp(0.0, double.infinity));
    final isPaid = status == 'paid' || (payment != null && balanceDue <= 0.0);
    final isPartial = status == 'partial' || (payment != null && !isPaid && (amountPaid > 0.0 || discount > 0.0));
    final canManage = _canManageDues;

    final Color bg;
    final Color fg;
    final String text;
    final IconData? icon;

    if (isPaid) {
      bg = isDark ? SoftPalette.emerald700 : SoftPalette.green100m;
      fg = isDark ? SoftPalette.emerald200 : SoftPalette.green550;
      text = 'PAID (Rs. ${amountPaid > 0 ? amountPaid.toInt() : due.toInt()})';
      icon = Icons.check_circle_rounded;
    } else if (isPartial) {
      bg = isDark ? SoftPalette.orange800.withValues(alpha: 0.3) : SoftPalette.yellow150;
      fg = isDark ? SoftPalette.amber200 : SoftPalette.orange400;
      text = 'PARTIAL (Rem: Rs. ${balanceDue.toInt()})';
      icon = Icons.pie_chart_outline_rounded;
    } else if (due <= 0) {
      bg = isDark ? SoftPalette.emerald700 : SoftPalette.green100m;
      fg = isDark ? SoftPalette.emerald200 : SoftPalette.green550;
      text = '0 (No Due)';
      icon = null;
    } else {
      bg = isDark ? SoftPalette.red700 : SoftPalette.pink100m;
      fg = isDark ? SoftPalette.red300 : SoftPalette.red500;
      text = 'Rs. ${balanceDue.toInt()}';
      icon = canManage ? Icons.edit_note_rounded : null;
    }

    return InkWell(
      onTap: () {
        _showFeePaymentDialog(
          context,
          studentId: studentId,
          studentName: studentName,
          rollNumber: rollNumber,
          studentData: studentData,
          config: config,
          amountDue: due,
          currentPayment: payment,
          year: year,
          month: month,
          canEdit: canManage,
        );
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: fg.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFeePaymentDialog(
    BuildContext context, {
    required String studentId,
    required String studentName,
    required String rollNumber,
    required Map<String, dynamic> studentData,
    required MadrassaConfig config,
    required double amountDue,
    required Map<String, dynamic>? currentPayment,
    required int year,
    required int month,
    required bool canEdit,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);

    // 1. Calculate historical months strictly from student admission date
    final now = DateTime.now();
    final joinDate = MadrassaFeeLogic.parseStudentJoinDate(studentData);
    final earliestAllowed = DateTime(now.year - 1, now.month, 1);
    final startMonthDate = joinDate != null
        ? DateTime(joinDate.year, joinDate.month, 1)
        : earliestAllowed;
    final endMonthDate = DateTime(now.year, now.month, 1);

    final holidaysList = MadrassaLocalStorage.getHolidaysCached(_effectiveBranch).map((h) {
      final d = DateTime.tryParse(h['date']?.toString() ?? '');
      return d ?? DateTime.now();
    }).toList();

    final List<Map<String, dynamic>> monthItems = [];
    DateTime iter = DateTime(endMonthDate.year, endMonthDate.month, 1);

    while (!iter.isBefore(startMonthDate)) {
      final y = iter.year;
      final m = iter.month;

      final mConfig = config.copyWith(year: y, month: m);
      final mWorkingDays = MadrassaFeeLogic.getWorkingDaysCount(y, m, holidaysList);
      final mLogs = MadrassaLocalStorage.getLogsForMonthCached(_effectiveBranch, y, m);

      final mFee = MadrassaFeeLogic.calculateStudentFee(
        studentId: studentId,
        studentData: studentData,
        logs: mLogs,
        config: mConfig,
        totalWorkingDays: mWorkingDays,
        holidays: holidaysList,
      );

      final mPayment = MadrassaLocalStorage.getFeePaymentCached(_effectiveBranch, y, m, studentId);
      final activeDays = (mFee['activeWorkingDays'] as num?)?.toInt() ?? 0;

      // Only show months where student had active working days or has an existing payment record
      if (activeDays > 0 || mPayment != null) {
        final mDue = ((mFee['amountDue'] as num?) ?? 0.0).toDouble();
        final mStatus = mPayment?['status']?.toString().toLowerCase();
        final mPaid = (mPayment?['amountPaid'] as num?)?.toDouble() ?? 0.0;
        final mDiscount = (mPayment?['discount'] as num?)?.toDouble() ?? 0.0;
        final mRemains = (mPayment?['balanceDue'] as num?)?.toDouble() ??
            ((mStatus == 'paid' || mDue <= 0) ? 0.0 : (mDue - mPaid - mDiscount).clamp(0.0, double.infinity));
        final isItemPaid = mStatus == 'paid' || (mPayment != null && mRemains <= 0.0) || (mPayment == null && mDue <= 0.0);
        final isItemPartial = !isItemPaid && (mPaid > 0.0 || mDiscount > 0.0 || mStatus == 'partial');
        final resolvedStatus = isItemPaid ? 'paid' : (isItemPartial ? 'partial' : 'unpaid');
        final mNote = mPayment?['note']?.toString() ?? '';

        monthItems.add({
          'year': y,
          'month': m,
          'label': DateFormat('MMMM yyyy').format(DateTime(y, m)),
          'amountDue': mDue,
          'amountPaid': mPaid,
          'discount': mDiscount,
          'balanceDue': mRemains,
          'status': resolvedStatus,
          'isPaid': isItemPaid,
          'isPartial': isItemPartial,
          'present': mFee['present'] ?? 0,
          'leave': mFee['leave'] ?? 0,
          'absent': mFee['absent'] ?? 0,
          'activeWorkingDays': activeDays,
          'note': mNote,
          'paymentRecord': mPayment,
          'isSelected': !isItemPaid && mRemains > 0,
        });
      }

      if (iter.month == 1) {
        iter = DateTime(iter.year - 1, 12, 1);
      } else {
        iter = DateTime(iter.year, iter.month - 1, 1);
      }
    }

    bool isSaving = false;
    final paidDeductCtrl = TextEditingController();
    final discountDeductCtrl = TextEditingController(text: '0');
    final noteDeductCtrl = TextEditingController();
    String paymentMethodDeduct = 'Cash';
    bool showDeductPanel = false;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final unpaidItems = monthItems.where((item) => item['isPaid'] != true && (item['balanceDue'] as double) > 0).toList();
            final totalUnpaidDues = unpaidItems.fold<double>(0.0, (sum, item) => sum + (item['balanceDue'] as double));
            final totalPaidSoFar = monthItems.fold<double>(0.0, (sum, item) => sum + (item['amountPaid'] as double));
            final totalDiscountSoFar = monthItems.fold<double>(0.0, (sum, item) => sum + (item['discount'] as double));

            final selectedItems = monthItems.where((item) => item['isSelected'] == true && item['isPaid'] != true && (item['balanceDue'] as double) > 0).toList();
            final totalSelectedDues = selectedItems.fold<double>(0.0, (sum, item) => sum + (item['balanceDue'] as double));
            final allUnpaidSelected = unpaidItems.isNotEmpty && unpaidItems.every((item) => item['isSelected'] == true);

            final markUser = (widget.username != null && widget.username!.isNotEmpty)
                ? widget.username!
                : ((widget.role ?? '').toLowerCase().contains('chairman') ? 'Chairman' : 'HQ Manager');
            final markRole = (widget.role != null && widget.role!.isNotEmpty)
                ? widget.role!
                : ((widget.role ?? '').toLowerCase().contains('chairman') ? 'Chairman' : 'HQ Manager');

            // Deduct custom amount and concessions from total or selected dues
            Future<void> performCustomDeduction({
              required double amountPaidInput,
              required double discountInput,
              required List<Map<String, dynamic>> targetMonths,
              required String method,
              String? customNote,
            }) async {
              if (amountPaidInput <= 0 && discountInput <= 0) return;
              setDialogState(() => isSaving = true);
              try {
                double remainingPaidToAlloc = amountPaidInput;
                double remainingDiscToAlloc = discountInput;

                // Sort chronological (oldest unpaid month first) so past arrears get cleared first
                final sortedMonths = [...targetMonths]..sort((a, b) {
                  final cmp = (a['year'] as int).compareTo(b['year'] as int);
                  if (cmp != 0) return cmp;
                  return (a['month'] as int).compareTo(b['month'] as int);
                });

                for (final item in sortedMonths) {
                  if (remainingPaidToAlloc <= 0 && remainingDiscToAlloc <= 0) break;

                  final y = item['year'] as int;
                  final m = item['month'] as int;
                  final mDue = item['amountDue'] as double;
                  final mPriorPaid = item['amountPaid'] as double;
                  final mPriorDisc = item['discount'] as double;
                  final mRemains = (item['balanceDue'] as double);

                  if (mRemains <= 0) continue;

                  // Allocate discount first
                  final allocDisc = math.min(mRemains, remainingDiscToAlloc);
                  remainingDiscToAlloc -= allocDisc;
                  final afterDiscRemains = mRemains - allocDisc;

                  // Allocate paid amount
                  final allocPaid = math.min(afterDiscRemains, remainingPaidToAlloc);
                  remainingPaidToAlloc -= allocPaid;

                  final newPaid = mPriorPaid + allocPaid;
                  final newDisc = mPriorDisc + allocDisc;
                  final newBalance = (mDue - newPaid - newDisc).clamp(0.0, double.infinity);
                  final newStatus = newBalance <= 0 ? 'paid' : 'partial';

                  await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                    branchId: _effectiveBranch,
                    studentId: studentId,
                    studentName: studentName,
                    rollNumber: rollNumber,
                    year: y,
                    month: m,
                    amountDue: mDue,
                    amountPaid: newPaid,
                    discount: newDisc,
                    balanceDue: newBalance,
                    paymentMethod: method,
                    status: newStatus,
                    markedBy: markUser,
                    markedByRole: markRole,
                    note: customNote ?? (newBalance <= 0 ? 'Dues cleared' : 'Partial payment recorded by $markRole'),
                  );

                  item['amountPaid'] = newPaid;
                  item['discount'] = newDisc;
                  item['balanceDue'] = newBalance;
                  item['status'] = newStatus;
                  item['isPaid'] = newBalance <= 0;
                  item['isPartial'] = newBalance > 0 && (newPaid > 0 || newDisc > 0);
                  item['isSelected'] = newBalance > 0;
                }

                SyncService().triggerUpload();

                if (context.mounted) {
                  final totalRemainsAfter = monthItems
                      .where((i) => i['isPaid'] != true)
                      .fold<double>(0.0, (s, i) => s + (i['balanceDue'] as double));
                  AppToast.showSnackBar(
                    context,
                    SnackBar(
                      content: Text(
                        'Deducted Rs. ${amountPaidInput.toInt()} from dues. Remaining balance: Rs. ${totalRemainsAfter.toInt()}.',
                      ),
                      backgroundColor: SoftPalette.teal550,
                    ),
                  );
                }

                setDialogState(() {
                  isSaving = false;
                  showDeductPanel = false;
                  paidDeductCtrl.clear();
                  discountDeductCtrl.text = '0';
                });
              } catch (e) {
                setDialogState(() => isSaving = false);
                if (context.mounted) {
                  AppToast.showSnackBar(context, SnackBar(content: Text('Error saving deduction: $e'), backgroundColor: SoftPalette.red400));
                }
              }
            }

            // Quick pay full due for selected/all months
            Future<void> performPayment({
              required List<Map<String, dynamic>> itemsToPay,
              String? customNote,
            }) async {
              if (itemsToPay.isEmpty) return;
              setDialogState(() => isSaving = true);
              try {
                for (final item in itemsToPay) {
                  final y = item['year'] as int;
                  final m = item['month'] as int;
                  final due = item['amountDue'] as double;
                  final currentPaid = item['amountPaid'] as double;
                  final currentDisc = item['discount'] as double;
                  final neededToClear = (due - currentPaid - currentDisc).clamp(0.0, double.infinity);
                  final finalPaid = currentPaid + neededToClear;

                  await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                    branchId: _effectiveBranch,
                    studentId: studentId,
                    studentName: studentName,
                    rollNumber: rollNumber,
                    year: y,
                    month: m,
                    amountDue: due,
                    amountPaid: finalPaid,
                    discount: currentDisc,
                    balanceDue: 0.0,
                    status: 'paid',
                    markedBy: markUser,
                    markedByRole: markRole,
                    note: customNote ?? 'Fee Payment via Madrassa Portal',
                  );

                  item['amountPaid'] = finalPaid;
                  item['balanceDue'] = 0.0;
                  item['status'] = 'paid';
                  item['isPaid'] = true;
                  item['isPartial'] = false;
                  item['isSelected'] = false;
                }

                SyncService().triggerUpload();

                if (dialogCtx.mounted) {
                  Navigator.pop(dialogCtx);
                }
                if (context.mounted) {
                  AppToast.showSnackBar(
                    context,
                    SnackBar(
                      content: Text('Recorded full payment for ${itemsToPay.length} month(s).'),
                      backgroundColor: SoftPalette.teal550,
                    ),
                  );
                }
              } catch (e) {
                setDialogState(() => isSaving = false);
                if (context.mounted) {
                  AppToast.showSnackBar(context, SnackBar(content: Text('Error saving payments: $e'), backgroundColor: SoftPalette.red400));
                }
              }
            }

            // Single month edit dialog for granular deduction
            void openSingleMonthDeductionDialog(Map<String, dynamic> item) {
              final mDue = (item['amountDue'] as double);
              final mPriorDisc = (item['discount'] as double);
              final mRemains = (item['balanceDue'] as double);

              final amtCtrl = TextEditingController(text: mRemains > 0 ? mRemains.toInt().toString() : '0');
              final discCtrl = TextEditingController(text: mPriorDisc > 0 ? mPriorDisc.toInt().toString() : '0');
              final noteCtrl = TextEditingController(text: item['note'] ?? '');
              String mMethod = 'Cash';

              showDialog(
                context: context,
                builder: (sCtx) => StatefulBuilder(
                  builder: (sCtx, setSState) {
                    final pInput = double.tryParse(amtCtrl.text.trim()) ?? 0.0;
                    final dInput = double.tryParse(discCtrl.text.trim()) ?? 0.0;
                    final computedRemains = (mDue - pInput - dInput).clamp(0.0, double.infinity);
                    final isDone = computedRemains <= 0.0;

                    return AlertDialog(
                      backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(
                        children: [
                          Icon(Icons.edit_note_rounded, color: sCtx.adapt(SoftPalette.teal550)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${item['label']} - Deduct / Pay',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDone
                                    ? SoftPalette.green550.withValues(alpha: 0.12)
                                    : SoftPalette.red500.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isDone ? SoftPalette.green550 : SoftPalette.red500),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Month Total Fee:', style: TextStyle(fontSize: 12)),
                                      Text('Rs. ${mDue.toInt()}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Amount Paid (Deducted):', style: TextStyle(fontSize: 12, color: SoftPalette.green550)),
                                      Text('- Rs. ${pInput.toInt()}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: SoftPalette.green550)),
                                    ],
                                  ),
                                  if (dInput > 0) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('Concession / Discount:', style: TextStyle(fontSize: 12, color: SoftPalette.orange400)),
                                        Text('- Rs. ${dInput.toInt()}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: SoftPalette.orange400)),
                                      ],
                                    ),
                                  ],
                                  const Divider(height: 12),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        isDone ? 'Status: Fully Cleared 🎉' : 'Remaining Due:',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDone ? SoftPalette.green550 : SoftPalette.red500),
                                      ),
                                      Text(
                                        'Rs. ${computedRemains.toInt()}',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDone ? SoftPalette.green550 : SoftPalette.red500),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: amtCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setSState(() {}),
                              decoration: const InputDecoration(labelText: 'Amount Paid (PKR)', prefixText: 'Rs. ', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: discCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setSState(() {}),
                              decoration: const InputDecoration(labelText: 'Concession / Discount (PKR)', prefixText: 'Rs. ', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 10),
                            DropdownButtonFormField<String>(
                              value: mMethod,
                              decoration: const InputDecoration(labelText: 'Payment Method', border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                                DropdownMenuItem(value: 'Bank Transfer', child: Text('Bank Transfer')),
                                DropdownMenuItem(value: 'JazzCash/EasyPaisa', child: Text('JazzCash / EasyPaisa')),
                                DropdownMenuItem(value: 'Online', child: Text('Online / Card')),
                              ],
                              onChanged: (v) {
                                if (v != null) setSState(() => mMethod = v);
                              },
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: noteCtrl,
                              decoration: const InputDecoration(labelText: 'Notes / Remarks', border: OutlineInputBorder()),
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(sCtx),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: SoftPalette.teal550,
                            foregroundColor: SoftPalette.gray50,
                          ),
                          onPressed: () async {
                            final y = item['year'] as int;
                            final m = item['month'] as int;
                            final statusStr = isDone ? 'paid' : (pInput > 0 || dInput > 0 ? 'partial' : 'unpaid');

                            await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                              branchId: _effectiveBranch,
                              studentId: studentId,
                              studentName: studentName,
                              rollNumber: rollNumber,
                              year: y,
                              month: m,
                              amountDue: mDue,
                              amountPaid: pInput,
                              discount: dInput,
                              balanceDue: computedRemains,
                              paymentMethod: mMethod,
                              status: statusStr,
                              markedBy: markUser,
                              markedByRole: markRole,
                              note: noteCtrl.text.trim(),
                            );

                            SyncService().triggerUpload();

                            setDialogState(() {
                              item['amountPaid'] = pInput;
                              item['discount'] = dInput;
                              item['balanceDue'] = computedRemains;
                              item['status'] = statusStr;
                              item['isPaid'] = isDone;
                              item['isPartial'] = !isDone && (pInput > 0 || dInput > 0);
                              item['isSelected'] = !isDone;
                              item['note'] = noteCtrl.text.trim();
                            });

                            if (sCtx.mounted) {
                              Navigator.pop(sCtx);
                            }
                          },
                          child: const Text('Save & Update Month'),
                        ),
                      ],
                    );
                  },
                ),
              );
            }

            return Dialog(
              backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.account_balance_wallet_rounded, color: context.adapt(SoftPalette.teal550), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  studentName,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Roll #$rollNumber • Monthly Fee & Dues Management',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: SoftPalette.blue500,
                              foregroundColor: SoftPalette.gray50,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.receipt_long_rounded, size: 15),
                            label: const Text('Ledger & Receipts', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => StudentFeeLedgerScreen(
                                    branchId: _effectiveBranch,
                                    studentId: studentId,
                                    studentName: studentName,
                                    rollNumber: rollNumber,
                                    monthlyFee: amountDue,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      // Dues Summary Bar
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: totalUnpaidDues > 0
                              ? (isDark ? SoftPalette.red800 : SoftPalette.red100t)
                              : (isDark ? SoftPalette.emerald700 : SoftPalette.emerald50),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: totalUnpaidDues > 0
                                ? context.adapt(SoftPalette.red500).withValues(alpha: 0.3)
                                : context.adapt(SoftPalette.emerald500).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Remaining Outstanding Dues',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Rs. ${totalUnpaidDues.toInt()}',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.bold,
                                    color: totalUnpaidDues > 0 ? context.adapt(SoftPalette.red500) : context.adapt(SoftPalette.emerald500),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                if (totalPaidSoFar > 0) ...[
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text('Paid: Rs. ${totalPaidSoFar.toInt()}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.green550))),
                                      if (totalDiscountSoFar > 0)
                                        Text('Disc: Rs. ${totalDiscountSoFar.toInt()}', style: TextStyle(fontSize: 10, color: context.adapt(SoftPalette.orange400))),
                                    ],
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                if (canEdit && totalUnpaidDues > 0)
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: showDeductPanel ? SoftPalette.gray400 : SoftPalette.teal550,
                                      foregroundColor: SoftPalette.gray50,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    icon: Icon(showDeductPanel ? Icons.expand_less : Icons.remove_circle_outline, size: 15),
                                    label: Text(
                                      showDeductPanel ? 'Hide Deduction' : 'Deduct from Total',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    onPressed: () {
                                      setDialogState(() {
                                        showDeductPanel = !showDeductPanel;
                                        if (showDeductPanel && paidDeductCtrl.text.isEmpty) {
                                          paidDeductCtrl.text = totalUnpaidDues.toInt().toString();
                                        }
                                      });
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Interactive Deduction Panel (when toggled by HQ Manager)
                      if (showDeductPanel && canEdit && totalUnpaidDues > 0) ...[
                        Builder(
                          builder: (_) {
                            final pVal = double.tryParse(paidDeductCtrl.text.trim()) ?? 0.0;
                            final dVal = double.tryParse(discountDeductCtrl.text.trim()) ?? 0.0;
                            final remVal = (totalUnpaidDues - pVal - dVal).clamp(0.0, double.infinity);
                            final willClear = remVal <= 0.0;

                            return Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: isDark ? SoftPalette.slate700.withValues(alpha: 0.5) : SoftPalette.slate100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.4)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.calculate_rounded, size: 16, color: context.adapt(SoftPalette.teal550)),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'Deduct Payment from Outstanding Dues',
                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: paidDeductCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setDialogState(() {}),
                                          decoration: const InputDecoration(
                                            labelText: 'Amount Paid (PKR)',
                                            prefixText: 'Rs. ',
                                            isDense: true,
                                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: discountDeductCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setDialogState(() {}),
                                          decoration: const InputDecoration(
                                            labelText: 'Concession / Discount (PKR)',
                                            prefixText: 'Rs. ',
                                            isDense: true,
                                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Live calculation banner: Total - Paid - Discount = Remains
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: willClear
                                          ? SoftPalette.green550.withValues(alpha: 0.12)
                                          : SoftPalette.red500.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Total: Rs. ${totalUnpaidDues.toInt()} - Paid: Rs. ${pVal.toInt()} ${dVal > 0 ? "- Disc: Rs. ${dVal.toInt()}" : ""}',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                                        ),
                                        Text(
                                          willClear ? 'What Remains: Rs. 0 (Fully Cleared 🎉)' : 'What Remains: Rs. ${remVal.toInt()}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: willClear ? SoftPalette.green550 : SoftPalette.red500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          value: paymentMethodDeduct,
                                          isDense: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Payment Method',
                                            isDense: true,
                                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                            border: OutlineInputBorder(),
                                          ),
                                          items: const [
                                            DropdownMenuItem(value: 'Cash', child: Text('Cash', style: TextStyle(fontSize: 12))),
                                            DropdownMenuItem(value: 'Bank Transfer', child: Text('Bank Transfer', style: TextStyle(fontSize: 12))),
                                            DropdownMenuItem(value: 'JazzCash/EasyPaisa', child: Text('JazzCash / EasyPaisa', style: TextStyle(fontSize: 12))),
                                            DropdownMenuItem(value: 'Online', child: Text('Online / Card', style: TextStyle(fontSize: 12))),
                                          ],
                                          onChanged: (v) {
                                            if (v != null) setDialogState(() => paymentMethodDeduct = v);
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: noteDeductCtrl,
                                          decoration: const InputDecoration(
                                            labelText: 'Remarks / Receipt #',
                                            isDense: true,
                                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: SoftPalette.teal550,
                                          foregroundColor: SoftPalette.gray50,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                        icon: isSaving
                                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                                            : const Icon(Icons.check_circle_outline, size: 16),
                                        label: const Text('Confirm & Deduct', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        onPressed: isSaving
                                            ? null
                                            : () => performCustomDeduction(
                                                  amountPaidInput: pVal,
                                                  discountInput: dVal,
                                                  targetMonths: unpaidItems,
                                                  method: paymentMethodDeduct,
                                                  customNote: noteDeductCtrl.text.trim(),
                                                ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],

                      // Select All Header
                      if (canEdit && unpaidItems.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Monthly Dues History (${monthItems.length} months)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate700,
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  setDialogState(() {
                                    final newVal = !allUnpaidSelected;
                                    for (final item in monthItems) {
                                      if (item['isPaid'] != true && (item['balanceDue'] as double) > 0) {
                                        item['isSelected'] = newVal;
                                      }
                                    }
                                  });
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    children: [
                                      Checkbox(
                                        value: allUnpaidSelected,
                                        activeColor: context.adapt(SoftPalette.teal550),
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                        onChanged: (val) {
                                          setDialogState(() {
                                            for (final item in monthItems) {
                                              if (item['isPaid'] != true && (item['balanceDue'] as double) > 0) {
                                                item['isSelected'] = val ?? false;
                                              }
                                            }
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Select All Unpaid',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Scrollable List of Months
                      Expanded(
                        child: monthItems.isEmpty
                            ? Center(
                                child: Text(
                                  'No monthly fee records found.',
                                  style: TextStyle(color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
                                ),
                              )
                            : ListView.separated(
                                itemCount: monthItems.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 8),
                                itemBuilder: (ctx, idx) {
                                  final item = monthItems[idx];
                                  final isItemPaid = item['isPaid'] == true;
                                  final isItemPartial = item['isPartial'] == true;
                                  final dueVal = (item['amountDue'] as double).toInt();
                                  final paidVal = (item['amountPaid'] as double).toInt();
                                  final discVal = (item['discount'] as double).toInt();
                                  final remainsVal = (item['balanceDue'] as double).toInt();
                                  final isSelected = item['isSelected'] == true;

                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isItemPaid
                                          ? (isDark ? SoftPalette.slate900 : SoftPalette.gray50)
                                          : (isSelected
                                              ? (isDark ? SoftPalette.blue700.withValues(alpha: 0.3) : SoftPalette.slate100)
                                              : (isDark ? SoftPalette.slate800 : SoftPalette.gray50)),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected && !isItemPaid
                                            ? ctx.adapt(SoftPalette.blue500)
                                            : (isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                                        width: isSelected && !isItemPaid ? 1.5 : 1.0,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        if (canEdit && !isItemPaid && remainsVal > 0)
                                          Checkbox(
                                            value: isSelected,
                                            activeColor: ctx.adapt(SoftPalette.teal550),
                                            onChanged: (val) {
                                              setDialogState(() {
                                                item['isSelected'] = val ?? false;
                                              });
                                            },
                                          )
                                        else
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 10),
                                            child: Icon(
                                              isItemPaid
                                                  ? Icons.check_circle_rounded
                                                  : (isItemPartial ? Icons.pie_chart_outline_rounded : Icons.radio_button_unchecked),
                                              size: 18,
                                              color: isItemPaid
                                                  ? ctx.adapt(SoftPalette.emerald500)
                                                  : (isItemPartial ? ctx.adapt(SoftPalette.orange350) : ctx.adapt(SoftPalette.gray300)),
                                            ),
                                          ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Text(
                                                    item['label'] as String,
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 13,
                                                      color: isDark ? SoftPalette.gray50 : SoftPalette.slate800,
                                                    ),
                                                  ),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: isItemPaid
                                                          ? ctx.adapt(SoftPalette.emerald350).withValues(alpha: 0.15)
                                                          : (isItemPartial
                                                              ? ctx.adapt(SoftPalette.orange350).withValues(alpha: 0.15)
                                                              : ctx.adapt(SoftPalette.red400).withValues(alpha: 0.15)),
                                                      borderRadius: BorderRadius.circular(6),
                                                    ),
                                                    child: Text(
                                                      isItemPaid
                                                          ? 'PAID (Rs. $paidVal)'
                                                          : (isItemPartial
                                                              ? 'PARTIAL (Paid: Rs. $paidVal • Rem: Rs. $remainsVal)'
                                                              : 'UNPAID (Due: Rs. $remainsVal)'),
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.bold,
                                                        color: isItemPaid
                                                            ? ctx.adapt(SoftPalette.emerald500)
                                                            : (isItemPartial
                                                                ? ctx.adapt(SoftPalette.orange350)
                                                                : ctx.adapt(SoftPalette.red500)),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  Text(
                                                    'Total: Rs. $dueVal • P: ${item['present']} • L: ${item['leave']} • A: ${item['absent']}',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray500,
                                                    ),
                                                  ),
                                                  if (discVal > 0) ...[
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      '• Disc: Rs. $discVal',
                                                      style: TextStyle(fontSize: 11, color: ctx.adapt(SoftPalette.orange400)),
                                                    ),
                                                  ],
                                                  if ((item['note'] as String).isNotEmpty) ...[
                                                    const SizedBox(width: 6),
                                                    Flexible(
                                                      child: Text(
                                                        '• ${item['note']}',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontStyle: FontStyle.italic,
                                                          color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (canEdit) ...[
                                          IconButton(
                                            tooltip: 'Deduct / Pay this Month',
                                            icon: Icon(Icons.edit_note_rounded, size: 20, color: ctx.adapt(SoftPalette.teal550)),
                                            onPressed: () => openSingleMonthDeductionDialog(item),
                                          ),
                                          if (isItemPaid || isItemPartial)
                                            IconButton(
                                              tooltip: 'Reset to Unpaid',
                                              icon: Icon(Icons.undo_rounded, size: 16, color: ctx.adapt(SoftPalette.amber300)),
                                              onPressed: () async {
                                                await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                                                  branchId: _effectiveBranch,
                                                  studentId: studentId,
                                                  studentName: studentName,
                                                  rollNumber: rollNumber,
                                                  year: item['year'] as int,
                                                  month: item['month'] as int,
                                                  amountDue: item['amountDue'] as double,
                                                  amountPaid: 0,
                                                  discount: 0,
                                                  balanceDue: item['amountDue'] as double,
                                                  status: 'unpaid',
                                                  markedBy: widget.username ?? 'HQ',
                                                  markedByRole: widget.role ?? 'manager',
                                                  note: 'Marked unpaid by manager',
                                                );
                                                setDialogState(() {
                                                  item['status'] = 'unpaid';
                                                  item['isPaid'] = false;
                                                  item['isPartial'] = false;
                                                  item['amountPaid'] = 0.0;
                                                  item['discount'] = 0.0;
                                                  item['balanceDue'] = item['amountDue'] as double;
                                                  item['isSelected'] = true;
                                                });
                                              },
                                            ),
                                        ],
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),

                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      // Dialog Action Buttons: Pay Selected & Pay All
                      if (canEdit)
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogCtx),
                              child: const Text('Close'),
                            ),
                            const Spacer(),
                            if (selectedItems.isNotEmpty) ...[
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: SoftPalette.teal550,
                                  foregroundColor: SoftPalette.gray50,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSaving
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                                    : const Icon(Icons.check_box_rounded, size: 16),
                                label: Text(
                                  'Clear Selected (${selectedItems.length} • Rs. ${totalSelectedDues.toInt()})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                onPressed: isSaving ? null : () => performPayment(itemsToPay: selectedItems),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (unpaidItems.isNotEmpty && totalUnpaidDues > 0)
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: SoftPalette.emerald500,
                                  foregroundColor: SoftPalette.gray50,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSaving
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                                    : const Icon(Icons.done_all_rounded, size: 16),
                                label: Text(
                                  'Clear All Dues (Rs. ${totalUnpaidDues.toInt()})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                onPressed: isSaving ? null : () => performPayment(itemsToPay: unpaidItems),
                              ),
                          ],
                        )
                      else
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: const Text('Close'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMobileStudentSummaryCard(
    BuildContext context,
    dynamic s,
    Map<String, dynamic> fee,
    Map<String, dynamic>? payment,
    MadrassaConfig config,
    List<dynamic> logs,
    List<DateTime> holidays,
    int year,
    int month,
    bool isDark,
  ) {
    final c = context.comfort;
    final data = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
    final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
    final due = ((fee['amountDue'] as num?) ?? 0.0).toDouble();
    final savings = ((fee['totalSavings'] as num?) ?? 0).toStringAsFixed(0);
    final p = fee['present'];
    final l = fee['leave'];
    final a = fee['absent'];
    final cardBg = c.surface;
    final borderColor = c.border;
    final textPrimary = c.textPrimary;
    final textMuted = c.textMuted;

    final status = payment?['status']?.toString().toLowerCase();
    final amountPaid = (payment?['amountPaid'] as num?)?.toDouble() ?? 0.0;
    final discount = (payment?['discount'] as num?)?.toDouble() ?? 0.0;
    final balanceDue = (payment?['balanceDue'] as num?)?.toDouble() ??
        ((status == 'paid' || due <= 0) ? 0.0 : (due - amountPaid - discount).clamp(0.0, double.infinity));
    final isPaid = status == 'paid' || (payment != null && balanceDue <= 0.0);
    final isPartial = status == 'partial' || (payment != null && !isPaid && (amountPaid > 0.0 || discount > 0.0));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: MadrassaErp.cardRadius,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['name'] ?? '',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? SoftPalette.teal500.withValues(alpha: 0.2) : SoftPalette.teal50t,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Roll ${data['rollNumber'] ?? '?'}',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: isDark ? SoftPalette.teal300 : SoftPalette.teal550),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Active Days: ${fee['activeWorkingDays']}',
                            style: context.urduStyle(style: TextStyle(color: textMuted, fontSize: 12)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPaid) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.emerald350).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle_rounded, size: 11, color: context.adapt(SoftPalette.emerald500)),
                                const SizedBox(width: 3),
                                Text(
                                  'PAID',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.emerald500)),
                                ),
                              ],
                            ),
                          ),
                        ] else if (isPartial) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.orange350).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.pie_chart_outline_rounded, size: 11, color: context.adapt(SoftPalette.orange400)),
                                const SizedBox(width: 3),
                                Text(
                                  'PARTIAL (Rem: Rs. ${balanceDue.toInt()})',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange400)),
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
              StudentExportMenu(
                onPdf: () {
                  AppToast.showSnackBar(context, SnackBar(content: Text('Preparing report for ${data['name'] ?? 'student'}...')));
                  MadrassaReportHelper.exportIndividualPdf(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
                },
                onExcel: () {
                  AppToast.showSnackBar(context, SnackBar(content: Text('Preparing Excel report for ${data['name'] ?? 'student'}...')));
                  MadrassaReportHelper.exportIndividualExcel(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
                },
                onWhatsApp: () {
                  _sendMonthlyWhatsApp(s, fee, logs);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: borderColor),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _statPill(context.l.present[0], '$p', context.adapt(SoftPalette.green550)),
              _statPill(context.l.leave[0], '$l', context.adapt(SoftPalette.orange400)),
              _statPill(context.l.absent[0], '$a', context.adapt(SoftPalette.red500)),
              _statPill(context.l.ptm, fee['ptm'] ? 'J' : 'M', fee['ptm'] ? context.adapt(SoftPalette.green550) : context.adapt(SoftPalette.red500)),
            ],
          ),
          if (config.enableFees) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Savings', style: context.urduStyle(style: TextStyle(fontSize: 10, color: textMuted))),
                    const SizedBox(height: 2),
                    Text('Rs. $savings', style: TextStyle(fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.green550), fontSize: 14)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(context.l.amountDue, style: context.urduStyle(style: TextStyle(fontSize: 10, color: textMuted))),
                    const SizedBox(height: 4),
                    _buildDuesCell(
                      context: context,
                      studentId: sId,
                      studentName: data['name']?.toString() ?? 'Student',
                      rollNumber: data['rollNumber']?.toString() ?? '?',
                      studentData: data,
                      config: config,
                      due: due,
                      payment: payment,
                      year: year,
                      month: month,
                      isDark: isDark,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statPill(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: MadrassaErp.radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 11),
          ),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    MadrassaConfig displayConfig,
    List<dynamic> students,
    List<dynamic> logs,
    int year,
    int month,
    List<DateTime> holidays,
    int workingDays,
    bool showDetail,
    bool isDark,
  ) {
    final c = context.comfort;
    final monthName = DateFormat('MMMM yyyy').format(DateTime(year, month));
    final isMobile = GBreakpoint.isMobile(context);
    final cardBg = c.surface;
    final borderColor = c.border;
    final textPrimary = c.textPrimary;
    final textMuted = c.textMuted;

    final headerInfo = Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: c.brandSoft,
            borderRadius: MadrassaErp.radius,
          ),
          child: Icon(Icons.analytics_rounded, color: c.brand, size: 24),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l.monthlyReport,
              style: context.urduStyle(
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              monthName,
              style: TextStyle(fontSize: 12, color: textMuted),
            ),
          ],
        ),
      ],
    );

    final monthPicker = Container(
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: MadrassaErp.radius,
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.chevron_left, size: 20, color: c.textPrimary),
            tooltip: 'Previous Month',
            onPressed: () {
              setState(() {
                if (month == 1) {
                  _selectedYear = year - 1;
                  _selectedMonth = 12;
                } else {
                  _selectedYear = year;
                  _selectedMonth = month - 1;
                }
              });
            },
          ),
          Text(
            DateFormat('MMM yyyy').format(DateTime(year, month)),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textPrimary),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right, size: 20, color: c.textPrimary),
            tooltip: 'Next Month',
            onPressed: () {
              setState(() {
                if (month == 12) {
                  _selectedYear = year + 1;
                  _selectedMonth = 1;
                } else {
                  _selectedYear = year;
                  _selectedMonth = month + 1;
                }
              });
            },
          ),
        ],
      ),
    );

    final exportActions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip: 'Export Report',
          shape: RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
          color: c.surface,
          elevation: 4,
          onSelected: (val) {
            if (val == 'pdf') {
              AppToast.showSnackBar(context, 
                const SnackBar(content: Text('Preparing bulk PDF report...'), duration: Duration(seconds: 2)),
              );
              MadrassaReportHelper.exportMonthlyPdf(config: displayConfig, students: students, logs: logs, holidays: holidays);
            } else if (val == 'excel') {
              AppToast.showSnackBar(context, 
                const SnackBar(content: Text('Preparing bulk Excel report...'), duration: Duration(seconds: 2)),
              );
              MadrassaReportHelper.exportMonthlyExcel(config: displayConfig, students: students, logs: logs, holidays: holidays);
            }
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'pdf',
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: c.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(Icons.picture_as_pdf_rounded, color: c.danger, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    context.l.printPdf,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'excel',
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: c.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(Icons.table_chart_rounded, color: c.success, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    context.l.exportExcel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: c.brand,
              borderRadius: MadrassaErp.radius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined, color: c.onBrand, size: 18),
                const SizedBox(width: 6),
                Text(
                  context.isUrdu ? 'رپورٹ برآمد کریں' : 'Export',
                  style: TextStyle(
                    color: c.onBrand,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down_rounded, color: c.onBrand.withValues(alpha: 0.7), size: 16),
              ],
            ),
          ),
        ),
        if (!isMobile) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              showDetail ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              color: c.brand,
              size: 20,
            ),
            tooltip: showDetail ? 'Compact View' : 'Detailed View',
            onPressed: () {
              setState(() {
                _userShowDetailOverride = !showDetail;
              });
            },
          ),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1)),
      ),
      child: isMobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    headerInfo,
                    exportActions,
                  ],
                ),
                const SizedBox(height: 12),
                monthPicker,
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                headerInfo,
                Row(
                  children: [
                    monthPicker,
                    const SizedBox(width: 12),
                    exportActions,
                  ],
                ),
              ],
            ),
    );
  }

  Widget _colCell(Widget child, double width, {bool center = false}) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Align(
          alignment: center ? Alignment.center : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }

  Widget _tag(String text, Color bg, Color textC) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(color: textC, fontWeight: FontWeight.bold, fontSize: 11)),
    );
  }

  void _sendMonthlyWhatsApp(dynamic s, Map<String, dynamic> fee, List<dynamic> monthLogs) async {
    final studentData = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
    final phone = (studentData['guardianContact'] ?? studentData['phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9+]'), '');
    final sId = s is DocumentSnapshot ? s.id : s['id'].toString();

    if (phone.isEmpty) {
      if (mounted) {
        AppToast.showSnackBar(context, const SnackBar(content: Text('No guardian contact found for student')));
      }
      return;
    }

    final sortedLogs = List<dynamic>.from(monthLogs)
      ..sort((a, b) {
        final da = a is DocumentSnapshot ? a.id : (a['dateKey'] ?? a['id'] ?? '');
        final db = b is DocumentSnapshot ? b.id : (b['dateKey'] ?? b['id'] ?? '');
        return da.toString().compareTo(db.toString());
      });

    String sabakMsg = 'No updates recorded / کوئی سبق درج نہیں';
    String sabkiMsg = 'No updates recorded / کوئی سبکی درج نہیں';
    String manzilMsg = 'No updates recorded / کوئی منزل درج نہیں';
    int lastLines = -1;

    for (int i = sortedLogs.length - 1; i >= 0; i--) {
      final doc = sortedLogs[i];
      final data = doc is DocumentSnapshot ? (_asStringMap(doc.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(doc as Map);
      final sLog = _asStringMap(data[sId]);
      if (sLog != null) {
        if (sLog['sabakRatio'] != null && sabakMsg.contains('No updates')) {
          sabakMsg = 'Ratio: ${sLog['sabakRatio']}' + (sLog['sabakPara'] != null ? ' (Para: ${sLog['sabakPara']})' : '');
        }
        if (sLog['sabkiRatio'] != null && sabkiMsg.contains('No updates')) {
          sabkiMsg = 'Ratio: ${sLog['sabkiRatio']}' + (sLog['sabkiPara'] != null ? ' (Para: ${sLog['sabkiPara']})' : '');
        }
        if (sLog['manzilRatio'] != null && manzilMsg.contains('No updates')) {
          manzilMsg = 'Ratio: ${sLog['manzilRatio']}' + (sLog['manzilPara'] != null ? ' (Para: ${sLog['manzilPara']})' : '');
        }
        if (sLog['currentLines'] != null && lastLines == -1) {
          lastLines = (sLog['currentLines'] as num).toInt();
        }
      }
    }

    if (lastLines != -1) {
      sabakMsg += ' (Cumulative Line: $lastLines / مجموعی لائن: $lastLines)';
    }

    final due = (fee['amountDue'] as num?)?.toStringAsFixed(0) ?? '0';
    final savings = (fee['totalSavings'] as num?)?.toStringAsFixed(0) ?? '0';
    final p = fee['present'] ?? 0;
    final l = fee['leave'] ?? 0;
    final a = fee['absent'] ?? 0;
    final ptmAttended = fee['ptm'] == true;

    final currentYear = _selectedYear ?? DateTime.now().year;
    final currentMonth = _selectedMonth ?? DateTime.now().month;
    final monthName = DateFormat('MMMM yyyy').format(DateTime(currentYear, currentMonth));
    final studentName = studentData['name'] ?? '—';
    final rollNumber = studentData['rollNumber'] ?? '?';

    final payment = MadrassaLocalStorage.getFeePaymentCached(_effectiveBranch, currentYear, currentMonth, sId);
    final isPaid = payment != null && payment['status'] == 'paid';

    final bool isFeeEnabled = (fee['enableFees'] != false) && LocalStorageService.isMadrassaFeeEnabled(_effectiveBranch);

    final String feeSection = isFeeEnabled
        ? '\n*Financial Summary / مالیاتی رپورٹ:*\n'
            '• *Status/حیثیت:* ${isPaid ? "PAID / ادا شدہ" : "UNPAID / غیر ادا شدہ"}\n'
            '• *Amount Due/قابل ادا رقم:* Rs. $due\n'
            '• *Total Savings/کل بچت:* Rs. $savings\n'
        : '';

    final String message =
        '*Gulzar Madina Welfare Foundation (Madrassa)*\n'
        '*Monthly Progress Report | ماہانہ کارکردگی رپورٹ*\n'
        '--------------------------------------------\n'
        '*Month/مہینہ:* $monthName\n'
        '*Student/طالب علم:* $studentName (Roll: $rollNumber)\n'
        '*Attendance/حاضری:* Present: $p, Leave: $l, Absent: $a / حاضر: $p، رخصت: $l، غیر حاضر: $a\n'
        '*PTM Meeting/میٹنگ:* ${ptmAttended ? "Attended / شامل ہوئے" : "Missed / غیر حاضر"}\n'
        '\n'
        '*Monthly Progress / ماہانہ کارکردگی:*\n'
        '• *Sabak/سبق:* $sabakMsg\n'
        '• *Sabki/سبکی:* $sabkiMsg\n'
        '• *Manzil/منزل:* $manzilMsg\n'
        '$feeSection'
        '--------------------------------------------\n'
        'جزاک اللہ خیراً';

    final cleanPhone = phone.startsWith('+') ? phone : (phone.startsWith('0') ? '92${phone.substring(1)}' : '92$phone');
    final uri = Uri.parse('https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}');

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          AppToast.showSnackBar(context, const SnackBar(content: Text('Could not launch WhatsApp')));
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(content: Text('Error launching WhatsApp: $e')));
      }
    }
  }
}