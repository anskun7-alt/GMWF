// lib/pages/office/employee_detail_page.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/zkteco_network_service.dart';
import '../../services/staff_patient_link_service.dart';
import 'finance_report_helper.dart';
import 'employee_form_sheet.dart';
import 'shared_widgets.dart';
import 'offboard_dialog.dart';

class EmployeeDetailPage extends StatefulWidget {
  final String employeeId;
  final String userRole;
  final Function(BuildContext context, String employeeId)? openEmployeeForm;

  const EmployeeDetailPage({
    super.key,
    required this.employeeId,
    required this.userRole,
    this.openEmployeeForm,
  });

  @override
  State<EmployeeDetailPage> createState() => _EmployeeDetailPageState();
}

class _EmployeeDetailPageState extends State<EmployeeDetailPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _selectedMonthKey = DateFormat('yyyy-MM').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showOffboardDialog(Map<String, dynamic> emp) async {
    final result = await OffboardDialog.show(
      context,
      employeeData: emp,
      performedBy: widget.userRole,
    );
    if (result == true && mounted) {
      setState(() {});
      AppToast.showSnackBar(context, 
        SnackBar(content: Text('${emp['name'] ?? 'Employee'} has been offboarded.')),
      );
    }
  }

  void _showTransferBranchDialog(Map<String, dynamic> emp) {
    final currentBranchId = emp['branchId']?.toString() ?? 'karachi';
    final allBranches = FinanceLocalStorage.getAllKnownBranches([]);
    final t = RoleThemeScope.dataOf(context);
    final empName = emp['name']?.toString() ?? 'Employee';
    String targetBranchId = allBranches.firstWhereOrNull((b) => b['id'] != currentBranchId)?['id']?.toString() ?? currentBranchId;
    final reasonController = TextEditingController();
    bool isTransferring = false;

    showDialog(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (c, setDlgState) {
          String fromName = allBranches.firstWhereOrNull((b) => b['id'] == currentBranchId)?['name']?.toString() ?? currentBranchId;
          if (currentBranchId == 'karachi-1' || currentBranchId == 'karachi1') fromName = 'Karachi';

          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.bgRule)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF045D48).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF045D48), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Transfer Employee Branch',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary),
                      ),
                      Text(
                        'Relocate active employee across facility branches',
                        style: TextStyle(fontSize: 11, color: t.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transfer $empName to a different branch facility.',
                    style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('CURRENT BRANCH', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: t.textTertiary, letterSpacing: 0.4)),
                              const SizedBox(height: 3),
                              Text(fromName, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: t.textPrimary)),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF045D48).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF045D48), size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('DESTINATION BRANCH', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: t.textTertiary, letterSpacing: 0.4)),
                              const SizedBox(height: 3),
                              DropdownButton<String>(
                                value: targetBranchId,
                                isDense: true,
                                isExpanded: true,
                                underline: const SizedBox.shrink(),
                                dropdownColor: t.bgCard,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF045D48)),
                                items: allBranches.map((b) {
                                  final id = b['id']?.toString() ?? '';
                                  String name = b['name']?.toString() ?? id;
                                  if (id == 'karachi-1' || id == 'karachi1') name = 'Karachi';
                                  return DropdownMenuItem(value: id, child: Text('$name ($id)'));
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) setDlgState(() => targetBranchId = val);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: reasonController,
                    style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Transfer Reason / Notes (Optional)',
                      labelStyle: TextStyle(fontSize: 12, color: t.textSecondary),
                      hintText: 'e.g. Relocation, Staff Rebalancing',
                      hintStyle: TextStyle(fontSize: 11.5, color: t.textTertiary),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF045D48), width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF045D48)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Updates active records, biometric device routes, and cleans up cloud documents from old branch.',
                          style: TextStyle(fontSize: 10.5, color: t.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isTransferring ? null : () => Navigator.pop(dlgCtx),
                child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF045D48),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                icon: isTransferring
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.swap_horiz_rounded, size: 16),
                label: Text(isTransferring ? 'Transferring...' : 'Confirm Transfer', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                onPressed: isTransferring || targetBranchId == currentBranchId
                    ? null
                    : () async {
                        setDlgState(() => isTransferring = true);
                        try {
                          await FinanceLocalStorage.transferEmployee(
                            employeeId: widget.employeeId,
                            fromBranchId: currentBranchId,
                            toBranchId: targetBranchId,
                            performedBy: widget.userRole,
                            reason: reasonController.text.trim().isNotEmpty ? reasonController.text.trim() : null,
                          );
                          if (!mounted) return;
                          setState(() {});
                          if (dlgCtx.mounted) Navigator.pop(dlgCtx);
                          AppToast.showSnackBar(context, 
                            SnackBar(content: Text('✅ $empName transferred to $targetBranchId successfully!')),
                          );
                        } catch (e) {
                          if (!mounted) return;
                          setDlgState(() => isTransferring = false);
                          AppToast.showSnackBar(context, 
                            SnackBar(content: Text('Transfer failed: $e'), backgroundColor: SoftPalette.red400),
                          );
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  void _openQuickEditPinDialog(Map<String, dynamic> emp) {
    final empId = widget.employeeId;
    final empName = emp['name']?.toString() ?? 'Employee';
    final dept = emp['department']?.toString() ?? 'Office';
    final currentPin = (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();
    final ctrl = TextEditingController(text: currentPin);
    bool overwriteConfirmed = false;
    final t = RoleThemeScope.dataOf(context);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final enteredPin = ctrl.text.trim();
          final takenCred = enteredPin.isNotEmpty ? ZkTecoNetworkService.getCredentialByPin(enteredPin) : null;
          final isCollision = takenCred != null && takenCred.entityId != empId;
          final suggestedPins = ZkTecoNetworkService.getSuggestedPinsForDepartment(dept, count: 4, excludeEntityId: empId);

          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.bgRule)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF045D48).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.fingerprint_rounded, color: Color(0xFF045D48), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Biometric PIN Assignment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                      Text('$empName • $dept', style: TextStyle(fontSize: 11.5, color: t.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Assign or update the ZKTeco biometric device punch PIN for $empName. Follows department sequence patterns.',
                    style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                  ),
                  const SizedBox(height: 14),

                  // Suggested PINs chip row for this department
                  if (suggestedPins.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome_rounded, size: 13, color: Color(0xFF045D48)),
                        const SizedBox(width: 5),
                        Text('SUGGESTED FOR ${dept.toUpperCase()}:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: t.textTertiary, letterSpacing: 0.5)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: suggestedPins.take(4).map((sug) {
                        final isSel = sug == ctrl.text.trim();
                        return InkWell(
                          onTap: () {
                            ctrl.text = sug;
                            overwriteConfirmed = false;
                            setDialogState(() {});
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSel ? const Color(0xFF045D48) : const Color(0xFF045D48).withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isSel ? const Color(0xFF045D48) : const Color(0xFF045D48).withValues(alpha: 0.25)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.tag_rounded, size: 12, color: isSel ? Colors.white : const Color(0xFF045D48)),
                                const SizedBox(width: 4),
                                Text(
                                  'PIN $sug',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                    color: isSel ? Colors.white : const Color(0xFF045D48),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                  ],

                  TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: t.textPrimary),
                    onChanged: (_) {
                      overwriteConfirmed = false;
                      setDialogState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: 'Device Punch PIN',
                      labelStyle: TextStyle(fontSize: 12.5, color: t.textSecondary),
                      hintText: 'e.g. ${suggestedPins.isNotEmpty ? suggestedPins.first : '2001'}',
                      hintStyle: TextStyle(fontSize: 12, color: t.textTertiary),
                      prefixIcon: const Icon(Icons.tag_rounded, size: 18),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF045D48), width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                                          : '⚠️ PIN $enteredPin is already taken!',
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
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF045D48),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Save PIN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
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

                  if (ctx.mounted) Navigator.pop(ctx);

                  await ZkTecoNetworkService.assignPinToEntity(
                    entityId: empId,
                    entityName: empName,
                    entityType: 'employee',
                    branchId: emp['branchId']?.toString() ?? 'all',
                    customPin: newPin,
                  );

                  final updated = FinanceLocalStorage.getEmployee(empId);
                  if (updated != null) {
                    updated['biometricPin'] = newPin;
                    updated['pin'] = newPin;
                    await FinanceLocalStorage.saveEmployee(
                      branchId: updated['branchId']?.toString() ?? 'all',
                      data: updated,
                      performedBy: LocalStorageService.getActiveUsername(),
                    );
                  }

                  if (!mounted) return;
                  AppToast.showSnackBar(context, 
                    SnackBar(content: Text('✅ PIN $newPin assigned to $empName!'), backgroundColor: const Color(0xFF045D48)),
                  );
                  setState(() {});
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _calculateTenure(String? joiningDateStr) {
    if (joiningDateStr == null || joiningDateStr.isEmpty) return '';
    try {
      final joined = DateTime.parse(joiningDateStr);
      final now = DateTime.now();
      final difference = now.difference(joined);
      final days = difference.inDays;
      if (days < 0) return 'Future Joining';
      if (days < 30) return '$days days';
      final months = (days / 30.4375).floor();
      if (months < 12) return '$months mos';
      final years = (months / 12).floor();
      final remMonths = months % 12;
      if (remMonths == 0) return '$years yrs';
      return '$years yrs $remMonths mos';
    } catch (_) {
      return '';
    }
  }

  String _getDepartmentRangeDisplay(String? department) {
    final d = (department ?? '').toLowerCase();
    if (d.contains('madrassa') || d.contains('islamic') || d.contains('quran') || d.contains('hifz')) {
      return 'Madrassa Pattern: 3001 - 3999';
    } else if (d.contains('school') || d.contains('education') || d.contains('teacher')) {
      return 'School Pattern: 5001 - 5999';
    } else if (d.contains('dispensary') || d.contains('health') || d.contains('medical') || d.contains('clinic')) {
      return 'Dispensary Pattern: 2001 - 2999';
    } else if (d.contains('kitchen') || d.contains('dasterkhwaan') || d.contains('food')) {
      return 'Kitchen Pattern: 1001 - 1999';
    }
    return 'Office / General Pattern: 101 - 999';
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    return ValueListenableBuilder(
      valueListenable: DebouncedBoxListenable.shared(FinanceLocalStorage.employeesBox),
      builder: (c, Box box, _) {
        final emp = FinanceLocalStorage.getEmployee(widget.employeeId);

        if (emp == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
          return Scaffold(
            backgroundColor: t.bg,
            appBar: AppBar(title: const Text('Employee Details')),
            body: const SizedBox.shrink(),
          );
        }

        final name = emp['name']?.toString() ?? '';
        final role = emp['role']?.toString() ?? emp['designation']?.toString() ?? 'Employee';
        final dept = emp['department']?.toString() ?? 'Office';
        final isActive = emp['isActive'] as bool? ?? true;
        final status = emp['status'] as String? ?? (isActive ? 'Active' : 'Offboarded');

        final curRole = widget.userRole.toLowerCase().trim();
        final empRole = role.toLowerCase().trim();
        final isExecOrAdmin = empRole == 'ceo' ||
            empRole == 'hq manager' ||
            empRole == 'hq_manager' ||
            empRole == 'admin' ||
            empRole == 'chairman';
        final isSuperAdmin = curRole == 'chairman' ||
            curRole == 'admin' ||
            curRole == 'hq manager' ||
            curRole == 'hq_manager' ||
            curRole == 'finance' ||
            curRole == 'hr';
        final canEditEmp = isSuperAdmin || (!isExecOrAdmin);

        return Scaffold(
          backgroundColor: t.bg,
          appBar: _buildAppBar(
            context,
            emp: emp,
            t: t,
            name: name,
            role: role,
            dept: dept,
            isActive: isActive,
            canEditEmp: canEditEmp,
          ),
          body: Column(
            children: [
              // Hero Profile Banner
              _buildHeaderBanner(emp, t, isActive, status),

              // Navigation TabBar
              _buildTabBar(t),

              // TabBar Body
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildProfileTab(emp, t),
                    _buildAttendanceTab(emp, t),
                    _buildLeavesTab(emp, t),
                    _buildHistoryTab(emp, t),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required Map<String, dynamic> emp,
    required RoleThemeData t,
    required String name,
    required String role,
    required String dept,
    required bool isActive,
    required bool canEditEmp,
  }) {
    final branchName = FinanceLocalStorage.getBranchName(emp['branchId']?.toString() ?? '');

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color(0xFF042F2E), // deep teal 950
              Color(0xFF064E3B), // deep emerald 900
              Color(0xFF022C22), // rich islamic emerald
            ],
          ),
        ),
      ),
      leading: Center(
        child: InkWell(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded, size: 13, color: Colors.white),
          ),
        ),
      ),
      leadingWidth: 50,
      titleSpacing: 4,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 15.5,
              letterSpacing: -0.2,
            ),
          ),
          Text(
            '$role • $dept ${branchName.isNotEmpty ? '($branchName)' : ''}',
            style: const TextStyle(
              color: Color(0xFF86EFAC),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      actions: [
        if (isActive && canEditEmp) ...[
          _buildAppBarActionPill(
            icon: Icons.edit_rounded,
            label: 'Edit Profile',
            color: Colors.white,
            onTap: () {
              if (widget.openEmployeeForm != null) {
                widget.openEmployeeForm!(context, widget.employeeId);
              } else {
                openEmployeeFormSheet(
                  context,
                  activeBranchId: emp['branchId']?.toString() ?? 'all',
                  branches: const [],
                  employeeId: widget.employeeId,
                  onSaved: () => setState(() {}),
                );
              }
            },
          ),
          const SizedBox(width: 6),
          _buildAppBarActionPill(
            icon: Icons.swap_horiz_rounded,
            label: 'Transfer',
            color: const Color(0xFFFDE68A),
            onTap: () => _showTransferBranchDialog(emp),
          ),
          const SizedBox(width: 6),
        ],
        _buildAppBarActionPill(
          icon: Icons.medical_services_outlined,
          label: 'Medical',
          color: const Color(0xFF5EEAD4),
          onTap: () => StaffPatientLinkService.openStaffMedicalHistory(
            context,
            name: name,
            cnic: emp['cnic']?.toString(),
            branchId: emp['branchId']?.toString(),
            role: role,
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<String>(
          tooltip: 'More actions & exports',
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: t.bgCard,
          offset: const Offset(0, 42),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.more_horiz_rounded, size: 16, color: Colors.white),
                SizedBox(width: 4),
                Text('More', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          onSelected: (val) {
            if (val == 'pdf_profile') {
              FinanceReportHelper.exportIndividualPdf(widget.employeeId);
            } else if (val == 'pdf_payments') {
              FinanceReportHelper.exportPaymentReportPdf(widget.employeeId);
            } else if (val == 'offboard') {
              _showOffboardDialog(emp);
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(
              value: 'pdf_profile',
              child: Row(
                children: [
                  Icon(Icons.picture_as_pdf_outlined, size: 18, color: Color(0xFF045D48)),
                  SizedBox(width: 10),
                  Text('Export Profile PDF', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'pdf_payments',
              child: Row(
                children: [
                  Icon(Icons.receipt_long_outlined, size: 18, color: Color(0xFF2563EB)),
                  SizedBox(width: 10),
                  Text('Export Payment History PDF', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            if (isActive && canEditEmp) ...[
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'offboard',
                child: Row(
                  children: [
                    Icon(Icons.person_off_outlined, size: 18, color: Color(0xFFDC2626)),
                    SizedBox(width: 10),
                    Text('Offboard Employee', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(width: 12),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: Colors.white.withValues(alpha: 0.12),
        ),
      ),
    );
  }

  Widget _buildAppBarActionPill({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBanner(Map<String, dynamic> emp, RoleThemeData t, bool isActive, String status) {
    final name = emp['name']?.toString() ?? '';
    final role = emp['role']?.toString() ?? emp['designation']?.toString() ?? 'Employee';
    final dept = emp['department']?.toString() ?? 'Office';
    final branchName = FinanceLocalStorage.getBranchName(emp['branchId']?.toString() ?? '');
    final salary = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
    final pin = (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();
    final joiningDate = emp['joiningDate']?.toString() ?? '';
    final tenure = _calculateTenure(joiningDate);

    return Container(
      width: double.infinity,
      color: t.bgCard,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 800;

              return Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Avatar with active status indicator dot
                      Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isActive ? const Color(0xFF10B981) : t.bgRule,
                                width: 2,
                              ),
                            ),
                            child: buildInitialsAvatar(
                              context: context,
                              name: name,
                              theme: t,
                              radius: 32,
                              imageUrl: emp['profilePictureUrl']?.toString(),
                              imagePath: emp['profilePicturePath']?.toString(),
                              gender: emp['gender']?.toString(),
                            ),
                          ),
                          Positioned(
                            bottom: 2,
                            right: 2,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: isActive ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                shape: BoxShape.circle,
                                border: Border.all(color: t.bgCard, width: 2.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 16),

                      // Name, Badges, and Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: t.textPrimary,
                                      letterSpacing: -0.3,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? const Color(0xFF10B981).withValues(alpha: 0.12)
                                        : const Color(0xFFEF4444).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isActive
                                          ? const Color(0xFF10B981).withValues(alpha: 0.3)
                                          : const Color(0xFFEF4444).withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: isActive ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        status.toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                          color: isActive ? const Color(0xFF047857) : const Color(0xFFB91C1C),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _buildIdentityPill(Icons.badge_outlined, role, t),
                                _buildIdentityPill(Icons.domain_rounded, dept, t),
                                if (branchName.isNotEmpty)
                                  _buildIdentityPill(Icons.location_on_outlined, branchName, t),
                                _buildIdentityPill(Icons.tag_rounded, 'ID: ${widget.employeeId}', t),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Desktop KPI Stat tiles on right
                      if (!isCompact) ...[
                        const SizedBox(width: 20),
                        Row(
                          children: [
                            _buildHeroStatTile(
                              icon: Icons.payments_rounded,
                              label: 'SALARY',
                              value: 'PKR ${NumberFormat('#,##0').format(salary.toInt())}',
                              color: const Color(0xFF045D48),
                              t: t,
                            ),
                            const SizedBox(width: 10),
                            InkWell(
                              onTap: () => _openQuickEditPinDialog(emp),
                              borderRadius: BorderRadius.circular(10),
                              child: _buildHeroStatTile(
                                icon: Icons.fingerprint_rounded,
                                label: 'DEVICE PIN',
                                value: pin.isNotEmpty ? 'PIN $pin' : 'Unassigned',
                                color: pin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFF59E0B),
                                t: t,
                                showEditBadge: true,
                              ),
                            ),
                            if (joiningDate.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              _buildHeroStatTile(
                                icon: Icons.calendar_today_rounded,
                                label: 'JOINED',
                                value: joiningDate,
                                subValue: tenure.isNotEmpty ? 'Tenure: $tenure' : null,
                                color: const Color(0xFF6366F1),
                                t: t,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),

                  // Mobile stat tiles
                  if (isCompact) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _buildHeroStatTile(
                            icon: Icons.payments_rounded,
                            label: 'SALARY',
                            value: 'PKR ${NumberFormat('#,##0').format(salary.toInt())}',
                            color: const Color(0xFF045D48),
                            t: t,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: () => _openQuickEditPinDialog(emp),
                            borderRadius: BorderRadius.circular(10),
                            child: _buildHeroStatTile(
                              icon: Icons.fingerprint_rounded,
                              label: 'DEVICE PIN',
                              value: pin.isNotEmpty ? 'PIN $pin' : 'Unassigned',
                              color: pin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFF59E0B),
                              t: t,
                              showEditBadge: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeroStatTile({
    required IconData icon,
    required String label,
    required String value,
    String? subValue,
    required Color color,
    required RoleThemeData t,
    bool showEditBadge = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: t.textTertiary,
                ),
              ),
              const SizedBox(height: 1),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  if (showEditBadge) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.edit_rounded, size: 11, color: color.withValues(alpha: 0.8)),
                  ],
                ],
              ),
              if (subValue != null && subValue.isNotEmpty)
                Text(
                  subValue,
                  style: TextStyle(fontSize: 10, color: t.textTertiary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityPill(IconData icon, String text, RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: t.textSecondary),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(RoleThemeData t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF045D48),
            indicatorWeight: 3,
            labelColor: const Color(0xFF045D48),
            unselectedLabelColor: t.textTertiary,
            labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(icon: Icon(Icons.badge_outlined, size: 18), text: 'Profile Details'),
              Tab(icon: Icon(Icons.event_available_rounded, size: 18), text: 'Attendance Logs'),
              Tab(icon: Icon(Icons.verified_user_outlined, size: 18), text: 'Leave Quotas'),
              Tab(icon: Icon(Icons.history_rounded, size: 18), text: 'Audit History'),
            ],
          ),
        ),
      ),
    );
  }

  // ── Tab 1: Profile & Job Details ───────────────────────────────────────────
  Widget _buildProfileTab(Map<String, dynamic> emp, RoleThemeData t) {
    final salary = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
    final bankName = emp['bankName']?.toString() ?? 'Meezan Bank Limited';
    final iban = emp['bankAccount']?.toString() ?? 'N/A';
    final pin = (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();
    final dept = emp['department']?.toString() ?? 'Office';
    final branchName = FinanceLocalStorage.getBranchName(emp['branchId']?.toString() ?? '');

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 760;

              if (isWide) {
                return Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildEmploymentCard(emp, t, branchName)),
                        const SizedBox(width: 16),
                        Expanded(child: _buildCompensationCard(emp, t, salary, bankName, iban)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildPersonalCard(emp, t)),
                        const SizedBox(width: 16),
                        Expanded(child: _buildBiometricCard(emp, t, pin, dept)),
                      ],
                    ),
                  ],
                );
              } else {
                return Column(
                  children: [
                    _buildEmploymentCard(emp, t, branchName),
                    const SizedBox(height: 16),
                    _buildCompensationCard(emp, t, salary, bankName, iban),
                    const SizedBox(height: 16),
                    _buildPersonalCard(emp, t),
                    const SizedBox(height: 16),
                    _buildBiometricCard(emp, t, pin, dept),
                  ],
                );
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEmploymentCard(Map<String, dynamic> emp, RoleThemeData t, String branchName) {
    return _buildSectionCard(
      title: 'EMPLOYMENT & POSITION',
      icon: Icons.work_outline_rounded,
      accentColor: const Color(0xFF045D48),
      t: t,
      children: [
        _buildInfoTile(
          icon: Icons.calendar_today_rounded,
          label: 'Joining Date',
          value: emp['joiningDate']?.toString() ?? 'Not specified',
          t: t,
        ),
        if (emp['exitDate'] != null && emp['exitDate'].toString().isNotEmpty)
          _buildInfoTile(
            icon: Icons.event_busy_rounded,
            label: 'Exit Date',
            value: emp['exitDate'].toString(),
            accentColor: const Color(0xFFDC2626),
            t: t,
          ),
        _buildInfoTile(
          icon: Icons.domain_rounded,
          label: 'Department',
          value: emp['department']?.toString() ?? 'General Office',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.badge_outlined,
          label: 'Designation / Role',
          value: emp['role']?.toString() ?? emp['designation']?.toString() ?? 'Staff Member',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.location_on_outlined,
          label: 'Assigned Branch',
          value: branchName.isNotEmpty ? branchName : 'Headquarters',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.school_outlined,
          label: 'Education / Qualification',
          value: emp['qualification']?.toString() ?? emp['education']?.toString() ?? 'Not specified',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.calendar_view_week_rounded,
          label: 'Weekly Rest Schedule',
          value: FinanceLocalStorage.getEmployeeWeeklyOffDisplay(emp),
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.weekend_outlined,
          label: 'Sunday Working Status',
          value: (emp['isSundayOff'] == false) ? 'Working Day (Scheduled)' : 'Weekly Off (Excused)',
          accentColor: (emp['isSundayOff'] == false) ? const Color(0xFFD97706) : const Color(0xFF10B981),
          t: t,
        ),
      ],
    );
  }

  Widget _buildCompensationCard(Map<String, dynamic> emp, RoleThemeData t, double salary, String bankName, String iban) {
    return _buildSectionCard(
      title: 'COMPENSATION & BANKING',
      icon: Icons.account_balance_outlined,
      accentColor: const Color(0xFF047857),
      t: t,
      children: [
        _buildInfoTile(
          icon: Icons.payments_rounded,
          label: 'Base Monthly Salary',
          value: 'PKR ${NumberFormat('#,##0').format(salary.toInt())}',
          accentColor: const Color(0xFF045D48),
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.account_balance_rounded,
          label: 'Disbursement Bank',
          value: bankName,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.credit_card_rounded,
          label: 'Account / IBAN',
          value: iban,
          trailing: iban.isNotEmpty && iban != 'N/A'
              ? IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  tooltip: 'Copy IBAN',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: iban));
                    AppToast.showSnackBar(context, const SnackBar(content: Text('IBAN copied to clipboard')));
                  },
                )
              : null,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.receipt_long_rounded,
          label: 'Disbursement Method',
          value: bankName.toLowerCase().contains('cash') ? 'Direct Cash Payment' : 'Bank Transfer',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.security_rounded,
          label: 'Payroll Ledger Status',
          value: (emp['isActive'] ?? true) ? 'Active In Payroll Registry' : 'Excluded From Run',
          accentColor: (emp['isActive'] ?? true) ? const Color(0xFF10B981) : const Color(0xFFEF4444),
          t: t,
        ),
      ],
    );
  }

  Widget _buildPersonalCard(Map<String, dynamic> emp, RoleThemeData t) {
    final cnic = emp['cnic']?.toString() ?? 'N/A';
    final phone = emp['phone']?.toString() ?? 'N/A';

    return _buildSectionCard(
      title: 'PERSONAL & CONTACT DETAILS',
      icon: Icons.person_outline_rounded,
      accentColor: const Color(0xFF2563EB),
      t: t,
      children: [
        _buildInfoTile(
          icon: Icons.badge_outlined,
          label: 'CNIC / Identification',
          value: cnic,
          trailing: cnic.isNotEmpty && cnic != 'N/A'
              ? IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  tooltip: 'Copy CNIC',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: cnic));
                    AppToast.showSnackBar(context, const SnackBar(content: Text('CNIC copied to clipboard')));
                  },
                )
              : null,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.phone_rounded,
          label: 'Contact Phone',
          value: phone,
          trailing: phone.isNotEmpty && phone != 'N/A'
              ? IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  tooltip: 'Copy Phone',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: phone));
                    AppToast.showSnackBar(context, const SnackBar(content: Text('Phone number copied to clipboard')));
                  },
                )
              : null,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.cake_outlined,
          label: 'Date of Birth',
          value: emp['dob']?.toString() ?? 'Not specified',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.people_outline_rounded,
          label: 'Gender',
          value: emp['gender']?.toString() ?? 'Not specified',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.family_restroom_rounded,
          label: 'Relationship Type & Name',
          value: '${emp['relationshipType'] ?? 'Father'}: ${emp['fatherName'] ?? emp['guardianName'] ?? 'N/A'}',
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.home_outlined,
          label: 'Residential Address',
          value: emp['address']?.toString() ?? 'Not specified',
          t: t,
        ),
      ],
    );
  }

  Widget _buildBiometricCard(Map<String, dynamic> emp, RoleThemeData t, String pin, String dept) {
    final deptRange = _getDepartmentRangeDisplay(dept);

    return _buildSectionCard(
      title: 'BIOMETRIC & DEVICE ACCESS',
      icon: Icons.fingerprint_rounded,
      accentColor: const Color(0xFF6366F1),
      headerAction: OutlinedButton.icon(
        icon: const Icon(Icons.edit_rounded, size: 13),
        label: const Text('Edit PIN', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF045D48),
          side: const BorderSide(color: Color(0xFF045D48)),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => _openQuickEditPinDialog(emp),
      ),
      t: t,
      children: [
        _buildInfoTile(
          icon: Icons.fingerprint_rounded,
          label: 'Assigned Device PIN',
          value: pin.isNotEmpty ? 'PIN $pin' : 'No PIN Assigned',
          accentColor: pin.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFFDC2626),
          trailing: pin.isNotEmpty
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                  ),
                  child: const Text('Active', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
                )
              : null,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.auto_awesome_rounded,
          label: 'Department PIN Pattern',
          value: deptRange,
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.router_outlined,
          label: 'Biometric Sync Status',
          value: pin.isNotEmpty ? 'Registered In Device Roster' : 'Needs PIN Enrollment',
          accentColor: pin.isNotEmpty ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
          t: t,
        ),
        _buildInfoTile(
          icon: Icons.access_time_rounded,
          label: 'Attendance Capture Method',
          value: 'Dual Shift Punch (In / Out)',
          t: t,
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Color accentColor,
    required List<Widget> children,
    required RoleThemeData t,
    Widget? headerAction,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: accentColor, size: 16),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: accentColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              if (headerAction != null) headerAction,
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: children,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
    Color? accentColor,
    Widget? trailing,
    required RoleThemeData t,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final tileWidth = cardWidth > 380 ? (cardWidth - 12) / 2 : cardWidth;

        return Container(
          width: tileWidth,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: t.bgCardAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.bgRule.withValues(alpha: 0.8)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (accentColor ?? t.accent).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 15, color: accentColor ?? t.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: t.textTertiary,
                        letterSpacing: 0.4,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: accentColor ?? t.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        );
      },
    );
  }

  // ── Tab 2: Attendance ──────────────────────────────────────────────────────
  Widget _buildAttendanceTab(Map<String, dynamic> emp, RoleThemeData t) {
    final summary = FinanceLocalStorage.getPayrollAttendanceSummary(widget.employeeId, _selectedMonthKey);
    final daysInMonth = (summary['totalDays'] as num?)?.toInt() ?? 30;
    final present = (summary['presentDays'] as num?)?.toDouble() ?? 0.0;
    final lateDays = (summary['lateDays'] as num?)?.toDouble() ?? 0.0;
    final absent = (summary['absentDays'] as num?)?.toDouble() ?? 0.0;
    final paidLeaves = (summary['paidLeaves'] as num?)?.toDouble() ?? 0.0;
    final unpaidLeaves = (summary['unpaidLeaves'] as num?)?.toDouble() ?? 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header & Month Selector
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.bgRule),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: const Color(0xFF045D48).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.event_available_rounded, color: Color(0xFF045D48), size: 18),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Attendance Summary',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                            ),
                            Text(
                              'Monthly audit breakdown and daily punch calendar',
                              style: TextStyle(fontSize: 11, color: t.textSecondary),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.picture_as_pdf_rounded, size: 14),
                          label: const Text('Export Calendar PDF', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF045D48),
                            side: const BorderSide(color: Color(0xFF045D48)),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () async {
                            await FinanceReportHelper.exportAttendanceCalendarPdf(
                              employeeId: widget.employeeId,
                              monthKey: _selectedMonthKey,
                              context: context,
                            );
                          },
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: DropdownButton<String>(
                            value: _selectedMonthKey,
                            dropdownColor: t.bgCard,
                            underline: const SizedBox.shrink(),
                            style: TextStyle(color: t.textPrimary, fontSize: 12.5, fontWeight: FontWeight.bold),
                            icon: const Icon(Icons.calendar_month_rounded, size: 16),
                            onChanged: (val) {
                              if (val != null) setState(() => _selectedMonthKey = val);
                            },
                            items: List.generate(12, (index) {
                              final dt = DateTime(DateTime.now().year, DateTime.now().month - index, 1);
                              final key = DateFormat('yyyy-MM').format(dt);
                              return DropdownMenuItem(value: key, child: Text(DateFormat('MMMM yyyy').format(dt)));
                            }),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // KPI Stats
              GridView.count(
                crossAxisCount: 6,
                shrinkWrap: true,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.6,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildAttendanceMetric('TOTAL DAYS', '$daysInMonth', SoftPalette.blue500, t),
                  _buildAttendanceMetric('PRESENT', present.toStringAsFixed(1).replaceAll('.0', ''), const Color(0xFF10B981), t),
                  _buildAttendanceMetric('LATE DAYS', lateDays.toStringAsFixed(1).replaceAll('.0', ''), const Color(0xFFF59E0B), t),
                  _buildAttendanceMetric('ABSENT DAYS', absent.toStringAsFixed(1).replaceAll('.0', ''), const Color(0xFFEF4444), t),
                  _buildAttendanceMetric('PAID LEAVES', paidLeaves.toStringAsFixed(1).replaceAll('.0', ''), const Color(0xFF0D9488), t),
                  _buildAttendanceMetric('UNPAID LEAVES', unpaidLeaves.toStringAsFixed(1).replaceAll('.0', ''), const Color(0xFF8B5CF6), t),
                ],
              ),
              const SizedBox(height: 16),

              // Monthly Attendance Calendar
              _buildDetailCalendar(summary, daysInMonth, t),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailCalendar(Map<String, dynamic> summary, int daysInMonth, RoleThemeData t) {
    final dailyStatus = (summary['dailyStatus'] as Map<dynamic, dynamic>?)?.map(
          (k, v) => MapEntry(k is int ? k : int.tryParse(k.toString()) ?? 0, v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{}),
        ) ??
        <int, Map<String, dynamic>>{};

    final parts = _selectedMonthKey.split('-');
    final yr = int.tryParse(parts[0]) ?? DateTime.now().year;
    final mo = int.tryParse(parts[1]) ?? DateTime.now().month;
    final firstWeekday = DateTime(yr, mo, 1).weekday; // 1 = Mon, 7 = Sun
    final totalOffset = firstWeekday - 1;
    final totalCells = totalOffset + daysInMonth;
    final roundedTotal = ((totalCells + 6) ~/ 7) * 7;
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.bgRule),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_outlined, size: 16, color: Color(0xFF045D48)),
              const SizedBox(width: 8),
              Text('Monthly Attendance Calendar', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: weekdays.map((w) {
              final isSun = w == 'Sun';
              return Expanded(
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isSun ? SoftPalette.gray350.withValues(alpha: 0.08) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    w,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isSun ? context.adapt(SoftPalette.gray550) : t.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: roundedTotal,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 1.1,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemBuilder: (context, idx) {
              if (idx < totalOffset || idx >= totalCells) {
                return Container(
                  decoration: BoxDecoration(
                    color: t.bg.withValues(alpha: 0.3),
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

              Color cellBg = t.bg;
              Color borderColor = t.bgRule;
              Color textColor = t.textSecondary;
              String badge = '—';

              if (status == 'present') {
                cellBg = context.adapt(SoftPalette.emerald50);
                borderColor = context.adapt(SoftPalette.emerald150);
                textColor = context.adapt(SoftPalette.emerald600);
                badge = '✓ Present';
              } else if (status == 'late') {
                cellBg = context.adapt(SoftPalette.yellow50m);
                borderColor = context.adapt(SoftPalette.yellow150);
                textColor = context.adapt(SoftPalette.orange600);
                badge = '⏱ Late';
              } else if (status == 'leave') {
                cellBg = context.adapt(SoftPalette.slate100);
                borderColor = context.adapt(SoftPalette.slate200);
                textColor = context.adapt(SoftPalette.blue600);
                badge = '🏖 Leave';
              } else if (status == 'holiday') {
                cellBg = context.adapt(SoftPalette.purple50t);
                borderColor = context.adapt(SoftPalette.purple150);
                textColor = context.adapt(SoftPalette.violet600);
                badge = '🎉 Holiday';
              } else if (status == 'off') {
                cellBg = context.adapt(SoftPalette.slate100);
                borderColor = context.adapt(SoftPalette.slate150);
                textColor = context.adapt(SoftPalette.slate600);
                badge = 'Off Day';
              } else if (status == 'absent') {
                cellBg = context.adapt(SoftPalette.red100t);
                borderColor = context.adapt(SoftPalette.red200);
                textColor = context.adapt(SoftPalette.red600);
                badge = '✕ Absent';
              }

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

              return Tooltip(
                message: '${DateFormat('EEE, d MMM yyyy').format(DateTime(yr, mo, day))}\nStatus: ${badge.replaceAll('✓ ', '').replaceAll('⏱ ', '').replaceAll('🏖 ', '').replaceAll('🎉 ', '').replaceAll('✕ ', '')}${punchStr.isNotEmpty ? '\nPunches: $punchStr' : ''}${note != null && note.isNotEmpty ? '\nNote: $note' : ''}',
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: cellBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: borderColor, width: 0.8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('$day', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: status == 'off' ? context.adapt(SoftPalette.gray350) : t.textPrimary)),
                          Text(badge, style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: textColor)),
                        ],
                      ),
                      const Spacer(),
                      if (punchStr.isNotEmpty)
                        Text(
                          punchStr,
                          style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: t.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      else if (note != null && note.isNotEmpty)
                        Text(
                          note,
                          style: TextStyle(fontSize: 7.5, fontStyle: FontStyle.italic, color: context.adapt(SoftPalette.gray350)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegend(SoftPalette.emerald350, 'Present', t),
              const SizedBox(width: 12),
              _buildLegend(SoftPalette.amber300, 'Late', t),
              const SizedBox(width: 12),
              _buildLegend(SoftPalette.blue500, 'Leave', t),
              const SizedBox(width: 12),
              _buildLegend(SoftPalette.violet400, 'Holiday', t),
              const SizedBox(width: 12),
              _buildLegend(SoftPalette.slate550, 'Off Day', t),
              const SizedBox(width: 12),
              _buildLegend(SoftPalette.red400, 'Absent', t),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String label, RoleThemeData t) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: t.textSecondary)),
      ],
    );
  }

  // ── Tab 3: Leaves & Quotas ─────────────────────────────────────────────────
  Widget _buildLeavesTab(Map<String, dynamic> emp, RoleThemeData t) {
    final usage = FinanceLocalStorage.getLeaveUsage(widget.employeeId, DateTime.now().year);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Container(
            decoration: BoxDecoration(
              color: t.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.bgRule),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF045D48).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.verified_user_outlined, color: Color(0xFF045D48), size: 18),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Annual Leave Quotas (${DateTime.now().year})',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                        ),
                        Text(
                          'Entitlements, usage ledger, and accumulated balances',
                          style: TextStyle(fontSize: 11, color: t.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildLeaveRow('Casual Leaves', usage['casual'] ?? 0.0, 10.0, const Color(0xFF2563EB), t),
                const SizedBox(height: 12),
                _buildLeaveRow('Sick Leaves', usage['sick'] ?? 0.0, 8.0, const Color(0xFFD97706), t),
                const SizedBox(height: 12),
                _buildLeaveRow('Annual / Earned Leaves', usage['annual'] ?? 0.0, 14.0, const Color(0xFF059669), t),
                const SizedBox(height: 12),
                _buildLeaveRow('Unpaid / Special Leaves', usage['unpaid'] ?? 0.0, 0.0, const Color(0xFF7C3AED), t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Tab 4: History & Audit Ledger ──────────────────────────────────────────
  Widget _buildHistoryTab(Map<String, dynamic> emp, RoleThemeData t) {
    final history = FinanceLocalStorage.getSalaryHistory(widget.employeeId);
    final transfers = FinanceLocalStorage.getTransfersForEmployee(widget.employeeId);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Salary History
              Container(
                decoration: BoxDecoration(
                  color: t.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.bgRule),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: const Color(0xFF045D48).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.history_rounded, color: Color(0xFF045D48), size: 18),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Salary Revision & Adjustment History',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (history.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, size: 16, color: t.textTertiary),
                            const SizedBox(width: 8),
                            Text('No historical salary adjustments logged for this employee.', style: TextStyle(color: t.textTertiary, fontSize: 12)),
                          ],
                        ),
                      )
                    else
                      ...history.map((h) {
                        final amt = (h['amount'] as num?)?.toDouble() ?? 0.0;
                        final date = h['effectiveDate']?.toString() ?? 'N/A';
                        final reason = h['reason']?.toString() ?? 'Adjustment';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(reason, style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 13)),
                                  const SizedBox(height: 2),
                                  Text('Effective Date: $date', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                ],
                              ),
                              Text('PKR ${NumberFormat('#,##0').format(amt.toInt())}', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF045D48), fontSize: 13.5)),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Branch Transfer History
              Container(
                decoration: BoxDecoration(
                  color: t.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.bgRule),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF2563EB), size: 18),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Branch Relocation & Transfer Timeline',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (transfers.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, size: 16, color: t.textTertiary),
                            const SizedBox(width: 8),
                            Text('No branch transfers recorded.', style: TextStyle(color: t.textTertiary, fontSize: 12)),
                          ],
                        ),
                      )
                    else
                      ...transfers.map((tr) {
                        final from = FinanceLocalStorage.getBranchName(tr['fromBranchId']?.toString() ?? '');
                        final to = FinanceLocalStorage.getBranchName(tr['toBranchId']?.toString() ?? '');
                        final date = tr['transferDate']?.toString() ?? 'N/A';
                        final reason = tr['reason']?.toString() ?? '';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.compare_arrows_rounded, color: Color(0xFF2563EB), size: 16),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('$from ➔ $to', style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 13)),
                                    const SizedBox(height: 2),
                                    Text('Transfer Date: $date${reason.isNotEmpty ? ' • Reason: $reason' : ''}', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper Widgets ────────────────────────────────────────────────────────
  Widget _buildAttendanceMetric(String label, String value, Color color, RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 0.3, color: t.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildLeaveRow(String label, double used, double total, Color color, RoleThemeData t) {
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.bgRule)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 13)),
              Text('${used.toStringAsFixed(1)} / ${total > 0 ? total.toStringAsFixed(0) : '∞'} Days', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: progress, backgroundColor: t.bgRule, color: color, minHeight: 6),
            ),
          ],
        ],
      ),
    );
  }
}
