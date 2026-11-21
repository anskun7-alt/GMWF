// lib/pages/dispensary/dispensar/inventory.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';
import 'inventory_update.dart';
import 'medicine_ledger.dart';
import 'add_medicine_page.dart';
import 'stock_check_report.dart';
import '../widgets/medicine_icon_badge.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/expiry_rules.dart';
import 'package:gmwf/services/stock/expiry_service.dart';
import 'expiry_page.dart';
import 'package:gmwf/services/stock/stock_authority.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_log.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
import 'package:gmwf/services/stock/stock_sync.dart';
import 'package:gmwf/services/stock/stock_wipe_service.dart';
import 'package:gmwf/widgets/global_module_wrapper.dart';
import 'package:gmwf/widgets/app_back_button.dart';
import 'package:gmwf/widgets/camp_selector_chip.dart';
import 'package:gmwf/utils/string_similarity_helper.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/auto_update_service.dart';
import 'inventory_pdf_helper.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GIcons;
import 'package:gmwf/widgets/blurred_dialog_observer.dart';

class InventoryPage extends StatefulWidget {
  final String branchId;
  final bool isAdmin;
  final bool isDispenser;
  final bool isEmbedded;
  final bool isSupervisor;
  final bool isDoctor;
  final bool isReadOnly;
  final String? initialTabKey;

  const InventoryPage({
    super.key,
    required this.branchId,
    this.isAdmin = false,
    this.isDispenser = false,
    this.isEmbedded = false,
    this.isSupervisor = false,
    this.isDoctor = false,
    this.isReadOnly = false,
    this.initialTabKey,
  });

  static bool isHigherAuthorityRole(Map<dynamic, dynamic>? userData) {
    final raw = userData == null ? '' : (userData['role'] ?? userData['userRole'] ?? '').toString();
    // Same rule as the service-side check, so the screen and the service never disagree.
    return StockAuthority.isHigherAuthorityRole(raw);
  }

  static bool canDeleteInventoryItemFromRole(Map<dynamic, dynamic>? userData) =>
      isHigherAuthorityRole(userData);

  static bool canRegisterMedicineFromRole(Map<dynamic, dynamic>? userData) {
    final raw = userData == null ? '' : (userData['role'] ?? userData['userRole'] ?? '').toString();
    final role = raw.trim().toLowerCase();
    if (role.isEmpty) return false;

    // Explicitly exclude dispensary staff roles
    if (role == 'dispenser' ||
        role.contains('dispens') ||
        role == 'doctor' ||
        role.contains('doctor') ||
        role == 'receptionist' ||
        role.contains('receptionist') ||
        role == 'rec+dis' ||
        role == 'doc+dis' ||
        role == 'doc+rec' ||
        role == 'doc+rec+dis') {
      return false;
    }

    // Allowed: HQ Manager, Branch Manager, Supervisor, and executive roles above them
    return role == 'branch manager' ||
        role == 'branch_manager' ||
        role == 'bm' ||
        role == 'supervisor' ||
        role.contains('supervisor') ||
        role.contains('branch manager') ||
        role.contains('branch_manager') ||
        role == 'hq manager' ||
        role == 'hq_manager' ||
        role == 'hqmanager' ||
        role == 'headquarters manager' ||
        role.contains('headquarters') ||
        role.contains('hq') ||
        role == 'chairman' ||
        role == 'ceo' ||
        role == 'president' ||
        role == 'director' ||
        role.contains('admin') ||
        role == 'manager';
  }

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // ── Palette ───────────────────────────────────────────────────────────────
  Color get _teal => context.comfort.brand;
  Color get _tealDark => context.comfort.brandStrong;
  static const _white = SoftPalette.gray50;
  static const _green100 = SoftPalette.green200;
  static const _green600 = SoftPalette.green550;
  static const _red = SoftPalette.red500; // More vibrant, premium red
  static const _amber = SoftPalette.orange350;
  static const _indigo = SoftPalette.indigo700;
  static const _brown = SoftPalette.red700m;
  static const _textDark = SoftPalette.slate800;
  static const _textMid = SoftPalette.slate600;
  static const _textLight = SoftPalette.slate500;
  Color get _border => context.comfort.border;
  static const _shadow = SoftPalette.teal600A9;

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        return Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true;
      }
    } catch (_) {}
    return false;
  }

  bool get _canDeleteInventoryItem {
    if (widget.isAdmin) return true;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          return InventoryPage.canDeleteInventoryItemFromRole(Map<dynamic, dynamic>.from(uData));
        }
      }
    } catch (_) {}
    return false;
  }

  /// Executive / dashboard higher-authority users (Chairman, HQ Manager, Admin, CEO, etc.).
  bool get _isHigherAuthority =>
      !widget.isDoctor && !widget.isDispenser && !widget.isReadOnly && (widget.isAdmin || _canDeleteInventoryItem);

  bool get _isDoctorUser {
    if (widget.isDoctor) return true;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          final r = (uData['role'] ?? uData['userRole'] ?? '').toString().trim().toLowerCase();
          return r == 'doctor' || r.contains('doctor');
        }
      }
    } catch (_) {}
    return false;
  }

  bool get _isSupervisorUser {
    if (widget.isSupervisor) return true;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          final r = (uData['role'] ?? uData['userRole'] ?? '').toString().trim().toLowerCase();
          return r == 'supervisor' || r.contains('supervisor');
        }
      }
    } catch (_) {}
    return false;
  }

  bool get _isManager => !widget.isAdmin && !widget.isDispenser;
  bool get _isSupervisorOrReadOnly => _isSupervisorUser || widget.isReadOnly || _isDoctorUser;

  /// Direct edit is strictly reserved for Admins, Global Admins, Chairmen, HQ Managers & Supervisors.
  /// Doctors are restricted to viewing stock and requesting restock.
  /// Dispensers are explicitly barred from direct edits and must use "Update Stock" for approval.
  bool get _isDirectEditAllowed {
    if (widget.isReadOnly) return false;
    if (widget.isDispenser) return false;
    if (_isDoctorUser) return false;
    return widget.isAdmin || widget.isSupervisor;
  }

  bool get _canRegisterMedicine {
    if (widget.isReadOnly || widget.isDispenser || _isDoctorUser) return false;
    if (widget.isAdmin) return true;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          return InventoryPage.canRegisterMedicineFromRole(Map<dynamic, dynamic>.from(uData));
        }
      }
    } catch (_) {}
    return false;
  }

  static const _editRequestTypes = {'edit_medicine', 'delete_medicine'};

  static Color _typeColor(String t) => switch (t) {
        'Tablet' => SoftPalette.blue550,
        'Capsule' => SoftPalette.purple600,
        'Syrup' => SoftPalette.orange350,
        'Injection' => SoftPalette.red550,
        'Infusion' => SoftPalette.teal600,
        'Drip' => SoftPalette.teal600,
        'Drip Set' => SoftPalette.cyan500,
        'Syringe' => SoftPalette.pink550,
        'Cannula' => SoftPalette.red500,
        'Needle' => SoftPalette.purple550,
        'Nebulization' => SoftPalette.indigo700,
        'Dressing Item' => SoftPalette.slate600,
        'Consumables' => SoftPalette.teal550,
        _ => SoftPalette.slate700,
      };

  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) {
        setState(() {
          _displayLimit = 50;
          _processData();
        });
      }
    });
  }

  String _filterType = 'All';
  String _filterBatch = 'All Batches';
  bool _mergeByFormula = false;
  bool _filterMissingBarcodeOnly = false;
  String _sortField = 'name';
  bool _isAscending = true;
  int _page = 0;
  final int _perPage = 25;
  List<String> _batchKeys = ['All Batches'];
  String? _selectedCampFilter;
  final ScrollController _scrollController = ScrollController();
  int _displayLimit = 50;
  bool _isExportingPdf = false;
  bool _isRefreshingInventory = false;
  bool _isDeletingBatches = false;
  DateTime? _lastManualRefreshAt;
  bool _isSelectMode = false;
  final Set<String> _selectedBatchKeys = {};

  bool get _allFilteredSelected =>
      _filteredBatches.isNotEmpty &&
      _filteredBatches.every((b) => _selectedBatchKeys.contains(b['batchKey']?.toString()));

  void _toggleSelectAll() {
    setState(() {
      if (_allFilteredSelected) {
        for (final b in _filteredBatches) {
          final key = (b['batchKey'] ?? '').toString();
          _selectedBatchKeys.remove(key);
        }
      } else {
        for (final b in _filteredBatches) {
          final key = (b['batchKey'] ?? '').toString();
          if (key.isNotEmpty) _selectedBatchKeys.add(key);
        }
      }
    });
  }

  void _toggleSelectItem(String batchKey) {
    if (batchKey.isEmpty) return;
    setState(() {
      if (_selectedBatchKeys.contains(batchKey)) {
        _selectedBatchKeys.remove(batchKey);
      } else {
        _selectedBatchKeys.add(batchKey);
      }
    });
  }

  // Cached state for performance/lazy loading
  List<Map<String, dynamic>> _rawItems = [];
  List<Map<String, dynamic>> _groupedBatches = [];
  List<Map<String, dynamic>> _filteredBatches = [];
  List<Map<String, dynamic>> _displayItems = [];

  // ── Sync & Stream Management ─────────────────────────────────────────────
  StreamSubscription? _fireInvSub;
  StreamSubscription? _logCombinedSub;
  final _logState = BehaviorSubject<List<Map<String, dynamic>>>();

  final List<String> _types = [
    'All', 'Tablet', 'Capsule', 'Syrup', 'Injection', 'Infusion',
    'Drip Set', 'Syringe', 'Cannula', 'Needle', 'Nebulization', 'Dressing Item', 'Consumables', 'Others',
  ];

  @override
  void initState() {
    super.initState();
    // One list drives the sidebar, the phone tab strip and the tab views, so they can never
    // disagree (the Supervisor's sidebar listed tabs the view did not build).
    final keys = _tabKeys;
    final tabCount = keys.length;
    var initialIndex = 0;
    if (widget.initialTabKey == 'add_medicine' && keys.contains('add')) initialIndex = keys.indexOf('add');
    if (widget.initialTabKey == 'expiry' && keys.contains('expiry')) initialIndex = keys.indexOf('expiry');
    _tabCtrl = TabController(length: tabCount, initialIndex: initialIndex, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted && !_tabCtrl.indexIsChanging) {
        debugPrint('[InventoryPage] tab -> ${_tabCtrl.index}'
            ' (previous ${_tabCtrl.previousIndex}) from: '
            '${StackTrace.current.toString().split("\n").skip(1).take(4).map((l) => l.trim()).join(" <- ")}');
        setState(() {});
      }
    });
    _scrollController.addListener(_onScroll);

    final isHqOrAdmin = _isHigherAuthority;
    final initBranch = _effectiveBranchId;
    final active = _isAllBranchesMode ? null : CampSessionService.getActiveCamp(initBranch);
    final availableOptions = CampSessionService.getAvailableCampOptions();
    final branchCamps = _isAllBranchesMode ? const <Map<String, dynamic>>[] : CampSessionService.getCampsForBranch(initBranch);
    final hasCamps = !_isAllBranchesMode &&
        (CampSessionService.hasCampsForBranch(initBranch) || initBranch.contains('karachi')) &&
        branchCamps.isNotEmpty;
    // Doctor and dispensar desks always look at their own pool (this PC's active camp), the
    // same pool the doctor's panel and the dispense use — never "all camps" added together,
    // even when the logged-in user is an admin running a desk.
    _selectedCampFilter = !hasCamps
        ? 'all'
        : (isHqOrAdmin && !_isDeskView
            ? 'all'
            : ((active != null && active.isNotEmpty)
                ? active
                : (availableOptions.isNotEmpty ? availableOptions.first['id'] : 'all')));

    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    RealtimeManager.isLanHealthyNotifier.addListener(_onLanHealthChanged);

    _initSync();
    if (!_isAllBranchesMode && initBranch.contains('karachi')) {
      LocalStorageService.healKarachiSplitInventory();
    }

    // Cache database loading
    // Kept so dispose() removes the listener from the same listenable (a fresh one removed
    // nothing, leaking a stock-box watcher each time this screen was opened).
    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      _stockListenable = Hive.box(LocalStorageService.stockBox).listenable()
        ..addListener(_debouncedLoadDataFromHive);
      _loadDataFromHive();
      // If an executive switched to a branch whose stock isn't cached locally yet, pull from Firestore once.
      if (isHqOrAdmin && !_isAllBranchesMode && _rawItems.isEmpty && Firebase.apps.isNotEmpty) {
        unawaited(_refreshInventory(showToast: false));
      }
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          _stockListenable = box.listenable()..addListener(_debouncedLoadDataFromHive);
          _loadDataFromHive();
        }
      });
    }
    // The stock book also needs its movements box; reload once both are open.
    if (!StockLedger.isOpen) {
      StockLedger.ensureOpen().then((_) {
        if (mounted) _loadDataFromHive();
      }).catchError((Object e) {
        debugPrint('[Inventory] Stock book open failed: $e');
      });
    }
  }

  /// True when the top-bar branch selector is set to "All Branches" (no single branch selected).
  bool get _isAllBranchesMode {
    final b = widget.branchId.trim().toLowerCase();
    return b.isEmpty || b == 'all' || b == 'global' || b == 'unknown';
  }

  List<String> _allKnownBranchIds() {
    final ids = <String>{};
    for (final b in LocalStorageService.getLocalBranchesList()) {
      final norm = StockPool.normalizeBranch(b['id']?.toString());
      if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
        ids.add(norm);
      }
    }
    if (StockLedger.isOpen) {
      for (final it in StockLedger.items()) {
        final norm = StockPool.normalizeBranch(it['branchId']?.toString());
        if (norm.isNotEmpty && norm != 'all' && norm != 'global' && norm != 'unknown') {
          ids.add(norm);
        }
      }
    }
    return ids.toList()..sort();
  }

  void _onLanHealthChanged() {
    if (!mounted) return;
    debugPrint('[Inventory] LAN Health changed: ${RealtimeManager.isLanHealthyNotifier.value}. Refreshing inventory sync state...');
    _fireInvSub?.cancel();
    _logCombinedSub?.cancel();
    _initSync();
  }

  /// A doctor or dispensar desk: shows exactly one pool, the desk's own.
  bool get _isDeskView => widget.isDoctor || widget.isDispenser;

  void _onActiveCampChanged() {
    if (!mounted || (_isHigherAuthority && !_isDeskView) || _isAllBranchesMode) return;
    final active = CampSessionService.getActiveCamp(_effectiveBranchId);
    if (active != null && active.isNotEmpty && active != _selectedCampFilter) {
      setState(() {
        _selectedCampFilter = active;
      });
      _loadDataFromHive();
    }
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _fireInvSub?.cancel();
      _logCombinedSub?.cancel();
      _selectedCampFilter = 'all';
      _selectedBatchKeys.clear();
      _isSelectMode = false;
      _rawItems.clear();
      _groupedBatches.clear();
      _filteredBatches.clear();
      _displayItems.clear();
      _initSync();
      _loadDataFromHive();
      if (_isHigherAuthority && !_isAllBranchesMode && _rawItems.isEmpty && Firebase.apps.isNotEmpty) {
        unawaited(_refreshInventory(showToast: false));
      }
    }
  }

  /// Strictly follows the branch passed by the top-bar branch selector (never silently
  /// substitutes another branch's data when a specific branch is selected).
  String get _effectiveBranchId {
    final b = widget.branchId.trim().toLowerCase();
    if (b.isEmpty || b == 'all' || b == 'global' || b == 'unknown') return 'all';
    return CampSessionService.isKarachiFamily(b) ? 'karachi' : b;
  }

  // ── Stock book pools ──────────────────────────────────────────────────────
  /// The pools this screen shows: ONLY the selected branch's pool(s) when a branch is
  /// chosen in the top bar, or all local branch pools when "All Branches" is chosen.
  List<StockPool> _viewPools() {
    if (_isAllBranchesMode) {
      final byKey = <String, StockPool>{};
      for (final b in _allKnownBranchIds()) {
        for (final p in StockPool.allFor(b)) {
          byKey[p.key] = p;
        }
      }
      return byKey.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    }
    final branch = _effectiveBranchId;
    final sel = (_selectedCampFilter ?? '').trim();
    if (widget.isDoctor && (sel.isEmpty || sel.toLowerCase() == 'all')) {
      // The doctor has no camp bar: always the desk's own pool (StockPool.current), the same
      // one the doctor's panel prescribes from. (A dispensar picking "All camps" on its camp
      // bar is a deliberate choice and is left alone.)
      final own = StockPool.current(branch);
      return own == null ? StockPool.allFor(branch).take(1).toList() : [own];
    }
    if (sel.isEmpty || sel.toLowerCase() == 'all') return StockPool.allFor(branch);
    final p = StockPool.of(branch, sel, fallbackCamp: CampSessionService.getActiveCamp(branch));
    return p == null ? const [] : [p];
  }

  /// Pool for writing when the screen shows exactly one pool (else null).
  StockPool? get _singleViewPool {
    final pools = _viewPools();
    return pools.length == 1 ? pools.first : null;
  }

  /// (pool, medicineId) of every ledger batch behind a displayed row.
  List<(StockPool, String)> _batchRefs(Map batchData) {
    final ids = List<String>.from(batchData['_docIds'] as List? ?? const []);
    final pools = List<String>.from(batchData['_docPools'] as List? ?? const []);
    final fallback = _singleViewPool;
    final out = <(StockPool, String)>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i].trim();
      if (id.isEmpty || id == 'unknown') continue;
      final pool = (i < pools.length ? StockPool.fromKey(pools[i]) : null) ?? fallback;
      if (pool != null) out.add((pool, id));
    }
    return out;
  }

  void _initSync() {
    // Log tab: the real activity log (Hive `local_audit_logs`). Every PC of the branch has the
    // same entries (StockLog sends each one over the LAN). It used to read only the upload
    // queue for two retired item types, so it was always empty.
    unawaited(() async {
      try {
        const name = LocalStorageService.auditLogsBox;
        final box = Hive.isBoxOpen(name) ? Hive.box(name) : await Hive.openBox(name);
        if (!mounted) return;
        _logCombinedSub = box
            .watch()
            .debounceTime(const Duration(milliseconds: 400))
            .map((_) => _loadActivityLogs())
            .startWith(_loadActivityLogs())
            .listen((list) {
          if (!_logState.isClosed) _logState.add(list);
        });
      } catch (e) {
        debugPrint('[Inventory] Activity log load error: $e');
        if (!_logState.isClosed) _logState.add(const []);
      }
    }());
  }

  /// Entries of the branch (and camp) picked in the top bar, newest first, max 500.
  List<Map<String, dynamic>> _loadActivityLogs() {
    final all = LocalStorageService.getLocalInventoryLogs();
    final pools = _isAllBranchesMode ? const <String>{} : {for (final p in _viewPools()) p.key};
    final branch = _isAllBranchesMode ? '' : StockPool.normalizeBranch(_effectiveBranchId);
    final out = <Map<String, dynamic>>[];
    for (final e in all) {
      if (!_isAllBranchesMode) {
        final pool = (e['pool'] ?? '').toString().toLowerCase();
        if (pool.isNotEmpty) {
          if (!pools.contains(pool)) continue;
        } else {
          final b = StockPool.normalizeBranch((e['branchId'] ?? '').toString());
          if (b.isNotEmpty && branch.isNotEmpty && b != branch) continue;
        }
      }
      out.add(e);
      if (out.length >= 500) break;
    }
    return out;
  }

  // ─── Manual Cloud / LAN Inventory Refresh ──────────────────────────────
  DateTime? _lastCloudPullTime;

  /// Fetches the latest inventory snapshot from the LAN server (when connected to LAN)
  /// or directly from Firestore cloud (when standalone / web), then reloads the view.
  Future<void> _refreshInventory({bool showToast = true}) async {
    if (_isRefreshingInventory) return;
    final viaLan = StockSync.isLanClient;
    final cooldown = viaLan ? const Duration(seconds: 3) : const Duration(seconds: 15);
    if (_lastManualRefreshAt != null &&
        DateTime.now().difference(_lastManualRefreshAt!) < cooldown) {
      if (showToast && mounted) {
        final left = cooldown.inSeconds - DateTime.now().difference(_lastManualRefreshAt!).inSeconds;
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text('Please wait ${left.clamp(1, cooldown.inSeconds)}s before refreshing again.'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    _lastManualRefreshAt = DateTime.now();
    if (mounted) setState(() => _isRefreshingInventory = true);

    StreamSubscription<BoxEvent>? watchSub;
    try {
      final effBranch = _effectiveBranchId;
      if (viaLan) {
        final gotUpdate = Completer<void>();
        if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
          watchSub = Hive.box(LocalStorageService.stockBox).watch().listen((_) {
            if (!gotUpdate.isCompleted) gotUpdate.complete();
          });
        }
        StockSync.requestSnapshot(effBranch);
        // Wait briefly for the LAN server's snapshot/wipe frames to land in Hive.
        await gotUpdate.future.timeout(const Duration(milliseconds: 1500), onTimeout: () {});
        if (gotUpdate.isCompleted) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      } else if (_isAllBranchesMode) {
        for (final b in _allKnownBranchIds()) {
          await LocalStorageService.downloadInventory(b, forceFull: true);
        }
      } else {
        await LocalStorageService.downloadInventory(
          effBranch,
          forceFull: true,
          campId: _selectedCampFilter,
        );
      }

      if (mounted) {
        _loadDataFromHive();
        if (showToast) {
          AppToast.showSnackBar(
            context,
            SnackBar(
              content: Text(
                viaLan
                    ? 'Inventory refreshed from server (${_groupedBatches.length} items).'
                    : 'Inventory refreshed from cloud (${_groupedBatches.length} items).',
              ),
              backgroundColor: SoftPalette.teal600,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Inventory] Manual refresh failed: $e');
      if (showToast && mounted) {
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text('Could not refresh inventory: $e'),
            backgroundColor: _red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      await watchSub?.cancel();
      if (mounted) setState(() => _isRefreshingInventory = false);
    }
  }

  Future<void> manualCloudPull({bool showToast = true}) async {
    if (_lastCloudPullTime != null &&
        DateTime.now().difference(_lastCloudPullTime!) < const Duration(seconds: 30)) {
      if (showToast && mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('Please wait 30 seconds between cloud syncs.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _lastCloudPullTime = DateTime.now();

    final effBranch = _effectiveBranchId;
    final activeCamp = CampSessionService.getActiveCamp(effBranch);

    if (showToast && mounted) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('Refreshing inventory from cloud...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      if (CampSessionService.isKarachiFamily(effBranch)) {
        await LocalStorageService.restoreAndSyncKarachiInventory('karachi');
      } else {
        await LocalStorageService.downloadInventory(effBranch, forceFull: true, campId: activeCamp);
      }
      if (mounted) {
        _loadDataFromHive();
        if (showToast) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('Inventory cloud sync complete.'),
              backgroundColor: SoftPalette.teal600,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Inventory] Manual cloud pull failed: $e');
    }
  }


  @override
  void dispose() {
    _searchDebounce?.cancel();
    _debounceLoadTimer?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    RealtimeManager.isLanHealthyNotifier.removeListener(_onLanHealthChanged);
    try {
      _stockListenable?.removeListener(_debouncedLoadDataFromHive);
      _stockListenable = null;
    } catch (_) {}
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _fireInvSub?.cancel();
    _logCombinedSub?.cancel();
    _logState.close();
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_displayLimit < _filteredBatches.length) {
        if (mounted) {
          setState(() {
            _displayLimit += 25;
            _processData();
          });
        }
      }
    }
  }

  Timer? _debounceLoadTimer;
  ValueListenable<Box>? _stockListenable;

  void _debouncedLoadDataFromHive() {
    _debounceLoadTimer?.cancel();
    _debounceLoadTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _loadDataFromHive();
    });
  }

  void _loadDataFromHive() {
    // Stock book: each ledger record is one real batch of one pool. No de-duplication,
    // branch guessing or camp rewriting is needed any more.
    final allMapDocs = <Map<String, dynamic>>[];
    final officialBarcodes = MasterProformaService.getOfficialBarcodes();

    for (final pool in _viewPools()) {
      // Higher Authority sees ALL non-deleted records (including blank/unnamed junk rows so
      // they can inspect and delete them); regular desks use StockReader.batches(pool).
      final records = _isHigherAuthority && !_isDeskView
          ? StockLedger.items(pool: pool.key)
          : StockReader.batches(pool);
      for (final rec in records) {
        final m = Map<String, dynamic>.from(rec);
        m['id'] = (m['medicineId'] ?? m['id']).toString();
        m['pool'] = pool.key;

        // Auto-normalize medicine name, formula, code & 3-digit Proforma barcode
        final isCustom = m['isCustomized'] == true || m['userEdited'] == true;
        if (!isCustom) {
          MasterProformaService.alignStockItemWithProforma(m);
          final curBar = (m['barcode'] ?? '').toString().trim();
          final normBar = MasterProformaService.normalizeProformaBarcode(curBar);
          if (normBar != null) {
            m['barcode'] = normBar;
            m['rollNo'] = normBar;
          } else {
            m['barcode'] = '';
          }
          final rawName = (m['name'] ?? m['formula'] ?? '').toString();
          final cleanName = MasterProformaService.cleanBrandToFormula(rawName);
          if (cleanName.isNotEmpty) {
            m['name'] = cleanName;
            m['formula'] = cleanName;
          }
        }
        final resolvedBar = MasterProformaService.normalizeProformaBarcode(
            (m['barcode'] ?? m['rollNo'] ?? '').toString());
        m['_hasOfficialBarcode'] =
            resolvedBar != null && (officialBarcodes.isEmpty || officialBarcodes.contains(resolvedBar));

        allMapDocs.add(m);
      }
    }

    if (mounted) {
      setState(() {
        _rawItems = allMapDocs;
        _processData();
      });
    }
  }

  bool _isBatchMissingOfficialBarcode(Map<String, dynamic> b, Set<String> officialBarcodes) {
    final norm = MasterProformaService.normalizeProformaBarcode(
        (b['barcode'] ?? b['rollNo'] ?? '').toString());
    if (norm == null) return true;
    if (officialBarcodes.isNotEmpty && !officialBarcodes.contains(norm)) return true;
    return false;
  }

  void _processData() {
    if (_rawItems.isEmpty) {
      _groupedBatches = [];
      _filteredBatches = [];
      _displayItems = [];
      return;
    }
    final batches = _groupByBatch(_rawItems);
    _groupedBatches = batches;
    final officialBarcodes = _filterMissingBarcodeOnly ? MasterProformaService.getOfficialBarcodes() : const <String>{};

    var preFiltered = batches.where((b) {
      final qty = (b['quantity'] as num?)?.toInt() ?? 0;
      if (qty < 0) return false;
      if (_filterMissingBarcodeOnly && !_isBatchMissingOfficialBarcode(b, officialBarcodes)) {
        return false;
      }

      final name = b['name'].toString().toLowerCase();
      final formula = (b['formula'] ?? '').toString().toLowerCase();
      final barcode = (b['barcode'] ?? b['code'] ?? '').toString().toLowerCase();
      final packBarcode = (b['packBarcode'] ?? '').toString().toLowerCase();
      final type = b['type'];
      final query = _searchCtrl.text.trim().toLowerCase();
      return (name.contains(query) || formula.contains(query) || barcode.contains(query) || packBarcode.contains(query)) &&
          (_filterType == 'All' || type == _filterType);
    }).toList();

    if (preFiltered.isEmpty && _searchCtrl.text.trim().length >= 3) {
      final query = _searchCtrl.text.trim().toLowerCase();
      preFiltered = batches.where((b) {
        final qty = (b['quantity'] as num?)?.toInt() ?? 0;
        if (qty < 0) return false;
        if (_filterMissingBarcodeOnly && !_isBatchMissingOfficialBarcode(b, officialBarcodes)) {
          return false;
        }
        final name = b['name'].toString().toLowerCase();
        final formula = (b['formula'] ?? '').toString().toLowerCase();
        final type = b['type'];
        final matchesType = _filterType == 'All' || type == _filterType;
        if (!matchesType) return false;
        final simName = StringSimilarityHelper.calculateSimilarity(query, name);
        final simForm = StringSimilarityHelper.calculateSimilarity(query, formula);
        return simName >= 0.55 || simForm >= 0.55;
      }).toList();
    }

    _updateBatchKeys(preFiltered);

    var filtered = _filterBatch == 'All Batches'
        ? preFiltered
        : preFiltered.where((b) => b['expiryDate'] == _filterBatch).toList();

    filtered.sort((a, b) {
      int cmp = switch (_sortField) {
        'name' => a['name']
            .toString()
            .toLowerCase()
            .compareTo(b['name'].toString().toLowerCase()),
        'formula' => (a['formula'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['formula'] ?? '').toString().toLowerCase()),
        'dose' => (a['dose'] ?? '')
            .toString()
            .compareTo((b['dose'] ?? '').toString()),
        'quantity' => (a['quantity'] as int).compareTo(b['quantity'] as int),
        'price' => (a['price'] as double).compareTo(b['price'] as double),
        'expiry' => _parseExpiry(a['expiryDate'])
            .compareTo(_parseExpiry(b['expiryDate'])),
        _ => 0,
      };
      return _isAscending ? cmp : -cmp;
    });

    _filteredBatches = filtered;
    
    final end = _displayLimit.clamp(0, filtered.length);
    _displayItems = filtered.sublist(0, end);
  }

  void _resetFilters() {
    setState(() {
      _searchCtrl.clear();
      _filterType = 'All';
      _filterBatch = 'All Batches';
      _mergeByFormula = false;
      _filterMissingBarcodeOnly = false;
      _sortField = 'name';
      _isAscending = true;
      _displayLimit = 50;
      _page = 0;
      _processData();
    });
  }

  Future<void> _exportPdf() async {
    if (_isExportingPdf) return;
    setState(() => _isExportingPdf = true);
    try {
      await InventoryPdfHelper.exportInventoryChecklistPdf(
        items: _groupedBatches,
        branchName: _getBranchName(),
        context: context,
      );
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('PDF export failed: $e'),
            backgroundColor: _red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExportingPdf = false);
    }
  }

  void _applyLowStockSort() {
    setState(() {
      _sortField = 'quantity';
      _isAscending = true;
      _displayLimit = 50;
      _page = 0;
      _processData();
    });
  }

  void _applyExpirySort() {
    setState(() {
      _sortField = 'expiry';
      _isAscending = true;
      _displayLimit = 50;
      _page = 0;
      _processData();
    });
  }

  int _asInt(dynamic v) {
    int raw = v is int
        ? v
        : v is double
            ? v.toInt()
            : v is String
                ? (int.tryParse(v) ?? 0)
                : 0;
    return raw < 0 ? 0 : raw;
  }

  double _parsePrice(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _fmtPrice(double price) =>
      price == price.floorToDouble()
          ? price.toInt().toString()
          : price.toStringAsFixed(2);

  Widget _typeIconWidget(String t, {double size = 14, Color? color}) {
    final c = color ?? _teal;
    return MedicineTypeIcon(
      type: t,
      size: size + 2,
      color: c,
    );
  }

  void _sort(String field) {
    if (field == 'type') return;
    setState(() {
      if (_sortField == field) {
        _isAscending = !_isAscending;
      } else {
        _sortField = field;
        _isAscending = true;
      }
      _page = 0;
      _processData();
    });
  }

  String _formatDate(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    if (raw.length == 7 && raw[2] == '-') return raw;
    final p = raw.split('-');
    if (p.length != 3) return raw;
    return '${p[0].padLeft(2, '0')}-${p[1].padLeft(2, '0')}-${p[2]}';
  }

  bool _isExpiringSoon(String? exp) {
    if (exp == null || exp.isEmpty) return false;
    try {
      final date = _parseExpiry(exp);
      if (date.year >= 3000) return false;
      final lastDayOfMonth = DateTime(date.year, date.month + 1, 0);
      final diff = lastDayOfMonth.difference(DateTime.now()).inDays;
      return diff <= 30 && diff >= 0;
    } catch (_) {
      return false;
    }
  }

  DateTime _parseExpiry(String? s) {
    if (s == null || s.isEmpty) return DateTime(3000);
    try {
      final clean = s.replaceAll('/', '-').replaceAll('.', '-').trim();
      final p = clean.split('-');
      if (p.length == 2) {
        if (p[0].length == 4) {
          return DateTime(int.parse(p[0]), int.parse(p[1]), 15);
        } else {
          return DateTime(int.parse(p[1]), int.parse(p[0]), 15);
        }
      }
      if (p.length == 3) {
        if (p[0].length == 4) {
          return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
        } else {
          return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
        }
      }
    } catch (_) {}
    return DateTime(3000);
  }

  List<Map<String, dynamic>> _groupByBatch(
      Iterable<Map<String, dynamic>> docs) {
    final Map<String, Map<String, dynamic>> map = {};
    for (final data in docs) {
      final name = (data['name'] ?? '').toString().trim();
      final type = (data['type'] ?? '').toString().trim();
      final dose = (data['dose'] ?? '').toString().trim();
      final expiry = data['expiryDate']?.toString().trim() ?? '';
      final qty = _asInt(data['quantity']);
      final price = _parsePrice(data['price']);
      final formula = (data['formula'] ?? '').toString().trim();
      final barcode = (data['barcode'] ?? data['rollNo'] ?? '').toString().trim();
      final itemCode = (data['code'] ?? data['itemCode'] ?? '').toString().trim();
      final packBarcode = (data['packBarcode'] ?? '').toString().trim();

      String monthYear = '';
      if (expiry.length == 10 && expiry[2] == '-' && expiry[5] == '-') {
        monthYear = expiry.substring(3);
      } else {
        monthYear = expiry;
      }

      String doseDisplay = dose;
      if (type == 'Nebulization' && dose.isEmpty) doseDisplay = 'per session';

      final docId = (data['id'] ?? data['medicineId'] ?? 'unknown').toString();
      final docPool = (data['pool'] ?? '').toString();

      String key;
      String displayName = name;
      String displayFormula = formula;

      final itemCamp = (data['campId'] ?? data['dispensaryId'] ?? '').toString().toLowerCase().trim();
      final campSuffix = (_selectedCampFilter == null || _selectedCampFilter == 'all') && itemCamp.isNotEmpty ? '|$itemCamp' : '';
      final scopeSuffix = _isAllBranchesMode && docPool.isNotEmpty ? '|$docPool' : campSuffix;

      if (_mergeByFormula) {
        // Canonical formula resolution
        final rawForm = formula.isNotEmpty ? formula : name;
        final cleanForm = MasterProformaService.cleanBrandToFormula(rawForm).trim();
        final effFormula = cleanForm.isNotEmpty ? cleanForm : rawForm.trim();

        // Key groups strictly by normalized generic formula so same formula quantities merge together
        key = '${effFormula.toLowerCase().trim()}$scopeSuffix';
        displayFormula = effFormula;
        displayName = effFormula;
      } else {
        // Normal mode: separated by batch (monthYear) and item name
        key = '$name|$type|$dose|$monthYear$scopeSuffix';
      }

      if (map.containsKey(key)) {
        final existing = map[key]!;
        final existingDocIds = existing['_docIds'] as List<String>;
        final existingDocPools = existing['_docPools'] as List<String>;
        var seen = false;
        for (var i = 0; i < existingDocIds.length; i++) {
          if (existingDocIds[i] == docId && existingDocPools[i] == docPool) {
            seen = true;
            break;
          }
        }
        if (!seen) {
          existingDocIds.add(docId);
          existingDocPools.add(docPool);
          existing['quantity'] = (existing['quantity'] as int) + qty;
          existing['_mergedCount'] = ((existing['_mergedCount'] as int?) ?? 1) + 1;
        }
        // Keep the first non-empty barcode, itemCode, and packBarcode found for this batch
        if ((existing['barcode'] as String? ?? '').isEmpty && barcode.isNotEmpty) {
          existing['barcode'] = barcode;
        }
        if ((existing['code'] as String? ?? '').isEmpty && itemCode.isNotEmpty) {
          existing['code'] = itemCode;
          existing['itemCode'] = itemCode;
        }
        if ((existing['packBarcode'] as String? ?? '').isEmpty && packBarcode.isNotEmpty) {
          existing['packBarcode'] = packBarcode;
        }

        if (_mergeByFormula) {
          // Combine dose if different (e.g. 500 mg, 250 mg)
          final currentDose = (existing['dose'] ?? '').toString().trim();
          if (doseDisplay.isNotEmpty && doseDisplay != '—' && currentDose.isNotEmpty && currentDose != '—' && !currentDose.contains(doseDisplay)) {
            existing['dose'] = '$currentDose, $doseDisplay';
          } else if (currentDose.isEmpty || currentDose == '—') {
            existing['dose'] = doseDisplay;
          }

          // Combine type if different
          final currentType = (existing['type'] ?? '').toString().trim();
          if (type.isNotEmpty && currentType.isNotEmpty && !currentType.contains(type)) {
            existing['type'] = '$currentType / $type';
          }

          // Track earliest expiry among merged batches
          final currentExp = existing['expiryDate']?.toString() ?? '';
          if (currentExp.isNotEmpty && monthYear.isNotEmpty && currentExp != monthYear) {
            final d1 = _parseExpiry(currentExp);
            final d2 = _parseExpiry(monthYear);
            final earliest = d1.isBefore(d2) ? currentExp : monthYear;
            existing['expiryDate'] = earliest;
            existing['hasMultipleExpiries'] = true;
          }
        }
      } else {
        map[key] = {
          'name': displayName,
          'type': type,
          'dose': doseDisplay,
          'formula': displayFormula,
          'barcode': barcode,
          'code': itemCode,
          'itemCode': itemCode,
          if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
          'expiryDate': monthYear,
          'quantity': qty,
          'price': price,
          'batchKey': key,
          'campId': data['campId'] ?? itemCamp,
          'dispensaryId': data['dispensaryId'] ?? itemCamp,
          'branchId': data['branchId'],
          '_docIds': <String>[docId],
          '_docPools': <String>[docPool],
          'pool': docPool,
          '_mergedCount': 1,
          '_isMerged': _mergeByFormula,
        };
      }
    }
    return map.values.toList();
  }

  void _updateBatchKeys(List<Map<String, dynamic>> preFiltered) {
    final set = <String>{};
    for (final b in preFiltered) {
      final e = (b['expiryDate'] as String?) ?? '';
      if (e.isNotEmpty) set.add(e);
    }
    var list = set.toList();
    list.sort((a, b) {
      int n(String s) {
        final p = s.split('-');
        if (p.length != 2) return 0;
        return (int.tryParse(p[1]) ?? 0) * 100 + (int.tryParse(p[0]) ?? 0);
      }
      return n(a).compareTo(n(b));
    });
    final newKeys = ['All Batches', ...list];
    if (_batchKeys.join(',') != newKeys.join(',')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _batchKeys = newKeys;
          if (!_batchKeys.contains(_filterBatch)) _filterBatch = 'All Batches';
        });
      });
    }
  }



  String _getBranchName() {
    if (_isAllBranchesMode) return 'All Branches';
    final effBranch = _effectiveBranchId;
    String bName = LocalStorageService.getBranchName(effBranch);
    if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
      final cached = Hive.box(LocalStorageService.branchesBox).get('branch:$effBranch');
      if (cached is Map && (cached['name'] ?? '').toString().trim().isNotEmpty) {
        bName = cached['name'].toString().trim();
      }
    }
    if (_selectedCampFilter != null && _selectedCampFilter != 'all' && _selectedCampFilter!.isNotEmpty) {
      final campLabel = CampSessionService.getCampLabel(_selectedCampFilter!, effBranch);
      return '$bName ($campLabel)';
    }
    return bName;
  }

  /// The tabs of this screen, in order (keys). Doctors see Stock only.
  List<String> get _tabKeys => _isDoctorUser
      ? const ['stock']
      : [
          'stock',
          'expiry',
          if (!_isSupervisorOrReadOnly) 'update',
          if (_canRegisterMedicine) 'register',
          if (!_isSupervisorUser) 'add',
          'report',
          'pending',
          'log',
          'history',
        ];

  static const Map<String, (String, IconData)> _tabMeta = {
    'stock': ('Stock', GIcons.inventory),
    'expiry': ('Expiry', GIcons.calendar),
    'update': ('Update Stock', GIcons.stock),
    'register': ('Register Medicine', GIcons.medicine),
    'add': ('Add Medicines', GIcons.add),
    'report': ('Report', GIcons.prescription),
    'pending': ('Pending', GIcons.waiting),
    'log': ('Log', GIcons.audit),
    'history': ('History', GIcons.history),
  };

  List<Map<String, dynamic>> get _menuItems => [
        for (final k in _tabKeys)
          {
            'key': k,
            'label': _tabMeta[k]!.$1,
            'icon': _tabMeta[k]!.$2,
            if (k == 'expiry') 'badge': _expiredBatchCount(),
          },
      ];

  /// Expired batches with stock in the pools on screen (sidebar badge).
  int _expiredBatchCount() {
    try {
      return ExpiryService.rows(_viewPools()).where((r) => r.status == ExpiryStatus.expired).length;
    } catch (_) {
      return 0;
    }
  }

  Widget _tabView(String key) {
    switch (key) {
      case 'stock':
        return _stockTab();
      case 'expiry':
        return ExpiryPage(
          key: ValueKey('exp_$_effectiveBranchId'),
          pools: _viewPools,
          branchId: _effectiveBranchId,
          needsApproval: widget.isDispenser && !widget.isAdmin,
        );
      case 'update':
        return InventoryUpdatePage(
          key: ValueKey('upd_$_effectiveBranchId'),
          branchId: _effectiveBranchId,
          isAdmin: widget.isAdmin,
          isDispenser: widget.isDispenser,
          isDoctor: widget.isDoctor,
          isEmbedded: true,
          showMode: 1,
        );
      case 'register':
        return InventoryUpdatePage(
          key: ValueKey('reg_$_effectiveBranchId'),
          branchId: _effectiveBranchId,
          isAdmin: widget.isAdmin,
          isDispenser: widget.isDispenser,
          isDoctor: widget.isDoctor,
          isEmbedded: true,
          showMode: 2,
        );
      case 'add':
        return AddMedicinePage(
          key: ValueKey('add_med_$_effectiveBranchId'),
          branchId: _effectiveBranchId,
          isAdmin: widget.isAdmin,
          isDispenser: widget.isDispenser,
          isEmbedded: true,
          onBackToInventory: () {
            _tabCtrl.animateTo(0);
            _loadDataFromHive();
          },
          onOpenRegisterMedicine: _canRegisterMedicine
              ? () {
                  final regIdx = _tabKeys.indexOf('register');
                  if (regIdx >= 0 && regIdx < _tabCtrl.length) {
                    _tabCtrl.animateTo(regIdx);
                    setState(() {});
                  }
                }
              : null,
        );
      case 'report':
        // Report: the medicine ledger + stock check results in one place.
        return StockReportPage(
          key: ValueKey('rep_$_effectiveBranchId'),
          branchId: _effectiveBranchId,
          isEmbedded: true,
          canAdjust: !_isDoctorUser,
        );
      case 'pending':
        return _pendingTab();
      case 'log':
        return _logTab();
      default:
        return _historyTab();
    }
  }

  Widget _buildMobileSubNav(BuildContext context) {
    final c = context.comfort;
    final List<Map<String, dynamic>> menuItems = _menuItems;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border, width: 1)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: menuItems.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final item = menuItems[index];
          final isActive = _tabCtrl.index == index;
          return InkWell(
            onTap: () {
              _tabCtrl.animateTo(index);
              setState(() {});
            },
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isActive ? c.brand : c.surfaceSunken,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isActive ? c.brand : c.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item['icon'] as IconData,
                    size: 13,
                    color: isActive ? c.onBrand : c.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    item['label'] as String,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                      color: isActive ? c.onBrand : c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidebarContent(BuildContext context) {
    final c = context.comfort;
    final List<Map<String, dynamic>> menuItems = _menuItems;

    return Container(
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
            child: Row(
              children: [
                Image.asset(
                  'assets/logo/gmwf-1.webp',
                  width: 40,
                  height: 40,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: c.brand,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(FontAwesomeIcons.pills, color: c.onBrand, size: 16),
                    );
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gulzar Madina',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      Text(
                        '${_getBranchName()} Inventory',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textSecondary,
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
          Divider(height: 1, color: c.border),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: menuItems.length,
              itemBuilder: (context, index) {
                final item = menuItems[index];
                final isActive = _tabCtrl.index == index;
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  decoration: BoxDecoration(
                    color: isActive ? c.brand : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: InkWell(
                    onTap: () {
                      _tabCtrl.animateTo(index);
                      if (GBreakpoint.isCompact(context)) {
                        Navigator.of(context).maybePop();
                      } else {
                        if (mounted) setState(() {});
                      }
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            item['icon'] as IconData,
                            color: isActive ? c.onBrand : c.textSecondary,
                            size: 17,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              item['label'] as String,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isActive ? c.onBrand : c.textPrimary,
                                fontSize: 13,
                                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          if ((item['badge'] as int? ?? 0) > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: isActive ? c.onBrand : c.danger,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${item['badge']}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: isActive ? c.danger : c.onBrand,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, color: c.border),
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.store_rounded, color: c.brand, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getBranchName(),
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      FutureBuilder<String>(
                        future: AutoUpdateService.getAppVersion(),
                        builder: (context, snapshot) {
                          final version = snapshot.data ?? AutoUpdateService.resolvedVersion;
                          return Text(
                            'v$version',
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        },
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.comfort;
    final bool isWrapped = GlobalModuleWrapper.isWrapped(context);
    final bool isMobile = GBreakpoint.isCompact(context);

    if (_isSupervisorUser || _isDoctorUser) {
      return Scaffold(
        backgroundColor: c.background,
        appBar: (!widget.isEmbedded && !isWrapped) ? _buildAppBar(isMobile: isMobile) : null,
        body: _stockTab(),
      );
    }

    return Scaffold(
      backgroundColor: c.background,
      appBar: (!widget.isEmbedded && !isWrapped) ? _buildAppBar(isMobile: isMobile) : null,
      drawer: (isMobile && !widget.isDispenser)
          ? Drawer(
              backgroundColor: c.surface,
              child: _buildSidebarContent(context),
            )
          : null,
      floatingActionButton: (_isSupervisorOrReadOnly || widget.isAdmin || !isMobile)
          ? null
          : FloatingActionButton.extended(
              backgroundColor: c.brand,
              foregroundColor: c.onBrand,
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => InventoryUpdatePage(
                            branchId: _effectiveBranchId,
                            isAdmin: widget.isAdmin,
                            isDispenser: widget.isDispenser,
                            isDoctor: widget.isDoctor,
                          ))),
              icon: const Icon(Icons.add_rounded),
              label: const Text(
                'Update Stock',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
      body: BlurredUnderDialogBackground(
        child: Row(
          children: [
            if (!isMobile)
              Container(
                width: 220,
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(right: BorderSide(color: c.border, width: 1)),
                ),
                child: _buildSidebarContent(context),
              ),
          Expanded(
            child: Column(
              children: [
                if (isMobile) _buildMobileSubNav(context),
                Expanded(
                  child: TabBarView(
                    controller: _tabCtrl,
                    children: [for (final k in _tabKeys) _tabView(k)],
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

  Widget _buildInternalActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 12, color: SoftPalette.gray50),
      label: Text(label, style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        elevation: 1,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  /// Removing from "All Branches" would hit pools the user cannot tell apart, so removal
  /// needs one branch (and camp) picked in the top bar first.
  bool _blockRemovalInAllBranches() {
    if (!_isAllBranchesMode) return false;
    AppToast.showSnackBar(
      context,
      const SnackBar(
        content: Text('Pick one branch in the top bar before removing medicines.'),
        backgroundColor: SoftPalette.amber300,
      ),
    );
    return true;
  }

  /// Asks why medicines are being removed. Doubles as the final confirmation.
  /// Returns the reason, or null when cancelled.
  Future<String?> _askRemovalReason({required int count, required String scope}) async {
    const reasons = [
      'Wrong entry',
      'Not our medicine / no barcode',
      'Expired',
      'Damaged',
      'Lost',
      'Duplicate',
    ];
    String? picked;
    final noteCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('Remove $count medicine${count == 1 ? '' : 's'}?'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('From: $scope', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    'Their stock is written down to 0 and they are hidden on every PC. '
                    'Their history stays in the log.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 12),
                  const Text('Reason', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in reasons)
                        ChoiceChip(
                          label: Text(r),
                          selected: picked == r,
                          onSelected: (_) => setDlg(() => picked = r),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: picked == null
                  ? null
                  : () {
                      final note = noteCtrl.text.trim();
                      Navigator.pop(ctx, note.isEmpty ? picked : '$picked: $note');
                    },
              icon: const Icon(GIcons.delete, size: 17),
              style: FilledButton.styleFrom(backgroundColor: SoftPalette.red400),
              label: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    noteCtrl.dispose();
    return result;
  }

  Future<void> _showDeleteInventoryDialog(Map<String, dynamic> batchData) async {
    if (!_canDeleteInventoryItem) {
      AppToast.showSnackBar(context,
        const SnackBar(
          content: Text('Only the Chairman and HQ Manager can delete medicines from inventory.'),
          backgroundColor: SoftPalette.red400,
        ),
      );
      return;
    }
    if (_blockRemovalInAllBranches()) return;

    final reason = await _askRemovalReason(
      count: 1,
      scope: '${batchData['name']} (${batchData['type'] ?? '—'} ${batchData['dose'] ?? ''}) · '
          'Qty ${batchData['quantity'] ?? 0} · ${_getBranchName()}',
    );
    if (reason == null || !mounted) return;

    try {
      final byPool = <StockPool, List<String>>{};
      for (final (pool, id) in _batchRefs(batchData)) {
        byPool.putIfAbsent(pool, () => []).add(id);
      }
      final res = await StockWipeService.removeBatches(byPool, reason: reason);

      // Refresh UI instantly
      if (mounted) {
        _loadDataFromHive();
        AppToast.clear();
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text(
              res.hasErrors
                  ? '⚠️ Removed ${res.localRemoved}, error: ${res.errors.first}'
                  : '✅ "${batchData['name']}" removed and logged.',
            ),
            backgroundColor: res.hasErrors ? SoftPalette.amber300 : SoftPalette.green400,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[InventoryDelete] ❌ ERROR: $e\n$st');
      if (mounted) {
        AppToast.clear();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('Delete notice: $e'),
            backgroundColor: SoftPalette.amber300,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _confirmDeleteSelectedMedicines() async {
    if (!_canDeleteInventoryItem) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('Only the Chairman and HQ Manager can delete medicines from inventory.'),
          backgroundColor: SoftPalette.red400,
        ),
      );
      return;
    }

    if (_selectedBatchKeys.isEmpty) return;
    if (_blockRemovalInAllBranches()) return;

    final selectedBatches = _filteredBatches
        .where((b) => _selectedBatchKeys.contains(b['batchKey']?.toString()))
        .toList();
    if (selectedBatches.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: SoftPalette.red400, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Delete ${selectedBatches.length} Medicine(s)?',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Remove the ${selectedBatches.length} selected medicine batch(es) from ${_getBranchName()}?\n\n'
                  '• Their stock is written down to 0 as a logged stock change.\n'
                  '• They are hidden on this PC, every LAN desk and the cloud.\n'
                  '• Their history is kept. You will be asked for a reason next.\n',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 6),
                const Text('Selected items to delete:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  decoration: BoxDecoration(
                    color: _isDark ? SoftPalette.slate800 : SoftPalette.gray100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ctx.adapt(SoftPalette.gray150)),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    itemCount: selectedBatches.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, idx) {
                      final sb = selectedBatches[idx];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            MedicineIconBadge(
                              name: sb['name']?.toString() ?? '',
                              type: sb['type']?.toString() ?? '',
                              size: 20,
                              iconSize: 12,
                              borderRadius: 5,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${sb['name']} (${sb['type']} ${sb['dose'] ?? ''}) - Qty: ${sb['quantity']}',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red500, foregroundColor: SoftPalette.gray50),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(GIcons.delete, size: 17),
              label: Text(
                'Remove ${selectedBatches.length}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;
    final reason = await _askRemovalReason(count: selectedBatches.length, scope: _getBranchName());
    if (reason == null || !mounted) return;

    try {
      if (mounted) setState(() => _isDeletingBatches = true);
      final byPool = <StockPool, List<String>>{};
      for (final batch in selectedBatches) {
        for (final (pool, id) in _batchRefs(batch)) {
          byPool.putIfAbsent(pool, () => []).add(id);
        }
      }
      final res = await StockWipeService.removeBatches(byPool, reason: reason);

      if (mounted) {
        setState(() {
          _isDeletingBatches = false;
          _isSelectMode = false;
          _selectedBatchKeys.clear();
        });
        _loadDataFromHive();
        AppToast.clear();
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text(
              res.hasErrors
                  ? '⚠️ Removed ${res.localRemoved} (${res.errors.length} error(s): ${res.errors.first})'
                  : '✅ Removed ${res.localRemoved} medicine(s) and logged the reason.',
            ),
            backgroundColor: res.hasErrors ? SoftPalette.amber300 : SoftPalette.green400,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e, st) {
      if (mounted) setState(() => _isDeletingBatches = false);
      debugPrint('[InventoryDelete] ❌ ERROR: $e\n$st');
      if (mounted) {
        AppToast.clear();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('Delete notice: $e'),
            backgroundColor: SoftPalette.amber300,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  PreferredSizeWidget _buildAppBar({bool isMobile = false}) => AppBar(
        backgroundColor: _isDark ? SoftPalette.slate900 : _teal,
        elevation: 1,
        toolbarHeight: 55,
        automaticallyImplyLeading: false,
        leading: (!widget.isEmbedded && Navigator.canPop(context))
            ? const AppBackButton(color: SoftPalette.gray50)
            : (isMobile && !widget.isDispenser && !_isDoctorUser && !_isSupervisorUser
                ? Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu_rounded, color: SoftPalette.gray50, size: 22),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                  )
                : null),
        iconTheme: const IconThemeData(color: SoftPalette.gray50),
        title: Row(children: [
          const Icon(FontAwesomeIcons.pills,
              color: SoftPalette.gray50A70, size: 14),
          const SizedBox(width: 8),
          const Text('Inventory',
              style: TextStyle(
                  color: SoftPalette.gray50,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ]),
        actions: [
          if (_isDoctorUser)
            Tooltip(
              message: 'Refresh inventory',
              child: IconButton(
                onPressed: _isRefreshingInventory ? null : () => _refreshInventory(),
                icon: _isRefreshingInventory
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                      )
                    : const Icon(Icons.refresh_rounded, color: SoftPalette.gray50, size: 20),
              ),
            ),
          if (!_isHigherAuthority)
            CampSelectorChip(
              branchId: _effectiveBranchId,
              onCampChanged: (newCamp) {
                _selectedCampFilter = newCamp;
                _loadDataFromHive();
              },
            ),
          const SizedBox(width: 6),
          ValueListenableBuilder(
            valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox), cooldown: const Duration(seconds: 2)),
            builder: (context, Box box, _) {
              final failuresCount = box.values
                  .whereType<Map>()
                  .where((action) => (action['attempts'] ?? 0) > 0)
                  .length;
              if (failuresCount == 0) return const SizedBox.shrink();
              return Tooltip(
                message: '$failuresCount sync operations retrying',
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Icon(Icons.sync_problem_rounded, color: SoftPalette.amber300),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: CircleAvatar(
                            radius: 6,
                            backgroundColor: SoftPalette.red400,
                            child: Text(
                              '$failuresCount',
                              style: const TextStyle(color: SoftPalette.gray50, fontSize: 8, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                    onPressed: () => _showSyncFailuresDialog(context),
                  ),
                ),
              );
            },
          ),
        ],
      );

  /// Items that failed to upload and are waiting in the retry queue, with their Hive keys.
  List<MapEntry<dynamic, Map>> _failedSyncEntries() {
    final box = Hive.box(LocalStorageService.syncBox);
    return box
        .toMap()
        .entries
        .where((e) => e.value is Map && ((e.value as Map)['attempts'] ?? 0) > 0)
        .map((e) => MapEntry<dynamic, Map>(e.key, e.value as Map))
        .toList();
  }

  /// "Clearing" moves the item to the dead-letter queue instead of deleting it, so it is
  /// no longer retried but can still be recovered. The local record itself is untouched.
  Future<void> _dismissSyncEntry(dynamic key, Map item) async {
    await LocalStorageService.moveToDeadLetterQueue(
      LocalStorageService.syncBox,
      key,
      Map<String, dynamic>.from(item),
      reason: 'Dismissed by user from Sync Retry Queue',
    );
  }

  void _showSyncFailuresDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final failed = _failedSyncEntries();

            Future<void> clearAll() async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear all failed items?'),
                  content: Text(
                      '${failed.length} items that could not be uploaded will stop retrying. '
                      'The data stays saved on this computer and the items are kept in the '
                      'dead-letter queue, but they will not reach the cloud unless re-queued.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: SoftPalette.red500),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear all'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              for (final e in failed) {
                await _dismissSyncEntry(e.key, e.value);
              }
              if (context.mounted) setDialogState(() {});
            }

            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.sync_problem_rounded, color: SoftPalette.amber300),
                  SizedBox(width: 8),
                  Text('Sync Retry Queue'),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: failed.isEmpty
                    ? const Text('All sync operations are running smoothly.')
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: failed.length,
                        itemBuilder: (context, index) {
                          final entry = failed[index];
                          final item = entry.value;
                          final type = item['type'] ?? 'Unknown';
                          final attempts = item['attempts'] ?? 0;
                          final error = item['lastError'] ?? 'Unknown network timeout';
                          final data = item['data'] is Map ? item['data'] as Map : {};
                          final name = data['name'] ?? item['medicineName'] ?? 'General Sync Item';

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              title: Text('$name ($type)'),
                              subtitle: Text('Error: $error\nRetries: $attempts'),
                              isThreeLine: true,
                              leading: const Icon(Icons.error_outline_rounded, color: SoftPalette.red400),
                              trailing: IconButton(
                                tooltip: 'Clear this item (stop retrying)',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  await _dismissSyncEntry(entry.key, item);
                                  if (context.mounted) setDialogState(() {});
                                },
                              ),
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                if (failed.isNotEmpty) ...[
                  TextButton.icon(
                    onPressed: clearAll,
                    icon: const Icon(Icons.delete_sweep_rounded, color: SoftPalette.red400),
                    label: const Text('Clear all', style: TextStyle(color: SoftPalette.red400)),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      SyncService().triggerUpload(force: true);
                      AppToast.showSnackBar(context, 
                        const SnackBar(content: Text('Retrying upload now…'), duration: Duration(seconds: 2)),
                      );
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry now'),
                  ),
                ],
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Stock Tab ─────────────────────────────────────────────────────────────
  Widget _stockTab() {
    if (_rawItems.isEmpty) {
      final emptyCard = Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _isDark ? SoftPalette.slate700 : SoftPalette.gray150),
            boxShadow: [
              BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GEmptyIllustration(
                GEmptyIllustrationKind.inventory,
                size: 148,
                fallbackIcon: Icons.inventory_2_outlined,
              ),
              const SizedBox(height: 14),
              Text(
                'No Medicines in ${_getBranchName()} Stock',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _isDark ? SoftPalette.gray50 : _textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Stock for this branch has not been loaded or added yet. You can add medicines from Add Medicine or refresh from cloud.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: _isDark ? SoftPalette.slate350 : _textLight,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  if (!_isSupervisorOrReadOnly)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _teal,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddMedicinePage(
                              branchId: _effectiveBranchId,
                              isAdmin: widget.isAdmin,
                              isDispenser: widget.isDispenser,
                            ),
                          ),
                        ).then((_) => _loadDataFromHive());
                      },
                      icon: const Icon(Icons.playlist_add_rounded, size: 18),
                      label: const Text('Add Medicine'),
                    ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _teal,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      side: BorderSide(color: _teal),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _isRefreshingInventory ? null : () => _refreshInventory(),
                    icon: _isRefreshingInventory
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _teal),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(_isRefreshingInventory ? 'Refreshing...' : 'Refresh Inventory'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      if (_isHigherAuthority) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCampScopeBar(),
            _buildHigherAuthorityControls(),
            Expanded(child: emptyCard),
          ],
        );
      }
      return emptyCard;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isHigherAuthority) _buildCampScopeBar(),
        _buildMetricsRow(_groupedBatches, GBreakpoint.isCompact(context)),
        if (_isHigherAuthority) _buildHigherAuthorityControls(),
        _buildFilterSection(),
        if (_isSelectMode) _buildSelectionActionBar(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _displayItems.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const GEmptyIllustration(
                            GEmptyIllustrationKind.search,
                            size: 144,
                            fallbackIcon: GIcons.searchOff,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'No medicines match your current filter',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                              color: context.comfort.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Try a different search term or reset your active filters.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: context.comfort.textSecondary,
                            ),
                          ),
                          if (_searchCtrl.text.trim().isNotEmpty ||
                              _filterType != 'All' ||
                              _filterBatch != 'All Batches' ||
                              _filterMissingBarcodeOnly) ...[
                            const SizedBox(height: 14),
                            OutlinedButton.icon(
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {
                                  _filterType = 'All';
                                  _filterBatch = 'All Batches';
                                  _filterMissingBarcodeOnly = false;
                                  _processData();
                                });
                              },
                              icon: const Icon(GIcons.close, size: 15),
                              label: const Text('Clear Filters'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : LayoutBuilder(builder: (ctx, constraints) {
                    return constraints.maxWidth > 640
                        ? _stockTable(_displayItems, constraints.maxWidth, _filteredBatches.length, constraints.maxHeight)
                        : _stockCards(_displayItems, _filteredBatches.length);
                  }),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectionActionBar() {
    final allSelected = _allFilteredSelected;
    final count = _selectedBatchKeys.length;
    final total = _filteredBatches.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _isDark ? SoftPalette.slate800 : SoftPalette.red100t,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _isDark ? SoftPalette.red600 : SoftPalette.red200,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.red400.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Select all checkbox
          InkWell(
            onTap: _toggleSelectAll,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: allSelected,
                      tristate: count > 0 && !allSelected,
                      activeColor: SoftPalette.red500,
                      onChanged: (_) => _toggleSelectAll(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    allSelected ? 'Deselect All' : 'Select All ($total)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: _isDark ? SoftPalette.gray50 : SoftPalette.red550,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: count > 0
                  ? SoftPalette.red400.withValues(alpha: 0.15)
                  : (_isDark ? SoftPalette.gray50A10 : SoftPalette.gray350.withValues(alpha: 0.15)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count of $total selected',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: count > 0
                    ? (_isDark ? SoftPalette.red350 : SoftPalette.red550)
                    : (_isDark ? SoftPalette.slate350 : SoftPalette.gray550),
              ),
            ),
          ),
          const Spacer(),
          // Delete selected button
          ElevatedButton.icon(
            onPressed: count > 0 ? _confirmDeleteSelectedMedicines : null,
            icon: const Icon(GIcons.delete, size: 16, color: SoftPalette.gray50),
            label: Text(
              'Delete Selected ($count)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.red500,
              foregroundColor: SoftPalette.gray50,
              disabledBackgroundColor: _isDark ? SoftPalette.gray700 : SoftPalette.gray150,
              disabledForegroundColor: _isDark ? SoftPalette.gray50A38 : SoftPalette.gray500,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          // Cancel / Exit button
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _isSelectMode = false;
                _selectedBatchKeys.clear();
              });
            },
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text('Exit Selection', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _isDark ? SoftPalette.gray50A70 : SoftPalette.gray700,
              side: BorderSide(color: _isDark ? SoftPalette.gray50A24 : SoftPalette.gray300),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCampFilterChip(String campId, String label) {
    final c = context.comfort;
    final active = _selectedCampFilter ?? 'all';
    final isSelected = active == campId || (campId == 'haji_camp' && active == 'haji') || (campId == 'haji' && active == 'haji_camp');
    return InkWell(
      onTap: () {
        setState(() {
          _selectedCampFilter = campId;
          _selectedBatchKeys.clear();
          _displayLimit = 50;
          _loadDataFromHive();
        });
        if (!_isHigherAuthority) {
          CampSessionService.setActiveCamp(campId, isManual: true);
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? c.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            color: isSelected ? c.onBrand : c.textSecondary,
          ),
        ),
      ),
    );
  }

  /// Camp selector bar for Higher Authority users — branch selection itself is controlled
  /// by the top-bar branch selector so there is zero duplication or clashing across screens.
  /// Shows Camp chips ONLY when the active branch has multiple camps (e.g. Karachi -> Saddar / Haji Camp),
  /// or a brief hint when "All Branches" is active in the top bar.
  Widget _buildCampScopeBar() {
    final c = context.comfort;
    if (_isAllBranchesMode) {
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.brand.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.public_rounded, size: 16, color: c.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Viewing All Branches — choose a specific branch from the top bar above to view or manage only that branch\'s inventory.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    final effBranch = _effectiveBranchId;
    final branchCamps = CampSessionService.getCampsForBranch(effBranch);
    final hasCamps = (CampSessionService.hasCampsForBranch(effBranch) || effBranch.contains('karachi')) &&
        branchCamps.isNotEmpty;
    if (!hasCamps) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.brand.withValues(alpha: 0.25)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: c.brandSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.location_on_rounded, size: 15, color: c.brand),
              ),
              const SizedBox(width: 8),
              Text(
                'Camp:',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: c.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCampFilterChip('all', 'All Camps'),
                for (final camp in branchCamps) ...[
                  const SizedBox(width: 2),
                  _buildCampFilterChip(
                    (camp['id'] ?? '').toString(),
                    (camp['name'] ?? camp['id'] ?? '').toString(),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.brandSoft,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.brand.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.track_changes_rounded, size: 13, color: c.brand),
                const SizedBox(width: 5),
                Text(
                  'Active: ${_getBranchName()}',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.brand),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Dedicated Higher Authority Controls strip — visible ONLY to Chairman, HQ Manager & Admins,
  /// explicitly communicating that these controls are hidden from lower-level users.
  Widget _buildHigherAuthorityControls() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final btnPad = EdgeInsets.symmetric(horizontal: isCompact ? 8 : 9);
    final labelStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: isCompact ? 11 : 11.5);
    const ctrlHeight = 30.0;

    final accentBorder = _isDark ? SoftPalette.amber300.withValues(alpha: 0.30) : SoftPalette.amber300.withValues(alpha: 0.50);
    final accentBg = _isDark ? SoftPalette.slate800.withValues(alpha: 0.9) : SoftPalette.amber50m;
    final badgeFg = _isDark ? SoftPalette.amber200 : SoftPalette.amber600;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: accentBg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accentBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3.5, color: badgeFg),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isCompact ? 9 : 12, vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(GIcons.shield, size: 15, color: badgeFg),
                            const SizedBox(width: 6),
                            Text(
                              'Higher Authority Controls',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.textPrimary),
                            ),
                          ],
                        ),
                        Tooltip(
                          message:
                              'Visible only to Chairman, HQ Manager & Admins — these management and permanent deletion tools are not visible to lower-level staff.',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: badgeFg.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: badgeFg.withValues(alpha: 0.32)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(GIcons.visibilityOff, size: 11, color: badgeFg),
                                const SizedBox(width: 4),
                                Text(
                                  'Hidden from lower-level users',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: badgeFg),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!isCompact)
                          Text(
                            'Chairman, HQ Manager & Admins only',
                            style: TextStyle(fontSize: 10.5, color: c.textMuted, fontWeight: FontWeight.w500),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_canRegisterMedicine)
                          SizedBox(
                            height: ctrlHeight,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                const regIdx = 2;
                                if (regIdx < _tabCtrl.length) {
                                  _tabCtrl.animateTo(regIdx);
                                  setState(() {});
                                } else {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => InventoryUpdatePage(
                                        branchId: _effectiveBranchId,
                                        isAdmin: widget.isAdmin,
                                        isDispenser: widget.isDispenser,
                                        isDoctor: widget.isDoctor,
                                        showMode: 2,
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(GIcons.add, size: 14),
                              label: Text('Register Medicine', style: labelStyle),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: c.brandStrong,
                                foregroundColor: c.onBrand,
                                elevation: 0,
                                padding: btnPad,
                                shape: shape,
                              ),
                            ),
                          ),
                        SizedBox(
                          height: ctrlHeight,
                          child: OutlinedButton.icon(
                            onPressed: _isRefreshingInventory ? null : _syncInventoryFromCloud,
                            icon: _isRefreshingInventory
                                ? SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: c.textSecondary),
                                  )
                                : Icon(GIcons.sync, size: 14, color: c.textPrimary),
                            label: Text(_isRefreshingInventory ? 'Syncing…' : 'Sync / Restore Cloud', style: labelStyle),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: c.surface,
                              foregroundColor: c.textPrimary,
                              side: BorderSide(color: c.borderStrong),
                              padding: btnPad,
                              shape: shape,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: ctrlHeight,
                          child: ElevatedButton.icon(
                            onPressed: _isDeletingBatches
                                ? null
                                : () {
                                    setState(() {
                                      _isSelectMode = !_isSelectMode;
                                      if (!_isSelectMode) _selectedBatchKeys.clear();
                                    });
                                  },
                            icon: Icon(_isSelectMode ? GIcons.close : GIcons.checklist, size: 14),
                            label: Text(_isSelectMode ? 'Cancel Selection' : 'Select & Delete', style: labelStyle),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isSelectMode ? SoftPalette.slate700 : SoftPalette.red500,
                              foregroundColor: SoftPalette.gray50,
                              elevation: 0,
                              padding: btnPad,
                              shape: shape,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: ctrlHeight,
                          child: OutlinedButton.icon(
                            onPressed: _isDeletingBatches ? null : _showSelectByBarcodesDialog,
                            icon: const Icon(GIcons.qr, size: 14),
                            label: Text('Remove by Barcodes', style: labelStyle),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: c.surface,
                              foregroundColor: SoftPalette.red550,
                              side: BorderSide(color: SoftPalette.red400.withValues(alpha: 0.55)),
                              padding: btnPad,
                              shape: shape,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: ctrlHeight,
                          child: OutlinedButton.icon(
                            onPressed: _isDeletingBatches ? null : _showRemoveUnbarcodedDialog,
                            icon: const Icon(GIcons.filter, size: 14),
                            label: Text('Remove Unbarcoded Meds', style: labelStyle),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: c.surface,
                              foregroundColor: SoftPalette.orange500,
                              side: BorderSide(color: SoftPalette.orange400.withValues(alpha: 0.60)),
                              padding: btnPad,
                              shape: shape,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: ctrlHeight,
                          child: OutlinedButton.icon(
                            onPressed: _isDeletingBatches ? null : _confirmWipeSelectedPool,
                            icon: const Icon(GIcons.delete, size: 14),
                            label: Text('Wipe Selected Pool', style: labelStyle),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: c.surface,
                              foregroundColor: SoftPalette.red600,
                              side: BorderSide(color: SoftPalette.red500.withValues(alpha: 0.55)),
                              padding: btnPad,
                              shape: shape,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Higher Authority tool: paste/type 3-digit barcodes (e.g. `012, 040, 046, 053, 059, 063, 071`)
  /// to immediately preview and either select or permanently delete all matching batches in the
  /// currently selected Branch / Camp.
  Future<void> _showSelectByBarcodesDialog() async {
    if (_blockRemovalInAllBranches()) return;
    final scopeLabel = _getBranchName();
    List<Map<String, dynamic>> matchedBatches = [];
    List<String> parsedCodes = [];
    List<String> notFoundCodes = [];

    void recompute(String raw) {
      // A segment (line / comma part) with words, like "Ponstan 250 046", gives only its LAST
      // 3-digit code (the dose 250 is not a barcode). A bare list "012 040 046" gives all.
      final threeDigits = RegExp(r'^\d{3}$');
      final tokens = <String>[];
      for (final seg in raw.split(RegExp(r'[\n,;]+'))) {
        final parts = seg.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
        if (parts.isEmpty) continue;
        final codes = parts.where(threeDigits.hasMatch).toList();
        if (codes.isEmpty) continue;
        final hasWords = parts.any((p) => RegExp(r'[A-Za-z؀-ۿ]').hasMatch(p));
        tokens.addAll(hasWords ? [codes.last] : codes);
      }
      final normSet = <String>{};
      for (final t in tokens) {
        final norm = MasterProformaService.normalizeProformaBarcode(t);
        if (norm != null) normSet.add(norm);
      }
      parsedCodes = normSet.toList()..sort();
      final matched = <Map<String, dynamic>>[];
      final foundCodes = <String>{};
      for (final b in _groupedBatches) {
        final bar = MasterProformaService.normalizeProformaBarcode(
            (b['barcode'] ?? b['rollNo'] ?? '').toString());
        if (bar != null && normSet.contains(bar)) {
          matched.add(b);
          foundCodes.add(bar);
        }
      }
      matchedBatches = matched;
      notFoundCodes = parsedCodes.where((c) => !foundCodes.contains(c)).toList();
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.qr_code_scanner_rounded, color: SoftPalette.red500, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Remove Medicines by Barcodes — $scopeLabel',
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter 3-digit barcodes separated by spaces, commas, or new lines — or paste lines like "Calcium 012" directly. '
                    'Only medicines in "$scopeLabel" will be matched.',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    maxLines: 3,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '012, 040, 046, 053, 059, 063, 071',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.all(10),
                    ),
                    onChanged: (v) => setDlgState(() => recompute(v)),
                  ),
                  const SizedBox(height: 10),
                  if (parsedCodes.isNotEmpty) ...[
                    Text(
                      'Matched ${matchedBatches.length} medicine row(s) in $scopeLabel'
                      '${notFoundCodes.isNotEmpty ? ' • Not found: ${notFoundCodes.join(", ")}' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: matchedBatches.isNotEmpty ? SoftPalette.red550 : SoftPalette.slate600,
                      ),
                    ),
                    if (matchedBatches.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        decoration: BoxDecoration(
                          color: _isDark ? SoftPalette.slate800 : SoftPalette.gray100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ctx.adapt(SoftPalette.gray150)),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < matchedBatches.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: SoftPalette.teal500.withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(5),
                                        ),
                                        child: Text(
                                          '${matchedBatches[i]['barcode'] ?? '—'}',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${matchedBatches[i]['name']} (${matchedBatches[i]['type'] ?? ''} ${matchedBatches[i]['dose'] ?? ''})',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        'Qty: ${matchedBatches[i]['quantity'] ?? 0}',
                                        style: const TextStyle(fontSize: 11.5, color: SoftPalette.slate500),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            if (matchedBatches.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'select'),
                icon: const Icon(Icons.checklist_rounded, size: 16),
                label: Text('Select (${matchedBatches.length})'),
              ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.red500,
                foregroundColor: SoftPalette.gray50,
              ),
              onPressed: matchedBatches.isEmpty ? null : () => Navigator.pop(ctx, 'delete'),
              icon: const Icon(GIcons.delete, size: 17),
              label: Text(
                'Remove (${matchedBatches.length})',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null || matchedBatches.isEmpty) return;

    if (action == 'select') {
      setState(() {
        _isSelectMode = true;
        _selectedBatchKeys.clear();
        for (final b in matchedBatches) {
          final k = (b['batchKey'] ?? '').toString();
          if (k.isNotEmpty) _selectedBatchKeys.add(k);
        }
      });
      return;
    }

    if (action == 'delete') {
      final reason = await _askRemovalReason(count: matchedBatches.length, scope: scopeLabel);
      if (reason == null || !mounted) return;
      setState(() => _isDeletingBatches = true);
      try {
        final byPool = <StockPool, List<String>>{};
        for (final b in matchedBatches) {
          for (final (pool, id) in _batchRefs(b)) {
            byPool.putIfAbsent(pool, () => []).add(id);
          }
        }
        final res = await StockWipeService.removeBatches(byPool, reason: reason);
        if (mounted) {
          setState(() => _isDeletingBatches = false);
          _loadDataFromHive();
          AppToast.showSnackBar(
            context,
            SnackBar(
              content: Text(
                res.hasErrors
                    ? '⚠️ Removed ${res.localRemoved} (${res.errors.first})'
                    : '✅ Removed ${res.localRemoved} medicine(s) from $scopeLabel and logged the reason.',
              ),
              backgroundColor: res.hasErrors ? SoftPalette.amber300 : SoftPalette.green400,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isDeletingBatches = false);
          AppToast.showSnackBar(context, SnackBar(content: Text('Delete error: $e'), backgroundColor: SoftPalette.red400));
        }
      }
    }
  }

  /// Higher Authority tool: scans either the selected Branch/Camp OR ALL Branches & Camps
  /// (local Hive + Firestore server) for medicines with no barcode or not carrying an official
  /// GMWF Master Proforma barcode, previews them, and deletes them permanently everywhere.
  Future<void> _showRemoveUnbarcodedDialog() async {
    // Default to the branch picked in the top bar; "All" must be chosen on purpose.
    var allInventories = _isAllBranchesMode;
    final scopeAtOpen = _isAllBranchesMode ? 'All branches & camps' : _getBranchName();
    final poolsAtOpen = _viewPools();
    var scanning = false;
    var deleting = false;
    var scannedOnce = false;
    String statusText = 'Choose a scope and click Scan to find all medicines without an official GMWF medicine barcode.';
    List<UnbarcodedMedicineMatch> matches = [];
    List<String> scanErrors = [];
    int totalScanned = 0;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          Future<void> runScan() async {
            setDlgState(() {
              scanning = true;
              scannedOnce = false;
              matches = [];
              scanErrors = [];
              statusText = allInventories
                  ? 'Scanning ALL branches & camps (Local + Firestore Cloud)…'
                  : 'Scanning $scopeAtOpen (Local + Firestore Cloud)…';
            });
            try {
              final pools = allInventories
                  ? await StockWipeService.allBranchPools(includeCloudBranches: true)
                  : poolsAtOpen;
              final res = await StockWipeService.scanUnbarcodedMedicines(
                pools: pools,
                includeCloud: true,
                onProgress: (msg) {
                  if (ctx.mounted) setDlgState(() => statusText = msg);
                },
              );
              if (ctx.mounted) {
                setDlgState(() {
                  scanning = false;
                  scannedOnce = true;
                  matches = res.matches;
                  totalScanned = res.totalScanned;
                  scanErrors = res.errors;
                  statusText = matches.isEmpty
                      ? '✅ All $totalScanned scanned medicine(s) have a valid official GMWF barcode!'
                      : 'Found ${matches.length} medicine(s) without an official GMWF barcode (out of $totalScanned scanned across ${pools.length} pool(s)).';
                });
              }
            } catch (e) {
              if (ctx.mounted) {
                setDlgState(() {
                  scanning = false;
                  scannedOnce = true;
                  scanErrors = ['Scan failed: $e'];
                  statusText = '❌ Scan failed: $e';
                });
              }
            }
          }

          Future<void> runDelete() async {
            if (matches.isEmpty || deleting) return;
            final reason = await _askRemovalReason(
              count: matches.length,
              scope: allInventories
                  ? 'ALL branches & camps (${matches.map((m) => m.pool.key).toSet().length} pools)'
                  : scopeAtOpen,
            );
            if (reason == null || !ctx.mounted) return;
            setDlgState(() {
              deleting = true;
              statusText = 'Removing ${matches.length} unbarcoded medicine(s)…';
            });
            try {
              final byPool = <StockPool, List<String>>{};
              for (final m in matches) {
                byPool.putIfAbsent(m.pool, () => []).add(m.medicineId);
              }
              final res = await StockWipeService.removeBatches(
                byPool,
                reason: reason,
                onProgress: (msg) {
                  if (ctx.mounted) setDlgState(() => statusText = msg);
                },
              );
              if (ctx.mounted) {
                Navigator.pop(ctx);
              }
              if (mounted) {
                _loadDataFromHive();
                AppToast.showSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      res.hasErrors
                          ? '⚠️ Removed ${res.localRemoved} (${res.errors.length} error(s): ${res.errors.first})'
                          : '✅ Removed ${res.localRemoved} unbarcoded medicine(s) and logged the reason.',
                    ),
                    backgroundColor: res.hasErrors ? SoftPalette.amber300 : SoftPalette.green400,
                    duration: const Duration(seconds: 5),
                  ),
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                setDlgState(() {
                  deleting = false;
                  statusText = '❌ Delete error: $e';
                });
              }
            }
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.cleaning_services_rounded, color: SoftPalette.orange500, size: 24),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Remove Unbarcoded / Non-Catalog Medicines',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 580,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Finds medicines that have NO barcode or whose barcode does not match our official GMWF Medicine Catalog. '
                    'Check the list before removing: a spelling variant of a real medicine can show up here.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('All Branches & Camps (All Inventories)'),
                        selected: allInventories,
                        onSelected: (scanning || deleting)
                            ? null
                            : (_) => setDlgState(() {
                                  allInventories = true;
                                  scannedOnce = false;
                                  matches = [];
                                }),
                      ),
                      ChoiceChip(
                        label: Text('Current Scope ($scopeAtOpen)'),
                        selected: !allInventories,
                        onSelected: (scanning || deleting || _isAllBranchesMode)
                            ? null
                            : (_) => setDlgState(() {
                                  allInventories = false;
                                  scannedOnce = false;
                                  matches = [];
                                }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _isDark ? SoftPalette.slate800 : SoftPalette.gray100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        if (scanning || deleting) ...[
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(statusText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
                  if (scanErrors.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Notes: ${scanErrors.take(2).join(' | ')}',
                      style: const TextStyle(fontSize: 11, color: SoftPalette.orange500),
                    ),
                  ],
                  if (matches.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 260),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ctx.adapt(SoftPalette.gray150)),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < matches.length; i++) ...[
                              if (i > 0) const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 5),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            matches[i].name.isEmpty ? '(Blank / Unnamed)' : matches[i].name,
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            '${matches[i].poolLabel} • ${matches[i].type.isEmpty ? 'No Type' : matches[i].type}'
                                            '${matches[i].dose.isNotEmpty ? ' ${matches[i].dose}' : ''} • Qty: ${matches[i].quantity.toInt()}',
                                            style: const TextStyle(fontSize: 11, color: SoftPalette.slate500),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: SoftPalette.red400.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        matches[i].rawBarcode.isEmpty ? 'No Barcode' : 'Invalid: ${matches[i].rawBarcode}',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: SoftPalette.red550,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: (scanning || deleting) ? null : () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              OutlinedButton.icon(
                onPressed: (scanning || deleting) ? null : runScan,
                icon: const Icon(Icons.search_rounded, size: 17),
                label: Text(scannedOnce ? 'Re-Scan' : 'Scan Now'),
              ),
              if (matches.isNotEmpty)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SoftPalette.red500,
                    foregroundColor: SoftPalette.gray50,
                  ),
                  onPressed: (scanning || deleting) ? null : runDelete,
                  icon: const Icon(GIcons.delete, size: 17),
                  label: Text(
                    'Remove All ${matches.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Higher Authority tool: permanently wipes the currently selected single branch/camp pool
  /// after verifying the single wipe password (`admin123`), using `StockWipeService.wipePool`.
  Future<void> _confirmWipeSelectedPool() async {
    final pool = _singleViewPool;
    if (pool == null) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select a Specific Branch / Camp First'),
          content: const Text(
            'Please pick a specific branch from the top bar above (and a specific camp such as Saddar or Haji Camp if the branch has multiple camps) before wiping.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Understood')),
          ],
        ),
      );
      return;
    }

    var enteredPw = '';
    String? err;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: SoftPalette.red500, size: 26),
              const SizedBox(width: 8),
              Expanded(child: Text('Wipe All Meds — ${_getBranchName()}')),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This will permanently wipe EVERY medicine and movement from:\n'
                  '• Pool: ${pool.key}\n'
                  '• Firestore: branches/${pool.cloudBranch}/${pool.collection}\n'
                  '• Connected Doctor, Dispensary & Hybrid desks\n\n'
                  'Enter the wipe password to confirm:',
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Wipe Password',
                    errorText: err,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) {
                    enteredPw = v;
                    if (err != null) setDlgState(() => err = null);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red600, foregroundColor: SoftPalette.gray50),
              icon: const Icon(GIcons.delete, size: 17),
              label: const Text('Wipe Permanently', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () {
                if (!StockAuthority.verifyWipePassword(enteredPw)) {
                  setDlgState(() => err = 'Incorrect password.');
                  return;
                }
                Navigator.pop(ctx, true);
              },
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeletingBatches = true);
    try {
      final result = await StockWipeService.wipePool(pool);
      if (mounted) {
        setState(() => _isDeletingBatches = false);
        _loadDataFromHive();
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text(
              result.hasErrors
                  ? '⚠️ Wiped ${result.itemsWiped} local, ${result.cloudDocsDeleted} cloud (${result.errors.first})'
                  : '✅ Wiped ${pool.key} completely (Local: ${result.itemsWiped}, Firestore: ${result.cloudDocsDeleted}).',
            ),
            backgroundColor: result.hasErrors ? SoftPalette.amber300 : SoftPalette.green400,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDeletingBatches = false);
        AppToast.showSnackBar(context, SnackBar(content: Text('Wipe error: $e'), backgroundColor: SoftPalette.red400));
      }
    }
  }

  Widget _buildMissingBarcodeFilterChip({bool isCompact = false}) {
    final c = context.comfort;
    final officialBarcodes = MasterProformaService.getOfficialBarcodes();
    final missingCount = _groupedBatches
        .where((b) => _isBatchMissingOfficialBarcode(b, officialBarcodes))
        .length;
    if (missingCount == 0 && !_filterMissingBarcodeOnly) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: 'Show only medicines missing an official GMWF medicine barcode',
      child: InkWell(
        onTap: () {
          setState(() {
            _filterMissingBarcodeOnly = !_filterMissingBarcodeOnly;
            _displayLimit = 50;
            _processData();
          });
        },
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 9),
          decoration: BoxDecoration(
            color: _filterMissingBarcodeOnly
                ? SoftPalette.orange400.withValues(alpha: 0.16)
                : c.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _filterMissingBarcodeOnly ? SoftPalette.orange500 : c.border,
              width: _filterMissingBarcodeOnly ? 1.3 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _filterMissingBarcodeOnly ? GIcons.warning : GIcons.qr,
                size: 14,
                color: _filterMissingBarcodeOnly ? SoftPalette.orange500 : c.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                'No Barcode ($missingCount)',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: _filterMissingBarcodeOnly ? FontWeight.w700 : FontWeight.w600,
                  color: _filterMissingBarcodeOnly ? SoftPalette.orange500 : c.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterSection() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final effBranch = _effectiveBranchId;
    final branchCamps = CampSessionService.getCampsForBranch(effBranch);
    final hasCamps = (effBranch.contains('karachi') || CampSessionService.hasCampsForBranch(effBranch)) &&
        branchCamps.isNotEmpty;
    final showInlineCampBar = hasCamps && !widget.isDoctor && !_isHigherAuthority;
    const ctrlHeight = 34.0;

    Widget buildSearchField() {
      return Container(
        height: ctrlHeight,
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.borderStrong),
        ),
        child: TextField(
          controller: _searchCtrl,
          cursorColor: c.brand,
          onChanged: (_) {
            setState(() {});
            _onSearchChanged();
          },
          style: TextStyle(fontSize: 12.5, color: c.textPrimary),
          decoration: InputDecoration(
            prefixIcon: Icon(GIcons.search, color: c.brand, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            suffixIcon: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: Icon(GIcons.close, size: 15, color: c.textSecondary),
                    padding: EdgeInsets.zero,
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchCtrl.clear();
                      _displayLimit = 50;
                      setState(() => _processData());
                    },
                  )
                : null,
            hintText: isCompact
                ? 'Search formula or barcode...'
                : 'Search medicine, formula, or barcode...',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
          ),
        ),
      );
    }

    Widget buildDropdownChip({
      required String value,
      required List<String> items,
      required IconData icon,
      required ValueChanged<String?> onChanged,
    }) {
      return Container(
        height: ctrlHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: c.brand),
            const SizedBox(width: 5),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: items.contains(value) ? value : items.first,
                isDense: true,
                dropdownColor: c.surface,
                icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.textSecondary),
                onChanged: onChanged,
                items: items
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(
                            v,
                            style: TextStyle(
                              fontSize: isCompact ? 12 : 12.5,
                              fontWeight: FontWeight.w600,
                              color: c.textPrimary,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildCampBar() {
      return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCampFilterChip('all', isCompact ? '🏥 All' : '🏥 All Camps'),
            for (final camp in branchCamps) ...[
              const SizedBox(width: 2),
              _buildCampFilterChip(
                (camp['id'] ?? '').toString(),
                '📍 ${(camp['name'] ?? camp['id'] ?? '').toString()}',
              ),
            ],
          ],
        ),
      );
    }

    List<Widget> buildActionButtons() {
      final btns = <Widget>[];
      final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
      final btnPad = EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10);
      final labelStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: isCompact ? 11.5 : 12);

      if (!_isSupervisorUser) {
        btns.add(
          SizedBox(
            height: ctrlHeight,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                elevation: 0,
                padding: btnPad,
                shape: shape,
              ),
              onPressed: () async {
                final res = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AddMedicinePage(
                      branchId: _effectiveBranchId,
                      isDispenser: widget.isDispenser,
                      isAdmin: widget.isAdmin,
                    ),
                  ),
                );
                if (res == true) _loadDataFromHive();
              },
              icon: const Icon(GIcons.add, size: 15),
              label: Text('Add Medicines', style: labelStyle),
            ),
          ),
        );
      }

      if (_isDoctorUser && !_canDeleteInventoryItem) {
        btns.add(
          _isRefreshingInventory
              ? Container(
                  height: ctrlHeight,
                  padding: btnPad,
                  decoration: BoxDecoration(
                    color: c.surfaceSunken,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.brand.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: c.brand),
                      ),
                      const SizedBox(width: 6),
                      Text('Refreshing...', style: labelStyle.copyWith(color: c.brand)),
                    ],
                  ),
                )
              : SizedBox(
                  height: ctrlHeight,
                  child: Tooltip(
                    message: 'Fetch latest inventory from server / cloud',
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: c.surfaceSunken,
                        foregroundColor: c.brand,
                        side: BorderSide(color: c.brand.withValues(alpha: 0.45)),
                        padding: btnPad,
                        shape: shape,
                      ),
                      onPressed: () => _refreshInventory(),
                      icon: const Icon(GIcons.refresh, size: 14),
                      label: Text('Refresh', style: labelStyle),
                    ),
                  ),
                ),
        );
      }

      btns.add(
        _isExportingPdf
            ? Container(
                height: ctrlHeight,
                padding: btnPad,
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.brand.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.brand),
                    ),
                    const SizedBox(width: 6),
                    Text('Exporting...', style: labelStyle.copyWith(color: c.brand)),
                  ],
                ),
              )
            : SizedBox(
                height: ctrlHeight,
                child: Tooltip(
                  message: 'Download Inventory Checklist PDF',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: c.surfaceSunken,
                      foregroundColor: c.brand,
                      side: BorderSide(color: c.brand.withValues(alpha: 0.45)),
                      padding: btnPad,
                      shape: shape,
                    ),
                    onPressed: _exportPdf,
                    icon: const Icon(GIcons.download, size: 14),
                    label: Text(isCompact ? 'Inventory PDF' : 'PDF', style: labelStyle),
                  ),
                ),
              ),
      );

      // Non-higher-authority roles with Register permission (e.g. Branch Manager) keep Register
      // Medicine in the regular toolbar; Chairman / HQ Manager / Admin have it in Higher Authority Controls.
      if (_canRegisterMedicine && !_isHigherAuthority) {
        btns.add(
          SizedBox(
            height: ctrlHeight,
            child: ElevatedButton.icon(
              onPressed: () {
                const regIdx = 2;
                if (regIdx < _tabCtrl.length) {
                  _tabCtrl.animateTo(regIdx);
                  setState(() {});
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => InventoryUpdatePage(
                        branchId: _effectiveBranchId,
                        isAdmin: widget.isAdmin,
                        isDispenser: widget.isDispenser,
                        isDoctor: widget.isDoctor,
                        showMode: 2,
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.add_circle_outline_rounded, size: 15),
              label: Text(isCompact ? 'Register Med' : 'Register Medicine', style: labelStyle),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brandStrong,
                foregroundColor: c.onBrand,
                elevation: 0,
                padding: btnPad,
                shape: shape,
              ),
            ),
          ),
        );
      }

      return btns;
    }

    final typeDropdown = buildDropdownChip(
      value: _filterType,
      items: _types,
      icon: GIcons.catalogue,
      onChanged: (val) {
        if (val != null) {
          setState(() {
            _filterType = val;
            _displayLimit = 50;
            _processData();
          });
        }
      },
    );

    final batchDropdown = buildDropdownChip(
      value: _filterBatch,
      items: _batchKeys,
      icon: GIcons.layers,
      onChanged: (val) {
        if (val != null) {
          setState(() {
            _filterBatch = val;
            _displayLimit = 50;
            _processData();
          });
        }
      },
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 7,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: c.border),
      ),
      child: isCompact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: buildSearchField()),
                    const SizedBox(width: 8),
                    typeDropdown,
                  ],
                ),
                const SizedBox(height: 6),
                if (showInlineCampBar) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: buildCampBar(),
                  ),
                  const SizedBox(height: 6),
                ],
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      batchDropdown,
                      const SizedBox(width: 6),
                      _buildMergeFormulaCheckButton(isCompact: true),
                      if (_isHigherAuthority) ...[
                        const SizedBox(width: 6),
                        _buildMissingBarcodeFilterChip(isCompact: true),
                      ],
                      for (final btn in buildActionButtons()) ...[
                        const SizedBox(width: 6),
                        btn,
                      ],
                    ],
                  ),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final actionBtns = buildActionButtons();
                final missingChip = _isHigherAuthority ? _buildMissingBarcodeFilterChip(isCompact: false) : null;
                final hasMissingChip = missingChip != null && missingChip is! SizedBox;
                // Fits on 1 sleek row on desktop (>= 860px) so the medicine table gets maximum screen height.
                if (constraints.maxWidth >= 860 && !showInlineCampBar) {
                  return Row(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 160),
                          child: buildSearchField(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      typeDropdown,
                      const SizedBox(width: 6),
                      batchDropdown,
                      const SizedBox(width: 6),
                      _buildMergeFormulaCheckButton(isCompact: false),
                      if (hasMissingChip) ...[
                        const SizedBox(width: 6),
                        missingChip,
                      ],
                      for (final btn in actionBtns) ...[
                        const SizedBox(width: 6),
                        btn,
                      ],
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 180),
                            child: buildSearchField(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        typeDropdown,
                        const SizedBox(width: 6),
                        batchDropdown,
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _buildMergeFormulaCheckButton(isCompact: false),
                        if (hasMissingChip) missingChip,
                        if (showInlineCampBar) buildCampBar(),
                        ...actionBtns,
                      ],
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildMergeFormulaCheckButton({bool isCompact = false}) {
    final c = context.comfort;
    return Tooltip(
      message: _mergeByFormula
          ? 'Formulas merged: Showing combined quantities of same formula. Click to view normal separated batches.'
          : 'Normal view: Batches separated. Click to check and merge quantities of the same formula.',
      child: InkWell(
        onTap: () {
          setState(() {
            _mergeByFormula = !_mergeByFormula;
            if (_mergeByFormula) {
              _filterBatch = 'All Batches';
            }
            _displayLimit = 50;
            _processData();
          });
        },
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 9),
          decoration: BoxDecoration(
            color: _mergeByFormula ? c.brandSoft : c.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _mergeByFormula ? c.brand : c.border,
              width: _mergeByFormula ? 1.3 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _mergeByFormula ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: _mergeByFormula ? c.brand : c.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                'Merge Formula',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: _mergeByFormula ? FontWeight.w700 : FontWeight.w600,
                  color: _mergeByFormula ? c.brand : c.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _syncInventoryFromCloud() async {
    final effBranch = _effectiveBranchId;
    if (mounted) setState(() => _isRefreshingInventory = true);
    AppToast.showSnackBar(
      context,
      SnackBar(
        content: Text('🔄 Downloading & restoring inventory for ${_getBranchName()} from Firestore...'),
        duration: const Duration(seconds: 2),
      ),
    );
    try {
      if (_isAllBranchesMode) {
        for (final b in _allKnownBranchIds()) {
          await LocalStorageService.downloadInventory(b, forceFull: true);
        }
      } else {
        await LocalStorageService.downloadInventory(effBranch, forceFull: true, campId: _selectedCampFilter);
      }
      if (mounted) {
        _loadDataFromHive();
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text('✅ ${_getBranchName()} synced! Showing ${_groupedBatches.length} records.'),
            backgroundColor: SoftPalette.green400,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshingInventory = false);
    }
  }

  Widget _buildUpdateStockButton() {
    return ElevatedButton.icon(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InventoryUpdatePage(
            branchId: _effectiveBranchId,
            isAdmin: widget.isAdmin,
            isDispenser: widget.isDispenser,
            isDoctor: widget.isDoctor,
          ),
        ),
      ),
      icon: const Icon(Icons.add_rounded, color: SoftPalette.gray50, size: 18),
      label: const Text(
        'Update Stock',
        style: TextStyle(
          color: SoftPalette.gray50,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: _teal,
        foregroundColor: SoftPalette.gray50,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 1,
      ),
    );
  }

  Widget _searchField() {
    return Container(
      decoration: BoxDecoration(
        color: context.adapt(_white),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: _shadow.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: _searchCtrl,
        cursorColor: _teal,
        style: TextStyle(color: context.adapt(_textDark), fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: Icon(Icons.search_rounded, color: _teal, size: 20),
          hintText: 'Search formula or name (Tap row to edit)...',
          hintStyle: TextStyle(color: context.adapt(_textLight), fontSize: 13),
          filled: true,
          fillColor: Colors.transparent,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: context.adapt(SoftPalette.gray100), width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _teal, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onChanged: (_) => setState(() => _page = 0),
      ),
    );
  }

  Widget _buildMetricsRow(List<Map<String, dynamic>> batches, bool isMobile) {
    final c = context.comfort;
    final totalMedicines = batches.length;
    final lowStockCount = batches.where((b) => (b['quantity'] as int) < 10).length;
    final expiringSoonCount = batches.where((b) => _isExpiringSoon(b['expiryDate'] as String?)).length;
    final totalStockQty = batches.fold<int>(0, (acc, b) => acc + (b['quantity'] as int));

    final numberFormat = NumberFormat('#,###');

    final card1 = _buildMetricItem(
      GIcons.medicine,
      c.brand,
      c.brandSoft,
      '$totalMedicines',
      'Formulas',
      onTap: _resetFilters,
    );
    final card2 = _buildMetricItem(
      GIcons.inventory,
      c.info,
      c.infoBg,
      numberFormat.format(totalStockQty),
      'Total Units',
      onTap: _resetFilters,
    );
    final card3 = _buildMetricItem(
      GIcons.lowStock,
      c.danger,
      c.dangerBg,
      '$lowStockCount',
      'Low Stock',
      onTap: _applyLowStockSort,
    );
    final card4 = _buildMetricItem(
      GIcons.overdue,
      c.warning,
      c.warningBg,
      '$expiringSoonCount',
      'Expiring Soon',
      onTap: _applyExpirySort,
    );

    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: card1),
                const SizedBox(width: 8),
                Expanded(child: card2),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: card3),
                const SizedBox(width: 8),
                Expanded(child: card4),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          Expanded(child: card1),
          const SizedBox(width: 8),
          Expanded(child: card2),
          const SizedBox(width: 8),
          Expanded(child: card3),
          const SizedBox(width: 8),
          Expanded(child: card4),
        ],
      ),
    );
  }

  Widget _buildMetricItem(
    IconData icon,
    Color accentColor,
    Color bgTint,
    String value,
    String label, {
    VoidCallback? onTap,
  }) {
    final c = context.comfort;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: bgTint,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: accentColor, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
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
      ),
    );
  }

  Widget _filterDropdown(
      String value, List<String> items, ValueChanged<String?> onChange,
      {String Function(String)? display, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: context.adapt(_white),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.adapt(SoftPalette.gray100), width: 1),
        boxShadow: [
          BoxShadow(
            color: _shadow.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: _teal, size: 16),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: context.adapt(_white),
              style: TextStyle(color: context.adapt(_textDark), fontSize: 13.5, fontWeight: FontWeight.w500),
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: context.adapt(_textMid), size: 20),
              items: items
                  .map((t) => DropdownMenuItem<String>(
                      value: t,
                      child: Text(display != null ? display(t) : t,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: context.adapt(_textDark), fontSize: 13.5))))
                  .toList(),
              onChanged: onChange,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _requestRestock(Map<String, dynamic> b) async {
    final name = (b['name'] ?? 'Medicine').toString();
    final qty = _asInt(b['quantity']);
    final noteCtrl = TextEditingController();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.notification_important_rounded, color: SoftPalette.orange400),
            SizedBox(width: 8),
            Text('Request Restock', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Alert the dispensary that this medicine needs to be restocked:'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _isDark ? SoftPalette.slate700 : SoftPalette.slate150),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: qty < 10 ? SoftPalette.red400.withValues(alpha: 0.15) : SoftPalette.amber200.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Qty: $qty',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: qty < 10 ? SoftPalette.red400 : SoftPalette.orange350,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Optional Note / Target Qty',
                hintText: 'e.g. Need 50 more tablets',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.orange400,
              foregroundColor: SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Send Alert to Dispensary', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    String doctorName = 'Doctor';
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          doctorName = (uData['name'] ?? uData['username'] ?? 'Doctor').toString();
        }
      }
    } catch (_) {}

    final reqId = 'restock_${DateTime.now().millisecondsSinceEpoch}_${name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';
    final reqData = {
      'id': reqId,
      'medicineName': name,
      'currentQty': qty,
      'requestedBy': doctorName,
      'notes': noteCtrl.text.trim(),
      'status': 'pending',
      'createdAt': DateTime.now().toIso8601String(),
      'timestamp': DateTime.now().toIso8601String(),
      'branchId': widget.branchId,
    };

    // 1. Save locally in Hive so it is immediately persisted and available offline
    await LocalStorageService.saveRestockRequest(widget.branchId, reqData);

    final payload = RealtimeEvents.payload(
      type: RealtimeEvents.restockRequest,
      branchId: widget.branchId,
      data: reqData,
    );

    // 2. Realtime broadcast
    RealtimeManager().sendMessage(payload);

    // 3. Persistent cloud & offline sync storage. Always through the upload queue: the
    // un-awaited direct write never reached its catch on Windows (an unanswered write
    // neither completes nor fails), so the request only sat in the SDK's hidden queue.
    unawaited(LocalStorageService.enqueueSync({
      'type': 'save_restock_request',
      'branchId': widget.branchId,
      'id': reqId,
      'data': reqData,
    }));

    if (mounted) {
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: SoftPalette.gray50, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('Restock alert sent & persisted for $name!')),
            ],
          ),
          backgroundColor: SoftPalette.teal600,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// "Gujrat" / "Karachi — Haji Camp" for the pool(s) a grouped row comes from.
  String _poolsLabel(Map<String, dynamic> b) {
    final keys = <String>{
      for (final p in (b['_docPools'] as List? ?? const [])) p.toString(),
    }..removeWhere((k) => k.isEmpty);
    if (keys.isEmpty) return '—';
    final labels = <String>[];
    for (final k in keys) {
      final pool = StockPool.fromKey(k);
      if (pool == null) {
        labels.add(k);
        continue;
      }
      final branchName = LocalStorageService.getBranchName(pool.branch);
      labels.add(pool.camp == null
          ? branchName
          : '$branchName — ${CampSessionService.getCampLabel(pool.camp!, pool.branch)}');
    }
    return labels.join(', ');
  }

  // ── Stock Table (wide screens) ─────────────────────────────────────────────
  Widget _stockTable(
      List<Map<String, dynamic>> data, double screenWidth, int totalCount, [double? availableHeight]) {
    final c = context.comfort;
    // In "All Branches" every row needs its branch/camp shown, and removing is blocked
    // (a delete there could land in a pool the user cannot tell apart).
    final showBranchCol = _isAllBranchesMode;
    final hasDeleteAction = _canDeleteInventoryItem && !_isSelectMode && !showBranchCol;
    final hasDoctorAction = !hasDeleteAction && _isDoctorUser && !_isSelectMode;
    final hasActionCol = hasDeleteAction || hasDoctorAction;

    final double cardInnerWidth = screenWidth - 26;
    final double minTableWidth = (hasDoctorAction ? 820 : 760) + (showBranchCol ? 150 : 0);
    final double w = cardInnerWidth < minTableWidth ? minTableWidth : cardInnerWidth;

    const double numW = 46;
    const double barcodeW = 116;
    const double typeW = 118;
    const double doseW = 88;
    const double qtyW = 86;
    const double expW = 112;
    final double branchW = showBranchCol ? 150 : 0;
    final double actionW = hasDeleteAction ? 54 : (hasDoctorAction ? 116 : 0);
    final double nameW =
        (w - numW - barcodeW - typeW - doseW - qtyW - expW - branchW - actionW).clamp(180, double.infinity);

    final cols = [
      const _Col('#', numW, null),
      _Col('Medicine / Formula', nameW, 'name'),
      const _Col('Barcode', barcodeW, null),
      const _Col('Type', typeW, null),
      const _Col('Dose', doseW, 'dose'),
      const _Col('Qty', qtyW, 'quantity', alignEnd: true),
      const _Col('Expiry', expW, 'expiry'),
      if (showBranchCol) _Col('Branch / Camp', branchW, null),
      if (hasActionCol) _Col('', actionW, null, alignEnd: true),
    ];

    Widget buildTableRow(int i) {
      if (i == data.length) {
        return Container(
          width: w,
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          color: c.surface,
          child: Text(
            data.length >= totalCount
                ? 'Showing all $totalCount medicines'
                : 'Loading more...',
            style: TextStyle(color: c.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        );
      }
      final b = data[i];
      final batchKey = (b['batchKey'] ?? b['id'] ?? b['name'] ?? '$i').toString();
      final isSelected = _selectedBatchKeys.contains(batchKey);
      final qty = b['quantity'] as int;
      final type = (b['type'] ?? '').toString().trim();
      final rawName = (b['name'] ?? '').toString().trim();
      final rawFormula = (b['formula'] ?? '').toString().trim();
      final showFormulaSubtitle =
          rawFormula.isNotEmpty && rawFormula.toLowerCase() != rawName.toLowerCase();
      final barcode = (b['barcode'] ?? b['rollNo'] ?? '').toString().trim();
      final itemCode = (b['code'] ?? b['itemCode'] ?? '').toString().trim();
      final packBarcode = (b['packBarcode'] ?? '').toString().trim();
      final doseText = (b['dose'] ?? '').toString().trim();
      final lowStock = qty < 10;
      final expSoon = _isExpiringSoon(b['expiryDate'] as String?);
      final expText = _formatDate(b['expiryDate'] as String?);
      final isWarning = lowStock || expSoon;
      final statusDotColor = lowStock ? c.danger : (expSoon ? c.warning : c.brand);

      final baseBg = isSelected
          ? c.dangerBg
          : (isWarning
              ? c.dangerBg.withValues(alpha: _isDark ? 0.18 : 0.32)
              : (i.isEven ? c.surface : c.surfaceSunken.withValues(alpha: 0.35)));
      final hoverBg = isSelected
          ? c.dangerBg
          : (isWarning
              ? c.dangerBg.withValues(alpha: _isDark ? 0.30 : 0.50)
              : c.surfaceSunken.withValues(alpha: 0.72));

      void Function()? handleTap;
      if (_isSelectMode) {
        handleTap = () => _toggleSelectItem(batchKey);
      } else if (_isDoctorUser) {
        handleTap = () => _requestRestock(b);
      } else if (_isDirectEditAllowed) {
        handleTap = () => _showEditSheet(b);
      } else {
        handleTap = () {
          if (widget.isDispenser && mounted) {
            AppToast.showSnackBar(
              context,
              SnackBar(
                content: const Text(
                  '💡 Dispensers must use "Update Stock" to submit medicine changes for Supervisor approval.',
                  style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold),
                ),
                backgroundColor: c.brand,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        };
      }

      return _InventoryHoverRow(
        baseColor: baseBg,
        hoverColor: hoverBg,
        borderColor: isSelected
            ? c.danger
            : (isWarning ? c.danger.withValues(alpha: 0.22) : c.border.withValues(alpha: 0.75)),
        borderWidth: isSelected ? 1.5 : 1.0,
        onTap: handleTap,
        builder: (rowHovered) => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _dCell(
              cols[0].w,
              _isSelectMode
                  ? Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: isSelected,
                          activeColor: c.danger,
                          onChanged: (_) => _toggleSelectItem(batchKey),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: c.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
            ),
            _dCell(
              cols[1].w,
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 9),
                    decoration: BoxDecoration(
                      color: rawName.isEmpty ? c.warning : statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: rawName.isEmpty
                        ? Row(
                            children: [
                              Text(
                                '(Unnamed Medicine)',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w600,
                                  color: c.textMuted,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: c.warningBg,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  'Blank Record',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c.warning),
                                ),
                              ),
                            ],
                          )
                        : RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: TextStyle(fontSize: 13, color: c.textPrimary),
                              children: [
                                TextSpan(
                                  text: rawName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: isWarning ? c.danger : c.textPrimary,
                                  ),
                                ),
                                if (showFormulaSubtitle) ...[
                                  const TextSpan(text: '  '),
                                  TextSpan(
                                    text: rawFormula,
                                    style: TextStyle(
                                      color: isWarning ? c.danger.withValues(alpha: 0.78) : c.textMuted,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
            _dCell(cols[2].w, _barcodeCell(barcode, itemCode: itemCode, packBarcode: packBarcode)),
            _dCell(cols[3].w, _typePill(type)),
            _dCell(
              cols[4].w,
              Text(
                doseText.isEmpty ? '—' : doseText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: doseText.isEmpty ? c.textMuted : c.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            _dCell(
              cols[5].w,
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: lowStock ? 8 : 4, vertical: lowStock ? 2.5 : 1),
                      decoration: lowStock
                          ? BoxDecoration(
                              color: c.dangerBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: c.danger.withValues(alpha: 0.3)),
                            )
                          : null,
                      child: Text(
                        NumberFormat('#,###').format(qty),
                        style: TextStyle(
                          color: lowStock ? c.danger : c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    if (_mergeByFormula && (b['_mergedCount'] as int? ?? 1) > 1) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.brandSoft,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: c.brand.withValues(alpha: 0.35), width: 0.8),
                        ),
                        child: Text(
                          'Merged',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: c.brandStrong,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _dCell(
              cols[6].w,
              Text(
                b['hasMultipleExpiries'] == true ? '$expText (Earliest)' : expText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: expText == '—' ? c.textMuted : (expSoon ? c.danger : c.textSecondary),
                  fontWeight: expSoon ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 12.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (showBranchCol)
              _dCell(
                branchW,
                Text(
                  _poolsLabel(b),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            if (hasDeleteAction)
              _dCell(
                actionW,
                Center(
                  child: _InventoryRowDeleteButton(
                    rowHovered: rowHovered,
                    onTap: () => _showDeleteInventoryDialog(b),
                  ),
                ),
              )
            else if (hasDoctorAction)
              _dCell(
                actionW,
                Align(
                  alignment: Alignment.centerRight,
                  child: Tooltip(
                    message: 'Request restock from Dispensary',
                    child: InkWell(
                      onTap: () => _requestRestock(b),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.warningBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: c.warning.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(GIcons.notifications, size: 13, color: c.warning),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Restock',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.warning,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: _isDark ? 0.16 : 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final tableContent = Column(
            children: [
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  border: Border(bottom: BorderSide(color: c.borderStrong)),
                ),
                child: Row(
                    children: cols.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final col = entry.value;
                      if (idx == 0 && _isSelectMode) {
                        return Container(
                          width: col.w,
                          height: 36,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: Checkbox(
                              value: _allFilteredSelected,
                              tristate: _selectedBatchKeys.isNotEmpty && !_allFilteredSelected,
                              activeColor: c.brand,
                              checkColor: c.onBrand,
                              side: BorderSide(color: c.textSecondary, width: 1.5),
                              onChanged: (_) => _toggleSelectAll(),
                            ),
                          ),
                        );
                      }
                      return _hCell(col.w, col.label, col.sort, alignEnd: col.alignEnd, centered: idx == 0);
                    }).toList()),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.zero,
                  itemCount: data.length + 1,
                  itemBuilder: (ctx, i) => buildTableRow(i),
                ),
              ),
            ],
          );

          if (w > constraints.maxWidth) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                width: w,
                height: constraints.maxHeight,
                child: tableContent,
              ),
            );
          }

          return tableContent;
        },
      ),
    );
  }

  // ── Stock Cards (narrow screens) ──────────────────────────────────────────
  Widget _stockCards(List<Map<String, dynamic>> data, int totalCount) =>
      ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        itemCount: data.length + 1,
        itemBuilder: (ctx, i) {
          final c = ctx.comfort;
          if (i == data.length) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              child: Text(
                data.length >= totalCount
                    ? 'Showing all $totalCount medicines'
                    : 'Loading more...',
                style: TextStyle(color: c.textMuted, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            );
          }
          final b = data[i];
          final batchKey = (b['batchKey'] ?? b['id'] ?? b['name'] ?? '$i').toString();
          final isSelected = _selectedBatchKeys.contains(batchKey);
          final qty = _asInt(b['quantity']);
          final type = b['type']?.toString() ?? '';
          final price = _parsePrice(b['price']);
          final barcode = (b['barcode'] ?? b['rollNo'] ?? '').toString().trim();
          final packBarcode = (b['packBarcode'] ?? '').toString().trim();
          final lowStock = qty < 10;
          final expSoon = _isExpiringSoon(b['expiryDate']?.toString());
          final expText = _formatDate(b['expiryDate']?.toString());

          final isWarning = lowStock || expSoon;

          final card = Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isSelected
                  ? c.dangerBg
                  : (isWarning ? c.dangerBg.withValues(alpha: 0.35) : c.surface),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? c.danger
                    : (isWarning ? c.danger.withValues(alpha: 0.45) : c.border),
                width: isSelected ? 1.6 : 1.0,
              ),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (_isSelectMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: isSelected,
                            activeColor: c.danger,
                            onChanged: (_) => _toggleSelectItem(batchKey),
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: isWarning ? c.dangerBg : c.brandSoft,
                          borderRadius: BorderRadius.circular(8)),
                      child: _typeIconWidget(type,
                          size: 13,
                          color: isWarning ? c.danger : c.brand),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${i + 1}. ${b['name']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: isWarning ? c.danger : c.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5),
                        ),
                      ],
                    )),
                    if (_canDeleteInventoryItem && !_isSelectMode)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: _InventoryRowDeleteButton(
                          rowHovered: true,
                          onTap: () => _showDeleteInventoryDialog(b),
                        ),
                      )
                    else if (_isDoctorUser && !_isSelectMode)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(
                          message: 'Request restock from Dispensary',
                          child: InkWell(
                            onTap: () => _requestRestock(b),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: c.warningBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: c.warning.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.notification_important_rounded, size: 13, color: c.warning),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Restock',
                                    style: TextStyle(
                                      color: c.warning,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (!_isSelectMode)
                      _qtyBadge(qty, lowStock),
                    if (_canDeleteInventoryItem && !_isSelectMode) ...[
                      const SizedBox(width: 8),
                      _qtyBadge(qty, lowStock),
                    ] else if (_isDoctorUser && !_isSelectMode) ...[
                      const SizedBox(width: 8),
                      _qtyBadge(qty, lowStock),
                    ] else if (_isSelectMode) ...[
                      const SizedBox(width: 8),
                      _qtyBadge(qty, lowStock),
                    ],
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    _typePill(type),
                    if ((b['dose'] ?? '').toString().isNotEmpty)
                      _infoBadge(b['dose'].toString(), c.textSecondary),
                    if (barcode.isNotEmpty)
                      _infoBadge(barcode, c.brandStrong, icon: Icons.qr_code_rounded),
                    if (packBarcode.isNotEmpty)
                      _infoBadge(packBarcode, c.brand, icon: Icons.qr_code_scanner_rounded),
                    _priceBadge(price),
                    _expBadge(b['hasMultipleExpiries'] == true ? '$expText (Earliest)' : expText, expSoon),
                    if (_mergeByFormula && (b['_mergedCount'] as int? ?? 1) > 1)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.brandSoft,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: c.brand.withValues(alpha: 0.35), width: 0.8),
                        ),
                        child: Text(
                          'Merged (${b['_mergedCount']} batches)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: c.brandStrong,
                          ),
                        ),
                      ),
                    if (lowStock || expSoon)
                      _statusLabel(lowStock: lowStock, expSoon: expSoon),
                  ]),
                ]),
          );

          void Function()? handleCardTap;
          if (_isSelectMode) {
            handleCardTap = () => _toggleSelectItem(batchKey);
          } else if (_isDoctorUser) {
            handleCardTap = () { _requestRestock(b); };
          } else if (_isDirectEditAllowed) {
            handleCardTap = () { _showEditSheet(b); };
          } else {
            handleCardTap = () {
              if (widget.isDispenser && mounted) {
                AppToast.showSnackBar(context,
                  SnackBar(
                    content: const Text(
                      '💡 Dispensers must use "Update Stock" to submit medicine changes for Supervisor approval.',
                      style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold),
                    ),
                    backgroundColor: c.brand,
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            };
          }

          return GestureDetector(
            onTap: handleCardTap,
            child: card,
          );
        },
      );

  // Small pill showing the 3-digit Proforma barcode (and optional packBarcode)
  Widget _barcodeCell(String barcode, {String itemCode = '', String packBarcode = ''}) {
    final c = context.comfort;
    if (barcode.isEmpty && packBarcode.isEmpty) {
      if (_isHigherAuthority) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: c.warningBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.warning.withValues(alpha: 0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(GIcons.warning, size: 11, color: c.warning),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Missing',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.warning, fontSize: 10.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
      }
      return Text('—', style: TextStyle(color: c.textMuted, fontSize: 12.5));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (barcode.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.brandSoft,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.brand.withValues(alpha: 0.28)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(GIcons.qr, size: 12, color: c.brandStrong),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  barcode,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.brandStrong,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ]),
          ),
        if (packBarcode.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            'Pack: $packBarcode',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textSecondary, fontSize: 9.5, fontWeight: FontWeight.w500),
          ),
        ],
      ],
    );
  }

  void _showEditSheet(Map<String, dynamic> batchData) {
    if (!_isDirectEditAllowed) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('🔒 Direct editing is restricted for Dispensers. Use "Update Stock" for Supervisor approval.'),
            backgroundColor: SoftPalette.amber300,
          ),
        );
      }
      return;
    }
    final refs = _batchRefs(batchData);
    if (refs.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditMedicineSheet(
        branchId: _effectiveBranchId,
        docIds: [for (final r in refs) r.$2],
        docPools: [for (final r in refs) r.$1],
        initial: batchData,
        medicineTypes: _types.where((t) => t != 'All').toList(),
        formatDate: _formatDate,
        isAdmin: widget.isAdmin,
        isDoctor: widget.isDoctor,
        isDispenser: widget.isDispenser,
      ),
    );
  }



  Future<QuerySnapshot?> _fetchEditRequests(String status) async {
    try {
      return await FirebaseFirestore.instance
          .collection('branches')
          .doc(_effectiveBranchId)
          .collection('edit_requests')
          .where('status', isEqualTo: status)
          .get(const GetOptions(source: Source.serverAndCache));
    } catch (_) {
      return null;
    }
  }

  // ── Pending Tab ───────────────────────────────────────────────────────────
  Widget _pendingTab() => FutureBuilder<QuerySnapshot?>(
        future: _fetchEditRequests('pending'),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
                child: CircularProgressIndicator(color: _teal));
          }
          var docs = snap.data?.docs ?? [];

          docs = docs.where((d) {
            final t =
                (d.data() as Map<String, dynamic>)['requestType']?.toString() ??
                    '';
            return _editRequestTypes.contains(t);
          }).toList();

          if (docs.isEmpty) {
            return _emptyState(
              Icons.pending_actions_rounded,
              'No pending edit requests',
              illustration: GEmptyIllustrationKind.requests,
              subtitle: 'All caught up. New stock edit requests will appear here for review.',
            );
          }

          docs.sort((a, b) {
            final ta = (a.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            final tb = (b.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            if (ta == null && tb == null) return 0;
            if (ta == null) return 1;
            if (tb == null) return -1;
            return tb.compareTo(ta);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) => _requestCard(
                docs[i].id,
                docs[i].data() as Map<String, dynamic>,
                'pending'),
          );
        },
      );

  // ── Log Tab (activity log of this branch, same on every PC) ───────────────
  String _logFilter = 'all';
  String _logQuery = '';

  static const _logFilters = <(String, String)>[
    ('all', 'All'),
    ('added', 'Added'),
    ('removed', 'Removed'),
    ('edited', 'Edits'),
    ('counted', 'Counts'),
    ('dispensed', 'Dispensed'),
    ('requests', 'Requests'),
  ];

  /// Which filter group an action belongs to.
  static String _logGroup(String action) {
    final a = action.toLowerCase();
    if (a.contains('request')) return 'requests';
    if (a.contains('dispens')) return 'dispensed';
    if (a.contains('remove') || a.contains('wipe') || a.contains('delete') || a.contains('unbarcoded')) return 'removed';
    if (a.contains('count')) return 'counted';
    if (a.contains('edit') || a.contains('expiry') || a.contains('rename') || a.contains('update_details')) return 'edited';
    if (a.contains('add') || a.contains('restock') || a.contains('regist') || a.contains('batch') || a.contains('proforma') || a.contains('stock')) return 'added';
    return 'edited';
  }

  static DateTime? _logTime(Map<String, dynamic> e) {
    final raw = e['createdAt'] ?? e['timestamp'] ?? e['savedAt'];
    if (raw is DateTime) return raw;
    if (raw is Timestamp) return raw.toDate();
    return DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
  }

  static double? _logNum(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  Widget _logTab() => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _logState.stream,
        builder: (context, snap) {
          final c = context.comfort;
          if (!snap.hasData) {
            return Center(child: CircularProgressIndicator(color: _teal));
          }
          final all = snap.data!;
          final q = _logQuery.trim().toLowerCase();
          final list = all.where((e) {
            if (_logFilter != 'all' && _logGroup((e['action'] ?? '').toString()) != _logFilter) return false;
            if (q.isEmpty) return true;
            return '${e['medicineName'] ?? ''} ${e['performedByName'] ?? ''} ${e['reason'] ?? ''} ${e['serial'] ?? ''}'
                .toLowerCase()
                .contains(q);
          }).toList()
            ..sort((a, b) => (_logTime(b) ?? DateTime(2000)).compareTo(_logTime(a) ?? DateTime(2000)));

          final toolbar = Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      onChanged: (v) => setState(() => _logQuery = v),
                      decoration: InputDecoration(
                        hintText: 'Search medicine, person, reason or token',
                        prefixIcon: Icon(GIcons.search, size: 18, color: c.textMuted),
                        isDense: true,
                        filled: true,
                        fillColor: c.surface,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.border)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('${list.length} of ${all.length}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textMuted)),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final (key, label) in _logFilters)
                  ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: _logFilter == key,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _logFilter = key),
                  ),
              ]),
            ]),
          );

          if (list.isEmpty) {
            return Column(children: [
              toolbar,
              Expanded(
                child: _emptyState(
                  Icons.history_edu_rounded,
                  all.isEmpty
                      ? 'No activity yet.\nStock updates will appear here.'
                      : 'Nothing matches this filter.',
                  illustration: all.isEmpty ? GEmptyIllustrationKind.activity : GEmptyIllustrationKind.search,
                ),
              ),
            ]);
          }

          // Day headers between entries.
          final rows = <Widget>[];
          String? lastDay;
          for (final e in list) {
            final t = _logTime(e);
            final day = t == null ? 'Unknown date' : DateFormat('EEEE, d MMM yyyy').format(t);
            if (day != lastDay) {
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
                child: Text(day, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.textSecondary)),
              ));
              lastDay = day;
            }
            rows.add(_logCard(e));
          }
          return Column(children: [
            toolbar,
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), children: rows),
            ),
          ]);
        },
      );

  Widget _logCard(Map<String, dynamic> data) {
    final c = context.comfort;
    final action = (data['action'] ?? '').toString();
    final group = _logGroup(action);
    final medicineName = (data['medicineName'] ?? data['name'] ?? '—').toString();
    final medicineType = (data['medicineType'] ?? data['type'] ?? '').toString();
    final dose = (data['dose'] ?? '').toString();
    final performedBy = (data['performedByName'] ?? data['createdByName'] ?? 'Unknown').toString();
    final reason = (data['reason'] ?? '').toString().trim();
    final t = _logTime(data);

    final (Color fg, Color bg, IconData icon, String label) = switch (group) {
      'added' => (c.success, c.successBg, GIcons.add, action.contains('regist') ? 'NEW MEDICINE' : 'STOCK ADDED'),
      'removed' => (c.danger, c.dangerBg, GIcons.delete, action.contains('wipe') ? 'INVENTORY WIPED' : 'REMOVED'),
      'counted' => (c.warning, c.warningBg, GIcons.inventory, 'STOCK COUNTED'),
      'dispensed' => (c.brand, c.brandSoft, GIcons.medicine, 'DISPENSED'),
      'requests' => (
          action.contains('reject') ? c.danger : (action.contains('approv') ? c.success : c.info),
          action.contains('reject') ? c.dangerBg : (action.contains('approv') ? c.successBg : c.infoBg),
          GIcons.send,
          action.contains('reject')
              ? 'REQUEST REJECTED'
              : (action.contains('approv') ? 'REQUEST APPROVED' : 'EDIT REQUESTED'),
        ),
      _ => (c.info, c.infoBg, GIcons.edit, 'EDITED'),
    };

    // Quantity line: "+50", "−12", or "120 → 100".
    String? qtyText;
    final before = _logNum(data['quantityBefore']);
    final after = _logNum(data['quantityAfter']);
    final added = _logNum(data['quantityAdded']);
    final removedQ = _logNum(data['quantityRemoved']);
    String f(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    if (before != null && after != null && before != after) {
      qtyText = '${f(before)} → ${f(after)}';
    } else if (added != null && added > 0) {
      qtyText = '+${f(added)}';
    } else if (removedQ != null && removedQ > 0) {
      qtyText = '−${f(removedQ)}';
    }
    final expBefore = (data['expiryBefore'] ?? '').toString().trim();
    final exp = (data['expiryDate'] ?? '').toString().trim();
    final expText = expBefore.isNotEmpty && exp.isNotEmpty && expBefore != exp
        ? 'Exp ${_formatDate(expBefore)} → ${_formatDate(exp)}'
        : (exp.isNotEmpty && group == 'added' ? 'Exp ${_formatDate(exp)}' : null);
    final serial = (data['serial'] ?? '').toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: fg, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                child: Text(label, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w800)),
              ),
              const Spacer(),
              if (t != null)
                Text(DateFormat('hh:mm a').format(t), style: TextStyle(color: c.textMuted, fontSize: 11.5)),
            ]),
            const SizedBox(height: 6),
            Text(medicineName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 5, children: [
              if (qtyText != null) _miniChip(qtyText, fg),
              if (medicineType.isNotEmpty) _miniChip(medicineType, c.brandStrong),
              if (dose.isNotEmpty) _miniChip(dose, c.textSecondary),
              if (expText != null) _miniChip(expText, c.textSecondary),
              if (serial.isNotEmpty) _miniChip('Token $serial', c.textSecondary),
            ]),
            if (reason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Reason: $reason', style: TextStyle(fontSize: 12, color: c.textSecondary)),
            ],
            const SizedBox(height: 6),
            Row(children: [
              Icon(GIcons.profile, size: 13, color: c.textMuted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(performedBy,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }


  // ── History Tab ───────────────────────────────────────────────────────────
  Widget _historyTab() {
    final c = context.comfort;
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: TabBar(
            indicator: BoxDecoration(
              color: c.brand,
              borderRadius: BorderRadius.circular(8),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: c.onBrand,
            unselectedLabelColor: c.textSecondary,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            dividerColor: Colors.transparent,
            isScrollable: false,
            tabs: const [
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Approved'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cancel_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Rejected'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
            child: TabBarView(children: [
          _historyList('approved'),
          _historyList('rejected')
        ])),
      ]),
    );
  }

  Widget _historyList(String status) => FutureBuilder<QuerySnapshot?>(
        future: _fetchEditRequests(status),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
                child: CircularProgressIndicator(color: _teal));
          }
          var docs = snap.data?.docs ?? [];

          docs = docs.where((d) {
            final t =
                (d.data() as Map<String, dynamic>)['requestType']?.toString() ??
                    '';
            return _editRequestTypes.contains(t);
          }).toList();

          if (docs.isEmpty) {
            return _emptyState(
              status == 'approved'
                  ? Icons.check_circle_outline
                  : Icons.cancel_outlined,
              'No $status edit requests',
              illustration: GEmptyIllustrationKind.requests,
              subtitle: status == 'approved'
                  ? 'Approved stock edit requests will be archived here.'
                  : 'Rejected stock edit requests will be listed here.',
            );
          }

          docs.sort((a, b) {
            final ta = (a.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            final tb = (b.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            if (ta == null && tb == null) return 0;
            if (ta == null) return 1;
            if (tb == null) return -1;
            return tb.compareTo(ta);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) => _requestCard(
                docs[i].id,
                docs[i].data() as Map<String, dynamic>,
                status),
          );
        },
      );

  String _resolveCampLabel(Map<String, dynamic> data) {
    String? rawCamp = data['campName']?.toString() ??
        data['campLabel']?.toString() ??
        data['campId']?.toString() ??
        data['dispensaryId']?.toString() ??
        data['camp']?.toString();

    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final items = data['items'] ?? data['draftItems'];
      if (items is List && items.isNotEmpty && items.first is Map) {
        rawCamp = items.first['campId']?.toString() ??
            items.first['dispensaryId']?.toString() ??
            items.first['campName']?.toString();
      }
    }

    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final orig = data['originalData'];
      if (orig is Map) {
        rawCamp = orig['campId']?.toString() ??
            orig['dispensaryId']?.toString() ??
            orig['campName']?.toString();
      }
    }

    if (rawCamp == null || rawCamp.isEmpty || rawCamp == 'all') {
      final docId = (data['docId'] ?? data['id'] ?? '').toString().toLowerCase();
      if (docId.contains('saddar') || docId.contains('sadd') || docId.contains('kapay')) {
        rawCamp = 'saddar';
      } else if (docId.contains('haji')) {
        rawCamp = 'haji_camp';
      }
    }

    if (rawCamp != null && rawCamp.isNotEmpty && rawCamp != 'all') {
      if (rawCamp.toLowerCase().contains('kapay')) {
        rawCamp = 'saddar';
      }
      return CampSessionService.getCampLabel(rawCamp);
    }

    final isKarachi = CampSessionService.isKarachiFamily(_effectiveBranchId);
    return (_selectedCampFilter != null && _selectedCampFilter != 'all')
        ? CampSessionService.getCampLabel(_selectedCampFilter!, _effectiveBranchId)
        : (isKarachi ? 'Saddar Camp' : 'Main Facility');
  }

  Widget _requestCard(
      String docId, Map<String, dynamic> data, String status) {
    final c = context.comfort;
    final requestType = data['requestType']?.toString() ?? '';
    final reason = data['reason']?.toString() ?? '';
    final ts = data['requestedAt'] as Timestamp?;
    final cachedName =
        (data['requesterName']?.toString() ?? '').trim();
    final requesterId =
        (data['requestedBy']?.toString() ??
                data['requester']?.toString() ??
                '')
            .trim();

    final Future<String> nameFuture = cachedName.isNotEmpty
        ? Future.value(cachedName)
        : requesterId.isEmpty
            ? Future.value('Unknown')
            : FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('users')
                .doc(requesterId)
                .get()
                .then((s) =>
                    s.data()?['username']?.toString() ?? 'User')
                .timeout(const Duration(seconds: 5),
                    onTimeout: () => 'User')
                .catchError((_) => 'User');

    Color badgeBg = switch (requestType) {
      'edit_medicine' => c.infoBg,
      'delete_medicine' => c.dangerBg,
      _ => c.surfaceSunken,
    };
    Color badgeFg = switch (requestType) {
      'edit_medicine' => c.info,
      'delete_medicine' => c.danger,
      _ => c.textSecondary,
    };
    String typeLabel = switch (requestType) {
      'edit_medicine' => 'EDIT MEDICINE',
      'delete_medicine' => 'DELETE MEDICINE',
      _ => requestType.replaceAll('_', ' ').toUpperCase(),
    };

    final rawItems = status == 'pending'
        ? (data['draftItems'] as List?) ?? (data['items'] as List?) ?? []
        : (data['items'] as List?) ?? [];
    final items = rawItems.cast<Map<String, dynamic>>();

    final campLabel = _resolveCampLabel(data);

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                switch (requestType) {
                  'edit_medicine' => 'Edit Medicine Request',
                  'delete_medicine' => 'Delete Medicine Request',
                  _ => 'Inventory Request',
                },
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: c.brandSoft,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.brand.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.holiday_village_rounded, size: 13, color: c.brandStrong),
                  const SizedBox(width: 4),
                  Text(
                    campLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: c.brandStrong,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(20)),
              child: Text(typeLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: badgeFg)),
            ),
          ]),
          const SizedBox(height: 10),
          FutureBuilder<String>(
            future: nameFuture,
            builder: (_, snap) => Row(children: [
              Icon(Icons.person_rounded, size: 15, color: c.brand),
              const SizedBox(width: 6),
              Text('By: ${snap.data ?? '…'}',
                  style:
                      TextStyle(fontSize: 13, color: c.textPrimary)),
            ]),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.location_on_rounded, size: 14, color: c.brand),
            const SizedBox(width: 6),
            Text(
              'Facility Camp: $campLabel',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: c.brandStrong,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          if (ts != null)
            Row(children: [
              Icon(Icons.access_time_rounded,
                  size: 14, color: c.textMuted),
              const SizedBox(width: 6),
              Text(
                DateFormat('dd MMM yyyy, hh:mm a')
                    .format(ts.toDate()),
                style:
                    TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ]),
          const SizedBox(height: 12),
          if (requestType == 'edit_medicine')
            _buildMedicineEditComparison(data)
          else if (items.isNotEmpty)
            _buildItemsList(items),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.comment_rounded,
                      size: 14, color: c.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Reason: $reason',
                          style: TextStyle(
                              fontSize: 13, color: c.textPrimary))),
                ],
              ),
            ),
          ],
          if (status != 'pending') ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: status == 'approved' ? c.successBg : c.dangerBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (status == 'approved' ? c.success : c.danger).withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      status == 'approved'
                          ? Icons.verified_user_rounded
                          : Icons.gavel_rounded,
                      size: 14,
                      color: status == 'approved' ? c.success : c.danger,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      status == 'approved' ? 'Approved by:' : 'Rejected by:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: status == 'approved' ? c.success : c.danger,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        data['reviewedByName']?.toString() ?? '—',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: status == 'approved' ? c.success : c.danger,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                  if (data['reviewedAt'] != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.access_time_rounded,
                          size: 12, color: c.textMuted),
                      const SizedBox(width: 5),
                      Text(
                        DateFormat('dd MMM yyyy, hh:mm a').format(
                            (data['reviewedAt'] as Timestamp).toDate()),
                        style: TextStyle(
                            fontSize: 11, color: c.textSecondary),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _handleApproval(
      String docId, Map<String, dynamic> data, String newStatus) async {
    final db = FirebaseFirestore.instance;
    final branchRef = db.collection('branches').doc(widget.branchId);
    final reqRef =
        branchRef.collection('edit_requests').doc(docId);

    try {
      String? reviewerName;
      final reviewerUid = FirebaseAuth.instance.currentUser?.uid;
      if (reviewerUid != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('users')
            .doc(reviewerUid)
            .get();
        reviewerName = userDoc.data()?['username']?.toString();
      }

      await reqRef.update({
        'status': newStatus,
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': reviewerUid,
        if (reviewerName != null) 'reviewedByName': reviewerName,
      });

      if (newStatus == 'approved') {
        final requestType = data['requestType']?.toString() ?? '';

        if (requestType == 'edit_medicine') {
          final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
              ? _safeItemList(data['draftItems'])
              : _safeItemList(data['items']);

          if (itemsToUse.isNotEmpty) {
            await _applyEditMedicine(
                branchRef, data, itemsToUse, reviewerUid, reviewerName,
                requestId: docId);
          }
        } else if (requestType == 'delete_medicine') {
          final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
              ? _safeItemList(data['draftItems'])
              : _safeItemList(data['items']);
          await _applyDeleteMedicine(data, itemsToUse);
        } else if (requestType == 'register_medicine') {
          final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
              ? _safeItemList(data['draftItems'])
              : _safeItemList(data['items']);
          if (itemsToUse.isNotEmpty) {
            // Stock book: a new batch in the request's pool with its first stock. The
            // request id makes the first stock once-only (approving twice adds nothing).
            final pool = _requestPool(data);
            if (pool == null) {
              throw 'Could not work out the stock place (camp) for this request. Choose a camp first.';
            }
            for (final item in itemsToUse) {
              final name = item['name']?.toString() ?? '';
              final type = item['type'] ?? '';
              final dose = item['dose'] ?? '';
              final exp  = item['expiryDate'] ?? '';
              final id = RequestUtils.generateDocId(name, type, dose, exp);
              final qty = _asInt(item['quantity']).toDouble();
              final details = _stockDetailsOnly({
                ...item,
                'createdBy': data['requestedBy'],
                'createdByName': data['requesterName'],
                'approvedBy': reviewerUid,
                'approvedByName': reviewerName ?? 'Supervisor',
                'addedAt': DateTime.now().toIso8601String(),
              });
              await StockActions.addBatch(pool, id, details,
                  initialQty: qty, ref: 'approved registration', opKey: docId);
            }
          }
        }
      }

      if (newStatus == 'approved' &&
          (data['requestType']?.toString() ?? '') == 'edit_medicine') {
        final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
            ? _safeItemList(data['draftItems'])
            : _safeItemList(data['items']);
        final originalDocId = data['docId']?.toString();

        for (final item in itemsToUse) {
          final name = item['name']?.toString() ?? '';
          final type = item['type'] ?? '';
          final dose = item['dose'] ?? '';
          final oldId = originalDocId ?? item['oldId']?.toString();
          
          await branchRef.collection('inventory_log').add({
            'action': 'medicine_edited',
            'medicineName': name,
            'medicineType': type,
            'dose': dose,
            'oldId': oldId,
            'performedBy': reviewerUid,
            'performedByName': reviewerName ?? 'Supervisor',
            'timestamp': FieldValue.serverTimestamp(),
          });
        }
      }

      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(
          content: Text('Request ${newStatus.toUpperCase()}'),
          backgroundColor: newStatus == 'approved' ? _teal : _red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(
          content: Text('Error: $e'),
          backgroundColor: _red,
        ));
      }
    }
  }

  Future<void> _applyEditMedicine(
      DocumentReference branchRef,
      Map<String, dynamic> requestData,
      List<Map<String, dynamic>> items,
      String? reviewerUid,
      String? reviewerName,
      {String? requestId}) async {
    final originalDocId = requestData['docId']?.toString();
    final effCamp = (requestData['dispensaryId'] ?? requestData['campId'])?.toString();
    // Stock book: the request's pool. Details via saveDetails, quantity only via a counted
    // difference (setCounted), never an absolute overwrite.
    final pool = _requestPool(requestData);
    if (pool == null) {
      throw 'Could not work out the stock place (camp) for this request. Choose a camp first.';
    }
    final original = requestData['originalData'];
    final originalQty = original is Map && original['quantity'] != null ? _asInt(original['quantity']) : null;

    for (final item in items) {
      final name = (item['name'] ?? '').toString().trim();
      final type = (item['type'] ?? '').toString().trim();
      final dose = (item['dose'] ?? '').toString().trim();
      final formula = (item['formula'] ?? item['name'] ?? '').toString().trim();
      final price = _parsePrice(item['price']);
      final expiry = (item['expiryDate'] ?? '').toString().trim();
      final barcode = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim();
      final itemCode = (item['code'] ?? item['itemCode'] ?? '').toString().trim();
      final packBarcode = (item['packBarcode'] ?? '').toString().trim();
      final qty = (item['quantity'] is num)
          ? (item['quantity'] as num).toInt()
          : (int.tryParse(item['quantity']?.toString() ?? '') ?? 0);
      final distilledWater = (item['distilledWater'] as num?)?.toInt();
      final drops = (item['drops'] as num?)?.toInt();

      final updateData = <String, dynamic>{
        'name': name,
        'name_lower': name.toLowerCase(),
        'formula': formula,
        'formula_lower': formula.toLowerCase(),
        'type': type,
        'dose': type == 'Nebulization' ? '' : dose,
        'price': price,
        if (barcode.isNotEmpty) 'barcode': barcode,
        if (barcode.isNotEmpty) 'rollNo': barcode,
        if (itemCode.isNotEmpty) 'code': itemCode,
        if (itemCode.isNotEmpty) 'itemCode': itemCode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
        'expiryDate': expiry,
        'approvedBy': reviewerUid,
        'approvedByName': reviewerName ?? 'Supervisor',
      };
      if (type == 'Nebulization') {
        updateData['distilledWater'] = distilledWater ?? 0;
        updateData['drops'] = drops ?? 0;
      }

      String cleanDocId(dynamic raw) {
        final s = (raw ?? '').toString().trim();
        return s.startsWith('stock:') ? s.substring(6) : s;
      }

      final targetDocId = cleanDocId(originalDocId ?? item['oldId']);
      final newId = RequestUtils.generateDocId(
        name,
        type,
        type == 'Nebulization' ? '' : dose,
        expiry,
        distilledWater: distilledWater,
        drops: drops,
        campId: effCamp,
      );
      // Only a quantity the request really changed is applied (as a counted difference),
      // so stock dispensed since the request was made is not undone.
      final qtyChanged = originalQty == null || originalQty != qty;

      if (targetDocId.isNotEmpty && targetDocId == newId) {
        await StockActions.saveDetails(pool, targetDocId, updateData);
        if (qtyChanged) {
          await StockActions.setCounted(pool, targetDocId, qty.toDouble(), reason: 'approved edit');
        }
      } else {
        // The id changes: hide the old batch and open the new one with the old batch's
        // current stock. The request id makes that transfer once-only.
        final oldItem = targetDocId.isEmpty ? null : StockLedger.item(pool.key, targetDocId);
        final carried = oldItem == null ? 0.0 : StockReader.qty(oldItem);
        if (oldItem != null) await StockActions.deleteBatch(pool, targetDocId);
        updateData['addedAt'] = DateTime.now().toIso8601String();
        await StockActions.addBatch(pool, newId, updateData,
            initialQty: carried,
            ref: 'approved edit (renamed)',
            opKey: requestId ?? 'edit:$targetDocId');
        if (qtyChanged || oldItem == null) {
          await StockActions.setCounted(pool, newId, qty.toDouble(), reason: 'approved edit');
        }
      }
    }

    _loadDataFromHive();
  }

  /// Pool of an edit/registration request: its camp, else this PC's active camp.
  StockPool? _requestPool(Map requestData) {
    final camp = (requestData['dispensaryId'] ?? requestData['campId'])?.toString();
    return StockPool.of(_effectiveBranchId, camp, fallbackCamp: CampSessionService.getActiveCamp(_effectiveBranchId));
  }

  /// Item details without quantity / server-only fields (the stock book keeps quantity).
  static Map<String, dynamic> _stockDetailsOnly(Map item) {
    final out = <String, dynamic>{};
    item.forEach((k, v) {
      final key = k.toString();
      if (v is FieldValue || v is Timestamp) return;
      if (const {'quantity', 'stock', '_quantityDelta', 'pool', 'id', 'medicineId', 'docId'}.contains(key)) return;
      out[key] = v;
    });
    return out;
  }

  Future<void> _applyDeleteMedicine(
      Map<String, dynamic> requestData,
      List<Map<String, dynamic>> items) async {
    // Stock book: hide the matching batches of the request's pool (kept for history).
    final pool = _requestPool(requestData);
    if (pool == null) {
      throw 'Could not work out the stock place (camp) for this request. Choose a camp first.';
    }
    for (final item in items) {
      final name = item['name']?.toString();
      final type = item['type']?.toString();
      if (name == null || type == null) continue;
      for (final rec in StockLedger.items(pool: pool.key)) {
        final rName = (rec['name'] ?? '').toString().toLowerCase();
        final rType = (rec['type'] ?? '').toString();
        if (rName != name.toLowerCase() || rType != type) continue;
        final id = (rec['medicineId'] ?? rec['id'] ?? '').toString();
        if (id.isNotEmpty) await StockActions.deleteBatch(pool, id);
      }
    }
    _loadDataFromHive();
  }

  Widget _buildMedicineEditComparison(Map<String, dynamic> data) {
    final c = context.comfort;
    final originalData = data['originalData'] as Map<String, dynamic>? ?? {};
    final rawItems = data['draftItems'] ?? data['items'] ?? [];
    final items = _safeItemList(rawItems);
    
    final proposedData = items.isNotEmpty ? items.first : <String, dynamic>{};
    
    final fields = [
      {'key': 'name', 'label': 'Formula'},
      {'key': 'type', 'label': 'Type'},
      {'key': 'dose', 'label': 'Dose'},
      {'key': 'barcode', 'label': 'Barcode'},
      {'key': 'quantity', 'label': 'Qty'},
      {'key': 'price', 'label': 'Price'},
      {'key': 'expiryDate', 'label': 'Expiry'},
    ];

    String getValue(Map<String, dynamic> m, String key) {
      final v = m[key];
      if (key == 'price' && v != null && v.toString().isNotEmpty) {
        return 'PKR ${v.toString()}';
      }
      return v?.toString() ?? '—';
    }

    final isWide = !GBreakpoint.isMobile(context);

    if (isWide) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(c.brandSoft),
            columnSpacing: 20,
            horizontalMargin: 16,
            columns: [
              DataColumn(label: Text('Field', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: c.textSecondary))),
              DataColumn(label: Text('Original', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: c.textSecondary))),
              DataColumn(label: Text('Proposed', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: c.textSecondary))),
            ],
            rows: fields.map((f) {
              final key = f['key'] as String;
              final oldVal = getValue(originalData, key);
              final newVal = getValue(proposedData, key);
              final isChanged = oldVal != newVal && newVal != '—';

              return DataRow(cells: [
                DataCell(Text(f['label']!, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: c.textPrimary))),
                DataCell(Text(oldVal, style: TextStyle(
                  color: isChanged ? c.textMuted : c.textPrimary,
                  decoration: isChanged ? TextDecoration.lineThrough : null,
                  fontSize: 12,
                ))),
                DataCell(Text(newVal, style: TextStyle(
                  color: isChanged ? c.info : c.textPrimary,
                  fontWeight: isChanged ? FontWeight.w700 : FontWeight.normal,
                  fontSize: 12,
                ))),
              ]);
            }).toList(),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Text('Proposed Changes:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.brandStrong)),
        ),
        ...fields.map((f) {
          final key = f['key'] as String;
          final label = f['label'] as String;
          final oldVal = getValue(originalData, key);
          final newVal = getValue(proposedData, key);
          
          if (oldVal == newVal || newVal == '—') return const SizedBox.shrink();

          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text(label, style: TextStyle(fontSize: 11, color: c.textSecondary, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(oldVal, style: TextStyle(fontSize: 11, color: c.textMuted, decoration: TextDecoration.lineThrough)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.arrow_forward, size: 10, color: c.textMuted),
                      ),
                      Text(newVal, style: TextStyle(fontSize: 12, color: c.info, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  List<Map<String, dynamic>> _safeItemList(dynamic raw) {
    if (raw == null) return [];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Widget _buildItemsList(List<Map<String, dynamic>> items) {
    final isWide = !GBreakpoint.isMobile(context);
    return isWide ? _itemsTable(items) : _itemsCompact(items);
  }

  Widget _itemsTable(List<Map<String, dynamic>> items) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor:
            WidgetStateProperty.all(_tealDark.withValues(alpha: 0.07)),
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        columnSpacing: 16,
        columns: const [
          DataColumn(
              label: Text('Formula',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Type',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Dose',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Camp',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Barcode',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Qty',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Price',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
          DataColumn(
              label: Text('Expiry',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12))),
        ],
        rows: items.map((m) {
          final p = _parsePrice(m['price']);
          final campId = (m['dispensaryId'] ?? m['campId'] ?? 'all').toString();
          final campLabel = CampSessionService.getCampLabel(campId);
          return DataRow(cells: [
            DataCell(Text(m['name']?.toString() ?? '—',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12))),
            DataCell(Row(children: [
              _typeIconWidget(m['type'] ?? '',
                  size: 12, color: _teal),
              const SizedBox(width: 5),
              Text(m['type']?.toString() ?? '—',
                  style: const TextStyle(fontSize: 12)),
            ])),
            DataCell(Text(m['dose']?.toString() ?? '—',
                style: const TextStyle(fontSize: 12))),
            DataCell(Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _teal.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _teal.withValues(alpha: 0.3)),
              ),
              child: Text(campLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _teal)),
            )),
            DataCell(Text(
                (m['barcode']?.toString().isNotEmpty ?? false)
                    ? m['barcode'].toString()
                    : '—',
                style: const TextStyle(fontSize: 12))),
            DataCell(Text('${m['quantity'] ?? 0}',
                style: const TextStyle(fontSize: 12))),
            DataCell(Text('PKR ${_fmtPrice(p)}',
                style: const TextStyle(
                    fontSize: 12,
                    color: _green600,
                    fontWeight: FontWeight.w600))),
            DataCell(Text(
                _formatDate(m['expiryDate']?.toString()),
                style: const TextStyle(fontSize: 12))),
          ]);
        }).toList(),
      ),
    );
  }

  Widget _itemsCompact(List<Map<String, dynamic>> items) {
    return Column(
      children: items.map((m) {
        final name = m['name']?.toString() ?? '—';
        final type = m['type']?.toString() ?? '';
        final dose = (m['dose']?.toString().isNotEmpty == true)
            ? ' · ${m['dose']}'
            : '';
        final qty = m['quantity'] ?? 0;
        final price = _parsePrice(m['price']);
        final expiry = _formatDate(m['expiryDate']?.toString());
        final barcode = (m['barcode'] ?? m['rollNo'] ?? '').toString().trim();
        final campId = (m['dispensaryId'] ?? m['campId'] ?? 'all').toString();
        final campLabel = CampSessionService.getCampLabel(campId);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                  color: context.adapt(_white),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.adapt(_border))),
              child: _typeIconWidget(type, size: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              Text('$name ($type$dose) × $qty',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: context.adapt(_textDark))),
              const SizedBox(height: 2),
              Row(children: [
                _miniChip('PKR ${_fmtPrice(price)}', _green600),
                const SizedBox(width: 6),
                _miniChip(expiry, context.adapt(_textMid)),
                const SizedBox(width: 6),
                _miniChip('Camp: $campLabel', _teal),
                if (barcode.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _miniChip(barcode, context.adapt(_indigo)),
                ],
              ]),
            ])),
          ]),
        );
      }).toList(),
    );
  }

  Widget _hCell(double w, String label, String? sort, {bool alignEnd = false, bool centered = false}) {
    final c = context.comfort;
    final active = _sortField == sort;
    return InkWell(
      onTap: sort != null ? () => _sort(sort) : null,
      child: Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisAlignment: centered
              ? MainAxisAlignment.center
              : (alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start),
          children: [
            Flexible(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? c.brand : c.textMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            if (active) ...[
              const SizedBox(width: 3),
              Icon(
                _isAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 12,
                color: c.brand,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Color _darkTypeColor(String type) => switch (type) {
        'Tablet' => SoftPalette.blue350,
        'Capsule' => SoftPalette.purple350,
        'Syrup' => SoftPalette.amber200,
        'Injection' => SoftPalette.red300,
        'Infusion' => SoftPalette.teal200,
        'Drip' => SoftPalette.teal200,
        'Drip Set' => SoftPalette.cyan200,
        'Syringe' => SoftPalette.pink350,
        'Cannula' => SoftPalette.red350,
        'Needle' => SoftPalette.purple350,
        'Nebulization' => SoftPalette.indigo400,
        'Dressing Item' => SoftPalette.slate200,
        'Consumables' => SoftPalette.teal300,
        _ => SoftPalette.slate150,
      };

  Widget _typePill(String type) {
    final clean = type.trim();
    if (clean.isEmpty) {
      return Text('—', style: TextStyle(color: context.comfort.textMuted, fontSize: 12.5));
    }
    final color = _isDark ? _darkTypeColor(clean) : _typeColor(clean);
    final bg = _isDark ? color.withValues(alpha: 0.16) : color.withValues(alpha: 0.10);
    final border = _isDark ? color.withValues(alpha: 0.36) : color.withValues(alpha: 0.28);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 0.9),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _typeIconWidget(clean, size: 10, color: color),
        const SizedBox(width: 4),
        Flexible(
            child: Text(clean,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700))),
      ]),
    );
  }

  Widget _priceBadge(double price) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: _isDark ? SoftPalette.green700.withValues(alpha: 0.35) : SoftPalette.green50t,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: _isDark ? SoftPalette.green350.withValues(alpha: 0.5) : SoftPalette.green300.withValues(alpha: 0.6)),
        ),
        child: Text('PKR ${_fmtPrice(price)}',
            style: TextStyle(
                color: _isDark ? SoftPalette.green300 : SoftPalette.green550,
                fontWeight: FontWeight.w800,
                fontSize: 11.5)),
      );

  Widget _dCell(double w, Widget child) => Container(
      width: w,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: child);

  Widget _qtyBadge(int qty, bool low) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (low ? _red : _green600).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: (low ? _red : _green600).withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (low) ...[
            const Icon(Icons.warning_rounded, size: 11, color: _red),
            const SizedBox(width: 3)
          ],
          Text(qty.toString(),
              style: TextStyle(
                  color: low ? _red : _green600,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ]),
      );

  Widget _expBadge(String text, bool soon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: (soon ? _red : (_isDark ? SoftPalette.slate700 : SoftPalette.gray100)).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: (soon ? _red : (_isDark ? SoftPalette.slate600 : SoftPalette.gray150)).withValues(alpha: 0.5),
              width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_today_rounded, size: 10, color: soon ? _red : (_isDark ? SoftPalette.slate350 : _textMid)),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: soon ? _red : (_isDark ? SoftPalette.slate200 : _textMid),
                  fontWeight: soon ? FontWeight.bold : FontWeight.normal,
                  fontSize: 11)),
        ]),
      );

  Widget _statusDot({required bool lowStock, required bool expSoon}) {
    final Color dotColor = lowStock
        ? _red
        : (expSoon ? _amber : SoftPalette.green550);
    
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _statusLabel(
      {required bool lowStock, required bool expSoon, bool isTable = false}) {
    String label = '';
    IconData icon = Icons.warning_rounded;
    Color badgeColor = _red;

    if (lowStock && expSoon) {
      label = isTable ? 'CRITICAL' : 'CRITICAL: LOW STOCK & NEAR EXPIRY';
      icon = Icons.error_outline_rounded;
      badgeColor = _red;
    } else if (lowStock) {
      label = isTable ? 'LOW STOCK' : 'WARNING: LOW STOCK';
      icon = Icons.inventory_2_rounded;
      badgeColor = _red;
    } else if (expSoon) {
      label = isTable ? 'NEAR EXPIRY' : 'ALERT: NEAR EXPIRY';
      icon = Icons.access_time_rounded;
      badgeColor = _amber;
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: isTable ? 8 : 12, vertical: isTable ? 3 : 5),
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: badgeColor.withValues(alpha: 0.35),
            blurRadius: 5,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: SoftPalette.gray50, size: isTable ? 10 : 12),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: SoftPalette.gray50,
                fontSize: isTable ? 8 : 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoBadge(String text, Color color, {IconData? icon}) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _miniChip(String text, Color color) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(text,
            style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600)),
      );

  Widget _emptyState(
    IconData icon,
    String msg, {
    GEmptyIllustrationKind? illustration,
    String? subtitle,
  }) {
    final c = context.comfort;
    final kind = illustration ??
        GEmptyIllustrationKind.infer(icon: icon, title: msg, subtitle: subtitle);
    final lines = msg.split('\n');
    final headline = lines.first.trim();
    final sub = subtitle ??
        (lines.length > 1 ? lines.sublist(1).join('\n').trim() : null);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GEmptyIllustration(kind, size: 164, fallbackIcon: icon),
              const SizedBox(height: 16),
              Text(
                headline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (sub != null && sub.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EditMedicineSheet extends StatefulWidget {
  final String branchId;
  final List<String> docIds;
  /// Pool of each entry in [docIds] (same order).
  final List<StockPool> docPools;
  final Map<String, dynamic> initial;
  final List<String> medicineTypes;
  final String Function(String?) formatDate;
  final bool isAdmin;
  final bool isDoctor;
  final bool isDispenser;

  const _EditMedicineSheet({
    required this.branchId,
    required this.docIds,
    required this.docPools,
    required this.initial,
    required this.medicineTypes,
    required this.formatDate,
    this.isAdmin = false,
    this.isDoctor = false,
    this.isDispenser = false,
  });

  @override
  State<_EditMedicineSheet> createState() => _EditMedicineSheetState();
}

class _EditMedicineSheetState extends State<_EditMedicineSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _doseCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _expiryCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _packBarcodeCtrl;
  late String _selectedType;

  bool _saving = false;
  final _formKey = GlobalKey<FormState>();

  double _parsePrice(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _fmtPrice(double p) =>
      p == p.floorToDouble()
          ? p.toInt().toString()
          : p.toStringAsFixed(2);

  int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? (double.tryParse(v?.toString() ?? '')?.toInt() ?? 0);
  }

  @override
  void initState() {
    super.initState();
    final initialPrice = _parsePrice(widget.initial['price']);
    _nameCtrl =
        TextEditingController(text: widget.initial['name']?.toString() ?? '');
    _doseCtrl =
        TextEditingController(text: widget.initial['dose']?.toString() ?? '');
    _qtyCtrl = TextEditingController(
        text: '${widget.initial['quantity'] ?? 0}');
    _priceCtrl =
        TextEditingController(text: _fmtPrice(initialPrice));
    _expiryCtrl = TextEditingController(
        text: widget.initial['expiryDate']?.toString() ?? '');
    _barcodeCtrl = TextEditingController(
        text: widget.initial['barcode']?.toString() ?? '');
    _packBarcodeCtrl = TextEditingController(
        text: widget.initial['packBarcode']?.toString() ?? '');
    _selectedType = widget.medicineTypes
            .contains(widget.initial['type'])
        ? widget.initial['type'].toString()
        : widget.medicineTypes.first;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _doseCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _expiryCtrl.dispose();
    _barcodeCtrl.dispose();
    _packBarcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
      final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;
      final rawBar = _barcodeCtrl.text.trim();
      final barcode = MasterProformaService.normalizeProformaBarcode(rawBar) ?? rawBar;
      final packBarcode = _packBarcodeCtrl.text.trim();
      final existingCode = (widget.initial['code'] ?? '').toString().trim();
      final existingFormula = (widget.initial['formula'] ?? '').toString();
      final n = widget.docIds.length < widget.docPools.length ? widget.docIds.length : widget.docPools.length;

      // 1. Details (name, type, dose, expiry, price, codes) on every batch of this row.
      //    Quantity is never part of the details.
      for (int i = 0; i < n; i++) {
        final id = widget.docIds[i];
        final pool = widget.docPools[i];
        var formula = existingFormula;
        if (formula.isEmpty) {
          formula = (StockLedger.item(pool.key, id)?['formula'] ?? '').toString();
        }
        await StockActions.saveDetails(pool, id, {
          if (formula.isNotEmpty) 'formula': formula,
          'name': _nameCtrl.text.trim(),
          'name_lower': _nameCtrl.text.trim().toLowerCase(),
          'type': _selectedType,
          'dose': _doseCtrl.text.trim(),
          'price': price,
          'barcode': barcode,
          'rollNo': barcode,
          if (existingCode.isNotEmpty) 'code': existingCode,
          'packBarcode': packBarcode,
          'expiryDate': _expiryCtrl.text.trim(),
        });
      }

      // 2. Quantity: only if the user changed the figure, and only as a counted difference
      //    on ONE batch (for a grouped row the earliest-expiry batch). A fall below zero
      //    carries on to the next batches. Never spread a total over the batches.
      final shownQty = _toInt(widget.initial['quantity']);
      final diff = qty - shownQty;
      if (diff != 0 && n > 0) {
        final batches = <Map<String, dynamic>>[];
        for (int i = 0; i < n; i++) {
          final it = StockLedger.item(widget.docPools[i].key, widget.docIds[i]);
          batches.add({
            ...?it,
            'id': widget.docIds[i],
            'medicineId': widget.docIds[i],
            '_pool': widget.docPools[i],
            'quantity': it == null ? 0.0 : StockReader.qty(it),
          });
        }
        StockReader.sortFefo(batches);
        if (diff > 0) {
          final b = batches.first;
          await StockActions.setCounted(b['_pool'] as StockPool, b['id'].toString(),
              StockReader.qty(b) + diff, reason: 'edit medicine');
        } else {
          var left = -diff.toDouble();
          for (final b in batches) {
            if (left <= 0) break;
            final have = StockReader.qty(b);
            if (have <= 0) continue;
            final take = left <= have ? left : have;
            await StockActions.setCounted(b['_pool'] as StockPool, b['id'].toString(),
                have - take, reason: 'edit medicine');
            left -= take;
          }
        }
      }

      await StockLog.record({
        'action': 'medicine_edited',
        'medicineName': _nameCtrl.text.trim(),
        'medicineType': _selectedType,
        'dose': _doseCtrl.text.trim(),
        'medicineId': widget.docIds.isNotEmpty ? widget.docIds.first : '',
        'pool': widget.docPools.isNotEmpty ? widget.docPools.first.key : '',
        'expiryBefore': widget.initial['expiryDate'],
        'expiryDate': _expiryCtrl.text.trim(),
        'quantityBefore': shownQty,
        'quantityAfter': qty,
        'quantityChange': diff,
        'branchId': widget.branchId,
      });

      if (!mounted) return;
      Navigator.pop(context);
      AppFeedback.showSuccess(
        context,
        'Medicine updated successfully',
        subtitle: 'Saved locally • Synced across dispensary & clinic',
      );
    } catch (e) {
      setState(() => _saving = false);
      if (!mounted) return;
      AppFeedback.showError(context, 'Failed to update: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: c.border)),
      ),
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.brandSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.edit_rounded, color: c.brand, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('Edit Medicine',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary)),
              Text('${widget.docIds.length} batch doc(s) will be updated',
                  style: TextStyle(
                      fontSize: 11.5, color: c.textSecondary)),
            ]),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, color: c.textMuted),
            onPressed: () => Navigator.pop(context),
          ),
        ]),
        const SizedBox(height: 14),
        Divider(height: 1, color: c.border),
        const SizedBox(height: 14),
        // Flexible so the fields scroll on short windows / with the keyboard up, and the
        // Save button below always stays visible.
        Flexible(
          child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(children: [
              _field(
                controller: _nameCtrl,
                label: 'Formula',
                icon: Icons.medication_rounded,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Type',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: c.surfaceSunken,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.border),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedType,
                    isExpanded: true,
                    underline: const SizedBox(),
                    dropdownColor: c.surface,
                    style: TextStyle(color: c.textPrimary, fontSize: 14),
                    icon: Icon(Icons.expand_more_rounded, color: c.brand),
                    items: widget.medicineTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _selectedType = v ?? _selectedType),
                  ),
                ),
              ])),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  controller: _doseCtrl,
                  label: 'Dose (e.g. 500mg, 5ml)',
                  icon: Icons.vaccines_rounded,
                ),
              ),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: _field(
                    controller: _barcodeCtrl,
                    label: 'Barcode (001–999)',
                    icon: Icons.qr_code_rounded,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _field(
                    controller: _packBarcodeCtrl,
                    label: 'Pack Barcode (Optional)',
                    icon: Icons.qr_code_scanner_rounded,
                    keyboardType: TextInputType.text,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: _field(
                  controller: _qtyCtrl,
                  label: 'Total Quantity',
                  icon: Icons.numbers_rounded,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly
                  ],
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                )),
                const SizedBox(width: 12),
                Expanded(
                    child: _field(
                  controller: _priceCtrl,
                  label: 'Price (PKR)',
                  icon: Icons.payments_rounded,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d*')),
                  ],
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Required';
                    if (double.tryParse(v.trim()) == null) {
                      return 'Invalid price';
                    }
                    return null;
                  },
                )),
              ]),
              const SizedBox(height: 12),
              _field(
                controller: _expiryCtrl,
                label: 'Expiry (MM-YYYY or DD-MM-YYYY)',
                icon: Icons.calendar_today_rounded,
                // Only a CHANGED expiry is checked, so fixing the price of a batch that
                // already expires soon is still possible.
                validator: (v) => (v ?? '').trim() == (widget.initial['expiryDate'] ?? '').toString().trim()
                    ? null
                    : expiryInputError(v ?? '', allowEmpty: true),
              ),
              const SizedBox(height: 8),
            ]),
          ),
        ),
        ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: c.onBrand))
                      : const Icon(Icons.save_rounded, size: 18),
                  label: Text(_saving ? 'Saving…' : 'Save Changes',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.brand,
                    foregroundColor: c.onBrand,
                    disabledBackgroundColor: c.brand.withValues(alpha: 0.45),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
      ]),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
    bool enabled = true,
    String? helperText,
  }) {
    final c = context.comfort;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: c.textSecondary)),
      const SizedBox(height: 6),
      TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        validator: validator,
        enabled: enabled,
        readOnly: !enabled,
        cursorColor: c.brand,
        style: TextStyle(
            color: enabled ? c.textPrimary : c.textMuted,
            fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, size: 17, color: enabled ? c.brand : c.textMuted),
          suffixIcon: !enabled ? Icon(Icons.lock_rounded, size: 16, color: c.textMuted) : null,
          helperText: helperText,
          helperStyle: TextStyle(color: c.warning, fontSize: 11, fontWeight: FontWeight.w700),
          filled: true,
          fillColor: enabled ? c.surfaceSunken : c.background,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.brand, width: 1.6)),
          disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.border)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.danger)),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.danger, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 13),
        ),
      ),
    ]);
  }
}

class _Col {
  final String label;
  final double w;
  final String? sort;
  final bool alignEnd;
  const _Col(this.label, this.w, this.sort, {this.alignEnd = false});
}

/// Interactive medicine table row with smooth hover state and crisp hairline divider.
class _InventoryHoverRow extends StatefulWidget {
  const _InventoryHoverRow({
    required this.baseColor,
    required this.hoverColor,
    required this.borderColor,
    required this.borderWidth,
    required this.onTap,
    required this.builder,
  });

  final Color baseColor;
  final Color hoverColor;
  final Color borderColor;
  final double borderWidth;
  final VoidCallback? onTap;
  final Widget Function(bool hovered) builder;

  @override
  State<_InventoryHoverRow> createState() => _InventoryHoverRowState();
}

class _InventoryHoverRowState extends State<_InventoryHoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 44),
          decoration: BoxDecoration(
            color: _hovered ? widget.hoverColor : widget.baseColor,
            border: Border(
              bottom: BorderSide(color: widget.borderColor, width: widget.borderWidth),
            ),
          ),
          child: widget.builder(_hovered),
        ),
      ),
    );
  }
}

/// Sleek, low-noise row delete action using GMWF's new `GIcons.delete` rounded icon:
/// quiet muted ghost icon at rest, smoothly elevating into a soft-danger pill on hover.
class _InventoryRowDeleteButton extends StatefulWidget {
  const _InventoryRowDeleteButton({
    required this.onTap,
    this.rowHovered = false,
  });

  final VoidCallback onTap;
  final bool rowHovered;

  @override
  State<_InventoryRowDeleteButton> createState() => _InventoryRowDeleteButtonState();
}

class _InventoryRowDeleteButtonState extends State<_InventoryRowDeleteButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bg = _hovered
        ? c.dangerBg
        : (widget.rowHovered ? c.danger.withValues(alpha: 0.08) : Colors.transparent);
    final border = _hovered
        ? c.danger.withValues(alpha: 0.42)
        : (widget.rowHovered ? c.danger.withValues(alpha: 0.18) : Colors.transparent);
    final iconColor = _hovered
        ? c.danger
        : (widget.rowHovered ? c.danger.withValues(alpha: 0.82) : c.textMuted.withValues(alpha: 0.65));

    return Tooltip(
      message: 'Remove medicine from inventory',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            splashColor: c.danger.withValues(alpha: 0.14),
            highlightColor: Colors.transparent,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: border, width: 1),
              ),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 140),
                scale: _hovered ? 1.08 : 1.0,
                child: Icon(GIcons.delete, size: 16, color: iconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
