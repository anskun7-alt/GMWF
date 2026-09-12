// lib/pages/global_modular_dashboard.dart
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:lottie/lottie.dart';

import '../models/module_registry.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../services/user_theme_service.dart';
import 'settings_page.dart';
import 'support_page.dart';
import 'notification_screen.dart';
import '../widgets/global_module_wrapper.dart';
import '../widgets/home_snapshot_widgets.dart';
import '../services/sync_service.dart';
import 'admin/data_cleanup_screen.dart';
import '../services/role_simulator_service.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/local_storage_service.dart';
import '../services/auth_service.dart';
import '../realtime/realtime_manager.dart';
import '../constants/navigator_key.dart';
import 'login_page.dart';
import '../services/offline_auth_service.dart' as offline_auth;
import '../services/image_upload_service.dart';
import '../services/auto_update_service.dart';
import '../utils/formatters.dart';

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
  
  String get _userName {
    final email = widget.userData['email']?.toString();
    Map<String, dynamic> data = Map<String, dynamic>.from(widget.userData);
    if (email != null && email.isNotEmpty) {
      try {
        if (Hive.isBoxOpen('local_users')) {
          final user = Hive.box('local_users').get('user:${email.toLowerCase()}');
          if (user != null && user is Map) {
            data.addAll(Map<String, dynamic>.from(user));
          }
        }
      } catch (_) {}
    }
    return resolveUserDisplayName(data);
  }

  String get _userPhotoUrl {
    final email = widget.userData['email']?.toString();
    Map<String, dynamic> data = Map<String, dynamic>.from(widget.userData);
    if (email != null && email.isNotEmpty) {
      try {
        if (Hive.isBoxOpen('local_users')) {
          final user = Hive.box('local_users').get('user:${email.toLowerCase()}');
          if (user != null && user is Map) {
            data.addAll(Map<String, dynamic>.from(user));
          }
        }
      } catch (_) {}
    }
    return (data['profileImage'] ?? data['profilePictureUrl'] ?? data['photoUrl'] ?? data['avatarUrl'])?.toString() ?? '';
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
    _loadAvailableModules();
    _recomputeFilteredModules();
  }

  @override
  void initState() {
    super.initState();
    _loadAvailableModules();

    // ── START SYNC SERVICE ────────────────────────────────────────────────────
    final branchId = (widget.userData['branchId'] as String? ?? '').trim();
    if (branchId.isNotEmpty && branchId != _kGlobalBranchId) {
      SyncService().start(branchId);
    } else {
      // Executive roles (chairman, CEO) have branchId='all' or empty.
      // Start sync with all known real branches so data still uploads to Firestore.
      try {
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
        if (realIds.isNotEmpty) {
          SyncService().start(realIds.first, authorizedBranches: realIds);
        }
      } catch (_) {}
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
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _startBackgroundFullSync();
      });
    }
  }

  // ── Role helpers ──────────────────────────────────────────────────────────

  bool get _isGlobalExecutive =>
      ['ceo', 'chairman', 'global user'].contains(_role);

  /// Whether the user has toggled dark mode in Settings.
  bool get _userDarkMode {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        return Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true;
      }
    } catch (_) {}
    return false;
  }

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

  void _logout() async {
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
            Icon(Icons.cloud_upload_rounded, color: Color(0xFF10B981), size: 28),
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
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('📡 Broadcasting global sync to all devices & uploading local queue...'),
          ],
        ),
        backgroundColor: Color(0xFF0F766E),
        duration: Duration(seconds: 4),
      ),
    );

    try {
      // 1. Broadcast over LAN to all connected client devices & server
      RealtimeManager().sendMessage({
        'event_type': 'force_all_users_cloud_sync',
        'timestamp': DateTime.now().toIso8601String(),
        'triggeredBy': _userName,
        'triggeredByRole': _role,
        'branchId': _branchId,
      });

      // 2. Upload executive node local sync queue
      await SyncService().triggerUpload();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Global Cloud Sync completed successfully! All nodes notified.'),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('[GlobalSync] Error triggering force sync: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Sync completed with warning: $e'),
            backgroundColor: Colors.amber.shade900,
          ),
        );
      }
    }
  }



  void _changeCategory(DashboardCategoryFilter cat) {
    setState(() {
      _selectedCategory = cat;
      _searchCtrl.clear();
      _searchQuery = '';
      _searchDebounce?.cancel();
      _recomputeFilteredModules();
    });
  }

  void _openModule(AppModule module) {
    const wrappedRoles = [
      'admin', 'global admin', 'ceo', 'chairman',
      'global user', 'manager', 'hq manager',
      'supervisor', 'branch manager',
    ];
    final isWrapped = wrappedRoles.contains(_role);
    final dest = (isWrapped && module.supportsGlobalWrapper)
        ? GlobalModuleWrapper(module: module, userData: widget.userData)
        : module.builder(context, widget.userData);

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, anim, _) => dest,
        transitionsBuilder: (_, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0.025, 0), end: Offset.zero)
                .animate(CurvedAnimation(
                    parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final roleTheme = RoleThemeData.fromString(_role);

    return ValueListenableBuilder(
      valueListenable: Hive.box('app_settings').listenable(keys: ['custom_accent_color', 'is_dark_mode']),
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

        final isDark = box.get('is_dark_mode', defaultValue: false) == true;

        return RoleThemeScope(
          role: roleTheme,
          child: Builder(builder: (ctx) {
            RoleThemeData t = RoleThemeData.of(roleTheme, customColor);
            t = isDark ? t.toDarkMode() : t.toLightMode();
            final isDesktop = MediaQuery.of(ctx).size.width >= 900;

            // ── SUPERVISOR DEDICATED LAYOUT: Bottom NavBar + Module Navigation Home Hub ──
            if (_isSupervisor) {
              return FadeTransition(
                opacity: _pageOpacity,
                child: _SupervisorScaffold(state: this, t: t),
              );
            }

            return FadeTransition(
              opacity: _pageOpacity,
              child: Scaffold(
                backgroundColor: t.bg,
                body: isDesktop
                    ? Row(children: [
                        _Sidebar(state: this, t: t),
                        Expanded(
                            child:
                                _MainContent(state: this, t: t, isDesktop: true)),
                      ])
                    : _MobileLayout(state: this, t: t),
              ),
            );
          }),
        );
      },
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
    final isDark = widget.state._isDark;
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
        backgroundColor: isDark ? const Color(0xFF161B22) : t.bgCard,
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
                      color: isDark ? Colors.white : t.textPrimary,
                      letterSpacing: -0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1.5),
                  Text(
                    _getSupervisorTabSubtitle(navIndex, userName, branchName),
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF8B949E) : t.textTertiary,
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
          // Toggle Dark & Light Mode Button
          IconButton(
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? const Color(0xFFFBBF24) : t.textSecondary,
              size: 20,
            ),
            onPressed: () async {
              await UserThemeService.toggleDarkMode();
              widget.state.refresh();
            },
          ),
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout_rounded, color: Color(0xFFEF4444), size: 20),
            onPressed: widget.state._logout,
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            color: isDark ? const Color(0xFF30363D) : t.bgRule,
          ),
        ),
      ),
      body: Builder(
        builder: (ctx) {
          final curIdx = navIndex.clamp(0, 5);
          return IndexedStack(
            index: curIdx == 0 ? 0 : 1,
            children: [
              _SupervisorHomeHub(state: widget.state, t: t),
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
          color: isDark ? const Color(0xFF161B22) : t.bgCard,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.05),
              blurRadius: 14,
              offset: const Offset(0, -2),
            ),
          ],
          border: Border(
            top: BorderSide(
              color: isDark ? const Color(0xFF30363D) : t.bgRule,
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
                  onTap: () => widget.state.setSupervisorTab(0),
                ),
                _SupervisorNavItem(
                  icon: Icons.dashboard_rounded,
                  label: 'Summary',
                  isSelected: navIndex == 1,
                  accentColor: const Color(0xFF6366F1),
                  isDark: isDark,
                  onTap: () => widget.state.setSupervisorTab(1),
                ),
                _SupervisorNavItem(
                  icon: Icons.inventory_2_rounded,
                  label: 'Inventory',
                  isSelected: navIndex == 2,
                  accentColor: const Color(0xFF10B981),
                  isDark: isDark,
                  onTap: () => widget.state.setSupervisorTab(2),
                ),
                _SupervisorNavItem(
                  icon: Icons.rule_rounded,
                  label: 'Requests',
                  isSelected: navIndex == 3,
                  accentColor: const Color(0xFFF59E0B),
                  isDark: isDark,
                  onTap: () => widget.state.setSupervisorTab(3),
                ),
                _SupervisorNavItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Ledger',
                  isSelected: navIndex == 4,
                  accentColor: const Color(0xFF8B5CF6),
                  isDark: isDark,
                  onTap: () => widget.state.setSupervisorTab(4),
                ),
                _SupervisorNavItem(
                  icon: Icons.person_rounded,
                  label: 'Account',
                  isSelected: navIndex == 5,
                  accentColor: const Color(0xFF06B6D4),
                  isDark: isDark,
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
  final VoidCallback onTap;

  const _SupervisorNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.accentColor,
    required this.isDark,
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
              color: isSelected ? accentColor.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected
                      ? accentColor
                      : (isDark ? const Color(0xFF8B949E) : const Color(0xFF64748B)),
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
                      color: isSelected
                          ? accentColor
                          : (isDark ? const Color(0xFF8B949E) : const Color(0xFF64748B)),
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
    final isDark = state._isDark;
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
            Color(0xFFD97706),
            Color(0xFFF59E0B),
            Color(0xFFB45309),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
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
              color: Colors.white.withValues(alpha: 0.22),
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
                    color: Colors.white,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Congratulations! $branch is leading operational efficiency and patient throughput across GMWF healthcare centers.',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.95),
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
        gradient: const [Color(0xFF6366F1), Color(0xFF4338CA)],
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
        gradient: const [Color(0xFF10B981), Color(0xFF047857)],
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
        gradient: const [Color(0xFFF59E0B), Color(0xFFD97706)],
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
        gradient: const [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
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
        gradient: const [Color(0xFF06B6D4), Color(0xFF0E7490)],
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
    final isDark = widget.isDark;

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
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1E293B),
                        const Color(0xFF0F172A),
                      ]
                    : [
                        Colors.white,
                        const Color(0xFFF8FAFC),
                      ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _isHovered
                    ? primaryColor.withValues(alpha: isDark ? 0.7 : 0.5)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFE2E8F0)),
                width: _isHovered ? 1.5 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? primaryColor.withValues(alpha: isDark ? 0.30 : 0.16)
                      : (isDark
                          ? Colors.black.withValues(alpha: 0.25)
                          : primaryColor.withValues(alpha: 0.05)),
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
                      child: Icon(widget.icon, color: Colors.white, size: 20),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: isDark ? 0.20 : 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: isDark ? 0.4 : 0.25),
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
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                        color: _isHovered ? primaryColor : (isDark ? Colors.white38 : const Color(0xFF94A3B8)),
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
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1E293B),
                        const Color(0xFF0F172A),
                      ]
                    : [
                        Colors.white,
                        const Color(0xFFF8FAFC),
                      ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isHovered
                    ? primaryColor.withValues(alpha: isDark ? 0.7 : 0.5)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFE2E8F0)),
                width: _isHovered ? 1.5 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? primaryColor.withValues(alpha: isDark ? 0.25 : 0.12)
                      : (isDark
                          ? Colors.black.withValues(alpha: 0.20)
                          : primaryColor.withValues(alpha: 0.04)),
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
                  child: Icon(widget.icon, color: Colors.white, size: 22),
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
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                                letterSpacing: -0.2,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: isDark ? 0.20 : 0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: primaryColor.withValues(alpha: isDark ? 0.4 : 0.25),
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
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                        : primaryColor.withValues(alpha: isDark ? 0.15 : 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: _isHovered ? Colors.white : primaryColor,
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

  bool get _dark => state._isDark;
  Color get _divider => _dark ? Colors.white.withValues(alpha: 0.10) : t.accent.withValues(alpha: 0.15);
  Color get _muted => _dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
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
          child: Container(
            width: 260,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: _dark ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.65),
                  width: 1.2,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: _dark ? 0.10 : 0.05),
                  blurRadius: 28,
                  offset: const Offset(6, 0),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: _dark ? 0.35 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(2, 0),
                ),
              ],
            ),
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _dark
                          ? [
                              const Color(0xFF1E293B).withValues(alpha: 0.90),
                              const Color(0xFF0F172A).withValues(alpha: 0.84),
                            ]
                          : [
                              const Color(0xFFF8FAFC).withValues(alpha: 0.98),
                              const Color(0xFFF1F5F9).withValues(alpha: 0.94),
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
                                  t.accent.withValues(alpha: _dark ? 0.28 : 0.14),
                                  t.accent.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Bottom-Right Cyan Glow
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
                                  const Color(0xFF0EA5E9).withValues(alpha: _dark ? 0.16 : 0.08),
                                  const Color(0xFF0EA5E9).withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Sidebar Layout
                      Column(
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

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF1E293B).withValues(alpha: 0.65)
            : Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE2E8F0).withValues(alpha: 0.90),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.25 : 0.04),
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
                        color: dark ? Colors.white : const Color(0xFF0F172A),
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
                            color: dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: dark ? 0.20 : 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35), width: 0.8),
                          ),
                          child: const Text(
                            'Online',
                            style: TextStyle(
                              color: Color(0xFF10B981),
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
            color: dark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
          ),
          const SizedBox(height: 10),
          // User Role Pill & Full Name
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: (isChairman || isCeo)
                        ? [
                            const Color(0xFFF59E0B).withValues(alpha: dark ? 0.30 : 0.20),
                            const Color(0xFFD97706).withValues(alpha: dark ? 0.20 : 0.12),
                          ]
                        : [
                            t.accent.withValues(alpha: dark ? 0.30 : 0.18),
                            t.accent.withValues(alpha: dark ? 0.15 : 0.08),
                          ],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: (isChairman || isCeo)
                        ? const Color(0xFFF59E0B).withValues(alpha: dark ? 0.40 : 0.45)
                        : t.accent.withValues(alpha: dark ? 0.35 : 0.40),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (isChairman || isCeo) ? Icons.workspace_premium_rounded : Icons.verified_user_rounded,
                      size: 10,
                      color: (isChairman || isCeo) ? (dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309)) : t.accent,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      state._role.toUpperCase(),
                      style: TextStyle(
                        color: (isChairman || isCeo) ? (dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309)) : t.accent,
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
                'v${AutoUpdateService.currentVersion}',
                style: TextStyle(
                  color: dark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
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
              color: dark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
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
            accentColor: const Color(0xFF8B5CF6),
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
            accentColor: const Color(0xFFF59E0B),
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
            accentColor: const Color(0xFF10B981),
            t: t,
            dark: dark,
            onTap: () => state._confirmAndTriggerForceGlobalSync(context),
          ),
        _ActionTile(
          icon: Icons.settings_outlined,
          label: 'Settings',
          accentColor: const Color(0xFF38BDF8),
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
            accentColor: const Color(0xFF10B981),
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
          accentColor: const Color(0xFFF59E0B),
          t: t,
          dark: dark,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SupportPage())),
        ),
        _ActionTile(
          icon: Icons.logout_rounded,
          label: 'Sign Out',
          accentColor: const Color(0xFFEF4444),
          t: t,
          dark: dark,
          danger: true,
          onTap: state._logout,
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
            Colors.white,
            Color(0xFFF1F5F9),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1.0),
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

Color _getCatColor(DashboardCategoryFilter cat) {
  switch (cat) {
    case DashboardCategoryFilter.overall:
      return const Color(0xFF0EA5E9); // Sky Blue
    case DashboardCategoryFilter.office:
      return const Color(0xFF6366F1); // Royal Indigo / Purple
    case DashboardCategoryFilter.dispensary:
      return const Color(0xFF0D9488); // Teal / Emerald
    case DashboardCategoryFilter.dasterkhwaan:
      return const Color(0xFFF97316); // Warm Amber / Orange
    case DashboardCategoryFilter.madrassa:
      return const Color(0xFFE11D48); // Berry Rose
    case DashboardCategoryFilter.school:
      return const Color(0xFF10B981); // Emerald Green
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
    final catColor = _getCatColor(widget.cat);
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
                ? (dark ? catColor.withValues(alpha: 0.22) : catColor.withValues(alpha: 0.16))
                : (_hov
                    ? (dark ? Colors.white.withValues(alpha: 0.06) : catColor.withValues(alpha: 0.08))
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: sel
                  ? catColor.withValues(alpha: dark ? 0.50 : 0.45)
                  : (_hov
                      ? (dark ? Colors.white.withValues(alpha: 0.10) : catColor.withValues(alpha: 0.20))
                      : Colors.transparent),
              width: 1.0,
            ),
            boxShadow: sel
                ? [
                    BoxShadow(
                      color: catColor.withValues(alpha: dark ? 0.25 : 0.16),
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
                  color: catColor,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: catColor.withValues(alpha: 0.6),
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
                        ? const Color(0xFF1E293B)
                        : catColor.withValues(alpha: 0.10))
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sel
                      ? Colors.white.withValues(alpha: 0.35)
                      : (dark ? Colors.white.withValues(alpha: 0.06) : catColor.withValues(alpha: 0.20)),
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
                    ? Colors.white
                    : (dark ? const Color(0xFFCBD5E1) : catColor),
                size: 15,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: sel
                      ? (dark ? Colors.white : catColor)
                      : (_hov
                          ? (dark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A))
                          : (dark ? const Color(0xFFCBD5E1) : const Color(0xFF334155))),
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
                  color: catColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: catColor.withValues(alpha: 0.6),
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
                ? (dark ? t.accent.withValues(alpha: 0.16) : t.accent.withValues(alpha: 0.08))
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
                    ? (dark ? const Color(0xFF1E293B) : t.accent.withValues(alpha: 0.08))
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _hov ? Colors.white.withValues(alpha: 0.3) : Colors.transparent,
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
                    ? Colors.white
                    : (dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                size: 15,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                widget.module.title,
                style: TextStyle(
                  color: _hov
                      ? (dark ? Colors.white : const Color(0xFF0F172A))
                      : (dark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
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
        ? const Color(0xFFEF4444)
        : (widget.accentColor ?? widget.t.accent);

    final col = widget.danger
        ? const Color(0xFFEF4444)
        : (widget.dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B));

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
                ? effectiveAccent.withValues(alpha: widget.dark ? 0.16 : 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hov
                  ? effectiveAccent.withValues(alpha: widget.dark ? 0.35 : 0.25)
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
                        ? const Color(0xFFEF4444)
                        : (widget.dark ? Colors.white : const Color(0xFF0F172A)))
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

  bool get _dark => state._isDark;

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

    return AppBar(
      backgroundColor: _dark ? const Color(0xFF0D1117) : t.bgCard,
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
                        color: _dark ? Colors.white : t.textPrimary,
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
                        'v${AutoUpdateService.currentVersion}',
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
                    color: _dark ? const Color(0xFF8B949E) : t.textTertiary,
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
              colors: (isChairman || isCeo)
                  ? [
                      const Color(0xFFF59E0B).withValues(alpha: _dark ? 0.25 : 0.18),
                      const Color(0xFFD97706).withValues(alpha: _dark ? 0.15 : 0.08),
                    ]
                  : [
                      t.accent.withValues(alpha: _dark ? 0.25 : 0.15),
                      t.accent.withValues(alpha: _dark ? 0.12 : 0.06),
                    ],
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (isChairman || isCeo)
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                  : t.accent.withValues(alpha: 0.3),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                (isChairman || isCeo) ? Icons.workspace_premium_rounded : Icons.verified_user_rounded,
                size: 11,
                color: (isChairman || isCeo) ? const Color(0xFFF59E0B) : t.accent,
              ),
              const SizedBox(width: 4),
              Text(
                state._role.toUpperCase(),
                style: TextStyle(
                  color: (isChairman || isCeo) ? const Color(0xFFF59E0B) : t.accent,
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
            icon: const Icon(Icons.preview_rounded, color: Colors.amberAccent, size: 20),
            onPressed: () => RoleSimulatorService.showRoleSelectorModal(context),
          ),
        if (state._isFullExecutive || state._isGlobalExecutive)
          IconButton(
            tooltip: 'Force Global Cloud Sync',
            icon: const Icon(Icons.cloud_upload_rounded, color: Color(0xFF10B981), size: 21),
            onPressed: () => state._confirmAndTriggerForceGlobalSync(context),
          ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(
            Icons.settings_outlined,
            color: _dark ? Colors.white70 : t.textSecondary,
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
          color: _dark ? const Color(0xFF30363D) : t.bgRule,
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
    final filtered = state._cachedFilteredModules;
    final double hPad = isDesktop ? 36 : 20;

    final showSnapshot = state._selectedCategory == DashboardCategoryFilter.overall && state._searchQuery.isEmpty;

    return Column(
      children: [
        // Built ONCE at the top — never re-animates or rebuilds on category tab changes
        _HeroHeader(state: state, t: t, isDesktop: isDesktop),
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

  bool get _dark => state._isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your Modules',
              style: TextStyle(
                  color: _dark ? const Color(0xFFE6EDF3) : t.textPrimary,
                  fontSize: isDesktop ? 20 : 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text('$count available',
                key: ValueKey(count),
                style: TextStyle(
                    color: _dark ? const Color(0xFF8B949E) : t.textTertiary,
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

  bool get _dark => state._isDark;

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
      ? '$timeEmoji GOOD $timeOfDayUpper, MR. $userRole'
      : '$timeEmoji GOOD $timeOfDayUpper';

  final avatarSize = isDesktop ? 76.0 : 64.0;
  final primaryThemeColor = t.accent;

  return Container(
    margin: EdgeInsets.fromLTRB(hPad, isDesktop ? 22 : 16, hPad, 0),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28.0),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [
                const Color(0xFF1E293B),
                const Color(0xFF0F172A),
              ]
            : [
                const Color(0xFFFFFBEB),
                const Color(0xFFF8FAFC),
                Colors.white,
              ],
      ),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.16)
            : const Color(0xFFF59E0B).withValues(alpha: 0.25),
        width: 1.2,
      ),
      boxShadow: [
        BoxShadow(
          color: primaryThemeColor.withValues(alpha: isDark ? 0.25 : 0.12),
          blurRadius: 24,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.04),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(28.0),
      child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28.0),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF1E293B).withValues(alpha: 0.90),
                      const Color(0xFF0F172A).withValues(alpha: 0.82),
                    ]
                  : [
                      const Color(0xFFFFFBEB).withValues(alpha: 0.98),
                      const Color(0xFFF8FAFC).withValues(alpha: 0.94),
                      Colors.white.withValues(alpha: 0.98),
                    ],
            ),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.16)
                  : const Color(0xFFF59E0B).withValues(alpha: 0.25),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.25 : 0.08),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.03),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Ambient Radial Glow Spot (Top-Left behind greeting/avatar)
              Positioned(
                top: -50,
                left: -50,
                width: 240,
                height: 240,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.35 : 0.18),
                          primaryThemeColor.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Ambient Radial Glow Spot (Top-Right sky-blue accent glow)
              Positioned(
                top: -40,
                right: 40,
                width: 220,
                height: 220,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFF0EA5E9).withValues(alpha: isDark ? 0.22 : 0.12),
                          const Color(0xFF0EA5E9).withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Seamlessly Dissolved Islamic Pattern Watermark on Right
              Positioned(
                right: -20,
                top: -20,
                bottom: -20,
                width: isDesktop ? 340 : 220,
                child: IgnorePointer(
                  child: ShaderMask(
                    shaderCallback: (rect) {
                      return RadialGradient(
                        center: Alignment.centerRight,
                        radius: 0.85,
                        colors: [
                          Colors.black.withValues(alpha: isDark ? 0.35 : 0.18),
                          Colors.transparent,
                        ],
                        stops: const [0.2, 1.0],
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.dstIn,
                    child: Opacity(
                      opacity: isDark ? 0.30 : 0.15,
                      child: Image.asset(
                        'assets/images/1.webp',
                        color: isDark ? Colors.white : primaryThemeColor,
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
                padding: EdgeInsets.all(isDesktop ? 24 : 18),
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
                            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.18 : 0.10),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.45 : 0.35),
                                width: 1.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.20 : 0.08),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  greetingBadgeText,
                                  style: TextStyle(
                                    color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Profile Avatar, User Name & Date Row
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Interactive Avatar with Luxury Gold Halo & Online Indicator
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
                                            gradient: const LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                Color(0xFFFBBF24),
                                                Color(0xFFD97706),
                                              ],
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFFF59E0B).withValues(alpha: 0.40),
                                                blurRadius: 12,
                                                spreadRadius: 1,
                                              ),
                                            ],
                                          ),
                                          padding: const EdgeInsets.all(2.5),
                                          child: ClipOval(
                                            child: _buildUserHeroAvatar(userPhotoUrl, userName, t, size: avatarSize),
                                          ),
                                        ),
                                        Positioned(
                                          right: 2,
                                          bottom: 2,
                                          child: Container(
                                            width: 15,
                                            height: 15,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF10B981),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: isDark ? const Color(0xFF0F172A) : Colors.white,
                                                width: 2.0,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(0xFF10B981).withValues(alpha: 0.6),
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 18),
                              // User Display Name & Date Subtitle
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      userName,
                                      style: TextStyle(
                                        color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                                        fontSize: isDesktop ? 24 : 19,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.3,
                                        height: 1.15,
                                      ),
                                      softWrap: true,
                                      maxLines: 2,
                                    ),
                                    const SizedBox(height: 5),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.calendar_today_outlined,
                                          size: 13,
                                          color: isDark
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF64748B),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          dateStr,
                                          style: TextStyle(
                                            color: isDark
                                                ? const Color(0xFF94A3B8)
                                                : const Color(0xFF64748B),
                                            fontSize: 12.5,
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
                          const SizedBox(height: 18),

                          // Bottom Metadata Badges Row (Strict Single-Line on Mobile)
                          FittedBox(
                            alignment: Alignment.centerLeft,
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ExecutiveGlassPill(
                                  label: userRole,
                                  icon: (isChairman || isCeo)
                                      ? Icons.workspace_premium_rounded
                                      : Icons.shield_outlined,
                                  accentColor: const Color(0xFFF59E0B),
                                  isDark: isDark,
                                  isCompact: !isDesktop,
                                ),
                                SizedBox(width: isDesktop ? 8 : 5),
                                _ExecutiveGlassPill(
                                  label: '${state._availableModules.length} Modules',
                                  icon: Icons.grid_view_rounded,
                                  accentColor: const Color(0xFF6366F1),
                                  isDark: isDark,
                                  isCompact: !isDesktop,
                                ),
                                if (state._isSupervisor) ...[
                                  if ((state.widget.userData['branchId'] ?? '').toString().isNotEmpty) ...[
                                    SizedBox(width: isDesktop ? 8 : 5),
                                    _ExecutiveGlassPill(
                                      label: (state.widget.userData['branchId'] ?? '').toString().toUpperCase(),
                                      icon: Icons.storefront_rounded,
                                      accentColor: const Color(0xFF10B981),
                                      isDark: isDark,
                                      isCompact: !isDesktop,
                                    ),
                                  ],
                                ] else ...[
                                  SizedBox(width: isDesktop ? 8 : 5),
                                  _ExecutiveGlassPill(
                                    label: 'Global Access',
                                    icon: Icons.public_rounded,
                                    accentColor: const Color(0xFF0EA5E9),
                                    isDark: isDark,
                                    isCompact: !isDesktop,
                                  ),
                                  SizedBox(width: isDesktop ? 8 : 5),
                                  _ExecutiveGlassPill(
                                    label: 'Live Network',
                                    icon: Icons.sensors_rounded,
                                    accentColor: const Color(0xFF10B981),
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
                        padding: const EdgeInsets.only(left: 16, right: 8),
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
                                        (isDark
                                                ? const Color(0xFF0EA5E9)
                                                : const Color(0xFFF59E0B))
                                            .withValues(alpha: isDark ? 0.18 : 0.10),
                                        Colors.transparent,
                                      ],
                                      radius: 0.75,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 290,
                              height: 220,
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
                                  repeat: true,
                                  errorBuilder: (context, error, stackTrace) => Icon(
                                    Icons.dashboard_customize_rounded,
                                    size: 64,
                                    color: isDark
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFF0284C7),
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
      ),
  );
}

class _ExecutiveGlassPill extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color accentColor;
  final bool isDark;
  final bool isPulse;
  final bool isCompact;

  const _ExecutiveGlassPill({
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
          color: widget.isDark
              ? (_isHovered
                  ? widget.accentColor.withValues(alpha: 0.22)
                  : const Color(0xFF1E293B).withValues(alpha: 0.70))
              : (_isHovered
                  ? widget.accentColor.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.92)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? widget.accentColor.withValues(alpha: widget.isDark ? 0.65 : 0.55)
                : (widget.isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : widget.accentColor.withValues(alpha: 0.25)),
            width: 0.8,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: widget.isDark ? 0.35 : 0.20),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: widget.isDark ? 0.15 : 0.06),
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
                color: widget.accentColor.withValues(alpha: widget.isDark ? 0.20 : 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(widget.icon, size: widget.isCompact ? 11 : 13, color: widget.accentColor),
            ),
            SizedBox(width: widget.isCompact ? 5.0 : 7.0),
            Text(
              widget.label,
              style: TextStyle(
                color: widget.isDark
                    ? (_isHovered ? Colors.white : const Color(0xFFE2E8F0))
                    : (_isHovered ? const Color(0xFF0F172A) : const Color(0xFF334155)),
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

  final userData = state.widget.userData;
  final lastUpdatedByName = (userData['photoUpdatedByName'] as String?) ?? '';
  final rawTime = userData['photoUpdatedAt'];
  final lastUpdatedTime = (rawTime != null)
      ? (rawTime is Timestamp
          ? rawTime.toDate().toLocal().toString().split('.')[0]
          : rawTime.toString())
      : '';

  showDialog(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (context, setDialogState) {
        final currentPhoto = state._userPhotoUrl;
        final hasPhoto = currentPhoto.trim().isNotEmpty;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: t.accent.withValues(alpha: 0.4), width: 1.8),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.25),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header bar with Title & Close Button
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_circle_rounded, color: t.accent, size: 22),
                        const SizedBox(width: 8),
                        const Text(
                          'Profile Photo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                      onPressed: () => Navigator.pop(dialogCtx),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Enlarged Avatar Preview Container (Crystal Clear 320px display)
                Container(
                  width: 320,
                  height: 320,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFF59E0B), width: 4.0),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                        blurRadius: 24,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: _buildUserHeroAvatar(currentPhoto, userName, t, size: 320),
                  ),
                ),
                const SizedBox(height: 20),

                // User Name & Role Pill
                Text(
                  userName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    userRole,
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

                // Audit Trail info badge (Who updated this info last)
                if (lastUpdatedByName.isNotEmpty || lastUpdatedTime.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.history_rounded, size: 13, color: Colors.white60),
                            const SizedBox(width: 4),
                            Text(
                              'Last Photo Audit',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 10.5, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Updated by: ${lastUpdatedByName.isNotEmpty ? lastUpdatedByName : "System"}${lastUpdatedTime.isNotEmpty ? ' ($lastUpdatedTime)' : ''}',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // Action Buttons Row: Change Photo & Remove Photo
                Row(
                  children: [
                    // Change Photo Button
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final source = await ImageUploadService.showSourceDialog(context, title: 'Choose Profile Photo Source');
                          if (source == null) return;

                          final newBase64 = await ImageUploadService.pickAndProcessImage(source: source, maxWidth: 512, maxHeight: 512);
                          if (newBase64 == null || newBase64.isEmpty) return;

                          await _updateUserProfilePhoto(
                            state: state,
                            newBase64: newBase64,
                            action: 'PHOTO_CHANGED',
                          );

                          setDialogState(() {});
                          if (dialogCtx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ Profile photo updated successfully!'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.photo_camera_rounded, size: 18),
                        label: const Text('Change Photo'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 2,
                        ),
                      ),
                    ),
                    if (hasPhoto) ...[
                      const SizedBox(width: 12),
                      // Remove Photo Button
                      OutlinedButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (confirmCtx) => AlertDialog(
                              backgroundColor: const Color(0xFF1E293B),
                              title: const Text('Remove Profile Photo?', style: TextStyle(color: Colors.white)),
                              content: const Text('Are you sure you want to remove your profile photo?', style: TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(confirmCtx, false),
                                  child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(confirmCtx, true),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                  child: const Text('Remove', style: TextStyle(color: Colors.white)),
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('🗑️ Profile photo removed.'),
                                backgroundColor: Colors.orange,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                        label: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.redAccent, width: 1.2),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(branchId)
            .collection('users')
            .doc(updaterUid)
            .set(updateData, SetOptions(merge: true));
      }

      try {
        final cgSnap = await FirebaseFirestore.instance
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
    debugPrint('[GlobalDashboard] Error syncing updated profile photo to cloud: $e');
  }
}

String _timeOfDayString(int hour) {
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  return 'evening';
}

String _weekdayFull(int d) => ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d - 1];
String _monthFull(int m) => ['January','February','March','April','May','June','July','August','September','October','November','December'][m-1];

Widget _buildUserHeroAvatar(String photoUrl, String userName, RoleThemeData t, {double size = 64}) {
  final str = photoUrl.trim();
  Widget child;
  if (str.isNotEmpty) {
    final bytes = ImageUploadService.decodeBase64ToBytes(str);
    if (bytes != null) {
      child = Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size));
    } else if (str.startsWith('http://') || str.startsWith('https://')) {
      child = Image.network(str, width: size, height: size, fit: BoxFit.cover, errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size));
    } else if (File(str).existsSync()) {
      child = Image.file(File(str), width: size, height: size, fit: BoxFit.cover, errorBuilder: (c, e, s) => _buildUserAvatarFallback(userName, t, size));
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
      border: Border.all(color: Colors.white.withValues(alpha: 0.95), width: 3.0),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
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
    color: t.accent.withValues(alpha: 0.8),
    alignment: Alignment.center,
    child: Text(
      initial,
      style: TextStyle(
        color: Colors.white,
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

  bool get _dark => state._isDark;

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
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
            color: _dark ? const Color(0xFF161B22) : t.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: _dark ? const Color(0xFF30363D) : t.bgRule,
                width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
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
                color: _dark ? const Color(0xFFE6EDF3) : t.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Search modules…',
              hintStyle: TextStyle(
                  color: _dark ? const Color(0xFF8B949E) : t.textTertiary,
                  fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded,
                  color: _dark ? const Color(0xFF8B949E) : t.textTertiary,
                  size: 20),
              suffixIcon: state._searchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close_rounded,
                          color: _dark
                              ? const Color(0xFF8B949E)
                              : t.textTertiary,
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

  bool get _dark => state._isDark;

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
                    _dark ? t.accent.withValues(alpha: 0.2) : t.accent,
                labelStyle: TextStyle(
                    color: sel
                        ? (_dark ? t.accent : Colors.white)
                        : (_dark
                            ? const Color(0xFF8B949E)
                            : t.textSecondary),
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 12),
                backgroundColor:
                    _dark ? const Color(0xFF161B22) : t.bgCard,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                        color: sel
                            ? t.accent
                            : (_dark
                                ? const Color(0xFF30363D)
                                : t.bgRule))),
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

  bool get _dark => state._isDark;

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
              color: _dark ? const Color(0xFF161B22) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _dark ? const Color(0xFF30363D) : t.bgRule),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.school_outlined, size: 36, color: Color(0xFF2563EB)),
                ),
                const SizedBox(height: 18),
                Text(
                  'School is not available in $branchName yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: _dark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The school facility is not enabled or registered for the $branchName branch.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: _dark ? const Color(0xFF8B949E) : const Color(0xFF64748B),
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
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: _dark ? const Color(0xFF161B22) : t.accentMuted.withValues(alpha: 0.3),
                shape: BoxShape.circle,
                border: Border.all(
                    color: _dark ? const Color(0xFF30363D) : t.bgRule),
              ),
              child: Icon(Icons.search_off_rounded,
                  size: 32,
                  color: _dark ? const Color(0xFF8B949E) : t.textTertiary),
            ),
            const SizedBox(height: 16),
            Text('No modules found',
                style: TextStyle(
                    color: _dark ? const Color(0xFFE6EDF3) : t.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(state._searchQuery.isNotEmpty ? '"${state._searchQuery}" didn\'t match anything' : 'No modules available for this category',
                style: TextStyle(
                    color: _dark ? const Color(0xFF8B949E) : t.textTertiary,
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
    final dark = state._isDark;
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
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 15, color: color),
                ),
                const SizedBox(width: 8),
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: dark ? const Color(0xFFE6EDF3) : t.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
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
          buildCategorySection('Core & Executive Operations', Icons.star_rounded, const Color(0xFFF59E0B), featured),
        if (officeMods.isNotEmpty)
          buildCategorySection('Office & Financial ERP', Icons.business_center_rounded, const Color(0xFF6366F1), officeMods),
        if (medicalMods.isNotEmpty)
          buildCategorySection('Medical & Dispensary Services', Icons.local_hospital_rounded, const Color(0xFF0D9488), medicalMods),
        if (welfareMods.isNotEmpty)
          buildCategorySection('Welfare & Relief Services', Icons.volunteer_activism_rounded, const Color(0xFFF97316), welfareMods),
        if (eduMods.isNotEmpty)
          buildCategorySection('Madrassa & School Education', Icons.school_rounded, const Color(0xFF8B5CF6), eduMods),
        if (restMods.isNotEmpty)
          buildCategorySection('System & Maintenance', Icons.settings_rounded, const Color(0xFF64748B), restMods),
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
    final w = MediaQuery.of(context).size.width;
    final tiny = w < 480;

    // Get color & label for category with individual rich palette & ambient glow themes
    final Color categoryColor;
    final Color ambientGlowColor;
    final String categoryLabel;

    switch (widget.module.category) {
      case ModuleCategory.office:
        categoryColor = widget.module.id == 'finance' ? const Color(0xFF8B5CF6) : const Color(0xFF6366F1); // Soft Purple / Indigo
        ambientGlowColor = const Color(0xFF818CF8);
        categoryLabel = widget.module.id == 'finance' ? 'HR / FINANCE' : 'OFFICE';
        break;
      case ModuleCategory.dispensary:
        categoryColor = const Color(0xFF0EA5E9); // Sky Blue / Teal
        ambientGlowColor = const Color(0xFF38BDF8);
        categoryLabel = 'MEDICAL';
        break;
      case ModuleCategory.dasterkhwaan:
        categoryColor = const Color(0xFFF97316); // Warm Orange
        ambientGlowColor = const Color(0xFFFB923C);
        categoryLabel = 'WELFARE';
        break;
      case ModuleCategory.madrassa:
        categoryColor = const Color(0xFFE11D48); // Deep Rose / Berry
        ambientGlowColor = const Color(0xFFF43F5E);
        categoryLabel = 'MADRASSA';
        break;
      case ModuleCategory.school:
        categoryColor = const Color(0xFF10B981); // Emerald / Sage Green
        ambientGlowColor = const Color(0xFF34D399);
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
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              // Ambient outer radial glow shadow
              boxShadow: [
                BoxShadow(
                  color: ambientGlowColor.withValues(alpha: _hov ? (dark ? 0.35 : 0.25) : (dark ? 0.14 : 0.08)),
                  blurRadius: _hov ? 28 : 16,
                  spreadRadius: _hov ? 2 : 0,
                  offset: Offset(0, _hov ? 10 : 4),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.40 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    // High-blur translucent frosted glass background with gradient tint
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? [
                              const Color(0xFF1E293B).withValues(alpha: _hov ? 0.85 : 0.65),
                              const Color(0xFF0F172A).withValues(alpha: _hov ? 0.80 : 0.60),
                            ]
                          : [
                              Colors.white.withValues(alpha: _hov ? 0.90 : 0.78),
                              Colors.white.withValues(alpha: _hov ? 0.75 : 0.60),
                            ],
                    ),
                    // Subtle top/left inner white border stroke (1px at 30% opacity)
                    border: Border.all(
                      color: _hov
                          ? categoryColor.withValues(alpha: dark ? 0.65 : 0.50)
                          : (dark
                              ? Colors.white.withValues(alpha: 0.16)
                              : Colors.white.withValues(alpha: 0.60)),
                      width: _hov ? 1.5 : 1.0,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Ambient Radial Glow Spot (Top-Left behind icon)
                      Positioned(
                        top: -30,
                        left: -30,
                        width: 140,
                        height: 140,
                        child: IgnorePointer(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  ambientGlowColor.withValues(alpha: _hov ? (dark ? 0.35 : 0.25) : (dark ? 0.18 : 0.12)),
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
                                        color: Colors.white.withValues(alpha: 0.35),
                                        width: 1.0,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: categoryColor.withValues(alpha: _hov ? 0.45 : 0.30),
                                          blurRadius: _hov ? 12 : 8,
                                          offset: const Offset(0, 4),
                                        ),
                                        BoxShadow(
                                          color: Colors.white.withValues(alpha: 0.25),
                                          blurRadius: 1,
                                          offset: const Offset(-1, -1),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      widget.module.icon,
                                      color: Colors.white,
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
                                          color: dark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
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
                                            ? Colors.white.withValues(alpha: 0.08)
                                            : categoryColor.withValues(alpha: 0.10)),
                                    border: Border.all(
                                      color: _hov
                                          ? Colors.transparent
                                          : (dark
                                              ? Colors.white.withValues(alpha: 0.20)
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
                                        color: _hov ? Colors.white : categoryColor,
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
                                color: dark
                                    ? (_hov ? const Color(0xFFCBD5E1) : const Color(0xFF94A3B8))
                                    : (_hov ? const Color(0xFF475569) : const Color(0xFF64748B)),
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
      ),
    );
  }
}