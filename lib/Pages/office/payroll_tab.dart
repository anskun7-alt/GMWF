// lib/pages/office/payroll_tab.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_loans_storage.dart';
import '../../services/finance_ledger_storage.dart';
import '../../services/local_storage_service.dart';

import '../../services/permission_service.dart';
import '../../services/payroll_calculator_service.dart';
import 'package:collection/collection.dart';
import 'shared_widgets.dart';

class PayrollTab extends StatefulWidget {
  final String branchId;
  final String monthKey;
  final ValueChanged<String> onMonthChanged;
  final String userRole;
  final String departmentFilter;

  const PayrollTab({
    super.key,
    required this.branchId,
    required this.monthKey,
    required this.onMonthChanged,
    required this.userRole,
    this.departmentFilter = 'all',
  });

  @override
  State<PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<PayrollTab> {
  final TextEditingController _ledgerSearchCtrl = TextEditingController();
  final TextEditingController _payrollSearchCtrl = TextEditingController();
  String _selectedLedgerEmployeeId = 'all';
  String _selectedBranchFilter = 'all';
  String _selectedDeptFilter = 'all';
  bool _showLedger = false;
  List<Map<String, dynamic>>? _calculatedPayroll;
  bool _isCalculating = false;

  // Tracks which payroll rows have their secondary breakdown expanded.
  // Progressive disclosure: collapsed by default, one tap away.
  final Set<String> _expandedRows = {};

  @override
  void initState() {
    super.initState();
    _selectedDeptFilter = widget.departmentFilter;
    _runPayrollCalculation();
  }

  @override
  void didUpdateWidget(PayrollTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monthKey != widget.monthKey || oldWidget.branchId != widget.branchId) {
      _selectedBranchFilter = 'all';
      _selectedDeptFilter = widget.departmentFilter;
      _runPayrollCalculation();
    } else if (oldWidget.departmentFilter != widget.departmentFilter) {
      _selectedDeptFilter = widget.departmentFilter;
    }
  }

  Future<void> _runPayrollCalculation() async {
    if (!mounted) return;
    // 1. Immediately calculate and render from local cache with 0ms blocking
    try {
      final cachedRes = await PayrollCalculatorService().calculatePayroll(
        branchId: widget.branchId,
        monthKey: widget.monthKey,
      );
      if (mounted && cachedRes.isNotEmpty) {
        setState(() {
          _calculatedPayroll = cachedRes;
          _isCalculating = false;
        });
      } else if (mounted) {
        setState(() => _isCalculating = true);
      }
    } catch (_) {
      if (mounted) setState(() => _isCalculating = true);
    }

    // 2. Fetch fresh network updates in background without freezing UI
    Future.microtask(() async {
      try {
        await FinanceLocalStorage.downloadAttendance(widget.branchId, monthKey: widget.monthKey);
        final freshRes = await PayrollCalculatorService().calculatePayroll(
          branchId: widget.branchId,
          monthKey: widget.monthKey,
        );
        if (mounted) {
          setState(() {
            _calculatedPayroll = freshRes;
            _isCalculating = false;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _isCalculating = false);
      }
    });
  }

  @override
  void dispose() {
    _ledgerSearchCtrl.dispose();
    _payrollSearchCtrl.dispose();
    super.dispose();
  }

  double _asNumDouble(dynamic val, [double fallback = 0.0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val) ?? fallback;
    return fallback;
  }

  int _asNumInt(dynamic val, [int fallback = 0]) {
    if (val == null) return fallback;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? (_asNumDouble(val).toInt());
    return fallback;
  }

  Color _mutedColorForKey(String key) {
    const palette = [
      SoftPalette.slate900, // Deep Slate
      SoftPalette.emerald550, // Deep Emerald
      SoftPalette.blue600, // Deep Royal Blue
      SoftPalette.violet600, // Deep Purple
      SoftPalette.orange500, // Amber Bronze
      SoftPalette.sky550, // Cyan Teal
    ];
    final idx = key.hashCode.abs() % palette.length;
    return palette[idx];
  }

  @override
  Widget build(BuildContext context) {
    final tOriginal = RoleThemeScope.dataOf(context);
    final t = RoleThemeData(
      roleLabel: tOriginal.roleLabel,
      isDarkCanvas: false,
      bg: SoftPalette.gray50,
      bgCard: SoftPalette.gray50,
      bgCardAlt: SoftPalette.slate100,
      bgRule: SoftPalette.slate150,
      accent: SoftPalette.emerald350,
      accentLight: SoftPalette.emerald300,
      accentMuted: SoftPalette.emerald100,
      accentGradient: const LinearGradient(colors: [SoftPalette.emerald350, SoftPalette.emerald500]),
      glassTint: SoftPalette.emerald350A10,
      textPrimary: SoftPalette.slate900,
      textSecondary: SoftPalette.slate550,
      textTertiary: SoftPalette.slate350,
      danger: SoftPalette.red400,
      zakat: tOriginal.zakat,
      nonZakat: tOriginal.nonZakat,
      gmwf: tOriginal.gmwf,
      cardFillTokens: tOriginal.cardFillTokens,
      cardFillPrescriptions: tOriginal.cardFillPrescriptions,
      cardFillDispensary: tOriginal.cardFillDispensary,
      chartBar1: tOriginal.chartBar1,
      chartBar2: tOriginal.chartBar2,
      chartBar3: tOriginal.chartBar3,
      chartGrid: tOriginal.chartGrid,
    );

    return Scaffold(
      backgroundColor: context.adapt(SoftPalette.gray50),
      body: Column(
        children: [
          _buildMonthPickerBar(t),
          Expanded(
            child: _showLedger ? _buildLedgerTimelineView(t) : _buildPayrollBoard(t),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthPickerBar(RoleThemeData t) {
    final displayDate = DateFormat('yyyy-MM').parse(widget.monthKey);

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.bgRule),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left_rounded, size: 20, color: t.textPrimary),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () {
                        final prev = DateTime(displayDate.year, displayDate.month - 1);
                        widget.onMonthChanged(DateFormat('yyyy-MM').format(prev));
                      },
                    ),
                    Container(width: 0.5, height: 20, color: t.bgRule),
                    IconButton(
                      icon: Icon(Icons.chevron_right_rounded, size: 20, color: t.textPrimary),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: widget.monthKey == DateFormat('yyyy-MM').format(DateTime.now())
                          ? null
                          : () {
                              final next = DateTime(displayDate.year, displayDate.month + 1);
                              widget.onMonthChanged(DateFormat('yyyy-MM').format(next));
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                children: [
                  Icon(Icons.calendar_month_outlined, color: t.accent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('MMMM yyyy').format(displayDate),
                    style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ],
              ),
            ],
          ),
          Container(
            height: 34,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: t.bgCardAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.bgRule),
            ),
            child: Row(
              children: [
                _buildToggleButton('Board View', !_showLedger, t),
                _buildToggleButton('Ledger Logs', _showLedger, t),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, bool active, RoleThemeData t) {
    return InkWell(
      onTap: () => setState(() => _showLedger = label == 'Ledger Logs'),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? t.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active ? [
            BoxShadow(
              color: t.accent.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            )
          ] : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? SoftPalette.gray50 : t.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }



  String _formatDayCount(double value) => value.toStringAsFixed(value % 1 == 0 ? 0 : 1);

  Widget _buildPayrollBoard(RoleThemeData t) {
    if (_isCalculating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: t.accent),
            const SizedBox(height: 12),
            Text('Calculating payroll details...', style: TextStyle(color: t.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }

    if (_calculatedPayroll == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              onPressed: _runPayrollCalculation,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Calculate Payroll'),
              style: ElevatedButton.styleFrom(backgroundColor: t.accent),
            ),
          ],
        ),
      );
    }

    final query = _payrollSearchCtrl.text.trim().toLowerCase();
    final filteredBySearch = _calculatedPayroll!.where((item) {
      final name = item['employeeName']?.toString().toLowerCase() ?? '';
      if (query.isNotEmpty && !name.contains(query)) return false;
      return true;
    }).toList();

    final list = filteredBySearch.where((item) {
      if (_selectedBranchFilter != 'all') {
        final empBranch = (item['empBranchId'] ?? '').toString().trim().toLowerCase();
        final selBranch = _selectedBranchFilter.trim().toLowerCase();
        final empNameBranch = FinanceLocalStorage.getBranchName(item['empBranchId']?.toString() ?? '').toLowerCase();
        final selNameBranch = FinanceLocalStorage.getBranchName(_selectedBranchFilter).toLowerCase();

        final matchCanonical = empNameBranch == selNameBranch;
        final matchClean = empBranch.replaceAll('branch_', '') == selBranch.replaceAll('branch_', '');
        final matchPrefix = empBranch.startsWith(selBranch) || selBranch.startsWith(empBranch);

        if (!matchCanonical && !matchClean && !matchPrefix) return false;
      }

      if (_selectedDeptFilter != 'all') {
        final dept = item['empDepartment']?.toString() ?? 'Other';
        final cleanDept = dept.trim().isEmpty ? 'Other' : dept.trim();
        if (cleanDept.toLowerCase() != _selectedDeptFilter.toLowerCase()) return false;
      }
      return true;
    }).toList();

    return ValueListenableBuilder(
      valueListenable: DebouncedBoxListenable.shared(FinanceLocalStorage.salaryLedgerBox),
      builder: (c, Box ledgerBox, _) {
        int paidCount = 0;
        double disbursedTotal = 0.0;
        double pendingTotal = 0.0;

        // O(1) payout lookup table
        final Map<String, List<Map<String, dynamic>>> payoutsByEmp = {};
        for (final val in ledgerBox.values) {
          if (val is Map) {
            final entry = Map<String, dynamic>.from(val);
            if (entry['monthKey'] == widget.monthKey && entry['type'] == 'payout' && entry['isVoided'] != true) {
              final eId = entry['employeeId']?.toString();
              if (eId != null && eId.isNotEmpty) {
                payoutsByEmp.putIfAbsent(eId, () => []).add(entry);
              }
            }
          }
        }

        final curMonthStr = DateFormat('yyyy-MM').format(DateTime.now());
        final isPreviousMonth = widget.monthKey.compareTo(curMonthStr) < 0;

        for (final item in list) {
          final empId = item['employeeId']?.toString() ?? '';
          final netSalary = _asNumDouble(item['netSalary']);
          final payouts = payoutsByEmp[empId] ?? [];

          final hasAttData = item['hasAttendanceData'] == true;
          final isPaid = payouts.isNotEmpty || (isPreviousMonth && hasAttData);

          if (isPaid) {
            paidCount++;
            final double amt = payouts.isNotEmpty 
                ? _asNumDouble(payouts.first['amount'], netSalary) 
                : netSalary;
            disbursedTotal += amt;
          } else {
            pendingTotal += netSalary;
          }
        }

        int unpaidCount = list.length - paidCount;

        return Column(

          children: [
            _buildMonthLockWarningIfNeeded(t),

            Container(
              color: t.bgCard,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.bgRule),
                ),
                child: TextField(
                  controller: _payrollSearchCtrl,
                  style: TextStyle(color: t.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search payroll by employee name...',
                    hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                    prefixIcon: Icon(Icons.search, color: t.textTertiary, size: 18),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),

            if (list.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_outline_rounded, size: 48, color: t.textTertiary),
                      const SizedBox(height: 12),
                      Text(
                        query.isNotEmpty ? 'No matching employees found.' : 'No active employees registered for this month.',
                        style: TextStyle(color: t.textTertiary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: context.adapt(SoftPalette.gray50),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.adapt(SoftPalette.slate150)),
                  boxShadow: const [
                    BoxShadow(color: SoftPalette.gray900A3, blurRadius: 4, offset: Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle_outline_rounded, color: SoftPalette.emerald500, size: 16),
                        const SizedBox(width: 6),
                        Text('DISBURSEMENT: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.adapt(SoftPalette.slate550))),
                        Text('$paidCount / ${list.length} PAID', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: SoftPalette.emerald500)),
                        Text(' ($unpaidCount pending)', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.slate350))),
                      ],
                    ),
                    Container(width: 1, height: 18, color: context.adapt(SoftPalette.slate150)),
                    Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined, color: SoftPalette.emerald500, size: 16),
                        const SizedBox(width: 6),
                        Text('DISBURSED: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.adapt(SoftPalette.slate550))),
                        Text('PKR ${_fmtCurrency(disbursedTotal)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: SoftPalette.emerald500)),
                      ],
                    ),
                    Container(width: 1, height: 18, color: context.adapt(SoftPalette.slate150)),
                    Row(
                      children: [
                        const Icon(Icons.hourglass_empty_rounded, color: SoftPalette.orange400, size: 16),
                        const SizedBox(width: 6),
                        Text('PENDING REQUIRED: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.adapt(SoftPalette.slate550))),
                        Text('PKR ${_fmtCurrency(pendingTotal)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: SoftPalette.orange400)),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _buildPayrollGroupedListWidget(t, list, payoutsByEmp),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildPayrollGroupedListWidget(RoleThemeData t, List<Map<String, dynamic>> list, Map<String, List<Map<String, dynamic>>> payoutsByEmp) {
    final grouped = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final item in list) {
      final branchId = item['empBranchId']?.toString() ?? 'unknown';
      final dept = item['empDepartment']?.toString() ?? 'Other';
      final cleanDept = dept.trim().isEmpty ? 'Other' : dept.trim();

      grouped.putIfAbsent(branchId, () => {});
      grouped[branchId]!.putIfAbsent(cleanDept, () => []);
      grouped[branchId]![cleanDept]!.add(item);
    }

    final sortedBranches = grouped.keys.toList()..sort((a, b) {
      if (a == 'unknown') return 1;
      if (b == 'unknown') return -1;
      return a.compareTo(b);
    });

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: sortedBranches.length,
      itemBuilder: (ctx, bIdx) {
        final branchId = sortedBranches[bIdx];
        final depts = grouped[branchId]!;
        final sortedDepts = FinanceLedgerStorage.sortDepartmentsCanonical(depts.keys);

        final branchName = Hive.box(LocalStorageService.branchesBox).get(branchId)?['name'] ?? branchId;
        final branchCol = context.adapt(_mutedColorForKey(branchName.toString()));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              margin: const EdgeInsets.only(top: 14, bottom: 8),
              width: double.infinity,
              decoration: BoxDecoration(
                color: context.adapt(SoftPalette.slate100),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.adapt(SoftPalette.slate200), width: 1.0),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.business_rounded, color: context.adapt(SoftPalette.slate900), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      branchName.toString().toUpperCase(),
                      style: TextStyle(
                        color: context.adapt(SoftPalette.slate900),
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ...sortedDepts.map((deptName) {
              final deptItems = depts[deptName]!;

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: t.bgRule),
                ),
                color: t.bgCard,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        border: Border(bottom: BorderSide(color: t.bgRule)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.label_outline_rounded, color: branchCol.withOpacity(0.95), size: 16),
                          const SizedBox(width: 8),
                          Text(
                            deptName.toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: t.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${deptItems.length} Employee${deptItems.length == 1 ? '' : 's'}',
                            style: TextStyle(fontSize: 11, color: t.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      children: () {
                        final isLocked = Hive.box(LocalStorageService.financeSettingsBox).get('month_lock_${widget.monthKey}') == true;
                        final curMonthStr = DateFormat('yyyy-MM').format(DateTime.now());
                        final isPreviousMonth = widget.monthKey.compareTo(curMonthStr) < 0;
                        final ps = PermissionService();

                        final List<Widget> rows = [];
                        for (final item in deptItems) {
                          try {
                            final empId = item['employeeId']?.toString() ?? '';
                            if (empId.isEmpty) continue;

                            // Use pre-computed employee metadata from payroll calculator
                            final emp = <String, dynamic>{
                              'name': item['empName'] ?? item['employeeName'] ?? 'Staff',
                              'role': item['empRole'] ?? 'Employee',
                              'department': item['empDepartment'] ?? deptName,
                              'camp': item['empCamp'] ?? '',
                              'localId': empId,
                              'isActive': item['empIsActive'] ?? true,
                              'branchId': item['empBranchId'] ?? branchId,
                            };

                            final payouts = payoutsByEmp[empId] ?? [];
                            // Use pre-computed hasAttendanceData flag
                            final hasAttData = item['hasAttendanceData'] == true;
                            final isPaid = payouts.isNotEmpty || (isPreviousMonth && hasAttData);
                            final isExpanded = _expandedRows.contains(empId);

                            // Use pre-computed values from payroll calculator (no re-fetching)
                            final double baseSalary = _asNumDouble(item['fullMonthWeightedSalary']);
                            final double baseSalaryEarned = _asNumDouble(item['baseSalaryEarned']);
                            final double absenceDeductions = _asNumDouble(item['absenceDeductions']);
                            final double overtimeBonusTotal = _asNumDouble(item['holidayBonus']) + _asNumDouble(item['sundayOvertimeBonus']);
                            final double netFromItem = _asNumDouble(item['netSalary']);
                            final double netPayDisplay = isPaid
                                ? (payouts.isNotEmpty ? _asNumDouble(payouts.first['amount'], netFromItem) : netFromItem)
                                : netFromItem;

                            final totalEmployed = _asNumDouble(item['totalEmployedDays'], 30);
                            final absent = _asNumDouble(item['absentDays']);
                            final unpaid = _asNumDouble(item['unpaidLeaves']);
                            final paidDaysCalc = totalEmployed - absent - unpaid;

                            rows.add(_buildPayrollRow(
                              t: t,
                              ps: ps,
                              emp: emp,
                              empId: empId,
                              isPaid: isPaid,
                              isLocked: isLocked,
                              netPayDisplay: netPayDisplay,
                              baseSalary: baseSalary,
                              baseSalaryEarned: baseSalaryEarned,
                              absenceDeductions: absenceDeductions,
                              overtimeBonusTotal: overtimeBonusTotal,
                              totalDays: _asNumInt(item['totalDays'], 30),
                              totalEmployedDays: _asNumInt(item['totalEmployedDays'], 30),
                              workingDays: _asNumDouble(item['workingDays']),
                              absentDays: absent,
                              unpaidLeaves: unpaid,
                              paidDaysStr: paidDaysCalc.toStringAsFixed(1).replaceAll('.0', ''),
                              sundayOvertimeDays: _asNumDouble(item['sundayOvertimeDays']),
                              advance: _asNumDouble(item['advanceInstallment']),
                              isExpanded: isExpanded,
                              payouts: payouts,
                              presentDates: (item['presentDates'] as List?) ?? const [],
                              absentDates: (item['absentDates'] as List?) ?? const [],
                              paidLeaveDates: (item['paidLeaveDates'] as List?) ?? const [],
                            ));
                          } catch (e, stack) {
                            debugPrint('[PayrollTab] Error rendering employee row: $e\n$stack');
                          }
                        }
                        return rows;
                      }(),
                    ),

                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildMonthLockWarningIfNeeded(RoleThemeData t) {
    final isLocked = Hive.box(LocalStorageService.financeSettingsBox).get('month_lock_${widget.monthKey}') == true;
    if (!isLocked) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.amber200).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.adapt(SoftPalette.amber200).withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: SoftPalette.amber200, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This period is locked and closed. All calculations and payouts are strictly read-only.',
              style: TextStyle(color: SoftPalette.orange350, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // ── Redesigned payroll row ────────────────────────────────────────────────
  // Two-tier layout: name/role + one primary number (Net Pay) up top;
  // everything else collapses behind a "Details" toggle. One primary action
  // ("Process Salary", gold); "Issue Loan"/"Log Repayment" live in a kebab
  // overflow menu since they're occasional, not the main task of this screen.
  Widget _buildPayrollRow({
    required RoleThemeData t,
    required PermissionService ps,
    required Map<String, dynamic> emp,
    required String empId,
    required bool isPaid,
    required bool isLocked,
    required double netPayDisplay,
    required double baseSalary,
    required double baseSalaryEarned,
    required double absenceDeductions,
    required double overtimeBonusTotal,
    required int totalDays,
    required int totalEmployedDays,
    required double workingDays,
    required double absentDays,
    required double unpaidLeaves,
    required String paidDaysStr,
    required double sundayOvertimeDays,
    required double advance,
    required bool isExpanded,
    required List payouts,
    required List presentDates,
    required List absentDates,
    required List paidLeaveDates,
  }) {
    final name = emp['name']?.toString() ?? '';
    final role = emp['role']?.toString() ?? '';
    final dept = emp['department']?.toString() ?? '';

    final branchLabel = Hive.box(LocalStorageService.branchesBox).get(emp['branchId']?.toString() ?? '')?['name'] ?? emp['branchId']?.toString() ?? '';
    final branchCol = context.adapt(_mutedColorForKey(branchLabel));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule, width: 1.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                  // ── Top line: identity + status pill ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              height: 36,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: branchCol,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            buildInitialsAvatar(context: context, name: name, theme: t, radius: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text('$role • $dept', style: TextStyle(color: t.textSecondary, fontSize: 11), overflow: TextOverflow.ellipsis),
                                      ),
                                      if (emp['camp'] != null && emp['camp'].toString().isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: emp['camp'].toString().contains('Haji')
                                                ? SoftPalette.sky500.withOpacity(0.12)
                                                : SoftPalette.emerald500.withOpacity(0.12),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(
                                              color: emp['camp'].toString().contains('Haji')
                                                  ? SoftPalette.sky500
                                                  : SoftPalette.emerald500,
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Text(
                                            emp['camp'].toString(),
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                              color: emp['camp'].toString().contains('Haji')
                                                  ? SoftPalette.sky550
                                                  : SoftPalette.emerald550,
                                            ),
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
                      ),
                      const SizedBox(width: 8),
                      buildStatusPill(
                        theme: t,
                        label: isPaid ? 'PAID' : 'UNPAID',
                        variant: isPaid ? StatusPillVariant.success : StatusPillVariant.warning,
                        icon: isPaid ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // ── The one number that matters: Net Pay ──
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isPaid ? 'NET PAID' : 'NET ESTIMATE', style: TextStyle(color: t.textTertiary, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.6)),
                          const SizedBox(height: 3),
                          Text(
                            'PKR ${_fmtCurrency(netPayDisplay)}',
                            style: TextStyle(color: isPaid ? SoftPalette.green400 : t.textPrimary, fontSize: 22, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      InkWell(
                        onTap: () => setState(() {
                          if (isExpanded) {
                            _expandedRows.remove(empId);
                          } else {
                            _expandedRows.add(empId);
                          }
                        }),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(isExpanded ? 'Hide details' : 'Details', style: TextStyle(color: t.accent, fontSize: 11, fontWeight: FontWeight.bold)),
                              Icon(isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: t.accent, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // ── Secondary breakdown, one tap away (progressive disclosure) ──
                  if (isExpanded) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildBreakdownColumn('Base Salary', baseSalaryEarned, false, t),
                              _buildBreakdownColumn('Deductions', absenceDeductions, true, t),
                              _buildBreakdownColumn('Bonuses/OT', overtimeBonusTotal, false, t),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Divider(color: t.bgRule, height: 1),
                          const SizedBox(height: 10),
                          Text(
                            '${totalEmployedDays < totalDays ? "Contract: $totalEmployedDays/$totalDays days" : "Full Month ($totalDays days)"} • Pay for $paidDaysStr days • worked ${_formatDayCount(workingDays)} d • ${_formatDayCount(absentDays)} abs • ${_formatDayCount(unpaidLeaves)} unpaid lv${sundayOvertimeDays > 0 ? " • sun OT: ${_formatDayCount(sundayOvertimeDays)}" : ""}',
                            style: TextStyle(color: t.textTertiary, fontSize: 11),
                          ),
                          if (absentDates.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.cancel_outlined, size: 13, color: SoftPalette.red400),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Absent on: ${FinanceLocalStorage.formatDayRanges(absentDates)}',
                                    style: const TextStyle(color: SoftPalette.red400, fontSize: 11, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (paidLeaveDates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.event_busy_outlined, size: 13, color: SoftPalette.amber300),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Leave on: ${FinanceLocalStorage.formatDayRanges(paidLeaveDates)}',
                                    style: const TextStyle(color: SoftPalette.amber300, fontSize: 11, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (presentDates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.check_circle_outline, size: 13, color: SoftPalette.green400),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Present on: ${FinanceLocalStorage.formatDayRanges(presentDates)}',
                                    style: TextStyle(color: t.textSecondary, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (!isPaid && totalEmployedDays < totalDays) ...[
                            const SizedBox(height: 4),
                            Text('Salary Rate: PKR ${_fmtCurrency((emp['currentSalary'] as num?)?.toDouble() ?? 0.0)}', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                          ],
                        ],
                      ),
                    ),
                  ],

                  // ── Advance pill, only when non-zero ──
                  if (advance > 0) ...[
                    const SizedBox(height: 10),
                    buildStatusPill(
                      theme: t,
                      label: 'Advance: PKR ${_fmtCurrency(advance)}',
                      variant: StatusPillVariant.warning,
                      icon: Icons.money_off_rounded,
                    ),
                  ],

                  const SizedBox(height: 12),

                  // ── One primary action + overflow for occasional actions ──
                  if (!isPaid) ...[
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isLocked ? SoftPalette.gray350 : t.accent,
                              foregroundColor: SoftPalette.gray50,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.payment, size: 14),
                            label: const Text('Process Salary', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            onPressed: isLocked ? null : () => _openPayoutDialog(context, empId, name, baseSalary, advance),
                          ),
                        ),
                        if (!isLocked) ...[
                          const SizedBox(width: 8),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: t.bgRule),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert, color: t.textSecondary, size: 18),
                              color: t.bgCardAlt,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              onSelected: (val) {
                                if (val == 'loan') _openIssueLoanDialog(context, empId, name);
                                if (val == 'repay') _openLogRepaymentDialog(context, empId, name);
                              },
                              itemBuilder: (menuCtx) => [
                                PopupMenuItem(
                                  value: 'loan',
                                  child: Row(
                                    children: [
                                      Icon(Icons.add_card, size: 16, color: t.textSecondary),
                                      const SizedBox(width: 8),
                                      Text('Issue Loan', style: TextStyle(color: t.textPrimary, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                if (advance > 0)
                                  PopupMenuItem(
                                    value: 'repay',
                                    child: Row(
                                      children: [
                                        Icon(Icons.payments_outlined, size: 16, color: t.textSecondary),
                                        const SizedBox(width: 8),
                                        Text('Log Repayment', style: TextStyle(color: t.textPrimary, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ] else if (ps.hasPermission(widget.userRole, AppPermission.voidFinanceRecord)) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isLocked ? context.adapt(SoftPalette.gray350) : t.danger,
                          side: BorderSide(color: isLocked ? context.adapt(SoftPalette.gray350) : t.danger, width: 0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        icon: const Icon(Icons.undo, size: 14),
                        label: const Text('Reverse Payout (Mark Unpaid)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: isLocked ? null : () => _showVoidDialog(context, payouts.first['localId']),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
  }

  static String _fmtCurrency(double amt) {
    return NumberFormat('#,###').format(amt);
  }

  Widget _buildLedgerTimelineView(RoleThemeData t) {
    final employees = FinanceLocalStorage.getEmployees(widget.branchId);
    final dropdownItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'all', child: Text('All Employees')),
    ];
    for (final emp in employees) {
      final id = emp['localId']?.toString() ?? '';
      final name = emp['name']?.toString() ?? 'Unknown';
      final role = emp['role']?.toString() ?? 'Staff';
      dropdownItems.add(DropdownMenuItem(
        value: id,
        child: Text('$name ($role)'),
      ));
    }

    return Column(
      children: [
        Container(
          color: t.bgCard,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            children: [
              Container(
                height: 38,
                decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.bgRule)),
                child: TextField(
                  controller: _ledgerSearchCtrl,
                  style: TextStyle(color: t.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search ledger logs...',
                    hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                    prefixIcon: Icon(Icons.search, color: t.textTertiary, size: 18),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.bgRule)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedLedgerEmployeeId,
                    dropdownColor: t.bgCard,
                    isExpanded: true,
                    style: TextStyle(color: t.textPrimary, fontSize: 13),
                    items: dropdownItems,
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedLedgerEmployeeId = val);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: DebouncedBoxListenable.shared(FinanceLocalStorage.salaryLedgerBox),
            builder: (ctx, Box box, _) {
              final query = _ledgerSearchCtrl.text.trim().toLowerCase();
              final entries = FinanceLocalStorage.getLedgerEntries(widget.branchId).where((e) {
                if (_selectedLedgerEmployeeId != 'all' && e['employeeId'] != _selectedLedgerEmployeeId) {
                  return false;
                }
                if (query.isNotEmpty) {
                  final name = e['employeeName']?.toString().toLowerCase() ?? '';
                  final note = e['note']?.toString().toLowerCase() ?? '';
                  final type = e['type']?.toString().toLowerCase() ?? '';
                  return name.contains(query) || note.contains(query) || type.contains(query);
                }
                return true;
              }).toList();

              if (entries.isEmpty) {
                return Center(child: Text('No payroll records logged.', style: TextStyle(color: t.textTertiary, fontSize: 12)));
              }

              final ps = PermissionService();

              return ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: entries.length,
                itemBuilder: (c, idx) {
                  final e = entries[idx];
                  final isVoid = e['isVoided'] == true;
                  final type = e['type']?.toString();
                  final amount = (e['amount'] as num?)?.toDouble() ?? 0.0;
                  final date = DateFormat('EEE, dd MMM yyyy').format(DateTime.parse(e['date']));

                  Color amountColor = SoftPalette.green400;
                  String typeLabel = 'Salary Payout';
                  IconData icon = Icons.payments_outlined;
                  StatusPillVariant typeVariant = StatusPillVariant.success;

                  if (type == 'advance_payment') {
                    amountColor = SoftPalette.amber300;
                    typeLabel = 'Advance Issue';
                    icon = Icons.add_card;
                    typeVariant = StatusPillVariant.warning;
                  } else if (type == 'arrears_payment') {
                    amountColor = SoftPalette.purple550;
                    typeLabel = 'Arrears Paid';
                    icon = Icons.redo_outlined;
                    typeVariant = StatusPillVariant.pro;
                  }

                  return Card(
                    color: t.bgCard,
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.bgRule)),
                    child: Opacity(
                      opacity: isVoid ? 0.45 : 1.0,
                      child: Tooltip(
                        message: isVoid ? 'Voided by ${e['voidedBy']}: ${e['voidReason']}' : '',
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundColor: isVoid ? t.bgRule : amountColor.withOpacity(0.12),
                            child: Icon(icon, color: isVoid ? t.textTertiary : amountColor, size: 18),
                          ),
                          title: Row(
                            children: [
                              Text(e['employeeName'] ?? '', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, decoration: isVoid ? TextDecoration.lineThrough : null)),
                              const SizedBox(width: 8),
                              buildStatusPill(theme: t, label: typeLabel, variant: isVoid ? StatusPillVariant.accent : typeVariant),
                            ],
                          ),
                          subtitle: Text(
                            'Period: ${e['monthKey']} • Date: $date\n${e['note'] ?? ""}',
                            style: TextStyle(color: t.textTertiary, fontSize: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'PKR ${NumberFormat('#,###').format(amount)}',
                                style: TextStyle(color: isVoid ? t.textTertiary : amountColor, fontWeight: FontWeight.bold, fontSize: 13, decoration: isVoid ? TextDecoration.lineThrough : null),
                              ),
                              if (!isVoid && ps.hasPermission(widget.userRole, AppPermission.voidFinanceRecord)) ...[
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: () => _showVoidDialog(context, e['localId']),
                                  child: const Icon(Icons.delete_forever_outlined, color: SoftPalette.red400, size: 18),
                                )
                              ]
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _showVoidDialog(BuildContext context, String recordId) {
    final t = RoleThemeScope.dataOf(context);
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: t.bgCard,
          title: Text('Void Financial Record', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'WARNING: Voiding a financial ledger record will immediately adjust the employee\'s advance balance. This action is audited and cannot be undone.',
                style: TextStyle(color: t.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                style: TextStyle(color: t.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Reason for Voiding *',
                  labelStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: t.bgRule)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400),
              onPressed: () async {
                if (reasonController.text.trim().isEmpty) {
                  AppToast.showSnackBar(ctx, const SnackBar(
                    content: Text('Please enter a reason for voiding this transaction.'),
                    backgroundColor: SoftPalette.red400,
                    behavior: SnackBarBehavior.floating,
                  ));
                  return;
                }
                try {
                  final curUser = LocalStorageService.getActiveUsername();

                  await FinanceLocalStorage.voidLedgerEntry(
                    branchId: widget.branchId,
                    recordId: recordId,
                    voidedBy: curUser,
                    voidReason: reasonController.text.trim(),
                    approvedBy: curUser,
                  );

                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    AppToast.showSnackBar(context, SnackBar(
                      content: const Text('Transaction voided and ledger recalculated.'),
                      backgroundColor: t.accent,
                      behavior: SnackBarBehavior.floating,
                    ));
                  }
                } catch (e) {
                  AppToast.showSnackBar(ctx, SnackBar(
                    content: Text('Failed: $e'),
                    backgroundColor: SoftPalette.red400,
                    behavior: SnackBarBehavior.floating,
                  ));
                }
              },
              child: const Text('Void Transaction', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _openIssueLoanDialog(BuildContext context, String employeeId, String employeeName) {
    final t = RoleThemeScope.dataOf(context);
    final amountController = TextEditingController();
    final usualController = TextEditingController();
    final noteController = TextEditingController();
    String repaymentType = 'fixed';

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return AlertDialog(
              backgroundColor: t.bgCard,
              title: Text('Issue Loan - $employeeName', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildFormField(
                    controller: amountController,
                    label: 'Loan Amount (PKR) *',
                    icon: Icons.payments,
                    theme: t,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 10),
                  buildDropdownField(
                    label: 'Repayment Type *',
                    value: repaymentType == 'fixed' ? 'Fixed Monthly Installment' : 'Flexible (pay as able)',
                    items: const ['Fixed Monthly Installment', 'Flexible (pay as able)'],
                    onChanged: (val) => setSheetState(() {
                      repaymentType = val == 'Fixed Monthly Installment' ? 'fixed' : 'flexible';
                    }),
                    theme: t,
                  ),
                  const SizedBox(height: 10),
                  buildFormField(
                    controller: usualController,
                    label: repaymentType == 'fixed'
                        ? 'Monthly Installment (PKR) *'
                        : 'Usual Repayment Amount (PKR, optional reference)',
                    icon: Icons.calendar_view_month,
                    theme: t,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 10),
                  buildFormField(
                    controller: noteController,
                    label: 'Reason / Notes',
                    icon: Icons.note_alt_outlined,
                    theme: t,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'This loan is tracked separately and never reduces salary payouts.\nRepayments are logged on their own via "Log Repayment".',
                      style: TextStyle(color: t.textTertiary, fontSize: 11, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: t.accent),
                  onPressed: () async {
                    final amt = double.tryParse(amountController.text.trim());
                    if (amt == null || amt <= 0) {
                      showCustomSnackBar(sheetCtx, 'Please enter a valid loan amount.', error: true);
                      return;
                    }
                    final usual = double.tryParse(usualController.text.trim()) ?? 0.0;
                    if (repaymentType == 'fixed' && usual <= 0) {
                      showCustomSnackBar(sheetCtx, 'Please enter the monthly installment amount.', error: true);
                      return;
                    }
                    try {
                      final curUser = LocalStorageService.getActiveUsername();
                      await FinanceLoansStorage.createLoan(
                        branchId: widget.branchId,
                        employeeId: employeeId,
                        employeeName: employeeName,
                        principal: amt,
                        repaymentType: repaymentType,
                        usualInstallment: usual,
                        reason: noteController.text.trim(),
                        performedBy: curUser,
                      );
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        showCustomSnackBar(context, 'Loan of PKR ${NumberFormat('#,###').format(amt)} issued to $employeeName');
                      }
                    } catch (e) {
                      showCustomSnackBar(sheetCtx, 'Failed: $e', error: true);
                    }
                  },
                  child: const Text('Issue Loan', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openLogRepaymentDialog(BuildContext context, String employeeId, String employeeName) {
    final t = RoleThemeScope.dataOf(context);
    final loans = FinanceLoansStorage.getActiveLoansForEmployee(employeeId);

    if (loans.isEmpty) {
      showCustomSnackBar(context, '$employeeName has no active loans.', error: true);
      return;
    }

    String selectedLoanId = loans.first['localId'].toString();
    final amountController = TextEditingController();
    final noteController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final selectedLoan = loans.firstWhere((l) => l['localId'] == selectedLoanId);
            final balance = FinanceLoansStorage.getLoanBalance(selectedLoan);

            return AlertDialog(
              backgroundColor: t.bgCard,
              title: Text('Log Repayment - $employeeName', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (loans.length > 1)
                    buildDropdownField(
                      label: 'Which Loan?',
                      value: '${selectedLoan['reason']} (PKR ${NumberFormat('#,###').format(balance)} left)',
                      items: loans.map((l) {
                        final b = FinanceLoansStorage.getLoanBalance(l);
                        return '${l['reason']} (PKR ${NumberFormat('#,###').format(b)} left)';
                      }).toList(),
                      onChanged: (val) {
                        final idx = loans.indexWhere((l) {
                          final b = FinanceLoansStorage.getLoanBalance(l);
                          return '${l['reason']} (PKR ${NumberFormat('#,###').format(b)} left)' == val;
                        });
                        if (idx != -1) setSheetState(() => selectedLoanId = loans[idx]['localId'].toString());
                      },
                      theme: t,
                    ),
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Outstanding Balance', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                        Text('PKR ${NumberFormat('#,###').format(balance)}',
                            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (selectedLoan['repaymentType'] == 'fixed')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Usual installment: PKR ${NumberFormat('#,###').format((selectedLoan['usualInstallment'] as num?)?.toDouble() ?? 0.0)}/month',
                        style: TextStyle(color: t.textTertiary, fontSize: 11),
                      ),
                    ),
                  buildFormField(
                    controller: amountController,
                    label: 'Amount Paid Today (PKR) *',
                    icon: Icons.payments,
                    theme: t,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 10),
                  buildFormField(
                    controller: noteController,
                    label: 'Note (optional)',
                    icon: Icons.note_alt_outlined,
                    theme: t,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: t.accent),
                  onPressed: () async {
                    final amt = double.tryParse(amountController.text.trim());
                    if (amt == null || amt <= 0) {
                      showCustomSnackBar(sheetCtx, 'Please enter a valid amount.', error: true);
                      return;
                    }
                    try {
                      final curUser = LocalStorageService.getActiveUsername();
                      await FinanceLoansStorage.recordPayment(
                        loanId: selectedLoanId,
                        amount: amt,
                        note: noteController.text.trim(),
                        performedBy: curUser,
                      );
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        showCustomSnackBar(context, 'Repayment of PKR ${NumberFormat('#,###').format(amt)} logged.');
                      }
                    } catch (e) {
                      showCustomSnackBar(sheetCtx, 'Failed: $e', error: true);
                    }
                  },
                  child: const Text('Log Repayment', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openPayoutDialog(
    BuildContext context,
    String employeeId,
    String employeeName,
    double baseSalary,
    double advanceBalance,
  ) {
    final t = RoleThemeScope.dataOf(context);

    // Compute payroll attendance summaries, including holidays and absence counts.
    final payrollSummary = FinanceLocalStorage.getPayrollAttendanceSummary(employeeId, widget.monthKey);
    final baseSalaryWeighted = (payrollSummary['fullMonthWeightedSalary'] as num).toDouble();
    final baseSalaryEarned = (payrollSummary['baseSalaryEarned'] as num).toDouble();
    final absentDays = (payrollSummary['absentDays'] as num).toDouble();
    final unpaidLeaves = (payrollSummary['unpaidLeaves'] as num).toDouble();
    final workingDays = (payrollSummary['workingDays'] as num).toDouble();
    final paidLeaves = (payrollSummary['paidLeaves'] as num).toDouble();
    final holidayWorkedDays = (payrollSummary['holidayWorkedDays'] as num).toDouble();
    final holidayCount = (payrollSummary['holidayCount'] as num).toInt();
    final totalDays = (payrollSummary['totalDays'] as num).toInt();
    final totalEmployedDays = (payrollSummary['totalEmployedDays'] as num).toInt();
    final sundayOvertimeDays = (payrollSummary['sundayOvertimeDays'] as num?)?.toDouble() ?? 0.0;
    final sundayOvertimeBonus = (payrollSummary['sundayOvertimeBonus'] as num?)?.toDouble() ?? 0.0;

    // Daily rate for average reference display
    final dailyRate = baseSalaryWeighted / totalDays;
    final absenceDeductions = (payrollSummary['absenceDeductions'] as num).toDouble();
    final holidayBonus = (payrollSummary['holidayBonus'] as num).toDouble();
    final overtimeBonusTotal = holidayBonus + sundayOvertimeBonus;

    final emp = FinanceLocalStorage.getEmployee(employeeId);
    final contractSalary = (emp?['currentSalary'] as num?)?.toDouble() ?? 0.0;
    final isCash = emp?['bankName'] == 'Cash' || emp?['bankName'] == null;
    String paymentMethod = isCash ? 'cash' : 'bank_transfer';
    String selectedAccountCode = isCash ? '1030' : '1010';

    final activeLoans = FinanceLoansStorage.getActiveLoansForEmployee(employeeId);
    final fixedLoan = activeLoans.firstWhereOrNull((l) => l['repaymentType'] == 'fixed');
    final flexibleLoan = activeLoans.firstWhereOrNull((l) => l['repaymentType'] == 'flexible');

    double defaultDeduction = 0.0;
    String defaultDeductionType = 'none';
    if (fixedLoan != null) {
      final balance = FinanceLoansStorage.getLoanBalance(fixedLoan);
      final usual = (fixedLoan['usualInstallment'] as num?)?.toDouble() ?? 0.0;
      defaultDeduction = usual.clamp(0.0, balance);
      defaultDeductionType = 'loan';
    }

    // Controllers
    final otherDeductionsCtrl = TextEditingController(text: defaultDeduction > 0 ? defaultDeduction.toStringAsFixed(0) : '0');
    final arrearsCtrl = TextEditingController(text: '0');
    final overtimeBonusCtrl = TextEditingController(text: overtimeBonusTotal.toStringAsFixed(0));
    final noteCtrl = TextEditingController();
    String otherDeductionsType = defaultDeductionType;

    double netPaid = baseSalaryEarned - absenceDeductions - defaultDeduction + overtimeBonusTotal;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            void updateCalculations() {
              final otherDed = double.tryParse(otherDeductionsCtrl.text) ?? 0.0;
              final arrs = double.tryParse(arrearsCtrl.text) ?? 0.0;
              final otBonus = double.tryParse(overtimeBonusCtrl.text) ?? 0.0;

              setSheetState(() {
                netPaid = (baseSalaryEarned - absenceDeductions - otherDed + arrs + otBonus).clamp(0.0, double.infinity);
              });
            }

            return Container(
              padding: EdgeInsets.only(top: 20, left: 16, right: 16, bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Process Payroll Payout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(sheetCtx)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('Employee: $employeeName', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('Payroll Period: ${widget.monthKey}', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                    const SizedBox(height: 14),
                    if (totalEmployedDays < totalDays) ...[
                      _buildCalculationRow('Contract Base Salary', contractSalary, false, t),
                      _buildCalculationRow('Prorated Base Salary (Employed $totalEmployedDays/$totalDays days)', baseSalaryEarned, false, t),
                    ] else ...[
                      _buildCalculationRow('Base Salary', contractSalary, false, t),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Automatically Detected Days', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                          Text('${totalEmployedDays < totalDays ? "Employed: $totalEmployedDays" : "Total: $totalDays"} | Worked: ${_formatDayCount(workingDays)} | Paid Leaves: ${_formatDayCount(paidLeaves)}', style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    _buildCalculationRow('Reference Salary Rate Per Day', dailyRate, false, t),
                    _buildCalculationRow('Absence Deductions (${absentDays + unpaidLeaves} days absent/unpaid)', absenceDeductions, true, t),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Overtime & Holiday details', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                          Text('Holidays: $holidayCount | Worked: ${_formatDayCount(holidayWorkedDays)} | Sun OT: ${_formatDayCount(sundayOvertimeDays)}', style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    buildFormField(
                      controller: overtimeBonusCtrl,
                      label: 'Overtime & Holiday Bonus (PKR)',
                      icon: Icons.star_border,
                      theme: t,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => updateCalculations(),
                    ),
                     const SizedBox(height: 10),
                     Divider(color: t.bgRule, height: 1),
                     const SizedBox(height: 14),

                     if (activeLoans.isNotEmpty) ...[
                       Container(
                         padding: const EdgeInsets.all(12),
                         margin: const EdgeInsets.only(bottom: 14),
                         decoration: BoxDecoration(
                           color: t.accent.withOpacity(0.06),
                           borderRadius: BorderRadius.circular(10),
                           border: Border.all(color: t.accent.withOpacity(0.2)),
                         ),
                         child: Column(
                           crossAxisAlignment: CrossAxisAlignment.start,
                           children: [
                             Row(
                               children: [
                                 Icon(Icons.credit_card, size: 16, color: t.accent),
                                 const SizedBox(width: 6),
                                 Text('Active Loan/Advance detected', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                               ],
                             ),
                             const SizedBox(height: 6),
                             ...activeLoans.map((loan) {
                               final balance = FinanceLoansStorage.getLoanBalance(loan);
                               final isFixed = loan['repaymentType'] == 'fixed';
                               final usual = (loan['usualInstallment'] as num?)?.toDouble() ?? 0.0;
                               return Padding(
                                 padding: const EdgeInsets.only(bottom: 4),
                                 child: Text(
                                   '• ${loan['reason']}: PKR ${NumberFormat('#,###').format(balance)} outstanding (${isFixed ? "Fixed Installment: PKR ${NumberFormat('#,###').format(usual)}/mo" : "Flexible repayment"})',
                                   style: TextStyle(color: t.textSecondary, fontSize: 11),
                                 ),
                               );
                             }),
                             if (fixedLoan != null) ...[
                               const SizedBox(height: 8),
                               Text(
                                 'Fixed installment of PKR ${NumberFormat('#,###').format(defaultDeduction)} is automatically pre-filled below.',
                                 style: TextStyle(color: t.accent, fontSize: 11, fontWeight: FontWeight.bold),
                               ),
                             ],
                             if (fixedLoan == null && flexibleLoan != null) ...[
                               const SizedBox(height: 8),
                               Text(
                                 'This employee has a Flexible Loan. Would you like to deduct any amount towards this loan?',
                                 style: TextStyle(color: t.textSecondary, fontSize: 11, fontStyle: FontStyle.italic),
                               ),
                               const SizedBox(height: 6),
                               Row(
                                 children: [
                                   ElevatedButton(
                                     style: ElevatedButton.styleFrom(
                                       padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                       minimumSize: Size.zero,
                                       backgroundColor: t.accent.withOpacity(0.1),
                                       foregroundColor: t.accent,
                                       elevation: 0,
                                     ),
                                     onPressed: () {
                                       setSheetState(() {
                                         otherDeductionsType = 'loan';
                                         otherDeductionsCtrl.text = '1000';
                                         updateCalculations();
                                       });
                                     },
                                     child: const Text('Deduct 1,000', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                   ),
                                   const SizedBox(width: 8),
                                   ElevatedButton(
                                     style: ElevatedButton.styleFrom(
                                       padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                       minimumSize: Size.zero,
                                       backgroundColor: t.accent.withOpacity(0.1),
                                       foregroundColor: t.accent,
                                       elevation: 0,
                                     ),
                                     onPressed: () {
                                       setSheetState(() {
                                         otherDeductionsType = 'loan';
                                         otherDeductionsCtrl.text = '5000';
                                         updateCalculations();
                                       });
                                     },
                                     child: const Text('Deduct 5,000', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                   ),
                                   const SizedBox(width: 8),
                                   ElevatedButton(
                                     style: ElevatedButton.styleFrom(
                                       padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                       minimumSize: Size.zero,
                                       backgroundColor: SoftPalette.gray350.withOpacity(0.1),
                                       foregroundColor: context.adapt(SoftPalette.gray550),
                                       elevation: 0,
                                     ),
                                     onPressed: () {
                                       setSheetState(() {
                                         otherDeductionsType = 'none';
                                         otherDeductionsCtrl.text = '0';
                                         updateCalculations();
                                       });
                                     },
                                     child: const Text('No Deduction', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                   ),
                                 ],
                               ),
                             ],
                           ],
                         ),
                       ),
                     ],

                     // Input: Other deductions
                    buildFormField(
                      controller: otherDeductionsCtrl,
                      label: 'Other Deductions (Fine, tax, etc.)',
                      icon: Icons.money_off,
                      theme: t,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => updateCalculations(),
                    ),
                    const SizedBox(height: 10),
                    buildDropdownField(
                      label: 'Deduction Type',
                      value: otherDeductionsType == 'loan' 
                          ? 'Loan Deduction' 
                          : (otherDeductionsType == 'security' ? 'Security Deduction' : 'None'),
                      items: ['None', 'Loan Deduction', 'Security Deduction'],
                      onChanged: (val) => setSheetState(() {
                        if (val == 'None') otherDeductionsType = 'none';
                        if (val == 'Loan Deduction') otherDeductionsType = 'loan';
                        if (val == 'Security Deduction') otherDeductionsType = 'security';
                      }),
                      theme: t,
                    ),

                    // Input: Arrears adjustment
                    buildFormField(
                      controller: arrearsCtrl,
                      label: 'Arrears / Bonuses Adjustment (Arrears add to net paid)',
                      icon: Icons.add_card,
                      theme: t,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => updateCalculations(),
                    ),

                    buildDropdownField(
                      label: 'Disburse From Bank/Cash Account *',
                      value: selectedAccountCode == '1010' ? '1010 - Meezan Bank Main' :
                             (selectedAccountCode == '1020' ? '1020 - UBL Operating Account' :
                             (selectedAccountCode == '1050' ? '1050 - EasyPaisa Merchant' :
                             (selectedAccountCode == '1060' ? '1060 - JazzCash Merchant' : '1030 - Cash in Hand (Petty)'))),
                      items: [
                        '1010 - Meezan Bank Main',
                        '1020 - UBL Operating Account',
                        '1030 - Cash in Hand (Petty)',
                        '1050 - EasyPaisa Merchant',
                        '1060 - JazzCash Merchant',
                      ],
                      onChanged: (val) => setSheetState(() {
                        if (val != null && val.contains('1010')) { selectedAccountCode = '1010'; paymentMethod = 'bank_transfer'; }
                        else if (val != null && val.contains('1020')) { selectedAccountCode = '1020'; paymentMethod = 'bank_transfer'; }
                        else if (val != null && val.contains('1050')) { selectedAccountCode = '1050'; paymentMethod = 'easypaisa'; }
                        else if (val != null && val.contains('1060')) { selectedAccountCode = '1060'; paymentMethod = 'jazzcash'; }
                        else { selectedAccountCode = '1030'; paymentMethod = 'cash'; }
                      }),
                      theme: t,
                    ),

                    const SizedBox(height: 10),
                    buildFormField(
                      controller: noteCtrl,
                      label: 'Payroll Remarks / Notes',
                      icon: Icons.note_alt_outlined,
                      theme: t,
                      maxLines: 2,
                    ),

                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.bgRule)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('NET PAID SALARY', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          Text(
                            'PKR ${NumberFormat('#,###').format(netPaid)}',
                            style: const TextStyle(color: SoftPalette.green400, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () async {
                        final otherDed = double.tryParse(otherDeductionsCtrl.text.trim()) ?? 0.0;
                        final arrs = double.tryParse(arrearsCtrl.text.trim()) ?? 0.0;
                        final otBonus = double.tryParse(overtimeBonusCtrl.text.trim()) ?? 0.0;

                        // Check if already paid to prevent duplicate payouts
                        final doubleCheckPaid = FinanceLocalStorage.salaryLedgerBox.values.any((val) {
                          if (val is! Map) return false;
                          final entry = Map<String, dynamic>.from(val);
                          return entry['employeeId'] == employeeId &&
                                 entry['monthKey'] == widget.monthKey &&
                                 entry['type'] == 'payout' &&
                                 entry['isVoided'] != true;
                        });

                        if (doubleCheckPaid) {
                          showCustomSnackBar(sheetCtx, 'Salary has already been processed for this month.', error: true);
                          return;
                        }

                        // Double confirmation dialog with payout breakdown
                        final confirm = await showDialog<bool>(
                          context: sheetCtx,
                          builder: (confirmCtx) {
                            return AlertDialog(
                              backgroundColor: t.bgCard,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              title: Text('Confirm Salary Payout', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Are you sure you want to disburse salary for $employeeName?', style: TextStyle(color: t.textSecondary, fontSize: 13)),
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.bgRule)),
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text('Base Salary Earned:', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                            Text('PKR ${NumberFormat('#,###').format(baseSalaryEarned)}', style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                        if (absenceDeductions > 0) ...[
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text('Absence Deductions:', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                              Text('- PKR ${NumberFormat('#,###').format(absenceDeductions)}', style: const TextStyle(color: SoftPalette.red400, fontSize: 11, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ],
                                        if (otherDed > 0) ...[
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(otherDeductionsType == 'loan' ? 'Loan Deduction:' : (otherDeductionsType == 'security' ? 'Security Deduction:' : 'Other Deductions:'), style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                              Text('- PKR ${NumberFormat('#,###').format(otherDed)}', style: const TextStyle(color: SoftPalette.red400, fontSize: 11, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ],
                                        if (arrs > 0) ...[
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text('Arrears / Adjustment:', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                              Text('+ PKR ${NumberFormat('#,###').format(arrs)}', style: const TextStyle(color: SoftPalette.green400, fontSize: 11, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ],
                                        if (otBonus > 0) ...[
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text('OT & Holiday Bonus:', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                              Text('+ PKR ${NumberFormat('#,###').format(otBonus)}', style: const TextStyle(color: SoftPalette.green400, fontSize: 11, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Divider(color: t.bgRule, height: 1),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text('Net Disbursed Amount:', style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
                                            Text('PKR ${NumberFormat('#,###').format(netPaid)}', style: const TextStyle(color: SoftPalette.green400, fontSize: 14, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(confirmCtx, false),
                                  child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: SoftPalette.green400,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () => Navigator.pop(confirmCtx, true),
                                  child: const Text('Confirm & Disburse', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            );
                          },
                        );

                        if (confirm != true) return;

                        try {
                          final curUser = LocalStorageService.getActiveUsername();

                          final ledgerData = {
                            'employeeId': employeeId,
                            'employeeName': employeeName,
                            'type': 'payout',
                            'amount': netPaid,
                            'monthKey': widget.monthKey,
                            'date': DateTime.now().toIso8601String(),
                            'advanceDeductions': 0.0,
                            'absenceDeductions': absenceDeductions,
                            'holidayBonus': otBonus,
                            'holidayWorkedDays': holidayWorkedDays,
                            'sundayOvertimeDays': sundayOvertimeDays,
                            'sundayOvertimeBonus': 0.0,
                            'baseSalaryWeighted': baseSalaryWeighted,
                            'baseSalaryEarned': baseSalaryEarned,
                            'otherDeductions': otherDed,
                            'otherDeductionsType': otherDeductionsType,
                            'advanceAdded': 0.0,
                            'paymentMethod': paymentMethod,
                            'accountCode': selectedAccountCode,
                            'note': noteCtrl.text.trim().isNotEmpty ? noteCtrl.text.trim() : 'Monthly salary processed.',
                          };

                          await FinanceLocalStorage.saveLedgerEntry(
                            branchId: widget.branchId,
                            data: ledgerData,
                            performedBy: curUser,
                          );

                          // Auto-apply loan repayment if type is loan and amount > 0
                          if (otherDeductionsType == 'loan' && otherDed > 0) {
                            double remainingToDeduct = otherDed;
                            for (final loan in activeLoans) {
                              if (remainingToDeduct <= 0.01) break;
                              final balance = FinanceLoansStorage.getLoanBalance(loan);
                              final deductFromThis = remainingToDeduct.clamp(0.0, balance);
                              if (deductFromThis > 0) {
                                await FinanceLoansStorage.recordPayment(
                                  loanId: loan['id'],
                                  amount: deductFromThis,
                                  note: 'Salary Deduction for Period ${widget.monthKey}',
                                  performedBy: curUser,
                                );
                                remainingToDeduct -= deductFromThis;
                              }
                            }
                          }

                          if (sheetCtx.mounted) {
                            Navigator.pop(sheetCtx);
                            showCustomSnackBar(context, 'Salary processed successfully for $employeeName. Net Paid: PKR ${NumberFormat('#,###').format(netPaid)}');
                          }
                        } catch (e) {
                          showCustomSnackBar(sheetCtx, 'Failed: $e', error: true);
                        }
                      },

                      child: const Text('Disburse Payout', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCalculationRow(String label, double amount, bool isDeduction, RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: t.textSecondary, fontSize: 12)),
          Text(
            '${isDeduction ? "-" : ""} PKR ${NumberFormat('#,###').format(amount)}',
            style: TextStyle(color: isDeduction ? SoftPalette.red400 : t.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildBreakdownColumn(
    String label,
    double amount,
    bool isDeduction,
    RoleThemeData t, {
    Color? highlightColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: t.textTertiary, fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          '${isDeduction ? "-" : ""}PKR ${NumberFormat('#,###').format(amount)}',
          style: TextStyle(
            color: highlightColor ?? (isDeduction ? SoftPalette.red400 : t.textPrimary),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}