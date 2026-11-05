import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'views/daily_log_view.dart' show DailyLogView;
import 'views/student_management_view.dart';
import 'views/monthly_report_view.dart';
import 'views/madrassa_config_view.dart';
import 'views/madrassa_overview_view.dart';
import 'views/madrassa_progress_view.dart';
import 'views/madrassa_teachers_view.dart';
import 'dialogs/enrollment_dialog.dart';
import 'dialogs/madrassa_profile_dialog.dart';
import 'dialogs/register_teacher_dialog.dart';
import 'madrassa_strings.dart';
import 'utils/madrassa_local_storage.dart';
import '../../services/local_storage_service.dart';
import '../../services/sync_service.dart';
import '../../services/auth_service.dart';
import '../../services/user_theme_service.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../design/design_system.dart';

class MadrassaDashboard extends StatefulWidget {
  final String branchId;
  final String username;
  final String role;
  final bool isAdmin;
  final int? initialIndex;
  final bool autoOpenAddStudent;

  const MadrassaDashboard({
    super.key,
    required this.branchId,
    required this.username,
    required this.role,
    this.isAdmin = true,
    this.initialIndex,
    this.autoOpenAddStudent = false,
  });

  @override
  State<MadrassaDashboard> createState() => _MadrassaDashboardState();
}

class _MadrassaDashboardState extends State<MadrassaDashboard> {
  late int _selectedIndex;
  late Future<void> _bootstrapFuture;
  late String _displayUsername;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex ?? 0;
    _displayUsername = widget.username;
    _bootstrapFuture = _bootstrapMadrassa();
    if (widget.autoOpenAddStudent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showAddStudentDialog(
          context,
          widget.branchId,
          username: _displayUsername,
          role: widget.role,
        );
      });
    }
  }

  Future<void> _openProfileDialog() async {
    final updated = await MadrassaProfileDialog.show(
      context,
      branchId: widget.branchId,
      currentUsername: _displayUsername,
      userRole: widget.role,
    );
    if (updated != null && updated.isNotEmpty && mounted) {
      setState(() {
        _displayUsername = updated;
      });
    }
  }

  Future<void> _openRegisterTeacherDialog() async {
    // Derive branch display name (fallback to branchId if not stored)
    String branchDisplayName = widget.branchId.toUpperCase();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final bn = box.get('branch_name_${widget.branchId.toLowerCase()}');
        if (bn is String && bn.isNotEmpty) branchDisplayName = bn;
      }
    } catch (_) {}

    final registered = await showRegisterTeacherDialog(
      context,
      branchId: widget.branchId,
      branchName: branchDisplayName,
      principalUsername: _displayUsername,
    );
    if (registered == true && mounted) {
      AppToast.showSnackBar(context, const SnackBar(
        content: Row(children: [
          Icon(Icons.check_circle_outline, color: SoftPalette.gray50, size: 17),
          SizedBox(width: 8),
          Text('Teacher registered successfully!'),
        ]),
        backgroundColor: SoftPalette.teal550,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        duration: Duration(seconds: 3),
      ));
    }
  }

  Future<void> _bootstrapMadrassa() async {
    await LocalStorageService.initForRoles([
      widget.role,
      'madrassa',
      'madrassa admin',
      'madrassa teacher',
      'qari',
      'nazim',
      'chairman',
      'hq manager',
      'hq_manager',
      'ceo',
      'admin',
    ]);
    await MadrassaLocalStorage.ensureBoxesOpen();
    if (widget.branchId.isNotEmpty && widget.branchId != 'unknown') {
      SyncService().start(widget.branchId);
      // Immediately download all fresh Madrassa data for this branch in the background
      MadrassaLocalStorage.downloadAllMadrassaData(widget.branchId);
    }
  }

  bool get _effectiveIsAdmin {
    final r = widget.role.toLowerCase().trim();
    return widget.isAdmin ||
        r.contains('admin') ||
        r.contains('chairman') ||
        r.contains('hq') ||
        r.contains('hq manager') ||
        r.contains('hqmanager') ||
        r.contains('hq_manager') ||
        r.contains('ceo') ||
        r.contains('principal') ||
        r.contains('manager') ||
        r.contains('director') ||
        r.contains('supervisor') ||
        r.contains('global');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: context.adapt(SoftPalette.teal550),
              ),
            ),
          );
        }
        return ChangeNotifierProvider(
          create: (_) => MadrassaLanguageProvider(),
          child: Builder(
        builder: (context) {
          final branchId = widget.branchId;

          if (branchId == 'unknown') {
            return const Scaffold(
              body: Center(
                child: Text('Please select a branch first'),
              ),
            );
          }

          final isTeacherOrAdmin = _effectiveIsAdmin || widget.role.toLowerCase() == 'madrassa teacher';

          final views = [
            if (_effectiveIsAdmin)
              MadrassaOverviewView(
                branchId: branchId,
                isAdmin: _effectiveIsAdmin,
                onAction: (index) => setState(() => _selectedIndex = index),
              ),
            DailyLogView(
              branchId: branchId,
              editorName: _displayUsername,
              editorRole: widget.role,
            ),
            StudentManagementView(
              branchId: branchId,
              isAdmin: _effectiveIsAdmin,
              username: _displayUsername,
              role: widget.role,
            ),
            if (_effectiveIsAdmin)
              MadrassaTeachersView(
                branchId: branchId,
                principalUsername: _displayUsername,
                role: widget.role,
              ),
            if (isTeacherOrAdmin) ...[
              MadrassaProgressView(
                branchId: branchId,
                isAdmin: _effectiveIsAdmin,
                username: _displayUsername,
              ),
              MonthlyReportView(
                branchId: branchId,
                username: _displayUsername,
                role: widget.role,
              ),
              MadrassaConfigView(
                branchId: branchId,
                username: _displayUsername,
                role: widget.role,
              ),
            ],
          ];

          final isMobileLayout = GBreakpoint.isMobile(context);

          // Navigation items definitions
          final navTitles = [
            if (_effectiveIsAdmin)
              isMobileLayout
                  ? (context.isUrdu ? 'اوور ویو' : 'Home')
                  : context.l.overviewTitle,
            isMobileLayout
                ? (context.isUrdu ? 'روزانہ' : 'Daily')
                : context.l.dailyLog,
            isMobileLayout
                ? (context.isUrdu ? 'طلبہ' : 'Students')
                : context.l.students,
            if (_effectiveIsAdmin)
              isMobileLayout
                  ? (context.isUrdu ? 'اساتذہ' : 'Teachers')
                  : context.l.teachers,
            if (isTeacherOrAdmin) ...[
              context.isUrdu ? 'پیشرفت' : 'Progress',
              isMobileLayout
                  ? (context.isUrdu ? 'ماہانہ' : 'Monthly')
                  : context.l.monthlyReport,
              isMobileLayout
                  ? (context.isUrdu ? 'سیٹنگ' : 'Setup')
                  : context.l.navConfig,
            ],
          ];

          final navIcons = [
            if (_effectiveIsAdmin) Icons.dashboard_outlined,
            Icons.calendar_today_outlined,
            Icons.people_outline,
            if (_effectiveIsAdmin) Icons.school_outlined,
            if (isTeacherOrAdmin) ...[
              Icons.trending_up_outlined,
              Icons.bar_chart_outlined,
              Icons.settings_outlined,
            ],
          ];

          final navActiveIcons = [
            if (_effectiveIsAdmin) Icons.dashboard_rounded,
            Icons.calendar_today_rounded,
            Icons.people_alt_rounded,
            if (_effectiveIsAdmin) Icons.school_rounded,
            if (isTeacherOrAdmin) ...[
              Icons.trending_up_rounded,
              Icons.bar_chart_rounded,
              Icons.settings_rounded,
            ],
          ];

          return RoleThemeScope(
            role: RoleTheme.madrassa,
            child: ValueListenableBuilder(
              valueListenable: UserThemeService.listenable(widget.username),
              builder: (context, Box box, _) {
                final isDark = UserThemeService.isDarkMode(widget.username);
                final scaffoldBg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
                final cardBg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
                final textPrimary = isDark ? SoftPalette.slate100 : SoftPalette.slate900;
                final textMuted = isDark ? SoftPalette.slate350 : SoftPalette.slate550;
                final borderColor = isDark ? SoftPalette.slate800 : SoftPalette.slate150;
                const emeraldPrimary = SoftPalette.teal550;
                const emeraldLight = SoftPalette.teal350;

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobile = GBreakpoint.isMobileC(constraints);
                    final isTablet = GBreakpoint.isTabletC(constraints);

                    if (isMobile) {
                      return Scaffold(
                        backgroundColor: scaffoldBg,
                        appBar: _buildMobileAppBar(
                          context,
                          isDark: isDark,
                          cardBg: cardBg,
                          borderColor: borderColor,
                          textPrimary: textPrimary,
                          textMuted: textMuted,
                          currentTitle: navTitles[_selectedIndex],
                        ),
                        body: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildIslamicWatermark(isDark),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              transitionBuilder: (child, animation) {
                                return FadeTransition(
                                  opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
                                  child: child,
                                );
                              },
                              child: KeyedSubtree(
                                key: ValueKey(_selectedIndex),
                                child: views[_selectedIndex],
                              ),
                            ),
                          ],
                        ),
                        bottomNavigationBar: MadrassaMotionBottomBar(
                          selectedIndex: _selectedIndex,
                          onTabSelected: (i) => setState(() => _selectedIndex = i),
                          titles: navTitles,
                          icons: navIcons,
                          activeIcons: navActiveIcons,
                          isDark: isDark,
                        ),
                      );
                    } else if (isTablet) {
                      return Scaffold(
                        backgroundColor: scaffoldBg,
                        appBar: _buildTabletAppBar(
                          context,
                          isDark: isDark,
                          cardBg: cardBg,
                          borderColor: borderColor,
                          textPrimary: textPrimary,
                          textMuted: textMuted,
                          currentTitle: navTitles[_selectedIndex],
                        ),
                        body: Row(
                          children: [
                            _buildTabletSidebar(
                              context,
                              isDark: isDark,
                              cardBg: cardBg,
                              borderColor: borderColor,
                              textMuted: textMuted,
                              navIcons: navIcons,
                              navActiveIcons: navActiveIcons,
                              navTitles: navTitles,
                            ),
                            VerticalDivider(width: 1, thickness: 1, color: borderColor),
                            Expanded(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _buildIslamicWatermark(isDark),
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 250),
                                    child: KeyedSubtree(
                                      key: ValueKey(_selectedIndex),
                                      child: views[_selectedIndex],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    } else {
                      // Desktop (> 960px)
                      return Scaffold(
                        backgroundColor: scaffoldBg,
                        body: Row(
                          children: [
                            // Executive Desktop Sidebar
                            _buildDesktopSidebar(
                              context,
                              isDark: isDark,
                              cardBg: cardBg,
                              borderColor: borderColor,
                              textPrimary: textPrimary,
                              textMuted: textMuted,
                              emeraldPrimary: emeraldPrimary,
                              emeraldLight: emeraldLight,
                              navIcons: navIcons,
                              navActiveIcons: navActiveIcons,
                              navTitles: navTitles,
                            ),
                            VerticalDivider(width: 1, thickness: 1, color: borderColor),
                            // Main View Area with Desktop Top Bar
                            Expanded(
                              child: Column(
                                children: [
                                  _buildDesktopTopBar(
                                    context,
                                    isDark: isDark,
                                    cardBg: cardBg,
                                    borderColor: borderColor,
                                    textPrimary: textPrimary,
                                    textMuted: textMuted,
                                    currentTitle: navTitles[_selectedIndex],
                                  ),
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _buildIslamicWatermark(isDark),
                                        Align(
                                          alignment: Alignment.topCenter,
                                          child: Container(
                                            constraints: const BoxConstraints(maxWidth: 1280),
                                            child: AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 250),
                                              child: KeyedSubtree(
                                                key: ValueKey(_selectedIndex),
                                                child: views[_selectedIndex],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                  },
                );
                },
              ),
            );
          },
        ),
      );
    },
  );
}

  // --- Islamic Watermark Background ---
  Widget _buildIslamicWatermark(bool isDark) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: isDark ? 0.055 : 0.075,
          child: GDecorativeImage.asset(
            'assets/images/islamic_pattern.webp',
            fit: BoxFit.cover,
            repeat: ImageRepeat.repeat,
            color: SoftPalette.yellow300,
            colorBlendMode: BlendMode.srcIn,
          ),
        ),
      ),
    );
  }

  // --- Mobile App Bar ---
  PreferredSizeWidget _buildMobileAppBar(
    BuildContext context, {
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textMuted,
    required String currentTitle,
  }) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg.withValues(alpha: 0.95),
          border: Border(bottom: BorderSide(color: borderColor, width: 1)),
          boxShadow: [
            BoxShadow(
              color: SoftPalette.gray900.withValues(alpha: isDark ? 0.3 : 0.03),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                // Back button if screen can be popped
                if (Navigator.of(context).canPop()) ...[
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: borderColor),
                      ),
                      child: Icon(Icons.arrow_back_rounded, size: 18, color: textPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // Logo squircle with glow
                Container(
                  width: 36,
                  height: 36,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: SoftPalette.teal550.withValues(alpha: 0.15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Image.asset('assets/logo/gmwf-1.webp', fit: BoxFit.contain),
                ),
                const SizedBox(width: 8),
                // Title, Branch pill & active section
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.isUrdu ? 'جامعہ گلزار مدینہ' : 'Gulzar Madina',
                        overflow: TextOverflow.ellipsis,
                        style: context.urduStyle(
                          style: TextStyle(
                            color: textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.25),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              widget.branchId.toUpperCase(),
                              style: TextStyle(
                                color: context.adapt(SoftPalette.teal550),
                                fontWeight: FontWeight.bold,
                                fontSize: 9,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              currentTitle,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.adapt(SoftPalette.teal550),
                                fontWeight: FontWeight.bold,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Modern Action Buttons on Mobile: Sync, Language, and consolidated More Menu
                _buildSyncBtn(context, isDark),
                const SizedBox(width: 6),
                _buildLanguageToggleBtn(context, isDark),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, size: 20, color: textMuted),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: cardBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: borderColor),
                  ),
                  onSelected: (val) async {
                    if (val == 'register_teacher') {
                      _openRegisterTeacherDialog();
                    } else if (val == 'profile') {
                      _openProfileDialog();
                    } else if (val == 'theme') {
                      await UserThemeService.toggleDarkMode(explicitUserKey: widget.username);
                    } else if (val == 'logout') {
                      final navigator = Navigator.of(context);
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (dCtx) => AlertDialog(
                          title: Text(
                            context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out',
                            style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          content: Text(
                            context.isUrdu ? 'کیا آپ واقعی لاگ آؤٹ کرنا چاہتے ہیں؟' : 'Are you sure you want to sign out?',
                            style: context.urduStyle(),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx, false),
                              child: Text(context.l.cancel, style: context.urduStyle()),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: context.adapt(SoftPalette.red500)),
                              onPressed: () => Navigator.pop(dCtx, true),
                              child: Text(
                                context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out',
                                style: context.urduStyle(style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true && mounted) {
                        await FirebaseAuth.instance.signOut();
                        navigator.pushNamedAndRemoveUntil('/login', (_) => false);
                      }
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (_effectiveIsAdmin)
                      PopupMenuItem(
                        value: 'register_teacher',
                        child: Row(
                          children: [
                            Icon(Icons.person_add_rounded, size: 18, color: ctx.adapt(SoftPalette.teal550)),
                            const SizedBox(width: 10),
                            Text(
                              context.isUrdu ? 'نیا استاد درج کریں' : 'Register Teacher',
                              style: context.urduStyle(style: const TextStyle(fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: 'profile',
                      child: Row(
                        children: [
                          Icon(Icons.manage_accounts_rounded, size: 18, color: ctx.adapt(SoftPalette.teal550)),
                          const SizedBox(width: 10),
                          Text(
                            context.isUrdu ? 'پروفائل اور پاس ورڈ' : 'Profile & Password',
                            style: context.urduStyle(style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'theme',
                      child: Row(
                        children: [
                          Icon(
                            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                            size: 18,
                            color: ctx.adapt(SoftPalette.amber300),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isDark
                                ? (context.isUrdu ? 'لائٹ موڈ' : 'Light Mode')
                                : (context.isUrdu ? 'ڈارک موڈ' : 'Dark Mode'),
                            style: context.urduStyle(style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'logout',
                      child: Row(
                        children: [
                          Icon(Icons.logout_rounded, size: 18, color: ctx.adapt(SoftPalette.red500)),
                          const SizedBox(width: 10),
                          Text(
                            context.isUrdu ? 'لاگ آؤٹ' : 'Sign Out',
                            style: context.urduStyle(
                              style: TextStyle(
                                fontSize: 13,
                                color: ctx.adapt(SoftPalette.red500),
                                fontWeight: FontWeight.w600,
                              ),
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
        ),
      ),
    );
  }

  // --- Tablet App Bar ---
  PreferredSizeWidget _buildTabletAppBar(
    BuildContext context, {
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textMuted,
    required String currentTitle,
  }) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          border: Border(bottom: BorderSide(color: borderColor, width: 1)),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              children: [
                Image.asset('assets/logo/gmwf-1.webp', height: 34),
                const SizedBox(width: 12),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Gulzar Madina Madrassa',
                      style: context.urduStyle(
                        style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Text(
                      '${widget.branchId.toUpperCase()} • $_displayUsername (${widget.role})',
                      style: TextStyle(color: textMuted, fontSize: 11.5, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    currentTitle,
                    style: context.urduStyle(
                      style: TextStyle(
                        color: context.adapt(SoftPalette.teal550),
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(Icons.manage_accounts_rounded, size: 22, color: context.adapt(SoftPalette.teal550)),
                  tooltip: 'Profile & Password',
                  onPressed: _openProfileDialog,
                ),
                const SizedBox(width: 6),
                if (_effectiveIsAdmin) ...[
                  _buildRegisterTeacherBtn(compact: true),
                  const SizedBox(width: 6),
                ],
                _buildSyncBtn(context, isDark),
                const SizedBox(width: 6),
                _buildThemeToggleBtn(isDark),
                const SizedBox(width: 6),
                _buildLanguageToggleBtn(context, isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Tablet Sidebar Navigation Rail ---
  Widget _buildTabletSidebar(
    BuildContext context, {
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textMuted,
    required List<IconData> navIcons,
    required List<IconData> navActiveIcons,
    required List<String> navTitles,
  }) {
    return Container(
      width: 72,
      color: cardBg,
      child: NavigationRail(
        backgroundColor: cardBg,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        labelType: NavigationRailLabelType.none,
        selectedIconTheme: IconThemeData(color: context.adapt(SoftPalette.teal550), size: 24),
        unselectedIconTheme: IconThemeData(color: textMuted, size: 22),
        indicatorColor: context.adapt(SoftPalette.teal550).withValues(alpha: 0.14),
        destinations: List.generate(navTitles.length, (idx) {
          return NavigationRailDestination(
            icon: Icon(navIcons[idx]),
            selectedIcon: Icon(navActiveIcons[idx]),
            label: Text(navTitles[idx]),
          );
        }),
      ),
    );
  }

  // --- Desktop Top Bar ---
  Widget _buildDesktopTopBar(
    BuildContext context, {
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textMuted,
    required String currentTitle,
  }) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1)),
      ),
      child: Row(
        children: [
          // Section Title pill badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [SoftPalette.teal550.withValues(alpha: 0.25), SoftPalette.teal350.withValues(alpha: 0.1)]
                    : [SoftPalette.teal550.withValues(alpha: 0.12), SoftPalette.teal350.withValues(alpha: 0.05)],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: context.adapt(SoftPalette.emerald350),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  currentTitle,
                  style: context.urduStyle(
                    style: TextStyle(
                      color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Branch info pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_on_outlined, size: 14, color: context.adapt(SoftPalette.teal550)),
                const SizedBox(width: 4),
                Text(
                  widget.branchId.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Profile & Password Button
          IconButton(
            icon: Icon(Icons.manage_accounts_rounded, size: 22, color: context.adapt(SoftPalette.teal550)),
            tooltip: 'Profile & Password',
            onPressed: _openProfileDialog,
          ),
          const SizedBox(width: 8),
          // Sync button
          _buildSyncBtn(context, isDark),
          const SizedBox(width: 8),
          // Theme Toggle
          _buildThemeToggleBtn(isDark),
          const SizedBox(width: 8),
          // Language Toggle
          _buildLanguageToggleBtn(context, isDark),
        ],
      ),
    );
  }

  // --- Executive Desktop Sidebar ---
  Widget _buildDesktopSidebar(
    BuildContext context, {
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textMuted,
    required Color emeraldPrimary,
    required Color emeraldLight,
    required List<IconData> navIcons,
    required List<IconData> navActiveIcons,
    required List<String> navTitles,
  }) {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: cardBg,
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: isDark ? 0.3 : 0.03),
            blurRadius: 10,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Sidebar Brand Header
          Container(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor, width: 1)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.35),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: SoftPalette.teal550.withValues(alpha: 0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Image.asset('assets/logo/gmwf-1.webp', fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Madrassa',
                        style: context.urduStyle(
                          style: TextStyle(
                            color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      Text(
                        'Management Hub',
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Sidebar Navigation Items
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              itemCount: navTitles.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, idx) {
                final isSelected = _selectedIndex == idx;
                return _SidebarNavItem(
                  title: navTitles[idx],
                  icon: navIcons[idx],
                  activeIcon: navActiveIcons[idx],
                  isSelected: isSelected,
                  isDark: isDark,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _selectedIndex = idx);
                  },
                );
              },
            ),
          ),

          // Register Teacher button (principal / chairman / hq / admin)
          if (_effectiveIsAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildRegisterTeacherBtn(compact: false),
            ),
          // User Profile Card at Bottom
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
              border: Border(top: BorderSide(color: borderColor, width: 1)),
            ),
            child: Row(
              children: [
                // Avatar Circle & User Details (Tappable)
                Expanded(
                  child: InkWell(
                    onTap: _openProfileDialog,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [SoftPalette.teal550, SoftPalette.teal350],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: SoftPalette.teal550.withValues(alpha: 0.3),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                _displayUsername.isNotEmpty ? _displayUsername[0].toUpperCase() : 'M',
                                style: const TextStyle(
                                  color: SoftPalette.gray50,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _displayUsername,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          color: textPrimary,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Icon(
                                      Icons.edit_outlined,
                                      size: 13,
                                      color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.7),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  widget.isAdmin
                                      ? 'Principal / Admin'
                                      : widget.role,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: textMuted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Sign Out Button
                IconButton(
                  icon: Icon(Icons.logout_rounded, color: context.adapt(SoftPalette.red400), size: 18),
                  tooltip: 'Sign Out',
                  splashRadius: 18,
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    try {
                      await AuthService().signOut();
                    } catch (e) {
                      debugPrint('[MadrassaDashboard] Sign out error: $e');
                    }
                    navigator.pushNamedAndRemoveUntil('/login', (_) => false);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Register Teacher Button ---
  Widget _buildRegisterTeacherBtn({required bool compact}) {
    if (compact) {
      // Icon-only for app bars
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.adapt(SoftPalette.teal550).withValues(alpha: 0.3), width: 1),
        ),
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(Icons.person_add_rounded, size: 18, color: context.adapt(SoftPalette.teal550)),
          tooltip: 'Register New Teacher',
          onPressed: _openRegisterTeacherDialog,
        ),
      );
    }
    // Full-width button for desktop sidebar
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: SoftPalette.teal550,
          foregroundColor: SoftPalette.gray50,
          elevation: 2,
          shadowColor: SoftPalette.teal550.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        icon: const Icon(Icons.person_add_rounded, size: 17),
        label: const Text(
          'Register Teacher',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
        ),
        onPressed: _openRegisterTeacherDialog,
      ),
    );
  }

  // --- Theme Toggle Button ---
  Widget _buildThemeToggleBtn(bool isDark) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? SoftPalette.gray50A12 : SoftPalette.slate150,
          width: 1,
        ),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Icon(
            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            key: ValueKey(isDark),
            color: isDark ? SoftPalette.yellow150 : SoftPalette.teal550,
            size: 18,
          ),
        ),
        tooltip: isDark ? 'Light Mode' : 'Dark Mode',
        onPressed: () async {
          await UserThemeService.toggleDarkMode(explicitUserKey: widget.username);
        },
      ),
    );
  }

  // --- Language Toggle Button ---
  Widget _buildLanguageToggleBtn(BuildContext context, bool isDark) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? SoftPalette.gray50A12 : SoftPalette.slate150,
          width: 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          Provider.of<MadrassaLanguageProvider>(context, listen: false).toggleLanguage();
        },
        child: Center(
          child: Text(
            context.isUrdu ? 'EN' : 'اردو',
            style: context.urduStyle(
              style: TextStyle(
                color: isDark ? SoftPalette.teal300 : SoftPalette.teal550,
                fontWeight: FontWeight.bold,
                fontSize: context.isUrdu ? 12 : 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Sync Cloud Data Button ---
  Widget _buildSyncBtn(BuildContext context, bool isDark) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? SoftPalette.gray50A12 : SoftPalette.slate150,
          width: 1,
        ),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(
          Icons.sync_rounded,
          color: context.adapt(SoftPalette.teal550),
          size: 18,
        ),
        tooltip: context.isUrdu ? 'کلاؤڈ سے معلومات اپ ڈیٹ کریں' : 'Sync / Download Cloud Data',
        onPressed: () async {
          AppToast.showSnackBar(context, 
            SnackBar(
              content: Text(context.isUrdu ? 'ڈیٹا حاصل کیا جا رہا ہے...' : 'Syncing data from cloud...'),
              duration: const Duration(seconds: 1),
            ),
          );
          final now = DateTime.now();
          // Trigger urgent upload and concurrently download students, monthly logs, and holidays
          final uploadFuture = SyncService().triggerUpload(urgent: true);
          final downloadResults = await Future.wait([
            MadrassaLocalStorage.downloadStudents(widget.branchId, force: true),
            MadrassaLocalStorage.downloadLogsForMonth(widget.branchId, now.year, now.month),
            MadrassaLocalStorage.downloadHolidays(widget.branchId),
            uploadFuture.timeout(const Duration(seconds: 30), onTimeout: () => null),
          ]);
          final downloaded = (downloadResults[0] as bool?) ?? false;
          final pending = MadrassaLocalStorage.pendingStudentUploads();
          if (mounted) setState(() {});
          if (context.mounted) {
            final ok = downloaded && pending == 0;
            final String msg;
            if (ok) {
              msg = context.isUrdu ? 'ڈیٹا کامیابی سے اپ ڈیٹ ہو گیا' : 'Sync completed successfully!';
            } else if (!downloaded) {
              msg = context.isUrdu
                  ? 'کلاؤڈ سے رابطہ نہیں ہو سکا۔ انٹرنیٹ چیک کر کے دوبارہ کوشش کریں'
                  : 'Could not reach the cloud. Check the internet and try again.';
            } else {
              msg = context.isUrdu
                  ? '$pending طالب علم ابھی اپ لوڈ ہونا باقی ہیں'
                  : '$pending student(s) still waiting to upload. They will retry automatically.';
            }
            AppToast.showSnackBar(context,
              SnackBar(
                content: Text(msg),
                backgroundColor: ok ? SoftPalette.teal550 : SoftPalette.amber600,
                duration: Duration(seconds: ok ? 2 : 5),
              ),
            );
          }
        },
      ),
    );
  }
}

// ==========================================
// DESKTOP SIDEBAR NAV ITEM (With Hover Effects)
// ==========================================
class _SidebarNavItem extends StatefulWidget {
  final String title;
  final IconData icon;
  final IconData activeIcon;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _SidebarNavItem({
    required this.title,
    required this.icon,
    required this.activeIcon,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final activeBg = widget.isDark
        ? const LinearGradient(
            colors: [SoftPalette.teal550, SoftPalette.teal600],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          )
        : const LinearGradient(
            colors: [SoftPalette.teal550, SoftPalette.teal500],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          );

    final hoverBg = widget.isDark
        ? SoftPalette.slate800.withValues(alpha: 0.6)
        : SoftPalette.slate100;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: widget.isSelected ? activeBg : null,
            color: widget.isSelected ? null : (_isHovered ? hoverBg : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: SoftPalette.teal550.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(
                widget.isSelected ? widget.activeIcon : widget.icon,
                size: 20,
                color: widget.isSelected
                    ? SoftPalette.gray50
                    : (_isHovered
                        ? (widget.isDark ? SoftPalette.teal300 : SoftPalette.teal550)
                        : (widget.isDark ? SoftPalette.slate350 : SoftPalette.slate550)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.title,
                  style: context.urduStyle(
                    style: TextStyle(
                      color: widget.isSelected
                          ? SoftPalette.gray50
                          : (_isHovered
                              ? (widget.isDark ? SoftPalette.gray50 : SoftPalette.slate900)
                              : (widget.isDark ? SoftPalette.slate200 : SoftPalette.slate700)),
                      fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.isSelected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: context.adapt(SoftPalette.emerald300),
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// MOBILE MOTION BOTTOM BAR (Auto-Centering Smooth Nav Bar)
// ==========================================
class MadrassaMotionBottomBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final List<String> titles;
  final List<IconData> icons;
  final List<IconData> activeIcons;
  final bool isDark;

  const MadrassaMotionBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.titles,
    required this.icons,
    required this.activeIcons,
    required this.isDark,
  });

  @override
  State<MadrassaMotionBottomBar> createState() => _MadrassaMotionBottomBarState();
}

class _MadrassaMotionBottomBarState extends State<MadrassaMotionBottomBar> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected(animate: false));
  }

  @override
  void didUpdateWidget(covariant MadrassaMotionBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected(animate: true));
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    const itemWidth = 72.0;
    final screenWidth = MediaQuery.of(context).size.width;
    final targetOffset = (widget.selectedIndex * itemWidth) - (screenWidth / 2) + (itemWidth / 2);
    final clampedOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
    if (animate) {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clampedOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderColor = widget.isDark ? SoftPalette.slate800 : SoftPalette.slate150;
    const emeraldPrimary = SoftPalette.teal550;
    const emeraldLight = SoftPalette.teal350;
    final inactiveColor = widget.isDark ? SoftPalette.slate350 : SoftPalette.slate550;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(color: borderColor, width: 1.0),
        ),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: widget.isDark ? 0.35 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalItems = widget.titles.length;
              final canFitAll = constraints.maxWidth >= (totalItems * 68.0);
              final itemWidth = canFitAll ? (constraints.maxWidth / totalItems) : 72.0;

              return ListView.builder(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: totalItems,
                itemBuilder: (context, i) {
                  final isSelected = widget.selectedIndex == i;
                  return InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onTabSelected(i);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: itemWidth,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              gradient: isSelected
                                  ? const LinearGradient(
                                      colors: [emeraldPrimary, emeraldLight],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : null,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: emeraldPrimary.withValues(alpha: 0.35),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              isSelected ? widget.activeIcons[i] : widget.icons[i],
                              size: 18,
                              color: isSelected ? SoftPalette.gray50 : inactiveColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.titles[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.urduStyle(
                              style: TextStyle(
                                color: isSelected ? (widget.isDark ? emeraldLight : emeraldPrimary) : inactiveColor,
                                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
