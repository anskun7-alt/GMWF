// lib/pages/school/school_dashboard.dart

import 'package:flutter/material.dart';
import 'views/school_overview_view.dart';
import 'views/school_daily_attendance_view.dart';
import 'views/school_teacher_attendance_view.dart';
import 'views/school_student_management_view.dart';
import 'views/school_teacher_management_view.dart';
import 'views/school_library_view.dart';
import 'views/school_audit_log_view.dart';
import 'views/school_grading_view.dart';
import 'views/school_fee_management_view.dart';
import 'views/school_principal_dashboard_view.dart';
import 'theme/school_theme.dart';
import 'utils/school_local_storage.dart';
import 'utils/school_sync_service.dart';
import 'utils/school_auth_helper.dart';
import '../../widgets/global_module_wrapper.dart';
import '../../widgets/app_back_button.dart';
import '../../services/local_storage_service.dart';
import '../../services/auth_service.dart';
import '../settings_page.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../design/design_system.dart';
import 'package:motion_tab_bar_v2/motion-tab-bar.dart';
import 'package:motion_tab_bar_v2/motion-tab-controller.dart';

class _NavItem {
  final String label;
  final IconData icon;

  const _NavItem({
    required this.label,
    required this.icon,
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

class _SchoolDashboardState extends State<SchoolDashboard> with TickerProviderStateMixin {
  int _selectedIndex = 0;
  List<_NavItem> _navItems = [];
  List<Widget> _views = [];
  bool _isCollapsed = false;
  MotionTabBarController? _motionTabController;

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.role);
  bool get _isHighestAuthority => SchoolAuthHelper.isHighestAuthority(widget.role);
  bool get _isAdminOrPrincipal => SchoolAuthHelper.isAdminOrPrincipal(widget.role);

  bool get _isPrincipal {
    final r = widget.role.toLowerCase().trim();
    return r.contains('principal') ||
        r == 'headmaster' ||
        r == 'headmistress' ||
        r.contains('headmaster') ||
        r.contains('headmistress');
  }

  String get _effectiveBranchId {
    final b = widget.branchId.trim().toLowerCase();
    if (b.isNotEmpty && b != 'all' && b != 'global') {
      if (!LocalStorageService.hasSchoolFacility(b) && !_isAdminOrPrincipal && !_isTeacher) {
        return 'gujrat';
      }
      return b;
    }
    return 'gujrat';
  }

  @override
  void initState() {
    super.initState();
    SchoolLocalStorage.ensureBoxesOpen();
    SchoolSyncService().init();
    _initNavItemsAndViews();
    _selectedIndex = widget.initialTabIndex.clamp(0, _navItems.isNotEmpty ? _navItems.length - 1 : 0);
  }

  @override
  void didUpdateWidget(covariant SchoolDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role != widget.role ||
        oldWidget.branchId != widget.branchId ||
        oldWidget.username != widget.username ||
        oldWidget.initialTabIndex != widget.initialTabIndex) {
      _initNavItemsAndViews();
      _selectedIndex = widget.initialTabIndex.clamp(0, _navItems.isNotEmpty ? _navItems.length - 1 : 0);
    }
  }

  void _initNavItemsAndViews() {
    if (_isTeacher) {
      // ── Teachers only see their assigned educational operations ──────────
      // One teacher CANNOT see another teacher's profile/attendance or Admin/Principal data.
      _navItems = const [
        _NavItem(label: 'Daily Attendance', icon: Icons.how_to_reg_rounded),
        _NavItem(label: 'Grading & Reports', icon: Icons.grade_rounded),
        _NavItem(label: 'Class Students Roster', icon: Icons.groups_rounded),
        _NavItem(label: 'School Library', icon: Icons.local_library_rounded),
      ];
      _views = [
        SchoolDailyAttendanceView(
          branchId: _effectiveBranchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolGradingView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolStudentManagementView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolLibraryView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
      ];
    } else if (_isPrincipal) {
      // ── Principal Executive School View ──────────────────────────────────
      _navItems = const [
        _NavItem(label: 'Principal Dashboard', icon: Icons.dashboard_rounded),
        _NavItem(label: 'Student Directory', icon: Icons.groups_rounded),
        _NavItem(label: 'Daily Attendance', icon: Icons.how_to_reg_rounded),
        _NavItem(label: 'Faculty Attendance', icon: Icons.co_present_rounded),
        _NavItem(label: 'Faculty Registry', icon: Icons.record_voice_over_rounded),
        _NavItem(label: 'Fee Management', icon: Icons.payments_rounded),
        _NavItem(label: 'School Library', icon: Icons.local_library_rounded),
        _NavItem(label: 'Grading & Reports', icon: Icons.grade_rounded),
        _NavItem(label: 'Audit Trail', icon: Icons.security_rounded),
      ];
      _views = [
        SchoolPrincipalDashboardView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolStudentManagementView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolDailyAttendanceView(
          branchId: _effectiveBranchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherAttendanceView(
          branchId: _effectiveBranchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherManagementView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolFeeManagementView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolLibraryView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolGradingView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolAuditLogView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
        ),
      ];
    } else {
      // ── Admin, HQ Manager, and Chairman (Highest Authority) ──────────────
      _navItems = const [
        _NavItem(label: 'Overview', icon: Icons.analytics_rounded),
        _NavItem(label: 'Student Admissions', icon: Icons.groups_rounded),
        _NavItem(label: 'Student Attendance', icon: Icons.how_to_reg_rounded),
        _NavItem(label: 'Faculty Attendance', icon: Icons.co_present_rounded),
        _NavItem(label: 'Faculty Registry', icon: Icons.record_voice_over_rounded),
        _NavItem(label: 'Fee Management', icon: Icons.payments_rounded),
        _NavItem(label: 'School Library', icon: Icons.local_library_rounded),
        _NavItem(label: 'Grading & Reports', icon: Icons.grade_rounded),
        _NavItem(label: 'Audit Trail', icon: Icons.security_rounded),
      ];
      _views = [
        SchoolOverviewView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
        ),
        SchoolStudentManagementView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolDailyAttendanceView(
          branchId: _effectiveBranchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherAttendanceView(
          branchId: _effectiveBranchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherManagementView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolFeeManagementView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolLibraryView(
          branchId: _effectiveBranchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolGradingView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolAuditLogView(
          branchId: _effectiveBranchId,
          userRole: widget.role,
        ),
      ];
    }

    if (_navItems.length <= 5) {
      _motionTabController?.dispose();
      _motionTabController = MotionTabBarController(
        initialIndex: _selectedIndex.clamp(0, _navItems.length - 1),
        length: _navItems.length,
        vsync: this,
      );
    }
  }

  @override
  void dispose() {
    _motionTabController?.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.logout_rounded, color: SchoolTheme.statusAbsent),
            SizedBox(width: 10),
            Text('Sign Out'),
          ],
        ),
        content: const Text('Are you sure you want to sign out from the School System?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: SchoolTheme.statusAbsent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
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
    final hasSchool = LocalStorageService.hasSchoolFacility(_effectiveBranchId);
    if (!hasSchool && !_isAdminOrPrincipal && !_isTeacher && !_isHighestAuthority) {
      final bName = LocalStorageService.getBranchName(_effectiveBranchId);
      return Scaffold(
        backgroundColor: SchoolTheme.bgLight,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: const AppBackButton(),
          title: const Text('School Module', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ),
        body: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: SchoolTheme.borderLight),
              boxShadow: SchoolTheme.cardShadow,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: SchoolTheme.primaryLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.school_outlined, size: 42, color: SchoolTheme.primary),
                ),
                const SizedBox(height: 24),
                Text(
                  'School is not available in $bName yet',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: SchoolTheme.textDark,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'The school facility is not registered for the $bName branch. Contact system administration to configure it in Branches Management.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: SchoolTheme.textMuted, height: 1.5),
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Return to Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SchoolTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_navItems.isEmpty) {
      _initNavItemsAndViews();
    }

    final t = RoleThemeScope.dataOf(context);

    // ── DASHBOARD NAVIGATION RULE ──────────────────────────────────────────
    // "in the dashboard we will only see the selected screen without the sidebar
    // but the admin and principal and the teacher will see the sidebar on the desktop
    // and bottom navbar on mobile"
    final isWrapped = GlobalModuleWrapper.isWrapped(context) || widget.hideNavigation == true;
    final isMobile = GBreakpoint.isMobile(context);
    final isSmallScreen = GBreakpoint.isCompact(context);
    final effectiveCollapsed = _isCollapsed || isSmallScreen;

    // When wrapped inside the modular dashboard:
    // Render ONLY the selected screen without sidebar and without bottom navbar!
    if (isWrapped) {
      final safeIndex = _selectedIndex.clamp(0, _views.isNotEmpty ? _views.length - 1 : 0);
      return Scaffold(
        backgroundColor: t.bg,
        body: _views.isNotEmpty ? _views[safeIndex] : const SizedBox.shrink(),
      );
    }

    // Standalone School Mode (direct login / routing):
    // Admin, Principal, and Teacher see:
    // - On Desktop: Modern School Sidebar
    // - On Mobile: Modern School Bottom Navbar
    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildTopAppBar(context, t),
      drawer: null,
      bottomNavigationBar: isMobile ? _buildBottomNavigationBar(t) : null,
      body: Row(
        children: [
          // Sidebar Navigation (Desktop only, for all authorized roles)
          if (!isMobile) _buildSidebar(effectiveCollapsed, t),

          // Main View Content Area
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: _views,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavigationBar(RoleThemeData t) {
    if (_navItems.length <= 5 && _motionTabController != null) {
      return MotionTabBar(
        controller: _motionTabController,
        initialSelectedTab: _navItems[_selectedIndex.clamp(0, _navItems.length - 1)].label,
        labels: _navItems.map((n) => n.label).toList(),
        icons: _navItems.map((n) => n.icon).toList(),
        tabSize: 48,
        tabBarHeight: 58,
        textStyle: TextStyle(
          fontSize: 11,
          color: t.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        tabIconColor: t.textSecondary,
        tabIconSize: 24.0,
        tabIconSelectedSize: 22.0,
        tabSelectedColor: t.accent,
        tabIconSelectedColor: Colors.white,
        tabBarColor: t.bgCard,
        onTabItemSelected: (int value) {
          setState(() {
            _selectedIndex = value;
            _motionTabController?.index = value;
          });
        },
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(top: BorderSide(color: t.bgRule)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: List.generate(_navItems.length, (idx) {
              final item = _navItems[idx];
              final isSelected = _selectedIndex == idx;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() {
                    _selectedIndex = idx;
                    if (_motionTabController != null && idx < _navItems.length) {
                      _motionTabController?.index = idx;
                    }
                  }),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? t.accent : (t.isDarkCanvas ? const Color(0xFF161B22) : const Color(0xFFF1F5F9)),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? t.accent : t.bgRule,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.icon,
                          size: 16,
                          color: isSelected ? Colors.white : t.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                            color: isSelected ? Colors.white : t.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopAppBar(BuildContext context, RoleThemeData t) {
    final isMobile = GBreakpoint.isMobile(context);

    return AppBar(
      backgroundColor: t.bgCard,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          // Dual Brand Logos (GMWF + School)
          ClipRRect(
            borderRadius: SchoolTheme.radius8,
            child: Image.asset(
              'assets/logo/gmwf-1.webp',
              height: 32,
              width: 32,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(Icons.school_rounded, color: t.accent, size: 24),
            ),
          ),
          const SizedBox(width: 10),
          ClipRRect(
            borderRadius: SchoolTheme.radius8,
            child: Image.asset(
              'assets/logo/twt-1.webp',
              height: 32,
              width: 32,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(width: 12),

          // Title & Badge
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'Taleem-wa-Tarbiyat School',
                    style: TextStyle(
                      fontSize: isMobile ? 15 : 17,
                      fontWeight: FontWeight.w800,
                      color: t.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  if (!isMobile) ...[
                    const SizedBox(width: 8),
                    SchoolBadge(
                      label: widget.role.toUpperCase(),
                      color: t.accent,
                      fontSize: 10.5,
                    ),
                  ],
                ],
              ),
              Text(
                'Branch: ${_effectiveBranchId.toUpperCase()} • Academic Portal',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: t.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        _SchoolSyncBadge(branchId: _effectiveBranchId),
        const SizedBox(width: 8),

        // User badge & settings
        if (!isMobile)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: InkWell(
              onTap: () {
                final uData = LocalStorageService.getActiveUserData();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsPage(userData: Map<String, dynamic>.from(uData)),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: t.isDarkCanvas ? const Color(0xFF161B22) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.bgRule),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.person_rounded, size: 15, color: t.accent),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.username,
                          style: TextStyle(
                            color: t.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.role,
                          style: TextStyle(
                            color: t.textTertiary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(width: 6),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: t.bgRule),
      ),
    );
  }

  Widget _buildSidebar(bool isCollapsed, RoleThemeData t) {
    final width = isCollapsed ? 72.0 : 250.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: width,
      decoration: const BoxDecoration(
        color: SchoolTheme.sidebarBg,
        border: Border(
          right: BorderSide(color: SchoolTheme.sidebarBorder, width: 1),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 14),

          // Sidebar Section Header
          if (!isCollapsed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _isTeacher ? 'FACULTY PORTAL' : 'SCHOOL MANAGEMENT',
                  style: const TextStyle(
                    color: SchoolTheme.sidebarMuted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 6),

          // Navigation items list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _navItems.length,
              itemBuilder: (context, index) {
                final item = _navItems[index];
                final isSelected = index == _selectedIndex;

                final tileWidget = Material(
                  color: Colors.transparent,
                  borderRadius: SchoolTheme.radius12,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => setState(() => _selectedIndex = index),
                    splashColor: t.accent.withValues(alpha: 0.15),
                    hoverColor: SchoolTheme.sidebarBorder,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: EdgeInsets.symmetric(
                        horizontal: isCollapsed ? 0 : 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected ? t.accent : Colors.transparent,
                        borderRadius: SchoolTheme.radius12,
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: t.accent.withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ]
                            : [],
                      ),
                      child: Row(
                        mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                        children: [
                          Icon(
                            item.icon,
                            color: isSelected ? Colors.white : SchoolTheme.sidebarMuted,
                            size: 20,
                          ),
                          if (!isCollapsed) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : SchoolTheme.sidebarText,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  fontSize: 13.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: isCollapsed ? Tooltip(message: item.label, child: tileWidget) : tileWidget,
                );
              },
            ),
          ),

          // Logout Tile
          const Divider(color: SchoolTheme.sidebarBorder, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _logout,
                splashColor: SchoolTheme.statusAbsent.withValues(alpha: 0.2),
                hoverColor: SchoolTheme.statusAbsent.withValues(alpha: 0.1),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCollapsed ? 0 : 14,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.logout_rounded,
                        color: Color(0xFFF87171),
                        size: 20,
                      ),
                      if (!isCollapsed) ...[
                        const SizedBox(width: 12),
                        const Text(
                          'Sign Out',
                          style: TextStyle(
                            color: Color(0xFFF87171),
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Collapse/Expand Footer
          const Divider(color: SchoolTheme.sidebarBorder, height: 1),
          InkWell(
            onTap: () => setState(() => _isCollapsed = !_isCollapsed),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.spaceBetween,
                children: [
                  if (!isCollapsed)
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _effectiveBranchId.toUpperCase(),
                          style: const TextStyle(
                            color: SchoolTheme.sidebarMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  Icon(
                    isCollapsed ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded,
                    color: SchoolTheme.sidebarMuted,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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

        Color color;
        String text;
        IconData? icon;

        switch (status.state) {
          case SchoolSyncState.synced:
            color = SchoolTheme.statusPresent;
            text = 'Synced';
            icon = Icons.cloud_done_rounded;
            break;
          case SchoolSyncState.syncing:
            color = SchoolTheme.statusLeave;
            text = 'Syncing…';
            icon = Icons.sync_rounded;
            break;
          case SchoolSyncState.failed:
            color = SchoolTheme.statusAbsent;
            text = 'Sync Failed (${status.failedCount})';
            icon = Icons.error_outline_rounded;
            break;
          case SchoolSyncState.offlinePending:
            color = status.isOnline ? SchoolTheme.statusLeave : SchoolTheme.textMuted;
            text = status.pendingCount > 0 ? 'Offline (${status.pendingCount} pending)' : 'Offline Mode';
            icon = Icons.cloud_off_rounded;
            break;
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () async {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Triggering manual School data sync…'),
                    duration: Duration(seconds: 1),
                  ),
                );
                await SchoolSyncService().syncNow(branchId: branchId);
              },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status.state == SchoolSyncState.syncing)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      )
                    else
                      Icon(icon, color: color, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      text,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.refresh_rounded, color: color.withValues(alpha: 0.8), size: 12),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
