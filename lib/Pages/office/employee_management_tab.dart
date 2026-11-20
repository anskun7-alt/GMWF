import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../../theme/role_theme_provider.dart';
import '../../services/finance_local_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/camp_session_service.dart';
import '../../services/zkteco_network_service.dart';
import 'bulk_attendance_dialog.dart';
import 'holiday_manager_dialog.dart';
import 'employee_detail_page.dart';
import 'offboard_dialog.dart';
import 'finance_report_helper.dart';

// ── Executive Navy Design System Tokens ─────────────────────────────────────────
class ExecTokens {
  // 1. Structural & Surface Neutrals
  static const navSurface      = SoftPalette.slate900; // Obsidian Navy
  static const canvasBg        = SoftPalette.gray50; // Cool Off-White
  static const cardSurface     = SoftPalette.gray50; // Pure White
  static const rowHover        = SoftPalette.slate100; // Slate Tint
  static const rowSelected     = SoftPalette.slate100; // Ice Blue
  static const borderMuted     = SoftPalette.slate150; // Muted Slate
  static const borderDivider   = SoftPalette.slate200; // Neutral Border

  // 2. Brand & Actions
  static const primaryCTA      = SoftPalette.blue550; // Executive Cobalt
  static const primaryHover    = SoftPalette.blue600; // Deep Cobalt
  static const primaryRing     = SoftPalette.blue300; // Cobalt Glow
  static const secBtnSurface   = SoftPalette.gray50;
  static const secBtnBorder    = SoftPalette.slate200;
  static const secBtnHover     = SoftPalette.gray50;

  // 3. Typography Colors
  static const textPrimary     = SoftPalette.slate900; // Deep Slate Navy
  static const textSecondary   = SoftPalette.slate700; // Mid Slate
  static const textMuted       = SoftPalette.slate600; // Cool Gray
  static const textInverse     = SoftPalette.gray50; // Pure White

  // 4. Semantic Status Badges (BG / Border / Text / Dot)
  // Present / Active
  static const presentBg       = SoftPalette.emerald50;
  static const presentBorder   = SoftPalette.emerald150;
  static const presentText     = SoftPalette.emerald600;
  static const presentDot      = SoftPalette.emerald350;

  // Late
  static const lateBg          = SoftPalette.yellow50m;
  static const lateBorder      = SoftPalette.yellow150;
  static const lateText        = SoftPalette.orange600;
  static const lateDot         = SoftPalette.amber300;

  // Absent / Inactive
  static const absentBg        = SoftPalette.red100t;
  static const absentBorder    = SoftPalette.red200;
  static const absentText      = SoftPalette.red600;
  static const absentDot       = SoftPalette.red400;

  // On Leave / Remote
  static const leaveBg         = SoftPalette.slate100;
  static const leaveBorder     = SoftPalette.slate200;
  static const leaveText       = SoftPalette.blue600;
  static const leaveDot        = SoftPalette.blue500;

  // Sunday / Off Day
  static const sundayBg        = SoftPalette.slate100;
  static const sundayBorder    = SoftPalette.slate150;
  static const sundayText      = SoftPalette.slate600;
  static const sundayDot       = SoftPalette.slate550;

  // Holiday
  static const holidayBg       = SoftPalette.purple50t;
  static const holidayBorder   = SoftPalette.purple150;
  static const holidayText     = SoftPalette.violet600;
  static const holidayDot      = SoftPalette.violet400;

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
  bool _isViewingOffboarded = false;
  StreamSubscription? _punchSubscription;

  // Calendar filter state
  late DateTime _calendarMonth;
  bool _isCalendarExpanded = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _selectedDeptFilter = widget.departmentFilter;
    _calendarMonth = DateTime(widget.date.year, widget.date.month, 1);

    // Realtime punch listener
    _punchSubscription = ZkTecoNetworkService.punchStream.listen((punch) {
      if (mounted) setState(() {});
    });

    // Ensure all finance & employee Hive boxes are open before reading/rendering
    FinanceLocalStorage.ensureBoxesOpen().then((_) {
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

  Future<void> _syncPunches([DateTime? targetDate, bool force = false]) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      final d = targetDate ?? widget.date;
      final dateStr = DateFormat('yyyy-MM-dd').format(d);
      if (force) {
        await FinanceLocalStorage.downloadEmployees(widget.branchId, force: true);
        await FinanceLocalStorage.deduplicateEmployeeRecords();
        await FinanceLocalStorage.downloadAttendance(widget.branchId, specificDateStr: dateStr, force: true);
      } else {
        // Fetch cloud attendance for target date and ensure employees box is populated
        await FinanceLocalStorage.downloadAttendance(widget.branchId, specificDateStr: dateStr);
        unawaited(FinanceLocalStorage.downloadEmployees(widget.branchId));
      }
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
    } finally {
      if (mounted) setState(() => _isSyncing = false);
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
        backgroundColor: context.adapt(ExecTokens.cardSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: ExecTokens.absentDot, size: 24),
            SizedBox(width: 8),
            Text('Wipe All Employees?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.adapt(ExecTokens.textPrimary))),
          ],
        ),
        content: Text(
          'This will delete all employees from local storage and enqueue deletion requests for Firestore sync when connected.\n\nAre you sure you want to proceed?',
          style: TextStyle(fontSize: 13, color: context.adapt(ExecTokens.textSecondary), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: context.adapt(ExecTokens.textMuted))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: ExecTokens.absentDot,
              foregroundColor: SoftPalette.gray50,
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
        AppToast.showSnackBar(context, 
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
  Map<String, dynamic> _computeEmployeeMonthStats(String empId, String monthKey, {String? pin, String? name}) {
    try {
      var resolvedId = empId;
      if (resolvedId.isEmpty && pin != null && pin.isNotEmpty) {
        final found = FinanceLocalStorage.getEmployee(pin);
        if (found != null) {
          resolvedId = (found['localId'] ?? found['id'] ?? '').toString();
        }
      }
      if (resolvedId.isEmpty && name != null && name.isNotEmpty) {
        final found = FinanceLocalStorage.getEmployee(name);
        if (found != null) {
          resolvedId = (found['localId'] ?? found['id'] ?? '').toString();
        }
      }
      final summary = FinanceLocalStorage.getPayrollAttendanceSummary(resolvedId, monthKey);
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
        'summary': summary,
      };
    } catch (_) {
      return {'totalDays': 30, 'workingDays': 0, 'employedDays': 30, 'percentage': 0.0, 'summary': null};
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('yyyy-MM-dd').format(widget.date);
    final monthKey = DateFormat('yyyy-MM').format(widget.date);

    if (!Hive.isBoxOpen(LocalStorageService.employeesBox) || !Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
      return Scaffold(
        backgroundColor: context.adapt(ExecTokens.canvasBg),
        body: Center(
          child: CircularProgressIndicator(color: ExecTokens.primaryCTA),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.adapt(ExecTokens.canvasBg),
      body: ValueListenableBuilder(
        valueListenable: DebouncedBoxListenable.shared(FinanceLocalStorage.employeesBox),
        builder: (ctx, Box empBox, _) {
          return ValueListenableBuilder(
            valueListenable: DebouncedBoxListenable.shared(FinanceLocalStorage.attendanceBox),
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
                  final dept = FinanceLocalStorage.normalizeDepartment(e['department']?.toString() ?? 'Other');
                  final target = FinanceLocalStorage.normalizeDepartment(_selectedDeptFilter);
                  if (dept.toLowerCase() != target.toLowerCase()) return false;
                }
                return true;
              }).toList();

              // 2. Attendance database records for date
              final dbRecords = FinanceLocalStorage.getAttendanceForDate(widget.branchId, dateStr);
              final isSunday = widget.date.weekday == DateTime.sunday;

              final records = filteredByDept.map((emp) {
                var empId = (emp['localId'] ?? emp['id'] ?? emp['employeeId'] ?? '').toString();
                if (empId.isEmpty) {
                  for (final key in FinanceLocalStorage.employeesBox.keys) {
                    final val = FinanceLocalStorage.employeesBox.get(key);
                    if (val == emp || (val is Map && val['name'] == emp['name'])) {
                      empId = key.toString();
                      emp['localId'] = empId;
                      emp['id'] = empId;
                      FinanceLocalStorage.employeesBox.put(key, emp);
                      break;
                    }
                  }
                }
                final altId = (emp['id'] ?? emp['localId'] ?? emp['remoteId'] ?? '').toString();
                final empDept = (emp['department'] ?? 'Office').toString();

                final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                final pin = cred?.biometricPin.isNotEmpty == true
                    ? cred!.biometricPin.trim()
                    : (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();

                final matchingDbRecs = dbRecords.where((r) {
                  final rEmpId = r['employeeId']?.toString();
                  if (rEmpId == empId || (altId.isNotEmpty && rEmpId == altId)) return true;
                  if (pin.isNotEmpty && (r['pin']?.toString() == pin || r['biometricPin']?.toString() == pin || r['employeeId']?.toString() == pin)) {
                    // Exclusivity: if attendance explicitly belongs to another existing employee, don't cross-claim
                    if (rEmpId != null && rEmpId.isNotEmpty && rEmpId != empId && rEmpId != altId) {
                      final other = FinanceLocalStorage.getEmployee(rEmpId);
                      if (other != null) return false;
                    }
                    return true;
                  }
                  return false;
                }).toList();

                Map<String, dynamic>? mergedDbRec;
                for (final m in matchingDbRecs) {
                  mergedDbRec = FinanceLocalStorage.mergeAttendanceRecordMaps(mergedDbRec, m);
                }

                final empRole = (emp['role'] ?? emp['designation'] ?? '').toString();
                final holInfo = FinanceLocalStorage.getHolidayForDate(
                  branchId: widget.branchId,
                  dateStr: dateStr,
                  employeeId: empId,
                  department: empDept,
                  role: empRole,
                );
                final bool isHoliday = holInfo != null && holInfo['isHoliday'] == true;
                final bool isOnDuty = holInfo != null && holInfo['isOnDuty'] == true;
                final String? holName = holInfo != null ? holInfo['name']?.toString() : null;

                final Map<String, dynamic> defaultRec = {
                  'employeeId': empId,
                  'date': dateStr,
                  'status': isSunday ? 'off' : (isHoliday ? 'holiday' : 'absent'),
                  'leaveType': null,
                  'checkInTime': null,
                  'arrivalTime': null,
                  'checkOutTime': null,
                  'departureTime': null,
                  'note': isHoliday ? (holName ?? 'Public Holiday') : (isOnDuty ? 'Holiday Duty' : null),
                  'overtimeDuration': null,
                };

                final baseRec = mergedDbRec ?? defaultRec;
                final record = _draftRecords.containsKey(empId)
                    ? Map<String, dynamic>.from(_draftRecords[empId]!)
                    : Map<String, dynamic>.from(baseRec);

                // Detect presence if real punch times exist and status isn't explicitly marked non-present
                final hasRealPunch = FinanceLocalStorage.hasAnyPunch(record);
                final curStatus = (record['status'] ?? '').toString().toLowerCase().trim();
                final bool isExplicitNonPresent = curStatus == 'absent' || curStatus == 'leave' || curStatus == 'holiday' || curStatus == 'off';

                if (!isExplicitNonPresent && hasRealPunch && curStatus != 'late') {
                  record['status'] = 'present';
                }

                record['employeeId'] = empId;
                record['localId'] = empId;
                record['id'] = empId;
                record['name'] = emp['name'] ?? 'Employee';
                record['role'] = emp['role'] ?? emp['designation'] ?? 'Staff';
                final bool branchHasCamps = CampSessionService.hasCampsForBranch(widget.branchId) || CampSessionService.isKarachiFamily(widget.branchId);
                record['department'] = empDept;
                record['pin'] = pin;
                record['shiftHours'] = emp['shiftHours'] ?? emp['workingHours'] ?? '09:00 - 17:00';
                record['camps'] = branchHasCamps ? (emp['camps'] ?? (emp['camp'] != null ? [emp['camp']] : null)) : null;
                record['sessions'] = branchHasCamps ? emp['sessions'] : null;
                if (mergedDbRec != null && mergedDbRec['shifts'] != null) {
                  record['shifts'] = mergedDbRec['shifts'];
                }

                // [MULTI-SHIFT FIX] If this employee has multiple sessions but no shift
                // punches yet today, pre-populate placeholder shift rows so the UI shows
                // Morning / Evening rows ready to be filled in (Ali, Iqra etc.)
                final sessions = branchHasCamps ? emp['sessions'] : null;
                if (branchHasCamps &&
                    (record['shifts'] == null || (record['shifts'] is Map && (record['shifts'] as Map).isEmpty)) &&
                    sessions is List && sessions.length > 1) {
                  final placeholderShifts = <String, dynamic>{};
                  for (final sess in sessions) {
                    if (sess is Map) {
                      final sessionName = (sess['session'] ?? 'morning').toString().toLowerCase();
                      final camp = (sess['camp'] ?? '').toString();
                      placeholderShifts[sessionName] = {
                        'session': sessionName,
                        'branchId': (emp['branchId'] ?? 'karachi').toString(),
                        'branchName': camp.isNotEmpty ? camp : 'Office',
                        'location': camp.isNotEmpty ? camp : 'Office',
                        'checkInTime': null,
                        'arrivalTime': null,
                        'checkInTimestamp': null,
                        'checkOutTime': null,
                        'departureTime': null,
                        'checkOutTimestamp': null,
                        'status': 'absent',
                        'source': 'placeholder',
                      };
                    }
                  }
                  if (placeholderShifts.isNotEmpty) {
                    record['shifts'] = placeholderShifts;
                  }
                }

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

              final offboardedEmployees = FinanceLocalStorage.getOffboardedEmployees(widget.branchId);
              final filteredOffboarded = offboardedEmployees.where((emp) {
                if (_selectedDeptFilter != 'all') {
                  final dept = FinanceLocalStorage.normalizeDepartment(emp['department']?.toString() ?? 'Other');
                  final target = FinanceLocalStorage.normalizeDepartment(_selectedDeptFilter);
                  if (dept.toLowerCase() != target.toLowerCase()) return false;
                }
                if (_searchQuery.isNotEmpty) {
                  final q = _searchQuery.toLowerCase();
                  final name = (emp['name'] ?? '').toString().toLowerCase();
                  final role = (emp['role'] ?? emp['designation'] ?? '').toString().toLowerCase();
                  final dept = (emp['department'] ?? '').toString().toLowerCase();
                  final pin = (emp['pin'] ?? emp['biometricPin'] ?? '').toString().toLowerCase();
                  if (!name.contains(q) && !role.contains(q) && !dept.contains(q) && !pin.contains(q)) {
                    return false;
                  }
                }
                return true;
              }).toList();

              return Column(
                children: [
                  _buildHeaderToolbar(allEmployees.length, offboardedEmployees.length),
                  if (_isViewingOffboarded) ...[
                    _buildOffboardedBanner(filteredOffboarded.length),
                    Expanded(
                      child: _buildOffboardedList(filteredOffboarded),
                    ),
                  ] else ...[
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
                    _buildHolidayBanner(widget.date),
                    _buildCrossBranchBanner(dateStr),
                    _buildUnmappedPunchesBanner(),
                    Expanded(
                      child: _buildRosterList(visibleRecords, monthKey, isSunday),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ── Header Toolbar ────────────────────────────────────────────────────────
  Widget _buildHeaderToolbar(int totalStaffCount, int offboardedCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: context.adapt(ExecTokens.cardSurface),
        border: Border(bottom: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isWide = constraints.maxWidth >= 950;

        final searchAndCategoryToggle = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Active Staff Pill
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _isViewingOffboarded = false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: !_isViewingOffboarded ? const Color(0xFF042F2E) : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: !_isViewingOffboarded ? const Color(0xFF042F2E) : context.adapt(ExecTokens.borderMuted),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.people_alt_outlined,
                      size: 14,
                      color: !_isViewingOffboarded ? Colors.white : context.adapt(ExecTokens.textSecondary),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Active Staff ($totalStaffCount)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: !_isViewingOffboarded ? FontWeight.bold : FontWeight.w500,
                        color: !_isViewingOffboarded ? Colors.white : context.adapt(ExecTokens.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Offboarded Pill
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _isViewingOffboarded = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: _isViewingOffboarded ? const Color(0xFF042F2E) : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isViewingOffboarded ? const Color(0xFF042F2E) : context.adapt(ExecTokens.borderMuted),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.person_off_outlined,
                      size: 14,
                      color: _isViewingOffboarded ? Colors.white : context.adapt(ExecTokens.textSecondary),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Offboarded ($offboardedCount)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _isViewingOffboarded ? FontWeight.bold : FontWeight.w500,
                        color: _isViewingOffboarded ? Colors.white : context.adapt(ExecTokens.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Search Input Pill
            Container(
              width: 230,
              height: 36,
              decoration: BoxDecoration(
                color: context.adapt(ExecTokens.canvasBg),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
              ),
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(fontSize: 12, color: context.adapt(ExecTokens.textPrimary)),
                decoration: InputDecoration(
                  hintText: 'Search by name, PIN, role...',
                  hintStyle: TextStyle(fontSize: 12, color: context.adapt(ExecTokens.textMuted)),
                  prefixIcon: Icon(Icons.search_rounded, size: 16, color: context.adapt(ExecTokens.textMuted)),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.close_rounded, size: 14, color: context.adapt(ExecTokens.textMuted)),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
          ],
        );

        final actionButtons = Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Sync & Refresh Pill Button
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _isSyncing ? null : () => _syncPunches(widget.date, true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: context.adapt(ExecTokens.secBtnSurface),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.adapt(ExecTokens.secBtnBorder)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _isSyncing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.sync_rounded, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                    const SizedBox(width: 6),
                    Text(
                      _isSyncing ? 'Syncing...' : 'Sync & Refresh',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.adapt(ExecTokens.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Calendar Filter Pill Button
            if (!_isViewingOffboarded)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => setState(() => _isCalendarExpanded = !_isCalendarExpanded),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: _isCalendarExpanded ? context.adapt(ExecTokens.rowSelected) : context.adapt(ExecTokens.secBtnSurface),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _isCalendarExpanded ? ExecTokens.primaryRing : context.adapt(ExecTokens.secBtnBorder)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isCalendarExpanded ? Icons.calendar_month_rounded : Icons.calendar_today_outlined,
                        size: 14,
                        color: _isCalendarExpanded ? ExecTokens.primaryCTA : context.adapt(ExecTokens.textSecondary),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isCalendarExpanded ? 'Hide Calendar' : 'Calendar Filter',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _isCalendarExpanded ? ExecTokens.primaryCTA : context.adapt(ExecTokens.textSecondary),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                    ],
                  ),
                ),
              ),

            // Monthly Grid Pill Button
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                final t = RoleThemeScope.dataOf(context);
                BulkAttendanceDialog.open(
                  context: context,
                  branchId: widget.branchId,
                  theme: t,
                  onSaved: () => setState(() {}),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: context.adapt(ExecTokens.secBtnSurface),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.adapt(ExecTokens.secBtnBorder)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.table_chart_outlined, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                    const SizedBox(width: 6),
                    Text(
                      'Monthly Grid',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textSecondary)),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                  ],
                ),
              ),
            ),

            // Holidays & Off Days Pill Button
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                HolidayManagerDialog.open(
                  context: context,
                  branchId: widget.branchId,
                  branches: widget.branches,
                  userRole: widget.userRole,
                  onSaved: () => setState(() {}),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: context.adapt(ExecTokens.secBtnSurface),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.adapt(ExecTokens.secBtnBorder)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.beach_access_outlined, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                    const SizedBox(width: 6),
                    Text(
                      'Holidays & Off Days',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textSecondary)),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: context.adapt(ExecTokens.textSecondary)),
                  ],
                ),
              ),
            ),

            // Primary CTA: Register Employee (Green Pill)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: widget.onAddEmployee,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF045D48),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF045D48).withValues(alpha: 0.25),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_add_alt_1_rounded, size: 14, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Register Employee',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

        if (!isWide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchAndCategoryToggle,
              const SizedBox(height: 10),
              actionButtons,
            ],
          );
        }

        return Row(
          children: [
            searchAndCategoryToggle,
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: context.adapt(ExecTokens.cardSurface),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
            final isWide = constraints.maxWidth >= 850;

            final dateNavigator = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: Icon(Icons.chevron_left_rounded, size: 20, color: context.adapt(ExecTokens.textSecondary)),
                  tooltip: 'Previous Day',
                  onPressed: () {
                    _draftRecords.clear();
                    widget.onDateChanged(widget.date.subtract(const Duration(days: 1)));
                  },
                ),
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: widget.date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) {
                      _draftRecords.clear();
                      widget.onDateChanged(picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSunday ? context.adapt(ExecTokens.lateBg) : context.adapt(ExecTokens.rowSelected),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSunday ? context.adapt(ExecTokens.lateBorder) : const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSunday ? Icons.weekend_outlined : Icons.calendar_today_rounded,
                          size: 13,
                          color: isSunday ? context.adapt(ExecTokens.lateText) : const Color(0xFF045D48),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isSunday ? '$dateTitle (Sunday Off)' : dateTitle,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isSunday ? context.adapt(ExecTokens.lateText) : const Color(0xFF042F2E),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: const Color(0xFF045D48)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: Icon(Icons.chevron_right_rounded, size: 20, color: context.adapt(ExecTokens.textSecondary)),
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
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.adapt(ExecTokens.canvasBg),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
                    ),
                    child: Text('Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textPrimary))),
                  ),
                ),
              ],
            );

            final filterPills = Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _statusFilterPill('All Staff', '$totalStaff', 'all', Colors.white, const Color(0xFF042F2E), const Color(0xFF042F2E)),
                _statusFilterPill('Present', '$present', 'present', const Color(0xFF15803D), const Color(0xFFDCFCE7), const Color(0xFFBBF7D0)),
                if (late > 0)
                  _statusFilterPill('Late', '$late', 'late', context.adapt(ExecTokens.lateText), context.adapt(ExecTokens.lateBg), context.adapt(ExecTokens.lateBorder)),
                if (leave > 0)
                  _statusFilterPill('On Leave', '$leave', 'leave', context.adapt(ExecTokens.leaveText), context.adapt(ExecTokens.leaveBg), context.adapt(ExecTokens.leaveBorder)),
                _statusFilterPill('Absent', '$absent', 'absent', const Color(0xFFB91C1C), const Color(0xFFFEE2E2), const Color(0xFFFECACA)),
                if (holiday > 0)
                  _statusFilterPill('Holiday', '$holiday', 'holiday', context.adapt(ExecTokens.holidayText), context.adapt(ExecTokens.holidayBg), context.adapt(ExecTokens.holidayBorder)),
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
        color: context.adapt(ExecTokens.cardSurface),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
        boxShadow: const [BoxShadow(color: SoftPalette.gray900A2, blurRadius: 4, offset: Offset(0, 1))],
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
                  Text(monthTitle, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
                  const Spacer(),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    icon: Icon(Icons.chevron_left_rounded, size: 18, color: context.adapt(ExecTokens.textSecondary)),
                    onPressed: () {
                      setState(() {
                        _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
                      });
                    },
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    icon: Icon(Icons.chevron_right_rounded, size: 18, color: context.adapt(ExecTokens.textSecondary)),
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
                        color: context.adapt(ExecTokens.rowHover),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
                      ),
                      child: Text('Today', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textPrimary))),
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
                          color: isSun ? context.adapt(ExecTokens.lateText) : context.adapt(ExecTokens.textMuted),
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
                                  ? context.adapt(ExecTokens.holidayBg)
                                  : (isSun ? context.adapt(ExecTokens.sundayBg) : Colors.transparent)),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isSelected
                                ? ExecTokens.primaryRing
                                : (isHol
                                    ? context.adapt(ExecTokens.holidayBorder)
                                    : (isSun ? context.adapt(ExecTokens.sundayBorder) : Colors.transparent)),
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
                                    ? context.adapt(ExecTokens.holidayText)
                                    : (isSun ? context.adapt(ExecTokens.lateText) : context.adapt(ExecTokens.textPrimary))),
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
                Icon(Icons.analytics_outlined, size: 15, color: context.adapt(ExecTokens.textSecondary)),
                const SizedBox(width: 6),
                Text('$monthTitle Overview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
                const Spacer(),
                IconButton(
                  tooltip: 'Hide Calendar',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: Icon(Icons.close_rounded, size: 18, color: context.adapt(ExecTokens.textMuted)),
                  onPressed: () => setState(() => _isCalendarExpanded = false),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Metric cards in a row
            Row(
              children: [
                Expanded(child: _metricCard('Total Days', '$daysInMonth', 'Month cycle', context.adapt(ExecTokens.textPrimary), context.adapt(ExecTokens.canvasBg), context.adapt(ExecTokens.borderMuted))),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Working Days', '$totalWorkingDays', 'Schedule', context.adapt(ExecTokens.presentText), context.adapt(ExecTokens.presentBg), context.adapt(ExecTokens.presentBorder))),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Sundays', '$totalSundays', 'Off days', context.adapt(ExecTokens.lateText), context.adapt(ExecTokens.lateBg), context.adapt(ExecTokens.lateBorder))),
                const SizedBox(width: 8),
                Expanded(child: _metricCard('Holidays', '$totalHolidays', 'Public/Gazetted', context.adapt(ExecTokens.holidayText), context.adapt(ExecTokens.holidayBg), context.adapt(ExecTokens.holidayBorder))),
              ],
            ),
            const SizedBox(height: 10),
            Divider(color: context.adapt(ExecTokens.borderMuted), height: 1),
            const SizedBox(height: 8),
            // Today / Selected Date Status Filter Pills
            Row(
              children: [
                Text(
                  '${DateFormat("EEE, d MMM").format(widget.date)} Live:',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _statusFilterPill('All Staff', '$totalStaff', 'all', context.adapt(ExecTokens.textSecondary), context.adapt(ExecTokens.canvasBg), context.adapt(ExecTokens.borderMuted)),
                      _statusFilterPill('Present', '$present', 'present', context.adapt(ExecTokens.presentText), context.adapt(ExecTokens.presentBg), context.adapt(ExecTokens.presentBorder)),
                      if (late > 0)
                        _statusFilterPill('Late', '$late', 'late', context.adapt(ExecTokens.lateText), context.adapt(ExecTokens.lateBg), context.adapt(ExecTokens.lateBorder)),
                      if (leave > 0)
                        _statusFilterPill('On Leave', '$leave', 'leave', context.adapt(ExecTokens.leaveText), context.adapt(ExecTokens.leaveBg), context.adapt(ExecTokens.leaveBorder)),
                      _statusFilterPill('Absent', '$absent', 'absent', context.adapt(ExecTokens.absentText), context.adapt(ExecTokens.absentBg), context.adapt(ExecTokens.absentBorder)),
                      if (holiday > 0)
                        _statusFilterPill('Holiday', '$holiday', 'holiday', context.adapt(ExecTokens.holidayText), context.adapt(ExecTokens.holidayBg), context.adapt(ExecTokens.holidayBorder)),
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
              Divider(color: context.adapt(ExecTokens.borderMuted), height: 1),
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
            SizedBox(height: 200, child: VerticalDivider(color: context.adapt(ExecTokens.borderMuted), width: 1)),
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
          Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textMuted))),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.3)),
          const SizedBox(height: 1),
          Text(subtitle, style: TextStyle(fontSize: 9.5, color: context.adapt(ExecTokens.textMuted))),
        ],
      ),
    );
  }

  Widget _statusFilterPill(String label, String count, String filterKey, Color textColor, Color bg, Color border) {
    final isSelected = _statusFilter == filterKey;
    final isAllStaff = filterKey == 'all';
    final isPresent = filterKey == 'present';
    final isAbsent = filterKey == 'absent';

    return InkWell(
      onTap: () => setState(() => _statusFilter = isSelected && filterKey != 'all' ? 'all' : filterKey),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected && !isAllStaff ? context.adapt(ExecTokens.rowSelected) : bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? ExecTokens.primaryCTA : border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isPresent) ...[
              const Icon(Icons.check_circle_rounded, size: 13, color: Color(0xFF15803D)),
              const SizedBox(width: 4),
            ] else if (isAbsent) ...[
              const Icon(Icons.cancel_rounded, size: 13, color: Color(0xFFB91C1C)),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: isSelected && !isAllStaff ? ExecTokens.primaryCTA : textColor,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: isAllStaff
                    ? const Color(0xFF0F766E)
                    : (isSelected ? ExecTokens.primaryCTA : textColor.withValues(alpha: 0.15)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: isAllStaff ? Colors.white : (isSelected ? SoftPalette.gray50 : textColor),
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
      valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.unmappedPunchesBox)),
      builder: (context, box, _) {
        final unmappedList = ZkTecoNetworkService.getUnmappedPunches();
        if (unmappedList.isEmpty) return const SizedBox.shrink();

        final uniquePins = unmappedList.map((p) => p['pin']?.toString() ?? '').where((p) => p.isNotEmpty).toSet().toList();

        return Container(
          margin: const EdgeInsets.fromLTRB(24, 4, 24, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: context.adapt(ExecTokens.absentBg),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: context.adapt(ExecTokens.absentBorder)),
          ),
          child: Row(
            children: [
              const Icon(Icons.fingerprint_rounded, color: ExecTokens.absentDot, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${unmappedList.length} Unmapped Biometric Scans Detected (PINs: ${uniquePins.join(", ")})',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.absentText)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final assigned = await ZkTecoNetworkService.bulkAutoAssignBiometricPins();
                  final remapped = await ZkTecoNetworkService.processPendingUnmappedPunches();
                  if (context.mounted) {
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text('✅ Auto-assigned $assigned PINs and routed $remapped punches!'), backgroundColor: ExecTokens.presentDot),
                    );
                    setState(() {});
                  }
                },
                icon: Icon(Icons.auto_fix_high_rounded, size: 13, color: context.adapt(ExecTokens.absentText)),
                label: Text('Auto-Route', style: TextStyle(fontSize: 11, color: context.adapt(ExecTokens.absentText), fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: context.adapt(ExecTokens.absentBorder)),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Scheduled Holiday Notification Banner ──────────────────────────────────
  Widget _buildHolidayBanner(DateTime date) {
    if (!Hive.isBoxOpen(LocalStorageService.financeHolidaysBox)) return const SizedBox.shrink();

    return ValueListenableBuilder<Box>(
      valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.financeHolidaysBox)),
      builder: (context, _, _) {
        final hol = FinanceLocalStorage.getHolidayForDate(
          branchId: widget.branchId,
          dateStr: DateFormat('yyyy-MM-dd').format(date),
        );
        if (hol == null) return const SizedBox.shrink();

        final name = hol['name']?.toString() ?? 'Public Holiday';
        final type = (hol['type'] ?? 'static').toString().toLowerCase();
        final workingEmps = hol['workingEmployees'] is List ? List<String>.from(hol['workingEmployees'] as List) : <String>[];
        String typeLabel = 'Fixed Annual Holiday';
        if (type == 'floating') typeLabel = 'Interchangeable / Floating Holiday';
        if (type == 'adhoc') typeLabel = 'Emergency / Special Day Off';

        final departments = hol['departments'] is List ? List<String>.from(hol['departments'] as List) : <String>[];
        final roles = hol['roles'] is List ? List<String>.from(hol['roles'] as List) : <String>[];
        final branches = hol['branches'] is List ? List<String>.from(hol['branches'] as List) : <String>[];

        final isSpecificDept = departments.isNotEmpty && !departments.contains('all');
        final isSpecificRole = roles.isNotEmpty && !roles.contains('all');
        final isSpecificBranch = branches.isNotEmpty && !branches.contains('all');

        final List<String> scopeNotes = [];
        if (isSpecificBranch) scopeNotes.add('Branches: ${branches.join(", ")}');
        if (isSpecificDept) scopeNotes.add('Depts: ${departments.join(", ")}');
        if (isSpecificRole) scopeNotes.add('Roles: ${roles.join(", ")}');
        if (workingEmps.isNotEmpty) scopeNotes.add('${workingEmps.length} Duty Staff Working');

        final scopeText = scopeNotes.isNotEmpty
            ? scopeNotes.join(' • ')
            : 'All branch personnel have an authorized organization day off.';

        return Container(
          margin: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: context.adapt(ExecTokens.holidayBg),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.adapt(ExecTokens.holidayBorder)),
          ),
          child: Row(
            children: [
              Icon(Icons.festival_outlined, size: 20, color: context.adapt(ExecTokens.holidayText)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'OFFICIAL HOLIDAY: $name',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: context.adapt(ExecTokens.holidayText),
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: context.adapt(ExecTokens.holidayText).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            typeLabel,
                            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.holidayText)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      scopeText,
                      style: TextStyle(fontSize: 11, color: context.adapt(ExecTokens.textSecondary), fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  HolidayManagerDialog.open(
                    context: context,
                    branchId: widget.branchId,
                    branches: widget.branches,
                    userRole: widget.userRole,
                    onSaved: () => setState(() {}),
                  );
                },
                icon: const Icon(Icons.tune, size: 14),
                label: const Text('Manage', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                style: TextButton.styleFrom(foregroundColor: context.adapt(ExecTokens.holidayText)),
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
      valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.crossBranchPunchesBox)),
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
            color: context.adapt(ExecTokens.lateBg),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: context.adapt(ExecTokens.lateBorder)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, color: ExecTokens.lateDot, size: 18),
              const SizedBox(width: 8),
              Text(
                'Cross-Branch Approvals (${pendingList.length} Pending)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.lateText)),
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
                    AppToast.showSnackBar(context, 
                      const SnackBar(content: Text('✅ Approved cross-branch punches!'), backgroundColor: ExecTokens.presentDot),
                    );
                    setState(() {});
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ExecTokens.lateDot,
                  foregroundColor: SoftPalette.gray50,
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
      decoration: BoxDecoration(
        color: context.adapt(ExecTokens.canvasBg),
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        border: Border(bottom: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
      ),
      child: Row(
        children: [
          SizedBox(width: 36), // avatar space
          SizedBox(width: 12),
          Expanded(flex: 3, child: Text('EMPLOYEE', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('DEPARTMENT', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('WORKING HOURS', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('CLOCK IN / OUT', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('DURATION', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('STATUS', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('ATTENDANCE % & DAYS', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
          Expanded(flex: 2, child: Text('NOTES', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
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
          color: context.adapt(ExecTokens.cardSurface),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
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
                          decoration: BoxDecoration(color: context.adapt(ExecTokens.rowHover), shape: BoxShape.circle),
                          child: Icon(Icons.people_outline_rounded, size: 28, color: context.adapt(ExecTokens.textMuted)),
                        ),
                        const SizedBox(height: 10),
                        Text('No employees found', style: ExecTokens.pageTitle.copyWith(color: context.adapt(ExecTokens.textPrimary))),
                        const SizedBox(height: 4),
                        Text('Add a new employee to get started or adjust your filters.', style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: widget.onAddEmployee,
                          icon: const Icon(Icons.person_add_alt_1_rounded, size: 14),
                          label: const Text('Register Employee', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ExecTokens.primaryCTA,
                            foregroundColor: SoftPalette.gray50,
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
        color: context.adapt(ExecTokens.cardSurface),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
      ),
      child: Column(
        children: [
          _buildTableHeader(),
          // Scrollable List of Rows
          Expanded(
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (c, i) => Divider(color: context.adapt(ExecTokens.borderDivider), height: 1, thickness: 0.5),
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

  Widget _buildOffboardedBanner(int count) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.adapt(ExecTokens.absentBg).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.adapt(ExecTokens.absentBorder).withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.archive_outlined, size: 20, color: ExecTokens.absentDot),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Offboarded Staff Archive ($count) · Historical attendance, profile records, and payroll settlements are preserved here permanently.',
              style: TextStyle(fontSize: 12.5, color: context.adapt(ExecTokens.textPrimary), fontWeight: FontWeight.w500),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _isViewingOffboarded = false),
            icon: const Icon(Icons.arrow_back_rounded, size: 14, color: ExecTokens.primaryCTA),
            label: const Text('Back to Active Staff', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA)),
            style: OutlinedButton.styleFrom(
              backgroundColor: context.adapt(ExecTokens.cardSurface),
              side: BorderSide(color: context.adapt(ExecTokens.borderMuted)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOffboardedList(List<Map<String, dynamic>> employees) {
    if (employees.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        decoration: BoxDecoration(
          color: context.adapt(ExecTokens.cardSurface),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: context.adapt(ExecTokens.rowHover), shape: BoxShape.circle),
                  child: Icon(Icons.people_outline_rounded, size: 28, color: context.adapt(ExecTokens.textMuted)),
                ),
                const SizedBox(height: 10),
                Text('No offboarded staff found', style: ExecTokens.pageTitle.copyWith(color: context.adapt(ExecTokens.textPrimary))),
                const SizedBox(height: 4),
                Text('Employees moved to offboarded status will appear in this category.', style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        color: context.adapt(ExecTokens.cardSurface),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
      ),
      child: Column(
        children: [
          // Table Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: context.adapt(ExecTokens.canvasBg),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
              border: Border(bottom: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
            ),
            child: Row(
              children: [
                SizedBox(width: 36), // avatar
                SizedBox(width: 12),
                Expanded(flex: 3, child: Text('EMPLOYEE', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
                Expanded(flex: 2, child: Text('DEPARTMENT', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
                Expanded(flex: 2, child: Text('OFFBOARDED DATE', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
                Expanded(flex: 3, child: Text('REASON / STATUS', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
                Expanded(flex: 2, child: Text('ADVANCE BALANCE', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)))),
                SizedBox(width: 140, child: Text('ACTIONS', style: ExecTokens.tableHeader.copyWith(color: context.adapt(ExecTokens.textMuted)), textAlign: TextAlign.right)),
              ],
            ),
          ),
          // List of Rows
          Expanded(
            child: ListView.separated(
              itemCount: employees.length,
              separatorBuilder: (c, i) => Divider(color: context.adapt(ExecTokens.borderDivider), height: 1, thickness: 0.5),
              itemBuilder: (ctx, idx) {
                final emp = employees[idx];
                final empId = (emp['localId'] ?? emp['id'] ?? '').toString();
                final name = emp['name']?.toString() ?? 'Employee';
                final role = emp['role'] ?? emp['designation'] ?? 'Staff';
                final dept = emp['department']?.toString() ?? 'Office';
                final pin = (emp['pin'] ?? emp['biometricPin'] ?? '').toString();

                final details = emp['offboardingDetails'] is Map ? emp['offboardingDetails'] as Map : null;
                final reason = details?['reason'] ?? emp['offboardingStatus'] ?? emp['status'] ?? 'Offboarded';
                final detailedReason = details?['detailedReason']?.toString() ?? '';
                final offboardedAtStr = details?['offboardedAt']?.toString() ?? emp['updatedAt']?.toString();
                String formattedDate = 'Archived';
                if (offboardedAtStr != null && offboardedAtStr.isNotEmpty) {
                  final dt = DateTime.tryParse(offboardedAtStr);
                  if (dt != null) formattedDate = DateFormat('dd MMM yyyy').format(dt);
                }

                final advance = (emp['currentAdvanceBalance'] as num?)?.toDouble() ?? 0.0;

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      // Avatar
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: context.adapt(ExecTokens.absentBg),
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ExecTokens.absentDot),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Name, Role, Pin
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(name, style: ExecTokens.rowPrimary.copyWith(color: context.adapt(ExecTokens.textPrimary))),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(role, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
                                if (pin.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: context.adapt(ExecTokens.borderMuted),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text('PIN $pin', style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: context.adapt(ExecTokens.textMuted))),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Department
                      Expanded(
                        flex: 2,
                        child: Text(dept, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
                      ),
                      // Offboarded Date
                      Expanded(
                        flex: 2,
                        child: Text(formattedDate, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
                      ),
                      // Reason & Details
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: context.adapt(ExecTokens.absentBg),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: context.adapt(ExecTokens.absentBorder), width: 0.8),
                              ),
                              child: Text(
                                reason.toString().toUpperCase(),
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.absentText)),
                              ),
                            ),
                            if (detailedReason.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(detailedReason, style: TextStyle(fontSize: 11, color: context.adapt(ExecTokens.textMuted)), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ],
                        ),
                      ),
                      // Advance Balance
                      Expanded(
                        flex: 2,
                        child: Text(
                          advance > 0 ? 'Rs ${advance.toStringAsFixed(0)}' : 'Cleared',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: advance > 0 ? ExecTokens.absentDot : context.adapt(ExecTokens.presentText),
                          ),
                        ),
                      ),
                      // Actions
                      SizedBox(
                        width: 140,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'View Profile & History',
                              icon: Icon(Icons.visibility_outlined, size: 18, color: context.adapt(ExecTokens.textSecondary)),
                              onPressed: () => _openEmployeeProfile(empId),
                            ),
                            const SizedBox(width: 4),
                            ElevatedButton.icon(
                              onPressed: () => _confirmReinstateEmployee(empId, name),
                              icon: const Icon(Icons.restore_rounded, size: 14),
                              label: const Text('Reinstate', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ExecTokens.primaryCTA,
                                foregroundColor: SoftPalette.gray50,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _confirmReinstateEmployee(String empId, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.adapt(ExecTokens.cardSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.restore_rounded, color: ExecTokens.primaryCTA, size: 22),
            const SizedBox(width: 8),
            Text('Reinstate $name', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
          ],
        ),
        content: Text(
          'Are you sure you want to reinstate $name back to Active Staff?\n\nThis will restore their profile in daily attendance and payroll rosters.',
          style: TextStyle(fontSize: 13, color: context.adapt(ExecTokens.textSecondary)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: context.adapt(ExecTokens.textMuted))),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await FinanceLocalStorage.reinstateEmployee(empId, performedBy: LocalStorageService.getActiveUsername());
              if (mounted) {
                setState(() {});
                AppToast.showSnackBar(context, 
                  SnackBar(
                    content: Text('$name has been reinstated to Active Staff.'),
                    backgroundColor: ExecTokens.primaryCTA,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: SoftPalette.gray50),
            child: const Text('Reinstate'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeRow(Map<String, dynamic> record, String monthKey, bool isSunday) {
    var empId = record['employeeId']?.toString() ?? '';
    final name = record['name']?.toString() ?? 'Employee';
    final role = record['role']?.toString() ?? 'Staff';
    final dept = record['department']?.toString() ?? 'Office';
    final pin = record['pin']?.toString() ?? '';
    final shiftHours = record['shiftHours']?.toString() ?? '09:00 - 17:00';
    final inTime = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
    final outTime = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
    final status = (record['status']?.toString() ?? 'absent').toLowerCase();
    final note = record['note']?.toString() ?? '';

    // Robust fallback for empId if empty
    if (empId.isEmpty) {
      empId = (record['localId'] ?? record['id'] ?? '').toString();
    }
    if (empId.isEmpty && pin.isNotEmpty) {
      final found = FinanceLocalStorage.getEmployee(pin);
      if (found != null) {
        empId = (found['localId'] ?? found['id'] ?? '').toString();
      }
    }
    if (empId.isEmpty && name.isNotEmpty) {
      final found = FinanceLocalStorage.getEmployee(name);
      if (found != null) {
        empId = (found['localId'] ?? found['id'] ?? '').toString();
      }
    }

    final shifts = record['shifts'] is Map ? (record['shifts'] as Map) : null;
    final camps = record['camps'] is List ? (record['camps'] as List) : null;

    // Calculate duration across single or multiple shifts/camps
    String duration = _computeTotalDuration(inTime, outTime, shifts);

    // Monthly stats
    final stats = _computeEmployeeMonthStats(empId, monthKey, pin: pin, name: name);
    final double pct = stats['percentage'] as double;
    final int workedDays = stats['workingDays'] as int;
    final int totalDays = stats['totalDays'] as int;

    return InkWell(
      hoverColor: context.adapt(ExecTokens.rowHover),
      onTap: () => _openEmployeeProfile(empId, empName: name, pin: pin),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Avatar Circle
            CircleAvatar(
              radius: 17,
              backgroundColor: context.adapt(ExecTokens.rowSelected),
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
                  Text(name, style: ExecTokens.rowPrimary.copyWith(color: context.adapt(ExecTokens.textPrimary))),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(role, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
                      const SizedBox(width: 6),
                      // PIN Chip
                      InkWell(
                        onTap: () => _editBiometricPin(empId, name, pin),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: pin.isNotEmpty ? context.adapt(ExecTokens.rowSelected) : context.adapt(ExecTokens.absentBg),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                              color: pin.isNotEmpty ? context.adapt(ExecTokens.leaveBorder) : context.adapt(ExecTokens.absentBorder),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            pin.isNotEmpty ? 'PIN $pin' : 'Set PIN',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: pin.isNotEmpty ? ExecTokens.primaryCTA : context.adapt(ExecTokens.absentText),
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
              child: Text(dept, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
            ),

            // Working Hours (Shift) + Camp tags
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(shiftHours, style: ExecTokens.monoData.copyWith(color: context.adapt(ExecTokens.textSecondary))),
                  if (camps != null && camps.isNotEmpty && (CampSessionService.hasCampsForBranch(widget.branchId) || CampSessionService.isKarachiFamily(widget.branchId)))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        camps.map((c) => c.toString()).join(' • '),
                        style: const TextStyle(fontSize: 9.5, color: ExecTokens.primaryCTA, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),

            // Clock In / Clock Out (Supports multi-session / multi-camp punches)
            Expanded(
              flex: (shifts != null && shifts.length > 1) ? 3 : 2,
              child: (shifts != null && shifts.length > 1)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: shifts.entries.map((entry) {
                        final sData = entry.value is Map ? entry.value as Map : {};
                        final campLabel = (sData['camp'] ?? entry.key).toString().toUpperCase();
                        final sIn = sData['checkIn']?.toString() ?? sData['checkInTime']?.toString() ?? '--:--';
                        final sOut = sData['checkOut']?.toString() ?? sData['checkOutTime']?.toString() ?? '--:--';
                        final sDur = sData['duration']?.toString() ?? '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: context.adapt(ExecTokens.rowSelected),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: context.adapt(ExecTokens.leaveBorder), width: 0.6),
                                ),
                                child: Text(
                                  campLabel.length > 9 ? campLabel.substring(0, 9) : campLabel,
                                  style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA),
                                ),
                              ),
                              const SizedBox(width: 4),
                              // Interactive Check-In for this shift
                              InkWell(
                                onTap: () => _pickTime(context, (t) async {
                                  final curShifts = Map<String, dynamic>.from(shifts);
                                  final curShiftData = Map<String, dynamic>.from(sData);
                                  curShiftData['checkIn'] = t;
                                  curShiftData['checkInTime'] = t;
                                  curShiftData['arrivalTime'] = t;
                                  curShiftData['status'] = 'present';
                                  curShifts[entry.key.toString()] = curShiftData;
                                  record['shifts'] = curShifts;
                                  record['status'] = 'present';
                                  final earliest = _findEarliestTime(curShifts);
                                  if (earliest != null) {
                                    record['checkInTime'] = earliest;
                                    record['arrivalTime'] = earliest;
                                  }
                                  await _saveRecordInstantly(empId, record);
                                }),
                                child: Text(
                                  (sIn != '--:--' && sIn.isNotEmpty) ? sIn : '--:--',
                                  style: ExecTokens.monoData.copyWith(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: (sIn != '--:--' && sIn.isNotEmpty) ? context.adapt(ExecTokens.presentText) : context.adapt(ExecTokens.textMuted),
                                    decoration: TextDecoration.underline,
                                    decorationStyle: TextDecorationStyle.dotted,
                                  ),
                                ),
                              ),
                              Text(' → ', style: TextStyle(fontSize: 9.5, color: context.adapt(ExecTokens.textMuted))),
                              // Interactive Check-Out for this shift
                              InkWell(
                                onTap: () => _pickTime(context, (t) async {
                                  final curShifts = Map<String, dynamic>.from(shifts);
                                  final curShiftData = Map<String, dynamic>.from(sData);
                                  curShiftData['checkOut'] = t;
                                  curShiftData['checkOutTime'] = t;
                                  curShiftData['departureTime'] = t;
                                  curShifts[entry.key.toString()] = curShiftData;
                                  record['shifts'] = curShifts;
                                  final latest = _findLatestTime(curShifts);
                                  if (latest != null) {
                                    record['checkOutTime'] = latest;
                                    record['departureTime'] = latest;
                                  }
                                  await _saveRecordInstantly(empId, record);
                                }),
                                child: Text(
                                  (sOut != '--:--' && sOut.isNotEmpty) ? sOut : '--:--',
                                  style: ExecTokens.monoData.copyWith(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: (sOut != '--:--' && sOut.isNotEmpty) ? ExecTokens.primaryCTA : context.adapt(ExecTokens.textMuted),
                                    decoration: TextDecoration.underline,
                                    decorationStyle: TextDecorationStyle.dotted,
                                  ),
                                ),
                              ),
                              if (sDur.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Text('($sDur)', style: TextStyle(fontSize: 9.5, color: context.adapt(ExecTokens.textMuted))),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                    )
                  : Row(
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
                                  ? context.adapt(ExecTokens.presentText)
                                  : context.adapt(ExecTokens.textMuted),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text('  ', style: TextStyle(color: context.adapt(ExecTokens.textMuted))),
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
                                  : context.adapt(ExecTokens.textMuted),
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
                    Text('Running', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.presentText))),
                  ] else ...[
                    Text(duration, style: ExecTokens.rowSecondary.copyWith(color: context.adapt(ExecTokens.textMuted))),
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
              child: Tooltip(
                message: 'Click to open monthly attendance calendar for $name',
                child: InkWell(
                  onTap: () => _showEmployeeAttendanceCalendarDialog(
                    empId: empId,
                    empName: name,
                    role: role,
                    dept: dept,
                    pin: pin,
                    monthKey: monthKey,
                  ),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: pct >= 85 ? context.adapt(ExecTokens.presentBg) : (pct >= 60 ? context.adapt(ExecTokens.lateBg) : context.adapt(ExecTokens.absentBg)),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: pct >= 85 ? context.adapt(ExecTokens.presentBorder) : (pct >= 60 ? context.adapt(ExecTokens.lateBorder) : context.adapt(ExecTokens.absentBorder)),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                '${pct.toStringAsFixed(0)}% Att.',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: pct >= 85 ? context.adapt(ExecTokens.presentText) : (pct >= 60 ? context.adapt(ExecTokens.lateText) : context.adapt(ExecTokens.absentText)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.calendar_month_outlined, size: 13, color: ExecTokens.primaryCTA),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$workedDays / $totalDays Days',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: context.adapt(ExecTokens.textPrimary),
                              ),
                            ),
                            const SizedBox(width: 3),
                            const Text(
                              '• View',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: ExecTokens.primaryCTA,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
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
                    color: note.isNotEmpty ? context.adapt(ExecTokens.textPrimary) : context.adapt(ExecTokens.textMuted),
                    fontStyle: note.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ),

            // 3-Dots Actions Menu
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, size: 18, color: context.adapt(ExecTokens.textMuted)),
              color: context.adapt(ExecTokens.cardSurface),
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (val) async {
                if (val == 'calendar') {
                  _showEmployeeAttendanceCalendarDialog(
                    empId: empId,
                    empName: name,
                    role: role,
                    dept: dept,
                    pin: pin,
                    monthKey: monthKey,
                  );
                } else if (val == 'profile') {
                  _openEmployeeProfile(empId, empName: name, pin: pin);
                } else if (val == 'edit') {
                  var resolvedId = empId.trim();
                  if (resolvedId.isEmpty || FinanceLocalStorage.getEmployee(resolvedId) == null) {
                    if (pin.isNotEmpty) {
                      final emp = FinanceLocalStorage.getEmployee(pin);
                      if (emp != null) resolvedId = (emp['localId'] ?? emp['id'] ?? '').toString();
                    }
                    if ((resolvedId.isEmpty || FinanceLocalStorage.getEmployee(resolvedId) == null) && name.isNotEmpty) {
                      final emp = FinanceLocalStorage.getEmployee(name);
                      if (emp != null) resolvedId = (emp['localId'] ?? emp['id'] ?? '').toString();
                    }
                  }
                  if (resolvedId.isEmpty) resolvedId = empId;
                  widget.onEditEmployee?.call(context, resolvedId);
                } else if (val == 'edit_times') {
                  _showEditAttendanceTimesDialog(empId, name, record);
                } else if (val == 'pin') {
                  _editBiometricPin(empId, name, pin);
                } else if (val == 'mark_present') {
                  record['status'] = 'present';
                  record['leaveType'] = null;
                  record['manualOverride'] = true;
                  if (record['checkInTime'] == null) {
                    record['checkInTime'] = DateFormat('hh:mm a').format(DateTime.now());
                  }
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_absent') {
                  record['status'] = 'absent';
                  record['leaveType'] = null;
                  record['checkInTime'] = null;
                  record['checkOutTime'] = null;
                  record['arrivalTime'] = null;
                  record['departureTime'] = null;
                  record['lastPunchTime'] = null;
                  record['manualOverride'] = true;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_leave') {
                  record['status'] = 'leave';
                  record['leaveType'] = record['leaveType'] ?? 'Paid';
                  record['checkInTime'] = null;
                  record['checkOutTime'] = null;
                  record['arrivalTime'] = null;
                  record['departureTime'] = null;
                  record['lastPunchTime'] = null;
                  record['manualOverride'] = true;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_holiday') {
                  record['status'] = 'holiday';
                  record['leaveType'] = null;
                  record['checkInTime'] = null;
                  record['checkOutTime'] = null;
                  record['arrivalTime'] = null;
                  record['departureTime'] = null;
                  record['lastPunchTime'] = null;
                  record['manualOverride'] = true;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'mark_off') {
                  record['status'] = 'off';
                  record['leaveType'] = null;
                  record['checkInTime'] = null;
                  record['checkOutTime'] = null;
                  record['arrivalTime'] = null;
                  record['departureTime'] = null;
                  record['lastPunchTime'] = null;
                  record['manualOverride'] = true;
                  await _saveRecordInstantly(empId, record);
                } else if (val == 'offboard') {
                  _offboardEmployee(empId);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'calendar',
                  child: Row(children: [
                    Icon(Icons.calendar_month_outlined, size: 16, color: ExecTokens.primaryCTA),
                    SizedBox(width: 8),
                    Text('Attendance Calendar', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'edit_times',
                  child: Row(children: [
                    Icon(Icons.access_time_rounded, size: 16, color: ExecTokens.primaryCTA),
                    SizedBox(width: 8),
                    Text('Edit Check-In / Out Times', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(children: [
                    Icon(Icons.badge_outlined, size: 16, color: ExecTokens.primaryCTA),
                    SizedBox(width: 8),
                    Text('View Profile & History', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 16, color: context.adapt(ExecTokens.textSecondary)),
                    SizedBox(width: 8),
                    Text('Edit Details / Profile', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'pin',
                  child: Row(children: [
                    Icon(Icons.fingerprint_rounded, size: 16, color: context.adapt(ExecTokens.textSecondary)),
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
                const PopupMenuItem(
                  value: 'mark_holiday',
                  child: Row(children: [
                    Icon(Icons.festival_outlined, size: 16, color: ExecTokens.holidayDot),
                    SizedBox(width: 8),
                    Text('Mark Holiday', style: TextStyle(fontSize: 12.5)),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'mark_off',
                  child: Row(children: [
                    Icon(Icons.beach_access_outlined, size: 16, color: ExecTokens.sundayDot),
                    SizedBox(width: 8),
                    Text('Mark Off Day', style: TextStyle(fontSize: 12.5)),
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
        bg = context.adapt(ExecTokens.presentBg);
        border = context.adapt(ExecTokens.presentBorder);
        text = context.adapt(ExecTokens.presentText);
        dot = ExecTokens.presentDot;
        label = 'PRESENT';
        break;
      case 'late':
        bg = context.adapt(ExecTokens.lateBg);
        border = context.adapt(ExecTokens.lateBorder);
        text = context.adapt(ExecTokens.lateText);
        dot = ExecTokens.lateDot;
        label = 'LATE';
        break;
      case 'leave':
        bg = context.adapt(ExecTokens.leaveBg);
        border = context.adapt(ExecTokens.leaveBorder);
        text = context.adapt(ExecTokens.leaveText);
        dot = ExecTokens.leaveDot;
        label = 'ON LEAVE';
        break;
      case 'holiday':
        bg = context.adapt(ExecTokens.holidayBg);
        border = context.adapt(ExecTokens.holidayBorder);
        text = context.adapt(ExecTokens.holidayText);
        dot = ExecTokens.holidayDot;
        label = 'HOLIDAY';
        break;
      case 'off':
        bg = context.adapt(ExecTokens.sundayBg);
        border = context.adapt(ExecTokens.sundayBorder);
        text = context.adapt(ExecTokens.sundayText);
        dot = context.adapt(ExecTokens.sundayDot);
        label = 'OFF DAY';
        break;
      case 'absent':
      default:
        bg = context.adapt(ExecTokens.absentBg);
        border = context.adapt(ExecTokens.absentBorder);
        text = context.adapt(ExecTokens.absentText);
        dot = ExecTokens.absentDot;
        label = 'ABSENT';
        break;
    }

    return PopupMenuButton<String>(
      tooltip: 'Change status',
      color: context.adapt(ExecTokens.cardSurface),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onSelected: (newStatus) async {
        setState(() {
          record['status'] = newStatus;
          record['manualOverride'] = true;
          if (newStatus == 'present') {
            record['leaveType'] = null;
            if (record['checkInTime'] == null) {
              record['checkInTime'] = DateFormat('hh:mm a').format(DateTime.now());
            }
          } else if (newStatus == 'late') {
            record['leaveType'] = null;
            if (record['checkInTime'] == null) {
              record['checkInTime'] = DateFormat('hh:mm a').format(DateTime.now());
            }
          } else if (newStatus == 'leave') {
            record['leaveType'] = record['leaveType'] ?? 'Paid';
            record['checkInTime'] = null;
            record['checkOutTime'] = null;
            record['arrivalTime'] = null;
            record['departureTime'] = null;
            record['lastPunchTime'] = null;
          } else {
            // absent, holiday, off
            record['leaveType'] = null;
            record['checkInTime'] = null;
            record['checkOutTime'] = null;
            record['arrivalTime'] = null;
            record['departureTime'] = null;
            record['lastPunchTime'] = null;
          }
        });
        await _saveRecordInstantly(empId, record);
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'present', child: Text('● PRESENT', style: TextStyle(color: context.adapt(ExecTokens.presentText), fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'late', child: Text('● LATE', style: TextStyle(color: context.adapt(ExecTokens.lateText), fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'leave', child: Text('● ON LEAVE', style: TextStyle(color: context.adapt(ExecTokens.leaveText), fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'absent', child: Text('● ABSENT', style: TextStyle(color: context.adapt(ExecTokens.absentText), fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'holiday', child: Text('● HOLIDAY', style: TextStyle(color: context.adapt(ExecTokens.holidayText), fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuItem(value: 'off', child: Text('● OFF DAY', style: TextStyle(color: context.adapt(ExecTokens.sundayText), fontWeight: FontWeight.bold, fontSize: 12))),
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
  void _openEmployeeProfile(String empId, {String? empName, String? pin}) {
    var resolvedId = empId.trim();
    if (resolvedId.isEmpty || FinanceLocalStorage.getEmployee(resolvedId) == null) {
      if (pin != null && pin.isNotEmpty) {
        final emp = FinanceLocalStorage.getEmployee(pin);
        if (emp != null) resolvedId = (emp['localId'] ?? emp['id'] ?? '').toString();
      }
      if ((resolvedId.isEmpty || FinanceLocalStorage.getEmployee(resolvedId) == null) && empName != null && empName.isNotEmpty) {
        final emp = FinanceLocalStorage.getEmployee(empName);
        if (emp != null) resolvedId = (emp['localId'] ?? emp['id'] ?? '').toString();
      }
    }
    if (resolvedId.isEmpty) resolvedId = empId;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeDetailPage(
          employeeId: resolvedId,
          userRole: widget.userRole,
          openEmployeeForm: widget.onEditEmployee,
        ),
      ),
    );
  }

  void _showEmployeeAttendanceCalendarDialog({
    required String empId,
    required String empName,
    required String role,
    required String dept,
    required String pin,
    required String monthKey,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        String activeMonth = monthKey;

        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final summary = FinanceLocalStorage.getPayrollAttendanceSummary(empId, activeMonth);
            final dailyStatus = (summary['dailyStatus'] as Map<dynamic, dynamic>?)?.map(
                  (k, v) => MapEntry(k is int ? k : int.tryParse(k.toString()) ?? 0, v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{}),
                ) ??
                <int, Map<String, dynamic>>{};

            final daysInMonth = FinanceLocalStorage.getDaysInMonth(activeMonth);
            final parts = activeMonth.split('-');
            final yr = int.tryParse(parts[0]) ?? DateTime.now().year;
            final mo = int.tryParse(parts[1]) ?? DateTime.now().month;
            final monthDt = DateTime(yr, mo, 1);
            final firstWeekday = monthDt.weekday; // 1 = Monday, 7 = Sunday
            final monthTitle = DateFormat('MMMM yyyy').format(monthDt);

            final presentDays = (summary['presentDays'] as num?)?.toInt() ?? 0;
            final lateDays = (summary['lateDays'] as num?)?.toInt() ?? 0;
            final paidLeaves = (summary['paidLeaves'] as num?)?.toDouble() ?? 0.0;
            final unpaidLeaves = (summary['unpaidLeaves'] as num?)?.toDouble() ?? 0.0;
            final totalLeaves = paidLeaves + unpaidLeaves;
            final holidayCount = (summary['holidayCount'] as num?)?.toInt() ?? 0;
            final absentDays = (summary['absentDays'] as num?)?.toInt() ?? 0;
            final workingDays = (summary['workingDays'] as num?)?.toDouble() ?? 0.0;
            final totalEmployed = (summary['totalEmployedDays'] as num?)?.toInt() ?? daysInMonth;
            final pct = totalEmployed > 0 ? ((workingDays / totalEmployed) * 100).clamp(0.0, 100.0) : 0.0;

            final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

            return Dialog(
              backgroundColor: context.adapt(ExecTokens.cardSurface),
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860, maxHeight: 820),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Header Row ──
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: context.adapt(ExecTokens.rowSelected),
                            child: Text(
                              empName.isNotEmpty ? empName[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      empName,
                                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary)),
                                    ),
                                    if (pin.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: context.adapt(ExecTokens.borderMuted),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'PIN $pin',
                                          style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textMuted)),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$role • $dept',
                                  style: TextStyle(fontSize: 12, color: context.adapt(ExecTokens.textSecondary)),
                                ),
                              ],
                            ),
                          ),
                          // Month Selector
                          Container(
                            decoration: BoxDecoration(
                              color: context.adapt(ExecTokens.canvasBg),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.chevron_left_rounded, size: 20, color: context.adapt(ExecTokens.textPrimary)),
                                  tooltip: 'Previous Month',
                                  onPressed: () {
                                    final prev = DateTime(yr, mo - 1, 1);
                                    setModalState(() {
                                      activeMonth = DateFormat('yyyy-MM').format(prev);
                                    });
                                  },
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    monthTitle,
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary)),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.chevron_right_rounded, size: 20, color: context.adapt(ExecTokens.textPrimary)),
                                  tooltip: 'Next Month',
                                  onPressed: () {
                                    final next = DateTime(yr, mo + 1, 1);
                                    setModalState(() {
                                      activeMonth = DateFormat('yyyy-MM').format(next);
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.picture_as_pdf_rounded, size: 16, color: ExecTokens.primaryCTA),
                            label: const Text('Export PDF', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: ExecTokens.primaryCTA, width: 1),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () async {
                              await FinanceReportHelper.exportAttendanceCalendarPdf(
                                employeeId: empId,
                                monthKey: activeMonth,
                                context: dialogCtx,
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(Icons.close_rounded, size: 20, color: context.adapt(ExecTokens.textMuted)),
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Month Metrics Summary Ribbon ──
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildCalendarSummaryBadge('Present', '$presentDays Days', context.adapt(ExecTokens.presentBg), context.adapt(ExecTokens.presentBorder), context.adapt(ExecTokens.presentText), Icons.check_circle_outline_rounded),
                          if (lateDays > 0)
                            _buildCalendarSummaryBadge('Late', '$lateDays Days', context.adapt(ExecTokens.lateBg), context.adapt(ExecTokens.lateBorder), context.adapt(ExecTokens.lateText), Icons.alarm_rounded),
                          if (totalLeaves > 0)
                            _buildCalendarSummaryBadge('Leave', '${totalLeaves.toStringAsFixed(1).replaceAll('.0', '')} Days', context.adapt(ExecTokens.leaveBg), context.adapt(ExecTokens.leaveBorder), context.adapt(ExecTokens.leaveText), Icons.beach_access_outlined),
                          if (holidayCount > 0)
                            _buildCalendarSummaryBadge('Holidays', '$holidayCount Days', context.adapt(ExecTokens.holidayBg), context.adapt(ExecTokens.holidayBorder), context.adapt(ExecTokens.holidayText), Icons.celebration_outlined),
                          _buildCalendarSummaryBadge('Absent', '$absentDays Days', context.adapt(ExecTokens.absentBg), context.adapt(ExecTokens.absentBorder), context.adapt(ExecTokens.absentText), Icons.highlight_off_rounded),
                          _buildCalendarSummaryBadge(
                            'Attendance',
                            '${pct.toStringAsFixed(0)}% (${workingDays.round()}/$totalEmployed)',
                            pct >= 85 ? context.adapt(ExecTokens.presentBg) : (pct >= 60 ? context.adapt(ExecTokens.lateBg) : context.adapt(ExecTokens.absentBg)),
                            pct >= 85 ? context.adapt(ExecTokens.presentBorder) : (pct >= 60 ? context.adapt(ExecTokens.lateBorder) : context.adapt(ExecTokens.absentBorder)),
                            pct >= 85 ? context.adapt(ExecTokens.presentText) : (pct >= 60 ? context.adapt(ExecTokens.lateText) : context.adapt(ExecTokens.absentText)),
                            Icons.pie_chart_outline_rounded,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Weekday Headers Row ──
                      Row(
                        children: weekdays.map((w) {
                          final isSun = w == 'Sun';
                          return Expanded(
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: isSun ? context.adapt(ExecTokens.sundayBg) : context.adapt(ExecTokens.canvasBg),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                w,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isSun ? context.adapt(ExecTokens.sundayText) : context.adapt(ExecTokens.textSecondary),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 6),

                      // ── Calendar Grid ──
                      Expanded(
                        child: SingleChildScrollView(
                          child: _buildMonthCalendarGrid(
                            year: yr,
                            month: mo,
                            daysInMonth: daysInMonth,
                            firstWeekday: firstWeekday,
                            dailyStatus: dailyStatus,
                            empName: empName,
                            empId: empId,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // ── Legend Bar ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildCalendarLegendDot(ExecTokens.presentDot, 'Present'),
                          const SizedBox(width: 14),
                          _buildCalendarLegendDot(ExecTokens.lateDot, 'Late'),
                          const SizedBox(width: 14),
                          _buildCalendarLegendDot(ExecTokens.leaveDot, 'On Leave'),
                          const SizedBox(width: 14),
                          _buildCalendarLegendDot(ExecTokens.holidayDot, 'Holiday'),
                          const SizedBox(width: 14),
                          _buildCalendarLegendDot(context.adapt(ExecTokens.sundayDot), 'Sunday Off'),
                          const SizedBox(width: 14),
                          _buildCalendarLegendDot(ExecTokens.absentDot, 'Absent'),
                        ],
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

  Widget _buildCalendarSummaryBadge(String label, String value, Color bg, Color border, Color text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: text),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: text),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: text),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 11, color: context.adapt(ExecTokens.textSecondary))),
      ],
    );
  }

  Widget _buildMonthCalendarGrid({
    required int year,
    required int month,
    required int daysInMonth,
    required int firstWeekday,
    required Map<int, Map<String, dynamic>> dailyStatus,
    required String empName,
    required String empId,
  }) {
    final totalOffset = firstWeekday - 1;
    final totalCells = totalOffset + daysInMonth;
    final roundedTotal = ((totalCells + 6) ~/ 7) * 7;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: roundedTotal,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1.15,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemBuilder: (context, idx) {
        if (idx < totalOffset || idx >= totalCells) {
          return Container(
            decoration: BoxDecoration(
              color: context.adapt(ExecTokens.canvasBg).withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
            ),
          );
        }

        final day = idx - totalOffset + 1;
        final dayData = dailyStatus[day] ?? {};
        final status = (dayData['status']?.toString() ?? 'unmarked').toLowerCase();
        final inTime = dayData['checkInTime']?.toString();
        final outTime = dayData['checkOutTime']?.toString();
        final shifts = dayData['shifts'];
        final note = dayData['note']?.toString();

        Color bg = context.adapt(ExecTokens.canvasBg);
        Color border = context.adapt(ExecTokens.borderMuted);
        Color textColor = context.adapt(ExecTokens.textSecondary);
        String badgeText = '—';

        if (status == 'present') {
          bg = context.adapt(ExecTokens.presentBg);
          border = context.adapt(ExecTokens.presentBorder);
          textColor = context.adapt(ExecTokens.presentText);
          badgeText = '✓ Present';
        } else if (status == 'late') {
          bg = context.adapt(ExecTokens.lateBg);
          border = context.adapt(ExecTokens.lateBorder);
          textColor = context.adapt(ExecTokens.lateText);
          badgeText = '⏱ Late';
        } else if (status == 'leave') {
          bg = context.adapt(ExecTokens.leaveBg);
          border = context.adapt(ExecTokens.leaveBorder);
          textColor = context.adapt(ExecTokens.leaveText);
          badgeText = '🏖 Leave';
        } else if (status == 'holiday') {
          bg = context.adapt(ExecTokens.holidayBg);
          border = context.adapt(ExecTokens.holidayBorder);
          textColor = context.adapt(ExecTokens.holidayText);
          badgeText = '🎉 Holiday';
        } else if (status == 'off') {
          bg = context.adapt(ExecTokens.sundayBg);
          border = context.adapt(ExecTokens.sundayBorder);
          textColor = context.adapt(ExecTokens.sundayText);
          badgeText = 'Off Day';
        } else if (status == 'absent') {
          bg = context.adapt(ExecTokens.absentBg);
          border = context.adapt(ExecTokens.absentBorder);
          textColor = context.adapt(ExecTokens.absentText);
          badgeText = '✕ Absent';
        }

        // Punches string
        String punchStr = '';
        if (shifts is Map && shifts.isNotEmpty) {
          for (final s in shifts.values) {
            if (s is Map) {
              final cin = s['checkIn']?.toString();
              final cout = s['checkOut']?.toString();
              if (cin != null && cin.isNotEmpty && cin != '--:--') {
                punchStr = '$cin - ${cout ?? 'Running'}';
                break;
              }
            }
          }
        }
        if (punchStr.isEmpty && inTime != null && inTime.isNotEmpty && inTime != '--:--') {
          punchStr = '$inTime - ${outTime ?? 'Running'}';
        }

        final duration = _computeTotalDuration(inTime, outTime, shifts is Map ? shifts : null);

        return Tooltip(
          message: '$empName\n${DateFormat('EEE, d MMM yyyy').format(DateTime(year, month, day))}\nStatus: ${badgeText.replaceAll('✓ ', '').replaceAll('⏱ ', '').replaceAll('🏖 ', '').replaceAll('🎉 ', '').replaceAll('✕ ', '')}${punchStr.isNotEmpty ? '\nPunches: $punchStr ($duration)' : ''}${note != null && note.isNotEmpty ? '\nNote: $note' : ''}',
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: border, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '$day',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: status == 'off' ? context.adapt(ExecTokens.textMuted) : context.adapt(ExecTokens.textPrimary),
                      ),
                    ),
                    Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                if (punchStr.isNotEmpty) ...[
                  Text(
                    punchStr,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: context.adapt(ExecTokens.textPrimary),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (duration != '0h')
                    Text(
                      '⏱ $duration',
                      style: TextStyle(
                        fontSize: 8.5,
                        color: textColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ] else if (note != null && note.isNotEmpty) ...[
                  Text(
                    note,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontStyle: FontStyle.italic,
                      color: context.adapt(ExecTokens.textMuted),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _editBiometricPin(String empId, String empName, String currentPin) {
    final ctrl = TextEditingController(text: currentPin);
    final empData = FinanceLocalStorage.getEmployee(empId);
    final dept = empData?['department']?.toString() ?? 'Office';
    final suggestedPins = ZkTecoNetworkService.getSuggestedPinsForDepartment(dept, count: 4, excludeEntityId: empId);
    bool overwriteConfirmed = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final enteredPin = ctrl.text.trim();
          final takenCred = enteredPin.isNotEmpty ? ZkTecoNetworkService.getCredentialByPin(enteredPin) : null;
          final isCollision = takenCred != null && takenCred.entityId != empId;

          return AlertDialog(
            backgroundColor: context.adapt(ExecTokens.cardSurface),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: Row(
              children: [
                const Icon(Icons.fingerprint_rounded, color: ExecTokens.primaryCTA, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Biometric PIN - $empName', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter the numeric PIN registered on physical ZKTeco attendance hardware. Department pattern for $dept is applied.',
                    style: TextStyle(fontSize: 12, color: context.adapt(ExecTokens.textSecondary)),
                  ),
                  const SizedBox(height: 12),

                  // Suggested PIN chips
                  if (suggestedPins.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.auto_awesome_rounded, size: 13, color: ExecTokens.primaryCTA),
                        const SizedBox(width: 4),
                        Text(
                          'Suggested for $dept:',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.adapt(ExecTokens.textSecondary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: suggestedPins.map((pin) {
                        final isCur = enteredPin == pin;
                        return InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            ctrl.text = pin;
                            overwriteConfirmed = false;
                            setDialogState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isCur ? const Color(0xFF042F2E) : const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: isCur ? const Color(0xFF042F2E) : const Color(0xFFBBF7D0)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.pin, size: 12, color: isCur ? Colors.white : const Color(0xFF15803D)),
                                const SizedBox(width: 4),
                                Text(
                                  pin,
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: isCur ? Colors.white : const Color(0xFF15803D)),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                  ],

                  TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {
                      overwriteConfirmed = false;
                    }),
                    decoration: InputDecoration(
                      labelText: 'Hardware PIN',
                      filled: true,
                      fillColor: context.adapt(ExecTokens.canvasBg),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: ExecTokens.primaryCTA, width: 1.5)),
                    ),
                  ),

                  // PIN Collision Warning Banner
                  if (isCollision) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: overwriteConfirmed ? const Color(0xFFF0FDF4) : const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: overwriteConfirmed ? const Color(0xFF86EFAC) : const Color(0xFFFCD34D)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                overwriteConfirmed ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                                color: overwriteConfirmed ? const Color(0xFF15803D) : const Color(0xFFB45309),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      overwriteConfirmed
                                          ? 'PIN Overwrite Confirmed'
                                          : 'PIN $enteredPin is already taken!',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: overwriteConfirmed ? const Color(0xFF15803D) : const Color(0xFF92400E),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      overwriteConfirmed
                                          ? 'This PIN will be unassigned from ${takenCred.entityName} and reassigned to $empName.'
                                          : 'Currently assigned to ${takenCred.entityName} (${takenCred.entityType.replaceAll('_', ' ')}). Should we overwrite this or use a new one?',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: overwriteConfirmed ? const Color(0xFF166534) : const Color(0xFF78350F),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (!overwriteConfirmed) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (suggestedPins.isNotEmpty)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      foregroundColor: const Color(0xFF045D48),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    ),
                                    onPressed: () {
                                      ctrl.text = suggestedPins.first;
                                      overwriteConfirmed = false;
                                      setDialogState(() {});
                                    },
                                    child: Text('Use Suggested (${suggestedPins.first})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                const SizedBox(width: 4),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFB45309),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    elevation: 0,
                                  ),
                                  onPressed: () => setDialogState(() => overwriteConfirmed = true),
                                  child: const Text('Overwrite PIN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: context.adapt(ExecTokens.textMuted)))),
              ElevatedButton(
                onPressed: () async {
                  final newPin = ctrl.text.trim();
                  if (newPin.isEmpty) return;

                  if (isCollision && !overwriteConfirmed) {
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Confirm PIN Overwrite', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        content: Text('PIN $newPin is currently assigned to ${takenCred.entityName}. Do you really want to overwrite and assign it to $empName?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No, cancel')),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309), foregroundColor: Colors.white),
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Yes, Overwrite'),
                          ),
                        ],
                      ),
                    );
                    if (proceed != true) return;
                  }

                  Navigator.pop(ctx);

                  await ZkTecoNetworkService.assignPinToEntity(
                    entityId: empId,
                    entityName: empName,
                    entityType: 'employee',
                    branchId: widget.branchId,
                    customPin: newPin,
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
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text('✅ PIN $newPin assigned to $empName!'), backgroundColor: ExecTokens.primaryCTA),
                    );
                    setState(() {});
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: SoftPalette.gray50),
                child: const Text('Save PIN'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _editNoteDialog(String empId, Map<String, dynamic> record) {
    final ctrl = TextEditingController(text: record['note']?.toString() ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.adapt(ExecTokens.cardSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Attendance Remarks', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter reason, late notes, or remarks...',
            filled: true,
            fillColor: context.adapt(ExecTokens.canvasBg),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: context.adapt(ExecTokens.textMuted)))),
          ElevatedButton(
            onPressed: () async {
              record['note'] = ctrl.text.trim();
              Navigator.pop(ctx);
              await _saveRecordInstantly(empId, record);
            },
            style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: SoftPalette.gray50),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String? _findEarliestTime(Map shifts) {
    final format = DateFormat('hh:mm a');
    DateTime? earliest;
    String? earliestStr;
    for (final v in shifts.values) {
      if (v is Map) {
        final t = (v['checkIn'] ?? v['checkInTime'] ?? v['arrivalTime'])?.toString();
        if (t != null && t.isNotEmpty && t != '--:--') {
          try {
            final dt = format.parse(t);
            if (earliest == null || dt.isBefore(earliest)) {
              earliest = dt;
              earliestStr = t;
            }
          } catch (_) {}
        }
      }
    }
    return earliestStr;
  }

  String? _findLatestTime(Map shifts) {
    final format = DateFormat('hh:mm a');
    DateTime? latest;
    String? latestStr;
    for (final v in shifts.values) {
      if (v is Map) {
        final t = (v['checkOut'] ?? v['checkOutTime'] ?? v['departureTime'])?.toString();
        if (t != null && t.isNotEmpty && t != '--:--') {
          try {
            final dt = format.parse(t);
            if (latest == null || dt.isAfter(latest)) {
              latest = dt;
              latestStr = t;
            }
          } catch (_) {}
        }
      }
    }
    return latestStr;
  }

  void _showEditAttendanceTimesDialog(String empId, String empName, Map<String, dynamic> record) {
    final dateStr = (record['date'] ?? DateFormat('yyyy-MM-dd').format(widget.date)).toString();
    final noteCtrl = TextEditingController(text: record['note']?.toString() ?? '');
    String inTime = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString() ?? '';
    String outTime = record['checkOutTime']?.toString() ?? record['departureTime']?.toString() ?? '';
    String curStatus = (record['status']?.toString() ?? 'present').toLowerCase();

    // Shifts clone
    final Map<String, dynamic> localShifts = record['shifts'] is Map
        ? Map<String, dynamic>.from(record['shifts'] as Map)
        : <String, dynamic>{};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            backgroundColor: context.adapt(ExecTokens.cardSurface),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Row(
              children: [
                const Icon(Icons.edit_calendar_rounded, color: ExecTokens.primaryCTA, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Edit Attendance: $empName', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
                      Text('Date: $dateStr', style: TextStyle(fontSize: 12, color: context.adapt(ExecTokens.textMuted))),
                    ],
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Status Selector
                    Text('Attendance Status', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary))),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: ['present', 'late', 'absent', 'leave', 'off'].map((st) {
                        final isSel = curStatus == st;
                        return ChoiceChip(
                          label: Text(st.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isSel ? SoftPalette.gray50 : context.adapt(ExecTokens.textSecondary))),
                          selected: isSel,
                          selectedColor: ExecTokens.primaryCTA,
                          backgroundColor: context.adapt(ExecTokens.canvasBg),
                          onSelected: (val) {
                            if (val) setDlgState(() => curStatus = st);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    // Multi-shift editor if shifts exist
                    if (localShifts.isNotEmpty) ...[
                      Text('Shift / Camp Punches', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary))),
                      const SizedBox(height: 8),
                      ...localShifts.entries.map((entry) {
                        final sData = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : <String, dynamic>{};
                        final campLabel = (sData['camp'] ?? entry.key).toString();
                        final sIn = sData['checkIn']?.toString() ?? sData['checkInTime']?.toString() ?? '--:--';
                        final sOut = sData['checkOut']?.toString() ?? sData['checkOutTime']?.toString() ?? '--:--';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.adapt(ExecTokens.canvasBg),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.adapt(ExecTokens.borderMuted)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(campLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textPrimary))),
                              ),
                              // Shift In Time
                              InkWell(
                                onTap: () => _pickTime(ctx, (t) {
                                  setDlgState(() {
                                    sData['checkIn'] = t;
                                    sData['checkInTime'] = t;
                                    sData['arrivalTime'] = t;
                                    sData['status'] = 'present';
                                    localShifts[entry.key] = sData;
                                  });
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(color: context.adapt(SoftPalette.gray50), borderRadius: BorderRadius.circular(4), border: Border.all(color: context.adapt(ExecTokens.borderDivider))),
                                  child: Text(sIn, style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.presentText))),
                                ),
                              ),
                              Text('  →  ', style: TextStyle(fontSize: 11, color: context.adapt(ExecTokens.textMuted))),
                              // Shift Out Time
                              InkWell(
                                onTap: () => _pickTime(ctx, (t) {
                                  setDlgState(() {
                                    sData['checkOut'] = t;
                                    sData['checkOutTime'] = t;
                                    sData['departureTime'] = t;
                                    localShifts[entry.key] = sData;
                                  });
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(color: context.adapt(SoftPalette.gray50), borderRadius: BorderRadius.circular(4), border: Border.all(color: context.adapt(ExecTokens.borderDivider))),
                                  child: Text(sOut, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: ExecTokens.primaryCTA)),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ] else ...[
                      // Single shift editor
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Check In Time', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary))),
                                const SizedBox(height: 4),
                                InkWell(
                                  onTap: () => _pickTime(ctx, (t) => setDlgState(() => inTime = t)),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(color: context.adapt(ExecTokens.canvasBg), borderRadius: BorderRadius.circular(6), border: Border.all(color: context.adapt(ExecTokens.borderMuted))),
                                    child: Row(
                                      children: [
                                        Icon(Icons.login_rounded, size: 16, color: context.adapt(ExecTokens.presentText)),
                                        const SizedBox(width: 8),
                                        Text(inTime.isNotEmpty ? inTime : 'Pick Time', style: TextStyle(fontSize: 13, fontFamily: 'monospace', color: inTime.isNotEmpty ? context.adapt(ExecTokens.textPrimary) : context.adapt(ExecTokens.textMuted))),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Check Out Time', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary))),
                                const SizedBox(height: 4),
                                InkWell(
                                  onTap: () => _pickTime(ctx, (t) => setDlgState(() => outTime = t)),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(color: context.adapt(ExecTokens.canvasBg), borderRadius: BorderRadius.circular(6), border: Border.all(color: context.adapt(ExecTokens.borderMuted))),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.logout_rounded, size: 16, color: ExecTokens.primaryCTA),
                                        const SizedBox(width: 8),
                                        Text(outTime.isNotEmpty ? outTime : 'Pick Time', style: TextStyle(fontSize: 13, fontFamily: 'monospace', color: outTime.isNotEmpty ? context.adapt(ExecTokens.textPrimary) : context.adapt(ExecTokens.textMuted))),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Remarks / Note
                    Text('Remarks / Note', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(ExecTokens.textSecondary))),
                    const SizedBox(height: 4),
                    TextField(
                      controller: noteCtrl,
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'e.g. Overtime approved, late arrival note...',
                        filled: true,
                        fillColor: context.adapt(ExecTokens.canvasBg),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: context.adapt(ExecTokens.textMuted)))),
              ElevatedButton(
                onPressed: () async {
                  record['status'] = curStatus;
                  record['note'] = noteCtrl.text.trim();
                  if (localShifts.isNotEmpty) {
                    record['shifts'] = localShifts;
                    final earliest = _findEarliestTime(localShifts);
                    final latest = _findLatestTime(localShifts);
                    if (earliest != null) {
                      record['checkInTime'] = earliest;
                      record['arrivalTime'] = earliest;
                    }
                    if (latest != null) {
                      record['checkOutTime'] = latest;
                      record['departureTime'] = latest;
                    }
                  } else {
                    if (inTime.isNotEmpty) {
                      record['checkInTime'] = inTime;
                      record['arrivalTime'] = inTime;
                    }
                    if (outTime.isNotEmpty) {
                      record['checkOutTime'] = outTime;
                      record['departureTime'] = outTime;
                    }
                  }
                  Navigator.pop(ctx);
                  await _saveRecordInstantly(empId, record);
                  if (mounted) {
                    AppToast.showSnackBar(context, 
                      SnackBar(content: Text('Attendance updated for $empName')),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: SoftPalette.gray50),
                child: const Text('Save Changes'),
              ),
            ],
          );
        },
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
          backgroundColor: context.adapt(ExecTokens.cardSurface),
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
                  fillColor: context.adapt(ExecTokens.canvasBg),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: context.adapt(ExecTokens.borderMuted))),
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
                AppToast.showSnackBar(context, 
                  const SnackBar(content: Text('✅ Leave marked for range!'), backgroundColor: ExecTokens.presentDot),
                );
                if (mounted) {
                  setState(() {});
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: ExecTokens.primaryCTA, foregroundColor: SoftPalette.gray50),
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

  String _computeTotalDuration(String? inTime, String? outTime, Map? shifts) {
    if (shifts != null && shifts.isNotEmpty) {
      int totalMinutes = 0;
      bool hasRunning = false;
      final format = DateFormat('hh:mm a');
      for (final entry in shifts.values) {
        if (entry is Map) {
          final sIn = entry['checkIn']?.toString();
          final sOut = entry['checkOut']?.toString();
          if (sIn != null && sIn.isNotEmpty && sIn != '--:--') {
            if (sOut != null && sOut.isNotEmpty && sOut != '--:--') {
              try {
                final inDt = format.parse(sIn);
                final outDt = format.parse(sOut);
                final diff = outDt.difference(inDt);
                if (!diff.isNegative) {
                  totalMinutes += diff.inMinutes;
                }
              } catch (_) {}
            } else {
              hasRunning = true;
            }
          }
        }
      }
      if (totalMinutes > 0) {
        final hours = totalMinutes ~/ 60;
        final mins = totalMinutes % 60;
        final durStr = '${hours}h ${mins}m';
        return hasRunning ? '$durStr (+Run)' : durStr;
      }
      if (hasRunning) return 'Running';
    }

    if (inTime != null && inTime.isNotEmpty && inTime != '--:--') {
      if (outTime != null && outTime.isNotEmpty && outTime != '--:--') {
        return _computeDuration(inTime, outTime);
      } else {
        return 'Running';
      }
    }
    return '0h';
  }
}
