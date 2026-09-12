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
import '../../widgets/global_module_wrapper.dart';
import '../../widgets/app_back_button.dart';
import '../../services/local_storage_service.dart';
import '../../services/auth_service.dart';
import '../settings_page.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
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

  const SchoolDashboard({
    super.key,
    this.branchId = 'all',
    this.username = 'User',
    this.role = 'School Admin',
    this.initialTabIndex = 0,
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

  bool get _isTeacher {
    final r = widget.role.toLowerCase().trim();
    return r.contains('teacher') && !r.contains('admin') && !r.contains('principal');
  }

  /// True only for school-specific roles (Principal, School Admin, School Teacher)
  /// Executive roles (Chairman, CEO, HQ Manager, Admin, etc.) get false.
  bool get _isSchoolRole {
    final r = widget.role.toLowerCase().trim();
    return r.contains('school') || r.contains('principal') || _isTeacher || _isPrincipal;
  }

  bool get _isPrincipal {
    final r = widget.role.toLowerCase().trim();
    return r.contains('principal');
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
    if (oldWidget.role != widget.role || oldWidget.branchId != widget.branchId || oldWidget.username != widget.username) {
      _initNavItemsAndViews();
    }
  }

  void _initNavItemsAndViews() {
    if (_isPrincipal) {
      // Principal sees Principal Dashboard, Directory, Fee, Library, Reports
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
          branchId: widget.branchId,
          userName: widget.username,
        ),
        SchoolStudentManagementView(
          branchId: widget.branchId,
          userRole: widget.role,
        ),
        SchoolDailyAttendanceView(
          branchId: widget.branchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherAttendanceView(
          branchId: widget.branchId,
          editorName: widget.username,
        ),
        SchoolTeacherManagementView(branchId: widget.branchId),
        SchoolFeeManagementView(
          branchId: widget.branchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolLibraryView(
          branchId: widget.branchId,
          userName: widget.username,
        ),
        SchoolGradingView(
          branchId: widget.branchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolAuditLogView(branchId: widget.branchId),
      ];
    } else if (_isTeacher) {
      // Teachers see assigned Daily Class Attendance, Class Grading & Reports, Student Directory, School Library
      _navItems = const [
        _NavItem(label: 'Daily Attendance', icon: Icons.how_to_reg_rounded),
        _NavItem(label: 'Grading & Reports', icon: Icons.grade_rounded),
        _NavItem(label: 'Class Students Roster', icon: Icons.groups_rounded),
        _NavItem(label: 'School Library', icon: Icons.local_library_rounded),
      ];
      _views = [
        SchoolDailyAttendanceView(
          branchId: widget.branchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolGradingView(
          branchId: widget.branchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolStudentManagementView(
          branchId: widget.branchId,
          userRole: widget.role,
        ),
        SchoolLibraryView(
          branchId: widget.branchId,
          userName: widget.username,
        ),
      ];
    } else {
      // Admin sees complete school control: Overview, Admissions, Attendance, Faculty, Fee, Library, Reports, Audit
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
        SchoolOverviewView(branchId: widget.branchId),
        SchoolStudentManagementView(
          branchId: widget.branchId,
          userRole: widget.role,
        ),
        SchoolDailyAttendanceView(
          branchId: widget.branchId,
          editorName: widget.username,
          userRole: widget.role,
        ),
        SchoolTeacherAttendanceView(
          branchId: widget.branchId,
          editorName: widget.username,
        ),
        SchoolTeacherManagementView(branchId: widget.branchId),
        SchoolFeeManagementView(
          branchId: widget.branchId,
          userName: widget.username,
          userRole: widget.role,
        ),
        SchoolLibraryView(
          branchId: widget.branchId,
          userName: widget.username,
        ),
        SchoolGradingView(
          branchId: widget.branchId,
          userRole: widget.role,
          userName: widget.username,
        ),
        SchoolAuditLogView(branchId: widget.branchId),
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
            Icon(Icons.logout_rounded, color: Color(0xFFEF4444)),
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
              backgroundColor: const Color(0xFFEF4444),
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
    final hasSchool = LocalStorageService.hasSchoolFacility(widget.branchId);
    if (!hasSchool) {
      final bName = LocalStorageService.getBranchName(widget.branchId);
      return Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
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
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.school_outlined, size: 42, color: Color(0xFF2563EB)),
                ),
                const SizedBox(height: 24),
                Text(
                  'School is not available in $bName yet',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1E293B),
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'The school facility is not enabled or registered for the $bName branch. If this branch has a school, contact system administration to configure it in Branches Management.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF64748B),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Return to Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
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
    final mediaWidth = MediaQuery.of(context).size.width;
    final isMobile = mediaWidth < 700;
    final isSmallScreen = mediaWidth < 850;
    final effectiveCollapsed = _isCollapsed || isSmallScreen;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: isWrapped ? null : _buildTopAppBar(context, t),
      drawer: null,
      bottomNavigationBar: isMobile
          ? (_navItems.length <= 5 && _motionTabController != null
              ? MotionTabBar(
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
                )
              : Container(
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    border: Border(top: BorderSide(color: t.bgRule)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
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
                                  color: isSelected
                                      ? t.accent
                                      : (t.isDarkCanvas ? const Color(0xFF161B22) : const Color(0xFFF1F5F9)),
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
                                        color: isSelected ? Colors.white : t.textSecondary,
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
                ))
          : null,
      body: Row(
        children: [
          // Sidebar Navigation (Desktop only, school-specific roles only)
          if (!isMobile && _isSchoolRole) _buildSidebar(effectiveCollapsed),

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

  PreferredSizeWidget _buildTopAppBar(BuildContext context, RoleThemeData t) {
    final isMobile = MediaQuery.of(context).size.width < 700;

    return AppBar(
      backgroundColor: t.bgCard,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          // Dual Logo Header: GMWF Logo + TWT Logo
          ClipRRect(
            borderRadius: SchoolTheme.radius8,
            child: Image.asset(
              'assets/logo/gmwf-1.webp',
              height: isMobile ? 26 : 32,
              width: isMobile ? 26 : 32,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: SchoolTheme.radius8,
                ),
                child: const Text('GMWF', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text('•', style: TextStyle(color: t.textTertiary, fontSize: 16)),
          const SizedBox(width: 6),
          ClipRRect(
            borderRadius: SchoolTheme.radius8,
            child: Image.asset(
              'assets/logo/twt.webp',
              height: isMobile ? 26 : 32,
              width: isMobile ? 26 : 32,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.2),
                  border: Border.all(color: t.accent),
                  borderRadius: SchoolTheme.radius8,
                ),
                child: Row(
                  children: [
                    Icon(Icons.school_rounded, color: t.accent, size: 16),
                    const SizedBox(width: 4),
                    Text('TWT', style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
          if (!isMobile) ...[
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Taleem-wa-Tarbiyat School System',
                    style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'User: ${widget.username} • Role: ${widget.role} • Branch: ${widget.branchId}',
                    style: TextStyle(color: t.textSecondary, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
      actions: [
        _SchoolSyncBadge(branchId: widget.branchId),
        // Sidebar toggle only on desktop and school roles
        if (!isMobile && _isSchoolRole)
          IconButton(
            tooltip: _isCollapsed ? 'Expand Sidebar' : 'Collapse Sidebar',
            icon: Icon(
              _isCollapsed ? Icons.menu_open_rounded : Icons.menu_rounded,
              color: t.textPrimary,
            ),
            onPressed: () {
              setState(() => _isCollapsed = !_isCollapsed);
            },
          ),
        // User Profile Section in AppBar — tapping opens Settings
        if (!isMobile)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.person_rounded, size: 16, color: t.accent),
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
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.role,
                          style: TextStyle(
                            color: t.textTertiary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildSidebar(bool isCollapsed, {bool isDrawer = false}) {
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
          const SizedBox(height: 12),

          // Sidebar Section Header
          if (!isCollapsed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'NAVIGATION',
                  style: TextStyle(
                    color: SchoolTheme.sidebarMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 4),

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
                      onTap: () {
                        setState(() => _selectedIndex = index);
                        if (isDrawer) Navigator.pop(context);
                      },
                      splashColor: SchoolTheme.accent.withValues(alpha: 0.15),
                      hoverColor: SchoolTheme.sidebarBorder,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: EdgeInsets.symmetric(
                          horizontal: isCollapsed ? 0 : 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? SchoolTheme.accent
                              : Colors.transparent,
                          borderRadius: SchoolTheme.radius12,
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: SchoolTheme.accent.withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : [],
                        ),
                        child: Row(
                          mainAxisAlignment: isCollapsed
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.start,
                          children: [
                            Icon(
                              item.icon,
                              color: isSelected
                                  ? Colors.white
                                  : SchoolTheme.sidebarMuted,
                              size: 20,
                            ),
                            if (!isCollapsed) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  item.label,
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : SchoolTheme.sidebarText,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w500,
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
                  child: isCollapsed
                      ? Tooltip(message: item.label, child: tileWidget)
                      : tileWidget,
                );
              },
            ),
          ),

          // Logout tile in Sidebar
          const Divider(color: Color(0xFF1E293B), height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _logout,
                splashColor: const Color(0xFFEF4444).withValues(alpha: 0.2),
                hoverColor: const Color(0xFFEF4444).withValues(alpha: 0.1),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCollapsed ? 0 : 14,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: isCollapsed
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
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

          // Sidebar Footer / Toggle button (hidden in drawer mode)
          if (!isDrawer) ...[
            const Divider(color: Color(0xFF1E293B), height: 1),
            InkWell(
              onTap: () => setState(() => _isCollapsed = !_isCollapsed),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: isCollapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.spaceBetween,
                  children: [
                    if (!isCollapsed)
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.branchId.toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    Icon(
                      isCollapsed
                          ? Icons.arrow_forward_ios_rounded
                          : Icons.arrow_back_ios_rounded,
                      color: const Color(0xFF64748B),
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
          ],
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
            color = const Color(0xFF10B981);
            text = 'Synced';
            icon = Icons.cloud_done_rounded;
            break;
          case SchoolSyncState.syncing:
            color = const Color(0xFFF59E0B);
            text = 'Syncing…';
            icon = Icons.sync_rounded;
            break;
          case SchoolSyncState.failed:
            color = const Color(0xFFEF4444);
            text = 'Sync Failed (${status.failedCount})';
            icon = Icons.error_outline_rounded;
            break;
          case SchoolSyncState.offlinePending:
            color = status.isOnline ? const Color(0xFFF59E0B) : const Color(0xFF64748B);
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
                  color: color.withValues(alpha: 0.15),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
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
