import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/madrassa_config.dart';
import '../models/madrassa_fee_logic.dart';
import '../widgets/madrassa_common_widgets.dart';
import '../utils/madrassa_report_helper.dart';
import '../madrassa_strings.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/sync_service.dart';

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

  @override
  void initState() {
    super.initState();
    MadrassaLocalStorage.downloadStudents(widget.branchId);
    MadrassaLocalStorage.downloadHolidays(widget.branchId);
  }

  @override
  Widget build(BuildContext context) {
    final configAsyncValue = ref.watch(madrassaConfigProvider(widget.branchId));
    final holidaysAsyncValue = ref.watch(madrassaHolidaysProvider(widget.branchId));

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
        final isFeeEnabled = (config.enableFees != false) && LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

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
            MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, currentYear, currentMonth);
            MadrassaLocalStorage.downloadFeePaymentsForMonth(widget.branchId, currentYear, currentMonth);
          });
        }

        final studentsAsyncValue = ref.watch(madrassaStudentsProvider(widget.branchId));
        final logsAsyncValue = ref.watch(madrassaMonthlyLogsProvider((branchId: widget.branchId, year: currentYear, month: currentMonth)));
        final feePaymentsAsyncValue = ref.watch(madrassaFeePaymentsProvider((branchId: widget.branchId, year: currentYear, month: currentMonth)));

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

                return ValueListenableBuilder(
                  valueListenable: UserThemeService.listenable(widget.username),
                  builder: (context, _, __) {
                    final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
                    final scaffoldBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD);
                    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
                    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
                    final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF454749);
                    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);

                    return Scaffold(
                      backgroundColor: scaffoldBg,
                      body: LayoutBuilder(
                        builder: (context, constraints) {
                          final bool showDetail = _userShowDetailOverride ?? (constraints.maxWidth >= 1100);
                          final isMobile = MediaQuery.of(context).size.width < 600;
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
                                    color: isDark ? const Color(0xFF451A03).withValues(alpha: 0.5) : Colors.amber.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: isDark ? const Color(0xFF78350F) : Colors.amber.shade200),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.warning_amber_rounded, color: isDark ? const Color(0xFFFBBF24) : Colors.amber.shade900, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          context.isUrdu
                                              ? 'آرکائیو اور مکمل شدہ طلباء کو بلک ڈاؤن لوڈ سے خارج کر دیا گیا ہے۔ ان کی رپورٹس دستی طور پر ڈاؤن لوڈ کریں۔'
                                              : 'Archived and Completed students are excluded from bulk downloads and must be downloaded manually.',
                                          style: TextStyle(
                                            color: isDark ? const Color(0xFFFBBF24) : Colors.amber.shade900,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: context.isUrdu ? 'Noori' : null,
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
                                  style: TextStyle(color: textPrimary),
                                  decoration: InputDecoration(
                                    hintText: context.isUrdu ? 'طالب علم تلاش کریں (نام یا رول نمبر)...' : 'Search student by name or roll number...',
                                    hintStyle: TextStyle(fontFamily: context.isUrdu ? 'Noori' : null, color: textMuted),
                                    prefixIcon: Icon(Icons.search, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080)),
                                    filled: true,
                                    fillColor: cardBg,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: borderColor)),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(color: borderColor),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF008080), width: 2),
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
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(vertical: 48),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 36, color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400),
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
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);

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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4)),
        ],
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
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(2, 0)),
                    ],
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
    final double baseDays = 90;
    final double baseP = 60;
    final double baseL = 60;
    final double baseA = 60;
    final double baseAtt = (showDetail && isFeeEnabled) ? 75 : 0;
    final double baseUni = 65;
    final double baseUniRs = (showDetail && isFeeEnabled) ? 85 : 0;
    final double baseMsg = 65;
    final double basePtm = 55;
    final double baseSavings = isFeeEnabled ? 80 : 0;
    final double baseDue = isFeeEnabled ? 110 : 0;
    final double baseActions = 130;

    final double totalBase = baseDays + baseP + baseL + baseA + baseAtt + baseUni + baseUniRs + baseMsg + basePtm + baseSavings + baseDue + baseActions;

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
      'due': baseDue * scale,
      'actions': baseActions * scale,
    };
  }

  Widget _frozenHeaderRow(BuildContext context, bool isDark) {
    final headingBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Container(
      height: _kHeaderHeight,
      decoration: BoxDecoration(
        color: headingBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1.5)),
      ),
      child: Row(
        children: [
          _colCell(Text('#', style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), 32.0, center: true),
          _colCell(Text(context.l.studentName, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), 170.0),
          _colCell(Text(context.l.rollNumber, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), 95.0),
        ],
      ),
    );
  }

  Widget _frozenDataRow(BuildContext context, int index, Map<String, dynamic> data, bool isDark) {
    final isEven = index.isEven;
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final altBg = isDark ? const Color(0xFF182234) : const Color(0xFFFAFBFE);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey[600];

    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        color: isEven ? cardBg : altBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _colCell(Text('${index + 1}', style: TextStyle(color: textMuted, fontSize: 12)), 32.0, center: true),
          _colCell(
            Text(
              data['name'] ?? '',
              style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            170.0,
          ),
          _colCell(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0D9488).withValues(alpha: 0.2) : const Color(0xFFF0FDFC),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${data['rollNumber'] ?? '?'}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E),
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
    final headingBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Container(
      height: _kHeaderHeight,
      decoration: BoxDecoration(
        color: headingBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1.5)),
      ),
      child: Row(
        children: [
          _colCell(Text(context.l.activeWorkingDays, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), widths['days']!, center: true),
          _colCell(Text(context.l.present[0], style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2E7D32), fontSize: 13))), widths['p']!, center: true),
          _colCell(Text(context.l.leave[0], style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFED6C02), fontSize: 13))), widths['l']!, center: true),
          _colCell(Text(context.l.absent[0], style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFD32F2F), fontSize: 13))), widths['a']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(context.l.attendanceSavings, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), widths['att']!, center: true),
          _colCell(Text(context.l.uniform[0], style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080), fontSize: 13))), widths['uni']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(context.l.uniformSavings, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), widths['uniRs']!, center: true),
          _colCell(Text(context.l.message[0], style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFED6C02), fontSize: 13))), widths['msg']!, center: true),
          _colCell(Text(context.l.ptm, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))), widths['ptm']!, center: true),
          if (isFeeEnabled) ...[
            _colCell(Text(context.l.savings, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2E7D32), fontSize: 13))), widths['savings']!, center: true),
            _colCell(Text(context.l.due, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFD32F2F), fontSize: 13))), widths['due']!, center: true),
          ],
          _colCell(Text(context.l.legendPresent, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080), fontSize: 13))), widths['actions']!, center: true),
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
    final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
    final isEven = index.isEven;
    final due = ((fee['amountDue'] as num?) ?? 0.0).toDouble();
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final altBg = isDark ? const Color(0xFF182234) : const Color(0xFFFAFBFE);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);

    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        color: isEven ? cardBg : altBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _colCell(Text('${fee['activeWorkingDays']}', style: TextStyle(fontSize: 12, color: textPrimary)), widths['days']!, center: true),
          _colCell(Text('${fee['present']}', style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold, fontSize: 12)), widths['p']!, center: true),
          _colCell(Text('${fee['leave']}', style: const TextStyle(color: Color(0xFFED6C02), fontWeight: FontWeight.bold, fontSize: 12)), widths['l']!, center: true),
          _colCell(Text('${fee['absent']}', style: const TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.bold, fontSize: 12)), widths['a']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(((fee['attSavings'] as num?) ?? 0).toStringAsFixed(0), style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold, fontSize: 12)), widths['att']!, center: true),
          _colCell(Text('${fee['uniform']}', style: TextStyle(color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080), fontWeight: FontWeight.bold, fontSize: 12)), widths['uni']!, center: true),
          if (showDetail && isFeeEnabled)
            _colCell(Text(((fee['uniSavings'] as num?) ?? 0).toStringAsFixed(0), style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold, fontSize: 12)), widths['uniRs']!, center: true),
          _colCell(Text('${fee['message']}/${fee['activeWorkingDays']}', style: const TextStyle(color: Color(0xFFED6C02), fontWeight: FontWeight.bold, fontSize: 12)), widths['msg']!, center: true),
          _colCell(_tag(
            fee['ptm'] ? 'J' : 'M',
            isDark ? (fee['ptm'] ? const Color(0xFF064E3B) : const Color(0xFF7F1D1D)) : (fee['ptm'] ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE)),
            isDark ? (fee['ptm'] ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5)) : (fee['ptm'] ? const Color(0xFF2E7D32) : const Color(0xFFD32F2F)),
          ), widths['ptm']!, center: true),
          if (isFeeEnabled) ...[
            _colCell(Text(((fee['totalSavings'] as num?) ?? 0).toStringAsFixed(0), style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold, fontSize: 12)), widths['savings']!, center: true),
            _colCell(
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
              widths['due']!,
              center: true,
            ),
          ],
          _colCell(
            StudentExportMenu(
              onPdf: () {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Preparing report for ${data['name'] ?? 'student'}...')));
                MadrassaReportHelper.exportIndividualPdf(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
              },
              onExcel: () {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Preparing Excel report for ${data['name'] ?? 'student'}...')));
                MadrassaReportHelper.exportIndividualExcel(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
              },
              onWhatsApp: () {
                _sendMonthlyWhatsApp(s, fee, logs);
              },
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
    final isPaid = payment != null && payment['status'] == 'paid';
    final amountPaid = (payment?['amountPaid'] as num?)?.toDouble() ?? due;
    final canManage = _canManageDues;

    final Color bg;
    final Color fg;
    final String text;
    final IconData? icon;

    if (isPaid) {
      bg = isDark ? const Color(0xFF064E3B) : const Color(0xFFE8F5E9);
      fg = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF2E7D32);
      text = 'PAID (Rs. ${amountPaid.toInt()})';
      icon = Icons.check_circle_rounded;
    } else if (due <= 0) {
      bg = isDark ? const Color(0xFF064E3B) : const Color(0xFFE8F5E9);
      fg = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF2E7D32);
      text = '0 (No Due)';
      icon = null;
    } else {
      bg = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFFEBEE);
      fg = isDark ? const Color(0xFFFCA5A5) : const Color(0xFFD32F2F);
      text = 'Rs. ${due.toInt()}';
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

    final holidaysList = MadrassaLocalStorage.getHolidaysCached(widget.branchId).map((h) {
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
      final mLogs = MadrassaLocalStorage.getLogsForMonthCached(widget.branchId, y, m);

      final mFee = MadrassaFeeLogic.calculateStudentFee(
        studentId: studentId,
        studentData: studentData,
        logs: mLogs,
        config: mConfig,
        totalWorkingDays: mWorkingDays,
        holidays: holidaysList,
      );

      final mPayment = MadrassaLocalStorage.getFeePaymentCached(widget.branchId, y, m, studentId);
      final activeDays = (mFee['activeWorkingDays'] as num?)?.toInt() ?? 0;

      // Only show months where student had active working days or has an existing payment record
      if (activeDays > 0 || mPayment != null) {
        final mDue = ((mFee['amountDue'] as num?) ?? 0.0).toDouble();
        final mStatus = mPayment?['status']?.toString() ?? (mDue <= 0 ? 'paid' : 'unpaid');
        final mPaid = (mPayment?['amountPaid'] as num?)?.toDouble() ?? (mStatus == 'paid' ? mDue : 0.0);
        final mNote = mPayment?['note']?.toString() ?? '';

        monthItems.add({
          'year': y,
          'month': m,
          'label': DateFormat('MMMM yyyy').format(DateTime(y, m)),
          'amountDue': mDue,
          'amountPaid': mPaid,
          'status': mStatus,
          'isPaid': mStatus == 'paid',
          'present': mFee['present'] ?? 0,
          'leave': mFee['leave'] ?? 0,
          'absent': mFee['absent'] ?? 0,
          'activeWorkingDays': activeDays,
          'note': mNote,
          'paymentRecord': mPayment,
          'isSelected': mStatus != 'paid' && mDue > 0,
        });
      }

      if (iter.month == 1) {
        iter = DateTime(iter.year - 1, 12, 1);
      } else {
        iter = DateTime(iter.year, iter.month - 1, 1);
      }
    }

    bool isSaving = false;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final unpaidItems = monthItems.where((item) => item['isPaid'] != true && (item['amountDue'] as double) > 0).toList();
            final totalUnpaidDues = unpaidItems.fold<double>(0.0, (sum, item) => sum + (item['amountDue'] as double));
            final selectedItems = monthItems.where((item) => item['isSelected'] == true && item['isPaid'] != true && (item['amountDue'] as double) > 0).toList();
            final totalSelectedDues = selectedItems.fold<double>(0.0, (sum, item) => sum + (item['amountDue'] as double));
            final allUnpaidSelected = unpaidItems.isNotEmpty && unpaidItems.every((item) => item['isSelected'] == true);

            Future<void> performPayment({
              required List<Map<String, dynamic>> itemsToPay,
              String? customNote,
            }) async {
              if (itemsToPay.isEmpty) return;
              setDialogState(() => isSaving = true);
              try {
                final markUser = (widget.username != null && widget.username!.isNotEmpty)
                    ? widget.username!
                    : ((widget.role ?? '').toLowerCase().contains('chairman') ? 'Chairman' : 'HQ Manager');
                final markRole = (widget.role != null && widget.role!.isNotEmpty)
                    ? widget.role!
                    : ((widget.role ?? '').toLowerCase().contains('chairman') ? 'Chairman' : 'HQ Manager');

                for (final item in itemsToPay) {
                  final y = item['year'] as int;
                  final m = item['month'] as int;
                  final due = item['amountDue'] as double;

                  await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                    branchId: widget.branchId,
                    studentId: studentId,
                    studentName: studentName,
                    rollNumber: rollNumber,
                    year: y,
                    month: m,
                    amountDue: due,
                    amountPaid: due,
                    status: 'paid',
                    markedBy: markUser,
                    markedByRole: markRole,
                    note: customNote ?? 'Fee Payment via Madrassa Portal',
                  );
                }

                SyncService().triggerUpload();

                if (dialogCtx.mounted) {
                  Navigator.pop(dialogCtx);
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Recorded payment for ${itemsToPay.length} month(s) (Total: Rs. ${itemsToPay.fold<double>(0.0, (s, e) => s + (e['amountDue'] as double)).toInt()}).'),
                      backgroundColor: const Color(0xFF0F766E),
                    ),
                  );
                }
              } catch (e) {
                setDialogState(() => isSaving = false);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error saving payments: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            }

            return Dialog(
              backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
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
                              color: const Color(0xFF0F766E).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.account_balance_wallet_rounded, color: Color(0xFF0F766E), size: 22),
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
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Roll #$rollNumber • Monthly Dues Breakdown',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          ),
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
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: totalUnpaidDues > 0
                              ? (isDark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2))
                              : (isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: totalUnpaidDues > 0
                                ? const Color(0xFFDC2626).withValues(alpha: 0.3)
                                : const Color(0xFF059669).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Total Outstanding Dues',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? Colors.white70 : Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Rs. ${totalUnpaidDues.toInt()}',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: totalUnpaidDues > 0 ? const Color(0xFFDC2626) : const Color(0xFF059669),
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: totalUnpaidDues > 0
                                    ? const Color(0xFFDC2626).withValues(alpha: 0.15)
                                    : const Color(0xFF059669).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                totalUnpaidDues > 0 ? '${unpaidItems.length} Unpaid Month(s)' : 'All Dues Clear',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: totalUnpaidDues > 0 ? const Color(0xFFDC2626) : const Color(0xFF059669),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Select All Header
                      if (canEdit && unpaidItems.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Previous Months Dues',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white70 : const Color(0xFF334155),
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  setDialogState(() {
                                    final newVal = !allUnpaidSelected;
                                    for (final item in monthItems) {
                                      if (item['isPaid'] != true && (item['amountDue'] as double) > 0) {
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
                                        activeColor: const Color(0xFF0F766E),
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                        onChanged: (val) {
                                          setDialogState(() {
                                            for (final item in monthItems) {
                                              if (item['isPaid'] != true && (item['amountDue'] as double) > 0) {
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
                                          color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E),
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
                                  style: TextStyle(color: isDark ? Colors.white54 : Colors.grey.shade500),
                                ),
                              )
                            : ListView.separated(
                                itemCount: monthItems.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 8),
                                itemBuilder: (ctx, idx) {
                                  final item = monthItems[idx];
                                  final isItemPaid = item['isPaid'] == true;
                                  final dueVal = (item['amountDue'] as double).toInt();
                                  final paidVal = (item['amountPaid'] as double).toInt();
                                  final isSelected = item['isSelected'] == true;

                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isItemPaid
                                          ? (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC))
                                          : (isSelected
                                              ? (isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : const Color(0xFFEFF6FF))
                                              : (isDark ? const Color(0xFF1E293B) : Colors.white)),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected && !isItemPaid
                                            ? const Color(0xFF3B82F6)
                                            : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                        width: isSelected && !isItemPaid ? 1.5 : 1.0,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        if (canEdit && !isItemPaid && dueVal > 0)
                                          Checkbox(
                                            value: isSelected,
                                            activeColor: const Color(0xFF0F766E),
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
                                              isItemPaid ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                                              size: 18,
                                              color: isItemPaid ? const Color(0xFF059669) : Colors.grey.shade400,
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
                                                      color: isDark ? Colors.white : const Color(0xFF1E293B),
                                                    ),
                                                  ),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: isItemPaid
                                                          ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                                          : const Color(0xFFEF4444).withValues(alpha: 0.15),
                                                      borderRadius: BorderRadius.circular(6),
                                                    ),
                                                    child: Text(
                                                      isItemPaid ? 'PAID (Rs. $paidVal)' : 'UNPAID (Rs. $dueVal)',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.bold,
                                                        color: isItemPaid ? const Color(0xFF059669) : const Color(0xFFDC2626),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  Text(
                                                    'P: ${item['present']} • L: ${item['leave']} • A: ${item['absent']}',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: isDark ? Colors.white54 : Colors.grey.shade600,
                                                    ),
                                                  ),
                                                  if ((item['note'] as String).isNotEmpty) ...[
                                                    const SizedBox(width: 8),
                                                    Flexible(
                                                      child: Text(
                                                        '• ${item['note']}',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontStyle: FontStyle.italic,
                                                          color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E),
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
                                        if (canEdit && isItemPaid)
                                          IconButton(
                                            tooltip: 'Mark as Unpaid',
                                            icon: const Icon(Icons.undo_rounded, size: 16, color: Colors.orange),
                                            onPressed: () async {
                                              await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                                                branchId: widget.branchId,
                                                studentId: studentId,
                                                studentName: studentName,
                                                rollNumber: rollNumber,
                                                year: item['year'] as int,
                                                month: item['month'] as int,
                                                amountDue: item['amountDue'] as double,
                                                amountPaid: 0,
                                                status: 'unpaid',
                                                markedBy: widget.username ?? 'HQ',
                                                markedByRole: widget.role ?? 'manager',
                                                note: 'Marked unpaid by manager',
                                              );
                                              setDialogState(() {
                                                item['status'] = 'unpaid';
                                                item['isPaid'] = false;
                                                item['isSelected'] = true;
                                              });
                                            },
                                          ),
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
                                  backgroundColor: const Color(0xFF0F766E),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSaving
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.check_box_rounded, size: 16),
                                label: Text(
                                  'Pay Selected (${selectedItems.length} • Rs. ${totalSelectedDues.toInt()})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                onPressed: isSaving ? null : () => performPayment(itemsToPay: selectedItems),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (unpaidItems.isNotEmpty && totalUnpaidDues > 0)
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF059669),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: isSaving
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.done_all_rounded, size: 16),
                                label: Text(
                                  'Pay All Dues (Rs. ${totalUnpaidDues.toInt()})',
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
    final data = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
    final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
    final due = ((fee['amountDue'] as num?) ?? 0.0).toDouble();
    final savings = ((fee['totalSavings'] as num?) ?? 0).toStringAsFixed(0);
    final p = fee['present'];
    final l = fee['leave'];
    final a = fee['absent'];
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey[600];

    final isPaid = payment != null && payment['status'] == 'paid';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
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
                            color: isDark ? const Color(0xFF0D9488).withValues(alpha: 0.2) : const Color(0xFFF0FDFC),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Roll ${data['rollNumber'] ?? '?'}',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E)),
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
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle_rounded, size: 11, color: Color(0xFF059669)),
                                SizedBox(width: 3),
                                Text(
                                  'PAID',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF059669)),
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
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Preparing report for ${data['name'] ?? 'student'}...')));
                  MadrassaReportHelper.exportIndividualPdf(config: config, studentId: sId, studentData: data, logs: logs, holidays: holidays);
                },
                onExcel: () {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Preparing Excel report for ${data['name'] ?? 'student'}...')));
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
              _statPill(context.l.present[0], '$p', const Color(0xFF2E7D32)),
              _statPill(context.l.leave[0], '$l', const Color(0xFFED6C02)),
              _statPill(context.l.absent[0], '$a', const Color(0xFFD32F2F)),
              _statPill(context.l.ptm, fee['ptm'] ? 'J' : 'M', fee['ptm'] ? const Color(0xFF2E7D32) : const Color(0xFFD32F2F)),
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
                    Text('Rs. $savings', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2E7D32), fontSize: 14)),
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
        borderRadius: BorderRadius.circular(8),
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
    final monthName = DateFormat('MMMM yyyy').format(DateTime(year, month));
    final isMobile = MediaQuery.of(context).size.width < 600;
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF454749);

    final headerInfo = Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0D9488).withValues(alpha: 0.2) : const Color(0xFFE0F2F1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.analytics_rounded, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080), size: 24),
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
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
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
            icon: const Icon(Icons.chevron_right, size: 20),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          elevation: 4,
          onSelected: (val) {
            if (val == 'pdf') {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Preparing bulk PDF report...'), duration: Duration(seconds: 2)),
              );
              MadrassaReportHelper.exportMonthlyPdf(config: displayConfig, students: students, logs: logs, holidays: holidays);
            } else if (val == 'excel') {
              ScaffoldMessenger.of(context).showSnackBar(
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
                      color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFEF4444), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    context.l.printPdf,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: isDark ? Colors.white : const Color(0xFF1E293B),
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
                      color: const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.table_chart_rounded, color: Color(0xFF10B981), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    context.l.exportExcel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: isDark ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                ],
              ),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF008080), Color(0xFF0D9488)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF008080).withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.file_download_outlined, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  context.isUrdu ? 'رپورٹ برآمد کریں' : 'Export',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 16),
              ],
            ),
          ),
        ),
        if (!isMobile) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              showDetail ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080),
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No guardian contact found for student')));
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

    final payment = MadrassaLocalStorage.getFeePaymentCached(widget.branchId, currentYear, currentMonth, sId);
    final isPaid = payment != null && payment['status'] == 'paid';

    final bool isFeeEnabled = (fee['enableFees'] != false) && LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

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
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not launch WhatsApp')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error launching WhatsApp: $e')));
      }
    }
  }
}