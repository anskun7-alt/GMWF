// lib/pages/global_modular_dashboard.dart
// ─────────────────────────────────────────────────────────────────────────────

import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:io';
import 'package:lottie/lottie.dart';

import '../models/module_registry.dart';
import '../theme/app_theme.dart';
import '../theme/app_visual_theme.dart';
import '../theme/role_theme_provider.dart';
import '../services/user_theme_service.dart';
import 'settings_page.dart';
import 'support_page.dart';
import 'notification_screen.dart';
import 'request.dart';
import '../widgets/global_module_wrapper.dart';
import '../widgets/notification_bell_popover.dart';
import '../widgets/home_snapshot_widgets.dart';
import '../services/sync_service.dart';
import '../design/design_system.dart';
import 'admin/data_cleanup_screen.dart';
import '../services/role_simulator_service.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:gmwf/services/branch_directory.dart';
import '../services/local_storage_service.dart';
import '../services/auth_service.dart';
import '../constants/navigator_key.dart';
import 'login_page.dart';
import '../services/offline_auth_service.dart' as offline_auth;
import '../services/image_upload_service.dart';
import '../services/auto_update_service.dart';
import '../services/finance_local_storage.dart';
import '../utils/formatters.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';
import '../services/home_dashboard_service.dart' show RecentActivityService;
import 'home/home_shell.dart';
import 'home/home_theme.dart';

const String _kGlobalBranchId = 'all';

bool _canAccessDataIntegrity(dynamic rawRole) {
  final role = rawRole?.toString().toLowerCase().trim() ?? '';
  return role.contains('chairman') ||
      role.contains('global admin') ||
      role == 'admin';
}

// ── Category filter enum ──────────────────────────────────────────────────────

enum DashboardCategoryFilter {
  overall,
  office,
  dispensary,
  dasterkhwaan,
  madrassa,
  school,
}

enum _HqUtilityView {
  notifications,
  settings,
}

// ── Page ──────────────────────────────────────────────────────────────────────

class GlobalModularDashboard extends StatefulWidget {
  final Map<String, dynamic> userData;
  const GlobalModularDashboard({super.key, required this.userData});

  @override
  State<GlobalModularDashboard> createState() => _GlobalModularDashboardState();
}

class _GlobalModularDashboardState extends State<GlobalModularDashboard>
    with TickerProviderStateMixin {
  late List<AppModule> _availableModules;
  void refresh() { if (mounted) setState(() {}); }
  
  late Map<String, dynamic> _cachedUserData;
  String _cachedDisplayName = '';
  String _cachedPhotoUrl = '';

  void _updateCachedUserData() {
    _cachedUserData = _resolveFreshUserData();
    _cachedDisplayName = resolveUserDisplayName(_cachedUserData);
    _cachedPhotoUrl = (_cachedUserData['profileImage'] ??
        _cachedUserData['profilePictureUrl'] ??
        _cachedUserData['photoUrl'] ??
        _cachedUserData['avatarUrl'])?.toString() ?? '';
  }

  Map<String, dynamic> _resolveFreshUserData() {
    final data = Map<String, dynamic>.from(widget.userData);
    // A saved copy may hold a stand-in name ("Staff User", the role): it must not replace the
    // real name the login gave, or the header shows the stand-in.
    void merge(Map source) {
      for (final k in source.keys) {
        final v = source[k];
        if (v == null || v == '' || v == 'null') continue;
        final key = k.toString();
        if ((key == 'name' || key == 'displayName' || key == 'fullName') &&
            isStandInUserName(v.toString()) &&
            !isStandInUserName(data[key]?.toString())) {
          continue;
        }
        data[key] = v;
      }
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final cached = Hive.box('app_settings').get('user_data');
        if (cached is Map) merge(cached);
      }
    } catch (_) {}

    final uid = (data['uid'] ?? data['id'])?.toString().trim();
    final email = (data['email'] ?? '').toString().trim().toLowerCase();

    // Fast O(1) keyed lookups only — NEVER do full box scans during build/getters
    if (uid != null && uid.isNotEmpty) {
      final local = LocalStorageService.getLocalUserByUid(uid);
      if (local != null) merge(local);
    }
    if (email.isNotEmpty) {
      final local = LocalStorageService.getLocalUserByEmail(email);
      if (local != null) merge(local);
    }
    return data;
  }

  String get _userName {
    if (_cachedDisplayName.isNotEmpty) return _cachedDisplayName;
    return resolveUserDisplayName(widget.userData);
  }

  String get _userPhotoUrl {
    return _cachedPhotoUrl;
  }

  String get _role {
    String r = (widget.userData['role']?.toString() ?? '').toLowerCase().trim();
    if (r.isNotEmpty && r != 'unknown') return r;

    final email = widget.userData['email']?.toString();
    if (email != null && email.isNotEmpty) {
      try {
        if (Hive.isBoxOpen('local_users')) {
          final user = Hive.box('local_users').get('user:${email.toLowerCase()}');
          if (user != null && user is Map) {
            r = (user['role']?.toString() ?? '').toLowerCase().trim();
            if (r.isNotEmpty && r != 'unknown') return r;
          }
        }
      } catch (_) {}
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final currentUserData = Hive.box('app_settings').get('user_data');
        if (currentUserData != null && currentUserData is Map) {
          r = (currentUserData['role']?.toString() ?? '').toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown') return r;
        }
      }
    } catch (_) {}

    return r.isNotEmpty && r != 'unknown' ? r : 'admin';
  }

  String get _branchId {
    String b = (widget.userData['branchId'] ?? widget.userData['branch'] ?? '').toString().toLowerCase().trim();
    if (b.isNotEmpty && b != 'unknown' && b != 'all' && b != 'global') return b;

    final email = widget.userData['email']?.toString();
    if (email != null && email.isNotEmpty) {
      try {
        if (Hive.isBoxOpen('local_users')) {
          final user = Hive.box('local_users').get('user:${email.toLowerCase()}');
          if (user != null && user is Map) {
            b = (user['branchId'] ?? user['branch'] ?? '').toString().toLowerCase().trim();
            if (b.isNotEmpty && b != 'unknown' && b != 'all' && b != 'global') return b;
          }
        }
      } catch (_) {}
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final currentUserData = box.get('user_data');
        if (currentUserData != null && currentUserData is Map) {
          b = (currentUserData['branchId'] ?? currentUserData['branch'] ?? '').toString().toLowerCase().trim();
          if (b.isNotEmpty && b != 'unknown' && b != 'all' && b != 'global') return b;
        }
        final sel = (box.get('selected_branch') ?? box.get('active_branch_id') ?? box.get('current_branch'))?.toString().toLowerCase().trim() ?? '';
        if (sel.isNotEmpty && sel != 'all' && sel != 'global') return sel;
      }
    } catch (_) {}

    final activeLocal = LocalStorageService.getActiveBranchId()?.toLowerCase().trim();
    if (activeLocal != null && activeLocal.isNotEmpty && activeLocal != 'all' && activeLocal != 'global') {
      return activeLocal;
    }

    return 'karachi';
  }

  DashboardCategoryFilter _selectedCategory = DashboardCategoryFilter.overall;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _searchOpen = false;
  bool _hqRailCollapsed = false;
  bool _sidebarCollapsed = false;
  _HqUtilityView? _hqUtilityView;

  bool get _isHqManager => _role == 'hq manager' || _role == 'hq_manager';
  void _toggleHqRail() => setState(() => _hqRailCollapsed = !_hqRailCollapsed);
  void _toggleSidebar() => setState(() => _sidebarCollapsed = !_sidebarCollapsed);
  void _openHqUtility(_HqUtilityView view) => setState(() => _hqUtilityView = view);

  List<AppModule> _cachedFilteredModules = [];
  Timer? _searchDebounce;

  // ── Animation controllers ─────────────────────────────────────────────────
  late AnimationController _pageEntryCtrl;
  late AnimationController _heroCtrl;
  late AnimationController _sidebarCtrl;
  late AnimationController _searchAnimCtrl;
  late AnimationController _logoPulseCtrl;

  late Animation<double> _pageOpacity;
  late Animation<Offset> _heroSlide;
  late Animation<double> _heroFade;
  late Animation<double> _searchExpand;
  late Animation<double> _logoPulseAnim;

  void _loadAvailableModules() {
    final allModules = ModuleRegistry.getAvailableModules(_role);
    allModules.removeWhere((m) => m.id == 'employee_attendance');
    _availableModules = _isFullExecutive
        ? allModules.where((m) => !m.hideFromExecutives).toList()
        : allModules;
  }

  @override
  void reassemble() {
    super.reassemble();
    _loadAvailableModules();
    _recomputeFilteredModules();
  }

  @override
  void didUpdateWidget(GlobalModularDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateCachedUserData();
    _loadAvailableModules();
    _recomputeFilteredModules();
  }

  @override
  void initState() {
    super.initState();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final saved = Hive.box('app_settings').get('selected_branch')?.toString().trim().toLowerCase();
        // "All Branches" is no longer a branch: an old saved 'all' / 'global' / alias is
        // turned into a real branch (or left unset so the default below applies).
        final real = BranchDirectory.canonical(saved);
        if (real != null) _selectedExecutiveBranch = real;
      }
    } catch (_) {}
    _updateCachedUserData();
    _loadAvailableModules();

    // ── START SYNC SERVICE ────────────────────────────────────────────────────
    final branchId = (widget.userData['branchId'] as String? ?? '').trim();
    if (branchId.isNotEmpty && branchId != _kGlobalBranchId) {
      SyncService().start(branchId);
    } else {
      _startSyncForExecutive();
    }
    // ─────────────────────────────────────────────────────────────────────────

    _pageEntryCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 480));
    _pageOpacity =
        CurvedAnimation(parent: _pageEntryCtrl, curve: Curves.easeOut);

    _heroCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 680));
    _heroSlide =
        Tween<Offset>(begin: const Offset(0, 0.07), end: Offset.zero).animate(
            CurvedAnimation(parent: _heroCtrl, curve: Curves.easeOutCubic));
    _heroFade =
        CurvedAnimation(parent: _heroCtrl, curve: Curves.easeOut);

    _sidebarCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 750));

    _searchAnimCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _searchExpand =
        CurvedAnimation(parent: _searchAnimCtrl, curve: Curves.easeOutCubic);

    _logoPulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _logoPulseAnim = const AlwaysStoppedAnimation<double>(1.0);

    // Staggered entrance
    _pageEntryCtrl.forward();
    Future.delayed(const Duration(milliseconds: 80),
        () { if (mounted) _heroCtrl.forward(); });
    Future.delayed(const Duration(milliseconds: 160),
        () { if (mounted) _sidebarCtrl.forward(); });

    _recomputeFilteredModules();
    if (!kIsWeb && (_isGlobalExecutive || _isFullExecutive)) {
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) _startBackgroundFullSync();
      });
    }

    // Refresh user profile picture and display name across devices in background
    Future.microtask(() async {
      try {
        final uid = (widget.userData['uid'] ?? widget.userData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();
        if (uid.isNotEmpty) {
          final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get().timeout(const Duration(seconds: 5));
          if (doc.exists && doc.data() is Map) {
            final data = Map<String, dynamic>.from(doc.data() as Map);
            final pImg = (data['profileImage'] ?? data['profilePictureUrl'] ?? data['photoUrl'] ?? data['avatarUrl'])?.toString();
            final name = (data['name'] ?? data['displayName'] ?? '').toString();
            if ((pImg != null && pImg.isNotEmpty && pImg != _userPhotoUrl) ||
                (name.isNotEmpty && name != _userName)) {
              if (mounted) {
                setState(() {
                  if (pImg != null && pImg.isNotEmpty) widget.userData['profileImage'] = pImg;
                  if (name.isNotEmpty) widget.userData['name'] = name;
                  // The header reads the cached name; it kept showing the old one until restart.
                  _updateCachedUserData();
                });
                unawaited(LocalStorageService.saveLocalUser(widget.userData));
              }
            }
          }
        }
      } catch (_) {}
    });
  }

  // ── Role helpers ──────────────────────────────────────────────────────────

  bool get _isGlobalExecutive =>
      ['ceo', 'chairman', 'global user'].contains(_role);

  /// Whether the user has toggled dark mode in Settings.
  bool get _userDarkMode => UserThemeService.isDarkMode();

  /// True when the dashboard should render in dark canvas mode.
  bool get _isDark => _userDarkMode;

  bool get _isFullExecutive {
    const execRoles = [
      'admin', 'global admin', 'ceo', 'chairman',
      'global user', 'manager', 'hq manager',
    ];
    return execRoles.contains(_role);
  }

  bool get _isSupervisor => _role == 'supervisor' || _role.contains('supervisor');
  bool get _isBranchManager => _role == 'branch manager';

  /// Categories visible to this role.
  List<DashboardCategoryFilter> get _visibleCategories => DashboardCategoryFilter.values;

  /// Desktop sidebar shows category nav for full-exec/branch-manager,
  /// module tiles for supervisor.
  bool get _sidebarShowsCategories =>
      _isFullExecutive || _isBranchManager;

  bool get _mobileShowsCategoryChips =>
      _isFullExecutive || _isBranchManager;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _pageEntryCtrl.dispose();
    _heroCtrl.dispose();
    _sidebarCtrl.dispose();
    _searchAnimCtrl.dispose();
    _logoPulseCtrl.dispose();
    super.dispose();
  }

  void _recomputeFilteredModules() {
    Iterable<AppModule> filtered = _availableModules;
    if (_selectedCategory != DashboardCategoryFilter.overall) {
      final targetCat = ModuleCategory.values
          .firstWhere((c) => c.name == _selectedCategory.name);
      filtered = filtered.where((m) => m.category == targetCat);
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((m) =>
          m.title.toLowerCase().contains(q) ||
          m.description.toLowerCase().contains(q));
    }
    _cachedFilteredModules = filtered.toList();
  }

  void updateSearchQuery(String query) {
    setState(() {
      _searchQuery = query;
    });
    _recomputeFilteredModules();
  }

  void clearSearch() {
    setState(() {
      _searchCtrl.clear();
      _searchQuery = '';
    });
    _recomputeFilteredModules();
  }

  static bool _hasRunFullBackgroundSync = false;

  Future<void> _startBackgroundFullSync() async {
    if (_hasRunFullBackgroundSync || RoleSimulatorService.isSimulating) return;
    _hasRunFullBackgroundSync = true;
    try {
      final activeBId = (_branchId.isNotEmpty && _branchId != 'all') ? _branchId : 'karachi';
      // Sync only the active branch's essential data instead of downloading all branches simultaneously into memory
      await SyncService().initialFullDownload(activeBId);
      debugPrint('[GlobalModularDashboard] Active branch sync completed for $activeBId.');
    } catch (e) {
      debugPrint('[GlobalModularDashboard] Background sync warning: $e');
    }
  }

  Future<void> _startSyncForExecutive() async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.branchesBox);
      }
      final localBox = Hive.box(LocalStorageService.branchesBox);
      final realIds = <String>[];
      for (final val in localBox.values) {
        if (val is Map) {
          final id = (val['id'] ?? '').toString().trim().toLowerCase();
          final isOff = val['isOffboarded'] == true || val['status'] == 'offboarded';
          if (id.isNotEmpty && id != 'all' && id != 'global' && !isOff) {
            realIds.add(id);
          }
        }
      }
      final effectiveBranch = realIds.isNotEmpty ? realIds.first : 'karachi';
      SyncService().start(effectiveBranch, authorizedBranches: realIds);
      debugPrint('[GlobalModularDashboard] SyncService started for executive on $effectiveBranch (authorized: $realIds)');
    } catch (e) {
      debugPrint('[GlobalModularDashboard] Error starting SyncService for executive: $e');
      SyncService().start('karachi');
    }
  }

  void _logout() async {
    final confirm = await showLogoutDialog(context);
    if (confirm != true || !mounted) return;
    try {
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[GlobalModularDashboard] Logout error: $e');
    }
    try {
      final navCtx = navigatorKey.currentContext;
      if (navCtx != null) {
        Navigator.of(navCtx, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      } else if (mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
    } catch (_) {}
  }

  Future<void> _confirmAndTriggerForceGlobalSync(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.cloud_upload_rounded, color: SoftPalette.emerald350, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Force Global Cloud Sync',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
            ),
          ],
        ),
        content: const Text(
          'This will command ALL connected workstations, staff devices, and local servers across the network to immediately upload any local Hive data that has not yet reached Cloud Firestore.\n\nAre you sure you want to trigger this global sync now?',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.emerald350,
              foregroundColor: SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.bolt_rounded, size: 18),
            label: const Text('Broadcast & Sync Now'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (!mounted) return;
    AppToast.showSnackBar(context, 
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
            ),
            SizedBox(width: 12),
            Text('📡 Broadcasting global sync to all devices & uploading local queue...'),
          ],
        ),
        backgroundColor: SoftPalette.teal550,
        duration: Duration(seconds: 4),
      ),
    );

    try {
      // 1. Broadcast universal force upload across LAN and Firestore cloud to all branches
      await SyncService().broadcastUniversalForceUpload(branchId: _branchId);
      await LocalStorageService.downloadUsers();
      try {
        final todayStr = DateTime.now().toIso8601String().substring(0, 10);
        await FinanceLocalStorage.downloadAttendance(_branchId, specificDateStr: todayStr, force: true);
      } catch (_) {}
      if (mounted) setState(() {});

      if (mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('✅ Global Cloud Sync completed successfully! All nodes notified.'),
            backgroundColor: SoftPalette.emerald350,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('[GlobalSync] Error triggering force sync: $e');
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('⚠️ Sync completed with warning: $e'),
            backgroundColor: SoftPalette.orange350,
          ),
        );
      }
    }
  }



  void _changeCategory(DashboardCategoryFilter cat) {
    setState(() {
      _hqUtilityView = null;
      _selectedCategory = cat;
      _searchCtrl.clear();
      _searchQuery = '';
      _searchDebounce?.cancel();
      _recomputeFilteredModules();
    });
  }

  /// The page a module opens: inside the branch wrapper for wrapped roles,
  /// otherwise its plain builder. Used by the push path (legacy home,
  /// supervisor) and by the redesigned shell, which shows it in place.
  Widget _moduleDestination(AppModule module) {
    const wrappedRoles = [
      'admin', 'global admin', 'ceo', 'chairman',
      'global user', 'manager', 'hq manager',
      'supervisor', 'branch manager',
    ];
    final isWrapped = wrappedRoles.contains(_role);
    final isExec = _isFullExecutive || _isGlobalExecutive;
    final selectedBranch = isExec ? _execBranch : null;
    final moduleUserData = isExec
        ? {
            ...widget.userData,
            'branchId': selectedBranch,
            'branch': selectedBranch,
          }
        : widget.userData;
    return (isWrapped && module.supportsGlobalWrapper)
        ? GlobalModuleWrapper(
            module: module,
            userData: moduleUserData,
            selectedBranchId: selectedBranch,
          )
        : module.builder(context, moduleUserData);
  }

  void _openModule(AppModule module) {
    final dest = _moduleDestination(module);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => dest,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final roleTheme = RoleThemeData.fromString(_role);

    // Guard against Hive lock contention (e.g. two app instances running simultaneously).
    // Extracts the body build into a local closure so it can be called with default
    // or loaded settings, without duplicating scaffold code.
    Widget buildBody(Color? customColor, bool isDark, AppVisualTheme visualTheme) {
      final RoleThemeData t = RoleThemeData.of(roleTheme).withVisualTheme(
        visualTheme,
        customAccent: customColor,
        isDark: isDark,
      );
      return RoleThemeScope(
        role: roleTheme,
        child: Builder(builder: (ctx) {
          final isDesktop = GBreakpoint.isDesktop(ctx);
          if (_isSupervisor) {
            return FadeTransition(
              opacity: _pageOpacity,
              child: _SupervisorScaffold(state: this, t: t),
            );
          }
          if (!_useLegacyHome) {
            return FadeTransition(opacity: _pageOpacity, child: _buildRedesignedHome(ctx, t));
          }
          return FadeTransition(
            opacity: _pageOpacity,
            child: Scaffold(
              backgroundColor: t.bg,
              body: isDesktop
                  ? Row(children: [
                      _isHqManager
                          ? _HqCollapsibleRail(state: this, t: t)
                          : _Sidebar(state: this, t: t),
                      Expanded(child: _MainContent(state: this, t: t, isDesktop: true)),
                    ])
                  : _MobileLayout(state: this, t: t),
            ),
          );
        }),
      );
    }

    if (!Hive.isBoxOpen('app_settings')) {
      // Box not yet open — render with default theme; will rebuild when box opens
      return buildBody(null, false, UserThemeService.defaultVisualTheme);
    }

    return ValueListenableBuilder<bool>(
      valueListenable: UserThemeService.currentThemeNotifier,
      builder: (context, themeVal, child) {
        return ValueListenableBuilder(
          valueListenable: Hive.box('app_settings').listenable(keys: [
            'custom_accent_color',
            'is_dark_mode',
            'visual_theme',
            UserThemeService.getStorageKey(),
            UserThemeService.getVisualThemeKey(),
          ]),
          builder: (context, Box box, child) {
            Color? customColor;
            
            // 1. Try local settings override first
            final localHex = box.get('custom_accent_color') as String?;
            if (localHex != null && localHex.isNotEmpty) {
              try {
                final hex = localHex.replaceAll('#', '');
                customColor = Color(int.parse('FF$hex', radix: 16));
              } catch (_) {}
            }
            
            // 2. Fallback to user metadata preference
            if (customColor == null) {
              final prefColorStr = widget.userData['preferredColor'] as String?;
              if (prefColorStr != null && prefColorStr.isNotEmpty) {
                try {
                  final hex = prefColorStr.replaceAll('#', '');
                  customColor = Color(int.parse('FF$hex', radix: 16));
                } catch (_) {}
              }
            }

            final isDark = UserThemeService.isDarkMode();
            final visualTheme = UserThemeService.getVisualTheme();
            return buildBody(customColor, isDark, visualTheme);
          },
        );
      },
    );
  }

  // ── Redesigned home (gmwf_ui) ───────────────────────────────────────────────

  /// Escape hatch for one release: `app_settings['use_legacy_dashboard'] = true`
  /// brings back the old sidebar and snapshot.
  bool get _useLegacyHome {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        return Hive.box('app_settings').get('use_legacy_dashboard') == true;
      }
    } catch (_) {}
    return false;
  }

  String? _selectedExecutiveBranch;

  /// Real branches only (user rule 2026-11-21): "All Branches" is a filter/tab inside a
  /// screen, never a branch in this picker; no 'global' / 'main' / duplicates / camps.
  List<Map<String, String>> get _availableBranchesForExecutive {
    if (!(_isFullExecutive || _isGlobalExecutive)) return const [];
    return BranchDirectory.list();
  }

  /// The branch an executive is looking at: their pick, else their own branch, else the
  /// first real branch. Never 'all'.
  String get _execBranch {
    final picked = BranchDirectory.canonical(_selectedExecutiveBranch);
    if (picked != null) return picked;
    final own = BranchDirectory.canonical(widget.userData['branchId']?.toString()) ??
        BranchDirectory.canonical(_branchId);
    if (own != null) return own;
    final list = BranchDirectory.list();
    return list.isNotEmpty ? list.first['id']! : 'karachi';
  }

  void _onExecutiveBranchChanged(String newBranchId) async {
    final effective = BranchDirectory.canonical(newBranchId) ?? _execBranch;
    setState(() {
      _selectedExecutiveBranch = effective;
      widget.userData['branchId'] = effective;
      widget.userData['branch'] = effective;
    });
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.put('selected_branch', effective);
        await box.put('current_branch', effective);
      }
      SyncService().start(effective);
    } catch (_) {}
  }

  String get _branchLabel {
    if (_isFullExecutive || _isGlobalExecutive) {
      return RecentActivityService.resolveBranchName(_execBranch);
    }
    return RecentActivityService.resolveBranchName(_branchId);
  }

  bool get _showNotifications {
    final r = (widget.userData['role'] ?? '').toString().toLowerCase();
    return !(r.contains('madrassa') || r.contains('guardian') || r.contains('parent') || r == 'teacher');
  }

  Widget _buildRedesignedHome(BuildContext ctx, RoleThemeData t) {
    final role = widget.userData['role']?.toString();
    return HomeThemeScope(
      userData: widget.userData,
      child: HomeShell(
        userData: widget.userData,
        userName: _userName,
        photoUrl: _userPhotoUrl,
        role: _role,
        branchLabel: _branchLabel,
        version: AutoUpdateService.resolvedVersion,
        modules: _availableModules,
        legacyTheme: Theme.of(ctx),
        showNotifications: _showNotifications,
        moduleBuilder: _moduleDestination,
        availableBranches: (_isFullExecutive || _isGlobalExecutive) ? _availableBranchesForExecutive : null,
        selectedBranchId: (_isFullExecutive || _isGlobalExecutive)
            ? _execBranch
            : (_branchId.isNotEmpty && _branchId != 'all' ? _branchId : 'all'),
        onBranchChanged: _onExecutiveBranchChanged,
        onLogout: _logout,
        onEditPhoto: () => _showEnlargedAvatarDialog(context, this, t),
        onSupport: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportPage())),
        onForceSync: (_isFullExecutive || _isGlobalExecutive) ? () => _confirmAndTriggerForceGlobalSync(context) : null,
        onRoleSimulator: RoleSimulatorService.canAccessSimulator(role)
            ? () => RoleSimulatorService.showRoleSelectorModal(context)
            : null,
        onDataIntegrity: _canAccessDataIntegrity(role)
            ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DataCleanupScreen()))
            : null,
      ),
    );
  }

  int _supervisorNavIndex = 0;
  void setSupervisorTab(int idx) {
    if (mounted) setState(() => _supervisorNavIndex = idx);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Supervisor Scaffold & Navigation Hub (No Sidebar + Bottom Nav Bar)
// ═══════════════════════════════════════════════════════════════════════════════

class _SupervisorScaffold extends StatefulWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;

  const _SupervisorScaffold({required this.state, required this.t});

  @override
  State<_SupervisorScaffold> createState() => _SupervisorScaffoldState();
}

class _SupervisorScaffoldState extends State<_SupervisorScaffold> {
  final GlobalKey _supervisorBellKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    NotificationBellHelper.ensureInitialized(branchId: widget.state._branchId);
  }

  AppModule _getModule(String id) {
    return widget.state._availableModules.firstWhere(
      (m) => m.id == id,
      orElse: () => ModuleRegistry.allModules.firstWhere((m) => m.id == id),
    );
  }

  String _getSupervisorTabTitle(int idx) {
    switch (idx) {
      case 1:
        return 'Branch Summary';
      case 2:
        return 'Dispensary Inventory';
      case 3:
        return 'Pending Requests';
      case 4:
        return 'Inventory Ledger';
      case 5:
        return 'Account';
      case 0:
      default:
        return 'Supervisor Portal';
    }
  }

  String _getSupervisorTabSubtitle(int idx, String userName, String branchName) {
    switch (idx) {
      case 1:
        return '$userName • $branchName Summary & Records';
      case 2:
        return '$userName • $branchName Stock';
      case 3:
        return '$userName • $branchName Approvals';
      case 4:
        return '$userName • $branchName Audit Log';
      case 5:
        return '$userName • Account & Settings';
      case 0:
      default:
        return '$userName • Dispensary Operations';
    }
  }

  Widget _buildSupervisorActiveTab(int idx, BuildContext context, Map<String, dynamic> resolvedUserData) {
    switch (idx) {
      case 1:
        return _getModule('branches').builder(context, resolvedUserData);
      case 2:
        return _getModule('inventory').builder(context, resolvedUserData);
      case 3:
        return _getModule('pending_requests').builder(context, resolvedUserData);
      case 4:
        return _getModule('inventory_ledger').builder(context, resolvedUserData);
      case 5:
        return SettingsPage(userData: resolvedUserData);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final navIndex = widget.state._supervisorNavIndex;
    final isDark = widget.t.isDarkCanvas || widget.state._isDark;
    final t = widget.t;
    final branchName = widget.state._branchId.toUpperCase();
    final userName = widget.state._userName;

    final resolvedUserData = {
      ...widget.state.widget.userData,
      'branchId': widget.state._branchId,
    };

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bgCard,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        titleSpacing: 16,
        toolbarHeight: 64,
        title: Row(
          children: [
            _LogoPulse(accent: t.accent, pulseAnim: widget.state._logoPulseAnim, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _getSupervisorTabTitle(navIndex),
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900,
                      color: t.textPrimary,
                      letterSpacing: -0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1.5),
                  Text(
                    _getSupervisorTabSubtitle(navIndex, userName, branchName),
                    style: TextStyle(
                      fontSize: 11,
                      color: t.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: NotificationBellHelper.buildCombinedListenable(),
            builder: (context, _) {
              final bId = widget.state._branchId;
              final uId = (widget.state.widget.userData['uid'] ??
                      widget.state.widget.userData['id'] ??
                      'supervisor')
                  .toString();
              final pendingReqs = NotificationBellHelper.getPendingRequests(
                branchId: bId,
                role: 'supervisor',
              );
              final unreadMsgs = NotificationBellHelper.getUnreadNotifications(
                branchId: bId,
                userId: uId,
                role: 'supervisor',
              );
              final totalBadge = pendingReqs.length + unreadMsgs.length;
              return IconButton(
                key: _supervisorBellKey,
                tooltip: totalBadge > 0
                    ? 'Notifications & Requests ($totalBadge pending)'
                    : 'Notifications & Requests',
                onPressed: () => NotificationBellHelper.showBellPopover(
                  context: context,
                  bellKey: _supervisorBellKey,
                  branchId: bId,
                  userId: uId,
                  role: 'supervisor',
                  onSelectRequest: (req) {
                    RequestPage.focusRequest((req['requestId'] ?? req['id'])?.toString());
                    widget.state.setSupervisorTab(3);
                  },
                  onViewAllRequests: () {
                    RequestPage.focusRequest(null);
                    widget.state.setSupervisorTab(3);
                  },
                ),
                icon: Badge(
                  isLabelVisible: totalBadge > 0,
                  backgroundColor: SoftPalette.orange400,
                  label: Text(
                    totalBadge > 99 ? '99+' : '$totalBadge',
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: SoftPalette.gray50,
                    ),
                  ),
                  child: Icon(
                    totalBadge > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_outlined,
                    color: totalBadge > 0 ? t.accent : t.textSecondary,
                    size: 21,
                  ),
                ),
              );
            },
          ),
          // Toggle Dark & Light Mode Button
          IconButton(
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? SoftPalette.brightGold : t.textSecondary,
              size: 20,
            ),
            onPressed: () async {
              await UserThemeService.toggleDarkMode();
              widget.state.refresh();
            },
          ),
          IconButton(
            tooltip: 'Sign Out',
            icon: Icon(
              Icons.logout_rounded,
              color: isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
              size: 20,
            ),
            onPressed: widget.state._logout,
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            color: t.bgRule,
          ),
        ),
      ),
      body: Builder(
        builder: (ctx) {
          final curIdx = navIndex.clamp(0, 5);
          return IndexedStack(
            index: curIdx == 0 ? 0 : 1,
            children: [
              // Hidden home hub keeps its state but must not keep animating (CPU on low-end PCs).
              TickerMode(enabled: curIdx == 0, child: _SupervisorHomeHub(state: widget.state, t: t)),
              if (curIdx != 0)
                KeyedSubtree(
                  key: ValueKey('supervisor_tab_$curIdx'),
                  child: _buildSupervisorActiveTab(curIdx, context, resolvedUserData),
                )
              else
                const SizedBox.shrink(),
            ],
          );
        },
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: t.bgCard,
          boxShadow: [
            BoxShadow(
              color: SoftPalette.gray900.withValues(alpha: isDark ? 0.35 : 0.05),
              blurRadius: 14,
              offset: const Offset(0, -2),
            ),
          ],
          border: Border(
            top: BorderSide(
              color: t.bgRule,
              width: 1,
            ),
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SupervisorNavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  isSelected: navIndex == 0,
                  accentColor: t.accent,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(0),
                ),
                _SupervisorNavItem(
                  icon: Icons.dashboard_rounded,
                  label: 'Summary',
                  isSelected: navIndex == 1,
                  accentColor: isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(1),
                ),
                _SupervisorNavItem(
                  icon: Icons.inventory_2_rounded,
                  label: 'Inventory',
                  isSelected: navIndex == 2,
                  accentColor: isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(2),
                ),
                _SupervisorNavItem(
                  icon: Icons.rule_rounded,
                  label: 'Requests',
                  isSelected: navIndex == 3,
                  accentColor: isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(3),
                ),
                _SupervisorNavItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Report',
                  isSelected: navIndex == 4,
                  accentColor: isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(4),
                ),
                _SupervisorNavItem(
                  icon: Icons.person_rounded,
                  label: 'Account',
                  isSelected: navIndex == 5,
                  accentColor: isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan,
                  isDark: isDark,
                  t: t,
                  onTap: () => widget.state.setSupervisorTab(5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SupervisorNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final Color accentColor;
  final bool isDark;
  final RoleThemeData t;
  final VoidCallback onTap;

  const _SupervisorNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.accentColor,
    required this.isDark,
    required this.t,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isSelected ? accentColor.withValues(alpha: isDark ? 0.18 : 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected ? accentColor : t.textSecondary,
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                      color: isSelected ? accentColor : t.textSecondary,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SupervisorHomeHub extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;

  const _SupervisorHomeHub({required this.state, required this.t});

  bool get _isTopBranch {
    final ud = state.widget.userData;
    if (ud['isTopBranch'] == true || ud['isBestBranch'] == true || ud['topBranch'] == true || ud['topPerformingBranch'] == true) {
      return true;
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        if (box.get('is_top_branch') == true) return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = t.isDarkCanvas || state._isDark;
    final branchName = state._branchId.toUpperCase();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 750;
        final double hPad = isWide ? 32 : 16;

          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Global Dashboard Hero
                _HeroHeader(state: state, t: t, isDesktop: isWide),
                const SizedBox(height: 16),

                // 2. Congratulatory Top Performing Branch Banner (only shown if top branch)
                if (_isTopBranch) ...[
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    child: _buildCongratulatoryBanner(branchName),
                  ),
                  const SizedBox(height: 18),
                ],

                // 3. Navigation Action Buttons (Summary, Inventory, Requests, Ledger, Settings)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: hPad),
                  child: LayoutBuilder(
                    builder: (context, boxConstraints) {
                      final maxWidth = boxConstraints.maxWidth;
                      // On wide desktop (>= 980px), show all 5 modules in 1 row (5 columns)
                      final bool isDesktopRow = maxWidth >= 980;
                      final int crossCount = isDesktopRow ? 5 : (maxWidth >= 640 ? 2 : 1);
                      final double itemExtent = isDesktopRow ? 144.0 : 80.0;

                      final buttons = _buildModuleButtons(context, isDark, isDesktopRow);

                      return GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossCount,
                          mainAxisExtent: itemExtent,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: buttons.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemBuilder: (context, idx) => buttons[idx],
                      );
                    },
                  ),
                ),

                const SizedBox(height: 36),
              ],
            ),
          );
        },
      );
  }

  Widget _buildCongratulatoryBanner(String branch) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            SoftPalette.orange400,
            SoftPalette.amber300,
            SoftPalette.orange500,
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.amber300.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: SoftPalette.gray50.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
            child: const Text('🏆', style: TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TOP PERFORMING BRANCH!',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: SoftPalette.gray50,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Congratulations! $branch is leading operational efficiency and patient throughput across GMWF healthcare centers.',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: SoftPalette.gray50.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildModuleButtons(BuildContext context, bool isDark, bool isDesktopRow) {
    return [
      _SupervisorModuleCard(
        context: context,
        title: 'Summary & Overview',
        subtitle: 'Live token queue, prescriptions status, and dispensary stats',
        icon: Icons.dashboard_rounded,
        gradient: [
          isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
          isDark ? SoftPalette.softIndigo : SoftPalette.luminousIndigo,
        ],
        badgeText: 'Live Queue',
        isDark: isDark,
        isVertical: isDesktopRow,
        t: t,
        onTap: () => state.setSupervisorTab(1),
      ),
      _SupervisorModuleCard(
        context: context,
        title: 'Medicine Inventory',
        subtitle: 'Track clinical stock levels, batch updates & stock adjustments',
        icon: Icons.inventory_2_rounded,
        gradient: [
          isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
          isDark ? SoftPalette.emerald350 : SoftPalette.teal600,
        ],
        badgeText: 'Stock In/Out',
        isDark: isDark,
        isVertical: isDesktopRow,
        t: t,
        onTap: () => state.setSupervisorTab(2),
      ),
      _SupervisorModuleCard(
        context: context,
        title: 'Requests & Approvals',
        subtitle: 'Review and approve supervisor token exceptions and void requests',
        icon: Icons.rule_rounded,
        gradient: [
          isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
          SoftPalette.orange400,
        ],
        badgeText: 'Approvals',
        isDark: isDark,
        isVertical: isDesktopRow,
        t: t,
        onTap: () => state.setSupervisorTab(3),
      ),
      _SupervisorModuleCard(
        context: context,
        title: 'Medicine Stock Ledger',
        subtitle: 'Complete registers of medicine consumption & category records',
        icon: Icons.receipt_long_rounded,
        gradient: [
          isDark ? SoftPalette.softLavender : SoftPalette.royalViolet,
          isDark ? SoftPalette.brightOrchid : SoftPalette.plumOrchid,
        ],
        badgeText: 'Consumption',
        isDark: isDark,
        isVertical: isDesktopRow,
        t: t,
        onTap: () => state.setSupervisorTab(4),
      ),
      _SupervisorModuleCard(
        context: context,
        title: 'Account & Preferences',
        subtitle: 'User profile, app preferences, dark mode & password',
        icon: Icons.person_rounded,
        gradient: [
          isDark ? SoftPalette.brightCyan : SoftPalette.deepCyan,
          isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
        ],
        badgeText: 'Account',
        isDark: isDark,
        isVertical: isDesktopRow,
        t: t,
        onTap: () => state.setSupervisorTab(5),
      ),
    ];
  }
}

class _SupervisorModuleCard extends StatefulWidget {
  final BuildContext context;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> gradient;
  final String badgeText;
  final bool isDark;
  final bool isVertical;
  final RoleThemeData t;
  final VoidCallback onTap;

  const _SupervisorModuleCard({
    required this.context,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.badgeText,
    required this.isDark,
    required this.isVertical,
    required this.t,
    required this.onTap,
  });

  @override
  State<_SupervisorModuleCard> createState() => _SupervisorModuleCardState();
}

class _SupervisorModuleCardState extends State<_SupervisorModuleCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final primaryColor = widget.gradient.first;
    final t = widget.t;
    final isDark = t.isDarkCanvas || widget.isDark;

    if (widget.isVertical) {
      // ── Desktop 5-Across Vertical Tile ──
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.bgCard,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  t.bgCard,
                  Color.alphaBlend(primaryColor.withValues(alpha: isDark ? 0.08 : 0.03), t.bgCard),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _isHovered
                    ? primaryColor.withValues(alpha: isDark ? 0.72 : 0.55)
                    : t.bgRule,
                width: _isHovered ? 1.5 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? primaryColor.withValues(alpha: isDark ? 0.28 : 0.16)
                      : (isDark
                          ? SoftPalette.gray900.withValues(alpha: 0.25)
                          : primaryColor.withValues(alpha: 0.06)),
                  blurRadius: _isHovered ? 16 : 8,
                  offset: Offset(0, _isHovered ? 6 : 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Top Row: Squircle Icon + Badge
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: widget.gradient,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: primaryColor.withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(widget.icon, color: SoftPalette.pureWhiteSoft, size: 20),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: isDark ? 0.22 : 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: isDark ? 0.42 : 0.28),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        widget.badgeText,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: primaryColor,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Middle: Title & Subtitle
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                        letterSpacing: -0.2,
                        height: 1.15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: t.textSecondary,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                // Bottom row: Interactive link / arrow
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AnimatedSlide(
                      duration: const Duration(milliseconds: 180),
                      offset: Offset(_isHovered ? 0.15 : 0, 0),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: _isHovered ? primaryColor : t.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      // ── Stacked Mobile & Tablet Horizontal Card ──
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.bgCard,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  t.bgCard,
                  Color.alphaBlend(primaryColor.withValues(alpha: isDark ? 0.08 : 0.03), t.bgCard),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isHovered
                    ? primaryColor.withValues(alpha: isDark ? 0.72 : 0.55)
                    : t.bgRule,
                width: _isHovered ? 1.5 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? primaryColor.withValues(alpha: isDark ? 0.25 : 0.14)
                      : (isDark
                          ? SoftPalette.gray900.withValues(alpha: 0.20)
                          : primaryColor.withValues(alpha: 0.05)),
                  blurRadius: _isHovered ? 12 : 6,
                  offset: Offset(0, _isHovered ? 4 : 2),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.gradient,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(widget.icon, color: SoftPalette.pureWhiteSoft, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.title,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                color: t.textPrimary,
                                letterSpacing: -0.2,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: isDark ? 0.22 : 0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: primaryColor.withValues(alpha: isDark ? 0.42 : 0.28),
                                width: 0.6,
                              ),
                            ),
                            child: Text(
                              widget.badgeText,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: primaryColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: t.textSecondary,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _isHovered
                        ? primaryColor
                        : primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: _isHovered ? SoftPalette.pureWhiteSoft : primaryColor,
                      size: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sidebar  (desktop)
// ═══════════════════════════════════════════════════════════════════════════════

class _Sidebar extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  const _Sidebar({required this.state, required this.t});

  bool get _dark => t.isDarkSidebar || t.isDarkCanvas || state._isDark;
  Color get _divider => t.sidebarBorder;
  Color get _muted => t.sidebarText;

  @override
  Widget build(BuildContext context) {
    final collapsed = state._sidebarCollapsed;
    return AnimatedBuilder(
      animation: state._sidebarCtrl,
      builder: (ctx, _) => FadeTransition(
        opacity: state._sidebarCtrl,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(-0.05, 0), end: Offset.zero)
              .animate(CurvedAnimation(
                  parent: state._sidebarCtrl,
                  curve: Curves.easeOutCubic)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: collapsed ? 72.0 : 260.0,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: t.sidebarBorder,
                  width: 1.2,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: _dark ? 0.12 : 0.05),
                  blurRadius: 28,
                  offset: const Offset(6, 0),
                ),
                BoxShadow(
                  color: SoftPalette.gray900.withValues(alpha: _dark ? 0.35 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(2, 0),
                ),
              ],
            ),
            // No BackdropFilter: a full-height sigma-24 blur re-rendered on every frame pinned
            // the HD 520 GPU; the near-opaque gradient below looks the same without it.
            child: ClipRect(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        t.sidebarBg,
                        t.sidebarBgSecondary,
                      ],
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Top-Left Ambient Theme Glow
                      Positioned(
                        top: -50,
                        left: -50,
                        width: 200,
                        height: 200,
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  t.accent.withValues(alpha: _dark ? 0.24 : 0.12),
                                  t.accent.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Bottom-Right Secondary Glow
                      Positioned(
                        bottom: -40,
                        right: -40,
                        width: 180,
                        height: 180,
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  t.chartBar2.withValues(alpha: _dark ? 0.16 : 0.08),
                                  t.chartBar2.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Sidebar Layout
                      collapsed
                          ? Column(
                              children: [
                                const SizedBox(height: 18),
                                Tooltip(
                                  message: 'Expand Sidebar',
                                  child: IconButton(
                                    onPressed: state._toggleSidebar,
                                    icon: Icon(
                                      Icons.keyboard_double_arrow_right_rounded,
                                      color: t.accent,
                                      size: 22,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Divider(color: _divider, height: 1),
                                ),
                                const Spacer(),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Divider(color: _divider, height: 1),
                                ),
                                const SizedBox(height: 8),
                                Tooltip(
                                  message: 'Expand Sidebar',
                                  child: IconButton(
                                    onPressed: state._toggleSidebar,
                                    icon: Icon(
                                      Icons.chevron_right_rounded,
                                      color: _muted,
                                      size: 22,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _SidebarBrand(state: state, t: t, dark: _dark),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: SingleChildScrollView(
                                    physics: const BouncingScrollPhysics(),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        _buildNav(context),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                  child: Divider(color: _divider, height: 1),
                                ),
                                _SidebarActions(state: state, t: t, dark: _dark),
                              ],
                            ),
                    ],
                  ),
                ),
            ),
            ),
          ),
        ),
    );
  }

  Widget _buildNav(BuildContext context) {
    // ── Supervisor: module tiles ─────────────────────────────────────────────
    if (state._isSupervisor) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
            child: _NavLabel(label: 'MY MODULES', muted: _muted),
          ),
          ...state._availableModules.asMap().entries.map((e) => _AnimatedEntry(
                index: e.key,
                ctrl: state._sidebarCtrl,
                child: _SidebarModuleTile(
                  module: e.value,
                  t: t,
                  dark: _dark,
                  onTap: () => state._openModule(e.value),
                ),
              )),
        ],
      );
    }

    // ── Full exec / branch manager: category nav ─────────────────────────────
    if (state._sidebarShowsCategories) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
            child: _NavLabel(label: 'NAVIGATION', muted: _muted),
          ),
          ...state._visibleCategories.asMap().entries.map((e) =>
              _AnimatedEntry(
                index: e.key,
                ctrl: state._sidebarCtrl,
                child: _SidebarCatItem(
                  cat: e.value,
                  selected: state._selectedCategory == e.value,
                  t: t,
                  dark: _dark,
                  onTap: () => state._changeCategory(e.value),
                ),
              )),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

// ── Unified Executive Profile Glass Card at top of Sidebar ───────────────────

class _SidebarBrand extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool dark;
  const _SidebarBrand(
      {required this.state, required this.t, required this.dark});

  @override
  Widget build(BuildContext context) {
    final isChairman = state._role == 'chairman';
    final isCeo = state._role == 'ceo';
    final onlineColor = dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final accentInk = dark ? GColor.accentOnDark(t.accent) : t.accent;
    final rolePillColor = (isChairman || isCeo)
        ? (dark ? SoftPalette.brightGold : SoftPalette.warmMarigold)
        : accentInk;
    final cardSurface = dark
        ? Color.alphaBlend(t.accent.withValues(alpha: 0.10), t.sidebarBgSecondary)
        : t.bgCard;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? t.sidebarBorder : t.bgRule,
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: dark ? 0.25 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo + Organization Header
          Row(
            children: [
              _LogoPulse(accent: t.accent, pulseAnim: state._logoPulseAnim, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GMWF',
                      style: TextStyle(
                        color: dark ? t.sidebarTextActive : t.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        letterSpacing: 1.0,
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          'Enterprise ERP',
                          style: TextStyle(
                            color: t.sidebarText,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: onlineColor.withValues(alpha: dark ? 0.20 : 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: onlineColor.withValues(alpha: 0.40), width: 0.8),
                          ),
                          child: Text(
                            'Online',
                            style: TextStyle(
                              color: onlineColor,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Divider rule inside card
          Container(
            height: 1,
            color: t.sidebarBorder,
          ),
          const SizedBox(height: 10),
          // User Role Pill & Full Name
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      rolePillColor.withValues(alpha: dark ? 0.28 : 0.16),
                      rolePillColor.withValues(alpha: dark ? 0.14 : 0.08),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: rolePillColor.withValues(alpha: dark ? 0.45 : 0.35),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (isChairman || isCeo) ? Icons.workspace_premium_rounded : Icons.verified_user_rounded,
                      size: 10,
                      color: rolePillColor,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      state._role.toUpperCase(),
                      style: TextStyle(
                        color: rolePillColor,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                'v${AutoUpdateService.resolvedVersion}',
                style: TextStyle(
                  color: t.sidebarText.withValues(alpha: 0.78),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            state._userName,
            style: TextStyle(
              color: dark ? t.sidebarTextActive : t.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
            softWrap: true,
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}

// ── Sidebar bottom actions ────────────────────────────────────────────────────

class _SidebarActions extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool dark;
  const _SidebarActions(
      {required this.state, required this.t, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
      child: Column(children: [
        if (RoleSimulatorService.canAccessSimulator(state.widget.userData['role']?.toString()))
          _ActionTile(
            icon: Icons.preview_rounded,
            label: 'Role Simulator',
            accentColor: dark ? SoftPalette.softLavender : SoftPalette.royalViolet,
            t: t,
            dark: dark,
            onTap: () => RoleSimulatorService.showRoleSelectorModal(context),
          ),
        if (!((state.widget.userData['role'] ?? '').toString().toLowerCase().contains('madrassa') ||
              (state.widget.userData['role'] ?? '').toString().toLowerCase().contains('guardian') ||
              (state.widget.userData['role'] ?? '').toString().toLowerCase().contains('parent') ||
              (state.widget.userData['role'] ?? '').toString().toLowerCase() == 'teacher'))
          _ActionTile(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            accentColor: dark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
            t: t,
            dark: dark,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NotificationScreen(
                  branchId: (state.widget.userData['branchId'] ?? 'all').toString(),
                  userId: (state.widget.userData['uid'] ?? state.widget.userData['id'] ?? 'user').toString(),
                  role: (state.widget.userData['role'] ?? 'admin').toString(),
                ),
              ),
            ),
          ),
        if (state._isFullExecutive || state._isGlobalExecutive)
          _ActionTile(
            icon: Icons.cloud_upload_rounded,
            label: 'Force Global Sync',
            accentColor: dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
            t: t,
            dark: dark,
            onTap: () => state._confirmAndTriggerForceGlobalSync(context),
          ),
        _ActionTile(
          icon: Icons.settings_outlined,
          label: 'Settings',
          accentColor: dark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
          t: t,
          dark: dark,
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      SettingsPage(userData: state.widget.userData))).then((_) {
            state.refresh();
          }),
        ),
        if (_canAccessDataIntegrity(state.widget.userData['role']))
          _ActionTile(
            icon: Icons.cleaning_services_outlined,
            label: 'Data Integrity',
            accentColor: dark ? SoftPalette.brightCyan : SoftPalette.deepCyan,
            t: t,
            dark: dark,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DataCleanupScreen()),
            ),
          ),
        _ActionTile(
          icon: Icons.help_outline_rounded,
          label: 'Support',
          accentColor: dark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
          t: t,
          dark: dark,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SupportPage())),
        ),
        _ActionTile(
          icon: Icons.chevron_left_rounded,
          label: 'Collapse Sidebar',
          accentColor: t.accent,
          t: t,
          dark: dark,
          onTap: state._toggleSidebar,
        ),
      ]),
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _NavLabel extends StatelessWidget {
  final String label;
  final Color muted;
  const _NavLabel({required this.label, required this.muted});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            color: muted,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      );
}

// ── Staggered entry wrapper ───────────────────────────────────────────────────

class _AnimatedEntry extends StatelessWidget {
  final int index;
  final AnimationController ctrl;
  final Widget child;
  const _AnimatedEntry(
      {required this.index, required this.ctrl, required this.child});

  @override
  Widget build(BuildContext context) {
    final start = (index * 0.07).clamp(0.0, 0.65);
    final end = (start + 0.35).clamp(0.0, 1.0);
    final anim = CurvedAnimation(
        parent: ctrl,
        curve: Interval(start, end, curve: Curves.easeOutCubic));
    return AnimatedBuilder(
      animation: anim,
      builder: (ctx, ch) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(-0.08, 0), end: Offset.zero)
              .animate(anim),
          child: ch,
        ),
      ),
      child: child,
    );
  }
}

// ── Logo pulse ────────────────────────────────────────────────────────────────

class _LogoPulse extends StatelessWidget {
  final Color accent;
  final Animation<double>? pulseAnim;
  final double size;
  const _LogoPulse({required this.accent, this.pulseAnim, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            SoftPalette.gray50,
            SoftPalette.slate100,
          ],
        ),
        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.9), width: 1.0),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(4),
      child: Image.asset(
        'assets/logo/gmwf-1.webp',
        cacheWidth: 200,
        fit: BoxFit.contain,
      ),
    );
  }
}

// ── Category colors map for vibrant distinct badges ──────────────────────────

Color _getCatColor(DashboardCategoryFilter cat, {bool dark = false}) {
  switch (cat) {
    case DashboardCategoryFilter.overall:
      return dark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;
    case DashboardCategoryFilter.office:
      return dark ? SoftPalette.softLavender : SoftPalette.royalViolet;
    case DashboardCategoryFilter.dispensary:
      return dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    case DashboardCategoryFilter.dasterkhwaan:
      return dark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
    case DashboardCategoryFilter.madrassa:
      return dark ? SoftPalette.brightCoral : SoftPalette.roseCoral;
    case DashboardCategoryFilter.school:
      return dark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
  }
}

// ── Sidebar category item ─────────────────────────────────────────────────────

class _SidebarCatItem extends StatefulWidget {
  final DashboardCategoryFilter cat;
  final bool selected;
  final RoleThemeData t;
  final bool dark;
  final VoidCallback onTap;
  const _SidebarCatItem({
    required this.cat,
    required this.selected,
    required this.t,
    required this.dark,
    required this.onTap,
  });

  @override
  State<_SidebarCatItem> createState() => _SidebarCatItemState();
}

class _SidebarCatItemState extends State<_SidebarCatItem> {
  bool _hov = false;

  static const _icons = {
    DashboardCategoryFilter.overall: Icons.home_rounded,
    DashboardCategoryFilter.office: Icons.business_center_rounded,
    DashboardCategoryFilter.dispensary: Icons.local_hospital_rounded,
    DashboardCategoryFilter.dasterkhwaan: Icons.volunteer_activism_rounded,
    DashboardCategoryFilter.madrassa: Icons.auto_stories_rounded,
    DashboardCategoryFilter.school: Icons.school_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final dark = widget.dark;
    final t = widget.t;
    final catColor = widget.cat == DashboardCategoryFilter.overall
        ? (dark ? GColor.accentOnDark(t.accent) : t.accent)
        : _getCatColor(widget.cat, dark: dark);
    final activeBarColor = widget.cat == DashboardCategoryFilter.overall
        ? t.sidebarActiveLine
        : catColor;
    final label = widget.cat == DashboardCategoryFilter.overall
        ? 'Dashboard'
        : widget.cat.name[0].toUpperCase() + widget.cat.name.substring(1);

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7.5),
          decoration: BoxDecoration(
            color: sel
                ? (widget.cat == DashboardCategoryFilter.overall
                    ? t.sidebarActiveBg
                    : Color.alphaBlend(
                        catColor.withValues(alpha: dark ? 0.22 : 0.14),
                        t.sidebarBg,
                      ))
                : (_hov
                    ? (dark ? t.sidebarTextActive.withValues(alpha: 0.08) : catColor.withValues(alpha: 0.08))
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: sel
                  ? catColor.withValues(alpha: dark ? 0.52 : 0.42)
                  : (_hov
                      ? (dark ? t.sidebarTextActive.withValues(alpha: 0.14) : catColor.withValues(alpha: 0.22))
                      : Colors.transparent),
              width: 1.0,
            ),
            boxShadow: sel
                ? [
                    BoxShadow(
                      color: catColor.withValues(alpha: dark ? 0.22 : 0.14),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [],
          ),
          child: Row(children: [
            // Left active indicator pill
            if (sel)
              Container(
                width: 3.5,
                height: 16,
                margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(
                  color: activeBarColor,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: activeBarColor.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),

            // Squircle Micro Badge
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: sel
                    ? LinearGradient(
                        colors: [catColor, catColor.withValues(alpha: 0.85)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: !sel
                    ? (dark
                        ? t.sidebarBgSecondary
                        : catColor.withValues(alpha: 0.11))
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sel
                      ? SoftPalette.pureWhiteSoft.withValues(alpha: 0.35)
                      : (dark ? t.sidebarBorder : catColor.withValues(alpha: 0.22)),
                  width: 0.8,
                ),
                boxShadow: sel
                    ? [
                        BoxShadow(
                          color: catColor.withValues(alpha: 0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                _icons[widget.cat] ?? Icons.circle_outlined,
                color: sel
                    ? SoftPalette.pureWhiteSoft
                    : catColor,
                size: 15,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: sel
                      ? (dark ? t.sidebarTextActive : catColor)
                      : (_hov
                          ? (dark ? t.sidebarTextActive : t.textPrimary)
                          : t.sidebarText),
                  fontWeight: sel ? FontWeight.w900 : FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            if (sel)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: activeBarColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: activeBarColor.withValues(alpha: 0.6),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

// ── Sidebar module tile (supervisor) ─────────────────────────────────────────

class _SidebarModuleTile extends StatefulWidget {
  final AppModule module;
  final RoleThemeData t;
  final bool dark;
  final VoidCallback onTap;
  const _SidebarModuleTile({
    required this.module,
    required this.t,
    required this.dark,
    required this.onTap,
  });

  @override
  State<_SidebarModuleTile> createState() => _SidebarModuleTileState();
}

class _SidebarModuleTileState extends State<_SidebarModuleTile> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final dark = widget.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _hov
                ? t.accent.withValues(alpha: dark ? 0.18 : 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hov
                  ? t.accent.withValues(alpha: dark ? 0.40 : 0.25)
                  : Colors.transparent,
              width: 1.0,
            ),
          ),
          child: Row(children: [
            // Squircle Micro-Badge
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                gradient: _hov ? t.accentGradient : null,
                color: !_hov
                    ? (dark ? t.sidebarBgSecondary : t.accent.withValues(alpha: 0.08))
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _hov ? SoftPalette.pureWhiteSoft.withValues(alpha: 0.3) : Colors.transparent,
                  width: 0.8,
                ),
                boxShadow: _hov
                    ? [
                        BoxShadow(
                          color: t.accent.withValues(alpha: 0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                widget.module.icon,
                color: _hov
                    ? SoftPalette.pureWhiteSoft
                    : t.sidebarText,
                size: 15,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                widget.module.title,
                style: TextStyle(
                  color: _hov
                      ? (dark ? t.sidebarTextActive : t.textPrimary)
                      : t.sidebarText,
                  fontWeight: _hov ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AnimatedOpacity(
              opacity: _hov ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: t.accent.withValues(alpha: 0.15),
                ),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: t.accent,
                  size: 12,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Sidebar action tile ───────────────────────────────────────────────────────

class _ActionTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color? accentColor;
  final RoleThemeData t;
  final bool dark;
  final bool danger;
  final VoidCallback onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    this.accentColor,
    required this.t,
    required this.dark,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final effectiveAccent = widget.danger
        ? (widget.dark ? SoftPalette.brightCoral : SoftPalette.roseCoral)
        : (widget.accentColor ?? widget.t.accent);

    final col = widget.danger
        ? (widget.dark ? SoftPalette.brightCoral : SoftPalette.roseCoral)
        : widget.t.sidebarText;

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
          decoration: BoxDecoration(
            color: _hov
                ? effectiveAccent.withValues(alpha: widget.dark ? 0.18 : 0.09)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hov
                  ? effectiveAccent.withValues(alpha: widget.dark ? 0.38 : 0.25)
                  : Colors.transparent,
              width: 1.0,
            ),
          ),
          child: Row(children: [
            Icon(widget.icon, color: _hov ? effectiveAccent : col, size: 16),
            const SizedBox(width: 10),
            Text(
              widget.label,
              style: TextStyle(
                color: _hov
                    ? (widget.danger
                        ? effectiveAccent
                        : (widget.dark ? widget.t.sidebarTextActive : widget.t.textPrimary))
                    : col,
                fontSize: 13,
                fontWeight: widget.danger || _hov ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Mobile layout
// ═══════════════════════════════════════════════════════════════════════════════

class _MobileLayout extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  const _MobileLayout({required this.state, required this.t});

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildAppBar(context),
      body: _MainContent(state: state, t: t, isDesktop: false),
    );
  }

  AppBar _buildAppBar(BuildContext context) {
    final isChairman = state._role == 'chairman';
    final isCeo = state._role == 'ceo';
    final roleBadgeColor = (isChairman || isCeo)
        ? (_dark ? SoftPalette.brightGold : SoftPalette.warmMarigold)
        : t.accent;

    return AppBar(
      backgroundColor: t.bgCard,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      toolbarHeight: 64,
      title: Row(
        children: [
          _LogoPulse(accent: t.accent, pulseAnim: state._logoPulseAnim, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'GMWF',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 16.5,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: t.accent.withValues(alpha: 0.28), width: 0.6),
                      ),
                      child: Text(
                        'v${AutoUpdateService.resolvedVersion}',
                        style: TextStyle(
                          color: t.accent,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1.5),
                Text(
                  'Healthcare & Community System',
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        // Role Badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          margin: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                roleBadgeColor.withValues(alpha: _dark ? 0.25 : 0.16),
                roleBadgeColor.withValues(alpha: _dark ? 0.12 : 0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: roleBadgeColor.withValues(alpha: 0.38),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                (isChairman || isCeo) ? Icons.workspace_premium_rounded : Icons.verified_user_rounded,
                size: 11,
                color: roleBadgeColor,
              ),
              const SizedBox(width: 4),
              Text(
                state._role.toUpperCase(),
                style: TextStyle(
                  color: roleBadgeColor,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
        if (RoleSimulatorService.canAccessSimulator(state._role))
          IconButton(
            tooltip: 'Live Role Simulator',
            icon: Icon(
              Icons.preview_rounded,
              color: _dark ? SoftPalette.softLavender : SoftPalette.royalViolet,
              size: 20,
            ),
            onPressed: () => RoleSimulatorService.showRoleSelectorModal(context),
          ),
        if (state._isFullExecutive || state._isGlobalExecutive)
          IconButton(
            tooltip: 'Force Global Cloud Sync',
            icon: Icon(
              Icons.cloud_upload_rounded,
              color: _dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
              size: 21,
            ),
            onPressed: () => state._confirmAndTriggerForceGlobalSync(context),
          ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(
            Icons.settings_outlined,
            color: t.textSecondary,
            size: 20,
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsPage(userData: state.widget.userData),
            ),
          ).then((_) => state.refresh()),
        ),
        const SizedBox(width: 8),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(
          height: 1,
          color: t.bgRule,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main content  (shared desktop / mobile)
// ═══════════════════════════════════════════════════════════════════════════════

class _MainContent extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool isDesktop;
  const _MainContent(
      {required this.state, required this.t, required this.isDesktop});

  bool get _showMobileChips =>
      !isDesktop && state._mobileShowsCategoryChips && !state._isSupervisor;

  @override
  Widget build(BuildContext context) {
    if (state._isHqManager && isDesktop && state._hqUtilityView != null) {
      switch (state._hqUtilityView!) {
        case _HqUtilityView.notifications:
          return NotificationScreen(
            branchId: (state.widget.userData['branchId'] ?? 'all').toString(),
            userId: (state.widget.userData['uid'] ??
                    state.widget.userData['id'] ??
                    'user')
                .toString(),
            role: (state.widget.userData['role'] ?? 'hq manager').toString(),
            embedded: true,
          );
        case _HqUtilityView.settings:
          return SettingsPage(
            userData: state.widget.userData,
            embedded: true,
          );
      }
    }

    final filtered = state._cachedFilteredModules;
    final double hPad = isDesktop ? 36 : 20;

    final showSnapshot = state._selectedCategory == DashboardCategoryFilter.overall && state._searchQuery.isEmpty;

    return Column(
      children: [
        // Built ONCE at the top — never re-animates or rebuilds on category tab changes
        state._isHqManager
            ? _HqSlimTopBar(state: state, t: t, isDesktop: isDesktop)
            : _HeroHeader(state: state, t: t, isDesktop: isDesktop),
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              if (!showSnapshot)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 0),
                    child: _SearchBar(state: state, t: t),
                  ),
                ),
              if (_showMobileChips)
                SliverToBoxAdapter(
                  child: Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: hPad, vertical: 12),
                    child: _CategoryChips(state: state, t: t),
                  ),
                ),
              if (showSnapshot)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 56),
                  sliver: SliverToBoxAdapter(
                    child: HomeSnapshotDashboard(
                      userData: state.widget.userData,
                      t: t,
                      availableModules: state._availableModules,
                      onOpenModule: state._openModule,
                      isDesktop: isDesktop,
                      onViewReports: () {
                        final reportsModule = state._availableModules.firstWhere(
                          (m) => m.id == 'branches',
                          orElse: () => state._availableModules.first,
                        );
                        state._openModule(reportsModule);
                      },
                    ),
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 20, hPad, 14),
                    child: _SectionLabel(
                        state: state, t: t, count: filtered.length, isDesktop: isDesktop),
                  ),
                ),
                filtered.isEmpty
                    ? SliverToBoxAdapter(
                        child: _EmptySearch(state: state, t: t, hPad: hPad))
                    : SliverPadding(
                        padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 56),
                        sliver: _ModuleGrid(
                            state: state,
                            t: t,
                            modules: filtered,
                            isDesktop: isDesktop),
                      ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final int count;
  final bool isDesktop;
  const _SectionLabel({
    required this.state,
    required this.t,
    required this.count,
    required this.isDesktop,
  });

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your Modules',
              style: TextStyle(
                  color: t.textPrimary,
                  fontSize: isDesktop ? 20 : 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text('$count available',
                key: ValueKey(count),
                style: TextStyle(
                    color: _dark ? t.textSecondary : t.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
        ]),
        Container(
          height: 3,
          width: 40,
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: [t.accent, t.accent.withValues(alpha: 0.0)]),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Hero header
// ═══════════════════════════════════════════════════════════════════════════════

class _HeroHeader extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool isDesktop;
  const _HeroHeader({required this.state, required this.t, required this.isDesktop});

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    final hPad = isDesktop ? 36.0 : 20.0;
    return FadeTransition(
      opacity: state._heroFade,
      child: SlideTransition(
        position: state._heroSlide,
        child: _dark
            ? _DarkHero(state: state, t: t, isDesktop: isDesktop, hPad: hPad)
            : _LightHero(state: state, t: t, isDesktop: isDesktop, hPad: hPad),
      ),
    );
  }
}

// ── Dark & Light Profile-Oriented Hero Header (Lag-free Executive Profile Layout) ─────────
class _DarkHero extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool isDesktop;
  final double hPad;
  const _DarkHero({required this.state, required this.t, required this.isDesktop, required this.hPad});

  @override
  Widget build(BuildContext context) {
    return _buildProfileHeroCard(
      state: state,
      t: t,
      isDesktop: isDesktop,
      hPad: hPad,
      isDark: true,
    );
  }
}

class _LightHero extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool isDesktop;
  final double hPad;
  const _LightHero({required this.state, required this.t, required this.isDesktop, required this.hPad});

  @override
  Widget build(BuildContext context) {
    return _buildProfileHeroCard(
      state: state,
      t: t,
      isDesktop: isDesktop,
      hPad: hPad,
      isDark: false,
    );
  }
}

Widget _buildProfileHeroCard({
  required _GlobalModularDashboardState state,
  required RoleThemeData t,
  required bool isDesktop,
  required double hPad,
  required bool isDark,
}) {
  final now = DateTime.now();
  final dateStr = '${_weekdayFull(now.weekday)}, ${now.day} ${_monthFull(now.month)} ${now.year}';
  final hour = now.hour;
  final isCeo = state._role == 'ceo';
  final isChairman = state._role == 'chairman';

  final timeOfDayUpper = _timeOfDayString(hour).toUpperCase();
  final timeEmoji = (hour >= 18 || hour < 5) ? '🌙' : '☀️';

  final String userPhotoUrl = state._userPhotoUrl;
  final String userName = state._userName;
  final String userRole = state._role.toUpperCase();

  final greetingBadgeText = userRole.isNotEmpty
      ? '$timeEmoji GOOD $timeOfDayUpper • $userRole'
      : '$timeEmoji GOOD $timeOfDayUpper';

  final avatarSize = isDesktop ? 64.0 : 56.0;
  final primaryThemeColor = t.accent;
  final secondaryThemeColor = t.chartBar2;
  final pillRoleColor = (isChairman || isCeo)
      ? (isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold)
      : primaryThemeColor;
  final pillModulesColor =
      isDark ? SoftPalette.softLavender : SoftPalette.royalViolet;
  final pillScopeColor =
      isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;
  final pillLiveColor =
      isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;

  return Container(
    margin: EdgeInsets.fromLTRB(hPad, isDesktop ? 16 : 14, hPad, 0),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(Gr.r5),
      color: t.bgCard,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            primaryThemeColor.withValues(alpha: isDark ? 0.16 : 0.085),
            t.bgCard,
          ),
          t.bgCard,
          Color.alphaBlend(
            secondaryThemeColor.withValues(alpha: isDark ? 0.10 : 0.045),
            t.bgCard,
          ),
        ],
      ),
      border: Border.all(
        color: primaryThemeColor.withValues(alpha: isDark ? 0.28 : 0.18),
        width: 1.0,
      ),
      boxShadow: GShadow.s2(isDark),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Gr.r5),
      child: Stack(
        children: [
          // Ambient Radial Glow Spot (Subtle accent wash top-left)
          Positioned(
            top: -50,
            left: -50,
            width: 220,
            height: 220,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      primaryThemeColor.withValues(alpha: isDark ? 0.22 : 0.12),
                      primaryThemeColor.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Ambient Radial Glow Spot (Subtle accent wash right)
          Positioned(
            top: -40,
            right: 40,
            width: 200,
            height: 200,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      secondaryThemeColor.withValues(alpha: isDark ? 0.16 : 0.09),
                      secondaryThemeColor.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Seamlessly Dissolved Islamic Pattern Watermark on Right
          if (GDecor.patternsEnabled)
            Positioned(
              right: -20,
              top: -20,
              bottom: -20,
              width: isDesktop ? 300 : 210,
              child: IgnorePointer(
                child: ShaderMask(
                  shaderCallback: (rect) {
                    return RadialGradient(
                      center: Alignment.centerRight,
                      radius: 0.85,
                      colors: [
                        SoftPalette.gray900.withValues(alpha: isDark ? 0.30 : 0.14),
                        Colors.transparent,
                      ],
                      stops: const [0.2, 1.0],
                    ).createShader(rect);
                  },
                  blendMode: BlendMode.dstIn,
                  child: Opacity(
                    opacity: isDark ? 0.25 : 0.12,
                    child: GDecorativeImage.asset(
                      'assets/images/1.webp',
                      color: isDark ? t.textPrimary : primaryThemeColor,
                      colorBlendMode: BlendMode.srcIn,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerRight,
                      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),

          // Hero Content
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 22 : 16,
              vertical: isDesktop ? 16 : 14,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Main Left Column: Greeting, Avatar, User Info & Metadata Badges
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Top Greeting Badge Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                        decoration: BoxDecoration(
                          color: primaryThemeColor.withValues(alpha: isDark ? 0.18 : 0.10),
                          borderRadius: BorderRadius.circular(Gr.rFull),
                          border: Border.all(
                            color: primaryThemeColor.withValues(alpha: isDark ? 0.42 : 0.28),
                            width: 1.0,
                          ),
                        ),
                        child: Text(
                          greetingBadgeText,
                          style: TextStyle(
                            color: primaryThemeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                      SizedBox(height: isDesktop ? 11 : 12),

                      // Profile Avatar, User Name & Date Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Interactive Avatar with Halo & Online Indicator
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _showEnlargedAvatarDialog(state.context, state, t),
                              child: Tooltip(
                                message: 'Tap to view, change or remove profile picture',
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            primaryThemeColor,
                                            secondaryThemeColor,
                                          ],
                                        ),
                                      ),
                                      padding: const EdgeInsets.all(2.0),
                                      child: ClipOval(
                                        child: _buildUserHeroAvatar(userPhotoUrl, userName, t, size: avatarSize),
                                      ),
                                    ),
                                    Positioned(
                                      right: 1,
                                      bottom: 1,
                                      child: Container(
                                        width: 13,
                                        height: 13,
                                        decoration: BoxDecoration(
                                          color: GColor.successOf(isDark),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: t.bgCard,
                                            width: 2.0,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 15),
                          // User Display Name & Date Subtitle
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  userName,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: isDesktop ? 22 : 18,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.35,
                                    height: 1.15,
                                  ),
                                  softWrap: true,
                                  maxLines: 2,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.calendar_today_outlined,
                                      size: 12.5,
                                      color: t.textSecondary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      dateStr,
                                      style: TextStyle(
                                        color: t.textSecondary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: isDesktop ? 13 : 14),

                      // Bottom Metadata Badges Row (Strict Single-Line on Mobile)
                      FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ExecutiveGlassPill(
                              t: t,
                              label: userRole,
                              icon: (isChairman || isCeo)
                                  ? Icons.workspace_premium_rounded
                                  : Icons.shield_outlined,
                              accentColor: pillRoleColor,
                              isDark: isDark,
                              isCompact: !isDesktop,
                            ),
                            SizedBox(width: isDesktop ? 8 : 5),
                            _ExecutiveGlassPill(
                              t: t,
                              label: '${state._availableModules.length} Modules',
                              icon: Icons.grid_view_rounded,
                              accentColor: pillModulesColor,
                              isDark: isDark,
                              isCompact: !isDesktop,
                            ),
                            if (state._isSupervisor) ...[
                              if ((state.widget.userData['branchId'] ?? '').toString().isNotEmpty) ...[
                                SizedBox(width: isDesktop ? 8 : 5),
                                _ExecutiveGlassPill(
                                  t: t,
                                  label: (state.widget.userData['branchId'] ?? '').toString().toUpperCase(),
                                  icon: Icons.storefront_rounded,
                                  accentColor: pillLiveColor,
                                  isDark: isDark,
                                  isCompact: !isDesktop,
                                ),
                              ],
                            ] else ...[
                              SizedBox(width: isDesktop ? 8 : 5),
                              _ExecutiveGlassPill(
                                t: t,
                                label: 'Global Access',
                                icon: Icons.public_rounded,
                                accentColor: pillScopeColor,
                                isDark: isDark,
                                isCompact: !isDesktop,
                              ),
                              SizedBox(width: isDesktop ? 8 : 5),
                              _ExecutiveGlassPill(
                                t: t,
                                label: 'Live Network',
                                icon: Icons.sensors_rounded,
                                accentColor: pillLiveColor,
                                isDark: isDark,
                                isPulse: true,
                                isCompact: !isDesktop,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Right Column on Desktop: Seamless Dashboard Animation with In-Engine Theming
                if (isDesktop)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 6),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Subtle contextual ambient aura behind animation
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    primaryThemeColor
                                        .withValues(alpha: isDark ? 0.16 : 0.09),
                                    Colors.transparent,
                                  ],
                                  radius: 0.72,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 230,
                          height: 158,
                          child: RepaintBoundary(
                            child: ColorFiltered(
                              colorFilter: isDark
                                  ? const ColorFilter.matrix(<double>[
                                      0.78, 0.00, 0.00, 0, -20, // Tones down harsh white base
                                      0.00, 1.00, 0.10, 0,  15, // Amplifies emerald / teal data graphs
                                      0.05, 0.12, 1.25, 0,  30, // Illuminates cyber cyan & sky accents
                                      0.00, 0.00, 0.00, 1,   0,
                                    ])
                                  : const ColorFilter.matrix(<double>[
                                      0.98, 0.00, 0.00, 0,   0,
                                      0.00, 0.98, 0.02, 0,   2,
                                      0.02, 0.04, 1.05, 0,   8,
                                      0.00, 0.00, 0.00, 1,   0,
                                    ]),
                              child: Lottie.asset(
                                'assets/animations/dashboard.json',
                                fit: BoxFit.contain,
                                repeat: !GDecor.reduceMotion,
                                errorBuilder: (context, error, stackTrace) => Icon(
                                  Icons.dashboard_customize_rounded,
                                  size: 56,
                                  color: primaryThemeColor,
                                ),
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
    ),
  );
}

class _ExecutiveGlassPill extends StatefulWidget {
  final RoleThemeData t;
  final String label;
  final IconData icon;
  final Color accentColor;
  final bool isDark;
  final bool isPulse;
  final bool isCompact;

  const _ExecutiveGlassPill({
    required this.t,
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.isDark,
    this.isPulse = false,
    this.isCompact = false,
  });

  @override
  State<_ExecutiveGlassPill> createState() => _ExecutiveGlassPillState();
}

class _ExecutiveGlassPillState extends State<_ExecutiveGlassPill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final baseFill = widget.isDark
        ? Color.alphaBlend(
            widget.accentColor.withValues(alpha: 0.09),
            widget.t.bgCardAlt,
          )
        : widget.t.bgCard;
    final hoverFill = Color.alphaBlend(
      widget.accentColor.withValues(alpha: widget.isDark ? 0.24 : 0.13),
      widget.t.bgCard,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: widget.isCompact ? 8.5 : 12.0,
          vertical: widget.isCompact ? 4.5 : 6.0,
        ),
        decoration: BoxDecoration(
          color: _isHovered ? hoverFill : baseFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? widget.accentColor.withValues(alpha: widget.isDark ? 0.65 : 0.50)
                : widget.t.bgRule,
            width: 0.9,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: widget.isDark ? 0.30 : 0.18),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: widget.isDark ? 0.14 : 0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 1.5),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Squircle Micro Icon Container
            Container(
              padding: EdgeInsets.all(widget.isCompact ? 3 : 4),
              decoration: BoxDecoration(
                color: widget.accentColor.withValues(alpha: widget.isDark ? 0.22 : 0.13),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(widget.icon, size: widget.isCompact ? 11 : 13, color: widget.accentColor),
            ),
            SizedBox(width: widget.isCompact ? 5.0 : 7.0),
            Text(
              widget.label,
              style: TextStyle(
                color: _isHovered ? widget.t.textPrimary : widget.t.textPrimary,
                fontSize: widget.isCompact ? 10.0 : 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            if (widget.isPulse) ...[
              SizedBox(width: widget.isCompact ? 4.5 : 6.0),
              Container(
                width: widget.isCompact ? 5 : 6,
                height: widget.isCompact ? 5 : 6,
                decoration: BoxDecoration(
                  color: widget.accentColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: widget.accentColor.withValues(alpha: 0.8),
                      blurRadius: 5,
                      spreadRadius: 1,
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
}



Future<void> _showEnlargedAvatarDialog(
  BuildContext context,
  _GlobalModularDashboardState state,
  RoleThemeData t,
) async {
  final userName = state._userName;
  final userRole = state._role.toUpperCase();

  await showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (dialogCtx) => StatefulBuilder(
      builder: (context, setDialogState) {
        final currentPhoto = state._userPhotoUrl;
        final hasPhoto = currentPhoto.trim().isNotEmpty;
        final userData = state.widget.userData;

        // Adaptive Dark/Light Mode Detection
        final isDark = UserThemeService.isDarkMode() ||
            Theme.of(context).brightness == Brightness.dark ||
            t.isDarkCanvas;

        // Solid executive palette tokens (zero translucency / zero glassmorphic slop)
        final cardBgColor = isDark ? const Color(0xFF18181B) : Colors.white;
        final cardBorderColor = isDark ? const Color(0xFF27272A) : const Color(0xFFE2E8F0);
        final textPrimaryColor = isDark ? Colors.white : const Color(0xFF0F172A);
        final textSecondaryColor = isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B);
        final innerSpacerColor = isDark ? const Color(0xFF18181B) : Colors.white;
        final surfaceCardColor = isDark ? const Color(0xFF27272A) : const Color(0xFFF8FAFC);


        // Dynamic audit information
        final lastUpdatedByName = (userData['photoUpdatedByName'] as String?) ?? '';
        final rawTime = userData['photoUpdatedAt'];

        DateTime? parsedAuditDate;
        if (rawTime is Timestamp) {
          parsedAuditDate = rawTime.toDate().toLocal();
        } else if (rawTime is DateTime) {
          parsedAuditDate = rawTime.toLocal();
        } else if (rawTime is int) {
          parsedAuditDate = DateTime.fromMillisecondsSinceEpoch(rawTime).toLocal();
        } else if (rawTime is String && rawTime.trim().isNotEmpty) {
          parsedAuditDate = DateTime.tryParse(rawTime.trim())?.toLocal();
        }

        String formattedDate = '';
        String relativeTime = '';
        if (parsedAuditDate != null) {
          try {
            formattedDate = DateFormat('dd MMM yyyy • hh:mm a').format(parsedAuditDate);
            final diff = DateTime.now().difference(parsedAuditDate);
            if (diff.inSeconds < 60) {
              relativeTime = 'Just now';
            } else if (diff.inMinutes < 60) {
              relativeTime = '${diff.inMinutes}m ago';
            } else if (diff.inHours < 24) {
              relativeTime = '${diff.inHours}h ago';
            } else if (diff.inDays < 7) {
              relativeTime = '${diff.inDays}d ago';
            } else if (diff.inDays < 30) {
              final weeks = (diff.inDays / 7).floor();
              relativeTime = '${weeks}w ago';
            } else {
              final months = (diff.inDays / 30).floor();
              relativeTime = '${months}mo ago';
            }
          } catch (_) {
            formattedDate = parsedAuditDate.toString().split('.')[0];
          }
        }

        final branchRaw = (userData['branchName'] ?? userData['branch'] ?? userData['branchId'] ?? '').toString().trim();
        final branchDisplay = (branchRaw.isNotEmpty &&
                branchRaw.toLowerCase() != 'null' &&
                branchRaw.toLowerCase() != 'all' &&
                branchRaw.toLowerCase() != 'unknown')
            ? branchRaw.toUpperCase()
            : '';
        final userEmail = (userData['email'] ?? FirebaseAuth.instance.currentUser?.email ?? '').toString().trim();

        Future<void> handlePickPhoto() async {
          final source = await ImageUploadService.showSourceDialog(
            context,
            title: 'Choose Profile Photo Source',
          );
          if (source == null) return;

          final newBase64 = await ImageUploadService.pickAndProcessImage(
            source: source,
            maxWidth: 512,
            maxHeight: 512,
          );
          if (newBase64 == null || newBase64.isEmpty) return;

          await _updateUserProfilePhoto(
            state: state,
            newBase64: newBase64,
            action: 'PHOTO_CHANGED',
          );

          setDialogState(() {});
          if (dialogCtx.mounted) {
            AppToast.showSnackBar(
              context,
              const SnackBar(
                content: Text('✅ Profile photo updated successfully!'),
                backgroundColor: SoftPalette.green400,
              ),
            );
          }
        }

        Future<void> handleRemovePhoto() async {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (confirmCtx) => AlertDialog(
              backgroundColor: cardBgColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cardBorderColor),
              ),
              icon: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF271318) : const Color(0xFFFFF1F2),
                  shape: BoxShape.circle,
                  border: Border.all(color: SoftPalette.red400.withValues(alpha: 0.3)),
                ),
                child: const Icon(Icons.delete_forever_rounded, color: SoftPalette.red400, size: 26),
              ),
              title: Text(
                'Remove Profile Photo?',
                style: TextStyle(color: textPrimaryColor, fontWeight: FontWeight.w700, fontSize: 18),
                textAlign: TextAlign.center,
              ),
              content: Text(
                'Are you sure you want to remove your custom profile photo? Monogram initials will be displayed instead.',
                style: TextStyle(color: textSecondaryColor, fontSize: 13, height: 1.4),
                textAlign: TextAlign.center,
              ),
              actionsAlignment: MainAxisAlignment.center,
              actionsPadding: const EdgeInsets.only(bottom: 20, left: 20, right: 20),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(confirmCtx, false),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: cardBorderColor),
                    foregroundColor: textSecondaryColor,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () => Navigator.pop(confirmCtx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.red400,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child: const Text('Remove Photo', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          );

          if (confirm != true) return;

          await _updateUserProfilePhoto(
            state: state,
            newBase64: '',
            action: 'PHOTO_REMOVED',
          );

          setDialogState(() {});
          if (dialogCtx.mounted) {
            AppToast.showSnackBar(
              context,
              const SnackBar(
                content: Text('🗑️ Profile photo removed.'),
                backgroundColor: SoftPalette.amber300,
              ),
            );
          }
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
            decoration: BoxDecoration(
              color: cardBgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cardBorderColor,
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark ? const Color(0x66000000) : const Color(0x14000000),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Header Bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7.5),
                          decoration: BoxDecoration(
                            color: surfaceCardColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: cardBorderColor),
                          ),
                          child: Icon(Icons.shield_outlined, color: textPrimaryColor, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Profile Photo',
                              style: TextStyle(
                                color: textPrimaryColor,
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                              ),
                            ),
                            Text(
                              'Executive Identity & Avatar',
                              style: TextStyle(
                                color: textSecondaryColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.pop(dialogCtx),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: surfaceCardColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: cardBorderColor),
                          ),
                          child: Icon(Icons.close_rounded, size: 18, color: textSecondaryColor),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),

                // Solid Tactile Avatar Showcase (zero glow halos / zero sweep gradients)
                Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        color: innerSpacerColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark ? const Color(0xFF3F3F46) : const Color(0xFFCBD5E1),
                          width: 3.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isDark ? const Color(0x40000000) : const Color(0x10000000),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(4.0),
                      child: ClipOval(
                        child: _buildDialogAvatarImage(
                          currentPhoto: currentPhoto,
                          userName: userName,
                          t: t,
                          size: 206,
                          isDark: isDark,
                        ),
                      ),
                    ),

                    // Solid Floating Camera Action Button
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Material(
                        color: Colors.transparent,
                        child: Tooltip(
                          message: 'Change profile picture',
                          child: InkWell(
                            onTap: handlePickPhoto,
                            borderRadius: BorderRadius.circular(22),
                            child: Ink(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF27272A) : Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark ? const Color(0xFF3F3F46) : const Color(0xFFCBD5E1),
                                  width: 2.0,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x20000000),
                                    blurRadius: 6,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.camera_alt_outlined,
                                  color: textPrimaryColor,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // User Name
                Text(
                  userName,
                  style: TextStyle(
                    color: textPrimaryColor,
                    fontSize: 21.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 7),

                // Badges Row: Executive Role, Active Status, Branch
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    // Executive Role Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                      decoration: BoxDecoration(
                        color: surfaceCardColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: cardBorderColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, size: 13, color: textPrimaryColor),
                          const SizedBox(width: 5),
                          Text(
                            userRole,
                            style: TextStyle(
                              color: textPrimaryColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Active Status Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isDark ? const Color(0xFF047857) : const Color(0xFF86EFAC),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6.5,
                            height: 6.5,
                            decoration: const BoxDecoration(
                              color: Color(0xFF22C55E),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5.5),
                          Text(
                            'Active',
                            style: TextStyle(
                              color: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF166534),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Branch Pill (if available)
                    if (branchDisplay.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                        decoration: BoxDecoration(
                          color: surfaceCardColor,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: cardBorderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_on_outlined, size: 12, color: textSecondaryColor),
                            const SizedBox(width: 4),
                            Text(
                              branchDisplay,
                              style: TextStyle(
                                color: textSecondaryColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),

                // Optional User Email
                if (userEmail.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    userEmail,
                    style: TextStyle(
                      color: textSecondaryColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],

                // Credential Audit Trail Card
                if (lastUpdatedByName.isNotEmpty || formattedDate.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: surfaceCardColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cardBorderColor,
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF18181B) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: cardBorderColor),
                          ),
                          child: Icon(Icons.verified_user_outlined, size: 20, color: textPrimaryColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'CREDENTIAL AUDIT',
                                    style: TextStyle(
                                      color: textSecondaryColor,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  if (relativeTime.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF18181B) : Colors.white,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: cardBorderColor),
                                      ),
                                      child: Text(
                                        relativeTime,
                                        style: TextStyle(
                                          color: textSecondaryColor,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              RichText(
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'Updated by ',
                                      style: TextStyle(
                                        color: textSecondaryColor,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: lastUpdatedByName.isNotEmpty ? lastUpdatedByName : 'System',
                                      style: TextStyle(
                                        color: textPrimaryColor,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (formattedDate.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  formattedDate,
                                  style: TextStyle(
                                    color: textSecondaryColor.withValues(alpha: 0.8),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 22),

                // Action Buttons Row: Solid Tactile Buttons
                Row(
                  children: [
                    // Primary: Change Photo
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: handlePickPhoto,
                          borderRadius: BorderRadius.circular(10),
                          child: Ink(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.photo_camera_outlined,
                                  size: 18,
                                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Change Photo',
                                  style: TextStyle(
                                    color: isDark ? const Color(0xFF0F172A) : Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Secondary: Remove Photo (only if has photo)
                    if (hasPhoto) ...[
                      const SizedBox(width: 12),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: handleRemovePhoto,
                          borderRadius: BorderRadius.circular(10),
                          child: Ink(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF271318) : const Color(0xFFFFF1F2),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: SoftPalette.red400.withValues(alpha: isDark ? 0.40 : 0.45),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.delete_outline_rounded, size: 18, color: SoftPalette.red400),
                                SizedBox(width: 6),
                                Text(
                                  'Remove',
                                  style: TextStyle(
                                    color: SoftPalette.red400,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Widget _buildDialogAvatarImage({
  required String currentPhoto,
  required String userName,
  required RoleThemeData t,
  required double size,
  bool isDark = true,
}) {
  final str = currentPhoto.trim();
  if (str.isNotEmpty) {
    final bytes = ImageUploadService.decodeBase64ToBytes(str);
    if (bytes != null) {
      return Image.memory(
        bytes,
        key: ValueKey('dialog_avatar_${str.hashCode}'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _buildDialogFallbackAvatar(
          userName,
          t,
          size,
          isDark: isDark,
        ),
      );
    }
    if (str.startsWith('http://') || str.startsWith('https://')) {
      return Image.network(
        str,
        key: ValueKey('dialog_avatar_net_${str.hashCode}'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _buildDialogFallbackAvatar(
          userName,
          t,
          size,
          isDark: isDark,
        ),
      );
    }
    if (!kIsWeb && File(str).existsSync()) {
      return Image.file(
        File(str),
        key: ValueKey('dialog_avatar_file_${str.hashCode}'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _buildDialogFallbackAvatar(
          userName,
          t,
          size,
          isDark: isDark,
        ),
      );
    }
  }
  return _buildDialogFallbackAvatar(
    userName,
    t,
    size,
    isDark: isDark,
  );
}

Widget _buildDialogFallbackAvatar(
  String userName,
  RoleThemeData t,
  double size, {
  bool isDark = true,
}) {
  final initials = userName.trim().isNotEmpty
      ? userName
          .trim()
          .split(RegExp(r'\s+'))
          .take(2)
          .map((e) => e.isNotEmpty ? e[0].toUpperCase() : '')
          .join()
      : 'U';

  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: isDark ? const Color(0xFF27272A) : const Color(0xFFE2E8F0),
      shape: BoxShape.circle,
    ),
    child: Center(
      child: Text(
        initials,
        style: TextStyle(
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: size * 0.36,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
    ),
  );
}

Future<void> _updateUserProfilePhoto({
  required _GlobalModularDashboardState state,
  required String newBase64,
  required String action,
}) async {
  // 1. Update State User Data
  state.widget.userData['profileImage'] = newBase64;
  state.widget.userData['photoUrl'] = newBase64;
  state.widget.userData['profilePictureUrl'] = newBase64;

  // 2. Audit Trail Tracking (who performed the update)
  final currentUser = FirebaseAuth.instance.currentUser;
  final updaterUid = (currentUser?.uid ?? state.widget.userData['uid'] ?? state.widget.userData['id'] ?? 'unknown').toString();
  final updaterName = state._userName;
  final updaterEmail = (state.widget.userData['email'] ?? currentUser?.email ?? 'unknown').toString();
  final timestampStr = DateTime.now().toIso8601String();

  final auditRecord = {
    'action': action,
    'timestamp': timestampStr,
    'updatedByUid': updaterUid,
    'updatedByName': updaterName,
    'updatedByEmail': updaterEmail,
  };

  state.widget.userData['photoUpdatedAt'] = timestampStr;
  state.widget.userData['photoUpdatedByUid'] = updaterUid;
  state.widget.userData['photoUpdatedByName'] = updaterName;
  state.widget.userData['photoUpdatedByEmail'] = updaterEmail;

  state._updateCachedUserData();
  state.refresh();

  // 3. Save locally in Hive & Offline Secure Credentials Cache
  await LocalStorageService.saveLocalUser(state.widget.userData);
  await offline_auth.OfflineAuthService.updateCachedUserData(state.widget.userData);

  // 4. Sync online with Cloud Firestore
  try {
    if (updaterUid.isNotEmpty && updaterUid != 'unknown') {
      final updateData = {
        'profileImage': newBase64,
        'photoUrl': newBase64,
        'profilePictureUrl': newBase64,
        'photoUpdatedAt': FieldValue.serverTimestamp(),
        'photoUpdatedByUid': updaterUid,
        'photoUpdatedByName': updaterName,
        'photoUpdatedByEmail': updaterEmail,
        'photoHistory': FieldValue.arrayUnion([auditRecord]),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance.collection('users').doc(updaterUid).set(updateData, SetOptions(merge: true));

      final branchId = state.widget.userData['branchId']?.toString();
      if (branchId != null && branchId.isNotEmpty && branchId != 'all' && branchId != 'unknown') {
        await CloudDb.instance
            .collection('branches')
            .doc(branchId)
            .collection('users')
            .doc(updaterUid)
            .set(updateData, SetOptions(merge: true));
      }

      try {
        final cgSnap = await CloudDb.instance
            .collectionGroup('users')
            .where('uid', isEqualTo: updaterUid)
            .get()
            .timeout(const Duration(seconds: 4));
        for (final doc in cgSnap.docs) {
          await doc.reference.set(updateData, SetOptions(merge: true));
        }
      } catch (_) {}
    }
  } catch (e) {
    debugPrint('[GlobalDashboard] Direct Firestore sync notice (will rely on durable sync queue): $e');
  }

  // 5. Durable Queue for Offline Sync & Background SyncService
  try {
    final branchId = (state.widget.userData['branchId'] ?? 'all').toString();
    await LocalStorageService.enqueueSync({
      'type': 'save_user',
      'uid': updaterUid,
      'branchId': branchId,
      'data': state.widget.userData,
    });
  } catch (e) {
    debugPrint('[GlobalDashboard] Error enqueuing user profile sync: $e');
  }

  // 6. Broadcast updated profile over LAN WebSocket so other active stations update immediately
  try {
    RealtimeManager().sendMessage(RealtimeEvents.payload(
      type: 'user_updated',
      branchId: (state.widget.userData['branchId'] ?? 'all').toString(),
      data: state.widget.userData,
    ));
  } catch (_) {}
}

String _timeOfDayString(int hour) {
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  return 'evening';
}

String _weekdayFull(int d) => ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d - 1];
String _monthFull(int m) => ['January','February','March','April','May','June','July','August','September','October','November','December'][m-1];

// Avatar decode memo: the base64 photo was decoded (and the file path stat'ed) on every build, and
// each new Uint8List was a new MemoryImage cache key, so the full-size photo was re-decoded too.
String? _heroAvatarSrc;
Uint8List? _heroAvatarBytes;
bool _heroAvatarFileExists = false;

Widget _buildUserHeroAvatar(String photoUrl, String userName, RoleThemeData t, {double size = 64}) {
  final str = photoUrl.trim();
  if (str != _heroAvatarSrc) {
    _heroAvatarSrc = str;
    _heroAvatarBytes = str.isEmpty ? null : ImageUploadService.decodeBase64ToBytes(str);
    _heroAvatarFileExists = _heroAvatarBytes == null &&
        str.isNotEmpty &&
        !str.startsWith('http://') &&
        !str.startsWith('https://') &&
        !kIsWeb &&
        File(str).existsSync();
  }
  // Decode at display size, not the photo's native resolution.
  final dpr = WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ?? 1.0;
  final cachePx = (size * dpr).round();
  Widget child;
  if (str.isNotEmpty) {
    final bytes = _heroAvatarBytes;
    if (bytes != null) {
      child = Image.memory(
        bytes,
        key: ValueKey('hero_avatar_${str.hashCode}'),
        width: size,
        height: size,
        cacheWidth: cachePx,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size),
      );
    } else if (str.startsWith('http://') || str.startsWith('https://')) {
      child = Image.network(
        str,
        key: ValueKey('hero_avatar_net_${str.hashCode}'),
        width: size,
        height: size,
        cacheWidth: cachePx,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size),
      );
    } else if (_heroAvatarFileExists) {
      child = Image.file(
        File(str),
        key: ValueKey('hero_avatar_file_${str.hashCode}'),
        width: size,
        height: size,
        cacheWidth: cachePx,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size),
      );
    } else {
      child = _buildUserAvatarFallback(userName, t, size);
    }
  } else {
    child = _buildUserAvatarFallback(userName, t, size);
  }

  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: t.bgCard.withValues(alpha: 0.96), width: 3.0),
      boxShadow: [
        BoxShadow(
          color: SoftPalette.gray900.withValues(alpha: 0.25),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    child: ClipOval(child: child),
  );
}

Widget _buildUserAvatarFallback(String userName, RoleThemeData t, double size) {
  final initial = userName.trim().isNotEmpty ? userName.trim()[0].toUpperCase() : 'U';
  return Container(
    color: t.accent.withValues(alpha: 0.85),
    alignment: Alignment.center,
    child: Text(
      initial,
      style: TextStyle(
        color: SoftPalette.pureWhiteSoft,
        fontWeight: FontWeight.w900,
        fontSize: size * 0.42,
      ),
    ),
  );
}






// ── Search bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  const _SearchBar({required this.state, required this.t});

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    final isMobile = GBreakpoint.isMobile(context);
    if (isMobile && !state._searchOpen) return const SizedBox.shrink();

    return SizeTransition(
      sizeFactor: isMobile
          ? state._searchExpand
          : const AlwaysStoppedAnimation(1.0),
      axisAlignment: -1,
      child: FadeTransition(
        opacity: isMobile
            ? state._searchExpand
            : const AlwaysStoppedAnimation(1.0),
        child: Container(
          decoration: BoxDecoration(
            color: t.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: t.bgRule,
                width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: SoftPalette.gray900.withValues(alpha: _dark ? 0.22 : 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: TextField(
            controller: state._searchCtrl,
            autofocus: isMobile && state._searchOpen,
            onChanged: (v) {
              state._searchDebounce?.cancel();
              state._searchDebounce = Timer(const Duration(milliseconds: 220), () {
                state.updateSearchQuery(v.trim());
              });
            },
            style: TextStyle(
                color: t.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Search modules…',
              hintStyle: TextStyle(
                  color: t.textTertiary,
                  fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded,
                  color: t.textTertiary,
                  size: 20),
              suffixIcon: state._searchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close_rounded,
                          color: t.textTertiary,
                          size: 18),
                      onPressed: () => state.clearSearch(),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                  vertical: 16, horizontal: 8),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Category chips (mobile) ───────────────────────────────────────────────────

class _CategoryChips extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  const _CategoryChips({required this.state, required this.t});

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: state._visibleCategories.map((cat) {
          final sel = state._selectedCategory == cat;
          final label = cat == DashboardCategoryFilter.overall
              ? 'Dashboard'
              : cat.name[0].toUpperCase() + cat.name.substring(1);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: ChoiceChip(
                label: Text(label),
                selected: sel,
                onSelected: (v) { if (v) state._changeCategory(cat); },
                selectedColor:
                    _dark ? t.accent.withValues(alpha: 0.22) : t.accent,
                labelStyle: TextStyle(
                    color: sel
                        ? (_dark ? t.accent : SoftPalette.pureWhiteSoft)
                        : t.textSecondary,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 12),
                backgroundColor: t.bgCard,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                        color: sel ? t.accent : t.bgRule)),
                showCheckmark: false,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Empty search ──────────────────────────────────────────────────────────────

class _EmptySearch extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final double hPad;
  const _EmptySearch(
      {required this.state, required this.t, required this.hPad});

  bool get _dark => t.isDarkCanvas || state._isDark;

  @override
  Widget build(BuildContext context) {
    final isSchoolCat = state._selectedCategory == DashboardCategoryFilter.school;
    final branchId = (state.widget.userData['branchId'] as String? ?? '').trim();
    final branchName = LocalStorageService.getBranchName(branchId);
    final isSchoolUnavailable = isSchoolCat && !LocalStorageService.hasSchoolFacility(branchId);

    if (isSchoolUnavailable) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 40),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: t.bgCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: t.bgRule),
              boxShadow: [
                BoxShadow(
                  color: SoftPalette.gray900.withValues(alpha: _dark ? 0.22 : 0.04),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GEmptyIllustration(
                  GEmptyIllustrationKind.education,
                  size: 148,
                  fallbackIcon: Icons.school_outlined,
                ),
                const SizedBox(height: 18),
                Text(
                  'School is not available in $branchName yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The school facility is not enabled or registered for the $branchName branch.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 60),
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          builder: (ctx, v, ch) => Opacity(
            opacity: v,
            child: Transform.translate(
                offset: Offset(0, 14 * (1 - v)), child: ch),
          ),
          child: Column(children: [
            const GEmptyIllustration(
              GEmptyIllustrationKind.search,
              size: 148,
              fallbackIcon: Icons.search_off_rounded,
            ),
            const SizedBox(height: 16),
            Text('No modules found',
                style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(state._searchQuery.isNotEmpty ? '"${state._searchQuery}" didn\'t match anything' : 'No modules available for this category',
                style: TextStyle(
                    color: t.textTertiary,
                    fontSize: 13)),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => state.clearSearch(),
              style: TextButton.styleFrom(
                foregroundColor: t.accent,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: t.accent.withValues(alpha: 0.4))),
              ),
              child: const Text('Clear search',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Module grid
// ═══════════════════════════════════════════════════════════════════════════════

class _ModuleGrid extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final List<AppModule> modules;
  final bool isDesktop;
  const _ModuleGrid({
    required this.state,
    required this.t,
    required this.modules,
    required this.isDesktop,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cols = w < 480 ? 2 : w < 700 ? 2 : w < 1100 ? 3 : 4;

    // AnimatedSwitcher cross-fades the entire grid when the category changes.
    return SliverToBoxAdapter(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: _buildGrid(context, cols, w),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, int cols, double w) {
    final dark = t.isDarkCanvas || state._isDark;
    final isSearchActive = state._searchQuery.isNotEmpty;

    // Responsive Grid Delegate: 1 col on mobile, 2 on tablet, 3-4 on desktop
    final gridCols = w < 600 ? 1 : (w < 950 ? 2 : (w < 1350 ? 3 : 4));
    final gridAspect = w < 600 ? 2.6 : (w < 950 ? 2.3 : (w < 1350 ? 2.2 : 2.1));

    // If searching or category filter chip is selected (not 'overall'), show flat grid
    if (isSearchActive || state._selectedCategory != DashboardCategoryFilter.overall) {
      return GridView.builder(
        key: ValueKey('flat_${state._selectedCategory}_${state._searchQuery}'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: gridCols,
          crossAxisSpacing: isDesktop ? 14 : 10,
          mainAxisSpacing: isDesktop ? 14 : 10,
          childAspectRatio: gridAspect,
        ),
        itemCount: modules.length,
        itemBuilder: (ctx, i) {
          return _ModuleCard(
            module: modules[i],
            t: t,
            dark: dark,
            isDesktop: isDesktop,
            isHero: modules[i].isFeatured,
            onTap: () => state._openModule(modules[i]),
          );
        },
      );
    }

    // Hierarchical Department Grouping for Main Dashboard View
    final featured = modules.where((m) => m.isFeatured).toList();
    final officeMods = modules.where((m) => !m.isFeatured && m.category == ModuleCategory.office).toList();
    final medicalMods = modules.where((m) => !m.isFeatured && m.category == ModuleCategory.dispensary).toList();
    final welfareMods = modules.where((m) => !m.isFeatured && m.category == ModuleCategory.dasterkhwaan).toList();
    final eduMods = modules.where((m) => !m.isFeatured && (m.category == ModuleCategory.madrassa || m.category == ModuleCategory.school)).toList();
    final restMods = modules.where((m) => !m.isFeatured &&
        m.category != ModuleCategory.office &&
        m.category != ModuleCategory.dispensary &&
        m.category != ModuleCategory.dasterkhwaan &&
        m.category != ModuleCategory.madrassa &&
        m.category != ModuleCategory.school).toList();

    Widget buildCategorySection(String title, IconData icon, Color color, List<AppModule> secModules) {
      if (secModules.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: dark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 15, color: color),
                ),
                const SizedBox(width: 8),
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: dark ? 0.22 : 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${secModules.length}',
                    style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: gridCols,
              crossAxisSpacing: isDesktop ? 14 : 10,
              mainAxisSpacing: isDesktop ? 14 : 10,
              childAspectRatio: gridAspect,
            ),
            itemCount: secModules.length,
            itemBuilder: (ctx, i) {
              return _ModuleCard(
                module: secModules[i],
                t: t,
                dark: dark,
                isDesktop: isDesktop,
                isHero: secModules[i].isFeatured,
                onTap: () => state._openModule(secModules[i]),
              );
            },
          ),
        ],
      );
    }

    return Column(
      key: const ValueKey('hierarchical_grid'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (featured.isNotEmpty)
          buildCategorySection('Core & Executive Operations', Icons.star_rounded, dark ? SoftPalette.brightGold : SoftPalette.warmMarigold, featured),
        if (officeMods.isNotEmpty)
          buildCategorySection('Office & Financial ERP', Icons.business_center_rounded, dark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue, officeMods),
        if (medicalMods.isNotEmpty)
          buildCategorySection('Medical & Dispensary Services', Icons.local_hospital_rounded, dark ? SoftPalette.brightCyan : SoftPalette.deepCyan, medicalMods),
        if (welfareMods.isNotEmpty)
          buildCategorySection('Welfare & Relief Services', Icons.volunteer_activism_rounded, dark ? SoftPalette.brightCoral : SoftPalette.roseCoral, welfareMods),
        if (eduMods.isNotEmpty)
          buildCategorySection('Madrassa & School Education', Icons.school_rounded, dark ? SoftPalette.softLavender : SoftPalette.royalViolet, eduMods),
        if (restMods.isNotEmpty)
          buildCategorySection('System & Maintenance', Icons.settings_rounded, t.textSecondary, restMods),
      ],
    );
  }
}

// ── Module card ───────────────────────────────────────────────────────────────

class _ModuleCard extends StatefulWidget {
  final AppModule module;
  final RoleThemeData t;
  final bool dark;
  final bool isDesktop;
  final bool isHero;
  final VoidCallback onTap;
  const _ModuleCard({
    required this.module,
    required this.t,
    required this.dark,
    required this.isDesktop,
    required this.onTap,
    this.isHero = false,
  });

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard>
    with SingleTickerProviderStateMixin {
  bool _hov = false;
  late AnimationController _pressCtrl;
  late Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _pressScale = Tween<double>(begin: 1.0, end: 0.97).animate(
        CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark;
    final t = widget.t;
    final w = MediaQuery.of(context).size.width;
    final tiny = w < 480;

    // High-clarity categorical accents matched across light, hybrid & dark themes
    final Color categoryColor;
    final Color ambientGlowColor;
    final String categoryLabel;

    switch (widget.module.category) {
      case ModuleCategory.office:
        categoryColor = widget.module.id == 'finance'
            ? (dark ? SoftPalette.softLavender : SoftPalette.royalViolet)
            : (dark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue);
        ambientGlowColor = categoryColor;
        categoryLabel = widget.module.id == 'finance' ? 'HR / FINANCE' : 'OFFICE';
        break;
      case ModuleCategory.dispensary:
        categoryColor = dark ? SoftPalette.brightCyan : SoftPalette.deepCyan;
        ambientGlowColor = categoryColor;
        categoryLabel = 'MEDICAL';
        break;
      case ModuleCategory.dasterkhwaan:
        categoryColor = dark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
        ambientGlowColor = categoryColor;
        categoryLabel = 'WELFARE';
        break;
      case ModuleCategory.madrassa:
        categoryColor = dark ? SoftPalette.brightCoral : SoftPalette.roseCoral;
        ambientGlowColor = categoryColor;
        categoryLabel = 'MADRASSA';
        break;
      case ModuleCategory.school:
        categoryColor = dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
        ambientGlowColor = categoryColor;
        categoryLabel = 'SCHOOL';
        break;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() {
        _hov = false;
        _pressCtrl.reverse();
      }),
      child: GestureDetector(
        onTapDown: (_) => _pressCtrl.forward(),
        onTapUp: (_) => _pressCtrl.reverse(),
        onTapCancel: () => _pressCtrl.reverse(),
        onTap: widget.onTap,
        child: ScaleTransition(
          scale: _pressScale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              // Ambient outer radial glow shadow
              boxShadow: [
                BoxShadow(
                  color: ambientGlowColor.withValues(alpha: _hov ? (dark ? 0.30 : 0.16) : (dark ? 0.12 : 0.05)),
                  blurRadius: _hov ? 24 : 12,
                  spreadRadius: _hov ? 1 : 0,
                  offset: Offset(0, _hov ? 8 : 3),
                ),
                BoxShadow(
                  color: SoftPalette.gray900.withValues(alpha: dark ? 0.35 : 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  // High contrast crisp card background
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? [
                            t.bgCard,
                            Color.alphaBlend(categoryColor.withValues(alpha: 0.05), t.bgCardAlt),
                          ]
                        : [
                            t.bgCard,
                            Color.alphaBlend(categoryColor.withValues(alpha: 0.03), t.bgCard),
                          ],
                  ),
                  border: Border.all(
                    color: _hov
                        ? categoryColor.withValues(alpha: dark ? 0.72 : 0.62)
                        : t.bgRule,
                    width: _hov ? 1.6 : 1.2,
                  ),
                ),
                child: Stack(
                  children: [
                    // Ambient Radial Glow Spot (Top-Left behind icon)
                    Positioned(
                      top: -24,
                      left: -24,
                      width: 120,
                      height: 120,
                        child: IgnorePointer(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  ambientGlowColor.withValues(alpha: _hov ? (dark ? 0.35 : 0.24) : (dark ? 0.18 : 0.11)),
                                  ambientGlowColor.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Watermark: Faded, low-opacity large line-art icon anchored subtly in bottom-right corner
                      Positioned(
                        right: -14,
                        bottom: -14,
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: dark ? (_hov ? 0.14 : 0.06) : (_hov ? 0.12 : 0.05),
                            duration: const Duration(milliseconds: 250),
                            child: Icon(
                              widget.module.icon,
                              size: tiny ? 76 : 94,
                              color: categoryColor,
                            ),
                          ),
                        ),
                      ),

                      // Content Body
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          tiny ? 16 : 20,
                          tiny ? 14 : 18,
                          tiny ? 16 : 18,
                          tiny ? 14 : 16,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // ── Top Row: Floating Squircle Badge + Tags + Action Arrow Button ──
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Floating Squircle Micro-Badge with inner bevel & soft drop shadow
                                AnimatedRotation(
                                  turns: _hov ? 0.015 : 0,
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeOutBack,
                                  child: Container(
                                    padding: EdgeInsets.all(tiny ? 9 : 11),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          categoryColor,
                                          categoryColor.withValues(alpha: 0.82),
                                        ],
                                      ),
                                      border: Border.all(
                                        color: SoftPalette.pureWhiteSoft.withValues(alpha: 0.35),
                                        width: 1.0,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: categoryColor.withValues(alpha: _hov ? 0.45 : 0.30),
                                          blurRadius: _hov ? 12 : 8,
                                          offset: const Offset(0, 4),
                                        ),
                                        BoxShadow(
                                          color: SoftPalette.pureWhiteSoft.withValues(alpha: 0.25),
                                          blurRadius: 1,
                                          offset: const Offset(-1, -1),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      widget.module.icon,
                                      color: SoftPalette.pureWhiteSoft,
                                      size: tiny ? 19 : 22,
                                    ),
                                  ),
                                ),

                                const SizedBox(width: 12),

                                // Category Pill Badge & Title Block
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Pill-shaped Category Badge
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                                        decoration: BoxDecoration(
                                          color: categoryColor.withValues(alpha: dark ? (_hov ? 0.30 : 0.18) : (_hov ? 0.20 : 0.10)),
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: categoryColor.withValues(alpha: dark ? 0.35 : 0.25),
                                            width: 0.8,
                                          ),
                                        ),
                                        child: Text(
                                          categoryLabel,
                                          style: TextStyle(
                                            color: categoryColor,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.7,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        widget.module.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: t.textPrimary,
                                          fontSize: tiny ? 14.0 : 15.5,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(width: 8),

                                // Action Button: Crisp circular pill button with directional arrow (→) & glass hover glow
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _hov
                                        ? categoryColor
                                        : (dark
                                            ? t.textPrimary.withValues(alpha: 0.08)
                                            : categoryColor.withValues(alpha: 0.10)),
                                    border: Border.all(
                                      color: _hov
                                          ? Colors.transparent
                                          : (dark
                                              ? t.textPrimary.withValues(alpha: 0.20)
                                              : categoryColor.withValues(alpha: 0.22)),
                                      width: 1.0,
                                    ),
                                    boxShadow: _hov
                                        ? [
                                            BoxShadow(
                                              color: categoryColor.withValues(alpha: 0.45),
                                              blurRadius: 10,
                                              offset: const Offset(0, 3),
                                            )
                                          ]
                                        : [],
                                  ),
                                  child: Center(
                                    child: AnimatedSlide(
                                      duration: const Duration(milliseconds: 200),
                                      offset: Offset(_hov ? 0.1 : 0.0, 0.0),
                                      child: Icon(
                                        Icons.arrow_forward_rounded,
                                        color: _hov ? SoftPalette.pureWhiteSoft : categoryColor,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 10),

                            // Muted secondary descriptive text
                            Text(
                              widget.module.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _hov ? t.textPrimary : t.textSecondary,
                                fontSize: tiny ? 11.0 : 12.0,
                                fontWeight: FontWeight.w400,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  }
}

// ── HQ Manager Command-Center Collapsible Rail & Slim Top Bar ─────────────────

class _HqCollapsibleRail extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  const _HqCollapsibleRail({required this.state, required this.t});

  static const _icons = {
    DashboardCategoryFilter.overall: Icons.space_dashboard_rounded,
    DashboardCategoryFilter.office: Icons.business_center_rounded,
    DashboardCategoryFilter.dispensary: Icons.local_hospital_rounded,
    DashboardCategoryFilter.dasterkhwaan: Icons.volunteer_activism_rounded,
    DashboardCategoryFilter.madrassa: Icons.auto_stories_rounded,
    DashboardCategoryFilter.school: Icons.school_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final collapsed = state._hqRailCollapsed;
    final dark = t.isDarkSidebar || t.isDarkCanvas || state._isDark;
    final double width = collapsed ? 76.0 : 244.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [t.sidebarBg, t.sidebarBgSecondary],
        ),
        border: Border(
          right: BorderSide(color: t.sidebarBorder, width: 1.1),
        ),
        boxShadow: [
          BoxShadow(
            color: t.accent.withValues(alpha: dark ? 0.10 : 0.05),
            blurRadius: 20,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Brand + Collapse Toggle
          Padding(
            padding: EdgeInsets.fromLTRB(
              collapsed ? 12 : 16,
              18,
              collapsed ? 12 : 12,
              14,
            ),
            child: collapsed
                ? Column(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: SoftPalette.gray50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: t.accent.withValues(alpha: 0.25),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.asset(
                            'assets/logo/gmwf-1.webp',
                            fit: BoxFit.contain,
                            cacheHeight: 108,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.business_rounded,
                              color: t.accent,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Tooltip(
                        message: 'Expand rail',
                        child: InkWell(
                          onTap: state._toggleHqRail,
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: dark ? 0.18 : 0.10),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: t.accent.withValues(alpha: 0.22),
                              ),
                            ),
                            child: Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: t.accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: SoftPalette.gray50,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: t.accent.withValues(alpha: 0.25),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: Image.asset(
                              'assets/logo/gmwf-1.webp',
                              fit: BoxFit.contain,
                              cacheHeight: 108,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.business_rounded,
                                color: t.accent,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'GMWF HQ',
                                style: TextStyle(
                                  color: t.sidebarTextActive,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  letterSpacing: 0.3,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Command Rail',
                                style: TextStyle(
                                  color: t.sidebarText,
                                  fontSize: 10.5,
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
                Tooltip(
                  message: 'Collapse rail',
                  child: InkWell(
                    onTap: state._toggleHqRail,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: dark ? 0.18 : 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: t.accent.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Icon(
                        Icons.chevron_left_rounded,
                        size: 18,
                        color: t.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Divider(color: t.sidebarBorder, height: 1),
          ),
          // Category Navigation
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                if (!collapsed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                    child: Text(
                      'WORKSPACES',
                      style: TextStyle(
                        color: t.sidebarText.withValues(alpha: 0.72),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ...state._visibleCategories.map((cat) {
                  final sel = state._hqUtilityView == null &&
                      state._selectedCategory == cat;
                  final icon = _icons[cat] ?? Icons.grid_view_rounded;
                  final label = cat == DashboardCategoryFilter.overall
                      ? 'Command Center'
                      : cat.name[0].toUpperCase() + cat.name.substring(1);
                  final catColor = cat == DashboardCategoryFilter.overall
                      ? t.accent
                      : _getCatColor(cat, dark: dark);

                  final item = Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: collapsed ? 12 : 10,
                      vertical: 3,
                    ),
                    child: InkWell(
                      onTap: () => state._changeCategory(cat),
                      borderRadius: BorderRadius.circular(12),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: EdgeInsets.symmetric(
                          horizontal: collapsed ? 0 : 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: sel
                              ? catColor.withValues(alpha: dark ? 0.22 : 0.13)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: sel
                                ? catColor.withValues(alpha: 0.40)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: collapsed
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.start,
                          children: [
                            Icon(
                              icon,
                              size: 19,
                              color: sel ? catColor : t.sidebarText,
                            ),
                            if (!collapsed) ...[
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    color: sel ? t.sidebarTextActive : t.sidebarText,
                                    fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );

                  return collapsed
                      ? Tooltip(message: label, child: item)
                      : item;
                }),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Divider(color: t.sidebarBorder, height: 1),
          ),
          // Utility Footer
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 12 : 10,
              vertical: 12,
            ),
            child: Column(
              children: [
                _HqRailAction(
                  icon: Icons.cloud_upload_rounded,
                  label: 'Force Global Sync',
                  color: dark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
                  collapsed: collapsed,
                  t: t,
                  onTap: () => state._confirmAndTriggerForceGlobalSync(context),
                ),
                _HqRailAction(
                  icon: Icons.notifications_outlined,
                  label: 'Notifications',
                  color: dark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
                  collapsed: collapsed,
                  selected: state._hqUtilityView == _HqUtilityView.notifications,
                  t: t,
                  onTap: () => state._openHqUtility(_HqUtilityView.notifications),
                ),
                _HqRailAction(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  color: dark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
                  collapsed: collapsed,
                  selected: state._hqUtilityView == _HqUtilityView.settings,
                  t: t,
                  onTap: () => state._openHqUtility(_HqUtilityView.settings),
                ),
                _HqRailAction(
                  icon: Icons.logout_rounded,
                  label: 'Sign Out',
                  color: dark ? SoftPalette.brightCoral : SoftPalette.roseCoral,
                  collapsed: collapsed,
                  t: t,
                  onTap: state._logout,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HqRailAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool collapsed;
  final bool selected;
  final RoleThemeData t;
  final VoidCallback onTap;

  const _HqRailAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.collapsed,
    this.selected = false,
    required this.t,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 0 : 10,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.35) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment:
              collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            if (!collapsed) ...[
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? t.sidebarTextActive : t.sidebarText,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    fontSize: 12.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return collapsed ? Tooltip(message: label, child: child) : child;
  }
}

class _HqSlimTopBar extends StatelessWidget {
  final _GlobalModularDashboardState state;
  final RoleThemeData t;
  final bool isDesktop;
  const _HqSlimTopBar({
    required this.state,
    required this.t,
    required this.isDesktop,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr =
        '${_weekdayFull(now.weekday)}, ${now.day} ${_monthFull(now.month)} ${now.year}';
    final hPad = isDesktop ? 36.0 : 18.0;
    final dark = t.isDarkCanvas || state._isDark;
    final rawTod = _timeOfDayString(now.hour);
    final todTitle = rawTod.isEmpty
        ? 'Day'
        : rawTod[0].toUpperCase() + rawTod.substring(1).toLowerCase();

    return Container(
      margin: EdgeInsets.fromLTRB(hPad, isDesktop ? 16 : 10, hPad, 0),
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 22 : 14,
        vertical: isDesktop ? 14 : 12,
      ),
      decoration: BoxDecoration(
        color: t.bgCard,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              t.accent.withValues(alpha: dark ? 0.16 : 0.07),
              t.bgCard,
            ),
            t.bgCard,
            Color.alphaBlend(
              t.chartBar2.withValues(alpha: dark ? 0.08 : 0.03),
              t.bgCard,
            ),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: t.accent.withValues(alpha: dark ? 0.28 : 0.18),
          width: 1.1,
        ),
        boxShadow: GShadow.s2(dark),
      ),
      child: Row(
        children: [
          _buildUserHeroAvatar(
            state._userPhotoUrl,
            state._userName,
            t,
            size: isDesktop ? 44 : 36,
          ),
          SizedBox(width: isDesktop ? 14 : 10),
          // Left: Respectful Executive Salutation & Authority Scope
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'ASSALAM-O-ALAIKUM · GOOD $todTitle'.toUpperCase(),
                      style: TextStyle(
                        color: t.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.9,
                      ),
                    ),
                    if (isDesktop) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: dark ? 0.20 : 0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: t.accent.withValues(alpha: 0.28),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dark
                                    ? SoftPalette.brightMint
                                    : SoftPalette.jadeEmerald,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'HQ MANAGER · ALL BRANCHES',
                              style: TextStyle(
                                color: t.accent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Respected ${state._userName}',
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: isDesktop ? 17 : 14.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (isDesktop)
                  Text(
                    'Executive Command Center  ·  $dateStr',
                    style: TextStyle(
                      color: t.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Right: Quick Actions
          if (isDesktop) ...[
            InkWell(
              onTap: () {
                if (state._selectedCategory == DashboardCategoryFilter.overall) {
                  state._changeCategory(DashboardCategoryFilter.office);
                }
              },
              borderRadius: BorderRadius.circular(11),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                decoration: BoxDecoration(
                  color: t.bgCardAlt,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: t.bgRule),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.apps_rounded, size: 15, color: t.accent),
                    const SizedBox(width: 7),
                    Text(
                      'All Modules (${state._availableModules.length})',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Executive Settings',
              child: InkWell(
                onTap: () => state._openHqUtility(_HqUtilityView.settings),
                borderRadius: BorderRadius.circular(11),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: t.bgCardAlt,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: t.bgRule),
                  ),
                  child: Icon(
                    Icons.tune_rounded,
                    size: 17,
                    color: t.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}