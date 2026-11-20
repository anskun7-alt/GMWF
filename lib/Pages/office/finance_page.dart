// lib/pages/office/finance_page.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:gmwf/design/design_system.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../services/permission_service.dart';
import '../../services/finance_local_storage.dart';
import '../../services/finance_loans_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/sync_service.dart';
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
const _kAccent     = SoftPalette.emerald500;
const _kBg         = SoftPalette.gray50;
const _kBgCard     = SoftPalette.gray50;
const _kBorder     = SoftPalette.slate100;
const _kTextPrimary   = SoftPalette.slate900;
const _kTextSecondary = SoftPalette.slate550;
const _kTextTertiary  = SoftPalette.slate350;
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
  void didUpdateWidget(covariant FinancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The app shell's sidebar switches sections by passing a new tab index;
    // keep the loaded data and just change the section.
    if (widget.initialTabIndex != oldWidget.initialTabIndex) {
      setState(() => _selectedIndex = widget.initialTabIndex.clamp(0, 7));
    }
  }

  @override
  void initState() {
    super.initState();
    _activeBranchId = _getEffectiveUserBranch();
    _selectedIndex = widget.initialTabIndex.clamp(0, 7);
    FinanceLocalStorage.ensureBoxesOpen().then((_) {
      if (mounted) setState(() {});
    });
    if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
      _syncBox = Hive.box(LocalStorageService.syncBox);
      _updateSyncCount();
      _syncListenable = DebouncedBoxListenable.shared(_syncBox)..addListener(_updateSyncCount);
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox).then((box) {
        if (!mounted) return;
        _syncBox = box;
        _updateSyncCount();
        _syncListenable = DebouncedBoxListenable.shared(_syncBox)..addListener(_updateSyncCount);
      });
    }
    FinanceLedgerStorage.initEngine();
    _loadBranches();
  }

  // Kept so dispose() removes the listener from the same listenable (a fresh one removed
  // nothing, and every sync-queue write kept calling into this disposed page).
  ValueListenable<Box>? _syncListenable;

  @override
  void dispose() {
    try {
      _syncListenable?.removeListener(_updateSyncCount);
      _syncListenable = null;
    } catch (_) {}
    super.dispose();
  }

  void _updateSyncCount() {
    if (!mounted) return;
    final pending = _syncBox.values.where((v) =>
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

      final conflicts = Hive.isBoxOpen(LocalStorageService.financeSettingsBox)
          ? Hive.box(LocalStorageService.financeSettingsBox).get('sync_conflicts') as List?
          : null;
    final hasConflicts = conflicts != null && conflicts.isNotEmpty;
    // Rebuild the whole Finance page only when the badge really changes.
    if (pending == _pendingSyncCount && hasConflicts == _hasConflicts) return;
    setState(() {
      _pendingSyncCount = pending;
      _hasConflicts = hasConflicts;
    });
  }

  Future<void> _loadBranches() async {
    setState(() => _isLoadingBranches = true);
    final userRole = LocalStorageService.getActiveUserRole();
    final isBranchScoped = userRole == 'branch manager' || userRole == 'supervisor';

    // 1. Load 100% locally from Hive first using FinanceLocalStorage.getAllKnownBranches
    if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
      final known = FinanceLocalStorage.getAllKnownBranches();
      if (known.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _branches = known;
          if (isBranchScoped) {
            _activeBranchId = _getEffectiveUserBranch();
            _branches = _branches.where((b) => b['id'].toString().toLowerCase().trim() == _activeBranchId.toLowerCase().trim()).toList();
          }
          _isLoadingBranches = false;
        });
        _triggerDownloadForActiveBranch();
        return;
      }
    }

    // 2. Fallback to Firestore only if local box is empty
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      if (!mounted) return;
      final seen = <String>{};
      final firestoreBranches = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final data = d.data();
        final rawId = (data['id'] ?? d.id).toString().trim();
        final normId = rawId.toLowerCase();
        if (normId.isEmpty || normId == 'all' || normId == 'global' || seen.contains(normId)) continue;
        seen.add(normId);
        firestoreBranches.add({
          'id': normId,
          'name': (data['name'] as String?)?.trim() ?? normId,
        });
      }
      setState(() {
        _branches = firestoreBranches;
        if (isBranchScoped) {
          _activeBranchId = _getEffectiveUserBranch();
          _branches = _branches.where((b) => b['id'].toString().toLowerCase().trim() == _activeBranchId.toLowerCase().trim()).toList();
        }
        _isLoadingBranches = false;
      });
      _triggerDownloadForActiveBranch();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingBranches = false);
    }
  }

  Future<void> _triggerDownloadForActiveBranch({bool force = false}) async {
    final bId = _activeBranchId;
    if (bId.isEmpty) return;

    if (!force) {
      // 24/7 HQ Quota Protection: Serve 100% from local Hive.
      // Cloud downloads only execute when user explicitly clicks Refresh (force = true).
      final hasLocal = FinanceLocalStorage.getEmployees(bId).isNotEmpty;
      if (hasLocal) return;
    }

    setState(() => _isDownloadingData = true);
    try {
      SyncService().start(bId);
      if (force) {
        await SyncService().broadcastUniversalForceUpload(branchId: bId);
        await FinanceLocalStorage.deduplicateEmployeeRecords();
      }
      await SyncService().triggerFinanceRefresh(force: force);
      await FinanceLoansStorage.migrateLegacyAdvancesToLoans(performedBy: 'System');
      if (force && mounted) showCustomSnackBar(context, 'Universal sync broadcasted & data refreshed successfully.');
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
        backgroundColor: context.adapt(_kBg),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline_rounded, size: 64, color: SoftPalette.red400),
              const SizedBox(height: 16),
              Text('Access Restricted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.adapt(_kTextPrimary))),
              const SizedBox(height: 8),
              Text('You do not have permissions to access the Finance & HR module.',
                  style: TextStyle(fontSize: 13, color: context.adapt(_kTextSecondary)), textAlign: TextAlign.center),
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

  Widget _buildCircularActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required RoleThemeData t,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: t.bgCard,
            shape: BoxShape.circle,
            border: Border.all(color: t.bgRule),
          ),
          child: Icon(icon, color: t.textSecondary, size: 16),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext ctx, bool canViewAudits, RoleThemeData t) {
    // Inside the executive shell its header already shows the section title,
    // so only this page's own actions stay, in a slim row.
    final hosted = HomeModuleHost.isModuleRoot(ctx);
    return Container(
      padding: EdgeInsets.fromLTRB(24, hosted ? 8 : 14, 24, 6),
      child: Row(
        children: [
          if (!hosted) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF059669), // primary emerald green
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.people_alt_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _sectionTitles[_selectedIndex],
                style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.2),
              ),
              const SizedBox(height: 2),
              Text(
                'Manage and track employees across all branches and departments.',
                style: TextStyle(color: t.textSecondary, fontSize: 11.5),
              ),
            ],
          ),
          ],
          const Spacer(),
          _buildSyncChip(),
          const SizedBox(width: 10),
          _buildCircularActionButton(
            tooltip: 'Force Refresh Data',
            icon: _isDownloadingData ? Icons.sync_rounded : Icons.refresh_rounded,
            onPressed: () => _triggerDownloadForActiveBranch(force: true),
            t: t,
          ),
          const SizedBox(width: 6),
          _buildCircularActionButton(
            tooltip: 'Export Reports',
            icon: Icons.download_rounded,
            onPressed: () => _openExportDialog(ctx),
            t: t,
          ),
          const SizedBox(width: 6),
          _buildCircularActionButton(
            tooltip: 'Manage Holidays',
            icon: Icons.calendar_month_outlined,
            onPressed: () => _openHolidaysManager(ctx),
            t: t,
          ),
        ],
      ),
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
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        children: [
          const Icon(Icons.filter_alt_outlined, size: 16, color: Color(0xFF042F2E)),
          const SizedBox(width: 6),
          const Text('Filters', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 20),
          if (isBranchScoped) ...[
            Row(
              children: [
                Icon(Icons.domain_outlined, size: 15, color: t.textSecondary),
                const SizedBox(width: 6),
                Text('Branch', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                const SizedBox(width: 8),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.bgCardAlt,
                    borderRadius: BorderRadius.circular(8),
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
              ],
            ),
            const SizedBox(width: 16),
          ] else if (_isLoadingBranches) ...[
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
          ] else if (_branches.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.domain_outlined, size: 15, color: t.textSecondary),
                const SizedBox(width: 6),
                Text('Branch', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                const SizedBox(width: 8),
                Builder(
                  builder: (context) {
                    final branchItems = _getUniqueBranchDropdownItems();
                    final normActive = _activeBranchId.toLowerCase().trim();
                    final safeBranchValue = branchItems.any((it) => it.value == normActive) ? normActive : 'all';
                    return Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: t.bgCardAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: t.bgRule),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: safeBranchValue,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
                          dropdownColor: t.bgCard,
                          style: TextStyle(color: t.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                          items: branchItems,
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _activeBranchId = val.toLowerCase().trim();
                              });
                              _triggerDownloadForActiveBranch();
                            }
                          },
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(width: 16),
          ],
          Row(
            children: [
              Icon(Icons.people_outline_rounded, size: 15, color: t.textSecondary),
              const SizedBox(width: 6),
              Text('Department', style: TextStyle(fontSize: 12, color: t.textSecondary)),
              const SizedBox(width: 8),
              Builder(
                builder: (context) {
                  final deptItems = _getUniqueDepartmentDropdownItems();
                  final safeDeptValue = deptItems.any((it) => it.value == _selectedDeptFilter.toLowerCase())
                      ? _selectedDeptFilter.toLowerCase()
                      : 'all';
                  return Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: t.bgCardAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: t.bgRule),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: safeDeptValue,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
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
            ],
          ),
          const Spacer(),
          if ((!isBranchScoped && _activeBranchId != 'all') || _selectedDeptFilter != 'all')
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: SoftPalette.red400,
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
    final dedupMap = <String, DropdownMenuItem<String>>{};
    dedupMap['all'] = const DropdownMenuItem<String>(
      value: 'all',
      child: Text('All Departments', style: TextStyle(fontSize: 11)),
    );
    final defaults = ['Administration', 'Office', 'Dasterkhwaan', 'Dispensary', 'Madrassa', 'School'];
    for (final d in [...defaults, ...FinanceLocalStorage.getCustomDepartments()]) {
      final norm = FinanceLocalStorage.normalizeDepartment(d);
      final key = norm.trim().toLowerCase();
      if (key.isNotEmpty && key != 'all' && !dedupMap.containsKey(key)) {
        dedupMap[key] = DropdownMenuItem<String>(
          value: key,
          child: Text(norm, style: const TextStyle(fontSize: 11)),
        );
      }
    }
    return dedupMap.values.toList();
  }

  List<DropdownMenuItem<String>> _getUniqueBranchDropdownItems({bool includeDetails = false}) {
    final dedupMap = <String, DropdownMenuItem<String>>{};
    dedupMap['all'] = const DropdownMenuItem<String>(
      value: 'all',
      child: Text('All Branches', style: TextStyle(fontSize: 11)),
    );

    for (final b in _branches) {
      final rawId = (b['id'] ?? b['branchId'] ?? '').toString().trim();
      final normId = rawId.toLowerCase();
      if (normId.isEmpty || normId == 'all' || normId == 'global') continue;

      if (!dedupMap.containsKey(normId)) {
        final rawName = (b['name'] ?? b['branchName'] ?? rawId).toString().trim();
        final name = rawName.isNotEmpty ? rawName : normId;
        final label = includeDetails ? '$name ($rawId)' : name;
        dedupMap[normId] = DropdownMenuItem<String>(
          value: normId,
          child: Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
        );
      }
    }
    return dedupMap.values.toList();
  }

  void _showSyncStatusDialog() {
    final isOnline = _syncBox.get('last_online_state') as bool? ?? true;
    final isSyncing = _isDownloadingData || SyncService().isUploading;

    final typeCounts = <String, int>{};
    for (final v in _syncBox.values) {
      if (v is Map && v['type'] != null) {
        final t = v['type'].toString();
        typeCounts[t] = (typeCounts[t] ?? 0) + 1;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isSyncing ? Icons.sync_rounded : (isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded),
              color: isSyncing ? SoftPalette.amber300 : (isOnline ? _kAccent : SoftPalette.blue400),
            ),
            const SizedBox(width: 10),
            const Text('Sync & Cloud Status', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Connectivity: ', style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500))),
                Text(
                  isOnline ? 'Online (Connected)' : 'Offline (Local Only)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isOnline ? _kAccent : SoftPalette.blue400,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('Pipeline State: ', style: TextStyle(fontSize: 12, color: context.adapt(SoftPalette.gray500))),
                Text(
                  isSyncing ? 'Active (Uploading / Downloading)' : (_pendingSyncCount > 0 ? 'Queued (Awaiting Flush)' : 'Idle (All Synchronized)'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSyncing ? SoftPalette.amber300 : (_pendingSyncCount > 0 ? SoftPalette.orange350 : _kAccent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Pending Outbox Queue (${_syncBox.length} Total items):',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            if (typeCounts.isEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: context.adapt(SoftPalette.emerald100), borderRadius: BorderRadius.circular(8)),
                child: const Row(children: [
                  Icon(Icons.check_circle_rounded, color: _kAccent, size: 16),
                  SizedBox(width: 8),
                  Text('All local changes are fully synced to Cloud Firestore.', style: TextStyle(fontSize: 11, color: _kAccent, fontWeight: FontWeight.w600)),
                ]),
              )
            else
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(color: context.adapt(SoftPalette.gray50), borderRadius: BorderRadius.circular(8), border: Border.all(color: context.adapt(SoftPalette.slate150))),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  children: typeCounts.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(e.key.replaceAll('save_', '').replaceAll('_', ' '), style: const TextStyle(fontSize: 11.5)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: context.adapt(SoftPalette.amber200).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                          child: Text('${e.value}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange600m))),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
          ],
        ),
        actions: [
          if (_syncBox.isNotEmpty)
            TextButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Clear Stuck Queue?'),
                    content: const Text('This will dismiss pending local outbox actions that may have failed repeated retries. Live employee records in Hive will remain intact.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(c, true),
                        style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400, foregroundColor: SoftPalette.gray50),
                        child: const Text('Clear Queue'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await _syncBox.clear();
                  _updateSyncCount();
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('Clear Stuck Queue', style: TextStyle(color: SoftPalette.red400, fontSize: 12)),
            ),
          ElevatedButton.icon(
            icon: const Icon(Icons.sync_rounded, size: 14),
            label: const Text('Sync Now', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: SoftPalette.gray50),
            onPressed: () {
              Navigator.pop(ctx);
              _triggerDownloadForActiveBranch(force: true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSyncChip() {
    final isSyncing = _isDownloadingData || SyncService().isUploading;
    if (_hasConflicts) {
      return InkWell(
        onTap: _showSyncStatusDialog,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: SoftPalette.red400.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: SoftPalette.red400.withValues(alpha: 0.4)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber_rounded, color: SoftPalette.red400, size: 12),
            SizedBox(width: 4),
            Text('Needs Review', style: TextStyle(color: SoftPalette.red400, fontSize: 10, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
    }
    if (isSyncing) {
      return InkWell(
        onTap: _showSyncStatusDialog,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: SoftPalette.amber300.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: SoftPalette.amber300.withValues(alpha: 0.4)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.amber300)),
            SizedBox(width: 6),
            Text('Syncing...', style: TextStyle(color: SoftPalette.amber300, fontSize: 10, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
    }
    if (_pendingSyncCount > 0) {
      return InkWell(
        onTap: _showSyncStatusDialog,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: context.adapt(SoftPalette.amber200).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.adapt(SoftPalette.amber200).withValues(alpha: 0.5)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_upload_outlined, color: SoftPalette.amber200, size: 12),
            const SizedBox(width: 4),
            Text('$_pendingSyncCount Queued', style: TextStyle(color: SoftPalette.orange350, fontSize: 10, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
    }
    final isOnline = _syncBox.get('last_online_state') as bool? ?? true;
    return InkWell(
      onTap: _showSyncStatusDialog,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isOnline ? context.adapt(SoftPalette.emerald100) : SoftPalette.blue400.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isOnline ? context.adapt(SoftPalette.emerald200) : SoftPalette.blue400.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(isOnline ? Icons.check_circle_outline_rounded : Icons.offline_pin_outlined,
              color: isOnline ? _kAccent : SoftPalette.blue400, size: 12),
          const SizedBox(width: 4),
          Text(isOnline ? '✓ Synced' : '● Offline',
              style: TextStyle(color: isOnline ? _kAccent : SoftPalette.blue400, fontSize: 10, fontWeight: FontWeight.bold)),
        ]),
      ),
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


  Widget _buildLockedAudit() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_outline_rounded, size: 54, color: context.adapt(_kTextTertiary)),
      SizedBox(height: 14),
      Text('Access Restricted', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: context.adapt(_kTextSecondary))),
      SizedBox(height: 6),
      Text('You do not have permissions to view audit trails.',
          style: TextStyle(fontSize: 12, color: context.adapt(_kTextTertiary)), textAlign: TextAlign.center),
    ]),
  );

  // ── Dialogs ────────────────────────────────────────────────────────────────
  void _openExportDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: context.adapt(_kBgCard),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.download_outlined, color: _kAccent),
          SizedBox(width: 8),
          Text('Export Reports', style: TextStyle(color: context.adapt(_kTextPrimary), fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        content: SizedBox(
          width: 500,
          child: _exportView(dCtx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text('Close', style: TextStyle(color: context.adapt(_kTextSecondary))),
          )
        ],
      ),
    );
  }

  Widget _exportView(BuildContext dCtx) {
    String selType = 'branch_pdf', selMonth = _payrollMonthKey;
    String selDept = 'All Departments';
    String selCamp = 'All Camps';
    String selScope = 'all'; // 'all' or 'custom'
    final Set<String> selectedEmpIds = {};

    final isKarachi = _activeBranchId.toLowerCase().contains('karachi') || _activeBranchId.toLowerCase() == 'all';
    final depts = [
      'All Departments',
      ...FinanceLedgerStorage.sortDepartmentsCanonical(
        [
          'Dispensary',
          'School',
          'Madrassa',
          'Dasterkhwaan',
          'Administration',
          'Security & Maintenance',
          ...FinanceLocalStorage.getCustomDepartments(),
        ],
      ),
    ];

    return StatefulBuilder(builder: (ctx, setS) {
      final isPayroll = selType == 'branch_pdf' || selType == 'branch';

      // Load filtered staff list (Executives are automatically excluded by FinanceLocalStorage.getEmployees)
      final allStaff = isPayroll ? FinanceLocalStorage.getEmployees(_activeBranchId) : <Map<String, dynamic>>[];
      final filteredStaff = allStaff.where((emp) {
        if (selDept != 'All Departments') {
          final d1 = FinanceLocalStorage.normalizeDepartment(emp['department']?.toString());
          final d2 = FinanceLocalStorage.normalizeDepartment(selDept);
          if (d1.toLowerCase() != d2.toLowerCase()) return false;
        }
        if (selCamp != 'All Camps') {
          if (!FinanceLocalStorage.isEmployeeInCamp(emp, selCamp)) return false;
        }
        return true;
      }).toList();

      return SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 8),
          Text('Report Type:', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            dropdownColor: context.adapt(_kBgCard), value: selType,
            style: TextStyle(color: context.adapt(_kTextPrimary), fontSize: 13),
            decoration: InputDecoration(
              filled: true, fillColor: context.adapt(_kBg),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
            ),
            items: const [
              DropdownMenuItem(value: 'branch_pdf', child: Text('Bank Transfer Slip (PDF)')),
              DropdownMenuItem(value: 'branch', child: Text('Salary Sheet (Excel)')),
              DropdownMenuItem(value: 'consolidated', child: Text('All Branches Consolidated Excel')),
              DropdownMenuItem(value: 'expenses_excel', child: Text('Daily Expenses Log Excel')),
            ],
            onChanged: (v) { if (v != null) setS(() => selType = v); },
          ),
          if (isPayroll) ...[
            const SizedBox(height: 12),
            Text('Department:', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              dropdownColor: context.adapt(_kBgCard), value: selDept,
              decoration: InputDecoration(
                filled: true, fillColor: context.adapt(_kBg),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
              ),
              style: TextStyle(color: context.adapt(_kTextPrimary), fontSize: 13),
              items: depts.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
              onChanged: (v) {
                if (v != null) {
                  setS(() {
                    selDept = v;
                    selectedEmpIds.clear();
                  });
                }
              },
            ),
            if (isKarachi) ...[
              const SizedBox(height: 12),
              Text('Camp / Location:', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                dropdownColor: context.adapt(_kBgCard), value: selCamp,
                decoration: InputDecoration(
                  filled: true, fillColor: context.adapt(_kBg),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
                ),
                style: TextStyle(color: context.adapt(_kTextPrimary), fontSize: 13),
                items: const [
                  DropdownMenuItem(value: 'All Camps', child: Text('All Camps / Main Branch')),
                  DropdownMenuItem(value: 'Haji Camp', child: Text('Haji Camp Dispensary')),
                  DropdownMenuItem(value: 'Saddar Camp', child: Text('Saddar Camp Dispensary')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setS(() {
                      selCamp = v;
                      selectedEmpIds.clear();
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 12),
            Text('Staff Members Scope:', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: Center(child: Text('All Matching Staff (${filteredStaff.length})')),
                    selected: selScope == 'all',
                    selectedColor: _kAccent.withOpacity(0.18),
                    onSelected: (_) => setS(() => selScope = 'all'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: Center(child: Text('Specific People (${selectedEmpIds.length})')),
                    selected: selScope == 'custom',
                    selectedColor: _kAccent.withOpacity(0.18),
                    onSelected: (_) => setS(() => selScope = 'custom'),
                  ),
                ),
              ],
            ),
            if (selScope == 'custom') ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Select people to export:', style: TextStyle(fontSize: 11, color: context.adapt(_kTextSecondary), fontWeight: FontWeight.w600)),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setS(() {
                            selectedEmpIds.clear();
                            selectedEmpIds.addAll(filteredStaff.map((e) => e['localId'].toString()));
                          });
                        },
                        child: const Text('Select All', style: TextStyle(fontSize: 11, color: _kAccent)),
                      ),
                      TextButton(
                        onPressed: () => setS(() => selectedEmpIds.clear()),
                        child: Text('Clear', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray350))),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: context.adapt(_kBg),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.adapt(_kBorder)),
                ),
                child: filteredStaff.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: Text('No employees found matching filter', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12))),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filteredStaff.length,
                        itemBuilder: (c, idx) {
                          final emp = filteredStaff[idx];
                          final id = emp['localId'].toString();
                          final name = emp['name']?.toString() ?? 'Staff';
                          final role = emp['role']?.toString() ?? '';
                          final dept = emp['department']?.toString() ?? '';
                          final camp = FinanceLocalStorage.getEmployeeCampDisplay(emp);
                          final isChecked = selectedEmpIds.contains(id);

                          return CheckboxListTile(
                            dense: true,
                            value: isChecked,
                            activeColor: _kAccent,
                            title: Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            subtitle: Text(
                              '$role • $dept${camp.isNotEmpty ? ' [$camp]' : ''}',
                              style: TextStyle(fontSize: 10, color: context.adapt(_kTextSecondary)),
                            ),
                            onChanged: (chk) {
                              setS(() {
                                if (chk == true) {
                                  selectedEmpIds.add(id);
                                } else {
                                  selectedEmpIds.remove(id);
                                }
                              });
                            },
                          );
                        },
                      ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Text('Month:', style: TextStyle(color: context.adapt(_kTextSecondary), fontSize: 12, fontWeight: FontWeight.bold)),
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
                decoration: BoxDecoration(border: Border.all(color: context.adapt(_kBorder)), borderRadius: BorderRadius.circular(8)),
                child: Text(DateFormat('MMMM yyyy').format(DateFormat('yyyy-MM').parse(selMonth)),
                    style: TextStyle(color: context.adapt(_kTextPrimary), fontWeight: FontWeight.bold, fontSize: 13)),
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
              style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: SoftPalette.gray50),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export Now', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () async {
                Navigator.pop(dCtx);
                final dParam = selDept == 'All Departments' ? null : selDept;
                final cParam = selCamp == 'All Camps' ? null : selCamp;
                final pParam = selScope == 'custom' ? selectedEmpIds.toList() : null;

                if (selType == 'branch') {
                  await FinanceReportHelper.exportMonthlyExcel(
                    branchId: _activeBranchId,
                    monthKey: selMonth,
                    department: dParam,
                    camp: cParam,
                    employeeIds: pParam,
                    context: context,
                  );
                } else if (selType == 'branch_pdf') {
                  await FinanceReportHelper.exportMonthlyPdf(
                    branchId: _activeBranchId,
                    monthKey: selMonth,
                    department: dParam,
                    camp: cParam,
                    employeeIds: pParam,
                    context: context,
                  );
                } else if (selType == 'consolidated') {
                  await FinanceReportHelper.exportConsolidatedAllBranchesExcel(
                    branches: _branches,
                    monthKey: selMonth,
                    context: context,
                  );
                } else if (selType == 'expenses_excel') {
                  await FinanceReportHelper.exportExpensesExcel(
                    branchId: _activeBranchId,
                    monthKey: selMonth,
                    context: context,
                  );
                }
              },
            ),
          ),
        ]),
      );
    });
  }

  void _openHolidaysManager(BuildContext ctx) {
    final userRole = LocalStorageService.getActiveUserRole();
    HolidayManagerDialog.open(
      context: ctx,
      branchId: _activeBranchId,
      branches: _branches,
      userRole: userRole,
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
