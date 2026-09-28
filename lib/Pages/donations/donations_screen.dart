// lib/pages/donations/donations_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../../services/local_storage_service.dart';
import '../../services/donations_local_storage.dart';
import '../../services/user_theme_service.dart';
import '../../theme/role_theme_provider.dart';
import '../../theme/app_theme.dart';
import 'donations_shared.dart';
import 'donations_dashboard.dart';
import 'donors_registry.dart';
import 'donation_boxes_screen.dart';
import 'donation_pagination_provider.dart';
import 'widgets/add_donation_wizard.dart';
import '../../models/donation_models.dart';
import '../../services/sync_service.dart';
import '../../widgets/global_module_wrapper.dart';
import '../../design/design_system.dart';
import 'package:motion_tab_bar_v2/motion-tab-bar.dart';
import 'package:motion_tab_bar_v2/motion-tab-controller.dart';

const String kStatusPending = 'pending';

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN TOKENS
// ─────────────────────────────────────────────────────────────────────────────

class DonDS {
  static const headerTop    = Color(0xFF0D1F1F);
  static const headerBot    = Color(0xFF163030);
  static const headerBorder = Color(0xFF1F3D3D);
  static const teal         = Color(0xFF0D9488);
  static const tealLight    = Color(0xFF2DD4BF);
  static const tealMuted    = Color(0x1A0D9488);
  // Keep amber only for currency/financial amounts — NOT for status
  static const amber        = Color(0xFFF59E0B);
  static const amberMuted   = Color(0x1AF59E0B);
  static const onDark       = Color(0xFFFFFFFF);
  static const onDarkSub    = Color(0xFF94B4B4);
  static const onDarkMuted  = Color(0xFF4D7070);
}

// UserRole moved to donations_shared.dart

// ─────────────────────────────────────────────────────────────────────────────
// DONATIONS SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class DonationsScreen extends ConsumerStatefulWidget {
  final String   branchId, username, branchName, userId;
  final UserRole role;
  final List<String> allBranchIds;
  final List<String> allBranchNames;
  final bool isEmbedded;

  const DonationsScreen({
    super.key,
    required this.branchId,
    required this.username,
    required this.branchName,
    required this.userId,
    required this.role,
    this.allBranchIds   = const [],
    this.allBranchNames = const [],
    this.isEmbedded     = false,
  });

  const DonationsScreen.embedded({
    super.key,
    this.branchId       = '',
    this.username       = '',
    this.branchName     = '',
    this.userId         = '',
    this.role           = UserRole.staff,
    this.allBranchIds   = const [],
    this.allBranchNames = const [],
    this.isEmbedded     = true,
  });

  factory DonationsScreen.withStringRole({
    Key?   key,
    required String branchId,
    required String username,
    String branchName    = '',
    String userId        = '',
    String role          = 'staff',
    List<String> allBranchIds   = const [],
    List<String> allBranchNames = const [],
  }) => DonationsScreen(
    key: key,
    branchId: branchId, username: username,
    branchName: branchName, userId: userId,
    role: UserRoleX.fromString(role),
    allBranchIds: allBranchIds, allBranchNames: allBranchNames,
  );

  @override
  ConsumerState<DonationsScreen> createState() => _DonationsScreenState();
}

class _DonationsScreenState extends ConsumerState<DonationsScreen> with TickerProviderStateMixin {
  MotionTabBarController? _motionTabController;
  TabController? _mobileTabController;
  int _selectedDesktopTab = 0;
  DonationCategory _selectedCategory = DonationCategory.all;
  late String _viewingBranchId;
  late String _viewingBranchName;

  // Auto-fetched branch list for HQ Manager / Chairman
  List<({String id, String name})> _fetchedBranches = [];
  bool _fetchingBranches = false;

  void _initControllers() {
    if (_motionTabController == null) {
      _motionTabController = MotionTabBarController(
        initialIndex: _selectedDesktopTab,
        length: 3,
        vsync: this,
      );
      _mobileTabController = _motionTabController;
      _mobileTabController?.addListener(_onTabChanged);
    }
  }

  void _onTabChanged() {
    if (_mobileTabController != null && !_mobileTabController!.indexIsChanging) {
      if (mounted) {
        setState(() => _selectedDesktopTab = _mobileTabController!.index);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _initControllers();

    final isExplicitBranch = widget.branchId.isNotEmpty &&
        widget.branchId != 'global' &&
        widget.branchId != 'all';

    if (isExplicitBranch) {
      _viewingBranchId   = widget.branchId;
      _viewingBranchName = widget.branchName.isNotEmpty
          ? widget.branchName
          : resolveBranchName(widget.branchId);
    } else if (widget.allBranchIds.isNotEmpty && !widget.role.canSeeAllBranches) {
      _viewingBranchId   = widget.allBranchIds.first;
      _viewingBranchName = widget.allBranchNames.isNotEmpty
          ? widget.allBranchNames.first
          : _viewingBranchId;
    } else {
      _viewingBranchId   = 'all';
      _viewingBranchName = 'All Branches (Consolidated)';
    }

    final effectiveSyncBranch = _viewingBranchId != 'all' ? _viewingBranchId : (widget.allBranchIds.isNotEmpty ? widget.allBranchIds.first : 'karachi');
    SyncService().start(effectiveSyncBranch, authorizedBranches: widget.allBranchIds);

    _loadAllBranches();
  }

  @override
  void didUpdateWidget(covariant DonationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId || oldWidget.branchName != widget.branchName) {
      final isExplicitBranch = widget.branchId.isNotEmpty &&
          widget.branchId != 'global' &&
          widget.branchId != 'all';
      setState(() {
        if (isExplicitBranch) {
          _viewingBranchId   = widget.branchId;
          _viewingBranchName = widget.branchName.isNotEmpty
              ? widget.branchName
              : resolveBranchName(widget.branchId);
        } else {
          _viewingBranchId   = 'all';
          _viewingBranchName = 'All Branches (Consolidated)';
        }
      });
    }
  }

  Future<void> _loadAllBranches() async {
    if (_fetchingBranches) return;
    setState(() => _fetchingBranches = true);
    try {
      // 1. Check local cached branches first (0 Firestore reads)
      final local = LocalStorageService.getLocalBranchesList();
      if (local.isNotEmpty) {
        final branches = local.map((d) {
          final id = d['id'] as String;
          final name = (d['name'] as String? ?? id);
          return (id: id, name: name);
        }).toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        if (mounted) {
          setState(() {
            _fetchedBranches = branches;
            if (_viewingBranchId.isEmpty || _viewingBranchId == 'global') {
              if (widget.branchId == 'all' || widget.branchId.isEmpty || widget.branchId == 'global') {
                _viewingBranchId = 'all';
                _viewingBranchName = 'All Branches (Consolidated)';
              } else if (branches.isNotEmpty) {
                _viewingBranchId   = branches.first.id;
                _viewingBranchName = branches.first.name;
              }
            } else if (_viewingBranchId == 'all') {
              _viewingBranchName = 'All Branches (Consolidated)';
            }
          });
          return;
        }
      }

      final snap = await FirebaseFirestore.instance.collection('branches').get();
      final branches = snap.docs.map((d) {
        final name = (d.data()['name'] as String? ?? d.id);
        return (id: d.id, name: name);
      }).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (!mounted) return;
      setState(() {
        _fetchedBranches = branches;
        // If we had no valid branch selected yet, pick the first one or 'all'
        if (_viewingBranchId.isEmpty || _viewingBranchId == 'global') {
          if (widget.branchId == 'all' || widget.branchId.isEmpty || widget.branchId == 'global') {
            _viewingBranchId = 'all';
            _viewingBranchName = 'All Branches (Consolidated)';
          } else if (branches.isNotEmpty) {
            _viewingBranchId   = branches.first.id;
            _viewingBranchName = branches.first.name;
          }
        } else if (_viewingBranchId == 'all') {
          _viewingBranchName = 'All Branches (Consolidated)';
        }
      });
    } catch (e) {
      debugPrint('DonationsScreen: Failed to load branches: $e');
    } finally {
      if (mounted) setState(() => _fetchingBranches = false);
    }
  }

  bool _isSyncing = false;

  Future<void> _performSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      // 1. Flush any pending local changes first
      try {
        SyncService().triggerUpload();
      } catch (e) {
        debugPrint('[DonationsScreen] triggerUpload error: $e');
      }

      final isHQOrAdmin = widget.role.canSeeAllBranches ||
          widget.role == UserRole.hqManager ||
          widget.role == UserRole.chairman ||
          widget.role == UserRole.manager;

      int count = 0;
      if (isHQOrAdmin) {
        // Download all donations across branches or current branch and save permanently to Hive
        count = await DonationsLocalStorage.downloadAllDonations(
          _viewingBranchId,
          force: true,
          allTime: true,
        );
        // Also download donors
        await DonationsLocalStorage.downloadDonors(_viewingBranchId, force: true);
      } else {
        // Download only this user's collected donations and save locally forever
        count = await DonationsLocalStorage.downloadUserDonations(
          branchId: _viewingBranchId,
          username: _effectiveUsername,
          userId: widget.userId,
        );
      }

      ref.refresh(donationPaginationFamily(DonationFetchConfig(branchId: _viewingBranchId)));

      if (mounted) {
        final msg = isHQOrAdmin
            ? 'Sync Complete: $count donations saved permanently to local storage.'
            : 'Sync Complete: $count of your collected donations saved locally.';
        AppFeedback.showSuccess(context, msg);
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, 'Sync error: $e');
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());

  dynamic get _col {
    if (_viewingBranchId == 'all' || _viewingBranchId.isEmpty) return 'all';
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(_viewingBranchId)
        .collection('donations');
  }

  Future<String> _nextReceiptNumber() async {
    try { return await LocalStorageService.nextReceiptNumber(_viewingBranchId); }
    catch (_) { return 'TEMP-${DateTime.now().millisecondsSinceEpoch}'; }
  }

  List<({String id, String name})> get _branchOptions {
    if (_fetchedBranches.isNotEmpty) {
      return [
        (id: 'all', name: 'All Branches (Consolidated)'),
        ..._fetchedBranches,
      ];
    }
    if (widget.allBranchIds.isNotEmpty) {
      return [
        (id: 'all', name: 'All Branches (Consolidated)'),
        ...List.generate(widget.allBranchIds.length, (i) {
          final id   = widget.allBranchIds[i];
          final name = i < widget.allBranchNames.length
              ? widget.allBranchNames[i]
              : resolveBranchName(id);
          return (id: id, name: name);
        }),
      ];
    }
    return [
      (id: widget.branchId, name: widget.branchName.isNotEmpty ? widget.branchName : resolveBranchName(widget.branchId)),
    ];
  }

  String get _effectiveUsername {
    if (widget.username.isNotEmpty && widget.username != 'Staff' && widget.username != 'User') {
      return widget.username;
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data');
        if (uData is Map) {
          final n = (uData['name'] ?? uData['username'] ?? uData['fullName'])?.toString();
          if (n != null && n.trim().isNotEmpty) return n;
        }
      }
    } catch (_) {}
    return widget.username.isNotEmpty ? widget.username : 'Staff';
  }

  String get _effectiveBranchName {
    if (_viewingBranchName.isNotEmpty && _viewingBranchName != 'Loading...') {
      return _viewingBranchName;
    }
    if (widget.branchName.isNotEmpty && widget.branchName != 'Loading...') {
      return widget.branchName;
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data');
        if (uData is Map && uData['branchName'] != null) {
          return uData['branchName'].toString();
        }
      }
    } catch (_) {}
    return resolveBranchName(widget.branchId);
  }

  bool get _canSwitchBranch {
    if (GlobalModuleWrapper.isWrapped(context)) return false;
    return widget.role.canSeeAllBranches && _branchOptions.length > 1;
  }

  void _switchBranch(String id, String name) =>
      setState(() { _viewingBranchId = id; _viewingBranchName = name; });

  @override
  void dispose() {
    _mobileTabController?.removeListener(_onTabChanged);
    _motionTabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _initControllers();
    return ValueListenableBuilder<Box>(
      valueListenable: UserThemeService.listenable(),
      builder: (context, _, child) {
        final t = RoleThemeScope.dataOf(context);
        final isMobile = GBreakpoint.isCompact(context);

        final displayUser = _effectiveUsername;
        final displayBranch = _effectiveBranchName;

        final views = [
          _donationsTab(),
          DonorRegistryWidget(
            branchId: _viewingBranchId,
            branchName: displayBranch,
          ),
          DonationBoxesWidget(
            branchId: _viewingBranchId,
            branchName: displayBranch,
            username: displayUser,
            role: widget.role,
          ),
        ];

        if (widget.isEmbedded) {
          return Scaffold(
            backgroundColor: t.bg,
            body: _donationsTab(),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: _onAddTap,
              elevation: 4,
              highlightElevation: 8,
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded, size: 22),
              label: const Text(
                'New Receipt',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: t.bg,
          body: Column(
            children: [
              // ── Unified Header matching branches.dart ──
              _buildBranchesStyleHeader(context, t, isMobile, displayBranch, displayUser),

              // ── Tab Views Stack ──
              Expanded(
                child: isMobile
                    ? TabBarView(
                        controller: _mobileTabController,
                        children: views,
                      )
                    : IndexedStack(
                        index: _selectedDesktopTab,
                        children: views,
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _onAddTap,
            elevation: 4,
            highlightElevation: 8,
            backgroundColor: t.accent,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded, size: 22),
            label: const Text(
              'New Receipt',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
          bottomNavigationBar: (!widget.isEmbedded && isMobile)
              ? MotionTabBar(
                  controller: _motionTabController,
                  initialSelectedTab: "Donations",
                  labels: const ["Donations", "Donors", "Boxes"],
                  icons: const [Icons.receipt_long_rounded, Icons.people_alt_rounded, Icons.inventory_2_rounded],
                  tabSize: 50,
                  tabBarHeight: 58,
                  textStyle: TextStyle(
                    fontSize: 12,
                    color: t.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  tabIconColor: t.textSecondary,
                  tabIconSize: 26.0,
                  tabIconSelectedSize: 24.0,
                  tabSelectedColor: t.accent,
                  tabIconSelectedColor: Colors.white,
                  tabBarColor: t.bgCard,
                  onTabItemSelected: (int value) {
                    setState(() {
                      _selectedDesktopTab = value;
                      _motionTabController?.index = value;
                    });
                  },
                )
              : null,
        );
      },
    );
  }

  Widget _buildBranchesStyleHeader(
    BuildContext context,
    RoleThemeData t,
    bool isMobile,
    String displayBranch,
    String displayUser,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 16 : 24,
        vertical: isMobile ? 12 : 16,
      ),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule, width: 1.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: isMobile ? 36 : 42,
                height: isMobile ? 36 : 42,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2)),
                  ],
                ),
                padding: const EdgeInsets.all(4),
                child: Image.asset('assets/logo/gmwf-1.webp', fit: BoxFit.contain),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            (isMobile && displayBranch.toLowerCase().contains('consolidated'))
                                ? 'All Donations'
                                : "$displayBranch Donations",
                            style: TextStyle(
                              fontSize: isMobile ? 17 : 22,
                              fontWeight: FontWeight.w800,
                              color: t.textPrimary,
                              letterSpacing: -0.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_canSwitchBranch) ...[
                          const SizedBox(width: 6),
                          PopupMenuButton<String>(
                            icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textSecondary),
                            tooltip: 'Switch Branch',
                            onSelected: (bId) {
                              final opt = _branchOptions.firstWhere(
                                (o) => o.id == bId,
                                orElse: () => _branchOptions.first,
                              );
                              _switchBranch(opt.id, opt.name);
                            },
                            itemBuilder: (ctx) => _branchOptions.map((b) => PopupMenuItem(
                              value: b.id,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.store_rounded,
                                    size: 16,
                                    color: b.id == _viewingBranchId ? t.accent : t.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    b.name,
                                    style: TextStyle(
                                      fontWeight: b.id == _viewingBranchId ? FontWeight.bold : FontWeight.normal,
                                      color: b.id == _viewingBranchId ? t.accent : t.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            )).toList(),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Monitor collections, donor records, and donation boxes.",
                      style: TextStyle(fontSize: 12, color: t.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!isMobile) ...[
                const SizedBox(width: 16),
                _buildHeaderTabPills(t),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _isSyncing ? null : _performSync,
                  icon: _isSyncing
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                        )
                      : Icon(Icons.sync_rounded, size: 16, color: t.accent),
                  label: Text(
                    _isSyncing
                        ? 'Syncing...'
                        : (widget.role.canSeeAllBranches ? 'Sync All' : 'Sync My Data'),
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: t.textPrimary),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.textPrimary,
                    side: BorderSide(color: t.bgRule, width: 1.2),
                    backgroundColor: t.bgCardAlt,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _onAddTap,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New Receipt', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
                const SizedBox(width: 10),
                _RolePill(role: widget.role),
              ],
              if (isMobile) ...[
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _isSyncing ? null : _performSync,
                  icon: _isSyncing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                        )
                      : Icon(Icons.sync_rounded, color: t.accent, size: 22),
                  tooltip: widget.role.canSeeAllBranches
                      ? 'Sync All Donations (Local Save)'
                      : 'Sync My Collected Donations (Local Save)',
                ),
                const SizedBox(width: 4),
                _RolePill(role: widget.role),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderTabPills(RoleThemeData t) {
    final tabs = [
      (label: 'Donations Ledger', icon: Icons.receipt_long_rounded),
      (label: 'Donors Directory', icon: Icons.people_alt_rounded),
      (label: 'Donation Boxes', icon: Icons.inventory_2_rounded),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.isDarkCanvas ? const Color(0xFF0D1117) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(tabs.length, (idx) {
          final tab = tabs[idx];
          final isSelected = _selectedDesktopTab == idx;
          return InkWell(
            onTap: () => setState(() {
              _selectedDesktopTab = idx;
              _mobileTabController?.animateTo(idx);
            }),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? t.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: t.accent.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tab.icon,
                    size: 16,
                    color: isSelected ? Colors.white : t.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tab.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      color: isSelected ? Colors.white : t.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }



  Widget _donationsTab() => DashboardTab(
    branchId:          _viewingBranchId,
    username:          widget.username,
    branchName:        _viewingBranchName,
    userId:            widget.userId,
    col:               _col,
    today:             _today,
    role:              widget.role,
    nextReceiptNumber: _nextReceiptNumber,
    selectedCategory:  _selectedCategory,
    onCatChanged:      (c) => setState(() => _selectedCategory = c),
    onAddTap:          _onAddTap,
    onSyncTap:         _performSync,
    isSyncing:         _isSyncing,
  );

  Future<void> _onAddTap() async {
    final result = await showDialog<DonationRecord>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AddDonationWizard(
        branchId: _viewingBranchId.isNotEmpty ? _viewingBranchId : widget.branchId,
        branchName: _viewingBranchName.isNotEmpty ? _viewingBranchName : widget.branchName,
        currentUsername: widget.username,
        userId: widget.userId,
        currentUserRole: widget.role,
      ),
    );

    if (result != null && mounted) {
      AppFeedback.showSuccess(context, 'Donation recorded: ${result.receiptNo}');
    }
  }
}

class _BranchPicker extends StatelessWidget {
  final String branchName;
  final bool canSwitchBranch;
  final VoidCallback onTap;
  final RoleThemeData t;

  const _BranchPicker({required this.branchName, required this.canSwitchBranch, required this.onTap, required this.t});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canSwitchBranch ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: t.bgCardAlt.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.bgRule),
            boxShadow: [
              BoxShadow(
                color: t.accent.withValues(alpha: 0.02),
                blurRadius: 4,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.location_on_rounded, size: 14, color: t.accent),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('BRANCH',
                      style: TextStyle(
                          fontSize: 7.5,
                          fontWeight: FontWeight.w900,
                          color: t.textTertiary,
                          letterSpacing: 1.2)),
                  const SizedBox(height: 1),
                  Text(
                    branchName.isNotEmpty ? branchName : 'Select...',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                        letterSpacing: -0.2),
                  ),
                ],
              ),
              if (canSwitchBranch) ...[
                const SizedBox(width: 6),
                Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: t.textTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String username;
  final Color  roleColor;
  final String? photoUrl;

  const _Avatar({
    required this.username,
    required this.roleColor,
    this.photoUrl,
  });

  String? _resolvePhotoUrl() {
    if (photoUrl != null && photoUrl!.trim().isNotEmpty) {
      return photoUrl!.trim();
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data');
        if (uData is Map) {
          final url = uData['photoUrl'] ?? uData['photoURL'] ?? uData['profileImageUrl'] ?? uData['avatarUrl'] ?? uData['image'];
          if (url != null && url.toString().trim().isNotEmpty) {
            return url.toString().trim();
          }
        }
      }
    } catch (_) {}
    return FirebaseAuth.instance.currentUser?.photoURL;
  }

  @override
  Widget build(BuildContext context) {
    final imgUrl = _resolvePhotoUrl();

    return Container(
      width: 46, height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: roleColor.withValues(alpha: 0.35), width: 2),
        boxShadow: [
          BoxShadow(
            color: roleColor.withValues(alpha: 0.2),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: ClipOval(
          child: imgUrl != null && imgUrl.isNotEmpty
              ? Image.network(
                  imgUrl,
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildLetterAvatar(),
                )
              : _buildLetterAvatar(),
        ),
      ),
    );
  }

  Widget _buildLetterAvatar() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [roleColor, roleColor.withValues(alpha: 0.75)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          username.isNotEmpty ? username[0].toUpperCase() : 'B',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white),
        ),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final UserRole role;
  const _RolePill({required this.role});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: role.roleColor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: role.roleColor.withValues(alpha: 0.15)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5, height: 5,
          decoration: BoxDecoration(color: role.roleColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          role.displayLabel.toUpperCase(),
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: role.roleColor, letterSpacing: 0.8),
        ),
      ],
    ),
  );
}

class _BranchPickerSheet extends StatelessWidget {
  final List<({String id, String name})>      options;
  final String                                currentBranchId;
  final void Function(String id, String name) onSelect;

  const _BranchPickerSheet({
    required this.options,
    required this.currentBranchId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: t.bgRule, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.domain_rounded,
                  size: 20, color: t.accent),
            ),
            const SizedBox(width: 16),
            Text('Switch Branch', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: t.textPrimary, letterSpacing: -0.5)),
          ]),
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: options.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (ctx, i) {
              final opt = options[i];
              final isSel = opt.id == currentBranchId;
              return InkWell(
                onTap: () => onSelect(opt.id, opt.name),
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isSel ? t.accent.withValues(alpha: 0.08) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: isSel ? t.accent.withValues(alpha: 0.3) : Colors.transparent),
                  ),
                  child: Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: isSel ? t.accent.withValues(alpha: 0.12) : t.bgCardAlt,
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Icon(Icons.location_on_rounded, size: 20, color: isSel ? t.accent : t.textTertiary)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(opt.name, style: TextStyle(fontSize: 15, fontWeight: isSel ? FontWeight.w800 : FontWeight.w700, color: isSel ? t.accent : t.textPrimary)),
                      Text(opt.id, style: TextStyle(fontSize: 11, color: t.textTertiary)),
                    ])),
                    if (isSel) Icon(Icons.check_circle_rounded, color: t.accent, size: 22),
                  ]),
                ),
              );
            },
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
      ]),
    );
  }
}