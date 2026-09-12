// lib/widgets/global_module_wrapper.dart
//
// ── REDESIGN NOTES ───────────────────────────────────────────────────────────
//  • Branch selector is a bottom-sheet on mobile, a side-panel slide-in on desktop.
//  • When a branch is selected the top bar shows a subtle animated pill instead
//    of raw text.
//  • The "pick a branch" empty-state is redesigned as a visually inviting card
//    grid rather than a plain centered column.
//  • Global roles (CEO/Chairman) use the dark-navy canvas; others use their
//    role theme's light surface.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/module_registry.dart';
import '../theme/role_theme_provider.dart';
import '../theme/app_theme.dart';
import '../services/sync_service.dart';
import 'package:hive/hive.dart';
import '../services/local_storage_service.dart';
import 'app_back_button.dart';
import '../services/user_module_access_service.dart';
import '../services/auto_update_service.dart';
import '../services/camp_session_service.dart';

const String _kGlobalBranchId = 'all';

class GlobalModuleWrapper extends StatefulWidget {
  final AppModule module;
  final Map<String, dynamic> userData;

  const GlobalModuleWrapper({
    super.key,
    required this.module,
    required this.userData,
  });

  static bool isWrapped(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_WrapperProvider>() !=
        null;
  }

  @override
  State<GlobalModuleWrapper> createState() => _GlobalModuleWrapperState();
}

class _WrapperProvider extends InheritedWidget {
  const _WrapperProvider({required super.child});
  @override
  bool updateShouldNotify(_WrapperProvider old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────

class _GlobalModuleWrapperState extends State<GlobalModuleWrapper>
    with SingleTickerProviderStateMixin {
  String? _selectedBranchId;
  String? _selectedBranchName;
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;
  String? _loadError;

  late AnimationController _pillAnim;
  late Animation<double> _pillFade;

  // ── Branch-scoped roles CANNOT switch branches ─────────────────────────────
  bool get _isBranchScoped {
    final r = _role.toLowerCase();
    return r == 'branch manager' || r == 'supervisor';
  }
  // ───────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final rawBranchId = (widget.userData['branchId'] as String? ?? '').trim();
    final normalizedBranchId = (rawBranchId == 'global' || rawBranchId.isEmpty) ? 'all' : rawBranchId;
    if (widget.module.id == 'finance' && !_isBranchScoped) {
      _selectedBranchId = 'all';
      _selectedBranchName = 'All Branches (Consolidated)';
    } else {
      _selectedBranchId = normalizedBranchId;
    }

    _pillAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 360));
    _pillFade =
        CurvedAnimation(parent: _pillAnim, curve: Curves.easeOutCubic);

    // ── START SYNC SERVICE ──────────────────────────────────────────────────
    final branchId = (widget.userData['branchId'] as String? ?? '').trim();
    if (branchId.isNotEmpty && branchId != _kGlobalBranchId) {
      SyncService().start(branchId);
    } else {
      // Executive roles (chairman, CEO, etc.) have branchId='all' or empty.
      // Start sync with authorized branches so their data still uploads.
      _startSyncForExecutive();
    }
    // ───────────────────────────────────────────────────────────────────────

    _loadBranches();
  }

  Future<void> _loadBranches() async {
    final localBranchesBox = Hive.box(LocalStorageService.branchesBox);

    // ── Branch-scoped roles: never fetch all branches ──────────────────────
    if (_isBranchScoped) {
      final myBranchId = (widget.userData['branchId'] as String? ?? '').trim();
      if (myBranchId.isEmpty || myBranchId == _kGlobalBranchId) {
        if (mounted) setState(() { _loading = false; _loadError = 'No branch assigned to your account.'; });
        return;
      }

      // Check cache first
      final cachedBranch = localBranchesBox.get('branch:$myBranchId');
      if (cachedBranch is Map) {
        final name = (cachedBranch['name'] as String?) ?? myBranchId;
        if (mounted) {
          setState(() {
            _branches = [{'id': myBranchId, 'name': name}];
            _selectedBranchId = myBranchId;
            _selectedBranchName = name;
            _loading = false;
            SyncService().updateAuthorizedBranches([myBranchId]);
          });
          _pillAnim.forward();
        }
        _refreshBranchInfoBackground(myBranchId);
        return;
      }

      // Fallback: Fetch only the name of the user's own branch (single document read).
      try {
        final doc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(myBranchId)
            .get();
        final name = (doc.data()?['name'] as String?) ?? myBranchId;
        await localBranchesBox.put('branch:$myBranchId', {'id': myBranchId, 'name': name});

        if (mounted) {
          setState(() {
            _branches = [{'id': myBranchId, 'name': name}];
            _selectedBranchId = myBranchId;
            _selectedBranchName = name;
            _loading = false;
            SyncService().updateAuthorizedBranches([myBranchId]);
          });
          _pillAnim.forward();
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _branches = [{'id': myBranchId, 'name': myBranchId}];
            _selectedBranchId = myBranchId;
            _selectedBranchName = myBranchId;
            _loading = false;
          });
          _pillAnim.forward();
        }
      }
      return;
    }

    // ── Global / executive roles: check cache first ─────────────────────────
    final uniqueLocalBranches = <String, Map<String, String>>{};
    for (final val in localBranchesBox.values) {
      if (val is Map &&
          val['id'] != null &&
          val['isOffboarded'] != true &&
          val['status'] != 'offboarded') {
        final id = val['id'].toString().trim();
        final name = val['name']?.toString().trim() ?? id;
        if (id.isNotEmpty && id.toLowerCase() != 'all' && id.toLowerCase() != 'global') {
          uniqueLocalBranches[id.toLowerCase()] = {'id': id, 'name': name};
        }
      }
    }

    if (uniqueLocalBranches.isNotEmpty) {
      final localBranches = uniqueLocalBranches.values.toList()
        ..sort((a, b) => a['name']!.compareTo(b['name']!));
      final allBranchesList = [
        {'id': 'all', 'name': 'All Branches (Consolidated)'},
        ...localBranches,
      ];

      if (mounted) {
        setState(() {
          _branches = allBranchesList;
          _loading = false;
          final branchIds = localBranches.map((b) => b['id'].toString()).toList();
          SyncService().updateAuthorizedBranches(branchIds);
          _updateSelectedBranchState();
        });
      }
      _refreshAllBranchesBackground();
      return;
    }

    // Fallback: fetch all branches from Firestore
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      final uniqueRemoteBranches = <String, Map<String, String>>{};
      for (final doc in snap.docs) {
        final data = doc.data();
        final id = doc.id.trim();
        final name = (data['name'] as String?)?.trim() ?? id;
        final idLower = id.toLowerCase();
        final isOffboarded = data['isOffboarded'] == true || data['status'] == 'offboarded';
        
        await localBranchesBox.put('branch:$id', {
          'id': id,
          'name': name,
          'isOffboarded': isOffboarded,
          'status': data['status'] ?? (isOffboarded ? 'offboarded' : 'active'),
        });

        if (!isOffboarded && idLower != 'all' && idLower != 'global') {
          uniqueRemoteBranches[idLower] = {'id': id, 'name': name};
        }
      }

      final branches = uniqueRemoteBranches.values.toList()
        ..sort((a, b) => a['name']!.compareTo(b['name']!));
      final allBranchesList = [
        {'id': 'all', 'name': 'All Branches (Consolidated)'},
        ...branches,
      ];

      if (mounted) {
        setState(() {
          _branches = allBranchesList;
          _loading = false;
          
          final branchIds = branches.map((b) => b['id'].toString()).toList();
          SyncService().updateAuthorizedBranches(branchIds);

          _updateSelectedBranchState();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Failed to load branches. Tap to retry.';
        });
      }
    }
  }

  void _updateSelectedBranchState() {
    if (_selectedBranchId != null) {
      final exists = _branches.any((b) => b['id'] == _selectedBranchId);
      if (!exists) {
        _selectedBranchId = 'all';
        _selectedBranchName = 'All Branches (Consolidated)';
      } else {
        final b = _branches.firstWhere((b) => b['id'] == _selectedBranchId);
        _selectedBranchName = b['name'];
        _pillAnim.forward();
      }
    } else {
      _selectedBranchId = 'all';
      _selectedBranchName = 'All Branches (Consolidated)';
    }
  }

  Future<void> _refreshBranchInfoBackground(String myBranchId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(myBranchId)
          .get();
      if (doc.exists) {
        final data = doc.data() ?? {};
        final name = (data['name'] as String?) ?? myBranchId;
        final isOffboarded = data['isOffboarded'] == true || data['status'] == 'offboarded';
        final localBranchesBox = Hive.box(LocalStorageService.branchesBox);
        await localBranchesBox.put('branch:$myBranchId', {
          'id': myBranchId,
          'name': name,
          'isOffboarded': isOffboarded,
          'status': data['status'] ?? (isOffboarded ? 'offboarded' : 'active'),
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshAllBranchesBackground() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      final localBranchesBox = Hive.box(LocalStorageService.branchesBox);
      for (final d in snap.docs) {
        final data = d.data();
        final id = d.id;
        final name = data['name'] as String? ?? id;
        final isOffboarded = data['isOffboarded'] == true || data['status'] == 'offboarded';
        await localBranchesBox.put('branch:$id', {
          'id': id,
          'name': name,
          'isOffboarded': isOffboarded,
          'status': data['status'] ?? (isOffboarded ? 'offboarded' : 'active'),
        });
      }
    } catch (_) {}
  }

  /// Start sync for executive roles that don't have a single branchId.
  void _startSyncForExecutive() {
    try {
      final localBranchesBox = Hive.box(LocalStorageService.branchesBox);
      final realBranchIds = <String>[];
      for (final val in localBranchesBox.values) {
        if (val is Map) {
          final id = (val['id'] ?? '').toString().trim().toLowerCase();
          final isOff = val['isOffboarded'] == true || val['status'] == 'offboarded';
          if (id.isNotEmpty && id != 'all' && id != 'global' && !isOff) {
            realBranchIds.add(id);
          }
        }
      }
      if (realBranchIds.isNotEmpty) {
        SyncService().start(realBranchIds.first, authorizedBranches: realBranchIds);
        debugPrint('[GlobalModuleWrapper] Executive sync started with ${realBranchIds.length} branches: ${realBranchIds.take(5)}');
      }
    } catch (e) {
      debugPrint('[GlobalModuleWrapper] Executive sync start failed: $e');
    }
  }

  void _selectBranch(String id, String name) {
    // ── Branch-scoped roles cannot switch branches ─────────────────────────
    if (_isBranchScoped) return;
    if (_selectedBranchId == id) return;
    // ───────────────────────────────────────────────────────────────────────
    setState(() {
      _selectedBranchId = id;
      _selectedBranchName = name;
    });
    _pillAnim.forward(from: 0);
    // ── Start sync for the newly selected branch asynchronously after frame ──
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        SyncService().start(id);
      }
    });
    // ───────────────────────────────────────────────────────────────────────
  }

  void clearLoadError() {
    setState(() {
      _loadError = null;
    });
  }

  // Branch-scoped roles always have their branch set; only global roles may
  // need to pick a branch if one isn't already selected.
  bool get _needsBranch =>
      widget.module.isBranchDependent &&
      !_isBranchScoped &&
      _selectedBranchId == null;

  String get _role =>
      (widget.userData['role'] as String? ?? '').toLowerCase();

  bool get _isGlobal => ['ceo', 'chairman', 'global user'].contains(_role);

  @override
  void dispose() {
    _pillAnim.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isMobile = MediaQuery.of(context).size.width < 600;

    final userId = (widget.userData['id'] ?? widget.userData['localId'] ?? widget.userData['username'] ?? '').toString();
    final role = (widget.userData['role'] ?? '').toString();
    final moduleId = widget.module.id;

    final hasAccess = UserModuleAccessService.canUserAccessModule(
      userId: userId,
      role: role,
      moduleId: moduleId,
    );

    if (!hasAccess) {
      return Scaffold(
        backgroundColor: t.bg,
        appBar: AppBar(
          backgroundColor: t.bgCard,
          elevation: 0,
          leading: AppBackButton(color: t.textPrimary),
          title: Text(widget.module.title, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_person_rounded, size: 64, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text('Access Restricted', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.textPrimary)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Text('Access to "${widget.module.title}" has been blocked by Chairman / Administrator.',
                    style: TextStyle(fontSize: 13, color: t.textSecondary), textAlign: TextAlign.center),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(backgroundColor: t.accent),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _isGlobal ? const Color(0xFF0D1117) : t.bg,
      appBar: _buildAppBar(t, isMobile),
      body: _needsBranch
          ? _BranchPickerBody(
              state: this,
              t: t,
              isMobile: isMobile,
            )
          : _ModuleBody(state: this, t: t),
    );
  }

  AppBar _buildAppBar(RoleThemeData t, bool isMobile) {
    final bgColor = _isGlobal ? const Color(0xFF161B22) : t.bgCard;
    final dividerColor =
        _isGlobal ? const Color(0xFF30363D) : t.bgRule;
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = isMobile || screenWidth < 800;

    return AppBar(
      backgroundColor: bgColor,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: AppBackButton(
        color: _isGlobal ? Colors.white : t.textPrimary,
        bgColor: _isGlobal ? const Color(0xFF21262D) : t.accent.withValues(alpha: 0.08),
        onPressed: () => Navigator.pop(context),
      ),
      leadingWidth: 50,
      titleSpacing: 4,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/logo/gmwf-1.webp',
                width: 20,
                height: 20,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.module.title,
                  style: TextStyle(
                    color: _isGlobal ? const Color(0xFFE6EDF3) : t.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: isCompact ? 14 : 16,
                    letterSpacing: -0.3,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (!isCompact && !_needsBranch && _selectedBranchName != null)
                  FadeTransition(
                    opacity: _pillFade,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _selectedBranchName!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.accent,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
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
      actions: [
        // Version pill (hide on very narrow screens < 420px to save space)
        if (screenWidth >= 420)
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('v${AutoUpdateService.currentVersion}',
                style: TextStyle(
                    color: t.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold)),
          ),
        // Branch-scoped roles or finance module see only a read-only branch label, no selector.
        if (widget.module.isBranchDependent && (_isBranchScoped || widget.module.id == 'finance'))
          _LockedBranchLabel(branchName: _selectedBranchName ?? '', t: t),
        if (widget.module.isBranchDependent && !_isBranchScoped && widget.module.id != 'finance') ...[
          isCompact
              ? _MobileBranchButton(state: this, t: t)
              : _DesktopBranchDropdown(state: this, t: t),
          if (screenWidth >= 950 && widget.module.id != 'donations' && (CampSessionService.hasCampsForBranch(_selectedBranchId ?? '') || (_selectedBranchId ?? '').toLowerCase().contains('karachi')))
            _DesktopCampDropdown(state: this, t: t),
        ],
        const SizedBox(width: 8),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, color: dividerColor),
      ),
    );
  }
}

// ── Locked branch label (branch-scoped roles) ─────────────────────────────────
/// A read-only pill displayed in the AppBar for branch managers / supervisors.
/// It shows the branch name but is NOT interactive — there is no way to tap
/// or switch to another branch.

class _LockedBranchLabel extends StatelessWidget {
  final String branchName;
  final RoleThemeData t;

  const _LockedBranchLabel({required this.branchName, required this.t});

  @override
  Widget build(BuildContext context) {
    if (branchName.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      constraints: const BoxConstraints(maxWidth: 150),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.accent.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock_outline_rounded, color: t.accent, size: 12),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            branchName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: t.accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700),
          ),
        ),
      ]),
    );
  }
}

// ── Desktop branch dropdown ───────────────────────────────────────────────────

class _DesktopBranchDropdown extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _DesktopBranchDropdown({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    if (state._loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: t.accent),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      constraints: const BoxConstraints(maxWidth: 200),
      decoration: BoxDecoration(
        color: state._isGlobal
            ? const Color(0xFF21262D)
            : t.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: state._isGlobal
                ? const Color(0xFF30363D)
                : t.accent.withValues(alpha: 0.2)),
      ),
      child: Builder(
        builder: (context) {
          final uniqueMap = <String, String>{};
          for (final b in state._branches) {
            final id = b['id']?.toString().trim() ?? '';
            final name = b['name']?.toString().trim() ?? id;
            if (id.isNotEmpty && !uniqueMap.containsKey(id)) {
              uniqueMap[id] = name;
            }
          }
          final items = uniqueMap.entries
              .map((e) => DropdownMenuItem<String>(
                    value: e.key,
                    child: Text(
                      e.value,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList();

          final safeValue = items.any((it) => it.value == state._selectedBranchId)
              ? state._selectedBranchId
              : (items.isNotEmpty ? items.first.value : null);

          return DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: safeValue,
              hint: Text('Select Branch',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: state._isGlobal
                          ? const Color(0xFF8B949E)
                          : t.textTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              icon: Icon(Icons.keyboard_arrow_down_rounded,
                  color: t.accent, size: 16),
              dropdownColor: state._isGlobal
                  ? const Color(0xFF161B22)
                  : t.bgCard,
              style: TextStyle(
                  color: state._isGlobal
                      ? const Color(0xFFE6EDF3)
                      : t.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
              items: items,
              onChanged: (val) {
                if (val != null) {
                  final bName = uniqueMap[val] ?? val;
                  state._selectBranch(val, bName);
                }
              },
            ),
          );
        },
      ),
    );
  }
}

// ── Desktop camp dropdown (for multi-camp branches e.g. Karachi) ─────────────

class _DesktopCampDropdown extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _DesktopCampDropdown({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: CampSessionService.activeCampNotifier,
      builder: (context, activeCamp, _) {
        final currentCamp = (activeCamp == null || activeCamp.isEmpty) ? 'all' : activeCamp;
        final items = [
          const DropdownMenuItem<String>(
            value: 'all',
            child: Text('All Camps (Collective)'),
          ),
          const DropdownMenuItem<String>(
            value: 'haji_camp',
            child: Text('Haji Camp Dispensary'),
          ),
          const DropdownMenuItem<String>(
            value: 'saddar',
            child: Text('Saddar Dispensary'),
          ),
        ];

        final safeValue = items.any((it) => it.value == currentCamp)
            ? currentCamp
            : (currentCamp.contains('haji') ? 'haji_camp' : (currentCamp.contains('sadd') ? 'saddar' : 'all'));

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: state._isGlobal
                ? const Color(0xFF21262D)
                : t.accent.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: state._isGlobal
                  ? const Color(0xFF30363D)
                  : t.accent.withValues(alpha: 0.2),
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: safeValue,
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.accent, size: 18),
              dropdownColor: state._isGlobal ? const Color(0xFF161B22) : t.bgCard,
              style: TextStyle(
                color: state._isGlobal ? const Color(0xFFE6EDF3) : t.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              items: items,
              onChanged: (val) {
                if (val != null) {
                  CampSessionService.setActiveCamp(val);
                }
              },
            ),
          ),
        );
      },
    );
  }
}

// ── Mobile branch button ──────────────────────────────────────────────────────

class _MobileBranchButton extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _MobileBranchButton({required this.state, required this.t});

  void _showSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _BranchSheet(state: state, t: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSheet(context),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        constraints: const BoxConstraints(maxWidth: 140),
        decoration: BoxDecoration(
          color: t.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.accent.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.storefront_rounded, color: t.accent, size: 13),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              state._selectedBranchName ?? 'Branch',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: t.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, color: t.accent, size: 14),
        ]),
      ),
    );
  }
}

// ── Branch bottom sheet ───────────────────────────────────────────────────────

class _BranchSheet extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _BranchSheet({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    final isGlobal = state._isGlobal;
    final bgColor = isGlobal ? const Color(0xFF161B22) : t.bgCard;

    return Container(
      margin: const EdgeInsets.only(top: 60),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(
            color: isGlobal
                ? const Color(0xFF30363D)
                : t.bgRule),
      ),
      child: Column(
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isGlobal
                    ? const Color(0xFF30363D)
                    : t.bgRule,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(children: [
              Icon(Icons.storefront_rounded, color: t.accent, size: 20),
              const SizedBox(width: 10),
              Text('Select Branch',
                  style: TextStyle(
                      color: isGlobal
                          ? const Color(0xFFE6EDF3)
                          : t.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          Divider(
              color: isGlobal
                  ? const Color(0xFF30363D)
                  : t.bgRule,
              height: 1),
          Expanded(
            child: state._loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: t.accent, strokeWidth: 2))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: state._branches.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final b = state._branches[i];
                      final sel = b['id'] == state._selectedBranchId;
                      return GestureDetector(
                        onTap: () {
                          state._selectBranch(b['id'], b['name']);
                          Navigator.pop(context);
                        },
                        child: AnimatedContainer(
                          duration:
                              const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: sel
                                ? t.accent.withOpacity(
                                    isGlobal ? 0.18 : 0.08)
                                : (isGlobal
                                    ? const Color(0xFF21262D)
                                    : t.bgCardAlt),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: sel
                                    ? t.accent.withValues(alpha: 0.5)
                                    : (isGlobal
                                        ? const Color(0xFF30363D)
                                        : t.bgRule)),
                          ),
                          child: Row(children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: sel
                                    ? t.accent.withValues(alpha: 0.2)
                                    : (isGlobal
                                        ? const Color(0xFF0D1117)
                                        : t.accentMuted),
                                borderRadius:
                                    BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: Text(
                                  b['name'][0].toUpperCase(),
                                  style: TextStyle(
                                      color: sel
                                          ? t.accent
                                          : (isGlobal
                                              ? const Color(
                                                  0xFF8B949E)
                                              : t.accent
                                                  .withValues(alpha: 0.7)),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                b['name'],
                                style: TextStyle(
                                    color: sel
                                        ? (isGlobal
                                            ? Colors.white
                                            : t.textPrimary)
                                        : (isGlobal
                                            ? const Color(0xFFE6EDF3)
                                            : t.textSecondary),
                                    fontWeight: sel
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    fontSize: 14),
                              ),
                            ),
                            if (sel)
                              Icon(Icons.check_circle_rounded,
                                  color: t.accent, size: 18),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Branch picker body (shown when no branch is selected yet)
// ═══════════════════════════════════════════════════════════════════════════

class _BranchPickerBody extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;
  final bool isMobile;

  const _BranchPickerBody(
      {required this.state, required this.t, required this.isMobile});

  bool get _isGlobal => state._isGlobal;

  @override
  Widget build(BuildContext context) {
    if (state._loadError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              state._loadError!,
              style: TextStyle(color: t.textTertiary),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                state._loadBranches();
                state.clearLoadError();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: EdgeInsets.all(isMobile ? 20 : 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header card
            Container(
              padding: EdgeInsets.all(isMobile ? 22 : 32),
              decoration: BoxDecoration(
                gradient: _isGlobal
                    ? const LinearGradient(
                        colors: [
                          Color(0xFF161B22),
                          Color(0xFF0D1117)
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : LinearGradient(
                        colors: [
                          t.accent.withValues(alpha: 0.08),
                          t.accentMuted.withValues(alpha: 0.3),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: _isGlobal
                        ? const Color(0xFF30363D)
                        : t.accent.withValues(alpha: 0.15)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: t.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: t.accent.withValues(alpha: 0.25)),
                    ),
                    child: Icon(Icons.storefront_rounded,
                        color: t.accent, size: 32),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose a Branch',
                          style: TextStyle(
                            color: _isGlobal
                                ? const Color(0xFFE6EDF3)
                                : t.textPrimary,
                            fontSize: isMobile ? 18 : 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Select a branch below to access ${state.widget.module.title}',
                          style: TextStyle(
                            color: _isGlobal
                                ? const Color(0xFF8B949E)
                                : t.textTertiary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // Section label
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 14),
              child: Row(children: [
                Container(
                    width: 3,
                    height: 16,
                    decoration: BoxDecoration(
                        color: t.accent,
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Text('ALL BRANCHES',
                    style: TextStyle(
                        color: _isGlobal
                            ? const Color(0xFF8B949E)
                            : t.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5)),
              ]),
            ),

            // Branch grid / list
            state._loading
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: CircularProgressIndicator(
                          color: t.accent, strokeWidth: 2),
                    ),
                  )
                : isMobile
                    ? _BranchList(state: state, t: t)
                    : _BranchGrid(state: state, t: t),
          ],
        ),
      ),
    );
  }
}

class _BranchList extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _BranchList({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: state._branches.map((b) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _BranchTile(
              b: b, state: state, t: t, isGrid: false),
        );
      }).toList(),
    );
  }
}

class _BranchGrid extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _BranchGrid({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cols = w < 800 ? 2 : 3;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 2.0,
      ),
      itemCount: state._branches.length,
      itemBuilder: (_, i) =>
          _BranchTile(b: state._branches[i], state: state, t: t, isGrid: true),
    );
  }
}

class _BranchTile extends StatefulWidget {
  final Map<String, dynamic> b;
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;
  final bool isGrid;

  const _BranchTile(
      {required this.b,
      required this.state,
      required this.t,
      required this.isGrid});

  @override
  State<_BranchTile> createState() => _BranchTileState();
}

class _BranchTileState extends State<_BranchTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final isGlobal = widget.state._isGlobal;
    final sel = widget.b['id'] == widget.state._selectedBranchId;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () =>
            widget.state._selectBranch(widget.b['id'], widget.b['name']),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.all(widget.isGrid ? 18 : 14),
          decoration: BoxDecoration(
            color: sel || _hovered
                ? t.accent.withOpacity(isGlobal ? 0.12 : 0.06)
                : (isGlobal ? const Color(0xFF161B22) : t.bgCard),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: sel
                    ? t.accent.withValues(alpha: 0.6)
                    : (_hovered
                        ? t.accent.withValues(alpha: 0.3)
                        : (isGlobal
                            ? const Color(0xFF30363D)
                            : t.bgRule)),
                width: sel ? 1.5 : 1),
            boxShadow: sel || _hovered
                ? [
                    BoxShadow(
                        color: t.accent.withValues(alpha: 0.1),
                        blurRadius: 16,
                        offset: const Offset(0, 4))
                  ]
                : [],
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: sel
                      ? t.accent.withValues(alpha: 0.2)
                      : (isGlobal
                          ? const Color(0xFF21262D)
                          : t.accentMuted),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    widget.b['name'][0].toUpperCase(),
                    style: TextStyle(
                      color: sel ? t.accent : t.accent.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.b['name'],
                  style: TextStyle(
                    color: sel
                        ? (isGlobal ? Colors.white : t.textPrimary)
                        : (isGlobal
                            ? const Color(0xFFE6EDF3)
                            : t.textSecondary),
                    fontWeight:
                        sel ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sel)
                Icon(Icons.check_circle_rounded,
                    color: t.accent, size: 17)
              else
                Icon(Icons.arrow_forward_ios_rounded,
                    color: isGlobal
                        ? const Color(0xFF8B949E)
                        : t.textTertiary,
                    size: 13),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Module body (rendered when a branch is selected)
// ═══════════════════════════════════════════════════════════════════════════

class _ModuleBody extends StatelessWidget {
  final _GlobalModuleWrapperState state;
  final RoleThemeData t;

  const _ModuleBody({required this.state, required this.t});

  @override
  Widget build(BuildContext context) {
    final contextualData = Map<String, dynamic>.from(state.widget.userData);
    contextualData['branchId'] = state._selectedBranchId;

    return _WrapperProvider(
      child: KeyedSubtree(
        key: ValueKey(state._selectedBranchId),
        child: state.widget.module.builder(context, contextualData),
      ),
    );
  }
}