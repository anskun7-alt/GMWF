// lib/pages/office/finance_page.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';

import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/permission_service.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_loans_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/sync_service.dart';
import 'attendance_tab.dart';
import 'employees_tab.dart';
import 'employee_management_tab.dart';
import 'payroll_tab.dart';
import 'audit_trail_tab.dart';
import 'expenses_tab.dart';
import 'loans_tab.dart';
import 'employee_form_sheet.dart';
import 'holiday_manager_dialog.dart';
import 'finance_report_helper.dart';
import 'shared_widgets.dart';
import '../../services/finance_ledger_storage.dart';
import 'finance_overview_dashboard.dart';
import 'report_builder_page.dart';
import 'bank_accounts_sheet.dart';


// ── Design tokens ─────────────────────────────────────────────────────────────
const _kAccent     = Color(0xFF0F9A7A);
const _kAccentMuted = Color(0xFFE8F6F0);
const _kBg         = Color(0xFFFBFDFF);
const _kBgCard     = Color(0xFFFFFFFF);
const _kBorder     = Color(0xFFF1F5F9);
const _kTextPrimary   = Color(0xFF111827);
const _kTextSecondary = Color(0xFF6B7280);
const _kTextTertiary  = Color(0xFF9CA3AF);
const _kSidebarWidth  = 210.0;
const _kMobileBreak   = 700.0;

class FinancePage extends StatefulWidget {
  final String branchId;
  final bool isAdmin;
  final int initialTabIndex;

  const FinancePage({
    super.key,
    required this.branchId,
    this.isAdmin = false,
    this.initialTabIndex = 0,
  });

  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  int _selectedIndex = 0;
  late String _activeBranchId;
  String _selectedDeptFilter = 'all';
  List<Map<String, dynamic>> _branches = [];
  bool _isLoadingBranches = false;
  bool _isDownloadingData = false;

  int _pendingSyncCount = 0;
  bool _hasConflicts = false;
  late final Box _syncBox;

  DateTime _attendanceDate = DateTime.now();
  String _payrollMonthKey = DateFormat('yyyy-MM').format(DateTime.now());

  String _getEffectiveUserBranch() {
    final curUser = LocalStorageService.getActiveUserData();
    if (curUser.isNotEmpty) {
      final role = LocalStorageService.getActiveUserRole();
      final isBranchScoped = role == 'branch manager' || role == 'supervisor';
      if (isBranchScoped) {
        final bId = (curUser['branchId']?.toString() ?? '').trim();
        if (bId.isNotEmpty && bId != 'all' && bId != 'global') return bId;
      }
    }
    final raw = widget.branchId;
    return (raw == 'global' || raw.isEmpty) ? 'all' : raw;
  }

  @override
  void initState() {
    super.initState();
    _activeBranchId = _getEffectiveUserBranch();
    _selectedIndex = widget.initialTabIndex.clamp(0, 7);
    _syncBox = Hive.box(LocalStorageService.syncBox);
    _updateSyncCount();
    _syncBox.listenable().addListener(_updateSyncCount);
    FinanceLedgerStorage.initEngine();
    _loadBranches();
  }

  @override
  void dispose() {
    _syncBox.listenable().removeListener(_updateSyncCount);
    super.dispose();
  }

  void _updateSyncCount() {
    if (!mounted) return;
    setState(() {
      _pendingSyncCount = _syncBox.values.where((v) =>
        v is Map && (
          v['type']?.toString().startsWith('save_employee') == true ||
          v['type']?.toString().startsWith('save_salary') == true ||
          v['type']?.toString().startsWith('save_attendance') == true ||
          v['type']?.toString().startsWith('save_finance_settings') == true ||
          v['type']?.toString().startsWith('save_branch_transfer') == true ||
          v['type']?.toString().startsWith('save_expense') == true ||
          v['type']?.toString().startsWith('void_expense') == true ||
          v['type']?.toString().startsWith('save_audit_log') == true
        )
      ).length;

      final conflicts = Hive.box(LocalStorageService.financeSettingsBox).get('sync_conflicts') as List?;
      _hasConflicts = conflicts != null && conflicts.isNotEmpty;
    });
  }

  Future<void> _loadBranches() async {
    setState(() => _isLoadingBranches = true);
    final userRole = LocalStorageService.getActiveUserRole();
    final isBranchScoped = userRole == 'branch manager' || userRole == 'supervisor';
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      if (!mounted) return;
      setState(() {
        _branches = snap.docs.map((d) {
          final data = d.data();
          return {'id': d.id, 'name': data['name'] as String? ?? d.id};
        }).toList();
        if (isBranchScoped) {
          _activeBranchId = _getEffectiveUserBranch();
          _branches = _branches.where((b) => b['id'].toString().toLowerCase() == _activeBranchId.toLowerCase()).toList();
        }
        _isLoadingBranches = false;
      });
      _triggerDownloadForActiveBranch();
    } catch (e) {
      final box = Hive.box(LocalStorageService.branchesBox);
      if (!mounted) return;
      setState(() {
        _branches = box.values.map((v) => Map<String, dynamic>.from(v as Map)).toList();
        if (isBranchScoped) {
          _activeBranchId = _getEffectiveUserBranch();
          _branches = _branches.where((b) => b['id'].toString().toLowerCase() == _activeBranchId.toLowerCase()).toList();
        }
        _isLoadingBranches = false;
      });
      _triggerDownloadForActiveBranch();
    }
  }

  Future<void> _triggerDownloadForActiveBranch({bool force = false}) async {
    final bId = _activeBranchId;
    if (bId.isEmpty) return;
    setState(() => _isDownloadingData = true);
    try {
      SyncService().start(bId);
      await SyncService().triggerFinanceRefresh(force: force);
      await FinanceLoansStorage.migrateLegacyAdvancesToLoans(performedBy: 'System');
      if (force && mounted) showCustomSnackBar(context, 'Financial data refreshed successfully.');
    } catch (e) {
      debugPrint('[FinancePage] Error: $e');
      if (force && mounted) showCustomSnackBar(context, 'Failed to refresh: $e', error: true);
    } finally {
      if (mounted) setState(() => _isDownloadingData = false);
    }
  }

  void _openEmployeeForm(BuildContext ctx, String? employeeId) {
    openEmployeeFormSheet(
      ctx,
      activeBranchId: _activeBranchId,
      branches: _branches,
      employeeId: employeeId,
      onSaved: () {
        if (mounted) {
          _loadBranches();
        }
      },
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final userRole = LocalStorageService.getActiveUserRole();
    
    // Strict Finance Gating
    if (!PermissionService().isFinanceUser(userRole) && !widget.isAdmin) {
      return Scaffold(
        backgroundColor: _kBg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline_rounded, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Access Restricted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kTextPrimary)),
              const SizedBox(height: 8),
              const Text('You do not have permissions to access the Finance & HR module.',
                  style: TextStyle(fontSize: 13, color: _kTextSecondary), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(backgroundColor: _kAccent),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final canViewAudits = PermissionService().getAuditTrailScope(userRole) != 'none';

    return RoleThemeScope(
      role: RoleTheme.globalUser,
      child: Builder(builder: (ctx) {
        final wide = MediaQuery.of(ctx).size.width >= _kMobileBreak;
        final content = _buildContent(userRole, canViewAudits);
        return wide
            ? _buildDesktop(ctx, userRole, canViewAudits, content)
            : _buildMobile(ctx, userRole, canViewAudits, content);
      }),
    );
  }

  // ── Desktop & Mobile Layouts (Sidebar Removed) ──────────────────────────────
  Widget _buildDesktop(BuildContext ctx, String userRole, bool canViewAudits, Widget content) {
    final t = RoleThemeScope.dataOf(ctx);
    return Scaffold(
      backgroundColor: t.bg,
      body: Column(children: [
        _buildHeader(ctx, canViewAudits, t),
        if (_selectedIndex == 0 || _selectedIndex == 6) _buildCashFlowSubTabs(t),
        _buildFilterBar(userRole, t),
        Expanded(child: content),
      ]),
    );
  }

  Widget _buildMobile(BuildContext ctx, String userRole, bool canViewAudits, Widget content) {
    final t = RoleThemeScope.dataOf(ctx);
    return Scaffold(
      backgroundColor: t.bg,
      body: Column(children: [
        _buildHeader(ctx, canViewAudits, t),
        if (_selectedIndex == 0 || _selectedIndex == 6) _buildCashFlowSubTabs(t),
        _buildFilterBar(userRole, t),
        Expanded(child: content),
      ]),
    );
  }

  static const _sectionTitles = [
    'Treasury & Accounts', 'Employee Management', 'Employee Management', 'Payroll',
    'Loans & Advances', 'Expenses', 'Audit Trail & Security Logs', 'Reports & Reconcile'
  ];
  static const _sectionIcons = [
    Icons.account_balance_wallet_outlined, Icons.badge_outlined, Icons.badge_outlined,
    Icons.receipt_long_outlined, Icons.credit_card_outlined, Icons.payments_outlined,
    Icons.history_edu_outlined, Icons.account_balance_outlined
  ];

  Widget _buildHeader(BuildContext ctx, bool canViewAudits, RoleThemeData t) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(children: [
        Icon(_sectionIcons[_selectedIndex], color: t.accent, size: 22),
        const SizedBox(width: 10),
        Text(
          _sectionTitles[_selectedIndex],
          style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: -0.3),
        ),
        const Spacer(),
        _buildSyncChip(),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Force Refresh Data',
          icon: Icon(_isDownloadingData ? Icons.sync_rounded : Icons.refresh_rounded, color: t.textSecondary, size: 20),
          onPressed: () => _triggerDownloadForActiveBranch(force: true),
        ),
        IconButton(
          tooltip: 'Export Reports',
          icon: Icon(Icons.download_outlined, color: t.textSecondary, size: 20),
          onPressed: () => _openExportDialog(ctx),
        ),
        IconButton(
          tooltip: 'Manage Holidays',
          icon: Icon(Icons.calendar_month_outlined, color: t.textSecondary, size: 20),
          onPressed: () => _openHolidaysManager(ctx),
        ),
      ]),
    );
  }

  Widget _buildCashFlowSubTabs(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          ChoiceChip(
            avatar: const Icon(Icons.account_balance_wallet_rounded, size: 16),
            label: const Text('Treasury Overview'),
            selected: _selectedIndex == 0,
            backgroundColor: t.bgCardAlt,
            selectedColor: t.accent.withValues(alpha: 0.15),
            labelStyle: TextStyle(
              fontWeight: FontWeight.bold,
              color: _selectedIndex == 0 ? t.accent : t.textSecondary,
              fontSize: 12,
            ),
            onSelected: (_) => setState(() => _selectedIndex = 0),
          ),
          const SizedBox(width: 10),
          ChoiceChip(
            avatar: const Icon(Icons.history_edu_rounded, size: 16),
            label: const Text('Audit Trail & Security Logs'),
            selected: _selectedIndex == 6,
            backgroundColor: t.bgCardAlt,
            selectedColor: t.accent.withValues(alpha: 0.15),
            labelStyle: TextStyle(
              fontWeight: FontWeight.bold,
              color: _selectedIndex == 6 ? t.accent : t.textSecondary,
              fontSize: 12,
            ),
            onSelected: (_) => setState(() => _selectedIndex = 6),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(String userRole, RoleThemeData t) {
    final cleanRole = userRole.toLowerCase().trim();
    final bool isBranchScoped = cleanRole == 'branch manager' || cleanRole == 'supervisor';
    final effectiveUserBranch = _getEffectiveUserBranch();
    final branchName = FinanceLocalStorage.getBranchName(effectiveUserBranch);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          Icon(Icons.filter_list_rounded, size: 16, color: t.textSecondary),
          const SizedBox(width: 8),
          Text('Filters:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: t.textSecondary)),
          const SizedBox(width: 16),
          if (isBranchScoped) ...[
            Text('Branch', style: TextStyle(fontSize: 11, color: t.textSecondary)),
            const SizedBox(width: 8),
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.bgCardAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.bgRule),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 12, color: t.accent),
                  const SizedBox(width: 6),
                  Text(
                    branchName.isNotEmpty ? branchName : effectiveUserBranch,
                    style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
          ] else if (_branches.isNotEmpty) ...[
            Text('Branch', style: TextStyle(fontSize: 11, color: t.textSecondary)),
            Builder(
              builder: (context) {
                final branchItems = _getUniqueBranchDropdownItems();
                final safeBranchValue = branchItems.any((it) => it.value == _activeBranchId) ? _activeBranchId : 'all';
                return Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: t.bgCardAlt,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: t.bgRule),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: safeBranchValue,
                      dropdownColor: t.bgCard,
                      style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                      items: branchItems,
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _activeBranchId = val;
                          });
                          _triggerDownloadForActiveBranch();
                        }
                      },
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 16),
          ],
          Text('Department', style: TextStyle(fontSize: 11, color: t.textSecondary)),
          const SizedBox(width: 8),
          Builder(
            builder: (context) {
              final deptItems = _getUniqueDepartmentDropdownItems();
              final safeDeptValue = deptItems.any((it) => it.value == _selectedDeptFilter.toLowerCase())
                  ? _selectedDeptFilter.toLowerCase()
                  : 'all';
              return Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.bgRule),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: safeDeptValue,
                    dropdownColor: t.bgCard,
                    style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                    items: deptItems,
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedDeptFilter = val;
                        });
                      }
                    },
                  ),
                ),
              );
            },
          ),
          const Spacer(),
          if ((!isBranchScoped && _activeBranchId != 'all') || _selectedDeptFilter != 'all')
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: Colors.red,
              ),
              icon: const Icon(Icons.clear, size: 14),
              label: const Text('Reset', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              onPressed: () {
                setState(() {
                  _activeBranchId = isBranchScoped ? effectiveUserBranch : 'all';
                  _selectedDeptFilter = 'all';
                });
                _triggerDownloadForActiveBranch();
              },
            ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<String>> _getUniqueDepartmentDropdownItems() {
    final uniqueDepts = <String, String>{};
    uniqueDepts['all'] = 'All Departments';
    final defaults = ['Administration', 'Office', 'Dasterkhawaan', 'Dispensary', 'Madrassa', 'School'];
    for (final d in [...defaults, ...FinanceLocalStorage.getCustomDepartments()]) {
      final key = d.trim().toLowerCase();
      if (key.isNotEmpty && key != 'all') {
        uniqueDepts[key] = d.trim();
      }
    }
    return uniqueDepts.entries.map((e) => DropdownMenuItem<String>(
      value: e.key,
      child: Text(e.value, style: const TextStyle(fontSize: 11)),
    )).toList();
  }

  List<DropdownMenuItem<String>> _getUniqueBranchDropdownItems({bool includeDetails = false}) {
    final uniqueBranches = <String, Map<String, dynamic>>{};
    for (final b in _branches) {
      final id = b['id']?.toString().trim() ?? '';
      if (id.isNotEmpty && id.toLowerCase() != 'all') {
        uniqueBranches[id] = b;
      }
    }
    return [
      const DropdownMenuItem<String>(value: 'all', child: Text('All Branches', style: TextStyle(fontSize: 11))),
      ...uniqueBranches.values.map((b) {
        final bId = b['id']?.toString() ?? '';
        final name = b['name']?.toString() ?? bId;
        final label = includeDetails ? '$name ($bId)' : name;
        return DropdownMenuItem<String>(
          value: bId,
          child: Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
        );
      }),
    ];
  }

  Widget _buildBranchDropdown() {
    final userRole = LocalStorageService.getActiveUserRole();
    final isBranchManager = userRole == 'branch manager' || userRole == 'supervisor';

    if (isBranchManager) {
      final bName = _branches.firstWhereOrNull((b) => b['id'] == _activeBranchId)?['name'] ?? _activeBranchId;
      return Container(
        height: 32,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 12, color: _kTextSecondary),
            const SizedBox(width: 6),
            Text(bName, style: const TextStyle(color: _kTextPrimary, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    final branchItems = _getUniqueBranchDropdownItems(includeDetails: true);
    final safeBranchValue = branchItems.any((it) => it.value == _activeBranchId) ? _activeBranchId : 'all';

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safeBranchValue,
          dropdownColor: _kBgCard,
          style: const TextStyle(color: _kTextPrimary, fontSize: 12, fontWeight: FontWeight.w600),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: _kTextSecondary),
          items: branchItems,
          onChanged: (val) { if (val != null) { setState(() => _activeBranchId = val); _triggerDownloadForActiveBranch(); } },
        ),
      ),
    );
  }

  Widget _buildSyncChip() {
    if (_hasConflicts) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 12),
          const SizedBox(width: 4),
          Text('Needs Review', style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
        ]),
      );
    }
    if (_pendingSyncCount > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
          SizedBox(width: 6),
          Text('Syncing', style: TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold)),
        ]),
      );
    }
    final isOnline = _syncBox.get('last_online_state') as bool? ?? true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isOnline ? const Color(0xFFD1FAE5) : Colors.blue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isOnline ? const Color(0xFF6EE7B7) : Colors.blue.withValues(alpha: 0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(isOnline ? Icons.check_circle_outline_rounded : Icons.offline_pin_outlined,
            color: isOnline ? _kAccent : Colors.blue, size: 12),
        const SizedBox(width: 4),
        Text(isOnline ? '✓ Synced' : '● Offline',
            style: TextStyle(color: isOnline ? _kAccent : Colors.blue, fontSize: 10, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  // ── Content builder ────────────────────────────────────────────────────────
  Widget _buildContent(String userRole, bool canViewAudits) {
    switch (_selectedIndex) {
      case 0:
        return FinanceOverviewDashboard(
          branchId: _activeBranchId,
          userRole: userRole,
          onNavigateToTab: (idx) => setState(() => _selectedIndex = idx),
          onOpenBankAccounts: () => BankAccountsSheet.show(context, onSaved: () => setState(() {})),
        );
      case 1:
      case 2:
        return EmployeeManagementTab(
          branchId: _activeBranchId,
          userRole: userRole,
          date: _attendanceDate,
          onDateChanged: (d) => setState(() => _attendanceDate = d),
          onAddEmployee: () => _openEmployeeForm(context, null),
          onEditEmployee: (ctx, empId) => _openEmployeeForm(ctx, empId),
          departmentFilter: _selectedDeptFilter,
          branches: _branches,
        );
      case 3:
        return PayrollTab(
          branchId: _activeBranchId,
          monthKey: _payrollMonthKey,
          onMonthChanged: (m) => setState(() => _payrollMonthKey = m),
          userRole: userRole,
          departmentFilter: _selectedDeptFilter,
        );
      case 4:
        return LoansTab(
          branchId: _activeBranchId,
          userRole: userRole,
          departmentFilter: _selectedDeptFilter,
        );
      case 5:
        return ExpensesTab(
          branchId: _activeBranchId,
          userRole: userRole,
        );
      case 6:
        return canViewAudits
            ? AuditTrailTab(branchId: _activeBranchId, searchQuery: '', onSearchChanged: (_) {})
            : _buildLockedAudit();
      case 7:
        return ReportBuilderPage(
          branchId: _activeBranchId,
          userRole: userRole,
          branches: _branches,
        );
      default:
        return const SizedBox.shrink();
    }
  }


  Widget _buildLockedAudit() => const Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_outline_rounded, size: 54, color: _kTextTertiary),
      SizedBox(height: 14),
      Text('Access Restricted', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kTextSecondary)),
      SizedBox(height: 6),
      Text('You do not have permissions to view audit trails.',
          style: TextStyle(fontSize: 12, color: _kTextTertiary), textAlign: TextAlign.center),
    ]),
  );

  // ── Dialogs ────────────────────────────────────────────────────────────────
  void _openExportDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: _kBgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.download_outlined, color: _kAccent),
          SizedBox(width: 8),
          Text('Export Reports', style: TextStyle(color: _kTextPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        content: SizedBox(
          width: 500,
          child: _exportView(dCtx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Close', style: TextStyle(color: _kTextSecondary)),
          )
        ],
      ),
    );
  }

  Widget _exportView(BuildContext dCtx) {
    String selType = 'branch', selMonth = _payrollMonthKey, selDept = 'Administration Staff';
    final depts = FinanceLedgerStorage.sortDepartmentsCanonical(
      ['Administration Staff', 'Office', 'Dasterkhwaan', 'Dispensary', 'Madrassa', 'School']
        ..addAll(FinanceLocalStorage.getCustomDepartments())
    );

    return StatefulBuilder(builder: (ctx, setS) {
      return SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 8),
          const Text('Report Type:', style: TextStyle(color: _kTextSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            dropdownColor: _kBgCard, value: selType,
            style: const TextStyle(color: _kTextPrimary, fontSize: 13),
            decoration: InputDecoration(
              filled: true, fillColor: _kBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderSide: const BorderSide(color: _kBorder), borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: _kBorder), borderRadius: BorderRadius.circular(8)),
            ),
            items: const [
              DropdownMenuItem(value: 'branch', child: Text('Branch Payroll Excel')),
              DropdownMenuItem(value: 'department', child: Text('Department Payroll Excel')),
              DropdownMenuItem(value: 'consolidated', child: Text('All Branches Consolidated Excel')),
              DropdownMenuItem(value: 'branch_pdf', child: Text('Branch Payroll PDF')),
              DropdownMenuItem(value: 'department_pdf', child: Text('Department Payroll PDF')),
              DropdownMenuItem(value: 'expenses_excel', child: Text('Daily Expenses Log Excel')),
            ],
            onChanged: (v) { if (v != null) setS(() => selType = v); },
          ),
          if (selType == 'department' || selType == 'department_pdf') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              dropdownColor: _kBgCard, value: selDept,
              decoration: InputDecoration(
                labelText: 'Department', labelStyle: const TextStyle(color: _kTextSecondary, fontSize: 12),
                filled: true, fillColor: _kBg,
                border: OutlineInputBorder(borderSide: const BorderSide(color: _kBorder), borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: _kBorder), borderRadius: BorderRadius.circular(8)),
              ),
              style: const TextStyle(color: _kTextPrimary, fontSize: 13),
              items: depts.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
              onChanged: (v) { if (v != null) setS(() => selDept = v); },
            ),
          ],
          const SizedBox(height: 12),
          const Text('Month:', style: TextStyle(color: _kTextSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, size: 14),
              onPressed: () {
                final p = DateFormat('yyyy-MM').parse(selMonth);
                setS(() => selMonth = DateFormat('yyyy-MM').format(DateTime(p.year, p.month - 1)));
              },
            ),
            Expanded(
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
                child: Text(DateFormat('MMMM yyyy').format(DateFormat('yyyy-MM').parse(selMonth)),
                    style: const TextStyle(color: _kTextPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 14),
              onPressed: selMonth == DateFormat('yyyy-MM').format(DateTime.now()) ? null : () {
                final p = DateFormat('yyyy-MM').parse(selMonth);
                setS(() => selMonth = DateFormat('yyyy-MM').format(DateTime(p.year, p.month + 1)));
              },
            ),
          ]),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 44,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export Now', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () async {
                Navigator.pop(dCtx);
                if (selType == 'branch') await FinanceReportHelper.exportMonthlyExcel(branchId: _activeBranchId, monthKey: selMonth);
                else if (selType == 'department') await FinanceReportHelper.exportMonthlyExcel(branchId: _activeBranchId, monthKey: selMonth, department: selDept);
                else if (selType == 'consolidated') await FinanceReportHelper.exportConsolidatedAllBranchesExcel(branches: _branches, monthKey: selMonth);
                else if (selType == 'branch_pdf') await FinanceReportHelper.exportMonthlyPdf(branchId: _activeBranchId, monthKey: selMonth);
                else if (selType == 'department_pdf') await FinanceReportHelper.exportMonthlyPdf(branchId: _activeBranchId, monthKey: selMonth, department: selDept);
                else if (selType == 'expenses_excel') await FinanceReportHelper.exportExpensesExcel(branchId: _activeBranchId, monthKey: selMonth);
              },
            ),
          ),
        ]),
      );
    });
  }

  void _openHolidaysManager(BuildContext ctx) {
    final userRole = LocalStorageService.getActiveUserRole();
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Card(
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: HolidayManagerDialog(branchId: _activeBranchId, branches: _branches, userRole: userRole),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar
// ─────────────────────────────────────────────────────────────────────────────

class _FinanceSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool canViewAudits;
  final List<Map<String, dynamic>> branches;
  final String activeBranchId;
  final ValueChanged<String> onBranchChanged;
  final int pendingSyncCount;
  final bool isDownloading;
  final VoidCallback onRefresh;
  final VoidCallback onExport;
  final VoidCallback onHolidays;
  final bool isMobile;

  const _FinanceSidebar({
    required this.selectedIndex,
    required this.onSelect,
    required this.canViewAudits,
    required this.branches,
    required this.activeBranchId,
    required this.onBranchChanged,
    required this.pendingSyncCount,
    required this.isDownloading,
    required this.onRefresh,
    required this.onExport,
    required this.onHolidays,
    this.isMobile = false,
  });

  static const _labels = [
    'Overview', 'Employees', 'Attendance', 'Payroll',
    'Loans & Advances', 'Expenses', 'Audit Trail', 'Reports & Reconcile'
  ];
  static const _icons  = [
    Icons.dashboard_outlined, Icons.people_outline, Icons.today_outlined,
    Icons.receipt_long_outlined, Icons.credit_card_outlined, Icons.payments_outlined,
    Icons.history_edu_outlined, Icons.account_balance_outlined
  ];
  static const _iconsA = [
    Icons.dashboard_rounded, Icons.people_rounded, Icons.today_rounded,
    Icons.receipt_long_rounded, Icons.credit_card_rounded, Icons.payments_rounded,
    Icons.history_edu_rounded, Icons.account_balance_rounded
  ];


  @override
  Widget build(BuildContext context) {
    final userName = LocalStorageService.getActiveUsername();
    final userRoleDisplay = LocalStorageService.getActiveUserRole();
    final isBranchManager = userRoleDisplay == 'branch manager' || userRoleDisplay == 'supervisor';

    return Container(
      width: _kSidebarWidth,
      decoration: const BoxDecoration(color: _kBgCard, border: Border(right: BorderSide(color: _kBorder))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Brand
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 10, 14),
          child: Row(children: [
            Image.asset(
              'assets/logo/gmwf-1.webp',
              width: 32,
              height: 32,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            const Expanded(child: Text('Finance & HR',
                style: TextStyle(color: _kTextPrimary, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: -0.3))),
          ]),
        ),

        // Branch picker
        if (branches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: isBranchManager
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline, size: 12, color: _kTextSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            branches.firstWhereOrNull((b) => b['id'] == activeBranchId)?['name'] ?? activeBranchId,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _kTextPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
                    child: Builder(
                      builder: (context) {
                        final uniqueBranches = <String, Map<String, dynamic>>{};
                        for (final b in branches) {
                          final id = b['id']?.toString().trim() ?? '';
                          if (id.isNotEmpty && id.toLowerCase() != 'all') {
                            uniqueBranches[id] = b;
                          }
                        }
                        final branchItems = [
                          const DropdownMenuItem<String>(value: 'all', child: Text('All Branches', style: TextStyle(fontSize: 11))),
                          ...uniqueBranches.values.map((b) {
                            final bId = b['id']?.toString() ?? '';
                            return DropdownMenuItem<String>(
                              value: bId,
                              child: Text('${b['name']} ($bId)', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                            );
                          }),
                        ];
                        final safeBranchValue = branchItems.any((it) => it.value == activeBranchId) ? activeBranchId : 'all';

                        return DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: safeBranchValue,
                            dropdownColor: _kBgCard,
                            isExpanded: true,
                            style: const TextStyle(color: _kTextPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: _kTextSecondary),
                            items: branchItems,
                            onChanged: (v) { if (v != null) onBranchChanged(v); },
                          ),
                        );
                      },
                    ),
                  ),
          ),

        const Divider(height: 1, color: _kBorder),
        const SizedBox(height: 6),

        // Nav items
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (int i = 0; i < _labels.length; i++) _navItem(i),
              const SizedBox(height: 10),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider(height: 1, color: _kBorder)),
              const SizedBox(height: 6),
              if (canViewAudits) ...[
                _actionItem(Icons.calendar_month_outlined, 'Holidays', onHolidays),
                _actionItem(Icons.download_outlined, 'Export Reports', onExport),
              ],
              _actionItem(isDownloading ? Icons.sync_rounded : Icons.refresh_rounded,
                  isDownloading ? 'Refreshing...' : 'Force Refresh', onRefresh),
            ]),
          ),
        ),

        // Sync chip
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: _syncChip(),
        ),

        const Divider(height: 1, color: _kBorder),

        // User card
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: _kAccentMuted,
              child: Text(userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                  style: const TextStyle(color: _kAccent, fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(userName, style: const TextStyle(color: _kTextPrimary, fontWeight: FontWeight.w700, fontSize: 12), overflow: TextOverflow.ellipsis),
              Text(userRoleDisplay, style: const TextStyle(color: _kTextTertiary, fontSize: 10), overflow: TextOverflow.ellipsis),
            ])),
          ]),
        ),
      ]),
    );
  }

  Widget _navItem(int i) {
    final sel = selectedIndex == i;
    return GestureDetector(
      onTap: () => onSelect(i),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFFECFDF5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(sel ? _iconsA[i] : _icons[i], size: 18, color: sel ? _kAccent : _kTextSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(_labels[i],
              style: TextStyle(color: sel ? _kAccent : _kTextSecondary, fontSize: 13,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500))),
          if (sel) Container(width: 6, height: 6, decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle)),
        ]),
      ),
    );
  }

  Widget _actionItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 16, color: _kTextTertiary),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: _kTextTertiary, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _syncChip() {
    if (pendingSyncCount > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
          const SizedBox(width: 8),
          Expanded(child: Text('Syncing $pendingSyncCount...', style: const TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold))),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF6EE7B7)),
      ),
      child: const Row(children: [
        Icon(Icons.check_circle_outline_rounded, color: _kAccent, size: 12),
        SizedBox(width: 6),
        Text('✓ Synced', style: TextStyle(color: _kAccent, fontSize: 10, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Standalone Finance Module Wrappers (Without Sidebar)
// ─────────────────────────────────────────────────────────────────────────────

class CashFlowPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  final int initialSubTab;
  const CashFlowPage({super.key, required this.branchId, this.isAdmin = false, this.initialSubTab = 0});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: initialSubTab == 1 ? 6 : 0);
  }
}

class EmployeesPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const EmployeesPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 1);
  }
}

class EmployeeAttendancePage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const EmployeeAttendancePage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 1);
  }
}

class EmployeeManagementPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const EmployeeManagementPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 1);
  }
}

class PayrollPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const PayrollPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 3);
  }
}

class LoansPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const LoansPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 4);
  }
}

class ExpensesPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const ExpensesPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 5);
  }
}

class FinanceReportsPage extends StatelessWidget {
  final String branchId;
  final bool isAdmin;
  const FinanceReportsPage({super.key, required this.branchId, this.isAdmin = false});

  @override
  Widget build(BuildContext context) {
    return FinancePage(branchId: branchId, isAdmin: isAdmin, initialTabIndex: 7);
  }
}
