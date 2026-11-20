// lib/pages/school/school_dashboard.dart

import 'package:flutter/material.dart';
import 'views/school_daily_attendance_view.dart';
import 'views/school_teacher_attendance_view.dart';
import 'views/school_student_management_view.dart';
import 'views/school_teacher_management_view.dart';
import 'views/school_library_view.dart';
import 'views/school_audit_log_view.dart';
import 'views/school_grading_view.dart';
import 'views/school_fee_management_view.dart';
import 'views/school_erp_dashboard_view.dart';
import 'core/school_roles.dart';
import 'utils/school_local_storage.dart';
import 'utils/school_sync_service.dart';
import '../../widgets/global_module_wrapper.dart';
import '../../widgets/app_back_button.dart';
import '../../services/local_storage_service.dart';
import '../../services/auth_service.dart';
import '../settings_page.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'theme/school_theme_scope.dart';
import 'widgets/urdu_phonetic_scope.dart';
import 'core/school_branch_id.dart';
import 'core/school_branches.dart';

/// Sidebar groups, in the order they appear (ERP layout, 2026-11-17).
const _groups = ['Overview', 'Academics', 'Staff', 'Finance', 'Library', 'Administration'];

class _NavItem {
  final String label;
  final IconData icon;
  final String group;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.group,
  });
}

class SchoolDashboard extends StatefulWidget {
  final String branchId;
  final String username;
  final String role;
  final int initialTabIndex;
  final bool? hideNavigation;

  const SchoolDashboard({
    super.key,
    this.branchId = 'all',
    this.username = 'User',
    this.role = 'School Admin',
    this.initialTabIndex = 0,
    this.hideNavigation,
  });

  @override
  State<SchoolDashboard> createState() => _SchoolDashboardState();
}

class _SchoolDashboardState extends State<SchoolDashboard> {
  int _selectedIndex = 0;
  List<_NavItem> _navItems = [];
  List<Widget> _views = [];

  /// The one School role rule (core/school_roles.dart).
  SchoolRole get _role => SchoolRoles.resolve(widget.role);
  bool get _isTeacher => _role == SchoolRole.teacher;
  bool get _isManager => SchoolRoles.isManager(_role);

  /// The pages this role may open, in sidebar order.
  List<SchoolPage> _pages = const [];

  /// The app's section index (executive order = SchoolPage order) → this role's page index.
  int _indexForSection(int section) {
    final want = SchoolPage.values[section.clamp(0, SchoolPage.values.length - 1)];
    final i = _pages.indexOf(want);
    return i < 0 ? 0 : i;
  }
  /// HQ / executive login (branch "all"): they pick which school branch to work in.
  bool get _isHq => SchoolBranchId.isAll(widget.branchId);
  String? _hqBranch;

  String get _effectiveBranchId {
    if (_isHq) return _hqBranch ??= SchoolBranches.hqChoice();
    final b = widget.branchId.trim().toLowerCase();
    if (!LocalStorageService.hasSchoolFacility(b) && !_isManager && !_isTeacher) {
      return SchoolBranches.fallback;
    }
    return b;
  }

  Future<void> _switchBranch(String branch) async {
    if (branch == _hqBranch) return;
    await SchoolBranches.setHqChoice(branch);
    if (!mounted) return;
    setState(() {
      _hqBranch = branch;
      _initNavItemsAndViews();
    });
    SchoolSyncService().syncNow(branchId: branch);
  }

  Widget _branchPicker(BuildContext context) {
    final options = SchoolBranches.withSchool();
    final current = _effectiveBranchId;
    return PopupMenuButton<String>(
      tooltip: 'Choose school branch',
      initialValue: current,
      onSelected: _switchBranch,
      itemBuilder: (_) => [
        for (final b in options)
          PopupMenuItem(value: b, child: Text(LocalStorageService.getBranchName(b))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gsp.sp1, vertical: Gsp.sp2),
        child: AppChip(
          label: 'Branch: ${LocalStorageService.getBranchName(current)}',
          icon: GIcons.branch,
          state: AppChipState.info,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    SchoolLocalStorage.ensureBoxesOpen();
    SchoolSyncService().init();
    SchoolSyncService().syncNow(branchId: _effectiveBranchId);
    _initNavItemsAndViews();
    _selectedIndex = _indexForSection(widget.initialTabIndex);
  }

  @override
  void didUpdateWidget(covariant SchoolDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role != widget.role ||
        oldWidget.branchId != widget.branchId ||
        oldWidget.username != widget.username ||
        oldWidget.initialTabIndex != widget.initialTabIndex) {
      if (oldWidget.branchId != widget.branchId) _hqBranch = null;
      _initNavItemsAndViews();
      _selectedIndex = _indexForSection(widget.initialTabIndex);
    }
  }

  /// Builds the sidebar and screens for this role from one table: every role
  /// sees the same pages in the same order, minus what it may not open.
  void _initNavItemsAndViews() {
    final b = _effectiveBranchId;
    final u = widget.username;
    final r = widget.role;
    _pages = SchoolRoles.pagesFor(_role);
    final table = <SchoolPage, (_NavItem, Widget Function())>{
      SchoolPage.dashboard: (
        const _NavItem(label: 'Dashboard', icon: GIcons.dashboard, group: 'Overview'),
        () => SchoolErpDashboardView(branchId: b, userName: u, userRole: r),
      ),
      SchoolPage.students: (
        _NavItem(label: _isTeacher ? 'My class' : 'Students', icon: GIcons.student, group: 'Academics'),
        () => SchoolStudentManagementView(branchId: b, userRole: r, userName: u),
      ),
      SchoolPage.dailyLog: (
        const _NavItem(label: 'Daily log', icon: GIcons.attendance, group: 'Academics'),
        () => SchoolDailyAttendanceView(branchId: b, editorName: u, userRole: r),
      ),
      SchoolPage.grades: (
        const _NavItem(label: 'Grades & reports', icon: GIcons.exam, group: 'Academics'),
        () => SchoolGradingView(branchId: b, userRole: r, userName: u),
      ),
      SchoolPage.staffAttendance: (
        const _NavItem(label: 'Staff attendance', icon: GIcons.fingerprint, group: 'Staff'),
        () => SchoolTeacherAttendanceView(branchId: b, editorName: u, userRole: r),
      ),
      SchoolPage.teachers: (
        const _NavItem(label: 'Teachers', icon: GIcons.teacher, group: 'Staff'),
        () => SchoolTeacherManagementView(branchId: b, userRole: r, userName: u),
      ),
      SchoolPage.fees: (
        const _NavItem(label: 'Fees', icon: GIcons.fees, group: 'Finance'),
        () => SchoolFeeManagementView(branchId: b, userName: u, userRole: r),
      ),
      SchoolPage.library: (
        const _NavItem(label: 'Library', icon: GIcons.library, group: 'Library'),
        () => SchoolLibraryView(branchId: b, userName: u, userRole: r),
      ),
      SchoolPage.audit: (
        const _NavItem(label: 'Audit log', icon: GIcons.audit, group: 'Administration'),
        () => SchoolAuditLogView(branchId: b, userRole: r),
      ),
    };
    _navItems = [for (final p in _pages) table[p]!.$1];
    _views = [for (final p in _pages) table[p]!.$2()];
  }
  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = ctx.comfort;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: Gr.modal),
          title: Row(
            children: [
              Icon(GIcons.logout, color: c.danger),
              const SizedBox(width: Gsp.sp2 + 2),
              Text('Sign Out', style: GText.h3(c.textPrimary)),
            ],
          ),
          content: Text('Are you sure you want to sign out from the School System?', style: GText.body2(c.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: c.onBrand),
              child: const Text('Sign Out'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      try {
        await AuthService().signOut();
      } catch (e) {
        debugPrint('[SchoolDashboard] Sign out error: $e');
      }
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_role == SchoolRole.none) {
      return SchoolThemeScope(
        role: widget.role,
        child: Scaffold(
          appBar: AppBar(leading: const AppBackButton(), title: const Text('School')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AppEmptyState(
                icon: GIcons.lock,
                title: "You don't have access to School",
                subtitle: 'Your role ("${widget.role}") is not a School role. School is open to the Principal, '
                    'School admin, Accountant, Librarian, Teachers and head office. Ask system administration to set your role.',
              ),
            ),
          ),
        ),
      );
    }

    final hasSchool = LocalStorageService.hasSchoolFacility(_effectiveBranchId);
    if (!hasSchool && !_isManager && !_isTeacher) {
      final bName = LocalStorageService.getBranchName(_effectiveBranchId);
      return SchoolThemeScope(
        role: widget.role,
        child: Scaffold(
          appBar: AppBar(leading: const AppBackButton(), title: const Text('School')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AppEmptyState(
                icon: GIcons.student,
                title: 'School is not available in $bName yet',
                subtitle: 'The school facility is not registered for the $bName branch. '
                    'Ask system administration to turn it on in Branches Management.',
                action: FilledButton.icon(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(GIcons.back),
                  label: const Text('Back to dashboard'),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (_navItems.isEmpty) {
      _initNavItemsAndViews();
    }

    // ── DASHBOARD NAVIGATION RULE ──────────────────────────────────────────
    // Inside the modular dashboard only the selected screen shows (no School nav).
    // Standalone (direct login), every role gets the shared gmwf_ui AppShell:
    // full sidebar on desktop, rail on tablet, drawer on phone. The role decides
    // which items appear, never the layout (gmwf_ui MODULE_DESIGN_PLAN §2).
    final isWrapped = GlobalModuleWrapper.isWrapped(context) || widget.hideNavigation == true;
    final safeIndex = _selectedIndex.clamp(0, _views.isNotEmpty ? _views.length - 1 : 0);

    // Views are keyed by branch so switching branch (HQ) starts them fresh.
    final branchKey = ValueKey('school-branch-$_effectiveBranchId');

    if (isWrapped) {
      return SchoolThemeScope(
        role: widget.role,
        child: UrduPhoneticScope(child: Builder(
          builder: (context) => Scaffold(
            backgroundColor: context.comfort.background,
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_isHq)
                Container(
                  color: context.comfort.surface,
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4),
                  child: Row(children: [
                    Text('Head office view', style: GText.caption(context.comfort.textMuted)),
                    const Spacer(),
                    _branchPicker(context),
                  ]),
                ),
              Expanded(
                child: KeyedSubtree(
                  key: branchKey,
                  child: _views.isNotEmpty ? _views[safeIndex] : const SizedBox.shrink(),
                ),
              ),
            ]),
          ),
        )),
      );
    }

    return SchoolThemeScope(
      role: widget.role,
      child: UrduPhoneticScope(child: AppShell(
        header: AppSidebarHeader(
          brand: GBrand.gmwf,
          title: 'Taleem o Tarbiyat',
          subtitle: 'School · ${LocalStorageService.getBranchName(_effectiveBranchId)}',
        ),
        items: [
          // Grouped like an ERP menu; ids keep the tab index so deep links still work.
          for (final g in _groups)
            if (_navItems.any((n) => n.group == g)) ...[
              GNavItem.section(g),
              for (var i = 0; i < _navItems.length; i++)
                if (_navItems[i].group == g) GNavItem(id: 'school/$i', label: _navItems[i].label, icon: _navItems[i].icon),
            ],
        ],
        selectedId: 'school/$safeIndex',
        onSelect: (id) {
          final i = int.tryParse(id.split('/').last);
          if (i != null) setState(() => _selectedIndex = i);
        },
        actions: [
          if (_isHq) _branchPicker(context),
          _SchoolSyncBadge(branchId: _effectiveBranchId),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(GIcons.settings),
            onPressed: () {
              final uData = LocalStorageService.getActiveUserData();
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(userData: Map<String, dynamic>.from(uData))),
              );
            },
          ),
          IconButton(tooltip: 'Sign out', icon: const Icon(GIcons.logout), onPressed: _logout),
        ],
        body: KeyedSubtree(key: branchKey, child: IndexedStack(index: safeIndex, children: _views)),
      )),
    );
  }
}

class _SchoolSyncBadge extends StatelessWidget {
  final String branchId;

  const _SchoolSyncBadge({required this.branchId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SchoolSyncStatus>(
      stream: SchoolSyncService().statusStream,
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null) return const SizedBox.shrink();
        final c = context.comfort;

        final (Color color, String text, IconData icon) = switch (status.state) {
          SchoolSyncState.synced => (c.success, 'Synced', GIcons.checkCircle),
          SchoolSyncState.syncing => (c.warning, 'Syncing…', GIcons.sync),
          SchoolSyncState.failed => (c.danger, 'Sync failed (${status.failedCount})', GIcons.syncProblem),
          SchoolSyncState.offlinePending => (
              status.isOnline ? c.warning : c.textMuted,
              status.pendingCount > 0 ? '${status.pendingCount} waiting to upload' : 'Offline',
              GIcons.cloudOff,
            ),
        };

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gsp.sp1, vertical: Gsp.sp2),
          child: Tooltip(
            message: 'Sync School data now',
            child: AppChip(
              label: text,
              icon: icon,
              state: AppChipState.custom,
              color: color,
              onTap: () => SchoolSyncService().syncNow(branchId: branchId),
            ),
          ),
        );
      },
    );
  }
}