// lib/pages/office/employees_tab.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_ledger_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/permission_service.dart';
import 'shared_widgets.dart';
import 'employee_form_sheet.dart';
import 'employee_detail_page.dart';
import 'finance_report_helper.dart';
import 'employee_report_page.dart';
import 'offboard_dialog.dart';
import '../settings/biometric_device_manager_page.dart';
import '../../services/zkteco_network_service.dart';
import '../../services/user_theme_service.dart';
import '../../services/staff_patient_link_service.dart';


class EmployeesTab extends StatefulWidget {
  final String branchId;
  final String userRole;
  final Function(BuildContext context, String? employeeId) openEmployeeForm;
  final List<Map<String, dynamic>> branches;

  const EmployeesTab({
    super.key,
    required this.branchId,
    required this.userRole,
    required this.openEmployeeForm,
    required this.branches,
  });

  @override
  State<EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends State<EmployeesTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _roleFilter = 'All';
  String _deptFilter = 'All';
  String _statusFilter = 'Active';
  String _branchFilter = 'All';
  String _enrollmentFilter = 'All'; // 'All', 'Enrolled', 'Not Enrolled'

  // Multi-select state (for batch offboard & delete only)
  bool _isSelectionMode = false;
  final Set<String> _selectedEmployeeIds = <String>{};

  void _toggleEmployeeSelection(String empId) {
    if (empId.isEmpty) return;
    setState(() {
      if (_selectedEmployeeIds.contains(empId)) {
        _selectedEmployeeIds.remove(empId);
        if (_selectedEmployeeIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedEmployeeIds.add(empId);
        _isSelectionMode = true;
      }
    });
  }

  void _selectAllEmployees(List<Map<String, dynamic>> visibleEmployees) {
    setState(() {
      final allIds = visibleEmployees
          .map((e) => e['localId']?.toString() ?? e['employeeId']?.toString() ?? e['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      if (_selectedEmployeeIds.containsAll(allIds) && allIds.isNotEmpty) {
        _selectedEmployeeIds.clear();
        _isSelectionMode = false;
      } else {
        _selectedEmployeeIds.addAll(allIds);
        _isSelectionMode = true;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedEmployeeIds.clear();
      _isSelectionMode = false;
    });
  }

  // Defaults used to decide whether a filter counts as "active" for the
  // Filters button badge + removable chip row. See redesign plan §3.C:
  // "only expand to full row width once a filter is actively applied,
  // showing it as a removable chip."
  static const String _defaultStatus = 'Active';

  String _getBranchName(String id) {
    final match = widget.branches.firstWhereOrNull((b) => b['id'] == id);
    return match != null ? (match['name']?.toString() ?? id) : id;
  }

  int get _activeFilterCount {
    int count = 0;
    if (_roleFilter != 'All') count++;
    if (_deptFilter != 'All') count++;
    if (_branchFilter != 'All') count++;
    if (_statusFilter != _defaultStatus) count++;
    if (_enrollmentFilter != 'All') count++;
    return count;
  }

  String _normalizeBranchKey(Map<String, dynamic> emp) {
    final raw = emp['branchId']?.toString().trim() ?? '';
    if (raw.isEmpty || raw.toLowerCase() == 'unknown' || raw.toLowerCase() == 'null') {
      final allowed = emp['allowedBranches'] ?? emp['branches'];
      if (allowed is List && allowed.isNotEmpty) {
        return allowed.first.toString();
      }
      return 'Karachi';
    }
    return raw;
  }

  String _normalizeDepartmentKey(Map<String, dynamic> emp) {
    final raw = emp['department']?.toString().trim() ?? '';
    if (raw.isEmpty || raw.toLowerCase() == 'unknown' || raw.toLowerCase() == 'null' || raw.toLowerCase() == 'unassigned') {
      final role = (emp['role'] ?? '').toString().toLowerCase();
      if (role.contains('doc') || role.contains('dispens') || role.contains('nurse')) return 'Dispensary';
      if (role.contains('teach') || role.contains('school') || role.contains('madrassa')) return 'Education';
      if (role.contains('account') || role.contains('cashier') || role.contains('finance')) return 'Finance';
      if (role.contains('manager') || role.contains('admin') || role.contains('coord')) return 'Administration';
      return 'General Staff';
    }
    return raw;
  }

  String _displayBranchName(String branchKey) {
    if (branchKey == 'Unassigned') return 'Unassigned';
    return _getBranchName(branchKey);
  }

  Color _mutedColorForKey(String key) {
    final seed = key.hashCode;
    final hue = (seed % 360).toDouble();
    final h = (hue + 360) % 360;
    final col = HSLColor.fromAHSL(1.0, h, 0.28, 0.88).toColor();
    return col;
  }

  bool get _isBranchScopedUser {
    final role = widget.userRole.isNotEmpty ? widget.userRole.toLowerCase().trim() : LocalStorageService.getActiveUserRole();
    return role == 'branch manager' || role == 'supervisor' || role == 'bm';
  }

  String _getEffectiveUserBranch() {
    final curUser = LocalStorageService.getActiveUserData();
    if (curUser.isNotEmpty) {
      final bId = (curUser['branchId']?.toString() ?? '').trim();
      if (bId.isNotEmpty && bId != 'all' && bId != 'global') return bId;
    }
    return widget.branchId.isNotEmpty ? widget.branchId : 'karachi';
  }

  @override
  void initState() {
    super.initState();
    if (_isBranchScopedUser) {
      _branchFilter = _getEffectiveUserBranch();
    }
    // Sanitize employee profile names and status on startup
    FinanceLocalStorage.sanitizeEmployeeProfiles().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(EmployeesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isBranchScopedUser) {
      _branchFilter = _getEffectiveUserBranch();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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

        return Scaffold(
          backgroundColor: t.bg,
          body: ValueListenableBuilder(
            valueListenable: FinanceLocalStorage.employeesBox.listenable(),
            builder: (context, Box box, _) {
              final query = _searchCtrl.text.trim().toLowerCase();
              final list = FinanceLocalStorage.getEmployees(widget.branchId).where((emp) {
                final role = (emp['role'] ?? emp['linkedUserRole'] ?? emp['designation'] ?? '').toString().toLowerCase().trim();
                final dept = (emp['department'] ?? emp['linkedDepartment'] ?? '').toString().toLowerCase().trim();
                if (role.contains('guardian') || role.contains('patient') || dept.contains('guardian') || dept.contains('patient') || emp['isEmployee'] == false) {
                  return false;
                }

                // Apply role
                if (_roleFilter != 'All' && emp['role'] != _roleFilter) return false;
                // Apply dept
                if (_deptFilter != 'All' && emp['department'] != _deptFilter) return false;
                // Apply branch
                if (_branchFilter != 'All') {
                  final String empBranch = (emp['branchId']?.toString() ?? '').toLowerCase();
                  final String selectedB = _branchFilter.toLowerCase();
                  final allowed = emp['allowedBranches'] ?? emp['branches'];
                  bool matchAllowed = false;
                  if (allowed is List) {
                    matchAllowed = allowed.any((b) => b.toString().toLowerCase().contains(selectedB) || b.toString().toLowerCase() == 'all');
                  } else if (allowed is String) {
                    matchAllowed = allowed.toLowerCase().contains(selectedB) || allowed.toLowerCase() == 'all';
                  }

                  if (selectedB.contains('karachi')) {
                    if (!empBranch.contains('karachi') && empBranch != 'all' && empBranch != 'global' && !matchAllowed) return false;
                  } else {
                    if (emp['branchId'] != _branchFilter && empBranch != 'all' && empBranch != 'global' && !matchAllowed) return false;
                  }
                }
                // Apply status
                final isActive = emp['isActive'] as bool? ?? true;
                final status = emp['status'] as String? ?? (isActive ? 'Active' : 'Left');
                if (_statusFilter == 'Active' && status != 'Active') return false;
                if (_statusFilter == 'Archived' && status != 'Archived') return false;
                if (_statusFilter == 'Temporary Leave' && status != 'Temporary Leave') return false;
                if (_statusFilter == 'Left' && status != 'Left') return false;
                if (_statusFilter == 'Inactive' && status == 'Active') return false;

                // Apply Biometric Enrollment status
                if (_enrollmentFilter != 'All') {
                  final empId = emp['localId']?.toString() ?? emp['id']?.toString() ?? '';
                  final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                  final isEnrolled = cred != null && cred.active && cred.biometricPin.isNotEmpty;
                  if (_enrollmentFilter == 'Enrolled' && !isEnrolled) return false;
                  if (_enrollmentFilter == 'Not Enrolled' && isEnrolled) return false;
                }

                if (query.isNotEmpty) {
                  final name = emp['name']?.toString().toLowerCase() ?? '';
                  final cnic = emp['cnic']?.toString().toLowerCase() ?? '';
                  final phone = emp['phone']?.toString().toLowerCase() ?? '';
                  return name.contains(query) || cnic.contains(query) || phone.contains(query);
                }
                return true;
              }).toList();

              return Column(
                children: [
                  _buildFilterBar(t, list),
                  Expanded(
                    child: list.isEmpty
                        ? _buildEmptyState(t)
                        : _buildGroupedEmployeeList(t, list),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // ── Filter bar ─────────────────────────────────────────────────────────────
  // Redesign plan §3.C: collapse the 4 always-visible dropdowns into a single
  // "Filters" button (badge shows active count). Tapping opens a compact
  // panel; whatever is actively applied shows as a removable chip below,
  Widget _buildStageTabPill(String label, int count, bool isSelected, VoidCallback onTap, Color activeColor, RoleThemeData t) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.12) : t.bgCardAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor.withValues(alpha: 0.5) : t.bgRule,
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
                color: isSelected ? activeColor.withValues(alpha: 0.2) : t.bgRule.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                "$count",
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? activeColor : t.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(RoleThemeData t, List<Map<String, dynamic>> currentFilteredList) {
    final selectedCount = _selectedEmployeeIds.length;
    final allIds = currentFilteredList
        .map((e) => e['localId']?.toString() ?? e['employeeId']?.toString() ?? e['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final isAllSelected = allIds.isNotEmpty && _selectedEmployeeIds.containsAll(allIds);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            color: t.textPrimary,
            tooltip: 'Cancel Selection',
            onPressed: _clearSelection,
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$selectedCount Selected',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: () => _selectAllEmployees(currentFilteredList),
            icon: Icon(
              isAllSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: t.accent,
            ),
            label: Text(
              isAllSelected ? 'Deselect All' : 'Select All (${currentFilteredList.length})',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.accent),
            ),
          ),
          const Spacer(),
          // STRICTLY ONLY OFFBOARD & DELETE BUTTONS (NO EDIT OR OTHER ACTIONS)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEA580C),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.person_off_rounded, size: 16),
            label: Text(
              'Offboard ($selectedCount)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            onPressed: selectedCount == 0 ? null : () => _showBatchOffboardDialog(context, t, currentFilteredList),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.delete_forever_rounded, size: 16),
            label: Text(
              'Delete ($selectedCount)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            onPressed: selectedCount == 0 ? null : () => _showBatchDeleteDialog(context, t),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(RoleThemeData t, List<Map<String, dynamic>> currentFilteredList) {
    final allList = FinanceLocalStorage.getEmployees(widget.branchId).where((emp) {
      final role = (emp['role'] ?? emp['linkedUserRole'] ?? emp['designation'] ?? '').toString().toLowerCase().trim();
      final dept = (emp['department'] ?? emp['linkedDepartment'] ?? '').toString().toLowerCase().trim();
      return !(role.contains('guardian') || role.contains('patient') || dept.contains('guardian') || dept.contains('patient') || emp['isEmployee'] == false);
    }).toList();

    final activeCount = allList.where((e) => (e['isActive'] as bool? ?? true) && (e['status'] ?? 'Active') == 'Active').length;
    final leaveCount = allList.where((e) => (e['status'] ?? '') == 'Temporary Leave').length;
    final leftCount = allList.where((e) => !(e['isActive'] as bool? ?? true) || (e['status'] ?? '') == 'Left' || (e['status'] ?? '') == 'Archived').length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildStageTabPill('All Staff', allList.length, _statusFilter == 'All', () => setState(() => _statusFilter = 'All'), const Color(0xFF3B82F6), t),
                const SizedBox(width: 8),
                _buildStageTabPill('Active', activeCount, _statusFilter == 'Active', () => setState(() => _statusFilter = 'Active'), const Color(0xFF10B981), t),
                const SizedBox(width: 8),
                _buildStageTabPill('On Leave', leaveCount, _statusFilter == 'Temporary Leave', () => setState(() => _statusFilter = 'Temporary Leave'), const Color(0xFFF59E0B), t),
                const SizedBox(width: 8),
                _buildStageTabPill('Left / Inactive', leftCount, _statusFilter == 'Left' || _statusFilter == 'Inactive', () => setState(() => _statusFilter = 'Left'), const Color(0xFF6B7280), t),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_isSelectionMode)
            _buildSelectionBar(t, currentFilteredList)
          else
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      style: TextStyle(color: t.textPrimary, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search by name, CNIC, phone...',
                        hintStyle: TextStyle(color: t.textTertiary, fontSize: 13),
                        prefixIcon: Icon(Icons.search, color: t.textTertiary, size: 20),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _openFiltersSheet(context, t),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _activeFilterCount > 0 ? t.accent.withOpacity(0.12) : t.bgCardAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _activeFilterCount > 0 ? t.accent.withOpacity(0.5) : t.bgRule),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune_rounded, size: 18, color: _activeFilterCount > 0 ? t.accent : t.textSecondary),
                        const SizedBox(width: 6),
                        Text('Filters', style: TextStyle(color: _activeFilterCount > 0 ? t.accent : t.textSecondary, fontSize: 13, fontWeight: FontWeight.bold)),
                        if (_activeFilterCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(10)),
                            child: Text('$_activeFilterCount', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Select Multiple to Offboard / Delete',
                  child: Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: IconButton(
                      icon: Icon(Icons.checklist_rounded, color: t.accent, size: 22),
                      onPressed: () {
                        setState(() {
                          _isSelectionMode = true;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Apply Annual Increments',
                  child: Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: t.accentMuted,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.accent.withOpacity(0.3)),
                    ),
                    child: IconButton(
                      icon: Icon(Icons.trending_up, color: t.accent, size: 20),
                      onPressed: () => _openAnnualIncrementsDialog(context),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'ZKTeco Devices & Fingerprint PINs',
                  child: Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.fingerprint_rounded, color: Color(0xFF059669), size: 22),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BiometricDeviceManagerPage(branchId: widget.branchId),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Merge Duplicate Staff Profiles',
                  child: Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F3FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.3)),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.merge_type_rounded, color: Color(0xFF7C3AED), size: 20),
                      onPressed: () => _openMergeStaffDialog(context, t),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Sanitize & Verify Employee Records',
                  child: Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.cleaning_services_rounded, color: Color(0xFF059669), size: 20),
                      onPressed: () async {
                        final sanitized = await FinanceLocalStorage.sanitizeEmployeeProfiles();
                        if (mounted) {
                          setState(() {});
                          showCustomSnackBar(
                            context,
                            '✅ Cleaned and verified ${sanitized.length} employee records.',
                          );
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: () => widget.openEmployeeForm(context, null),
                ),
              ],
            ),
          if (_activeFilterCount > 0 && !_isSelectionMode) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_roleFilter != 'All')
                  _buildFilterChip('Role: $_roleFilter', t, () => setState(() => _roleFilter = 'All')),
                if (_deptFilter != 'All')
                  _buildFilterChip('Dept: $_deptFilter', t, () => setState(() => _deptFilter = 'All')),
                if (_branchFilter != 'All')
                  _buildFilterChip('Branch: ${_getBranchName(_branchFilter)}', t, () => setState(() => _branchFilter = 'All')),
                if (_statusFilter != _defaultStatus)
                  _buildFilterChip('Status: $_statusFilter', t, () => setState(() => _statusFilter = _defaultStatus)),
                if (_enrollmentFilter != 'All')
                  _buildFilterChip('Biometrics: $_enrollmentFilter', t, () => setState(() => _enrollmentFilter = 'All')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, RoleThemeData t, VoidCallback onRemove) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: t.accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.accent.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: t.accent, fontSize: 11, fontWeight: FontWeight.bold)),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(5.0),
              child: Icon(Icons.close_rounded, size: 13, color: t.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _openFiltersSheet(BuildContext context, RoleThemeData t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (innerCtx, setSheetState) {
            final List<String> filterDepts = ['All', 'Administration', 'Office', 'Dasterkhwaan', 'Dispensary', 'Madrassa', 'School']
              ..addAll(FinanceLocalStorage.getCustomDepartments());
            if (!filterDepts.contains(_deptFilter)) _deptFilter = 'All';

            final List<String> filterRoles = ['All'];
            if (_deptFilter == 'All') {
              final allRoles = <String>{};
              for (final d in ['Administration', 'Office', 'Dasterkhwaan', 'Dispensary', 'Madrassa', 'School']) {
                allRoles.addAll(FinanceLocalStorage.getRolesForDepartment(d));
              }
              for (final cd in FinanceLocalStorage.getCustomDepartments()) {
                allRoles.addAll(FinanceLocalStorage.getRolesForDepartment(cd));
              }
              allRoles.addAll(FinanceLocalStorage.getCustomRoles());
              filterRoles.addAll(allRoles);
            } else {
              filterRoles.addAll(FinanceLocalStorage.getRolesForDepartment(_deptFilter));
            }
            if (!filterRoles.contains(_roleFilter)) _roleFilter = 'All';

            return Padding(
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(innerCtx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Filter Employees', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                      TextButton(
                        onPressed: () {
                          setSheetState(() {
                            _roleFilter = 'All';
                            _deptFilter = 'All';
                            _branchFilter = 'All';
                            _statusFilter = _defaultStatus;
                            _enrollmentFilter = 'All';
                          });
                          setState(() {});
                        },
                        child: Text('Reset', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  buildDropdownField(
                    label: 'Biometric Enrollment',
                    value: _enrollmentFilter,
                    items: const ['All', 'Enrolled', 'Not Enrolled'],
                    onChanged: (val) {
                      setSheetState(() => _enrollmentFilter = val!);
                      setState(() {});
                    },
                    theme: t,
                  ),
                  buildDropdownField(
                    label: 'Role',
                    value: _roleFilter,
                    items: filterRoles,
                    onChanged: (val) {
                      setSheetState(() => _roleFilter = val!);
                      setState(() {});
                    },
                    theme: t,
                  ),
                  buildDropdownField(
                    label: 'Department',
                    value: _deptFilter,
                    items: filterDepts,
                    onChanged: (val) {
                      setSheetState(() {
                        _deptFilter = val!;
                        _roleFilter = 'All';
                      });
                      setState(() {});
                    },
                    theme: t,
                  ),
                  if (_isBranchScopedUser) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFA7F3D0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_rounded, size: 16, color: Color(0xFF059669)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Branch: ${_getBranchName(_branchFilter)} (Locked)',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF064E3B)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (widget.branches.length > 1)
                    StatefulBuilder(
                      builder: (filterBranchCtx, setFilterBranchState) {
                        final allBranches = FinanceLocalStorage.getAllBranches(widget.branches);
                        final cleanBranches = <String, String>{};
                        for (final b in allBranches) {
                          final id = b['id']?.toString().trim() ?? '';
                          final name = b['name']?.toString().trim() ?? id;
                          if (id.isNotEmpty && id.toLowerCase() != 'all' && id != 'karachi-2' && id != 'karachi2') {
                            cleanBranches[id] = (id == 'karachi-1' || id == 'karachi1') ? 'Karachi' : name;
                          }
                        }

                        final List<DropdownMenuItem<String>> menuItems = [
                          const DropdownMenuItem(value: 'All', child: Text('All Branches')),
                          ...cleanBranches.entries.map((e) => DropdownMenuItem(value: e.key, child: Text('${e.value} (${e.key})'))),
                          const DropdownMenuItem(
                            value: '+ Add Custom Branch...',
                            child: Text('+ Add Custom Branch...', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ];

                        final safeVal = menuItems.any((it) => it.value == _branchFilter)
                            ? _branchFilter
                            : (menuItems.any((it) => it.value?.toLowerCase() == _branchFilter.toLowerCase())
                                ? menuItems.firstWhere((it) => it.value?.toLowerCase() == _branchFilter.toLowerCase()).value!
                                : 'All');

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: DropdownButtonFormField<String>(
                            value: safeVal,
                            dropdownColor: t.bgCard,
                            decoration: InputDecoration(
                              labelText: 'Branch',
                              labelStyle: TextStyle(color: t.textSecondary, fontSize: 11),
                              border: InputBorder.none,
                              filled: false,
                            ),
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            items: menuItems,
                            onChanged: (val) {
                              if (val == '+ Add Custom Branch...') {
                                showCustomBranchDialog(
                                  context: sheetCtx,
                                  theme: t,
                                  onAdded: (newId, newName) {
                                    setSheetState(() {
                                      _branchFilter = newId;
                                    });
                                    setState(() {});
                                  },
                                );
                              } else if (val != null) {
                                setSheetState(() => _branchFilter = val);
                                setState(() {});
                              }
                            },
                          ),
                        );
                      },
                    ),
                  buildDropdownField(
                    label: 'Status',
                    value: _statusFilter,
                    items: const ['Active', 'Inactive', 'Archived', 'Temporary Leave', 'Left', 'All'],
                    onChanged: (val) {
                      setSheetState(() => _statusFilter = val!);
                      setState(() {});
                    },
                    theme: t,
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text('Show Results', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGroupedEmployeeList(RoleThemeData t, List<Map<String, dynamic>> list) {
    final grouped = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final emp in list) {
      final branchKey = _normalizeBranchKey(emp);
      final deptKey = _normalizeDepartmentKey(emp);
      grouped.putIfAbsent(branchKey, () => {});
      grouped[branchKey]!.putIfAbsent(deptKey, () => []);
      grouped[branchKey]![deptKey]!.add(emp);
    }

    final sortedBranches = grouped.keys.toList()..sort((a, b) {
      if (a == 'Unassigned') return 1;
      if (b == 'Unassigned') return -1;
      return a.compareTo(b);
    });

    final displayItems = <Map<String, dynamic>>[];
    for (final branchKey in sortedBranches) {
      final branchDepts = grouped[branchKey]!;
      final sortedDepartments = FinanceLedgerStorage.sortDepartmentsCanonical(branchDepts.keys);

      final branchCount = sortedDepartments.fold<int>(0, (count, deptKey) => count + branchDepts[deptKey]!.length);
      displayItems.add({'type': 'branchHeader', 'branchName': _displayBranchName(branchKey), 'count': branchCount});

      for (final deptKey in sortedDepartments) {
        final deptItems = List<Map<String, dynamic>>.from(branchDepts[deptKey]!..sort((a, b) {
          final aName = (a['name'] ?? '').toString().toLowerCase();
          final bName = (b['name'] ?? '').toString().toLowerCase();
          return aName.compareTo(bName);
        }));
        displayItems.add({'type': 'departmentHeader', 'departmentName': deptKey, 'count': deptItems.length});
        for (final emp in deptItems) {
          displayItems.add({'type': 'employee', 'employee': emp});
        }
      }
    }

    return RefreshIndicator(
      onRefresh: () async {
        await FinanceLocalStorage.downloadEmployees(widget.branchId, force: true);
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        itemCount: displayItems.length,
        itemBuilder: (ctx, i) {
          final item = displayItems[i];
          switch (item['type']) {
            case 'branchHeader':
              return _buildBranchHeader(item['branchName'] as String, item['count'] as int, t);
            case 'departmentHeader':
              return _buildDepartmentHeader(item['departmentName'] as String, item['count'] as int, t);
            default:
              return _buildEmployeeRow(t, item['employee'] as Map<String, dynamic>);
          }
        },
      ),
    );
  }

  Widget _buildBranchHeader(String branchName, int count, RoleThemeData t) {
    final col = _mutedColorForKey(branchName);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      width: double.infinity,
      decoration: BoxDecoration(
        color: col.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: col.withOpacity(0.12)),
      ),
      child: Row(
        children: [
          Container(width: 6, height: 24, decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(
            branchName.toUpperCase(),
            style: TextStyle(
              color: col.withOpacity(0.95),
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: col.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count EMPLOYEES',
              style: TextStyle(
                color: col.withOpacity(0.95),
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDepartmentHeader(String departmentName, int count, RoleThemeData t) {
    final isOffice = departmentName.toUpperCase().contains('OFFICE');
    final isDark = UserThemeService.isDarkMode();
    final headerBg = isOffice
        ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : const Color(0xFFECFDF5))
        : t.bgCardAlt;
    final headerBorder = isOffice
        ? (isDark ? const Color(0xFF059669).withValues(alpha: 0.5) : const Color(0xFFA7F3D0))
        : t.bgRule;
    final iconColor = isOffice ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059669)) : t.accent;
    final titleColor = isOffice ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF064E3B)) : t.textPrimary;

    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: headerBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: headerBorder, width: isOffice ? 1.5 : 1.0),
        boxShadow: isOffice ? [
          BoxShadow(color: (isDark ? const Color(0xFF10B981) : const Color(0xFF059669)).withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2)),
        ] : [],
      ),
      child: Row(
        children: [
          Icon(
            isOffice ? Icons.business_rounded : Icons.label_outline_rounded,
            color: iconColor,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            departmentName.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: titleColor,
              letterSpacing: 0.8,
            ),
          ),
          if (isOffice) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF059669),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'TOP',
                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.5),
              ),
            ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: isOffice ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.4) : const Color(0xFF059669).withValues(alpha: 0.12)) : t.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isOffice ? (isDark ? const Color(0xFF059669).withValues(alpha: 0.5) : const Color(0xFFA7F3D0)) : t.bgRule),
            ),
            child: Text(
              '$count EMPLOYEE${count == 1 ? '' : 'S'}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: isOffice ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059669)) : t.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Employee row (branches.dart aesthetic + 3-dot action menu) ─────────────
  Widget _buildEmployeeRow(RoleThemeData t, Map<String, dynamic> emp) {
    final isDark = UserThemeService.isDarkMode();
    final rawName = emp['name']?.toString().trim() ?? '';
    final pin = (emp['biometricPin'] ?? emp['pin'] ?? '').toString().trim();
    final name = (rawName.isNotEmpty && rawName != '.' && rawName.toLowerCase() != 'employee')
        ? rawName
        : (emp['username']?.toString().isNotEmpty == true
            ? emp['username'].toString()
            : (pin.isNotEmpty ? 'Staff (PIN $pin)' : 'Employee'));

    final role = emp['role']?.toString().trim() ?? '';
    final dept = emp['department']?.toString().trim() ?? '';
    final empId = emp['localId']?.toString() ?? '';
    final isSelected = _selectedEmployeeIds.contains(empId);
    final isActive = emp['isActive'] as bool? ?? true;
    final status = emp['status'] as String? ?? (isActive ? 'Active' : 'Left');
    final branchName = _getBranchName(emp['branchId']?.toString() ?? '');

    final subtitleParts = [
      if (role.isNotEmpty && role.toLowerCase() != 'staff') role,
      if (dept.isNotEmpty && dept.toLowerCase() != 'unassigned' && dept.toLowerCase() != 'general') dept,
    ];
    final subtitle = subtitleParts.isNotEmpty
        ? subtitleParts.join(' • ')
        : (role.isNotEmpty ? role : (dept.isNotEmpty ? dept : (branchName.isNotEmpty ? branchName : 'Staff Member')));

    final rawCnic = emp['cnic']?.toString().trim() ?? '';
    final hasCnic = rawCnic.isNotEmpty && rawCnic != '-' && rawCnic != 'N/A';
    final cleanCnic = rawCnic.replaceAll(RegExp(r'[^0-9]'), '');
    final formattedCnic = (cleanCnic.length == 13)
        ? '${cleanCnic.substring(0, 5)}-${cleanCnic.substring(5, 12)}-${cleanCnic.substring(12)}'
        : rawCnic;

    final rawPhone = emp['phone']?.toString().trim() ?? '';
    final hasPhone = rawPhone.isNotEmpty && rawPhone != '-' && rawPhone != 'N/A';

    final statusColor = isActive
        ? (status == 'Temporary Leave' ? const Color(0xFFF59E0B) : const Color(0xFF10B981))
        : const Color(0xFFEF4444);
    final statusLabel = status.toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? t.accent.withValues(alpha: isDark ? 0.16 : 0.08) : t.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? t.accent : t.bgRule,
          width: isSelected ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? t.accent.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: isSelected ? 8 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () {
            if (_isSelectionMode) {
              _toggleEmployeeSelection(empId);
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EmployeeDetailPage(
                    employeeId: empId,
                    userRole: widget.userRole,
                    openEmployeeForm: widget.openEmployeeForm,
                  ),
                ),
              );
            }
          },
          onLongPress: () => _toggleEmployeeSelection(empId),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: Top Bar (PIN Badge + Department Pill on Left, Status Pill on Right)
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
                          Builder(builder: (_) {
                            final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                            final isEnrolled = cred != null && cred.active && cred.biometricPin.isNotEmpty;
                            final displayPin = isEnrolled ? cred.biometricPin : (pin.isNotEmpty ? pin : '');
                            final hasPin = displayPin.isNotEmpty;
                            final pinColor = hasPin ? const Color(0xFF10B981) : const Color(0xFFF59E0B);

                            return InkWell(
                              onTap: _isSelectionMode
                                  ? null
                                  : () => _showEditPinDialog(
                                        context,
                                        empId,
                                        name,
                                        displayPin,
                                        emp['branchId']?.toString() ?? widget.branchId,
                                      ),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                                decoration: BoxDecoration(
                                  color: pinColor.withValues(alpha: isDark ? 0.2 : 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: pinColor.withValues(alpha: isDark ? 0.4 : 0.25)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.fingerprint_rounded, size: 12, color: pinColor),
                                    const SizedBox(width: 4),
                                    Text(
                                      hasPin ? 'PIN: $displayPin' : 'Set PIN (+)',
                                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: pinColor),
                                    ),
                                    if (!_isSelectionMode) ...[
                                      const SizedBox(width: 3),
                                      Icon(Icons.edit_outlined, size: 10, color: pinColor),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          }),
                          if (dept.isNotEmpty && dept.toLowerCase() != 'unassigned' && dept.toLowerCase() != 'general')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFF6366F1).withValues(alpha: isDark ? 0.2 : 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: isDark ? 0.4 : 0.25)),
                              ),
                              child: Text(
                                dept.toUpperCase(),
                                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF818CF8), letterSpacing: 0.3),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      flex: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: isDark ? 0.2 : 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: statusColor.withValues(alpha: isDark ? 0.4 : 0.3)),
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

                // Row 2: Checkbox (if multi-select) + Avatar + Name + Subtitle (Role • Branch) + 3-Dot Actions Menu
                Row(
                  children: [
                    if (_isSelectionMode) ...[
                      Checkbox(
                        value: isSelected,
                        activeColor: t.accent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        onChanged: (_) => _toggleEmployeeSelection(empId),
                      ),
                      const SizedBox(width: 4),
                    ],
                    buildInitialsAvatar(
                      name: name,
                      theme: t,
                      radius: 17,
                      imageUrl: emp['profilePictureUrl']?.toString(),
                      imagePath: emp['profilePicturePath']?.toString(),
                      gender: emp['gender']?.toString(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: t.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (!_isSelectionMode)
                      // 3-dot action menu
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert_rounded, size: 20, color: t.textSecondary),
                        color: t.bgCard,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.bgRule)),
                        onSelected: (val) {
                          if (val == 'profile') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => EmployeeDetailPage(
                                  employeeId: empId,
                                  userRole: widget.userRole,
                                  openEmployeeForm: widget.openEmployeeForm,
                                ),
                              ),
                            );
                          } else if (val == 'edit') {
                            widget.openEmployeeForm(context, empId);
                          } else if (val == 'pin') {
                            final cred = ZkTecoNetworkService.getCredentialByEntityId(empId);
                            _showEditPinDialog(context, empId, name, cred?.biometricPin ?? pin, emp['branchId']?.toString() ?? widget.branchId);
                          } else if (val == 'medical') {
                            StaffPatientLinkService.openStaffMedicalHistory(
                              context,
                              name: name,
                              cnic: emp['cnic']?.toString(),
                              branchId: emp['branchId']?.toString() ?? widget.branchId,
                              role: role,
                            );
                          } else if (val == 'merge') {
                            _showMergeDuplicateStaffDialog(context, emp, t);
                          } else if (val == 'offboard') {
                            _showOffboardDialog(context, emp);
                          }
                        },
                        itemBuilder: (ctx) => [
                          PopupMenuItem(
                            value: 'profile',
                            child: Row(children: [
                              Icon(Icons.person_rounded, size: 16, color: t.accent),
                              const SizedBox(width: 8),
                              Text('View Profile', style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                          if (isActive) ...[
                            PopupMenuItem(
                              value: 'edit',
                              child: Row(children: [
                                Icon(Icons.edit_rounded, size: 16, color: t.accent),
                                const SizedBox(width: 8),
                                Text('Edit Profile', style: TextStyle(color: t.textPrimary, fontSize: 13)),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'pin',
                              child: Row(children: [
                                const Icon(Icons.fingerprint_rounded, size: 16, color: Color(0xFF10B981)),
                                const SizedBox(width: 8),
                                Text('Set / Edit PIN', style: TextStyle(color: t.textPrimary, fontSize: 13)),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'medical',
                              child: Row(children: [
                                const Icon(Icons.medical_services_outlined, size: 16, color: Colors.teal),
                                const SizedBox(width: 8),
                                Text('Medical History', style: TextStyle(color: t.textPrimary, fontSize: 13)),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'merge',
                              child: Row(children: [
                                const Icon(Icons.merge_type_rounded, size: 16, color: Color(0xFF7C3AED)),
                                const SizedBox(width: 8),
                                Text('Merge Duplicates', style: TextStyle(color: t.textPrimary, fontSize: 13)),
                              ]),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'offboard',
                              child: const Row(children: [
                                Icon(Icons.person_off_outlined, size: 16, color: Colors.redAccent),
                                SizedBox(width: 8),
                                Text('Offboard Employee', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                              ]),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                // Row 3: Minimal Meta Badges (Branch, CNIC, Phone)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (branchName.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: t.bgCardAlt,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: t.bgRule),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_on_outlined, size: 11, color: t.textTertiary),
                            const SizedBox(width: 4),
                            Text(branchName, style: TextStyle(fontSize: 10.5, color: t.textSecondary)),
                          ],
                        ),
                      ),
                    if (hasCnic)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: rawCnic));
                          ScaffoldMessenger.of(context).clearSnackBars();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Copied CNIC: $formattedCnic'), duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                          );
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.badge_outlined, size: 11, color: t.accent),
                              const SizedBox(width: 4),
                              Text(formattedCnic, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                            ],
                          ),
                        ),
                      ),
                    if (hasPhone)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: rawPhone));
                          ScaffoldMessenger.of(context).clearSnackBars();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Copied Phone: $rawPhone'), duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                          );
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.phone_rounded, size: 11, color: t.textSecondary),
                              const SizedBox(width: 4),
                              Text(rawPhone, style: TextStyle(fontSize: 10.5, color: t.textSecondary)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(RoleThemeData t) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_outlined, size: 54, color: t.textTertiary),
          const SizedBox(height: 14),
          Text('No employees found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textSecondary)),
          const SizedBox(height: 6),
          Text('Register a new employee to get started.', style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ],
      ),
    );
  }

  void _showOffboardDialog(BuildContext context, Map<String, dynamic> emp) async {
    final result = await OffboardDialog.show(
      context,
      employeeData: emp,
      performedBy: widget.userRole,
    );
    if (result == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${emp['name'] ?? 'Employee'} has been offboarded.')),
      );
    }
  }

  // ── Batch Offboard Dialog ──────────────────────────────────────────────────
  void _showBatchOffboardDialog(BuildContext context, RoleThemeData t, List<Map<String, dynamic>> allEmployees) {
    final selectedEmployees = allEmployees.where((emp) {
      final empId = emp['localId']?.toString() ?? emp['employeeId']?.toString() ?? emp['id']?.toString() ?? '';
      return _selectedEmployeeIds.contains(empId);
    }).toList();

    if (selectedEmployees.isEmpty) return;

    final isDark = UserThemeService.isDarkMode();
    final bgDialog = t.bgCard;
    final bgCard = t.bgCardAlt;
    final textColor = t.textPrimary;
    final subtextColor = t.textSecondary;
    final borderColor = t.bgRule;

    String selectedReason = 'Resigned';
    final detailedReasonCtrl = TextEditingController();
    DateTime effectiveDate = DateTime.now();
    bool isClearanceConfirmed = true;

    final reasonOptions = [
      'Resigned',
      'Terminated',
      'Contract Ended',
      'Retired',
      'Suspended',
      'Disciplinary Action',
      'Relocated',
      'Medical Reasons',
      'Other',
    ];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (diagCtx) {
        bool isProcessing = false;
        return StatefulBuilder(
          builder: (ctx, setDiagState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              backgroundColor: bgDialog,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.person_off_rounded, color: Colors.deepOrange, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Batch Offboard Employees (${selectedEmployees.length})',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Offboard selected staff and revoke linked system access',
                                  style: TextStyle(fontSize: 11.5, color: subtextColor),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: isProcessing ? null : () => Navigator.pop(diagCtx),
                            icon: Icon(Icons.close_rounded, color: subtextColor),
                          ),
                        ],
                      ),
                    ),

                    // Body
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Selected employee preview chips
                            Text(
                              'Selected Staff Members (${selectedEmployees.length}):',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 120),
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: bgCard,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: borderColor),
                              ),
                              child: SingleChildScrollView(
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: selectedEmployees.map((emp) {
                                    final empName = emp['name']?.toString() ?? 'Staff';
                                    final empRole = emp['role']?.toString() ?? '';
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: borderColor),
                                      ),
                                      child: Text(
                                        empRole.isNotEmpty ? '$empName ($empRole)' : empName,
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Reason Dropdown
                            Text('Offboarding Reason *', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtextColor)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                              decoration: BoxDecoration(
                                color: bgCard,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: selectedReason,
                                  dropdownColor: bgDialog,
                                  isExpanded: true,
                                  style: TextStyle(fontSize: 13, color: textColor, fontWeight: FontWeight.w600),
                                  items: reasonOptions.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                                  onChanged: (val) {
                                    if (val != null) setDiagState(() => selectedReason = val);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),

                            // Detailed remarks
                            Text('Detailed Remarks / Notes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtextColor)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: detailedReasonCtrl,
                              maxLines: 2,
                              style: TextStyle(fontSize: 13, color: textColor),
                              decoration: InputDecoration(
                                hintText: 'Enter reason or handover details...',
                                hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                                filled: true,
                                fillColor: bgCard,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.accent, width: 1.5)),
                                contentPadding: const EdgeInsets.all(12),
                              ),
                            ),
                            const SizedBox(height: 14),

                            // Effective Date
                            Text('Effective Date *', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtextColor)),
                            const SizedBox(height: 6),
                            InkWell(
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: effectiveDate,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (picked != null) setDiagState(() => effectiveDate = picked);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                decoration: BoxDecoration(
                                  color: bgCard,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(DateFormat('dd MMMM yyyy').format(effectiveDate), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor)),
                                    Icon(Icons.calendar_today_rounded, size: 16, color: t.accent),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Clearance confirmation
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.25)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Checkbox(
                                    value: isClearanceConfirmed,
                                    activeColor: Colors.redAccent,
                                    onChanged: (val) => setDiagState(() => isClearanceConfirmed = val ?? false),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        'I verify that handover has been completed for all selected employees and active status should be terminated.',
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Footer
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: borderColor))),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: isProcessing ? null : () => Navigator.pop(diagCtx),
                            child: Text('Cancel', style: TextStyle(color: subtextColor, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: isProcessing || !isClearanceConfirmed
                                ? null
                                : () async {
                                    setDiagState(() => isProcessing = true);
                                    int successCount = 0;
                                    for (final emp in selectedEmployees) {
                                      try {
                                        final empId = emp['localId']?.toString() ?? emp['employeeId']?.toString() ?? emp['id']?.toString() ?? '';
                                        final cnic = emp['cnic']?.toString();
                                        final userId = emp['linkedUserId']?.toString() ?? emp['uid']?.toString();
                                        final lastData = FinanceLocalStorage.getLastRecordedDataForEmployee(
                                          employeeId: empId,
                                          cnic: cnic,
                                          userId: userId,
                                        );
                                        await FinanceLocalStorage.syncBiDirectionalOffboarding(
                                          employeeId: empId,
                                          userId: userId,
                                          cnic: cnic,
                                          performedBy: widget.userRole,
                                          reason: selectedReason,
                                          detailedReason: detailedReasonCtrl.text.trim(),
                                          effectiveDate: effectiveDate,
                                          effectiveTime: DateFormat('hh:mm a').format(DateTime.now()),
                                          shiftMilestone: 'Immediate',
                                          lastRecordedData: lastData,
                                        );
                                        successCount++;
                                      } catch (_) {}
                                    }
                                    if (mounted) {
                                      Navigator.pop(diagCtx);
                                      _clearSelection();
                                      setState(() {});
                                      showCustomSnackBar(
                                        context,
                                        '✅ Successfully offboarded $successCount employee${successCount == 1 ? '' : 's'}.',
                                      );
                                    }
                                  },
                            icon: isProcessing
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.person_off_rounded, size: 16),
                            label: Text(isProcessing ? 'Offboarding...' : 'Confirm Batch Offboard (${selectedEmployees.length})'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEA580C),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
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

  // ── Batch Delete Dialog ────────────────────────────────────────────────────
  void _showBatchDeleteDialog(BuildContext context, RoleThemeData t) {
    if (_selectedEmployeeIds.isEmpty) return;
    final count = _selectedEmployeeIds.length;

    showDialog(
      context: context,
      builder: (diagCtx) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (ctx, setDiagState) {
            return AlertDialog(
              backgroundColor: t.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.delete_forever_rounded, color: Color(0xFFDC2626), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Permanently Delete $count Employee${count == 1 ? '' : 's'}?',
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ],
              ),
              content: Text(
                'Are you sure you want to permanently delete $count selected employee profile${count == 1 ? '' : 's'}?\n\n'
                '• All local and cloud employee records will be deleted.\n'
                '• Linked login credentials and app access will be permanently revoked.\n'
                '• This action is irreversible.',
                style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.4),
              ),
              actions: [
                TextButton(
                  onPressed: isDeleting ? null : () => Navigator.pop(diagCtx),
                  child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: isDeleting
                      ? null
                      : () async {
                          setDiagState(() => isDeleting = true);
                          int deletedCount = 0;
                          for (final empId in List<String>.from(_selectedEmployeeIds)) {
                            try {
                              final emp = FinanceLocalStorage.getEmployee(empId);
                              final branch = emp?['branchId']?.toString() ?? widget.branchId;
                              await FinanceLocalStorage.deleteEmployeePermanently(
                                branchId: branch,
                                employeeId: empId,
                                performedBy: widget.userRole,
                              );
                              deletedCount++;
                            } catch (_) {}
                          }
                          if (mounted) {
                            Navigator.pop(diagCtx);
                            _clearSelection();
                            setState(() {});
                            showCustomSnackBar(
                              context,
                              '🗑️ Permanently deleted $deletedCount employee${deletedCount == 1 ? '' : 's'}.',
                            );
                          }
                        },
                  icon: isDeleting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.delete_forever_rounded, size: 16),
                  label: Text(isDeleting ? 'Deleting...' : 'Delete Permanently ($count)'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Map<String, dynamic> _previewProjectedArrears({

    required String employeeId,
    required double newSalary,
    required double oldSalary,
    required DateTime effectiveDate,
  }) {
    final today = DateTime.now();
    DateTime checkDate = DateTime(effectiveDate.year, effectiveDate.month, 15);
    final limitDate = DateTime(today.year, today.month, 1);
    
    double totalArrears = 0.0;
    int affectedMonthsCount = 0;
    final List<String> affectedMonths = [];

    final delta = newSalary - oldSalary;
    if (delta <= 0) {
      return {'count': 0, 'amount': 0.0, 'months': []};
    }

    while (checkDate.isBefore(limitDate)) {
      final mKey = DateFormat('yyyy-MM').format(checkDate);
      
      final payouts = FinanceLocalStorage.salaryLedgerBox.values.where((val) {
        if (val is! Map) return false;
        final entry = Map<String, dynamic>.from(val);
        return entry['employeeId'] == employeeId &&
               entry['monthKey'] == mKey &&
               entry['type'] == 'payout' &&
               entry['isVoided'] != true;
      }).toList();

      if (payouts.isNotEmpty) {
        totalArrears += delta;
        affectedMonthsCount++;
        affectedMonths.add(mKey);
      }

      checkDate = DateTime(checkDate.year, checkDate.month + 1, 15);
    }

    return {
      'count': affectedMonthsCount,
      'amount': totalArrears,
      'months': affectedMonths,
    };
  }

  void _openSalaryAdjustmentDialog(
    BuildContext context,
    String employeeId,
    double currentSalary,
    VoidCallback onUpdated,
  ) {
    final t = RoleThemeScope.dataOf(context);
    final curUser = LocalStorageService.getActiveUsername();

    String adjustmentType = 'Percentage Raise (%)';
    final valueController = TextEditingController();
    final approvedByController = TextEditingController(text: curUser);
    final reasonController = TextEditingController();
    final effectiveDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Adjust Salary / Increment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(sheetCtx)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('Current Base Salary: PKR ${NumberFormat('#,###').format(currentSalary)}', style: TextStyle(color: t.textSecondary, fontSize: 13)),
                    const SizedBox(height: 14),

                    buildDropdownField(
                      label: 'Adjustment Type *',
                      value: adjustmentType,
                      items: const ['Percentage Raise (%)', 'Fixed Raise (PKR)', 'Set New Salary (PKR)'],
                      onChanged: (val) {
                        setSheetState(() {
                          adjustmentType = val!;
                        });
                      },
                      theme: t,
                    ),
                    const SizedBox(height: 10),

                    buildFormField(
                      controller: valueController,
                      label: adjustmentType == 'Percentage Raise (%)' ? 'Percentage Value (e.g. 10) *' : 'Amount (PKR) *',
                      icon: Icons.payments,
                      theme: t,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                      ],
                      onChanged: (_) => setSheetState(() {}),
                    ),
                    const SizedBox(height: 10),

                    buildDatePickerField(
                      context: sheetCtx,
                      controller: effectiveDateController,
                      label: 'Effective Date *',
                      icon: Icons.calendar_today,
                      theme: t,
                      onChanged: () => setSheetState(() {}),
                    ),
                    const SizedBox(height: 10),

                    buildFormField(
                      controller: approvedByController,
                      label: 'Approved By *',
                      icon: Icons.verified_user,
                      theme: t,
                    ),
                    const SizedBox(height: 10),

                    buildFormField(
                      controller: reasonController,
                      label: 'Reason / Remarks *',
                      icon: Icons.note_alt_outlined,
                      theme: t,
                    ),
                    const SizedBox(height: 15),

                    // Projected Arrears Preview
                    Builder(
                      builder: (context) {
                        final valStr = valueController.text.trim();
                        final val = double.tryParse(valStr) ?? 0.0;
                        double targetSalary = currentSalary;
                        if (adjustmentType == 'Percentage Raise (%)') {
                          targetSalary = currentSalary * (1 + val / 100);
                        } else if (adjustmentType == 'Fixed Raise (PKR)') {
                          targetSalary = currentSalary + val;
                        } else if (adjustmentType == 'Set New Salary (PKR)') {
                          targetSalary = val;
                        }

                        targetSalary = targetSalary.roundToDouble();

                        DateTime? effDate;
                        try {
                          effDate = DateTime.parse(effectiveDateController.text);
                        } catch (_) {}

                        if (effDate != null && effDate.isBefore(DateTime.now()) && targetSalary > currentSalary) {
                          final preview = _previewProjectedArrears(
                            employeeId: employeeId,
                            newSalary: targetSalary,
                            oldSalary: currentSalary,
                            effectiveDate: effDate,
                          );

                          final count = preview['count'] as int;
                          final amount = preview['amount'] as double;
                          final months = preview['months'] as List<String>;

                          if (count > 0) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.purple.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.purple.withOpacity(0.3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.info_outline, color: Colors.purple, size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Retroactive Arrears Preview',
                                        style: TextStyle(color: Colors.purple, fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'This change is retroactive and will generate arrears for $count paid month(s): ${months.join(", ")}.',
                                    style: TextStyle(color: t.textSecondary, fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Total Projected Arrears: PKR ${NumberFormat('#,###').format(amount)}',
                                    style: const TextStyle(color: Colors.purple, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                ],
                              ),
                            );
                          }
                        }
                        return const SizedBox.shrink();
                      }
                    ),
                    const SizedBox(height: 10),

                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () async {
                        final valStr = valueController.text.trim();
                        final val = double.tryParse(valStr) ?? 0.0;
                        if (valStr.isEmpty || val <= 0) {
                          showCustomSnackBar(sheetCtx, 'Please enter a valid positive value.', error: true);
                          return;
                        }

                        final approver = approvedByController.text.trim();
                        if (approver.isEmpty) {
                          showCustomSnackBar(sheetCtx, 'Please specify who approved this adjustment.', error: true);
                          return;
                        }

                        final reason = reasonController.text.trim();
                        if (reason.isEmpty) {
                          showCustomSnackBar(sheetCtx, 'Please specify the reason.', error: true);
                          return;
                        }

                        final effDateStr = effectiveDateController.text.trim();
                        if (effDateStr.isEmpty) {
                          showCustomSnackBar(sheetCtx, 'Please select an effective date.', error: true);
                          return;
                        }

                        double newSalary = currentSalary;
                        if (adjustmentType == 'Percentage Raise (%)') {
                          newSalary = currentSalary * (1 + val / 100);
                        } else if (adjustmentType == 'Fixed Raise (PKR)') {
                          newSalary = currentSalary + val;
                        } else if (adjustmentType == 'Set New Salary (PKR)') {
                          newSalary = val;
                        }

                        newSalary = newSalary.roundToDouble();

                        try {
                          final emp = FinanceLocalStorage.getEmployee(employeeId);
                          if (emp == null) throw Exception('Employee not found.');

                          final effectiveDateTime = DateTime.parse(effDateStr);

                          await FinanceLocalStorage.saveSalaryHistory(
                            branchId: emp['branchId'] ?? widget.branchId,
                            employeeId: employeeId,
                            amount: newSalary,
                            effectiveDate: effectiveDateTime,
                            reason: reason,
                            approvedBy: approver,
                            performedBy: curUser,
                          );

                          if (sheetCtx.mounted) {
                            Navigator.pop(sheetCtx);
                            showCustomSnackBar(context, 'Salary updated successfully. New Salary: PKR ${NumberFormat('#,###').format(newSalary)}');
                          }
                          onUpdated();
                        } catch (e) {
                          showCustomSnackBar(sheetCtx, 'Failed: $e', error: true);
                        }
                      },
                      child: const Text('Apply Salary Adjustment', style: TextStyle(fontWeight: FontWeight.bold)),
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

  void _openAnnualIncrementsDialog(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final curUser = LocalStorageService.getActiveUsername();

    int targetYear = DateTime.now().year;
    final percentCtrl = TextEditingController(text: '10');
    final approvedByCtrl = TextEditingController(text: curUser);
    final reasonCtrl = TextEditingController(text: 'Annual 10% Increment');

    final Map<String, bool> selectedEmployees = {};
    final List<String> eligibleIds = [];
    bool showEligibleOnly = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final percent = double.tryParse(percentCtrl.text) ?? 10.0;
            final cutoffDate = DateTime(targetYear - 1, 5, 1);
            final activeEmployees = FinanceLocalStorage.getEmployees(widget.branchId)
                .where((e) => e['isActive'] == true)
                .toList();

            if (selectedEmployees.isEmpty) {
              for (final emp in activeEmployees) {
                final empId = emp['localId']?.toString() ?? '';
                final joinStr = emp['joiningDate']?.toString();
                bool isEligible = false;
                if (joinStr != null && joinStr.isNotEmpty) {
                  try {
                    final joinDate = DateTime.parse(joinStr);
                    if (joinDate.isBefore(cutoffDate) || joinDate.isAtSameMomentAs(cutoffDate)) {
                      isEligible = true;
                    }
                  } catch (_) {}
                }
                if (isEligible) {
                  eligibleIds.add(empId);
                  selectedEmployees[empId] = true;
                } else {
                  selectedEmployees[empId] = false;
                }
              }
            }

            final filteredEmployees = activeEmployees.where((emp) {
              if (showEligibleOnly) {
                final empId = emp['localId']?.toString() ?? '';
                return eligibleIds.contains(empId);
              }
              return true;
            }).toList();

            double currentTotalSalary = 0.0;
            double proposedTotalSalary = 0.0;
            int selectedCount = 0;
            for (final emp in activeEmployees) {
              final empId = emp['localId']?.toString() ?? '';
              final isSelected = selectedEmployees[empId] ?? false;
              if (isSelected) {
                final currentSalary = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
                currentTotalSalary += currentSalary;
                proposedTotalSalary += (currentSalary * (1 + percent / 100)).roundToDouble();
                selectedCount++;
              }
            }
            final netPayrollIncrease = proposedTotalSalary - currentTotalSalary;

            return Container(
              height: MediaQuery.of(sheetCtx).size.height * 0.85,
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Bulk Annual Increments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(sheetCtx)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Rule: Applied on Jan 1st. Requires >= 8 months of work (joined on or before ${DateFormat('yyyy-MM-dd').format(cutoffDate)}).',
                    style: TextStyle(color: t.textSecondary, fontSize: 11, fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 10),

                  // Projected Impact Summary Box
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PROJECTED PAYROLL IMPACT',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: t.accent, letterSpacing: 1.1),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Selected Employees', style: TextStyle(color: t.textSecondary, fontSize: 11)),
                            Text('$selectedCount', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Current Total Monthly Payroll', style: TextStyle(color: t.textSecondary, fontSize: 11)),
                            Text('PKR ${NumberFormat('#,###').format(currentTotalSalary)}', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 11)),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Projected Total Monthly Payroll', style: TextStyle(color: t.textSecondary, fontSize: 11)),
                            Text('PKR ${NumberFormat('#,###').format(proposedTotalSalary)}', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Divider(color: t.bgRule, height: 1),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Projected Monthly Increase', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 11)),
                            Text('+PKR ${NumberFormat('#,###').format(netPayrollIncrease)}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),

                  Row(
                    children: [
                      Expanded(
                        child: buildDropdownField(
                          label: 'Target Year',
                          value: targetYear.toString(),
                          items: [targetYear.toString(), (targetYear + 1).toString(), (targetYear - 1).toString()],
                          onChanged: (val) {
                            setSheetState(() {
                              targetYear = int.parse(val!);
                              selectedEmployees.clear();
                              eligibleIds.clear();
                              reasonCtrl.text = 'Annual ${percentCtrl.text}% Increment';
                            });
                          },
                          theme: t,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: buildFormField(
                          controller: percentCtrl,
                          label: 'Increment (%)',
                          icon: Icons.percent,
                          theme: t,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                          ],
                          onChanged: (_) {
                            setSheetState(() {
                              reasonCtrl.text = 'Annual ${percentCtrl.text}% Increment';
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: buildFormField(
                          controller: approvedByCtrl,
                          label: 'Approved By *',
                          icon: Icons.verified_user,
                          theme: t,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: buildFormField(
                          controller: reasonCtrl,
                          label: 'Reason / Remarks *',
                          icon: Icons.note_alt_outlined,
                          theme: t,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Batch Controls & Filtering Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      InkWell(
                        onTap: () {
                          setSheetState(() {
                            showEligibleOnly = !showEligibleOnly;
                          });
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: Checkbox(
                                value: showEligibleOnly,
                                activeColor: t.accent,
                                onChanged: (val) {
                                  setSheetState(() {
                                    showEligibleOnly = val ?? false;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('Show Eligible Only', style: TextStyle(color: t.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              setSheetState(() {
                                for (final empId in eligibleIds) {
                                  selectedEmployees[empId] = true;
                                }
                              });
                            },
                            child: const Text('Select Eligible', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              setSheetState(() {
                                for (final key in selectedEmployees.keys) {
                                  selectedEmployees[key] = false;
                                }
                              });
                            },
                            child: const Text('Clear All', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  Text(
                    'EMPLOYEE ELIGIBILITY LIST (${filteredEmployees.length} Shown)',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: filteredEmployees.isEmpty
                        ? Center(child: Text('No employees found matching filters.', style: TextStyle(color: t.textTertiary)))
                        : ListView.builder(
                            itemCount: filteredEmployees.length,
                            itemBuilder: (ctx, idx) {
                              final emp = filteredEmployees[idx];
                              final empId = emp['localId']?.toString() ?? '';
                              final name = emp['name']?.toString() ?? '';
                              final role = emp['role']?.toString() ?? '';
                              final joinStr = emp['joiningDate']?.toString() ?? '';
                              final currentSalary = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
                              final isEligible = eligibleIds.contains(empId);
                              
                              final proposedSalary = (currentSalary * (1 + percent / 100)).roundToDouble();

                              String formattedJoin = 'N/A';
                              if (joinStr.isNotEmpty) {
                                final dt = DateTime.tryParse(joinStr);
                                formattedJoin = dt != null ? DateFormat('d MMM yyyy').format(dt) : joinStr;
                              }

                              return Card(
                                color: t.bgCardAlt,
                                margin: const EdgeInsets.only(bottom: 6),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: isEligible ? t.bgRule : Colors.orange.withOpacity(0.3),
                                  ),
                                ),
                                child: CheckboxListTile(
                                  activeColor: t.accent,
                                  dense: true,
                                  title: Text(name, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('$role • Joined: $formattedJoin', style: TextStyle(color: t.textSecondary, fontSize: 11)),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text('PKR ${NumberFormat('#,###').format(currentSalary)} ➔ ', style: TextStyle(color: t.textTertiary, fontSize: 11)),
                                          Text('PKR ${NumberFormat('#,###').format(proposedSalary)}', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 11)),
                                          const SizedBox(width: 8),
                                          if (!isEligible)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                                              child: const Text(
                                                '< 8 Months',
                                                style: TextStyle(color: Colors.orange, fontSize: 8, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  value: selectedEmployees[empId] ?? false,
                                  onChanged: (val) {
                                    setSheetState(() {
                                      selectedEmployees[empId] = val ?? false;
                                    });
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      final approver = approvedByCtrl.text.trim();
                      if (approver.isEmpty) {
                        showCustomSnackBar(sheetCtx, 'Please specify who approved this adjustment.', error: true);
                        return;
                      }

                      final reason = reasonCtrl.text.trim();
                      if (reason.isEmpty) {
                        showCustomSnackBar(sheetCtx, 'Please specify the reason.', error: true);
                        return;
                      }

                      final selectedIds = selectedEmployees.entries
                          .where((entry) => entry.value == true)
                          .map((entry) => entry.key)
                          .toList();

                      if (selectedIds.isEmpty) {
                        showCustomSnackBar(sheetCtx, 'No employees selected for increment.', error: true);
                        return;
                      }

                      try {
                        final effectiveDateTime = DateTime(targetYear, 1, 1);

                        int count = 0;
                        for (final empId in selectedIds) {
                          final emp = activeEmployees.firstWhere((e) => e['localId'] == empId);
                          final currentSalary = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
                          final proposedSalary = (currentSalary * (1 + percent / 100)).roundToDouble();

                          await FinanceLocalStorage.saveSalaryHistory(
                            branchId: emp['branchId'] ?? widget.branchId,
                            employeeId: empId,
                            amount: proposedSalary,
                            effectiveDate: effectiveDateTime,
                            reason: reason,
                            approvedBy: approver,
                            performedBy: curUser,
                          );
                          count++;
                        }

                        if (sheetCtx.mounted) {
                          Navigator.pop(sheetCtx);
                          showCustomSnackBar(
                            context,
                            'Successfully applied annual increment to $count employees.',
                          );
                        }
                      } catch (e) {
                        showCustomSnackBar(sheetCtx, 'Failed: $e', error: true);
                      }
                    },
                    child: Text(
                      'Apply Increments to ${selectedEmployees.values.where((v) => v).length} Employees',
                      style: const TextStyle(fontWeight: FontWeight.bold),
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

  Widget _buildInfoChip(IconData icon, String label, RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: t.bgCardAlt, borderRadius: BorderRadius.circular(8), border: Border.all(color: t.bgRule)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: t.textSecondary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: t.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildDetailSectionHeader(String label, RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, top: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: t.accent, letterSpacing: 1.2)),
          const SizedBox(height: 2),
          Divider(color: t.bgRule, height: 1),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: t.textSecondary)),
          Text(value, style: TextStyle(fontSize: 13, color: t.textPrimary, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // Sentence case instead of ALL CAPS — reads calmer, consistent with the
  // rest of the app (redesign plan §3.E).
  String _sentenceCase(String? s) {
    if (s == null || s.trim().isEmpty) return 'N/A';
    final lower = s.trim().toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  void _showDeactivateDialog(BuildContext sheetCtx, String employeeId, StateSetter setDrawerState) {
    final t = RoleThemeScope.dataOf(sheetCtx);
    final reasonController = TextEditingController();
    String selectedStatus = 'Left';

    showDialog(
      context: sheetCtx,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (diagCtx, setDiagState) {
            return AlertDialog(
              backgroundColor: t.bgCard,
              title: Text('Offboard Employee', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Are you sure you want to offboard this employee? This will toggle their status to inactive to preserve payroll records.',
                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  buildDropdownField(
                    label: 'Offboarding Status *',
                    value: selectedStatus,
                    items: const ['Archived', 'Temporary Leave', 'Left'],
                    onChanged: (val) => setDiagState(() => selectedStatus = val!),
                    theme: t,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reasonController,
                    style: TextStyle(color: t.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Offboarding Reason *',
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
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    if (reasonController.text.trim().isEmpty) {
                      return;
                    }
                    try {
                      final curUser = LocalStorageService.getActiveUsername();
                      final emp = FinanceLocalStorage.getEmployee(employeeId)!;
                      emp['isActive'] = false;
                      emp['status'] = selectedStatus;
                      emp['exitDate'] = DateFormat('yyyy-MM-dd').format(DateTime.now());

                      await FinanceLocalStorage.saveEmployee(
                        branchId: widget.branchId,
                        data: emp,
                        performedBy: curUser,
                      );

                      // Log soft delete audit
                      await FinanceLocalStorage.logAction(
                        branchId: widget.branchId,
                        entityType: 'employee',
                        entityId: employeeId,
                        action: 'update',
                        performedBy: curUser,
                        reason: 'Employee Deactivated as $selectedStatus. Reason: ${reasonController.text.trim()}',
                      );

                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        Navigator.pop(sheetCtx); // close drawer
                        showCustomSnackBar(context, 'Employee offboarded.');
                      }
                    } catch (e) {
                      showCustomSnackBar(diagCtx, 'Failed: $e', error: true);
                    }
                  },
                  child: const Text('Offboard', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Branch Transfer Dialog ────────────────────────────────────────────────
  void _openTransferDialog(BuildContext context, String employeeId, String currentBranchId) {
    final t = RoleThemeScope.dataOf(context);
    String selectedToBranch = '';
    final reasonController = TextEditingController();
    final effectiveController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
    bool loading = false;

    // Load available branches excluding current directly from Firestore list
    final availableBranches = widget.branches
        .where((b) => b['id'] != currentBranchId)
        .toList();

    if (availableBranches.isEmpty) {
      showCustomSnackBar(context, 'No other branches available for transfer.', error: true);
      return;
    }
    final List<String> dropdownItems = availableBranches.map((b) => "${b['name']} (${b['id']})").toList();
    String selectedDropdownItem = dropdownItems.first;
    selectedToBranch = availableBranches.first['id']?.toString() ?? '';

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (diagCtx, setDiagState) {
            return AlertDialog(
              backgroundColor: t.bgCard,
              title: Text('Transfer Employee Branch', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildDropdownField(
                    label: 'Destination Branch *',
                    value: selectedDropdownItem,
                    items: dropdownItems,
                    onChanged: (val) {
                      if (val != null) {
                        setDiagState(() {
                          selectedDropdownItem = val;
                          final idx = dropdownItems.indexOf(val);
                          selectedToBranch = availableBranches[idx]['id']?.toString() ?? '';
                        });
                      }
                    },
                    theme: t,
                  ),
                  const SizedBox(height: 10),
                  buildDatePickerField(
                    context: diagCtx,
                    controller: effectiveController,
                    label: 'Effective Date *',
                    icon: Icons.calendar_today,
                    theme: t,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reasonController,
                    maxLines: 2,
                    style: TextStyle(color: t.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Transfer Reason *',
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
                  style: ElevatedButton.styleFrom(backgroundColor: t.accent),
                  onPressed: loading
                      ? null
                      : () async {
                          if (reasonController.text.trim().isEmpty) {
                            showCustomSnackBar(diagCtx, 'Transfer reason is required.', error: true);
                            return;
                          }
                          setDiagState(() => loading = true);
                          try {
                            final curUser = LocalStorageService.getActiveUsername();

                            await FinanceLocalStorage.transferEmployee(
                              employeeId: employeeId,
                              fromBranchId: currentBranchId,
                              toBranchId: selectedToBranch,
                              reason: reasonController.text.trim(),
                              approvedBy: curUser, // In this flow, the current executive is the approver
                              performedBy: curUser,
                              effectiveDate: DateTime.parse(effectiveController.text),
                            );

                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              Navigator.pop(context); // close drawer to refresh
                              showCustomSnackBar(context, 'Employee transfer requested successfully!');
                            }
                          } catch (e) {
                            showCustomSnackBar(diagCtx, e.toString(), error: true);
                          } finally {
                            setDiagState(() => loading = false);
                          }
                        },
                  child: Text(loading ? 'Processing...' : 'Transfer', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCalendarDaysGrid(String employeeId, Map<String, dynamic> emp, DateTime month, RoleThemeData t) {
    final year = month.year;
    final monthNum = month.month;
    final branchId = emp['branchId']?.toString() ?? '';
    final dept = emp['department']?.toString() ?? '';

    final firstDay = DateTime(year, monthNum, 1);
    final lastDay = DateTime(year, monthNum + 1, 0);

    final int prefixDays = firstDay.weekday - 1;
    final totalCells = prefixDays + lastDay.day;

    int presentCount = 0;
    int absentCount = 0;
    int leaveCount = 0;
    int holidayCount = 0;

    final days = <Widget>[];

    for (int i = 0; i < totalCells; i++) {
      if (i < prefixDays) {
        days.add(const SizedBox.shrink());
      } else {
        final dayNum = i - prefixDays + 1;
        final date = DateTime(year, monthNum, dayNum);
        final dateStr = DateFormat('yyyy-MM-dd').format(date);
        final isSunday = date.weekday == DateTime.sunday;
        final isHolidayDay = FinanceLocalStorage.isHoliday(
          branchId: branchId,
          department: dept,
          dateStr: dateStr,
        );

        final key = '${employeeId}_$dateStr';
        final val = FinanceLocalStorage.attendanceBox.get(key);

        String status = 'unmarked';
        String? leaveType;
        if (val is Map) {
          status = val['status']?.toString() ?? 'absent';
          leaveType = val['leaveType']?.toString();
        } else {
          if (isSunday) {
            status = 'off';
          } else if (isHolidayDay) {
            status = 'holiday';
          }
        }

        Color cellBg = Colors.transparent;
        Color textCol = t.textPrimary;
        Border? cellBorder = Border.all(color: t.bgRule);

        if (status == 'present' || status == 'late') {
          cellBg = Colors.green.withValues(alpha: 0.15);
          textCol = t.isDarkCanvas ? Colors.green[300]! : Colors.green[700]!;
          cellBorder = Border.all(color: Colors.green.withValues(alpha: 0.3));
          presentCount++;
        } else if (status == 'absent') {
          cellBg = Colors.red.withValues(alpha: 0.15);
          textCol = t.isDarkCanvas ? Colors.red[300]! : Colors.red[700]!;
          cellBorder = Border.all(color: Colors.red.withValues(alpha: 0.3));
          absentCount++;
        } else if (status == 'leave') {
          cellBg = Colors.orange.withValues(alpha: 0.15);
          textCol = t.isDarkCanvas ? Colors.orange[300]! : Colors.orange[700]!;
          cellBorder = Border.all(color: Colors.orange.withValues(alpha: 0.3));
          leaveCount++;
        } else if (status == 'half_day') {
          cellBg = Colors.blue.withValues(alpha: 0.15);
          textCol = t.isDarkCanvas ? Colors.blue[300]! : Colors.blue[700]!;
          cellBorder = Border.all(color: Colors.blue.withValues(alpha: 0.3));
          presentCount++;
        } else if (status == 'off' || status == 'holiday' || isHolidayDay) {
          cellBg = t.accent.withValues(alpha: 0.08);
          textCol = t.accent;
          cellBorder = Border.all(color: t.accent.withValues(alpha: 0.2));
          holidayCount++;
        }

        days.add(
          Tooltip(
            message: 'Date: $dateStr\nStatus: ${status.toUpperCase()}${leaveType != null ? " ($leaveType)" : ""}',
            child: Container(
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: cellBg,
                borderRadius: BorderRadius.circular(6),
                border: cellBorder,
              ),
              child: Center(
                child: Text(
                  dayNum.toString(),
                  style: TextStyle(color: textCol, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 7,
          childAspectRatio: 1.3,
          children: days,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatIndicator('P', '$presentCount', Colors.green, t),
            _buildStatIndicator('A', '$absentCount', Colors.red, t),
            _buildStatIndicator('L', '$leaveCount', Colors.orange, t),
            _buildStatIndicator('H/O', '$holidayCount', t.accent, t),
          ],
        ),
      ],
    );
  }

  void _confirmDeleteEmployee(BuildContext context, String employeeId) {
    final t = RoleThemeScope.dataOf(context);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: t.bgCard,
          title: Text('Delete Employee Profile', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
          content: Text('Are you sure you want to permanently delete this employee\'s profile? This action is irreversible and will delete all their details from both the local database and Firestore.', style: TextStyle(color: t.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                Navigator.pop(ctx);
                Navigator.pop(context);
                try {
                  final curUser = LocalStorageService.getActiveUsername();
                  await FinanceLocalStorage.deleteEmployeePermanently(
                    branchId: widget.branchId,
                    employeeId: employeeId,
                    performedBy: curUser,
                  );
                  showCustomSnackBar(context, 'Employee profile permanently deleted.');
                } catch (e) {
                  showCustomSnackBar(context, 'Failed to delete: $e', error: true);
                }
              },
              child: const Text('Delete Permanently', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatIndicator(String label, String val, Color color, RoleThemeData t) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 6),
        Text(val, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }

  void _openBulkBackfillDialog(BuildContext context, String employeeId, String employeeName) {
    final t = RoleThemeScope.dataOf(context);
    final curUser = LocalStorageService.getActiveUsername();

    int startMonthsAgo = 3;
    final salaryCtrl = TextEditingController();
    final approvedByCtrl = TextEditingController(text: curUser);
    String defaultStatus = 'present'; // present, absent, off

    final emp = FinanceLocalStorage.getEmployee(employeeId);
    if (emp != null) {
      final double s = (emp['currentSalary'] as num?)?.toDouble() ?? 0.0;
      salaryCtrl.text = s.toStringAsFixed(0);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final now = DateTime.now();
            final months = <Map<String, dynamic>>[];
            for (int i = startMonthsAgo; i >= 1; i--) {
              final d = DateTime(now.year, now.month - i, 15);
              final mKey = DateFormat('yyyy-MM').format(d);
              final isLocked = Hive.box(LocalStorageService.financeSettingsBox).get('month_lock_$mKey') == true;
              months.add({
                'key': mKey,
                'label': DateFormat('MMMM yyyy').format(d),
                'isLocked': isLocked,
              });
            }

            final hasLockedMonths = months.any((m) => m['isLocked'] == true);

            return Container(
              height: MediaQuery.of(sheetCtx).size.height * 0.75,
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Bulk Historical Backfill', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary)),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(sheetCtx)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Bulk initialize attendance and salary rates for $employeeName. Active month locks are strictly enforced.',
                      style: TextStyle(color: t.textSecondary, fontSize: 11),
                    ),
                    const SizedBox(height: 14),

                    if (hasLockedMonths)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: Colors.red, size: 16),
                                SizedBox(width: 6),
                                Text('Locked Periods Detected', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Some months in the selected window are closed and locked. Backfill is blocked.',
                              style: TextStyle(color: Colors.red, fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: months.map((m) {
                                final isL = m['isLocked'] == true;
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isL ? Colors.red.withOpacity(0.12) : Colors.green.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${m['key']} ${isL ? "🔒" : "🔓"}',
                                    style: TextStyle(
                                      color: isL ? Colors.red : Colors.green,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                );
                              }).toList(),
                            )
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline_rounded, color: t.accent, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'All periods in this backfill window (${months.isEmpty ? "none" : months.last['key']} to ${months.isEmpty ? "none" : months.first['key']}) are unlocked and safe.',
                                style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),

                    buildDropdownField(
                      label: 'Backfill Window Depth (Months)',
                      value: startMonthsAgo.toString(),
                      items: const ['1', '2', '3', '4', '5', '6'],
                      onChanged: (val) {
                        if (val != null) {
                          setSheetState(() => startMonthsAgo = int.parse(val));
                        }
                      },
                      theme: t,
                    ),

                    buildFormField(
                      controller: salaryCtrl,
                      label: 'Base Salary (PKR / Month) *',
                      icon: Icons.payments_outlined,
                      theme: t,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),

                    buildDropdownField(
                      label: 'Default Daily Attendance Status',
                      value: defaultStatus,
                      items: const ['present', 'absent', 'off'],
                      onChanged: (val) {
                        if (val != null) {
                          setSheetState(() => defaultStatus = val);
                        }
                      },
                      theme: t,
                    ),

                    buildFormField(
                      controller: approvedByCtrl,
                      label: 'Approved By (CEO / Admin) *',
                      icon: Icons.verified_user_outlined,
                      theme: t,
                    ),
                    const SizedBox(height: 20),

                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: hasLockedMonths ? Colors.grey : t.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: hasLockedMonths
                          ? null
                          : () async {
                              final double sVal = double.tryParse(salaryCtrl.text) ?? 0.0;
                              if (sVal <= 0) {
                                showCustomSnackBar(sheetCtx, 'Please enter a valid salary amount.', error: true);
                                return;
                              }
                              final approver = approvedByCtrl.text.trim();
                              if (approver.isEmpty) {
                                showCustomSnackBar(sheetCtx, 'Please specify who approved this backfill.', error: true);
                                return;
                              }

                              try {
                                showCustomSnackBar(sheetCtx, 'Starting backfill process...');
                                
                                for (final monthInfo in months) {
                                  final mKey = monthInfo['key'] as String;
                                  final parts = mKey.split('-');
                                  final year = int.parse(parts[0]);
                                  final month = int.parse(parts[1]);

                                  final effective = DateTime(year, month, 1);
                                  await FinanceLocalStorage.saveSalaryHistory(
                                    branchId: widget.branchId,
                                    employeeId: employeeId,
                                    amount: sVal,
                                    effectiveDate: effective,
                                    reason: 'Bulk Historical Backfill Initialization',
                                    approvedBy: approver,
                                    performedBy: curUser,
                                  );

                                  final days = FinanceLocalStorage.getDaysInMonth(mKey);
                                  for (int d = 1; d <= days; d++) {
                                    final dateStr = '$mKey-${d.toString().padLeft(2, '0')}';
                                    final date = DateTime(year, month, d);
                                    final status = date.weekday == DateTime.sunday ? 'off' : defaultStatus;

                                    await FinanceLocalStorage.saveAttendanceRecord(
                                      branchId: widget.branchId,
                                      data: {
                                        'employeeId': employeeId,
                                        'date': dateStr,
                                        'status': status,
                                        'leaveType': null,
                                        'arrivalTime': null,
                                        'departureTime': null,
                                        'note': 'Backfill Default',
                                      },
                                      performedBy: curUser,
                                    );
                                  }
                                }

                                Navigator.pop(sheetCtx);
                                showCustomSnackBar(context, 'Historical backfill completed successfully!');
                              } catch (e) {
                                showCustomSnackBar(sheetCtx, 'Error during backfill: $e', error: true);
                              }
                            },
                      child: const Text('Execute Historical Backfill', style: TextStyle(fontWeight: FontWeight.bold)),
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

  void _showEditPinDialog(BuildContext context, String empId, String name, String currentPin, String branchId) {
    final pinCtrl = TextEditingController(text: currentPin);
    showDialog(
      context: context,
      builder: (diagCtx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.fingerprint_rounded, color: Color(0xFF0F766E), size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Biometric PIN — $name',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the unique numeric PIN for physical ZKTeco fingerprint/face scanners.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: pinCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              decoration: InputDecoration(
                labelText: 'Scanner PIN (e.g. 159)',
                labelStyle: const TextStyle(color: Color(0xFF64748B)),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                prefixIcon: const Icon(Icons.pin_outlined, color: Color(0xFF0F766E)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.5)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(diagCtx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              final newPin = pinCtrl.text.trim();
              if (newPin.isEmpty) {
                showCustomSnackBar(context, 'Please enter a numeric PIN.', error: true);
                return;
              }
              final conflict = ZkTecoNetworkService.findPinConflict(newPin, excludeEntityId: empId);
              if (conflict != null) {
                showCustomSnackBar(
                  context,
                  '❌ PIN $newPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please enter a unique PIN.',
                  error: true,
                );
                return;
              }
              await ZkTecoNetworkService.assignPinToEntity(
                entityId: empId,
                entityName: name,
                entityType: 'employee',
                branchId: branchId,
                customPin: newPin,
              );
              final emp = FinanceLocalStorage.getEmployee(empId);
              if (emp != null) {
                emp['biometricPin'] = newPin;
                await FinanceLocalStorage.saveEmployee(
                  branchId: branchId,
                  data: emp,
                  performedBy: LocalStorageService.getActiveUsername(),
                );
              }
              Navigator.pop(diagCtx);
              setState(() {});
              showCustomSnackBar(context, '✅ Updated $name to Biometric PIN: $newPin');
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
  }

  void _openMergeStaffDialog(BuildContext context, RoleThemeData theme) {
    final allEmps = FinanceLocalStorage.getEmployees(widget.branchId);
    if (allEmps.length < 2) {
      showCustomSnackBar(context, 'At least 2 staff profiles are required to perform a merge.');
      return;
    }

    // Find any duplicate names (like Iqra)
    Map<String, dynamic>? candidateA;
    Map<String, dynamic>? candidateB;

    for (int i = 0; i < allEmps.length; i++) {
      final nameI = (allEmps[i]['name'] ?? allEmps[i]['employeeName'] ?? '').toString().trim().toLowerCase();
      if (nameI.isEmpty) continue;
      for (int j = i + 1; j < allEmps.length; j++) {
        final nameJ = (allEmps[j]['name'] ?? allEmps[j]['employeeName'] ?? '').toString().trim().toLowerCase();
        if (nameI == nameJ || (nameI.length >= 3 && (nameI.contains(nameJ) || nameJ.contains(nameI)))) {
          candidateA = allEmps[i];
          candidateB = allEmps[j];
          break;
        }
      }
      if (candidateA != null) break;
    }

    if (candidateA != null && candidateB != null) {
      _showMergeDuplicateStaffDialog(context, candidateA, theme, candidateB);
    } else {
      _showMergeDuplicateStaffDialog(context, allEmps[0], theme, allEmps[1]);
    }
  }

  void _showMergeDuplicateStaffDialog(
    BuildContext context,
    Map<String, dynamic> emp,
    RoleThemeData theme, [
    Map<String, dynamic>? preselectedDuplicate,
  ]) {
    final empId = (emp['localId'] ?? emp['id'] ?? '').toString();
    final empName = (emp['name'] ?? emp['employeeName'] ?? '').toString().trim();
    final allEmps = FinanceLocalStorage.getEmployees(widget.branchId);

    // Find candidate duplicates matching name
    final duplicates = allEmps.where((other) {
      final oId = (other['localId'] ?? other['id'] ?? '').toString();
      if (oId == empId) return false;
      final oName = (other['name'] ?? other['employeeName'] ?? '').toString().trim().toLowerCase();
      return oName == empName.toLowerCase() ||
          (empName.length >= 3 && (oName.contains(empName.toLowerCase()) || empName.toLowerCase().contains(oName)));
    }).toList();

    Map<String, dynamic> secondary = preselectedDuplicate ??
        (duplicates.isNotEmpty ? duplicates.first : allEmps.firstWhere((e) => (e['localId'] ?? e['id']) != empId, orElse: () => emp));

    final empCred = ZkTecoNetworkService.getCredentialByEntityId(empId);
    final secId = (secondary['localId'] ?? secondary['id'] ?? '').toString();
    final secCred = ZkTecoNetworkService.getCredentialByEntityId(secId);

    final bestPin = (emp['biometricPin'] ?? empCred?.biometricPin ?? secondary['biometricPin'] ?? secCred?.biometricPin ?? '').toString().trim();
    final roleA = (emp['role'] ?? 'Staff').toString().trim();
    final roleB = (secondary['role'] ?? 'Staff').toString().trim();
    final combinedRole = roleA.toLowerCase() == roleB.toLowerCase() ? roleA : '$roleA / $roleB';
    final dept = (emp['department'] ?? secondary['department'] ?? 'Office').toString().trim();

    final nameCtrl = TextEditingController(text: empName.isNotEmpty ? empName : (secondary['name']?.toString() ?? 'Staff'));
    final roleCtrl = TextEditingController(text: combinedRole);
    final pinCtrl = TextEditingController(text: bestPin);
    final deptCtrl = TextEditingController(text: dept.isNotEmpty && dept.toLowerCase() != 'unassigned' ? dept : 'Office');

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final curSecId = (secondary['localId'] ?? secondary['id'] ?? '').toString();
          final curSecCred = ZkTecoNetworkService.getCredentialByEntityId(curSecId);
          final curSecPin = (secondary['biometricPin'] ?? curSecCred?.biometricPin ?? '').toString().trim();
          final curEmpCred = ZkTecoNetworkService.getCredentialByEntityId(empId);
          final curEmpPin = (emp['biometricPin'] ?? curEmpCred?.biometricPin ?? '').toString().trim();

          return AlertDialog(
            backgroundColor: theme.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDE9FE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.merge_type_rounded, color: Color(0xFF7C3AED), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Merge Staff Profiles', style: TextStyle(color: theme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                      Text('Combine duplicate profiles into one unified record', style: TextStyle(color: theme.textSecondary, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Profile Comparison Cards
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.bgCardAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.4)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: const [
                                    Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 14),
                                    SizedBox(width: 4),
                                    Text('Keep (Primary)', style: TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(emp['name']?.toString() ?? 'Staff', style: TextStyle(color: theme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                                Text('${emp['role'] ?? 'Staff'} • ${emp['department'] ?? 'Office'}', style: TextStyle(color: theme.textSecondary, fontSize: 11)),
                                const SizedBox(height: 4),
                                Text(curEmpPin.isNotEmpty ? 'PIN: $curEmpPin' : 'No PIN', style: TextStyle(color: curEmpPin.isNotEmpty ? const Color(0xFF059669) : theme.textTertiary, fontSize: 11, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.bgCardAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: const [
                                    Icon(Icons.remove_circle_outline_rounded, color: Colors.redAccent, size: 14),
                                    SizedBox(width: 4),
                                    Text('Remove (Duplicate)', style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                if (allEmps.length > 2)
                                  DropdownButton<String>(
                                    value: curSecId,
                                    isExpanded: true,
                                    underline: const SizedBox(),
                                    items: allEmps.where((e) => (e['localId'] ?? e['id']) != empId).map((d) {
                                      final dId = (d['localId'] ?? d['id'] ?? '').toString();
                                      final dName = (d['name'] ?? d['employeeName'] ?? 'Staff').toString();
                                      final dRole = (d['role'] ?? 'Staff').toString();
                                      return DropdownMenuItem(value: dId, child: Text('$dName ($dRole)', style: TextStyle(fontSize: 11.5, color: theme.textPrimary), overflow: TextOverflow.ellipsis));
                                    }).toList(),
                                    onChanged: (newId) {
                                      if (newId != null) {
                                        final matched = allEmps.firstWhere((d) => (d['localId'] ?? d['id']) == newId);
                                        setDlgState(() {
                                          secondary = matched;
                                          final secP = (matched['biometricPin'] ?? '').toString().trim();
                                          if (pinCtrl.text.isEmpty && secP.isNotEmpty) {
                                            pinCtrl.text = secP;
                                          }
                                        });
                                      }
                                    },
                                  )
                                else ...[
                                  Text(secondary['name']?.toString() ?? 'Staff', style: TextStyle(color: theme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                                  Text('${secondary['role'] ?? 'Staff'} • ${secondary['department'] ?? 'Office'}', style: TextStyle(color: theme.textSecondary, fontSize: 11)),
                                  const SizedBox(height: 4),
                                  Text(curSecPin.isNotEmpty ? 'PIN: $curSecPin' : 'No PIN', style: TextStyle(color: curSecPin.isNotEmpty ? const Color(0xFF059669) : theme.textTertiary, fontSize: 11, fontWeight: FontWeight.w600)),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Merged Staff Details:', style: TextStyle(color: theme.textPrimary, fontSize: 12.5, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: nameCtrl,
                      style: TextStyle(color: theme.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Staff Name',
                        labelStyle: TextStyle(color: theme.textSecondary, fontSize: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: roleCtrl,
                      style: TextStyle(color: theme.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Combined Role / Designation',
                        labelStyle: TextStyle(color: theme.textSecondary, fontSize: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: pinCtrl,
                            style: TextStyle(color: theme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Biometric PIN',
                              labelStyle: TextStyle(color: theme.textSecondary, fontSize: 12),
                              prefixIcon: const Icon(Icons.fingerprint_rounded, size: 18, color: Color(0xFF10B981)),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: deptCtrl,
                            style: TextStyle(color: theme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Department',
                              labelStyle: TextStyle(color: theme.textSecondary, fontSize: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text('Cancel', style: TextStyle(color: theme.textSecondary)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Confirm & Merge Staff Profiles', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () async {
                  final finalName = nameCtrl.text.trim();
                  final finalRole = roleCtrl.text.trim();
                  final finalPin = pinCtrl.text.trim();
                  final finalDept = deptCtrl.text.trim();

                  final primaryMap = Map<String, dynamic>.from(emp);
                  final branch = (primaryMap['branchId'] ?? widget.branchId).toString();
                  primaryMap['name'] = finalName;
                  primaryMap['role'] = finalRole;
                  primaryMap['department'] = finalDept;
                  if (finalPin.isNotEmpty) {
                    primaryMap['biometricPin'] = finalPin;
                    primaryMap['pin'] = finalPin;
                  }

                  // Preserve user linking
                  final linkedUser = primaryMap['userId'] ?? primaryMap['linkedUserId'] ?? secondary['userId'] ?? secondary['linkedUserId'];
                  if (linkedUser != null && linkedUser.toString().isNotEmpty) {
                    primaryMap['userId'] = linkedUser.toString();
                    primaryMap['linkedUserId'] = linkedUser.toString();
                  }

                  // 1. Save unified primary profile
                  await FinanceLocalStorage.saveEmployee(
                    branchId: branch,
                    data: primaryMap,
                    performedBy: LocalStorageService.getActiveUsername(),
                  );

                  // 2. Assign PIN in ZKTeco credentials
                  if (finalPin.isNotEmpty) {
                    await ZkTecoNetworkService.assignPinToEntity(
                      entityId: empId,
                      entityName: finalName,
                      entityType: 'employee',
                      branchId: branch,
                      customPin: finalPin,
                    );
                  }

                  // 3. Link User record if exists
                  if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
                    final uBox = Hive.box(LocalStorageService.usersBox);
                    for (final uk in uBox.keys) {
                      final uVal = uBox.get(uk);
                      if (uVal is Map) {
                        final uName = (uVal['name'] ?? uVal['username'] ?? '').toString().trim().toLowerCase();
                        if (uName == finalName.toLowerCase() || (linkedUser != null && (uk.toString() == linkedUser.toString() || uVal['uid'] == linkedUser))) {
                          final uMap = Map<String, dynamic>.from(uVal);
                          uMap['linkedEmployeeId'] = empId;
                          uMap['linkedEmployeeName'] = finalName;
                          if (finalPin.isNotEmpty) uMap['biometricPin'] = finalPin;
                          uMap['role'] = finalRole;
                          await uBox.put(uk, uMap);
                        }
                      }
                    }
                  }

                  // 4. Delete the duplicate profile
                  final deleteId = (secondary['localId'] ?? secondary['id'] ?? '').toString();
                  if (deleteId.isNotEmpty && deleteId != empId) {
                    await FinanceLocalStorage.employeesBox.delete(deleteId);
                    await LocalStorageService.enqueueSync({
                      'type': 'delete_employee',
                      'branchId': branch,
                      'localId': deleteId,
                      'data': {'id': deleteId, 'isDeleted': true},
                    });
                  }

                  Navigator.pop(dialogCtx);
                  setState(() {});
                  showCustomSnackBar(context, '✅ Successfully merged profiles for $finalName! Combined role: $finalRole.');
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

void showCustomBranchDialog({
  required BuildContext context,
  required RoleThemeData theme,
  required void Function(String id, String name) onAdded,
}) {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: theme.bgCard,
        title: Text('Add Custom Branch', style: TextStyle(color: theme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              autofocus: true,
              style: TextStyle(color: theme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter Branch ID (e.g. lahore)',
                hintStyle: TextStyle(color: theme.textTertiary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.bgRule)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.accent)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameController,
              style: TextStyle(color: theme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter Branch Name (e.g. Lahore)',
                hintStyle: TextStyle(color: theme.textTertiary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.bgRule)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.accent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: theme.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: theme.accent),
            onPressed: () async {
              final id = idController.text.trim().toLowerCase();
              final name = nameController.text.trim();
              if (id.isNotEmpty && name.isNotEmpty) {
                await FinanceLocalStorage.addCustomBranch(id, name);
                Navigator.pop(ctx);
                onAdded(id, name);
              }
            },
            child: const Text('Add Branch', style: TextStyle(color: Colors.white)),
          ),
        ],
      );
    },
  );
}