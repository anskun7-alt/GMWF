import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';

import '../../theme/role_theme_provider.dart';
import '../../services/finance_local_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/zkteco_network_service.dart';
import '../settings/biometric_device_manager_page.dart';
import 'bulk_attendance_dialog.dart';
import 'employee_detail_page.dart';
import 'offboard_dialog.dart';

// ── Executive Navy Design System Tokens ─────────────────────────────────────────
class ExecTokens {
  // 1. Structural & Surface Neutrals
  static const navSurface      = Color(0xFF0B132B); // Obsidian Navy
  static const canvasBg        = Color(0xFFF8FAFC); // Cool Off-White
  static const cardSurface     = Color(0xFFFFFFFF); // Pure White
  static const rowHover        = Color(0xFFF1F5F9); // Slate Tint
  static const rowSelected     = Color(0xFFEFF6FF); // Ice Blue
  static const borderMuted     = Color(0xFFE2E8F0); // Muted Slate
  static const borderDivider   = Color(0xFFCBD5E1); // Neutral Border

  // 2. Brand & Actions
  static const primaryCTA      = Color(0xFF1D4ED8); // Executive Cobalt
  static const primaryHover    = Color(0xFF1E40AF); // Deep Cobalt
  static const primaryRing     = Color(0xFF93C5FD); // Cobalt Glow
  static const secBtnSurface   = Color(0xFFFFFFFF);
  static const secBtnBorder    = Color(0xFFCBD5E1);
  static const secBtnHover     = Color(0xFFF8FAFC);

  // 3. Typography Colors
  static const textPrimary     = Color(0xFF0F172A); // Deep Slate Navy
  static const textSecondary   = Color(0xFF334155); // Mid Slate
  static const textMuted       = Color(0xFF475569); // Cool Gray
  static const textInverse     = Color(0xFFFFFFFF); // Pure White

  // 4. Semantic Status Badges (BG / Border / Text / Dot)
  // Present / Active
  static const presentBg       = Color(0xFFECFDF5);
  static const presentBorder   = Color(0xFFA7F3D0);
  static const presentText     = Color(0xFF065F46);
  static const presentDot      = Color(0xFF10B981);

  // Late
  static const lateBg          = Color(0xFFFFFBEB);
  static const lateBorder      = Color(0xFFFDE68A);
  static const lateText        = Color(0xFF92400E);
  static const lateDot         = Color(0xFFF59E0B);

  // Absent / Inactive
  static const absentBg        = Color(0xFFFEF2F2);
  static const absentBorder    = Color(0xFFFECACA);
  static const absentText      = Color(0xFF991B1B);
  static const absentDot       = Color(0xFFEF4444);

  // On Leave / Remote
  static const leaveBg         = Color(0xFFEFF6FF);
  static const leaveBorder     = Color(0xFFBFDBFE);
  static const leaveText       = Color(0xFF1E40AF);
  static const leaveDot        = Color(0xFF3B82F6);

  // Sunday / Off Day
  static const sundayBg        = Color(0xFFF1F5F9);
  static const sundayBorder    = Color(0xFFE2E8F0);
  static const sundayText      = Color(0xFF475569);
  static const sundayDot       = Color(0xFF64748B);

  // Holiday
  static const holidayBg       = Color(0xFFFAF5FF);
  static const holidayBorder   = Color(0xFFE9D5FF);
  static const holidayText     = Color(0xFF6B21A8);
  static const holidayDot      = Color(0xFFA855F7);

  // Typography Styles
  static const pageTitle = TextStyle(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: textPrimary,
  );

  static const metricValue = TextStyle(
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: textPrimary,
  );

  static const tableHeader = TextStyle(
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.55,
    color: textMuted,
  );

  static const rowPrimary = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    color: textPrimary,
  );

  static const rowSecondary = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    color: textMuted,
  );

  static const monoData = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    color: textSecondary,
    fontFamily: 'monospace',
  );

  static const statusBadge = TextStyle(
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.22,
  );
}

class EmployeeManagementTab extends StatefulWidget {
  final String branchId;
  final String userRole;
  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final VoidCallback onAddEmployee;
  final Function(BuildContext context, String? employeeId)? onEditEmployee;
  final String departmentFilter;
  final List<Map<String, dynamic>> branches;

  const EmployeeManagementTab({
    super.key,
    required this.branchId,
    this.userRole = 'Admin',
    required this.date,
    required this.onDateChanged,
    required this.onAddEmployee,
    this.onEditEmployee,
    this.departmentFilter = 'all',
    this.branches = const [],
  });

  @override
  State<EmployeeManagementTab> createState() => _EmployeeManagementTabState();
}

class _EmployeeManagementTabState extends State<EmployeeManagementTab> {
  final Map<String, Map<String, dynamic>> _draftRecords = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedDeptFilter = 'all';
  String _searchQuery = '';
  String _statusFilter = 'all';
  StreamSubscription? _punchSubscription;

  // Calendar filter state
  late DateTime _calendarMonth;
  bool _isCalendarExpanded = false;

  @override
  void initState() {
    super.initState();
    _selectedDeptFilter = widget.departmentFilter;
    _calendarMonth = DateTime(widget.date.year, widget.date.month, 1);

    // Realtime punch listener
    _punchSubscription = ZkTecoNetworkService.punchStream.listen((punch) {
      if (mounted) setState(() {});
    });

    // Auto-sync hardware punches & firestore
    _syncPunches(widget.date);
  }

  @override
  void didUpdateWidget(covariant EmployeeManagementTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _selectedDeptFilter = 'all';
      _syncPunches(widget.date);
    } else if (oldWidget.date != widget.date) {
      _calendarMonth = DateTime(widget.date.year, widget.date.month, 1);
      _syncPunches(widget.date);
    }
    if (oldWidget.departmentFilter != widget.departmentFilter) {
      _selectedDeptFilter = widget.departmentFilter;
    }
  }

  @override
  void dispose() {
    _punchSubscription?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _syncPunches([DateTime? targetDate]) async {
    try {
      final d = targetDate ?? widget.date;
      final dateStr = DateFormat('yyyy-MM-dd').format(d);
      await FinanceLocalStorage.downloadEmployees(widget.branchId, force: true);
      await FinanceLocalStorage.downloadAttendance(widget.branchId, specificDateStr: dateStr, force: true);
      await ZkTecoNetworkService.processPendingUnmappedPunches();
      if (mounted) setState(() {});

      unawaited(Future(() async {
        try {
          await ZkTecoNetworkService.syncAllDevices();
          await ZkTecoNetworkService.syncAllRecordedAttendanceToFirestore();
          if (mounted) setState(() {});
        } catch (_) {}
      }));
    } catch (e) {
      debugPrint('[EmployeeManagementTab] _syncPunches error: $e');
    }
  }

  Future<void> _saveRecordInstantly(String empId, Map<String, dynamic> record) async {
    _draftRecords[empId] = record;
    setState(() {});
    try {
      await FinanceLocalStorage.saveAttendanceRecord(
        branchId: widget.branchId,
        data: record,
        performedBy: LocalStorageService.getActiveUsername(),
      );
    } catch (e) {
      debugPrint('[EmployeeManagementTab] saveRecord error: $e');
    }
  }

  // ── Employee Removal Helper (Local & Firestore Queue) ──────────────────────
  Future<void> _confirmWipeAllEmployees() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ExecTokens.cardSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: ExecTokens.absentDot, size: 24),
            SizedBox(width: 8),
            Text('Wipe All Employees?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: ExecTokens.textPrimary)),
          ],
        ),
        content: const Text(
          'This will delete all employees from local storage and enqueue deletion requests for Firestore sync when connected.\n\nAre you sure you want to proceed?',
          style: TextStyle(fontSize: 13, color: ExecTokens.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: ExecTokens.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: ExecTokens.absentDot,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('Delete All Staff'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final removed = await FinanceLocalStorage.deleteAllEmployeesAndEnqueue(
        performedBy: LocalStorageService.getActiveUsername(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Removed $removed employees from local storage & enqueued cloud deletes.'),
            backgroundColor: ExecTokens.primaryCTA,
          ),
        );
        setState(() {});
      }
    }
  }

  // ── Month Metrics & Attendance % Helper ────────────────────────────────────
  Map<String, dynamic> _computeEmployeeMonthStats(String empId, String monthKey) {
    try {
      final summary = FinanceLocalStorage.getPayrollAttendanceSummary(empId, monthKey);
      final totalDays = (summary['totalDays'] as num?)?.toInt() ?? 30;
      final workingDays = (summary['workingDays'] as num?)?.toDouble() ?? 0.0;
      final totalEmployed = (summary['totalEmployedDays'] as num?)?.toInt() ?? totalDays;

      // Calculate attendance percentage
      double pct = 0.0;
      if (totalEmployed > 0) {
        pct = ((workingDays / totalEmployed) * 100).clamp(0.0, 100.0);
      }

      return {
        'totalDays': totalDays,
        'workingDays': workingDays.round(),
        'employedDays': totalEmployed,
        'percentage': pct,
      };
    } catch (_) {
      return {'totalDays': 30, 'workingDays': 0, 'employedDays': 30, 'percentage': 0.0};
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('yyyy-MM-dd').format(widget.date);
    final monthKey = DateFormat('yyyy-MM').format(widget.date);

    return Scaffold(
      backgroundColor: ExecTokens.canvasBg,
      body: ValueListenableBuilder(
        valueListenable: FinanceLocalStorage.employeesBox.listenable(),
        builder: (ctx, Box empBox, _) {
          return ValueListenableBuilder(
            valueListenable: FinanceLocalStorage.attendanceBox.listenable(),
            builder: (ctx, Box attBox, _) {
              // 1. Fetch active employees
              final allEmployees = FinanceLocalStorage.getEmployees(widget.branchId).where((e) {
                final isActive = e['isActive'] as bool? ?? true;
                if (!isActive) return false;
                if (e['isDeleted'] == true || e['deleted'] == true) return false;
                final status = (e['status'] ?? e['employeeStatus'] ?? '').toString().trim().toLowerCase();
                if (status.contains('left') ||
                    status.contains('offboard') ||
                    status.contains('kick') ||
                    status.contains('terminat') ||
                    status.contains('archived') ||
                    status.contains('inactive')) {
                  return false;
                }
                return true;
              }).toList();

              // Department filter
              final filteredByDept = allEmployees.where((e) {
                if (_selectedDeptFilter != 'all') {
                  final dept = (e['department'] ?? 'Other').toString().trim();
                  if (dept.toLowerCase() != _selectedDeptFilter.toLowerCase()) return false;
                }
                return true;
              }).toList();

              // 2. Attendance database records for date
              final dbRecords = FinanceLocalStorage.getAttendanceForDate(widget.branchId, dateStr);
              final isSunday = widget.date.weekday == DateTime.sunday;

              final records = filteredByDept.map((emp) {
                final empId = (emp['localId'] ?? emp['id'] ?? '').toString();
                final altId = emp['id']?.toString() ?? '';
                final empDept = (emp['department'] ?? 'Office').toString();

                final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                final pin = cred?.biometricPin.isNotEmpty == true
                    ? cred!.biometricPin.trim()
                    : (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();

                final dbRec = dbRecords.firstWhereOrNull((r) =>
                    r['employeeId']?.toString() == empId ||
                    (altId.isNotEmpty && r['employeeId']?.toString() == altId) ||
                    (pin.isNotEmpty && (r['pin']?.toString() == pin || r['biometricPin']?.toString() == pin)));

                final isHoliday = FinanceLocalStorage.isHoliday(
                  branchId: widget.branchId,
                  department: empDept,
                  dateStr: dateStr,
                );

                final record = _draftRecords[empId] ?? Map<String, dynamic>.from(dbRec ?? {
                  'employeeId': empId,
                  'date': dateStr,
                  'status': isSunday ? 'off' : (isHoliday ? 'holiday' : 'absent'),
                  'leaveType': null,
                  'checkInTime': null,
                  'arrivalTime': null,
                  'checkOutTime': null,
                  'departureTime': null,
                  'note': isHoliday ? 'Public Holiday' : null,
                  'overtimeDuration': null,
                });

                // Detect presence if punch times exist
                final inTime = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
                final outTime = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
                final lastPunch = record['lastPunchTime']?.toString();
                final shifts = record['shifts'] is Map ? (record['shifts'] as Map) : null;
                final hasPunch = (inTime != null && inTime.isNotEmpty && inTime != '--:--') ||
                    (outTime != null && outTime.isNotEmpty && outTime != '--:--') ||
                    (lastPunch != null && lastPunch.isNotEmpty) ||
                    (shifts != null && shifts.isNotEmpty);

                if (hasPunch && record['status'] != 'late') {
                  record['status'] = 'present';
                }

                record['name'] = emp['name'] ?? 'Employee';
                record['role'] = emp['role'] ?? emp['designation'] ?? 'Staff';
                record['department'] = empDept;
                record['pin'] = pin;
                record['shiftHours'] = emp['shiftHours'] ?? emp['workingHours'] ?? '09:00 - 17:00';
                return record;
              }).toList();

              // Compute Summary Counts
              int presentCount = 0, lateCount = 0, leaveCount = 0, absentCount = 0, holidayCount = 0;
              for (final r in records) {
                final s = (r['status']?.toString() ?? 'absent').toLowerCase();
                if (s == 'present') {
                  presentCount++;
                } else if (s == 'late') {
                  lateCount++;
                } else if (s == 'leave') {
                  leaveCount++;
                } else if (s == 'holiday') {
                  holidayCount++;
                } else if (s == 'absent') {
                  absentCount++;
                }
              }

              // Filter by Status & Search Query
              final visibleRecords = records.where((r) {
                if (_statusFilter != 'all') {
                  final s = (r['status']?.toString() ?? '').toLowerCase();
                  if (_statusFilter == 'present' && s != 'present') return false;
                  if (_statusFilter == 'late' && s != 'late') return false;
                  if (_statusFilter == 'leave' && s != 'leave') return false;
                  if (_statusFilter == 'absent' && s != 'absent') return false;
                  if (_statusFilter == 'holiday' && s != 'holiday') return false;
                }
                if (_searchQuery.isNotEmpty) {
                  final q = _searchQuery.toLowerCase();
                  final name = (r['name'] ?? '').toString().toLowerCase();
                  final role = (r['role'] ?? '').toString().toLowerCase();
                  final dept = (r['department'] ?? '').toString().toLowerCase();
                  final pin = (r['pin'] ?? '').toString().toLowerCase();
                  if (!name.contains(q) && !role.contains(q) && !dept.contains(q) && !pin.contains(q)) {
                    return false;
                  }
                }
                return true;
              }).toList();

              return Column(
                children: [
                  _buildHeaderToolbar(allEmployees.length),
                  if (_isCalendarExpanded)
                    _buildInteractiveCalendarFilter(
                      monthKey: monthKey,
                      totalStaff: allEmployees.length,
                      present: presentCount,
                      late: lateCount,
                      leave: leaveCount,
                      absent: absentCount,
                      holiday: holidayCount,
                      isSunday: isSunday,
                    )
                  else
                    _buildCompactDateAndKPIStrip(
                      totalStaff: allEmployees.length,
                      present: presentCount,
                      late: lateCount,
                      leave: leaveCount,
                      absent: absentCount,
                      holiday: holidayCount,
                      isSunday: isSunday,
                    ),
                  _buildCrossBranchBanner(dateStr),
                  _buildUnmappedPunchesBanner(),
                  Expanded(
                    child: _buildRosterList(visibleRecords, monthKey, isSunday),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ── Header Toolbar ────────────────────────────────────────────────────────
  Widget _buildHeaderToolbar(int totalStaffCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: ExecTokens.cardSurface,
        border: Border(bottom: BorderSide(color: ExecTokens.borderMuted)),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isWide = constraints.maxWidth >= 900;

        final searchAndCalendarToggle = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search Input
            Container(
              width: 250,
              height: 36,
              decoration: BoxDecoration(
                color: ExecTokens.canvasBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: ExecTokens.borderMuted),
              ),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 12, color: ExecTokens.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search by name, PIN, role...',
                  hintStyle: const TextStyle(fontSize: 12, color: ExecTokens.textMuted),
                  prefixIcon: const Icon(Icons.search_rounded, size: 16, color: ExecTokens.textMuted),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.close_rounded, size: 14, color: ExecTokens.textMuted),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
            const SizedBox(width: 8),

            // Calendar Expand/Collapse Filter Button
            OutlinedButton.icon(
              onPressed: () => setState(() => _isCalendarExpanded = !_isCalendarExpanded),
              icon: Icon(
                _isCalendarExpanded ? Icons.calendar_month_rounded : Icons.calendar_today_outlined,
                size: 15,
                color: _isCalendarExpanded ? ExecTokens.primaryCTA : ExecTokens.textSecondary,
              ),
              label: Text(
                _isCalendarExpanded ? 'Hide Calendar' : 'Calendar Filter',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _isCalendarExpanded ? ExecTokens.primaryCTA : ExecTokens.textSecondary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: _isCalendarExpanded ? ExecTokens.rowSelected : ExecTokens.secBtnSurface,
                side: BorderSide(color: _isCalendarExpanded ? ExecTokens.primaryRing : ExecTokens.secBtnBorder),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ],
        );

        final actionButtons = Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Leave Range
            OutlinedButton.icon(
              onPressed: () => _openLeaveRangeDialog(),
              icon: const Icon(Icons.date_range_outlined, size: 14, color: ExecTokens.textSecondary),
              label: const Text('Leave Range', style: TextStyle(fontSize: 12, color: ExecTokens.textSecondary)),
              style: OutlinedButton.styleFrom(
                backgroundColor: ExecTokens.secBtnSurface,
                side: const BorderSide(color: ExecTokens.secBtnBorder),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),

            // Monthly Grid
            OutlinedButton.icon(
              onPressed: () {
                final t = RoleThemeScope.dataOf(context);
                BulkAttendanceDialog.open(
                  context: context,
                  branchId: widget.branchId,
                  theme: t,
                  onSaved: () => setState(() {}),
                );
              },
              icon: const Icon(Icons.table_chart_outlined, size: 14, color: ExecTokens.textSecondary),
              label: const Text('Monthly Grid', style: TextStyle(fontSize: 12, color: ExecTokens.textSecondary)),
              style: OutlinedButton.styleFrom(
                backgroundColor: ExecTokens.secBtnSurface,
                side: const BorderSide(color: ExecTokens.secBtnBorder),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),

            // Biometric PINs
            OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => BiometricDeviceManagerPage(branchId: widget.branchId)),
                );
              },
              icon: const Icon(Icons.fingerprint_rounded, size: 14, color: ExecTokens.textSecondary),
              label: const Text('Biometric PINs', style: TextStyle(fontSize: 12, color: ExecTokens.textSecondary)),
              style: OutlinedButton.styleFrom(
                backgroundColor: ExecTokens.secBtnSurface,
                side: const BorderSide(color: ExecTokens.secBtnBorder),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),

            // Wipe All Staff (User Request)
            if (totalStaffCount > 0)
              OutlinedButton.icon(
                onPressed: _confirmWipeAllEmployees,
                icon: const Icon(Icons.delete_sweep_outlined, size: 14, color: ExecTokens.absentDot),
                label: const Text('Wipe Staff', style: TextStyle(fontSize: 12, color: ExecTokens.absentDot)),
                style: OutlinedButton.styleFrom(
                  backgroundColor: ExecTokens.absentBg,
                  side: const BorderSide(color: ExecTokens.absentBorder),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),

            // Primary CTA: Register Employee
            ElevatedButton.icon(
              onPressed: widget.onAddEmployee,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
              label: const Text('Register Employee', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: ExecTokens.primaryCTA,
                foregroundColor: ExecTokens.textInverse,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ],
        );

        if (!isWide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchAndCalendarToggle,
              const SizedBox(height: 10),
              actionButtons,
            ],
          );
        }

        return Row(
          children: [
            searchAndCalendarToggle,
            const Spacer(),
            actionButtons,
          ],
        );
      }),
    );
  }

  // ── Compact Date Navigator & Live Status Strip (When Calendar is Collapsed) ─
  Widget _buildCompactDateAndKPIStrip({
    required int totalStaff,
    required int present,
    required int late,
    required int leave,
    required int absent,
    required int holiday,
    required bool isSunday,
  }) {
    final dateTitle = DateFormat('EEE, d MMM yyyy').format(widget.date);

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 6, 24, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: ExecTokens.cardSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ExecTokens.borderMuted),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isWide = constraints.maxWidth >= 850;

        final dateNavigator = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.chevron_left_rounded, size: 20, color: ExecTokens.textSecondary),
              tooltip: 'Previous Day',
              onPressed: () {
                _draftRecords.clear();
                widget.onDateChanged(widget.date.subtract(const Duration(days: 1)));
              },
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isSunday ? ExecTokens.lateBg : ExecTokens.rowSelected,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: isSunday ? ExecTokens.lateBorder : ExecTokens.primaryRing),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSunday ? Icons.weekend_outlined : Icons.calendar_today_rounded,
                    size: 13,
                    color: isSunday ? ExecTokens.lateText : ExecTokens.primaryCTA,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isSunday ? '$dateTitle (Sunday Off)' : dateTitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isSunday ? ExecTokens.lateText : ExecTokens.primaryCTA,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.chevron_right_rounded, size: 20, color: ExecTokens.textSecondary),
              tooltip: 'Next Day',
              onPressed: () {
                _draftRecords.clear();
                widget.onDateChanged(widget.date.add(const Duration(days: 1)));
              },
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () {
                _draftRecords.clear();
                final now = DateTime.now();
                setState(() => _calendarMonth = DateTime(now.year, now.month, 1));
                widget.onDateChanged(now);
              },
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ExecTokens.rowHover,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: ExecTokens.borderMuted),
                ),
                child: const Text('Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ExecTokens.textPrimary)),
              ),
            ),
          ],
        );

        final filterPills = Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _statusFilterPill('All Staff', '$totalStaff', 'all', ExecTokens.textSecondary, ExecTokens.canvasBg, ExecTokens.borderMuted),
            _statusFilterPill('Present', '$present', 'present', ExecTokens.presentText, ExecTokens.presentBg, ExecTokens.presentBorder),
            if (late > 0)
              _statusFilterPill('Late', '$late', 'late', ExecTokens.lateText, ExecTokens.lateBg, ExecTokens.lateBorder),
            if (leave > 0)
              _statusFilterPill('On Leave', '$leave', 'leave', ExecTokens.leaveText, ExecTokens.leaveBg, ExecTokens.leaveBorder),
            _statusFilterPill('Absent', '$absent', 'absent', ExecTokens.absentText, ExecTokens.absentBg, ExecTokens.absentBorder),
            if (holiday > 0)
              _statusFilterPill('Holiday', '$holiday', 'holiday', ExecTokens.holidayText, ExecTokens.holidayBg, ExecTokens.holidayBorder),
          ],
        );

        if (!isWide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dateNavigator,
              const SizedBox(height: 6),
              filterPills,
            ],
          );
        }

        return Row(
          children: [
            dateNavigator,
            const SizedBox(width: 14),
            Expanded(child: filterPills),
          ],
        );
      }),
    );
  }

  // ── Executive Side-by-Side Calendar & Analytics Panel (When Expanded) ────────
  Widget _buildInteractiveCalendarFilter({
    required String monthKey,
    required int totalStaff,
    required int present,
    required int late,
    required int leave,
    required int absent,
    required int holiday,
    required bool isSunday,
  }) {
    final daysInMonth = DateUtils.getDaysInMonth(_calendarMonth.year, _calendarMonth.month);
    final firstWeekday = DateTime(_calendarMonth.year, _calendarMonth.month, 1).weekday; // 1 = Mon, 7 = Sun
    final monthTitle = DateFormat('MMMM yyyy').format(_calendarMonth);

    // Compute month metrics
    int totalWorkingDays = 0, totalSundays = 0, totalHolidays = 0;
    for (int d = 1; d <= daysInMonth; d++) {
      final date = DateTime(_calendarMonth.year, _calendarMonth.month, d);
      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      final isSun = date.weekday == DateTime.sunday;
      final isHol = FinanceLocalStorage.isHoliday(
        branchId: widget.branchId,
        department: 'all',
        dateStr: dateStr,
      );

      if (isSun) {
        totalSundays++;
      } else if (isHol) {
        totalHolidays++;
      } else {
        totalWorkingDays++;
      }
    }

    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 6, 24, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ExecTokens.cardSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ExecTokens.borderMuted),
        boxShadow: const [BoxShadow(color: Color(0x04000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isDesktop = constraints.maxWidth >= 900;

        // Calendar component (compact, width 320)
        final calendarBlock = SizedBox(
          width: isDesktop ? 320 : double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.calendar_month_outlined, size: 16, color: ExecTokens.primaryCTA),
                  const SizedBox(width: 6),
                  Text(monthTitle, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ExecTokens.textPrimary)),
                  const Spacer(),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    icon: const Icon(Icons.chevron_left_rounded, size: 18, color: ExecTokens.textSecondary),
                    onPressed: () {
                      setState(() {
                        _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
                      });
                    },
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    icon: const Icon(Icons.chevron_right_rounded, size: 18, color: ExecTokens.textSecondary),
                    onPressed: () {
                      setState(() {
                        _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1, 1);
                      });
                    },
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      final now = DateTime.now();
                      setState(() => _calendarMonth = DateTime(now.year, now.month, 1));
                      _draftRecords.clear();
                      widget.onDateChanged(now);
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: ExecTokens.rowHover,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: ExecTokens.borderMuted),
                      ),
                      child: const Text('Today', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ExecTokens.textPrimary)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Weekdays
              Row(
                children: weekdays.map((w) {
                  final isSun = w == 'Sun';
                  return Expanded(
                    child: Center(
                      child: Text(
                        w.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isSun ? ExecTokens.lateText : ExecTokens.textMuted,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 4),
              // Grid
              Builder(builder: (c) {
                final List<Widget> dayWidgets = [];
                for (int i = 1; i < firstWeekday; i++) {
                  dayWidgets.add(const SizedBox.shrink());
                }
                for (int d = 1; d <= daysInMonth; d++) {
                  final dayDate = DateTime(_calendarMonth.year, _calendarMonth.month, d);
                  final dayDateStr = DateFormat('yyyy-MM-dd').format(dayDate);
                  final isSelected = widget.date.year == dayDate.year &&
                      widget.date.month == dayDate.month &&
                      widget.date.day == dayDate.day;
                  final isSun = dayDate.weekday == DateTime.sunday;
                  final isHol = FinanceLocalStorage.isHoliday(
                    branchId: widget.branchId,
                    department: 'all',
                    dateStr: dayDateStr,
                  );

                  dayWidgets.add(
                    InkWell(
                      onTap: () {
                        _draftRecords.clear();
                        widget.onDateChanged(dayDate);
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? ExecTokens.primaryCTA
                              : (isHol
                                  ? ExecTokens.holidayBg
                                  : (isSun ? ExecTokens.sundayBg : Colors.transparent)),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isSelected
                                ? ExecTokens.primaryRing
                                : (isHol
                                    ? ExecTokens.holidayBorder
                                    : (isSun ? ExecTokens.sundayBorder : Colors.transparent)),
                            width: isSelected ? 1.2 : 0.8,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$d',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected
                                ? ExecTokens.textInverse
                                : (isHol
                                    ? ExecTokens.holidayText
                                    : (isSun ? ExecTokens.lateText : ExecTokens.textPrimary)),
                          ),
                        ),
                      ),
                    ),
                  );
                }

                return GridView.count(
                  crossAxisCount: 7,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.4,
                  children: dayWidgets,
                );
              }),
            ],
          ),
        );

        // Analytics & Filter component
        final analyticsBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined, size: 15, color: ExecTokens.textSecondary),
                const SizedBox(width: 6),
                Text('$monthTitle Overview', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ExecTokens.textPrimary)),
                const Spacer(),
                IconButton(
                  tooltip: 'Hide Calendar',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: const Icon(Icons.close_rounded, size: 18, color: ExecTokens.textMuted),
                  onPressed: () => setState(() => _isCalendarExpanded = false),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Metric cards in a row
            Row(
              children: [
                Expanded(child: _metricCard('Total Days', '$daysInMonth', 'Month cycle', ExecTokens.textPrimary, ExecTokens.canvasBg, ExecTokens.borderMuted)),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Working Days', '$totalWorkingDays', 'Schedule', ExecTokens.presentText, ExecTokens.presentBg, ExecTokens.presentBorder)),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Sundays', '$totalSundays', 'Off days', ExecTokens.lateText, ExecTokens.lateBg, ExecTokens.lateBorder)),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Holidays', '$totalHolidays', 'Public/Gazetted', ExecTokens.holidayText, ExecTokens.holidayBg, ExecTokens.holidayBorder)),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: ExecTokens.borderMuted, height: 1),
            const SizedBox(height: 8),
            // Today / Selected Date Status Filter Pills
            Row(
              children: [
                Text(
                  '${DateFormat("EEE, d MMM").format(widget.date)} Live:',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: ExecTokens.textSecondary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _statusFilterPill('All Staff', '$totalStaff', 'all', ExecTokens.textSecondary, ExecTokens.canvasBg, ExecTokens.borderMuted),
                      _statusFilterPill('Present', '$present', 'present', ExecTokens.presentText, ExecTokens.presentBg, ExecTokens.presentBorder),
                      if (late > 0)
                        _statusFilterPill('Late', '$late', 'late', ExecTokens.lateText, ExecTokens.lateBg, ExecTokens.lateBorder),
                      if (leave > 0)
                        _statusFilterPill('On Leave', '$leave', 'leave', ExecTokens.leaveText, ExecTokens.leaveBg, ExecTokens.leaveBorder),
                      _statusFilterPill('Absent', '$absent', 'absent', ExecTokens.absentText, ExecTokens.absentBg, ExecTokens.absentBorder),
                      if (holiday > 0)
                        _statusFilterPill('Holiday', '$holiday', 'holiday', ExecTokens.holidayText, ExecTokens.holidayBg, ExecTokens.holidayBorder),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );

        if (!isDesktop) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              calendarBlock,
              const SizedBox(height: 12),
              const Divider(color: ExecTokens.borderMuted, height: 1),
              const SizedBox(height: 10),
              analyticsBlock,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            calendarBlock,
            const SizedBox(width: 16),
            const SizedBox(height: 200, child: VerticalDivider(color: ExecTokens.borderMuted, width: 1)),
            const SizedBox(width: 16),
            Expanded(child: analyticsBlock),
          ],
        );
      }),
    );
  }

  Widget _metricCard(String label, String value, String subtitle, Color color, Color bg, Color border) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ExecTokens.textMuted)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.3)),
          const SizedBox(height: 1),
          Text(subtitle, style: TextStyle(fontSize: 9.5, color: color.withValues(alpha: 0.8))),
        ],
      ),
    );
  }

  Widget _statusFilterPill(String label, String count, String filterKey, Color textColor, Color bg, Color border) {
    final isSelected = _statusFilter == filterKey;
    return InkWell(
      onTap: () => setState(() => _statusFilter = isSelected && filterKey != 'all' ? 'all' : filterKey),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? ExecTokens.rowSelected : bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? ExecTokens.primaryCTA : border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, color: textColor)),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected ? ExecTokens.primaryCTA : textColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                count,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: isSelected ? Colors.white : textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Unmapped Punches Banner ───────────────────────────────────────────────
  Widget _buildUnmappedPunchesBanner() {
    if (!Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) return const SizedBox.shrink();

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.unmappedPunchesBox).listenable(),
      builder: (context, box, _) {
        final unmappedList = ZkTecoNetworkService.getUnmappedPunches();
        if (unmappedList.isEmpty) return const SizedBox.shrink();

        final uniquePins = unmappedList.map((p) => p['pin']?.toString() ?? '').where((p) => p.isNotEmpty).toSet().toList();

        return Container(
          margin: const EdgeInsets.fromLTRB(24, 4, 24, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: ExecTokens.absentBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ExecTokens.absentBorder),
          ),
          child: Row(
            children: [
              const Icon(Icons.fingerprint_rounded, color: ExecTokens.absentDot, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${unmappedList.length} Unmapped Biometric Scans Detected (PINs: ${uniquePins.join(", ")})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ExecTokens.absentText),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final assigned = await ZkTecoNetworkService.bulkAutoAssignBiometricPins();
                  final remapped = await ZkTecoNetworkService.processPendingUnmappedPunches();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('✅ Auto-assigned $assigned PINs and routed $remapped punches!'), backgroundColor: ExecTokens.presentDot),
                    );
                    setState(() {});
                  }
                },
                icon: const Icon(Icons.auto_fix_high_rounded, size: 13, color: ExecTokens.absentText),
                label: const Text('Auto-Route', style: TextStyle(fontSize: 11, color: ExecTokens.absentText, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: ExecTokens.absentBorder),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Cross-Branch Punch Banner ─────────────────────────────────────────────
  Widget _buildCrossBranchBanner(String dateStr) {
    if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) return const SizedBox.shrink();

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.crossBranchPunchesBox).listenable(),
      builder: (context, box, _) {
        final pendingList = ZkTecoNetworkService.getPendingCrossBranchPunches(
          branchId: widget.branchId,
          dateStr: dateStr,
        );
        if (pendingList.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(24, 4, 24, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: ExecTokens.lateBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ExecTokens.lateBorder),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, color: ExecTokens.lateDot, size: 18),
              const SizedBox(width: 8),
              Text(
                'Cross-Branch Approvals (${pendingList.length} Pending)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ExecTokens.lateText),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: () async {
                  for (final p in pendingList) {
                    await ZkTecoNetworkService.approveCrossBranchPunch(
                      pendingId: p['id']?.toString() ?? '',
                      reviewerName: LocalStorageService.getActiveUsername(),
                    );
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('✅ Approved cross-branch punches!'), backgroundColor: ExecTokens.presentDot),
                    );
                    setState(() {});
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ExecTokens.lateDot,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                child: const Text('Approve All', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Table Column Headers (11px, Semi-Bold, Caps, +0.05em, Text-Muted) ─────
  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: ExecTokens.canvasBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        border: Border(bottom: BorderSide(color: ExecTokens.borderMuted)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 36), // avatar space
          SizedBox(width: 12),
          Expanded(flex: 3, child: Text('EMPLOYEE', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('DEPARTMENT', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('WORKING HOURS', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('CLOCK IN / OUT', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('DURATION', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('STATUS', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('ATTENDANCE % & DAYS', style: ExecTokens.tableHeader)),
          Expanded(flex: 2, child: Text('NOTES', style: ExecTokens.tableHeader)),
          SizedBox(width: 36), // 3 dots
        ],
      ),
    );
  }

  // ── Roster Table / List (Matching Screenshot Design) ───────────────────────
  Widget _buildRosterList(List<Map<String, dynamic>> records, String monthKey, bool isSunday) {
    if (records.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(24, 6, 24, 16),
        decoration: BoxDecoration(
          color: ExecTokens.cardSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ExecTokens.borderMuted),
        ),
        child: Column(
          children: [
            _buildTableHeader(),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: const BoxDecoration(color: ExecTokens.rowHover, shape: BoxShape.circle),
                          child: const Icon(Icons.people_outline_rounded, size: 28, color: ExecTokens.textMuted),
                        ),
                        const SizedBox(height: 10),
                        const Text('No employees found', style: ExecTokens.pageTitle),
                        const SizedBox(height: 4),
                        const Text('Add a new employee to get started or adjust your filters.', style: ExecTokens.rowSecondary),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: widget.onAddEmployee,
                          icon: const Icon(Icons.person_add_alt_1_rounded, size: 14),
                          label: const Text('Register Employee', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ExecTokens.primaryCTA,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 6, 24, 16),
      decoration: BoxDecoration(
        color: ExecTokens.cardSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ExecTokens.borderMuted),
      ),
      child: Column(
        children: [
          _buildTableHeader(),
          // Scrollable List of Rows
          Expanded(
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (c, i) => const Divider(color: ExecTokens.borderDivider, height: 1, thickness: 0.5),
              itemBuilder: (ctx, idx) {
                final r = records[idx];
                return _buildEmployeeRow(r, monthKey, isSunday);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeRow(Map<String, dynamic> record, String monthKey, bool isSunday) {
    final empId = record['employeeId']?.toString() ?? '';
    final name = record['name']?.toString() ?? 'Employee';
    final role = record['role']?.toString() ?? 'Staff';
    final dept = record['department']?.toString() ?? 'Office';
    final pin = record['pin']?.toString() ?? '';
    final shiftHours = record['shiftHours']?.toString() ?? '09:00 - 17:00';
    final inTime = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
    final outTime = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
    final status = (record['status']?.toString() ?? 'absent').toLowerCase();
    final note = record['note']?.toString() ?? '';

    // Calculate duration
    String duration = '0h';
    if (inTime != null && inTime.isNotEmpty && inTime != '--:--') {
      if (outTime != null && outTime.isNotEmpty && outTime != '--:--') {
        duration = _computeDuration(inTime, outTime);
      } else {
        duration = 'Running';
      }
    }

    // Monthly stats
    final stats = _computeEmployeeMonthStats(empId, monthKey);
    final double pct = stats['percentage'] as double;
    final int workedDays = stats['workingDays'] as int;
    final int totalDays = stats['totalDays'] as int;

    return InkWell(
      hoverColor: ExecTokens.rowHover,
      onTap: () => _openEmployeeProfile(empId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Avatar Circle
            CircleAvatar(
              radius: 17,
              backgroundColor: ExecTokens.rowSelected,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA),
              ),
            ),
            const SizedBox(width: 12),

            // Employee Name, Designation, PIN
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: ExecTokens.rowPrimary),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(role, style: ExecTokens.rowSecondary),
                      const SizedBox(width: 6),
                      // PIN Chip
                      InkWell(
                        onTap: () => _editBiometricPin(empId, name, pin),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: pin.isNotEmpty ? ExecTokens.rowSelected : ExecTokens.absentBg,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                              color: pin.isNotEmpty ? ExecTokens.leaveBorder : ExecTokens.absentBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            pin.isNotEmpty ? 'PIN $pin' : 'Set PIN',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: pin.isNotEmpty ? ExecTokens.primaryCTA : ExecTokens.absentText,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Department
            Expanded(
              flex: 2,
              child: Text(dept, style: ExecTokens.rowSecondary),
            ),

            // Working Hours (Shift)
            Expanded(
              flex: 2,
              child: Text(shiftHours, style: ExecTokens.monoData),
            ),

            // Clock In / Clock Out
            Expanded(
              flex: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Check In
                  InkWell(
                    onTap: () => _pickTime(context, (t) async {
                      record['checkInTime'] = t;
                      record['arrivalTime'] = t;
                      await _saveRecordInstantly(empId, record);
                    }),
                    child: Text(
                      inTime != null && inTime.isNotEmpty ? inTime : '-- : --',
                      style: ExecTokens.monoData.copyWith(
                        color: (inTime != null && inTime.isNotEmpty && inTime != '--:--')
                            ? ExecTokens.presentText
                            : ExecTokens.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Text('  ', style: TextStyle(color: ExecTokens.textMuted)),
                  // Check Out
                  InkWell(
                    onTap: () => _pickTime(context, (t) async {
                      record['checkOutTime'] = t;
                      record['departureTime'] = t;
                      await _saveRecordInstantly(empId, record);
                    }),
                    child: Text(
                      outTime != null && outTime.isNotEmpty ? outTime : '-- : --',
                      style: ExecTokens.monoData.copyWith(
                        color: (outTime != null && outTime.isNotEmpty && outTime != '--:--')
                            ? ExecTokens.primaryCTA
                            : ExecTokens.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Work Duration
            Expanded(
              flex: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (duration == 'Running') ...[
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 5),
                      decoration: const BoxDecoration(color: ExecTokens.presentDot, shape: BoxShape.circle),
                    ),
                    const Text('Running', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ExecTokens.presentText)),
                  ] else ...[
                    Text(duration, style: ExecTokens.rowSecondary),
                  ],
                ],
              ),
            ),

            // Semantic Status Badge (Matching Screenshot)
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildStatusPill(status, empId, record, isSunday),
              ),
            ),

            // Attendance % & Total Days
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: pct >= 85 ? ExecTokens.presentBg : (pct >= 60 ? ExecTokens.lateBg : ExecTokens.absentBg),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: pct >= 85 ? ExecTokens.presentBorder : (pct >= 60 ? ExecTokens.lateBorder : ExecTokens.absentBorder),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      '${pct.toStringAsFixed(0)}% Att.',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: pct >= 85 ? ExecTokens.presentText : (pct >= 60 ? ExecTokens.lateText : ExecTokens.absentText),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('$workedDays / $totalDays Days', style: const TextStyle(fontSize: 10.5, color: ExecTokens.textMuted)),
                ],
              ),
            ),

            // Quick Note
            Expanded(
              flex: 2,
              child: InkWell(
                onTap: () => _editNoteDialog(empId, record),
                child: Text(
                  note.isNotEmpty ? note : 'Add Note',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: note.isNotEmpty ? ExecTokens.textPrimary : ExecTokens.textMuted,
                    fontStyle: note.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ),

            // 3-Dots Actions Menu
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 18, color: ExecTokens.textMuted),
              color: ExecTokens.cardSurface,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (val) async {
                if (val == 'profile') {
                  _openEmployeeProfile(empId);
                } else if (val == 'edit') {
                  widget.onEditEmployee?.call(context, empId);
                } else if (val == 'pin') {
                  _editBiometricPin(empId, name, pin);
                } else if (val == 'mark_present') {
                  record['status'] = 'present';
                  record['leaveType'] = null;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_absent') {
                  record['status'] = 'absent';
                  record['checkInTime'] = null;
                  record['checkOutTime'] = null;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_leave') {
                  record['status'] = 'leave';
                  record['leaveType'] = 'paid';
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'offboard') {
                  _offboardEmployee(empId);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(children: [
                    Icon(Icons.badge_outlined, size: 16, color: ExecTokens.primaryCTA),
                    SizedBox(width: 8),
                    Text('View Profile & History', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 16, color: ExecTokens.textSecondary),
                    SizedBox(width: 8),
                    Text('Edit Details', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'pin',
                  child: Row(children: [
                    Icon(Icons.fingerprint_rounded, size: 16, color: ExecTokens.textSecondary),
                    SizedBox(width: 8),
                    Text('Change Biometric PIN', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuDivider(height: 1),
                const PopupMenuItem(
                  value: 'mark_present',
                  child: Row(children: [
                    Icon(Icons.check_circle_outline_rounded, size: 16, color: ExecTokens.presentDot),
                    SizedBox(width: 8),
                    Text('Mark Present', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'mark_absent',
                  child: Row(children: [
                    Icon(Icons.cancel_outlined, size: 16, color: ExecTokens.absentDot),
                    SizedBox(width: 8),
                    Text('Mark Absent', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'mark_leave',
                  child: Row(children: [
                    Icon(Icons.time_to_leave_outlined, size: 16, color: ExecTokens.leaveDot),
                    SizedBox(width: 8),
                    Text('Mark On Leave', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuDivider(height: 1),
                const PopupMenuItem(
                  value: 'offboard',
                  child: Row(children: [
                    Icon(Icons.person_remove_outlined, size: 16, color: ExecTokens.absentDot),
                    SizedBox(width: 8),
                    Text('Offboard / Terminate', style: TextStyle(fontSize: 12.5, color: ExecTokens.absentDot)),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Status Pill Widget ────────────────────────────────────────────────────
  Widget _buildStatusPill(String status, String empId, Map<String, dynamic> record, bool isSunday) {
    Color bg, border, text, dot;
    String label;

    switch (status) {
      case 'present':
        bg = ExecTokens.presentBg;
        border = ExecTokens.presentBorder;
        text = ExecTokens.presentText;
        dot = ExecTokens.presentDot;
        label = 'PRESENT';
        break;
      case 'late':
        bg = ExecTokens.lateBg;
        border = ExecTokens.lateBorder;
        text = ExecTokens.lateText;
        dot = ExecTokens.lateDot;
        label = 'LATE';
        break;
      case 'leave':
        bg = ExecTokens.leaveBg;
        border = ExecTokens.leaveBorder;
        text = ExecTokens.leaveText;
        dot = ExecTokens.leaveDot;
        label = 'ON LEAVE';
        break;
      case 'holiday':
        bg = ExecTokens.holidayBg;
        border = ExecTokens.holidayBorder;
        text = ExecTokens.holidayText;
        dot = ExecTokens.holidayDot;
        label = 'HOLIDAY';
        break;
      case 'off':
        bg = ExecTokens.sundayBg;
        border = ExecTokens.sundayBorder;
        text = ExecTokens.sundayText;
        dot = ExecTokens.sundayDot;
        label = 'OFF DAY';
        break;
      case 'absent':
      default:
        bg = ExecTokens.absentBg;
        border = ExecTokens.absentBorder;
        text = ExecTokens.absentText;
        dot = ExecTokens.absentDot;
        label = 'ABSENT';
        break;
    }

    return PopupMenuButton<String>(
      tooltip: 'Change status',
      color: ExecTokens.cardSurface,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onSelected: (newStatus) async {
        setState(() {
          record['status'] = newStatus;
          if (newStatus == 'present') {
            record['leaveType'] = null;
            if (record['checkInTime'] == null) {
              record['checkInTime'] = DateFormat('hh:mm a').format(DateTime.now());
            }
          } else if (newStatus == 'absent') {
            record['checkInTime'] = null;
            record['checkOutTime'] = null;
          }
        });
        await _saveRecordInstantly(empId, record);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'present', child: Text('● PRESENT', style: TextStyle(color: ExecTokens.presentText, fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'late', child: Text('● LATE', style: TextStyle(color: ExecTokens.lateText, fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'leave', child: Text('● ON LEAVE', style: TextStyle(color: ExecTokens.leaveText, fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'absent', child: Text('● ABSENT', style: TextStyle(color: ExecTokens.absentText, fontWeight: FontWeight.bold, fontSize: 12))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(label, style: ExecTokens.statusBadge.copyWith(color: text, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // ── Modals & Dialogs ──────────────────────────────────────────────────────
  void _openEmployeeProfile(String empId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeDetailPage(
          employeeId: empId,
          userRole: widget.userRole,
          openEmployeeForm: widget.onEditEmployee,
        ),
      ),
    );
  }

  void _editBiometricPin(String empId, String empName, String currentPin) {
    final ctrl = TextEditingController(text: currentPin);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ExecTokens.cardSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.fingerprint_rounded, color: ExecTokens.primaryCTA, size: 22),
            const SizedBox(width: 8),
            Text('Biometric PIN - $empName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ExecTokens.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the hardware User ID / PIN registered for this employee on the physical ZKTeco machine.',
              style: TextStyle(fontSize: 12, color: ExecTokens.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'ZKTeco Hardware PIN',
                filled: true,
                fillColor: ExecTokens.canvasBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: ExecTokens.borderMuted)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: ExecTokens.borderMuted)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: ExecTokens.textMuted))),
          ElevatedButton(
            onPressed: () async {
              final newPin = ctrl.text.trim();
              if (newPin.isEmpty) return;
              Navigator.pop(ctx);

              await ZkTecoNetworkService.mapPinToEntity(
                pin: newPin,
                entityId: empId,
                entityName: empName,
                entityType: 'employee',
                branchId: widget.branchId,
              );

              final emp = FinanceLocalStorage.getEmployee(empId);
              if (emp != null) {
                emp['biometricPin'] = newPin;
                emp['pin'] = newPin;
                await FinanceLocalStorage.saveEmployee(
                  branchId: emp['branchId']?.toString() ?? widget.branchId,
                  data: emp,
                  performedBy: LocalStorageService.getActiveUsername(),
                );
              }

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ PIN $newPin assigned to $empName!'), backgroundColor: ExecTokens.primaryCTA),
                );
                setState(() {});
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: Colors.white),
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
  }

  void _editNoteDialog(String empId, Map<String, dynamic> record) {
    final ctrl = TextEditingController(text: record['note']?.toString() ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ExecTokens.cardSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Attendance Remarks', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ExecTokens.textPrimary)),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter reason, late notes, or remarks...',
            filled: true,
            fillColor: ExecTokens.canvasBg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: ExecTokens.borderMuted)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: ExecTokens.textMuted))),
          ElevatedButton(
            onPressed: () async {
              record['note'] = ctrl.text.trim();
              Navigator.pop(ctx);
              await _saveRecordInstantly(empId, record);
            },
            style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _offboardEmployee(String empId) {
    final emp = FinanceLocalStorage.getEmployee(empId);
    if (emp == null) return;
    OffboardDialog.show(
      context,
      employeeData: emp,
      performedBy: LocalStorageService.getActiveUsername(),
      onOffboarded: () {
        if (mounted) setState(() {});
      },
    );
  }

  void _openLeaveRangeDialog() {
    DateTimeRange? range;
    String selectedEmpId = 'all';
    String leaveType = 'casual';

    final employees = FinanceLocalStorage.getEmployees(widget.branchId).where((e) => e['isActive'] == true).toList();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: ExecTokens.cardSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Row(
            children: [
              Icon(Icons.date_range_outlined, color: ExecTokens.primaryCTA),
              SizedBox(width: 8),
              Text('Mark Leave Range', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select Staff Member', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: selectedEmpId,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: ExecTokens.canvasBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: ExecTokens.borderMuted)),
                ),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All Employees')),
                  ...employees.map((e) => DropdownMenuItem(
                    value: (e['localId'] ?? e['id']).toString(),
                    child: Text(e['name']?.toString() ?? 'Staff'),
                  )),
                ],
                onChanged: (v) { if (v != null) setS(() => selectedEmpId = v); },
              ),
              const SizedBox(height: 12),
              const Text('Date Range', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2025),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setS(() => range = picked);
                },
                icon: const Icon(Icons.calendar_today_rounded, size: 14),
                label: Text(
                  range == null
                      ? 'Pick Date Range'
                      : '${DateFormat('d MMM').format(range!.start)} - ${DateFormat('d MMM yyyy').format(range!.end)}',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: range == null ? null : () async {
                Navigator.pop(ctx);
                final cur = range!.start;
                final end = range!.end;
                final targets = selectedEmpId == 'all'
                    ? employees
                    : employees.where((e) => (e['localId'] ?? e['id']).toString() == selectedEmpId).toList();

                for (var d = cur; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
                  final dStr = DateFormat('yyyy-MM-dd').format(d);
                  for (final emp in targets) {
                    final eId = (emp['localId'] ?? emp['id']).toString();
                    await FinanceLocalStorage.saveAttendanceRecord(
                      branchId: widget.branchId,
                      data: {
                        'employeeId': eId,
                        'date': dStr,
                        'status': 'leave',
                        'leaveType': leaveType,
                      },
                      performedBy: LocalStorageService.getActiveUsername(),
                    );
                  }
                }
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Leave marked for range!'), backgroundColor: ExecTokens.presentDot),
                );
                if (mounted) {
                  setState(() {});
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: Colors.white),
              child: const Text('Apply Leaves'),
            ),
          ],
        ),
      ),
    );
  }

  void _pickTime(BuildContext context, ValueChanged<String> onSelected) async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked != null) {
      final now = DateTime.now();
      final dt = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
      onSelected(DateFormat('hh:mm a').format(dt));
    }
  }

  String _computeDuration(String inTime, String outTime) {
    try {
      final format = DateFormat('hh:mm a');
      final inDt = format.parse(inTime);
      final outDt = format.parse(outTime);
      final diff = outDt.difference(inDt);
      if (diff.isNegative) return '0h';
      final hours = diff.inHours;
      final mins = diff.inMinutes.remainder(60);
      return '${hours}h ${mins}m';
    } catch (_) {
      return '0h';
    }
  }
}
