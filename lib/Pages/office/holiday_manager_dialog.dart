// lib/pages/office/holiday_manager_dialog.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/finance_local_storage.dart';
import '../../services/local_storage_service.dart';
import 'shared_widgets.dart';
import '../../design/design_system.dart';

class HolidayManagerDialog extends StatefulWidget {
  final String branchId;
  final List<Map<String, dynamic>> branches;
  final String userRole;

  const HolidayManagerDialog({
    super.key,
    required this.branchId,
    required this.branches,
    required this.userRole,
  });

  /// Opens the Holiday Manager in a responsive executive workspace modal
  static Future<void> open({
    required BuildContext context,
    required String branchId,
    List<Map<String, dynamic>>? branches,
    String? userRole,
    VoidCallback? onSaved,
  }) async {
    final bList = branches ?? [
      {'id': branchId, 'name': branchId.toUpperCase()}
    ];
    final role = userRole ?? LocalStorageService.getActiveUserRole();
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: HolidayManagerDialog(
          branchId: branchId,
          branches: bList,
          userRole: role,
        ),
      ),
    );
    onSaved?.call();
  }

  @override
  State<HolidayManagerDialog> createState() => _HolidayManagerDialogState();
}

class _HolidayManagerDialogState extends State<HolidayManagerDialog> {
  // Tab index: 0 = Scheduled Holidays List, 1 = Schedule / Edit Holiday Form
  int _activeTabIndex = 0;
  String? _editingHolidayId;

  // Form controllers & states
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _dateCtrl = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final TextEditingController _endDateCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();

  // Holiday classification: 'static' (Fixed Annual), 'floating' (Eid / Variable), 'adhoc' (Rain / Emergency)
  String _holidayType = 'static';
  bool _isPaid = true;

  // Branch Scope
  bool _allBranchesScope = true;
  final Map<String, bool> _selectedBranches = {};

  // Department Scope (department-specific holidays)
  bool _allDeptsScope = true;
  final List<String> _departmentsList = [];
  final Map<String, bool> _selectedDepts = {};

  // Role Scope (role-specific holidays e.g. Teachers only, Drivers only, Doctors only)
  bool _allRolesScope = true;
  final List<String> _rolesList = [];
  final Map<String, bool> _selectedRoles = {};

  // Duty staff who WORK on this holiday (e.g. for Eid, emergency kitchen/dispensary)
  final Map<String, bool> _dutyStaff = {};
  List<Map<String, dynamic>> _availableEmployees = [];
  String _dutySearchQuery = '';
  String _dutyDeptFilter = 'all';

  // Exceptions (departments remaining open)
  final List<Map<String, String>> _exceptions = [];

  // Filter state for scheduled holidays tab
  String _searchQuery = '';
  String _typeFilter = 'all'; // 'all', 'static', 'floating', 'adhoc'

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _initScopesAndData();
  }

  void _initScopesAndData() {
    // 1. Branches scope
    for (final b in widget.branches) {
      final bId = b['id']?.toString() ?? '';
      if (bId.isNotEmpty) {
        _selectedBranches[bId] = (bId == widget.branchId);
      }
    }

    // 2. Departments scope from storage
    final depts = FinanceLocalStorage.getAllDepartments();
    _departmentsList.clear();
    _departmentsList.addAll(depts);
    for (final d in _departmentsList) {
      _selectedDepts[d] = true;
    }

    // 3. Roles scope from storage
    final roles = FinanceLocalStorage.getAllEmployeeRoles();
    _rolesList.clear();
    _rolesList.addAll(roles);
    for (final r in _rolesList) {
      _selectedRoles[r] = true;
    }

    // 4. Load employees for duty staff assignment
    _loadAvailableEmployees();
  }

  void _loadAvailableEmployees() {
    try {
      final emps = FinanceLocalStorage.getEmployees(widget.branchId);
      setState(() {
        _availableEmployees = emps.where((e) {
          final status = (e['employmentStatus'] ?? e['status'] ?? 'active').toString().toLowerCase();
          return status == 'active';
        }).toList();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _dateCtrl.dispose();
    _endDateCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  bool get _isExecutive {
    final role = widget.userRole.toLowerCase();
    return ['admin', 'ceo', 'chairman', 'hq manager', 'global admin'].contains(role);
  }

  String _getBranchName(String id) {
    if (id == 'all') return 'All Branches';
    for (final b in widget.branches) {
      if (b['id'] == id) {
        return b['name']?.toString() ?? id;
      }
    }
    return id;
  }

  void _resetForm() {
    _editingHolidayId = null;
    _nameCtrl.clear();
    _dateCtrl.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _endDateCtrl.clear();
    _notesCtrl.clear();
    _holidayType = 'static';
    _isPaid = true;
    _dutyStaff.clear();
    _dutySearchQuery = '';
    _dutyDeptFilter = 'all';

    _allBranchesScope = true;
    for (final key in _selectedBranches.keys) {
      _selectedBranches[key] = (key == widget.branchId);
    }

    _allDeptsScope = true;
    for (final key in _selectedDepts.keys) {
      _selectedDepts[key] = true;
    }

    _allRolesScope = true;
    for (final key in _selectedRoles.keys) {
      _selectedRoles[key] = true;
    }

    _exceptions.clear();
  }

  void _loadHolidayForEdit(Map<String, dynamic> hol) {
    _editingHolidayId = hol['id']?.toString() ?? hol['localId']?.toString();
    _nameCtrl.text = hol['name']?.toString() ?? '';
    _dateCtrl.text = hol['date']?.toString() ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    _endDateCtrl.text = hol['endDate']?.toString() ?? '';
    _notesCtrl.text = hol['notes']?.toString() ?? '';
    _holidayType = (hol['type'] ?? 'static').toString().toLowerCase();
    _isPaid = hol['isPaid'] != false;

    // Branches
    final bList = hol['branches'] is List ? List<String>.from(hol['branches'] as List) : <String>[];
    if (bList.contains('all') || bList.isEmpty) {
      _allBranchesScope = true;
      for (final k in _selectedBranches.keys) {
        _selectedBranches[k] = (k == widget.branchId);
      }
    } else {
      _allBranchesScope = false;
      for (final k in _selectedBranches.keys) {
        _selectedBranches[k] = bList.contains(k);
      }
    }

    // Departments
    final dList = hol['departments'] is List ? List<String>.from(hol['departments'] as List) : <String>[];
    if (dList.contains('all') || dList.isEmpty) {
      _allDeptsScope = true;
      for (final k in _selectedDepts.keys) {
        _selectedDepts[k] = true;
      }
    } else {
      _allDeptsScope = false;
      for (final k in _selectedDepts.keys) {
        _selectedDepts[k] = dList.contains(k);
      }
    }

    // Roles
    final rList = hol['roles'] is List ? List<String>.from(hol['roles'] as List) : <String>[];
    if (rList.contains('all') || rList.isEmpty) {
      _allRolesScope = true;
      for (final k in _selectedRoles.keys) {
        _selectedRoles[k] = true;
      }
    } else {
      _allRolesScope = false;
      for (final k in _selectedRoles.keys) {
        _selectedRoles[k] = rList.contains(k);
      }
    }

    // Duty staff
    _dutyStaff.clear();
    final wList = hol['workingEmployees'] is List ? List<String>.from(hol['workingEmployees'] as List) : <String>[];
    for (final eId in wList) {
      _dutyStaff[eId] = true;
    }

    // Exceptions
    _exceptions.clear();
    final exList = hol['exceptions'] is List ? List<dynamic>.from(hol['exceptions'] as List) : [];
    for (final ex in exList) {
      if (ex is Map) {
        _exceptions.add({
          'branchId': ex['branchId']?.toString() ?? 'all',
          'department': ex['department']?.toString() ?? 'Office',
        });
      }
    }

    setState(() {
      _activeTabIndex = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final size = MediaQuery.of(context).size;
    final isNarrow = GBreakpoint.isMobile(context);

    return Container(
      width: isNarrow ? double.infinity : 940,
      height: isNarrow ? (size.height * 0.92) : (size.height * 0.88),
      constraints: const BoxConstraints(maxWidth: 960, maxHeight: 850),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Modal Header with Icon & Actions
            _buildDialogHeader(t),

            // Tab Navigation Bar
            _buildTabBar(t),

            // Tab Body
            Expanded(
              child: _activeTabIndex == 0
                  ? _buildHolidaysWorkspace(t, isNarrow)
                  : _buildScheduleFormTab(t, isNarrow),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Header & Tab Navigation
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDialogHeader(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                ),
                child: Icon(Icons.festival_rounded, color: t.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Holiday & Off-Day Management',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: t.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Configure organization-wide, branch, department, or role-specific holidays',
                    style: TextStyle(fontSize: 11, color: t.textTertiary),
                  ),
                ],
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: t.textSecondary,
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(RoleThemeData t) {
    final count = FinanceLocalStorage.getHolidays(widget.branchId).length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          _buildTabButton(
            index: 0,
            label: 'Scheduled Holidays ($count)',
            icon: Icons.calendar_month_outlined,
            t: t,
          ),
          const SizedBox(width: 8),
          _buildTabButton(
            index: 1,
            label: _editingHolidayId != null ? 'Edit Holiday Schedule' : 'Schedule New Holiday',
            icon: _editingHolidayId != null ? Icons.edit_note_rounded : Icons.add_circle_outline,
            t: t,
          ),
          const Spacer(),
          if (_activeTabIndex == 0)
            OutlinedButton.icon(
              onPressed: () => _quickAddStandardHolidays(t),
              icon: const Icon(Icons.bolt, color: SoftPalette.amber400, size: 15),
              label: const Text(
                'Quick Add Public Holidays',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: SoftPalette.amber400,
                side: BorderSide(color: SoftPalette.amber400.withValues(alpha: 0.4)),
                backgroundColor: SoftPalette.amber400.withValues(alpha: 0.08),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required int index,
    required String label,
    required IconData icon,
    required RoleThemeData t,
  }) {
    final isSelected = _activeTabIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          if (index == 0 && _activeTabIndex == 1 && _editingHolidayId != null) {
            _resetForm();
          }
          _activeTabIndex = index;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? t.accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? t.accent : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? t.accent : t.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? t.accent : t.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // TAB 0: Scheduled Holidays Workspace
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildHolidaysWorkspace(RoleThemeData t, bool isNarrow) {
    return ValueListenableBuilder(
      valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.financeHolidaysBox)),
      builder: (ctx, Box box, _) {
        final allHolidays = FinanceLocalStorage.getHolidays(widget.branchId);

        // Filter by Search Query & Type
        final filteredList = allHolidays.where((hol) {
          final name = (hol['name'] ?? '').toString().toLowerCase();
          final type = (hol['type'] ?? 'static').toString().toLowerCase();
          final date = (hol['date'] ?? '').toString().toLowerCase();
          final depts = (hol['departments'] is List ? (hol['departments'] as List).join(' ') : '').toLowerCase();
          final roles = (hol['roles'] is List ? (hol['roles'] as List).join(' ') : '').toLowerCase();

          // Type filter
          if (_typeFilter != 'all') {
            if (_typeFilter == 'static' && !(type == 'static' || type == 'fixed')) return false;
            if (_typeFilter == 'floating' && type != 'floating') return false;
            if (_typeFilter == 'adhoc' && !(type == 'adhoc' || type == 'emergency')) return false;
          }

          // Search query
          if (_searchQuery.trim().isNotEmpty) {
            final q = _searchQuery.toLowerCase().trim();
            final matches = name.contains(q) || date.contains(q) || depts.contains(q) || roles.contains(q);
            if (!matches) return false;
          }

          return true;
        }).toList();

        // Calculate KPI Metrics
        final totalCount = allHolidays.length;
        final staticCount = allHolidays.where((h) => (h['type'] == 'static' || h['type'] == 'fixed')).length;
        final floatingCount = allHolidays.where((h) => h['type'] == 'floating').length;
        final adhocCount = allHolidays.where((h) => (h['type'] == 'adhoc' || h['type'] == 'emergency')).length;

        return Column(
          children: [
            // KPI Summary Row
            _buildKpiMetricsRow(t, totalCount, staticCount, floatingCount, adhocCount),

            // Search & Filter Toolbar
            _buildSearchAndFilterToolbar(t),

            // Main List Content
            Expanded(
              child: filteredList.isEmpty
                  ? _buildEmptyState(t, allHolidays.isEmpty)
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      itemCount: filteredList.length,
                      itemBuilder: (c, i) => _buildHolidayCard(t, filteredList[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildKpiMetricsRow(RoleThemeData t, int total, int statics, int floating, int adhoc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgCardAlt.withValues(alpha: 0.5),
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          _buildKpiChip('Total Holidays', total.toString(), Icons.event_available, SoftPalette.blue400, t),
          const SizedBox(width: 8),
          _buildKpiChip('Fixed Annual', statics.toString(), Icons.push_pin_outlined, SoftPalette.teal500, t),
          const SizedBox(width: 8),
          _buildKpiChip('Eid / Floating', floating.toString(), Icons.nightlight_outlined, SoftPalette.emerald500, t),
          const SizedBox(width: 8),
          _buildKpiChip('Emergency / Once', adhoc.toString(), Icons.thunderstorm_outlined, SoftPalette.amber400, t),
        ],
      ),
    );
  }

  Widget _buildKpiChip(String label, String value, IconData icon, Color color, RoleThemeData t) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: TextStyle(fontSize: 9.5, color: t.textSecondary), maxLines: 1),
                  Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchAndFilterToolbar(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          // Search Box
          Expanded(
            child: SizedBox(
              height: 34,
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search by holiday name, dept, role...',
                  hintStyle: TextStyle(fontSize: 11.5, color: t.textTertiary),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  isDense: true,
                  filled: true,
                  fillColor: t.bgCardAlt,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: t.bgRule),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: t.bgRule),
                  ),
                ),
                style: TextStyle(fontSize: 12, color: t.textPrimary),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Type Filters
          _buildFilterChip('All Types', 'all', t),
          const SizedBox(width: 4),
          _buildFilterChip('Fixed', 'static', t),
          const SizedBox(width: 4),
          _buildFilterChip('Eid / Floating', 'floating', t),
          const SizedBox(width: 4),
          _buildFilterChip('Emergency', 'adhoc', t),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, RoleThemeData t) {
    final isSelected = _typeFilter == value;
    return InkWell(
      onTap: () => setState(() => _typeFilter = value),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? t.accent.withValues(alpha: 0.15) : t.bgCardAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? t.accent : t.bgRule,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? t.accent : t.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildHolidayCard(RoleThemeData t, Map<String, dynamic> hol) {
    final id = hol['id']?.toString() ?? hol['localId']?.toString() ?? '';
    final name = hol['name']?.toString() ?? 'Holiday';
    final dateRaw = hol['date'];
    final endDateRaw = hol['endDate'];
    DateTime? parsedDate;
    if (dateRaw is String) parsedDate = DateTime.tryParse(dateRaw);
    final dateStr = parsedDate != null ? DateFormat('EEEE, dd MMM yyyy').format(parsedDate) : (dateRaw?.toString() ?? '');

    String dateDisplay = dateStr;
    if (endDateRaw != null && endDateRaw.toString().isNotEmpty) {
      DateTime? endParsed = DateTime.tryParse(endDateRaw.toString());
      if (endParsed != null && parsedDate != null && !endParsed.isAtSameMomentAs(parsedDate)) {
        final days = endParsed.difference(parsedDate).inDays + 1;
        dateDisplay = '${DateFormat('dd MMM').format(parsedDate)} - ${DateFormat('dd MMM yyyy').format(endParsed)} ($days Days)';
      }
    }

    final type = (hol['type'] ?? 'static').toString().toLowerCase();
    final workingEmployees = hol['workingEmployees'] is List ? List<String>.from(hol['workingEmployees'] as List) : <String>[];
    final branches = hol['branches'] is List ? List<String>.from(hol['branches'] as List) : <String>[];
    final departments = hol['departments'] is List ? List<String>.from(hol['departments'] as List) : <String>[];
    final roles = hol['roles'] is List ? List<String>.from(hol['roles'] as List) : <String>[];
    final exceptions = hol['exceptions'] is List ? List<dynamic>.from(hol['exceptions'] as List) : [];
    final isPaid = hol['isPaid'] != false;

    final isGlobalBranch = branches.contains('all');
    final appliesToAllDepts = departments.contains('all') || departments.isEmpty;
    final appliesToAllRoles = roles.contains('all') || roles.isEmpty;

    return Card(
      color: t.bgCard,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: t.bgRule),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Type icon, Name, Date, Edit & Delete actions
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTypeAvatar(type),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: TextStyle(
                                color: t.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                          if (hol['syncStatus'] == 'pending')
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              margin: const EdgeInsets.only(right: 6),
                              decoration: BoxDecoration(
                                color: SoftPalette.amber300.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('Syncing...', style: TextStyle(color: SoftPalette.amber300, fontSize: 9, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.event_outlined, size: 12, color: t.textTertiary),
                          const SizedBox(width: 4),
                          Text(dateDisplay, style: TextStyle(color: t.textSecondary, fontSize: 11.5, fontWeight: FontWeight.w500)),
                          if (type == 'static' || type == 'fixed') ...[
                            const SizedBox(width: 8),
                            Text('• Repeats annually', style: TextStyle(color: SoftPalette.blue400, fontSize: 10.5, fontStyle: FontStyle.italic)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Action Buttons
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      color: t.accent,
                      tooltip: 'Edit Holiday',
                      onPressed: () => _loadHolidayForEdit(hol),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: SoftPalette.red400, size: 18),
                      tooltip: 'Delete Holiday',
                      onPressed: () => _confirmDelete(id, branches),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 8),
            Divider(color: t.bgRule, height: 1),
            const SizedBox(height: 8),

            // Row 2: Granular Scope Badges (Branch, Department, Role, Duty Staff, Paid)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Rule Type Badge
                if (type == 'static' || type == 'fixed')
                  _buildScopeBadge('📌 Fixed Annual', SoftPalette.blue400, t)
                else if (type == 'floating')
                  _buildScopeBadge('🌙 Floating / Eid', SoftPalette.teal500, t)
                else
                  _buildScopeBadge('🌧️ Emergency / One-time', SoftPalette.amber400, t),

                // Branch Scope Badge
                _buildScopeBadge(
                  isGlobalBranch ? '🏢 All Branches' : '🏢 Branches: ${branches.map(_getBranchName).join(", ")}',
                  isGlobalBranch ? SoftPalette.blue400 : SoftPalette.teal500,
                  t,
                ),

                // Department Scope Badge (User highlight!)
                _buildScopeBadge(
                  appliesToAllDepts ? '🏷️ All Departments' : '🏷️ Depts: ${departments.join(", ")}',
                  appliesToAllDepts ? SoftPalette.gray400 : SoftPalette.emerald500,
                  t,
                  isHighlighted: !appliesToAllDepts,
                ),

                // Role Scope Badge (User highlight!)
                _buildScopeBadge(
                  appliesToAllRoles ? '👤 All Roles' : '👤 Roles: ${roles.join(", ")}',
                  appliesToAllRoles ? SoftPalette.gray400 : SoftPalette.violet400,
                  t,
                  isHighlighted: !appliesToAllRoles,
                ),

                // Duty Staff Badge
                if (workingEmployees.isNotEmpty)
                  _buildScopeBadge('💼 ${workingEmployees.length} Duty Staff Working', SoftPalette.amber400, t),

                // Paid / Unpaid Badge
                _buildScopeBadge(isPaid ? '💵 Paid' : 'Unpaid', isPaid ? SoftPalette.emerald500 : SoftPalette.red400, t),
              ],
            ),

            // Exceptions if any
            if (exceptions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: SoftPalette.amber300, size: 12),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Exceptions (Working): ${exceptions.map((ex) => "${ex['department']} (${_getBranchName(ex['branchId']?.toString() ?? 'all')})").join(", ")}',
                        style: TextStyle(color: t.textSecondary, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTypeAvatar(String type) {
    IconData icon;
    Color color;
    if (type == 'static' || type == 'fixed') {
      icon = Icons.push_pin_rounded;
      color = SoftPalette.blue400;
    } else if (type == 'floating') {
      icon = Icons.nightlight_round;
      color = SoftPalette.teal500;
    } else {
      icon = Icons.thunderstorm_rounded;
      color = SoftPalette.amber400;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }

  Widget _buildScopeBadge(String text, Color color, RoleThemeData t, {bool isHighlighted = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isHighlighted ? color.withValues(alpha: 0.2) : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isHighlighted ? color : color.withValues(alpha: 0.3),
          width: isHighlighted ? 1.2 : 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: isHighlighted ? FontWeight.bold : FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildEmptyState(RoleThemeData t, bool isTotallyEmpty) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GEmptyIllustration(
            isTotallyEmpty
                ? GEmptyIllustrationKind.people
                : GEmptyIllustrationKind.search,
            size: 136,
            fallbackIcon: Icons.event_busy_outlined,
          ),
          const SizedBox(height: 12),
          Text(
            isTotallyEmpty ? 'No holidays scheduled' : 'No holidays match your filter',
            style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Text(
              isTotallyEmpty
                  ? 'Click "Quick Add Public Holidays" above to pre-populate official Pakistan holidays, or schedule a custom department/role holiday.'
                  : 'Try clearing your search query or switching to "All Types".',
              style: TextStyle(color: t.textTertiary, fontSize: 11.5),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // TAB 1: Schedule / Edit Holiday Form
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildScheduleFormTab(RoleThemeData t, bool isNarrow) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Banner if editing
          if (_editingHolidayId != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.edit_note, color: t.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Editing Holiday Schedule: ${_nameCtrl.text}',
                      style: TextStyle(color: t.accent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _resetForm();
                      });
                    },
                    child: const Text('Reset to New', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),

          // Step 1: Rule Classification Cards
          _buildHolidayTypeSelector(t),
          const SizedBox(height: 16),

          // Step 2: Basic Details (Occasion Name, Suggestion Chips, Dates, Paid Switch)
          _buildBasicDetailsSection(t),
          const SizedBox(height: 16),

          // Step 3: Multi-Level Targeting Scope (Branch, Department, Role)
          _buildTargetingScopeSection(t),
          const SizedBox(height: 16),

          // Step 4: Essential Duty Staff Assignment (Who works on this holiday)
          _buildDutyStaffSection(t),
          const SizedBox(height: 16),

          // Step 5: Department Exceptions Builder
          _buildExceptionsBuilder(t),
          const SizedBox(height: 16),

          // Step 6: Live Summary Preview Callout
          _buildLiveSummaryPreview(t),
          const SizedBox(height: 20),

          // Step 7: Action Buttons (Cancel / Save)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: t.bgRule),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    setState(() {
                      _resetForm();
                      _activeTabIndex = 0;
                    });
                  },
                  child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: SoftPalette.gray50,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _isSaving ? null : () => _saveHoliday(t),
                  icon: _isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: SoftPalette.gray50, strokeWidth: 2))
                      : const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(
                    _isSaving
                        ? 'Saving Schedule...'
                        : (_editingHolidayId != null ? 'Update Holiday Schedule' : 'Schedule Holiday'),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step 1: Rule Classification ──
  Widget _buildHolidayTypeSelector(RoleThemeData t) {
    final types = [
      {
        'id': 'static',
        'title': 'Fixed Annual',
        'subtitle': 'Recurs every year on the same date\n(e.g. 14 Aug Independence Day, 23 Mar)',
        'icon': Icons.push_pin_rounded,
        'color': SoftPalette.blue400,
      },
      {
        'id': 'floating',
        'title': 'Floating / Eid',
        'subtitle': 'Shifts yearly, supports multi-day ranges & essential duty staff assignment',
        'icon': Icons.nightlight_round,
        'color': SoftPalette.teal500,
      },
      {
        'id': 'adhoc',
        'title': 'Emergency / Once',
        'subtitle': 'One-off day declared for emergencies\n(e.g. Rain Emergency, City Strike, Heatwave)',
        'icon': Icons.thunderstorm_rounded,
        'color': SoftPalette.amber400,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('1. HOLIDAY CLASSIFICATION / RECURRENCE RULE *', Icons.rule_rounded, t),
        const SizedBox(height: 8),
        Row(
          children: types.map((item) {
            final id = item['id'] as String;
            final isSelected = (_holidayType == id);
            final color = item['color'] as Color;

            return Expanded(
              child: InkWell(
                onTap: () => setState(() => _holidayType = id),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isSelected ? color.withValues(alpha: 0.12) : t.bgCardAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? color : t.bgRule,
                      width: isSelected ? 1.8 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(item['icon'] as IconData, size: 16, color: isSelected ? color : t.textSecondary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item['title'] as String,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? color : t.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        item['subtitle'] as String,
                        style: TextStyle(fontSize: 9.5, color: t.textTertiary, height: 1.25),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Step 2: Basic Details ──
  Widget _buildBasicDetailsSection(RoleThemeData t) {
    final suggestions = [
      {'name': 'Eid-ul-Fitr', 'type': 'floating'},
      {'name': 'Eid-ul-Adha', 'type': 'floating'},
      {'name': 'Pakistan Day', 'type': 'static', 'month': 3, 'day': 23},
      {'name': 'Labour Day', 'type': 'static', 'month': 5, 'day': 1},
      {'name': 'Independence Day', 'type': 'static', 'month': 8, 'day': 14},
      {'name': 'Iqbal Day', 'type': 'static', 'month': 11, 'day': 9},
      {'name': 'Quaid-e-Azam Day', 'type': 'static', 'month': 12, 'day': 25},
      {'name': 'Rain Emergency', 'type': 'adhoc'},
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('2. BASIC DETAILS & DURATION *', Icons.event_note, t),
          const SizedBox(height: 10),

          // Name Field
          buildFormField(
            controller: _nameCtrl,
            label: 'Holiday Occasion / Name *',
            icon: Icons.edit_note_rounded,
            theme: t,
          ),

          // Quick Suggestion Chips
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Text('Quick Templates: ', style: TextStyle(fontSize: 10, color: t.textTertiary)),
                ...suggestions.map((s) {
                  final sName = s['name'] as String;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _nameCtrl.text = sName;
                        _holidayType = s['type'] as String;
                        if (s.containsKey('month') && s.containsKey('day')) {
                          final curYear = DateTime.now().year;
                          final d = DateTime(curYear, s['month'] as int, s['day'] as int);
                          _dateCtrl.text = DateFormat('yyyy-MM-dd').format(d);
                          _endDateCtrl.clear();
                        }
                      });
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: Text(sName, style: TextStyle(fontSize: 10, color: t.accent, fontWeight: FontWeight.w500)),
                    ),
                  );
                }),
              ],
            ),
          ),

          // Dates Row
          Row(
            children: [
              Expanded(
                child: buildDatePickerField(
                  context: context,
                  controller: _dateCtrl,
                  label: 'Holiday Start Date *',
                  icon: Icons.calendar_today,
                  theme: t,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: buildDatePickerField(
                  context: context,
                  controller: _endDateCtrl,
                  label: 'End Date (Optional for Multi-Day)',
                  icon: Icons.event,
                  theme: t,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // Paid Holiday Switch
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'Paid Holiday (Employees receive normal pay on this day)',
              style: TextStyle(color: t.textPrimary, fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'If checked, payroll will not deduct wages for scheduled employees on this holiday.',
              style: TextStyle(color: t.textTertiary, fontSize: 10),
            ),
            value: _isPaid,
            activeColor: t.accent,
            onChanged: (val) => setState(() => _isPaid = val ?? true),
          ),
        ],
      ),
    );
  }

  // ── Step 3: Multi-Level Targeting Scope (Branch, Department, Role) ──
  Widget _buildTargetingScopeSection(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader('3. MULTI-LEVEL TARGETING SCOPE (BRANCH, DEPARTMENT & ROLE) *', Icons.hub_rounded, t),
          const SizedBox(height: 6),
          Text(
            'Target this holiday to specific branches, departments, or staff roles. Perfect when ONLY a department (e.g. Dispensary or Kitchen) or ONLY select roles (e.g. Teachers or Drivers) have an off day.',
            style: TextStyle(color: t.textSecondary, fontSize: 10.5, height: 1.3),
          ),
          const SizedBox(height: 14),

          // ── Scope A: Branch Specificity ──
          if (_isExecutive) ...[
            _buildScopeSelectorHeader(
              title: 'Branch Scope',
              isAll: _allBranchesScope,
              onToggleAll: (all) => setState(() => _allBranchesScope = all),
              t: t,
            ),
            if (!_allBranchesScope) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: t.bgCard, borderRadius: BorderRadius.circular(8), border: Border.all(color: t.bgRule)),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: widget.branches.map((b) {
                    final bId = b['id']?.toString() ?? '';
                    final bName = b['name']?.toString() ?? bId;
                    final isChecked = _selectedBranches[bId] ?? false;
                    return FilterChip(
                      selected: isChecked,
                      selectedColor: t.accent.withValues(alpha: 0.18),
                      checkmarkColor: t.accent,
                      label: Text('$bName ($bId)', style: TextStyle(fontSize: 11, color: isChecked ? t.accent : t.textPrimary)),
                      onSelected: (val) => setState(() => _selectedBranches[bId] = val),
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 14),
          ],

          // ── Scope B: Department Specificity (User requested) ──
          _buildScopeSelectorHeader(
            title: 'Department Specificity (Department-Only Holiday)',
            isAll: _allDeptsScope,
            onToggleAll: (all) => setState(() => _allDeptsScope = all),
            t: t,
          ),
          if (!_allDeptsScope) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: t.bgCard, borderRadius: BorderRadius.circular(8), border: Border.all(color: t.bgRule)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Select the departments that have this off-day:',
                        style: TextStyle(fontSize: 10, color: t.textTertiary, fontStyle: FontStyle.italic),
                      ),
                      Row(
                        children: [
                          InkWell(
                            onTap: () => setState(() {
                              for (final k in _selectedDepts.keys) {
                                _selectedDepts[k] = true;
                              }
                            }),
                            child: Text('Select All', style: TextStyle(fontSize: 10, color: t.accent, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() {
                              for (final k in _selectedDepts.keys) {
                                _selectedDepts[k] = false;
                              }
                            }),
                            child: Text('Clear All', style: TextStyle(fontSize: 10, color: SoftPalette.red400, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      )
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _departmentsList.map((dept) {
                      final isChecked = _selectedDepts[dept] ?? false;
                      return FilterChip(
                        selected: isChecked,
                        selectedColor: SoftPalette.emerald500.withValues(alpha: 0.18),
                        checkmarkColor: SoftPalette.emerald500,
                        label: Text(dept, style: TextStyle(fontSize: 11, color: isChecked ? SoftPalette.emerald500 : t.textPrimary)),
                        onSelected: (val) => setState(() => _selectedDepts[dept] = val),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),

          // ── Scope C: Role Specificity (User requested) ──
          _buildScopeSelectorHeader(
            title: 'Staff Role Specificity (Role-Only Holiday)',
            isAll: _allRolesScope,
            onToggleAll: (all) => setState(() => _allRolesScope = all),
            t: t,
          ),
          if (!_allRolesScope) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: t.bgCard, borderRadius: BorderRadius.circular(8), border: Border.all(color: t.bgRule)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Select the employee roles that have this off-day:',
                        style: TextStyle(fontSize: 10, color: t.textTertiary, fontStyle: FontStyle.italic),
                      ),
                      Row(
                        children: [
                          InkWell(
                            onTap: () => setState(() {
                              for (final k in _selectedRoles.keys) {
                                _selectedRoles[k] = true;
                              }
                            }),
                            child: Text('Select All', style: TextStyle(fontSize: 10, color: t.accent, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() {
                              for (final k in _selectedRoles.keys) {
                                _selectedRoles[k] = false;
                              }
                            }),
                            child: Text('Clear All', style: TextStyle(fontSize: 10, color: SoftPalette.red400, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      )
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _rolesList.map((role) {
                      final isChecked = _selectedRoles[role] ?? false;
                      return FilterChip(
                        selected: isChecked,
                        selectedColor: SoftPalette.violet400.withValues(alpha: 0.18),
                        checkmarkColor: SoftPalette.violet400,
                        label: Text(role, style: TextStyle(fontSize: 11, color: isChecked ? SoftPalette.violet400 : t.textPrimary)),
                        onSelected: (val) => setState(() => _selectedRoles[role] = val),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScopeSelectorHeader({
    required String title,
    required bool isAll,
    required ValueChanged<bool> onToggleAll,
    required RoleThemeData t,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.textPrimary),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => onToggleAll(true),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isAll ? t.accent.withValues(alpha: 0.15) : t.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isAll ? t.accent : t.bgRule),
                ),
                child: Text('All', style: TextStyle(fontSize: 10.5, fontWeight: isAll ? FontWeight.bold : FontWeight.normal, color: isAll ? t.accent : t.textSecondary)),
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: () => onToggleAll(false),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: !isAll ? t.accent.withValues(alpha: 0.15) : t.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: !isAll ? t.accent : t.bgRule),
                ),
                child: Text('Specific Only', style: TextStyle(fontSize: 10.5, fontWeight: !isAll ? FontWeight.bold : FontWeight.normal, color: !isAll ? t.accent : t.textSecondary)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Step 4: Essential Duty Staff Assignment ──
  Widget _buildDutyStaffSection(RoleThemeData t) {
    final filteredEmps = _availableEmployees.where((e) {
      final name = (e['name'] ?? '').toString().toLowerCase();
      final dept = (e['department'] ?? '').toString().toLowerCase();
      final role = (e['role'] ?? '').toString().toLowerCase();

      if (_dutyDeptFilter != 'all') {
        if (dept != _dutyDeptFilter.toLowerCase()) return false;
      }

      if (_dutySearchQuery.trim().isNotEmpty) {
        final q = _dutySearchQuery.toLowerCase().trim();
        return name.contains(q) || dept.contains(q) || role.contains(q);
      }
      return true;
    }).toList();

    final activeDutyCount = _dutyStaff.values.where((v) => v == true).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionHeader('4. ESSENTIAL DUTY PERSONNEL (WORKING ON HOLIDAY)', Icons.badge_outlined, t),
              if (activeDutyCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: SoftPalette.amber400.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('$activeDutyCount on duty', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: SoftPalette.amber400)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Some holidays (like Eid) require essential personnel (Emergency Kitchen, Dispensary, Guards) to remain on duty. Checked staff will be tracked as working and will NOT receive the day off.',
            style: TextStyle(color: t.textSecondary, fontSize: 10.5, height: 1.3),
          ),
          const SizedBox(height: 10),

          // Search & Filter
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search staff by name or role...',
                      hintStyle: TextStyle(fontSize: 11, color: t.textTertiary),
                      prefixIcon: const Icon(Icons.search, size: 14),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      isDense: true,
                      filled: true,
                      fillColor: t.bgCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                    ),
                    style: TextStyle(fontSize: 11, color: t.textPrimary),
                    onChanged: (val) => setState(() => _dutySearchQuery = val),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_dutyStaff.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _dutyStaff.clear()),
                  child: const Text('Clear Duty', style: TextStyle(fontSize: 10.5, color: SoftPalette.red400)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Employees Roster Checklist
          if (_availableEmployees.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No active employees found for duty assignment.', style: TextStyle(fontSize: 11, color: t.textTertiary, fontStyle: FontStyle.italic)),
            )
          else
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.bgRule),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: filteredEmps.length,
                separatorBuilder: (_, _) => Divider(color: t.bgRule, height: 1),
                itemBuilder: (ctx, i) {
                  final emp = filteredEmps[i];
                  final eId = emp['id']?.toString() ?? '';
                  final name = emp['name']?.toString() ?? 'Employee';
                  final role = emp['role']?.toString() ?? '';
                  final dept = emp['department']?.toString() ?? '';
                  final isChecked = _dutyStaff[eId] ?? false;

                  return CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    value: isChecked,
                    activeColor: SoftPalette.amber400,
                    onChanged: (val) {
                      setState(() {
                        _dutyStaff[eId] = val ?? false;
                      });
                    },
                    title: Text(name, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                    subtitle: Text('$role • $dept', style: TextStyle(fontSize: 10, color: t.textSecondary)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // ── Step 5: Exceptions Builder ──
  Widget _buildExceptionsBuilder(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.bgCardAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionHeader('5. DEPARTMENT EXCLUSIONS (REMAINING OPEN)', Icons.remove_circle_outline, t),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 12),
                label: const Text('Add Exclusion', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold)),
                onPressed: () {
                  setState(() {
                    _exceptions.add({'branchId': 'all', 'department': _departmentsList.isNotEmpty ? _departmentsList.first : 'Office'});
                  });
                },
              ),
            ],
          ),
          if (_exceptions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Text(
                'No exclusions defined. All targeted employees get this holiday off.',
                style: TextStyle(color: t.textTertiary, fontSize: 10.5, fontStyle: FontStyle.italic),
              ),
            ),
          ..._exceptions.asMap().entries.map((entry) {
            final idx = entry.key;
            final ex = entry.value;
            final currentBranch = ex['branchId'] ?? 'all';
            final currentDept = ex['department'] ?? 'Office';

            final branchOptions = <String>['all'];
            for (final b in widget.branches) {
              final bId = b['id']?.toString() ?? '';
              if (bId.isNotEmpty) branchOptions.add(bId);
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(color: t.bgCard, borderRadius: BorderRadius.circular(6), border: Border.all(color: t.bgRule)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: currentBranch,
                          dropdownColor: t.bgCard,
                          style: TextStyle(color: t.textPrimary, fontSize: 11),
                          isExpanded: true,
                          items: branchOptions.map((opt) {
                            return DropdownMenuItem<String>(
                              value: opt,
                              child: Text(opt == 'all' ? 'All Branches' : _getBranchName(opt)),
                            );
                          }).toList(),
                          onChanged: !_isExecutive
                              ? null
                              : (val) {
                                  if (val != null) setState(() => _exceptions[idx]['branchId'] = val);
                                },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(color: t.bgCard, borderRadius: BorderRadius.circular(6), border: Border.all(color: t.bgRule)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _departmentsList.contains(currentDept) ? currentDept : (_departmentsList.isNotEmpty ? _departmentsList.first : 'Office'),
                          dropdownColor: t.bgCard,
                          style: TextStyle(color: t.textPrimary, fontSize: 11),
                          isExpanded: true,
                          items: _departmentsList.map((opt) {
                            return DropdownMenuItem<String>(value: opt, child: Text(opt));
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _exceptions[idx]['department'] = val);
                          },
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, color: SoftPalette.red400, size: 18),
                    onPressed: () => setState(() => _exceptions.removeAt(idx)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Step 6: Live Summary Preview ──
  Widget _buildLiveSummaryPreview(RoleThemeData t) {
    final name = _nameCtrl.text.trim().isEmpty ? '(Holiday Name)' : _nameCtrl.text.trim();
    final date = _dateCtrl.text.trim();
    final endDate = _endDateCtrl.text.trim();
    final durationStr = endDate.isNotEmpty ? '$date to $endDate' : date;

    final selectedBranchesCount = _selectedBranches.values.where((v) => v == true).length;
    final branchSummary = _allBranchesScope ? 'All Branches' : '$selectedBranchesCount Branches';

    final selectedDepts = _selectedDepts.entries.where((e) => e.value == true).map((e) => e.key).toList();
    final deptSummary = _allDeptsScope ? 'All Departments' : 'Depts: ${selectedDepts.join(", ")}';

    final selectedRoles = _selectedRoles.entries.where((e) => e.value == true).map((e) => e.key).toList();
    final roleSummary = _allRolesScope ? 'All Roles' : 'Roles: ${selectedRoles.join(", ")}';

    final dutyCount = _dutyStaff.values.where((v) => v == true).length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.preview_rounded, size: 14, color: t.accent),
              const SizedBox(width: 6),
              Text('LIVE TARGETING SUMMARY PREVIEW', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: t.accent)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '📅 $name ($durationStr) • 🏢 $branchSummary • 🏷️ $deptSummary • 👤 $roleSummary • 💼 $dutyCount Staff On-Duty • ${_isPaid ? "💵 Paid" : "Unpaid"}',
            style: TextStyle(color: t.textPrimary, fontSize: 11, height: 1.3, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, RoleThemeData t) {
    return Row(
      children: [
        Icon(icon, size: 14, color: t.accent),
        const SizedBox(width: 6),
        Text(title, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: t.accent, letterSpacing: 0.3)),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Quick Add Pakistan Public Holidays
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _quickAddStandardHolidays(RoleThemeData t) async {
    final curYear = DateTime.now().year;
    final standards = [
      {'name': 'Pakistan Day', 'month': 3, 'day': 23, 'notes': 'National Public Holiday'},
      {'name': 'Labour Day', 'month': 5, 'day': 1, 'notes': 'International Workers Day'},
      {'name': 'Independence Day', 'month': 8, 'day': 14, 'notes': 'National Independence Day'},
      {'name': 'Iqbal Day', 'month': 11, 'day': 9, 'notes': 'Birth Anniversary of Allama Iqbal'},
      {'name': 'Quaid-e-Azam Day / Christmas', 'month': 12, 'day': 25, 'notes': 'Birth Anniversary of Quaid-e-Azam'},
    ];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.bgRule)),
        title: Row(
          children: [
            const Icon(Icons.bolt, color: SoftPalette.amber300, size: 22),
            const SizedBox(width: 8),
            Text('Quick Add Standard Holidays', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will schedule the 5 official Fixed Annual Holidays for all branches, departments, and roles for all future years:',
              style: TextStyle(color: t.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 10),
            for (final s in standards)
              Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, color: SoftPalette.emerald500, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      '${s['name']} (${s['day']}/${s['month']})',
                      style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'These are static fixed holidays that automatically recur every year.',
              style: TextStyle(color: t.textTertiary, fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: t.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add 5 Holidays', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isSaving = true);
    try {
      final curUser = LocalStorageService.getActiveUsername();
      for (final s in standards) {
        final d = DateTime(curYear, s['month'] as int, s['day'] as int);
        await FinanceLocalStorage.saveHoliday(
          name: s['name'] as String,
          date: d,
          type: 'static',
          branches: ['all'],
          departments: ['all'],
          roles: ['all'],
          exceptions: [],
          workingEmployees: [],
          isPaid: true,
          notes: s['notes'] as String?,
          performedBy: curUser,
        );
      }
      if (mounted) {
        showCustomSnackBar(context, 'Successfully added 5 standard public holidays!');
      }
    } catch (e) {
      if (mounted) {
        showCustomSnackBar(context, 'Error adding holidays: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Save Holiday Logic
  // ─────────────────────────────────────────────────────────────────────────

  void _saveHoliday(RoleThemeData t) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showCustomSnackBar(context, 'Please specify the holiday name.', error: true);
      return;
    }

    final dateStr = _dateCtrl.text.trim();
    final date = DateTime.tryParse(dateStr);
    if (date == null) {
      showCustomSnackBar(context, 'Please select a valid start date.', error: true);
      return;
    }

    DateTime? endDate;
    final endDateStr = _endDateCtrl.text.trim();
    if (endDateStr.isNotEmpty) {
      endDate = DateTime.tryParse(endDateStr);
    }

    final List<DateTime> targetDates = [];
    if (endDate != null && endDate.isAfter(date)) {
      var curr = DateTime(date.year, date.month, date.day);
      final limit = DateTime(endDate.year, endDate.month, endDate.day);
      while (curr.isBefore(limit) || curr.isAtSameMomentAs(limit)) {
        targetDates.add(curr);
        curr = curr.add(const Duration(days: 1));
      }
    } else {
      targetDates.add(date);
    }

    // Resolve branch selection
    final List<String> branches = [];
    if (!_isExecutive) {
      branches.add(widget.branchId);
    } else {
      if (_allBranchesScope) {
        branches.add('all');
      } else {
        final selected = _selectedBranches.entries
            .where((entry) => entry.value == true)
            .map((entry) => entry.key)
            .toList();
        if (selected.isEmpty) {
          showCustomSnackBar(context, 'Please select at least one branch.', error: true);
          return;
        }
        branches.addAll(selected);
      }
    }

    // Resolve department selection (Department-specific holidays!)
    final List<String> departments = [];
    if (_allDeptsScope) {
      departments.add('all');
    } else {
      final selected = _selectedDepts.entries
          .where((entry) => entry.value == true)
          .map((entry) => entry.key)
          .toList();
      if (selected.isEmpty) {
        showCustomSnackBar(context, 'Please select at least one department.', error: true);
        return;
      }
      departments.addAll(selected);
    }

    // Resolve role selection (Role-specific holidays!)
    final List<String> roles = [];
    if (_allRolesScope) {
      roles.add('all');
    } else {
      final selected = _selectedRoles.entries
          .where((entry) => entry.value == true)
          .map((entry) => entry.key)
          .toList();
      if (selected.isEmpty) {
        showCustomSnackBar(context, 'Please select at least one staff role.', error: true);
        return;
      }
      roles.addAll(selected);
    }

    final dutyList = _dutyStaff.entries
        .where((entry) => entry.value == true)
        .map((entry) => entry.key)
        .toList();

    setState(() => _isSaving = true);
    try {
      final curUser = LocalStorageService.getActiveUsername();

      for (final targetDate in targetDates) {
        await FinanceLocalStorage.saveHoliday(
          name: name,
          date: targetDate,
          endDate: (targetDates.length > 1 && targetDate == targetDates.first) ? endDate : null,
          type: _holidayType,
          branches: branches,
          departments: departments,
          roles: roles,
          exceptions: _exceptions,
          workingEmployees: dutyList,
          isPaid: _isPaid,
          notes: _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
          performedBy: curUser,
          holidayId: _editingHolidayId,
        );
      }

      if (mounted) {
        showCustomSnackBar(
          context,
          _editingHolidayId != null ? 'Holiday updated successfully!' : 'Holiday scheduled successfully!',
        );
        setState(() {
          _resetForm();
          _activeTabIndex = 0;
          _isSaving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        showCustomSnackBar(context, 'Failed: $e', error: true);
        setState(() => _isSaving = false);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Delete Holiday Logic
  // ─────────────────────────────────────────────────────────────────────────

  void _confirmDelete(String holidayId, List<String> branches) {
    final t = RoleThemeScope.dataOf(context);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: t.bgCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.bgRule)),
          title: Text('Delete Holiday Schedule', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
          content: Text(
            'Are you sure you want to cancel and delete this holiday schedule? This will restore regular work hour calculations for all employees on this date.',
            style: TextStyle(color: t.textSecondary, fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final curUser = LocalStorageService.getActiveUsername();
                  await FinanceLocalStorage.deleteHoliday(
                    holidayId: holidayId,
                    branches: branches,
                    performedBy: curUser,
                  );
                  if (mounted) showCustomSnackBar(context, 'Holiday schedule removed.');
                } catch (e) {
                  if (mounted) showCustomSnackBar(context, 'Failed: $e', error: true);
                }
              },
              child: const Text('Delete', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }
}
