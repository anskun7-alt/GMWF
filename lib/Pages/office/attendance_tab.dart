// lib/pages/office/attendance_tab.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_ledger_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/zkteco_network_service.dart';
import '../settings/biometric_device_manager_page.dart';
import 'bulk_attendance_dialog.dart';
import 'shared_widgets.dart';
import '../../services/user_theme_service.dart';

class AttendanceTab extends StatefulWidget {
  final String branchId;
  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final VoidCallback onAddEmployee;
  final Function(BuildContext context, String? employeeId)? onEditEmployee;
  final String departmentFilter;

  const AttendanceTab({
    super.key,
    required this.branchId,
    required this.date,
    required this.onDateChanged,
    required this.onAddEmployee,
    this.onEditEmployee,
    this.departmentFilter = 'all',
  });

  @override
  State<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<AttendanceTab> {
  // Store local modifications before saving to DB
  final Map<String, Map<String, dynamic>> _draftRecords = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all';
  StreamSubscription? _punchSubscription;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    // 1. Listen to realtime ZKTeco punches to re-render attendance immediately
    _punchSubscription = ZkTecoNetworkService.punchStream.listen((punch) {
      if (mounted) {
        setState(() {});
      }
    });
    // 2. Fetch latest punches from Cloud Firestore and hardware scanners
    _syncPunches(widget.date);
  }

  Future<void> _syncPunches([DateTime? targetDate]) async {
    if (_isSyncing) return;
    if (mounted) setState(() => _isSyncing = true);
    try {
      final date = targetDate ?? widget.date;
      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      // 1. Download employees from cloud so active staff roster is immediately loaded
      await FinanceLocalStorage.downloadEmployees(widget.branchId, force: true);
      // 2. Download attendance records from cloud (force fresh pull for target date)
      await FinanceLocalStorage.downloadAttendance(widget.branchId, specificDateStr: dateStr, force: true);
      // 3. Re-route any pending unmapped punches
      await ZkTecoNetworkService.processPendingUnmappedPunches();
      if (mounted) setState(() {});
      
      // 4. Hardware device pull & cloud punch sync in background
      unawaited(Future(() async {
        try {
          await ZkTecoNetworkService.syncAllDevices();
          await ZkTecoNetworkService.syncAllRecordedAttendanceToFirestore();
          if (mounted) setState(() {});
        } catch (_) {}
      }));
    } catch (e) {
      debugPrint('[AttendanceTab] _syncPunches error: $e');
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  void dispose() {
    _punchSubscription?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AttendanceTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _syncPunches(widget.date);
    } else if (oldWidget.date != widget.date) {
      _syncPunches(widget.date);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box>(
      valueListenable: UserThemeService.listenable(),
      builder: (context, _, __) {
        final isDark = UserThemeService.isDarkMode();
        final tOriginal = RoleThemeScope.dataOf(context);
        final t = isDark
            ? RoleThemeData(
                roleLabel: tOriginal.roleLabel,
                isDarkCanvas: true,
                bg: const Color(0xFF0F172A),
                bgCard: const Color(0xFF1E293B),
                bgCardAlt: const Color(0xFF162032),
                bgRule: const Color(0xFF334155),
                accent: const Color(0xFF10B981),
                accentLight: const Color(0xFF34D399),
                accentMuted: const Color(0xFF064E3B).withValues(alpha: 0.3),
                accentGradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
                glassTint: const Color(0x1A10B981),
                textPrimary: const Color(0xFFF8FAFC),
                textSecondary: const Color(0xFF94A3B8),
                textTertiary: const Color(0xFF64748B),
                danger: const Color(0xFFEF4444),
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
              )
            : RoleThemeData(
                roleLabel: tOriginal.roleLabel,
                isDarkCanvas: false,
                bg: const Color(0xFFFBFDFF),
                bgCard: Colors.white,
                bgCardAlt: const Color(0xFFF6F9F8),
                bgRule: const Color(0xFFF1F5F9),
                accent: const Color(0xFF0F9A7A),
                accentLight: const Color(0xFF4CB79A),
                accentMuted: const Color(0xFFE8F6F0),
                accentGradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
                glassTint: const Color(0x1A10B981),
                textPrimary: const Color(0xFF111827),
                textSecondary: const Color(0xFF6B7280),
                textTertiary: const Color(0xFF9CA3AF),
                danger: const Color(0xFFEF4444),
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
        final dateStr = DateFormat('yyyy-MM-dd').format(widget.date);

        return Scaffold(
          backgroundColor: t.bg,
          body: Column(
            children: [
              _buildDatePickerStrip(t),
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: FinanceLocalStorage.employeesBox.listenable(),
                  builder: (ctx, Box empBox, _) {
                    return ValueListenableBuilder(
                      valueListenable: FinanceLocalStorage.attendanceBox.listenable(),
                      builder: (ctx, Box box, _) {
                    final allEmployeesOfBranch = FinanceLocalStorage.getEmployees(widget.branchId).where((e) {
                  final isActive = e['isActive'] as bool? ?? true;
                  if (!isActive) return false;
                  if (e['isDeleted'] == true || e['deleted'] == true) return false;
                  final status = (e['status'] ?? e['employeeStatus'] ?? '').toString().trim().toLowerCase();
                  if (status == 'left' ||
                      status == 'offboarded' ||
                      status == 'kicked' ||
                      status == 'terminated' ||
                      status == 'archived' ||
                      status == 'inactive' ||
                      status == 'deleted' ||
                      status.contains('left') ||
                      status.contains('offboard') ||
                      status.contains('kick') ||
                      status.contains('terminat')) {
                    return false;
                  }
                  return true;
                }).toList();

                final activeEmployees = allEmployeesOfBranch.where((e) {
                  if (widget.departmentFilter != 'all') {
                    final dept = e['department']?.toString() ?? 'Other';
                    final cleanDept = dept.trim().isEmpty ? 'Other' : dept.trim();
                    if (cleanDept.toLowerCase() != widget.departmentFilter.toLowerCase()) return false;
                  }

                  // Limit by Joining Date
                  final joinStr = e['joiningDate']?.toString();
                  if (joinStr != null && joinStr.isNotEmpty) {
                    final joinDate = DateTime.tryParse(joinStr)?.toLocal();
                    if (joinDate != null) {
                      final joinDay = DateTime(joinDate.year, joinDate.month, joinDate.day);
                      final checkDay = DateTime(widget.date.year, widget.date.month, widget.date.day);
                      if (checkDay.isBefore(joinDay)) return false;
                    }
                  }
                  
                  // Limit by Exit Date
                  final exitStr = e['exitDate']?.toString();
                  if (exitStr != null && exitStr.isNotEmpty) {
                    final exitDate = DateTime.tryParse(exitStr)?.toLocal();
                    if (exitDate != null) {
                      final exitDay = DateTime(exitDate.year, exitDate.month, exitDate.day);
                      final checkDay = DateTime(widget.date.year, widget.date.month, widget.date.day);
                      if (checkDay.isAfter(exitDay)) return false;
                    }
                  }
                  
                  return true;
                }).toList();

                if (allEmployeesOfBranch.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.group_outlined, size: 54, color: t.textTertiary),
                          const SizedBox(height: 14),
                          Text('No active employees found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textSecondary)),
                          const SizedBox(height: 6),
                          Text('Register a new employee to get started.', style: TextStyle(fontSize: 12, color: t.textTertiary), textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: widget.onAddEmployee,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: t.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add Employee', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                if (activeEmployees.isEmpty) {
                  return Column(
                    children: [
                      const SizedBox.shrink(),
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.filter_list_off_outlined, size: 54, color: t.textTertiary),
                                const SizedBox(height: 14),
                                Text('No employees matching filters', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textSecondary)),
                                const SizedBox(height: 6),
                                Text('Try adjusting your filters to see more employees.', style: TextStyle(fontSize: 12, color: t.textTertiary), textAlign: TextAlign.center),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }

                // Load database records for today
                final dbRecords = FinanceLocalStorage.getAttendanceForDate(widget.branchId, dateStr);

                // Build working checklist
                final isSunday = widget.date.weekday == DateTime.sunday;
                final allRecords = activeEmployees.map((emp) {
                  final empId = (emp['localId'] ?? emp['id'] ?? '').toString();
                  final altId = emp['id']?.toString() ?? '';
                  final empDept = emp['department']?.toString() ?? '';
                  
                  // Live credential lookup from ZkTecoNetworkService takes top priority
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

                  // Prioritize draft records over DB records
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
                    'halfDayType': null,
                  });

                  // Ensure presence is recognized if ANY punch times exist
                  final checkIn = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
                  final checkOut = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
                  final lastPunch = record['lastPunchTime']?.toString();
                  final shifts = record['shifts'] is Map ? (record['shifts'] as Map) : null;
                  final hasPunch = (checkIn != null && checkIn.isNotEmpty && checkIn != '--:--') ||
                      (checkOut != null && checkOut.isNotEmpty && checkOut != '--:--') ||
                      (lastPunch != null && lastPunch.isNotEmpty) ||
                      (shifts != null && shifts.isNotEmpty);

                  if (hasPunch) {
                    record['status'] = 'present';
                    record['leaveType'] = null;
                  }

                  record['name'] = emp['name']; // cache name for drawing card
                  record['role'] = emp['role'];
                  record['createdBy'] = emp['createdBy'];
                  record['department'] = emp['department'];
                  record['pin'] = pin;
                  record['biometricPin'] = pin;
                  return record;
                }).toList();

                // Compute header counts (case-insensitive & punch-time aware) from all active employees
                int present = allRecords.where((r) {
                  final s = (r['status']?.toString() ?? '').toLowerCase();
                  final inTime = r['checkInTime']?.toString() ?? r['arrivalTime']?.toString();
                  final outTime = r['checkOutTime']?.toString() ?? r['departureTime']?.toString();
                  final lastPunch = r['lastPunchTime']?.toString();
                  final shifts = r['shifts'] is Map ? (r['shifts'] as Map) : null;
                  final hasPunch = (inTime != null && inTime.isNotEmpty && inTime != '--:--') ||
                      (outTime != null && outTime.isNotEmpty && outTime != '--:--') ||
                      (lastPunch != null && lastPunch.isNotEmpty) ||
                      (shifts != null && shifts.isNotEmpty);
                  return s == 'present' || hasPunch;
                }).length;
                int late = allRecords.where((r) => (r['status']?.toString() ?? '').toLowerCase() == 'late').length;
                int leave = allRecords.where((r) {
                  final s = (r['status']?.toString() ?? '').toLowerCase();
                  final inTime = r['checkInTime']?.toString() ?? r['arrivalTime']?.toString();
                  final outTime = r['checkOutTime']?.toString() ?? r['departureTime']?.toString();
                  final lastPunch = r['lastPunchTime']?.toString();
                  final shifts = r['shifts'] is Map ? (r['shifts'] as Map) : null;
                  final hasPunch = (inTime != null && inTime.isNotEmpty && inTime != '--:--') ||
                      (outTime != null && outTime.isNotEmpty && outTime != '--:--') ||
                      (lastPunch != null && lastPunch.isNotEmpty) ||
                      (shifts != null && shifts.isNotEmpty);
                  return s == 'leave' && !hasPunch;
                }).length;
                int absent = allRecords.where((r) {
                  final s = (r['status']?.toString() ?? '').toLowerCase();
                  final inTime = r['checkInTime']?.toString() ?? r['arrivalTime']?.toString();
                  final outTime = r['checkOutTime']?.toString() ?? r['departureTime']?.toString();
                  final lastPunch = r['lastPunchTime']?.toString();
                  final shifts = r['shifts'] is Map ? (r['shifts'] as Map) : null;
                  final hasPunch = (inTime != null && inTime.isNotEmpty && inTime != '--:--') ||
                      (outTime != null && outTime.isNotEmpty && outTime != '--:--') ||
                      (lastPunch != null && lastPunch.isNotEmpty) ||
                      (shifts != null && shifts.isNotEmpty);
                  return (s == 'absent' || s.isEmpty) && !hasPunch;
                }).length;
                int overtime = allRecords.where((r) => (r['status']?.toString() ?? '').toLowerCase() == 'overtime').length;
                int holiday = allRecords.where((r) => (r['status']?.toString() ?? '').toLowerCase() == 'holiday').length;

                // Apply search query and status filtering
                final filteredRecords = allRecords.where((r) {
                  // 1. Status Filter
                  if (_statusFilter != 'all') {
                    final s = (r['status']?.toString() ?? '').toLowerCase();
                    final inTime = r['checkInTime']?.toString() ?? r['arrivalTime']?.toString();
                    if (_statusFilter == 'present') {
                      if (s != 'present' && (inTime == null || inTime.isEmpty || inTime == '--:--')) return false;
                    } else if (_statusFilter == 'absent') {
                      if (s != 'absent' || (inTime != null && inTime.isNotEmpty && inTime != '--:--')) return false;
                    } else if (s != _statusFilter) {
                      return false;
                    }
                  }

                  // 2. Search Query Filter
                  if (_searchQuery.isNotEmpty) {
                    final q = _searchQuery.toLowerCase().trim();
                    final name = (r['name'] ?? '').toString().toLowerCase();
                    final role = (r['role'] ?? '').toString().toLowerCase();
                    final dept = (r['department'] ?? '').toString().toLowerCase();
                    final pin = (r['biometricPin'] ?? r['pin'] ?? '').toString().toLowerCase();

                    final matches = name.contains(q) ||
                        role.contains(q) ||
                        dept.contains(q) ||
                        pin == q ||
                        pin.contains(q);
                    if (!matches) return false;
                  }

                  return true;
                }).toList();

                if (filteredRecords.isEmpty) {
                  return Column(
                    children: [
                      _buildCrossBranchAuthorizationBanner(t, dateStr),
                      _buildSummaryStrip(
                        total: allRecords.length,
                        p: present,
                        lat: late,
                        lv: leave,
                        a: absent,
                        ot: overtime,
                        isSunday: isSunday,
                        t: t,
                        hol: holiday,
                        records: allRecords,
                      ),
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: const BoxDecoration(color: Color(0xFFF1F5F9), shape: BoxShape.circle),
                                  child: const Icon(Icons.search_off_rounded, size: 36, color: Color(0xFF64748B)),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _searchQuery.isNotEmpty
                                      ? 'No staff found matching "$_searchQuery"'
                                      : 'No employees found with status "${_statusFilter.toUpperCase()}"',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _searchQuery.isNotEmpty
                                      ? 'Check spelling or search by PIN number, role, or department.'
                                      : 'Try selecting a different status filter.',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                ),
                                const SizedBox(height: 14),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      _searchCtrl.clear();
                                      _searchQuery = '';
                                      _statusFilter = 'all';
                                    });
                                  },
                                  icon: const Icon(Icons.clear_all_rounded, size: 15),
                                  label: const Text('Reset All Filters'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF0F766E),
                                    side: const BorderSide(color: Color(0xFF0F766E)),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }

                // Group by department
                final Map<String, List<Map<String, dynamic>>> grouped = {};
                for (final r in filteredRecords) {
                  final dept = r['department']?.toString() ?? 'Other';
                  final cleanDept = dept.trim().isEmpty ? 'Other' : dept.trim();
                  grouped.putIfAbsent(cleanDept, () => []).add(r);
                }

                final List<Map<String, dynamic>> displayItems = [];
                final sortedDepts = FinanceLedgerStorage.sortDepartmentsCanonical(grouped.keys);
                for (final deptName in sortedDepts) {
                  final list = grouped[deptName]!;
                  displayItems.add({'isHeader': true, 'departmentName': deptName, 'count': list.length});
                  for (final r in list) {
                    displayItems.add(r);
                  }
                }

                return Column(
                  children: [
                    _buildUnmappedPunchesBanner(t),
                    _buildCrossBranchAuthorizationBanner(t, dateStr),
                    _buildSummaryStrip(
                      total: allRecords.length,
                      p: present,
                      lat: late,
                      lv: leave,
                      a: absent,
                      ot: overtime,
                      isSunday: isSunday,
                      t: t,
                      hol: holiday,
                      records: allRecords,
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (layoutCtx, constraints) {
                          final isWide = constraints.maxWidth >= 750;
                          return Column(children: [
                            if (isWide)
                              Container(
                                color: t.bgCardAlt,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                child: Row(children: [
                                  const SizedBox(width: 44),
                                  const SizedBox(width: 12),
                                  Expanded(child: Text('EMPLOYEE & DEPARTMENT', style: TextStyle(color: t.textTertiary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5))),
                                  Text('PUNCH TIMES', style: TextStyle(color: t.textTertiary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                                  const SizedBox(width: 50),
                                  Text('STATUS', style: TextStyle(color: t.textTertiary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                                  const SizedBox(width: 70),
                                ]),
                              ),
                            Expanded(
                              child: RefreshIndicator(
                                onRefresh: () async {
                                  await FinanceLocalStorage.downloadEmployees(widget.branchId, force: true);
                                  await FinanceLocalStorage.downloadAttendance(widget.branchId, force: true);
                                },
                                child: ListView.builder(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 60),
                                  itemCount: displayItems.length,
                                  itemBuilder: (c, idx) {
                                    final item = displayItems[idx];
                                    if (item['isHeader'] == true) {
                                      return _buildDepartmentHeader(item['departmentName'] as String, item['count'] as int, t);
                                    }
                                    return isWide
                                        ? _buildCompactAttendanceRow(item, t)
                                        : _buildAttendanceCard(item, t);
                                  },
                                ),
                              ),
                            ),
                          ]);
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    ],
  ),
);
      },
    );
  }

  // ── Cross-Branch Authorization Banner ───────────────────────────────────────
  Widget _buildCrossBranchAuthorizationBanner(RoleThemeData t, String dateStr) {
    if (!Hive.isBoxOpen(LocalStorageService.crossBranchPunchesBox)) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.crossBranchPunchesBox).listenable(),
      builder: (context, box, _) {
        final pendingList = ZkTecoNetworkService.getPendingCrossBranchPunches(
          branchId: widget.branchId,
          dateStr: dateStr,
        );

        if (pendingList.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB), // Calm soft amber
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFDE68A), width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: Color(0xFFD97706), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Cross-Branch Punch Approvals (${pendingList.length} Pending HQ Decision)',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...pendingList.map((punch) {
                final pendingId = punch['id']?.toString() ?? '';
                final name = punch['entityName']?.toString() ?? 'Employee';
                final empBranch = punch['employeeBranchName']?.toString() ?? 'Home Branch';
                final punchBranch = punch['punchBranchName']?.toString() ?? 'Remote Branch';
                final timeStr = punch['timestamp'] != null
                    ? DateFormat('hh:mm a').format(DateTime.tryParse(punch['timestamp'].toString()) ?? DateTime.now())
                    : '--:--';

                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$name ($empBranch) punched at $punchBranch @ $timeStr',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () async {
                          final ok = await ZkTecoNetworkService.approveCrossBranchPunch(
                            pendingId: pendingId,
                            reviewerName: 'HQ Manager',
                          );
                          if (context.mounted && ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('✅ Approved $name (Marked Present)'),
                                backgroundColor: const Color(0xFF0F766E),
                              ),
                            );
                            setState(() {});
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F766E),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          elevation: 0,
                        ),
                        child: const Text('Approve'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () async {
                          final ok = await ZkTecoNetworkService.rejectCrossBranchPunch(
                            pendingId: pendingId,
                            reviewerName: 'HQ Manager',
                          );
                          if (context.mounted && ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('❌ Rejected $name (Kept Absent)'),
                                backgroundColor: const Color(0xFFEF4444),
                              ),
                            );
                            setState(() {});
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFEF4444),
                          side: const BorderSide(color: Color(0xFFFECACA)),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  // ── Unmapped Punches Notification Banner ────────────────────────────────────
  Widget _buildUnmappedPunchesBanner(RoleThemeData t) {
    if (!Hive.isBoxOpen(LocalStorageService.unmappedPunchesBox)) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box(LocalStorageService.unmappedPunchesBox).listenable(),
      builder: (context, box, _) {
        final unmappedList = ZkTecoNetworkService.getUnmappedPunches();
        if (unmappedList.isEmpty) return const SizedBox.shrink();

        final uniquePins = unmappedList.map((p) => p['pin']?.toString() ?? '').where((p) => p.isNotEmpty).toSet().toList();

        return Container(
          margin: const EdgeInsets.fromLTRB(14, 6, 14, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFECACA), width: 1),
            boxShadow: [
              BoxShadow(color: Colors.red.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEE2E2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.fingerprint_rounded, color: Color(0xFFEF4444), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${unmappedList.length} Unmapped Biometric Scans Detected (PINs: ${uniquePins.join(", ")})',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF991B1B)),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Biometric punches occurred on hardware for unregistered PINs. Click "Assign PINs" to map them to your staff.',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF7F1D1D)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _showAssignUnmappedPinsDialog(context, unmappedList, t),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
                label: const Text('Assign PINs'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  final assigned = await ZkTecoNetworkService.bulkAutoAssignBiometricPins();
                  final remapped = await ZkTecoNetworkService.processPendingUnmappedPunches();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('✅ Auto-assigned $assigned PINs and routed $remapped punches!'),
                        backgroundColor: const Color(0xFF0F766E),
                      ),
                    );
                    setState(() {});
                  }
                },
                icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
                label: const Text('Auto-Route'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF991B1B),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAssignUnmappedPinsDialog(BuildContext context, List<Map<String, dynamic>> unmappedList, RoleThemeData t) {
    final employees = FinanceLocalStorage.getEmployees(widget.branchId).where((e) => e['isActive'] == true).toList();
    final uniquePins = unmappedList.map((p) => p['pin']?.toString() ?? '').where((p) => p.isNotEmpty).toSet().toList();
    final Map<String, String?> selectedEmployees = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: t.bgCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.fingerprint_rounded, color: t.accent, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Assign Unmapped Biometric Scans', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: t.textPrimary)),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select which employee each punched PIN belongs to. Once assigned, all punches for that PIN will instantly mark the employee Present with their recorded punch time.',
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ...uniquePins.map((pin) {
                    final punchesForPin = unmappedList.where((p) => (p['pin']?.toString() ?? '') == pin).toList();
                    final punchCount = punchesForPin.length;
                    final latestTs = punchesForPin.isNotEmpty ? punchesForPin.last['timestamp']?.toString() : null;
                    final timeLabel = latestTs != null ? DateFormat('hh:mm a').format(DateTime.tryParse(latestTs) ?? DateTime.now()) : '--:--';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDC2626),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text('PIN $pin', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                              const SizedBox(width: 8),
                              Text('$punchCount scan(s) • Latest @ $timeLabel', style: TextStyle(fontSize: 12, color: t.textSecondary, fontWeight: FontWeight.w500)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            value: selectedEmployees[pin],
                            dropdownColor: t.bgCard,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Assign to Employee',
                              labelStyle: TextStyle(color: t.textSecondary),
                              isDense: true,
                              filled: true,
                              fillColor: t.bgCard,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                            ),
                            hint: Text('Choose employee...', style: TextStyle(color: t.textTertiary)),
                            items: employees.map((emp) {
                              final eId = (emp['localId'] ?? emp['id']).toString();
                              final eName = emp['name']?.toString() ?? 'Employee';
                              final eDept = emp['department']?.toString() ?? 'Office';
                              final curPin = emp['biometricPin']?.toString() ?? '';
                              return DropdownMenuItem<String>(
                                value: eId,
                                child: Text(
                                  '$eName ($eDept)${curPin.isNotEmpty ? " [Old PIN: $curPin]" : ""}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                                ),
                              );
                            }).toList(),
                            onChanged: (val) {
                              setDlgState(() {
                                selectedEmployees[pin] = val;
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                int count = 0;
                for (final entry in selectedEmployees.entries) {
                  final pin = entry.key;
                  final empId = entry.value;
                  if (empId != null && empId.isNotEmpty) {
                    final emp = employees.firstWhereOrNull((e) => (e['localId'] ?? e['id']).toString() == empId);
                    final empName = emp?['name']?.toString() ?? 'Employee';
                    await ZkTecoNetworkService.mapPinToEntity(
                      pin: pin,
                      entityId: empId,
                      entityName: empName,
                      entityType: 'employee',
                      branchId: widget.branchId,
                    );
                    if (emp != null) {
                      emp['biometricPin'] = pin;
                      emp['pin'] = pin;
                      await FinanceLocalStorage.saveEmployee(
                        branchId: emp['branchId']?.toString() ?? widget.branchId,
                        data: emp,
                        performedBy: LocalStorageService.getActiveUsername(),
                      );
                    }
                    count++;
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ Assigned $count PIN(s) and applied punches! Staff marked Present.'),
                      backgroundColor: t.accent,
                    ),
                  );
                  setState(() {});
                }
              },
              icon: const Icon(Icons.check_circle_rounded, size: 16),
              label: const Text('Save & Apply Scans'),
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditEmployeePinDialog(String empId, String empName, String currentPin, RoleThemeData t) {
    final pinController = TextEditingController(text: currentPin);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.fingerprint_rounded, color: t.accent, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Biometric PIN for $empName',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: t.textPrimary),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the User ID number registered for $empName on the physical ZKTeco machine (e.g. 1, 2, 1111).',
              style: TextStyle(fontSize: 12, color: t.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: t.textPrimary, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'ZKTeco Hardware PIN / User ID',
                labelStyle: TextStyle(color: t.textSecondary),
                hintText: 'e.g. 1 or 1111',
                hintStyle: TextStyle(color: t.textTertiary),
                filled: true,
                fillColor: t.bgCardAlt,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.accent, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '💡 Tip: Any unmapped punches matching this PIN will automatically be routed to $empName and marked Present.',
              style: TextStyle(fontSize: 11, color: t.accent, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final newPin = pinController.text.trim();
              if (newPin.isEmpty) return;
              Navigator.pop(ctx);

              final remapped = await ZkTecoNetworkService.mapPinToEntity(
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
                  SnackBar(
                    content: Text('✅ PIN $newPin assigned to $empName! Remapped $remapped previous punch(es).'),
                    backgroundColor: t.accent,
                  ),
                );
                setState(() {});
              }
            },
            icon: const Icon(Icons.save_rounded, size: 16),
            label: const Text('Save PIN'),
            style: ElevatedButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Clean Department Header ───────────────────────────────────────────────
  Widget _buildDepartmentHeader(String department, int count, RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: t.bgCardAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.bgRule),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_outlined, size: 13, color: t.textSecondary),
                const SizedBox(width: 5),
                Text(
                  department.toUpperCase(),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: t.textPrimary, letterSpacing: 0.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count Staff',
            style: TextStyle(fontSize: 11, color: t.textTertiary, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: t.bgRule, thickness: 0.5)),
        ],
      ),
    );
  }

  // ── Integrated Search Bar ─────────────────────────────────────────────────
  Widget _buildSearchBar(RoleThemeData t) {
    return Container(
      width: 260,
      height: 36,
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _searchQuery.isNotEmpty ? t.accent : t.bgRule,
          width: _searchQuery.isNotEmpty ? 1.2 : 1,
        ),
      ),
      child: TextField(
        controller: _searchCtrl,
        style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          hintText: 'Search by name, PIN, role...',
          hintStyle: TextStyle(fontSize: 11.5, color: t.textTertiary),
          prefixIcon: Icon(Icons.search_rounded, size: 16, color: t.textSecondary),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: _searchQuery.isNotEmpty
              ? InkWell(
                  onTap: () {
                    _searchCtrl.clear();
                    setState(() => _searchQuery = '');
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(Icons.close_rounded, size: 15, color: t.textSecondary),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        ),
        onChanged: (val) {
          setState(() {
            _searchQuery = val.trim();
          });
        },
      ),
    );
  }

  // ── Date Picker Strip & Top Actions ────────────────────────────────────────
  Widget _buildDatePickerStrip(RoleThemeData t) {
    final today = DateTime.now();
    final isToday = widget.date.year == today.year &&
        widget.date.month == today.month &&
        widget.date.day == today.day;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule, width: 1)),
      ),
      child: LayoutBuilder(builder: (_, constraints) {
        final isNarrow = constraints.maxWidth < 960;

        final dateRow = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: t.bgCardAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.bgRule),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: Icon(Icons.chevron_left_rounded, color: t.textSecondary, size: 20),
                    onPressed: () {
                      _draftRecords.clear();
                      widget.onDateChanged(widget.date.subtract(const Duration(days: 1)));
                    },
                  ),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: widget.date,
                        firstDate: DateTime(2025),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) {
                        _draftRecords.clear();
                        widget.onDateChanged(picked);
                      }
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.calendar_today_rounded, color: t.accent, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            DateFormat('EEE, d MMM yyyy').format(widget.date),
                            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: Icon(Icons.chevron_right_rounded, color: t.textSecondary, size: 20),
                    onPressed: () {
                      _draftRecords.clear();
                      widget.onDateChanged(widget.date.add(const Duration(days: 1)));
                    },
                  ),
                ],
              ),
            ),
            if (!isToday) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  _draftRecords.clear();
                  widget.onDateChanged(DateTime.now());
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: const Text('Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF334155))),
                ),
              ),
            ],
            const SizedBox(width: 8),
            // Instant Punch Sync Button
            Tooltip(
              message: 'Sync & Pull Hardware & Cloud Punches',
              child: InkWell(
                onTap: () => _syncPunches(widget.date),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: _isSyncing ? const Color(0xFFEFF6FF) : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _isSyncing ? const Color(0xFFBFDBFE) : const Color(0xFFA7F3D0), width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _isSyncing
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2563EB)),
                            )
                          : const Icon(Icons.sync_rounded, size: 14, color: Color(0xFF059669)),
                      const SizedBox(width: 5),
                      Text(
                        _isSyncing ? 'Syncing...' : 'Sync Punches',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _isSyncing ? const Color(0xFF1D4ED8) : const Color(0xFF065F46),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        final actionButtons = Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _actionChip('Leave Range', Icons.date_range_outlined, () => _openLeaveRangeDialog(context, t), t),
            _actionChip('Monthly Grid', Icons.table_chart_outlined, () => BulkAttendanceDialog.open(context: context, branchId: widget.branchId, theme: t, onSaved: () => setState(() {})), t),
            _actionChip('Biometric PINs', Icons.fingerprint_rounded, () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BiometricDeviceManagerPage(branchId: widget.branchId),
                ),
              );
            }, t),
            ElevatedButton.icon(
              onPressed: widget.onAddEmployee,
              icon: const Icon(Icons.person_add_outlined, size: 14),
              label: const Text('Add Employee'),
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
            ),
          ],
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: dateRow),
                  const SizedBox(width: 8),
                  _buildSearchBar(t),
                ],
              ),
              const SizedBox(height: 10),
              actionButtons,
            ],
          );
        }

        return Row(
          children: [
            dateRow,
            const SizedBox(width: 14),
            _buildSearchBar(t),
            const Spacer(),
            actionButtons,
          ],
        );
      }),
    );
  }

  Widget _actionChip(String label, IconData icon, VoidCallback onTap, RoleThemeData t) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6.5),
        decoration: BoxDecoration(
          color: t.bgCardAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.bgRule),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: t.textSecondary),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }

  // ── Unified Modern Stats Bar ───────────────────────────────────────────────
  Widget _buildSummaryStrip({
    required int total,
    required int p,
    required int lat,
    required int lv,
    required int a,
    required int ot,
    required bool isSunday,
    required RoleThemeData t,
    required List<Map<String, dynamic>> records,
    int hol = 0,
  }) {
    final isDark = UserThemeService.isDarkMode() || t.isDarkCanvas;

    if (isSunday) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.bgRule),
        ),
        child: Row(
          children: [
            Icon(Icons.weekend_outlined, size: 16, color: t.textSecondary),
            const SizedBox(width: 8),
            Text('Sunday Weekend (Off Day)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: t.textPrimary)),
            const Spacer(),
            Text('Working Overtime: $ot', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: t.accent)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.bgRule),
        boxShadow: const [BoxShadow(color: Color(0x04000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isNarrow = constraints.maxWidth < 700;

        final statsPills = Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _statPill('All Staff', '$total', isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), t.bgCardAlt, t.bgRule, t, isDark, filterKey: 'all'),
            _statPill('Present', '$p', const Color(0xFF10B981), const Color(0xFF10B981).withValues(alpha: 0.12), const Color(0xFF10B981).withValues(alpha: 0.35), t, isDark, filterKey: 'present'),
            if (lat > 0)
              _statPill('Late', '$lat', const Color(0xFFF59E0B), const Color(0xFFF59E0B).withValues(alpha: 0.12), const Color(0xFFF59E0B).withValues(alpha: 0.35), t, isDark, filterKey: 'late'),
            if (lv > 0)
              _statPill('Leave', '$lv', const Color(0xFF3B82F6), const Color(0xFF3B82F6).withValues(alpha: 0.12), const Color(0xFF3B82F6).withValues(alpha: 0.35), t, isDark, filterKey: 'leave'),
            _statPill('Absent', '$a', const Color(0xFFEF4444), const Color(0xFFEF4444).withValues(alpha: 0.12), const Color(0xFFEF4444).withValues(alpha: 0.35), t, isDark, filterKey: 'absent'),
            if (hol > 0)
              _statPill('Holiday', '$hol', const Color(0xFF8B5CF6), const Color(0xFF8B5CF6).withValues(alpha: 0.12), const Color(0xFF8B5CF6).withValues(alpha: 0.35), t, isDark, filterKey: 'holiday'),
            if (_searchQuery.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.accent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search, size: 11, color: t.accent),
                    const SizedBox(width: 4),
                    Text('Searching: "$_searchQuery"', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: t.accent)),
                  ],
                ),
              ),
          ],
        );

        final markAllPresentBtn = ElevatedButton.icon(
          onPressed: () => _markAllPresent(records),
          icon: const Icon(Icons.done_all_rounded, size: 14),
          label: const Text('Mark All Present'),
          style: ElevatedButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 0,
          ),
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              statsPills,
              const SizedBox(height: 8),
              markAllPresentBtn,
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: statsPills),
            const SizedBox(width: 12),
            markAllPresentBtn,
          ],
        );
      }),
    );
  }

  Widget _statPill(
    String label,
    String value,
    Color themeColor,
    Color bg,
    Color border,
    RoleThemeData t,
    bool isDark, {
    required String filterKey,
  }) {
    final isSelected = _statusFilter == filterKey;
    final isAll = filterKey == 'all';

    final Color labelColor = isSelected
        ? (isAll ? (isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8)) : themeColor)
        : (isAll ? t.textSecondary : themeColor.withValues(alpha: 0.9));

    final Color badgeBg = isSelected
        ? (isAll ? (isDark ? const Color(0xFF3B82F6).withValues(alpha: 0.35) : const Color(0xFFDBEAFE)) : themeColor.withValues(alpha: 0.25))
        : (isAll ? (isDark ? const Color(0xFF334155).withValues(alpha: 0.6) : const Color(0xFFE2E8F0)) : themeColor.withValues(alpha: 0.15));

    final Color badgeTextColor = isSelected
        ? (isAll ? (isDark ? Colors.white : const Color(0xFF1E40AF)) : (isDark ? Colors.white : themeColor))
        : (isAll ? t.textPrimary : themeColor);

    return InkWell(
      onTap: () {
        setState(() {
          _statusFilter = (_statusFilter == filterKey && filterKey != 'all') ? 'all' : filterKey;
        });
      },
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: isSelected ? themeColor.withValues(alpha: 0.15) : bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? themeColor.withValues(alpha: 0.65) : border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: labelColor,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 11,
                  color: badgeTextColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── "Mark All Present" Shortcut ───────────────────────────────────────────
  Future<void> _markAllPresent(List<Map<String, dynamic>> records) async {
    final curUser = LocalStorageService.getActiveUsername();
    int count = 0;

    for (final r in records) {
      final empId = r['employeeId']?.toString() ?? '';
      final isLocked = r['isLockedByAdmin'] == true || r['isManagerLocked'] == true;
      if (isLocked) continue;

      r['status'] = 'present';
      r['checkInTime'] ??= '08:30 AM';
      r['leaveType'] = null;
      r['halfDayType'] = null;
      
      await FinanceLocalStorage.saveAttendanceRecord(
        branchId: widget.branchId,
        data: r,
        performedBy: curUser,
      );
      _draftRecords.remove(empId);
      count++;
    }

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Marked $count employees as Present'),
          backgroundColor: const Color(0xFF0F766E),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Compact Attendance Row (Desktop / Wide Screen) ────────────────────────
  Widget _buildCompactAttendanceRow(Map<String, dynamic> record, RoleThemeData t) {
    final empId = record['employeeId']?.toString() ?? '';
    final name = record['name']?.toString() ?? 'Employee';
    final role = record['role']?.toString() ?? 'Staff';
    final dept = record['department']?.toString() ?? '';
    final status = (record['status']?.toString() ?? 'absent').toLowerCase();
    final isSunday = widget.date.weekday == DateTime.sunday;
    final checkIn = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
    final checkOut = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
    final note = record['note']?.toString() ?? '';

    final rawShifts = record['shifts'];
    final Map<String, dynamic> shifts = rawShifts is Map ? Map<String, dynamic>.from(rawShifts) : {};

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule, width: 1)),
      ),
      child: Row(
        children: [
          // Avatar (Clickable to Edit Employee)
          InkWell(
            onTap: () {
              if (widget.onEditEmployee != null) {
                widget.onEditEmployee!(context, empId);
              } else {
                _showEmployeeDetailSheet(context, empId, t);
              }
            },
            borderRadius: BorderRadius.circular(16),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: t.bgCardAlt,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Name, Department & Biometric PIN (Clickable to Edit)
          Expanded(
            child: InkWell(
              onTap: () {
                if (widget.onEditEmployee != null) {
                  widget.onEditEmployee!(context, empId);
                } else {
                  _showEmployeeDetailSheet(context, empId, t);
                }
              },
              borderRadius: BorderRadius.circular(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        name,
                        style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.edit_outlined, size: 12, color: t.textTertiary),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '$role • $dept',
                        style: TextStyle(color: t.textSecondary, fontSize: 11),
                      ),
                      Builder(builder: (_) {
                        final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                        final currentPin = cred?.biometricPin.isNotEmpty == true 
                            ? cred!.biometricPin 
                            : (record['biometricPin']?.toString() ?? '');
                        return InkWell(
                          onTap: () => _showEditEmployeePinDialog(empId, name, currentPin, t),
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: currentPin.isNotEmpty ? const Color(0xFF3B82F6).withValues(alpha: 0.12) : const Color(0xFFEF4444).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: currentPin.isNotEmpty ? const Color(0xFF3B82F6).withValues(alpha: 0.35) : const Color(0xFFEF4444).withValues(alpha: 0.35)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  currentPin.isNotEmpty ? 'PIN $currentPin' : 'Set PIN',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                    color: currentPin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFDC2626),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(Icons.edit, size: 8, color: currentPin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFDC2626)),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Check In / Check Out Timestamps
          if (status == 'present' || status == 'late') ...[
            if (shifts.isNotEmpty) ...[
              ...shifts.entries.map((entry) {
                final sKey = entry.key.toLowerCase();
                final sMap = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : <String, dynamic>{};
                final sIn = sMap['checkInTime']?.toString() ?? '--:--';
                final sOut = sMap['checkOutTime']?.toString() ?? '--:--';
                String sBranch = sMap['branchName']?.toString() ?? sMap['branchId']?.toString() ?? '';
                if (sBranch.toLowerCase().contains('haji')) {
                  sBranch = 'Haji Camp';
                } else if (sBranch.toLowerCase().contains('saddar')) {
                  sBranch = 'Saddar';
                }

                final isMorning = sKey.contains('m') || sKey.contains('morn');
                final isEvening = sKey.contains('e') || sKey.contains('even');
                final isNight = sKey.contains('n') || sKey.contains('night');
                final sessionLabel = isMorning ? 'M' : (isEvening ? 'E' : (isNight ? 'N' : 'S'));

                final isHaji = sBranch.toLowerCase().contains('haji');
                final badgeColor = isHaji
                    ? const Color(0xFF6366F1) // Indigo for Haji Camp
                    : (isMorning ? const Color(0xFF059669) : const Color(0xFF0284C7)); // Emerald for Saddar/Morning, Sky for Evening

                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: '${isMorning ? "Morning" : (isEvening ? "Evening" : "Night")} Shift${sBranch.isNotEmpty ? " • $sBranch" : ""}',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 0.9),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (sBranch.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                sBranch,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: badgeColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4.5),
                          ],
                          Text(
                            '$sessionLabel: ',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: badgeColor,
                            ),
                          ),
                          Text(
                            '$sIn ➔ $sOut',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: t.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ] else ...[
              InkWell(
                onTap: () => _pickTime(context, (time) async {
                  setState(() {
                    record['checkInTime'] = time;
                    record['arrivalTime'] = time;
                  });
                  await _saveRecordInstantly(empId, record);
                }),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35), width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.login_rounded, size: 10, color: Color(0xFF059669)),
                      const SizedBox(width: 4),
                      Text(
                        checkIn != null && checkIn.isNotEmpty ? checkIn : '--:--',
                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF059669)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: () => _pickTime(context, (time) async {
                  setState(() {
                    record['checkOutTime'] = time;
                    record['departureTime'] = time;
                  });
                  await _saveRecordInstantly(empId, record);
                }),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: checkOut != null && checkOut.isNotEmpty ? t.bgCardAlt : t.bgCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: t.bgRule, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.logout_rounded, size: 10, color: t.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        checkOut != null && checkOut.isNotEmpty ? checkOut : 'Set Out',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ] else ...[
            Text('-- : --', style: TextStyle(color: t.textTertiary, fontSize: 11)),
          ],

          const SizedBox(width: 14),

          // The Elegant Single-Pill Status Selector
          isSunday
              ? _buildSundayOvertimeControls(record, empId, t)
              : _buildStatusPill(status, empId, record, t),

          const SizedBox(width: 6),

          // Remarks / Note Icon
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: Icon(
              note.isNotEmpty ? Icons.sticky_note_2_rounded : Icons.note_add_outlined,
              size: 15,
              color: note.isNotEmpty ? t.accent : t.textTertiary,
            ),
            tooltip: note.isNotEmpty ? note : 'Add remarks',
            onPressed: () => _editNoteDialog(context, empId, record, t),
          ),
        ],
      ),
    );
  }

  // ── Mobile Attendance Card Layout ─────────────────────────────────────────
  Widget _buildAttendanceCard(Map<String, dynamic> record, RoleThemeData t) {
    final empId = record['employeeId']?.toString() ?? '';
    final name = record['name']?.toString() ?? 'Employee';
    final role = record['role']?.toString() ?? 'Staff';
    final dept = record['department']?.toString() ?? '';
    final status = (record['status']?.toString() ?? 'absent').toLowerCase();
    final isSunday = widget.date.weekday == DateTime.sunday;
    final checkIn = record['checkInTime']?.toString() ?? record['arrivalTime']?.toString();
    final checkOut = record['checkOutTime']?.toString() ?? record['departureTime']?.toString();
    final note = record['note']?.toString() ?? '';

    final rawShifts = record['shifts'];
    final Map<String, dynamic> shifts = rawShifts is Map ? Map<String, dynamic>.from(rawShifts) : {};

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: t.bgCardAlt,
                child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (widget.onEditEmployee != null) {
                      widget.onEditEmployee!(context, empId);
                    } else {
                      _showEmployeeDetailSheet(context, empId, t);
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: t.textPrimary)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text('$role • $dept', style: TextStyle(fontSize: 11, color: t.textSecondary)),
                          Builder(builder: (_) {
                            final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                            final currentPin = cred?.biometricPin.isNotEmpty == true 
                                ? cred!.biometricPin 
                                : (record['biometricPin']?.toString() ?? '');
                            return InkWell(
                              onTap: () => _showEditEmployeePinDialog(empId, name, currentPin, t),
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: currentPin.isNotEmpty ? const Color(0xFF3B82F6).withValues(alpha: 0.12) : const Color(0xFFEF4444).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: currentPin.isNotEmpty ? const Color(0xFF3B82F6).withValues(alpha: 0.35) : const Color(0xFFEF4444).withValues(alpha: 0.35)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      currentPin.isNotEmpty ? 'PIN $currentPin' : 'Set PIN',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.bold,
                                        color: currentPin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFDC2626),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(Icons.edit, size: 8, color: currentPin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFDC2626)),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              isSunday
                  ? _buildSundayOvertimeControls(record, empId, t)
                  : _buildStatusPill(status, empId, record, t),
            ],
          ),
          if (status == 'present' || status == 'late') ...[
            const SizedBox(height: 8),
            if (shifts.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: shifts.entries.map((entry) {
                  final sKey = entry.key.toLowerCase();
                  final sMap = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : <String, dynamic>{};
                  final sIn = sMap['checkInTime']?.toString() ?? '--:--';
                  final sOut = sMap['checkOutTime']?.toString() ?? '--:--';
                  String sBranch = sMap['branchName']?.toString() ?? sMap['branchId']?.toString() ?? '';
                  if (sBranch.toLowerCase().contains('haji')) {
                    sBranch = 'Haji Camp';
                  } else if (sBranch.toLowerCase().contains('saddar')) {
                    sBranch = 'Saddar';
                  }

                  final isMorning = sKey.contains('m') || sKey.contains('morn');
                  final isEvening = sKey.contains('e') || sKey.contains('even');
                  final isNight = sKey.contains('n') || sKey.contains('night');
                  final sessionLabel = isMorning ? 'M' : (isEvening ? 'E' : (isNight ? 'N' : 'S'));

                  final isHaji = sBranch.toLowerCase().contains('haji');
                  final badgeColor = isHaji
                      ? const Color(0xFF6366F1) // Indigo for Haji Camp
                      : (isMorning ? const Color(0xFF059669) : const Color(0xFF0284C7)); // Emerald for Saddar/Morning, Sky for Evening

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 0.9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (sBranch.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              sBranch,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: badgeColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4.5),
                        ],
                        Text(
                          '$sessionLabel: ',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: badgeColor,
                          ),
                        ),
                        Text(
                          '$sIn ➔ $sOut',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: t.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.login_rounded, size: 12, color: Color(0xFF059669)),
                  const SizedBox(width: 4),
                  Text('In: ${checkIn ?? "--:--"}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF059669))),
                  const SizedBox(width: 14),
                  Icon(Icons.logout_rounded, size: 12, color: t.textSecondary),
                  const SizedBox(width: 4),
                  Text('Out: ${checkOut ?? "--:--"}', style: TextStyle(fontSize: 11, color: t.textSecondary)),
                  const Spacer(),
                  if (note.isNotEmpty)
                    Text(note, style: TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: t.textTertiary)),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Elegant Single-Pill Status Selector (Replaces 6-Button Clutter) ────────
  Widget _buildStatusPill(String status, String empId, Map<String, dynamic> record, RoleThemeData t) {
    Color bg;
    Color border;
    Color text;
    IconData icon;
    String label;

    switch (status) {
      case 'present':
        bg = const Color(0xFF10B981).withValues(alpha: 0.12);
        border = const Color(0xFF10B981).withValues(alpha: 0.35);
        text = const Color(0xFF059669);
        icon = Icons.check_circle_rounded;
        label = 'Present';
        break;
      case 'late':
        bg = const Color(0xFFF59E0B).withValues(alpha: 0.12);
        border = const Color(0xFFF59E0B).withValues(alpha: 0.35);
        text = const Color(0xFFD97706);
        icon = Icons.schedule_rounded;
        label = 'Late';
        break;
      case 'leave':
        bg = const Color(0xFF3B82F6).withValues(alpha: 0.12);
        border = const Color(0xFF3B82F6).withValues(alpha: 0.35);
        text = const Color(0xFF2563EB);
        icon = Icons.event_busy_rounded;
        final lType = (record['leaveType']?.toString() ?? 'Sick').toUpperCase();
        label = 'Leave ($lType)';
        break;
      case 'half_day':
        bg = const Color(0xFF14B8A6).withValues(alpha: 0.12);
        border = const Color(0xFF14B8A6).withValues(alpha: 0.35);
        text = const Color(0xFF0D9488);
        icon = Icons.timelapse_rounded;
        label = 'Half Day';
        break;
      case 'holiday':
        bg = const Color(0xFF8B5CF6).withValues(alpha: 0.12);
        border = const Color(0xFF8B5CF6).withValues(alpha: 0.35);
        text = const Color(0xFF7C3AED);
        icon = Icons.celebration_rounded;
        label = 'Holiday';
        break;
      case 'absent':
      default:
        bg = const Color(0xFFEF4444).withValues(alpha: 0.12);
        border = const Color(0xFFEF4444).withValues(alpha: 0.35);
        text = const Color(0xFFDC2626);
        icon = Icons.cancel_outlined;
        label = 'Absent';
        break;
    }

    return PopupMenuButton<String>(
      tooltip: 'Change Status',
      offset: const Offset(0, 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: t.bgCard,
      elevation: 4,
      onSelected: (newStatus) async {
        setState(() {
          record['status'] = newStatus;
          if (newStatus == 'present' && (record['checkInTime'] == null || record['checkInTime'].toString().isEmpty)) {
            record['checkInTime'] = '08:30 AM';
            record['arrivalTime'] = '08:30 AM';
          }
          if (newStatus != 'present' && newStatus != 'late') {
            record['checkInTime'] = null;
            record['checkOutTime'] = null;
            record['arrivalTime'] = null;
            record['departureTime'] = null;
          }
          if (newStatus == 'leave') {
            record['leaveType'] = record['leaveType'] ?? 'sick';
          }
          if (newStatus == 'half_day') {
            record['halfDayType'] = record['halfDayType'] ?? 'unpaid';
          }
        });
        await _saveRecordInstantly(empId, record);
      },
      itemBuilder: (ctx) => [
        _buildPopupMenuItem('present', 'Present (Full Day)', Icons.check_circle_rounded, const Color(0xFF059669), const Color(0xFF10B981).withValues(alpha: 0.12)),
        _buildPopupMenuItem('late', 'Late Arrival', Icons.schedule_rounded, const Color(0xFFD97706), const Color(0xFFF59E0B).withValues(alpha: 0.12)),
        _buildPopupMenuItem('leave', 'On Approved Leave', Icons.event_busy_rounded, const Color(0xFF2563EB), const Color(0xFF3B82F6).withValues(alpha: 0.12)),
        _buildPopupMenuItem('half_day', 'Half Day', Icons.timelapse_rounded, const Color(0xFF0D9488), const Color(0xFF14B8A6).withValues(alpha: 0.12)),
        _buildPopupMenuItem('absent', 'Mark Absent', Icons.cancel_outlined, const Color(0xFFDC2626), const Color(0xFFEF4444).withValues(alpha: 0.12)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: text),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(color: text, fontWeight: FontWeight.bold, fontSize: 11),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down_rounded, size: 14, color: text.withOpacity(0.7)),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _buildPopupMenuItem(String value, String label, IconData icon, Color color, Color bg) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  // ── Overtime Controls for Sunday ──────────────────────────────────────────
  Widget _buildSundayOvertimeControls(Map<String, dynamic> record, String empId, RoleThemeData t) {
    final ot = record['overtimeDuration']?.toString() ?? 'none';
    final isFull = ot == 'full';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () async {
            setState(() {
              record['status'] = isFull ? 'off' : 'overtime';
              record['overtimeDuration'] = isFull ? 'none' : 'full';
            });
            await _saveRecordInstantly(empId, record);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isFull ? t.accent : t.bgCardAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isFull ? t.accent : t.bgRule),
            ),
            child: Text(
              'Full OT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isFull ? Colors.white : t.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Note / Remarks Dialog ──────────────────────────────────────────────────
  void _editNoteDialog(BuildContext context, String empId, Map<String, dynamic> record, RoleThemeData t) {
    final ctrl = TextEditingController(text: record['note']?.toString() ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Remarks for ${record['name']}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          style: TextStyle(fontSize: 13, color: t.textPrimary),
          decoration: InputDecoration(
            hintText: 'Enter reason or attendance note...',
            hintStyle: TextStyle(color: t.textTertiary),
            filled: true,
            fillColor: t.bgCardAlt,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.accent, width: 1.5)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: t.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: Colors.white),
            onPressed: () async {
              record['note'] = ctrl.text.trim();
              Navigator.pop(ctx);
              setState(() {});
              await _saveRecordInstantly(empId, record);
            },
            child: const Text('Save Note'),
          ),
        ],
      ),
    );
  }

  // ── Employee Detail Sheet ─────────────────────────────────────────────────
  void _showEmployeeDetailSheet(BuildContext context, String employeeId, RoleThemeData t) {
    final emp = FinanceLocalStorage.getEmployee(employeeId);
    if (emp == null) return;

    final name = emp['name']?.toString() ?? '';
    final role = emp['role']?.toString() ?? '';
    final dept = emp['department']?.toString() ?? '';
    final cnic = emp['cnic']?.toString() ?? '';
    final phone = emp['phone']?.toString() ?? '';
    final joinStr = emp['joiningDate']?.toString() ?? '';
    String formattedJoinDate = 'N/A';
    if (joinStr.isNotEmpty) {
      final dt = DateTime.tryParse(joinStr);
      formattedJoinDate = dt != null ? DateFormat('d MMM yyyy').format(dt) : joinStr;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: t.textPrimary)),
                      Text('$role • $dept', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                    ],
                  ),
                  if (widget.onEditEmployee != null)
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onEditEmployee!(context, employeeId);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 14),
                      label: const Text('Edit Profile'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(height: 1, color: t.bgRule),
              const SizedBox(height: 12),
              _buildDetailItem('Phone Number', phone.isNotEmpty ? phone : 'N/A', Icons.phone_outlined, t),
              _buildDetailItem('CNIC Number', cnic.isNotEmpty ? cnic : 'N/A', Icons.badge_outlined, t),
              _buildDetailItem('Joining Date', formattedJoinDate, Icons.calendar_today_outlined, t),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailItem(String label, String value, IconData icon, RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.0),
      child: Row(
        children: [
          Icon(icon, size: 15, color: t.accent),
          const SizedBox(width: 8),
          Text('$label: ', style: TextStyle(fontSize: 12, color: t.textSecondary)),
          Text(value, style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _pickTime(BuildContext context, ValueChanged<String> onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked != null && context.mounted) {
      onPicked(picked.format(context));
    }
  }

  Future<void> _saveRecordInstantly(String empId, Map<String, dynamic> record) async {
    try {
      final curUser = LocalStorageService.getActiveUsername();
      await FinanceLocalStorage.saveAttendanceRecord(
        branchId: widget.branchId,
        data: record,
        performedBy: curUser,
      );
      _draftRecords.remove(empId);
    } catch (e) {
      if (mounted) {
        showCustomSnackBar(context, e.toString().replaceAll('Exception: ', ''), error: true);
        setState(() {});
      }
    }
  }

  void _openLeaveRangeDialog(BuildContext context, RoleThemeData t) {
    final curUser = LocalStorageService.getActiveUsername();
    final employees = FinanceLocalStorage.getEmployees(widget.branchId).where((e) => e['isActive'] == true).toList();
    
    if (employees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active employees available.')));
      return;
    }

    String selectedEmployeeId = employees.first['localId']?.toString() ?? '';
    DateTime startDate = DateTime.now();
    DateTime endDate = DateTime.now();
    String selectedStatus = 'leave';
    String selectedLeaveType = 'sick';
    final remarksCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (diagCtx, setDiagState) {
            return AlertDialog(
              backgroundColor: t.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: Text('Apply Leave / Absent Range', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Select Employee:', style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedEmployeeId,
                      dropdownColor: t.bgCard,
                      style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: t.bgCardAlt,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                      ),
                      items: employees.map((emp) {
                        return DropdownMenuItem<String>(
                          value: emp['localId']?.toString() ?? '',
                          child: Text('${emp['name']} (${emp['role']})', style: TextStyle(fontSize: 12.5, color: t.textPrimary)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setDiagState(() => selectedEmployeeId = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    Text('Status:', style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedStatus,
                      dropdownColor: t.bgCard,
                      style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: t.bgCardAlt,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                      ),
                      items: [
                        DropdownMenuItem(value: 'leave', child: Text('Leave', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                        DropdownMenuItem(value: 'absent', child: Text('Absent', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                      ],
                      onChanged: (val) {
                        if (val != null) setDiagState(() => selectedStatus = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    if (selectedStatus == 'leave') ...[
                      Text('Leave Type:', style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: selectedLeaveType,
                        dropdownColor: t.bgCard,
                        style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: t.bgCardAlt,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: t.bgRule), borderRadius: BorderRadius.circular(8)),
                        ),
                        items: [
                          DropdownMenuItem(value: 'sick', child: Text('SICK', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                          DropdownMenuItem(value: 'casual', child: Text('CASUAL', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                          DropdownMenuItem(value: 'annual', child: Text('ANNUAL', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                          DropdownMenuItem(value: 'unpaid', child: Text('UNPAID', style: TextStyle(fontSize: 12.5, color: t.textPrimary))),
                        ],
                        onChanged: (val) {
                          if (val != null) setDiagState(() => selectedLeaveType = val);
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Start Date:', style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: startDate,
                                    firstDate: DateTime(2025),
                                    lastDate: DateTime.now().add(const Duration(days: 365)),
                                  );
                                  if (picked != null) {
                                    setDiagState(() {
                                      startDate = picked;
                                      if (endDate.isBefore(startDate)) endDate = startDate;
                                    });
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: t.bgCardAlt,
                                    border: Border.all(color: t.bgRule),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(DateFormat('d MMM yyyy').format(startDate), style: TextStyle(fontSize: 12, color: t.textPrimary)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('End Date:', style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: endDate.isBefore(startDate) ? startDate : endDate,
                                    firstDate: startDate,
                                    lastDate: DateTime.now().add(const Duration(days: 365)),
                                  );
                                  if (picked != null) {
                                    setDiagState(() => endDate = picked);
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: t.bgCardAlt,
                                    border: Border.all(color: t.bgRule),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(DateFormat('d MMM yyyy').format(endDate), style: TextStyle(fontSize: 12, color: t.textPrimary)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: t.textSecondary))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: Colors.white),
                  onPressed: () async {
                    int count = 0;
                    var curr = DateTime(startDate.year, startDate.month, startDate.day);
                    final limit = DateTime(endDate.year, endDate.month, endDate.day);

                    while (curr.isBefore(limit) || curr.isAtSameMomentAs(limit)) {
                      final dateStr = DateFormat('yyyy-MM-dd').format(curr);
                      final record = {
                        'employeeId': selectedEmployeeId,
                        'date': dateStr,
                        'status': selectedStatus,
                        'leaveType': selectedStatus == 'leave' ? selectedLeaveType : null,
                        'note': remarksCtrl.text.trim().isNotEmpty ? remarksCtrl.text.trim() : 'Applied range leave',
                      };
                      await FinanceLocalStorage.saveAttendanceRecord(
                        branchId: widget.branchId,
                        data: record,
                        performedBy: curUser,
                      );
                      count++;
                      curr = curr.add(const Duration(days: 1));
                    }

                    Navigator.pop(ctx);
                    if (mounted) {
                      setState(() {});
                      showCustomSnackBar(context, 'Successfully applied $count days.');
                    }
                  },
                  child: const Text('Apply Range'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
