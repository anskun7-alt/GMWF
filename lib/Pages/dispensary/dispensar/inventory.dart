// lib/pages/dispensary/dispensar/inventory.dart

import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';
import 'inventory_update.dart';
import 'medicine_ledger.dart';
import 'universal_proforma_sheet.dart';
import 'stock_check_report.dart';
import '../widgets/medicine_icon_badge.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
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
import 'package:gmwf/widgets/blurred_dialog_observer.dart';

class InventoryPage extends StatefulWidget {
  final String branchId;
  final bool isAdmin;
  final bool isDispenser;
  final bool isEmbedded;
  final bool isSupervisor;
  final bool isDoctor;
  final bool isReadOnly;

  const InventoryPage({
    super.key,
    required this.branchId,
    this.isAdmin = false,
    this.isDispenser = false,
    this.isEmbedded = false,
    this.isSupervisor = false,
    this.isDoctor = false,
    this.isReadOnly = false,
  });

  static bool canDeleteInventoryItemFromRole(Map<dynamic, dynamic>? userData) {
    final raw = userData == null ? '' : (userData['role'] ?? userData['userRole'] ?? '').toString();
    final role = raw.trim().toLowerCase();
    return role == 'chairman' ||
        role == 'hq manager' ||
        role == 'hq_manager' ||
        role == 'hqmanager' ||
        role == 'headquarters manager' ||
        role.contains('admin');
  }

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
  String _sortField = 'name';
  bool _isAscending = true;
  int _page = 0;
  final int _perPage = 25;
  List<String> _batchKeys = ['All Batches'];
  String? _selectedCampFilter;
  final ScrollController _scrollController = ScrollController();
  int _displayLimit = 50;
  bool _isExportingPdf = false;
  bool _showRemoveAllMeds = false;
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

  bool _handleKeyboardShortcuts(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      if (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.delete) {
        setState(() {
          _showRemoveAllMeds = !_showRemoveAllMeds;
        });
        if (mounted) {
          AppToast.showSnackBar(context, 
            SnackBar(
              content: Text(
                _showRemoveAllMeds
                    ? '🔓 "Remove All Meds" button unlocked and visible.'
                    : '🔒 "Remove All Meds" button hidden.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              duration: const Duration(seconds: 2),
              backgroundColor: _showRemoveAllMeds ? SoftPalette.red550 : SoftPalette.slate700,
            ),
          );
        }
        return true;
      }
    }
    return false;
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
    HardwareKeyboard.instance.addHandler(_handleKeyboardShortcuts);
    int tabCount = 6; // Stock, Proforma, Report, Pending, Log, History
    if (_isSupervisorUser || _isDoctorUser) {
      tabCount = 1;
    } else {
      if (!_isSupervisorOrReadOnly) tabCount++; // Update Stock
      if (_canRegisterMedicine) tabCount++; // Register Medicine
    }
    _tabCtrl = TabController(length: tabCount, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted && !_tabCtrl.indexIsChanging) {
        debugPrint('[InventoryPage] tab -> ${_tabCtrl.index}'
            ' (previous ${_tabCtrl.previousIndex}) from: '
            '${StackTrace.current.toString().split("\n").skip(1).take(4).map((l) => l.trim()).join(" <- ")}');
        setState(() {});
      }
    });
    _scrollController.addListener(_onScroll);

    final isHqOrAdmin = widget.isAdmin || _canDeleteInventoryItem;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    final availableOptions = CampSessionService.getAvailableCampOptions();
    final hasCamps = CampSessionService.hasCampsForBranch(widget.branchId) || widget.branchId.toLowerCase().contains('karachi');
    _selectedCampFilter = !hasCamps
        ? 'all'
        : ((active != null && active.isNotEmpty)
            ? active
            : (isHqOrAdmin ? 'all' : (availableOptions.isNotEmpty ? availableOptions.first['id'] : 'all')));

    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    RealtimeManager.isLanHealthyNotifier.addListener(_onLanHealthChanged);

    _initSync();
    if (widget.branchId.toLowerCase().contains('karachi')) {
      LocalStorageService.healKarachiSplitInventory();
    }

    // Cache database loading
    // Kept so dispose() removes the listener from the same listenable (a fresh one removed
    // nothing, leaking a stock-box watcher each time this screen was opened).
    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      _stockListenable = Hive.box(LocalStorageService.stockBox).listenable()
        ..addListener(_debouncedLoadDataFromHive);
      _loadDataFromHive();
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

  void _onLanHealthChanged() {
    if (!mounted) return;
    debugPrint('[Inventory] LAN Health changed: ${RealtimeManager.isLanHealthyNotifier.value}. Refreshing inventory sync state...');
    _fireInvSub?.cancel();
    _logCombinedSub?.cancel();
    _initSync();
  }

  void _onActiveCampChanged() {
    if (!mounted) return;
    final active = CampSessionService.getActiveCamp(widget.branchId);
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
      _rawItems.clear();
      _groupedBatches.clear();
      _filteredBatches.clear();
      _displayItems.clear();
      _initSync();
      _loadDataFromHive();
    }
  }

  String get _effectiveBranchId {
    final b = widget.branchId.trim().toLowerCase();
    if (b.isNotEmpty && b != 'all' && b != 'unknown') {
      if (CampSessionService.isKarachiFamily(b)) return 'karachi';
      return b;
    }
    final active = LocalStorageService.getActiveBranchId();
    if (active != null && active.isNotEmpty && active != 'all') {
      if (CampSessionService.isKarachiFamily(active)) return 'karachi';
      return active.toLowerCase().trim();
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final saved = Hive.box('app_settings').get('selected_branch');
        if (saved != null && saved.toString().isNotEmpty && saved != 'all') {
          final s = saved.toString().toLowerCase().trim();
          if (CampSessionService.isKarachiFamily(s)) return 'karachi';
          return s;
        }
      }
    } catch (_) {}
    return 'karachi';
  }

  // ── Stock book pools ──────────────────────────────────────────────────────
  /// The pools this screen shows: the selected camp's pool, or every pool of the branch
  /// for the "all camps" view (each record keeps its own `pool`).
  List<StockPool> _viewPools() {
    final branch = _effectiveBranchId;
    final sel = (_selectedCampFilter ?? '').trim();
    if (sel.isEmpty || sel.toLowerCase() == 'all') return StockPool.allFor(branch);
    final p = StockPool.of(branch, sel, fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));
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
    // Inventory is driven 100% locally from Hive stockBox + LAN sync events.
    // Zero continuous Firestore listeners.
    try {
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        // Debounced: a sync pass writes the queue once per item, and each rescan walks the
        // whole queue on the UI thread — undebounced, that froze the window ("Not Responding").
        final localSyncStream = Hive.box(LocalStorageService.syncBox)
            .watch()
            .debounceTime(const Duration(milliseconds: 500))
            .map((_) => _getPendingLogs());
        _logCombinedSub = localSyncStream
            .startWith(_getPendingLogs())
            .listen((list) => _logState.add(list));
      }
    } catch (e) {
      debugPrint('[Inventory] Local pending logs sync error: $e');
    }
  }

  // ─── Manual Cloud Recovery Pull (On-Demand with 30s Debounce) ─────────
  DateTime? _lastCloudPullTime;
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

  List<Map<String, dynamic>> _getPendingLogs() {
    final box = Hive.box(LocalStorageService.syncBox);
    final pending = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map) continue;
      final type = raw['type']?.toString();
      if (type == 'add_inventory_stock' || type == 'register_medicine') {
        final item = Map<String, dynamic>.from(raw);
        final data = Map<String, dynamic>.from(item['data'] ?? item);
        pending.add({
          ...data,
          '_isPending': true,
          'action': type == 'add_inventory_stock' ? 'add_stock' : 'medicine_registered_directly',
          'medicineName': data['medicineName'] ?? data['name'] ?? 'Pending...',
          'timestamp': item['createdAt'] != null ? Timestamp.fromDate(DateTime.parse(item['createdAt'])) : Timestamp.now(),
        });
      }
    }
    return pending;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKeyboardShortcuts);
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

    for (final pool in _viewPools()) {
      for (final rec in StockReader.batches(pool)) {
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

  void _processData() {
    if (_rawItems.isEmpty) {
      _groupedBatches = [];
      _filteredBatches = [];
      _displayItems = [];
      return;
    }
    final batches = _groupByBatch(_rawItems);
    _groupedBatches = batches;

    var preFiltered = batches.where((b) {
      final qty = (b['quantity'] as num?)?.toInt() ?? 0;
      if (qty < 0) return false;

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
    final icon = switch (t) {
      'Tablet' => FontAwesomeIcons.tablets,
      'Capsule' => FontAwesomeIcons.capsules,
      'Syrup' => FontAwesomeIcons.bottleDroplet,
      'Injection' => FontAwesomeIcons.syringe,
      'Infusion' => FontAwesomeIcons.bottleDroplet,
      'Drip' => FontAwesomeIcons.bottleDroplet,
      'Drip Set' => FontAwesomeIcons.kitMedical,
      'Syringe' => FontAwesomeIcons.syringe,
      'Cannula' => FontAwesomeIcons.kitMedical,
      'Needle' => FontAwesomeIcons.syringe,
      'Nebulization' => FontAwesomeIcons.wind,
      _ => FontAwesomeIcons.pills,
    };
    return Icon(icon, size: size, color: c);
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

      if (_mergeByFormula) {
        // Canonical formula resolution
        final rawForm = formula.isNotEmpty ? formula : name;
        final cleanForm = MasterProformaService.cleanBrandToFormula(rawForm).trim();
        final effFormula = cleanForm.isNotEmpty ? cleanForm : rawForm.trim();

        // Key groups strictly by normalized generic formula so same formula quantities merge together
        key = '${effFormula.toLowerCase().trim()}$campSuffix';
        displayFormula = effFormula;
        displayName = effFormula;
      } else {
        // Normal mode: separated by batch (monthYear) and item name
        key = '$name|$type|$dose|$monthYear$campSuffix';
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
    final cached = Hive.box(LocalStorageService.branchesBox).get('branch:${widget.branchId}');
    String bName = 'Branch';
    if (cached is Map) {
      bName = (cached['name'] as String?) ?? 'Branch';
    }
    if (_selectedCampFilter != null && _selectedCampFilter != 'all' && _selectedCampFilter!.isNotEmpty) {
      final campLabel = CampSessionService.getCampLabel(_selectedCampFilter!, widget.branchId);
      return '$bName ($campLabel)';
    }
    return bName;
  }

  Widget _buildMobileSubNav(BuildContext context) {
    final c = context.comfort;
    final List<Map<String, dynamic>> menuItems = _isDoctorUser
        ? [
            {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
          ]
        : [
            {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
            if (!_isSupervisorOrReadOnly) {'label': 'Update Stock', 'icon': Icons.add_box_rounded},
            if (_canRegisterMedicine) {'label': 'Register Medicine', 'icon': Icons.medication_liquid_rounded},
            if (!_isSupervisorUser) {'label': 'Proforma Sheet', 'icon': Icons.list_alt_rounded},
            {'label': 'Report', 'icon': Icons.receipt_long_rounded},
            {'label': 'Pending', 'icon': Icons.pending_actions_rounded},
            {'label': 'Log', 'icon': Icons.history_edu_rounded},
            {'label': 'History', 'icon': Icons.history_rounded},
          ];

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
    final List<Map<String, dynamic>> menuItems = _isDoctorUser
        ? [
            {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
          ]
        : [
            {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
            if (!_isSupervisorOrReadOnly) {'label': 'Update Stock', 'icon': Icons.add_box_rounded},
            if (_canRegisterMedicine) {'label': 'Register Medicine', 'icon': Icons.medication_liquid_rounded},
            if (!_isSupervisorUser) {'label': 'Proforma Sheet', 'icon': Icons.list_alt_rounded},
            {'label': 'Report', 'icon': Icons.receipt_long_rounded},
            {'label': 'Pending', 'icon': Icons.pending_actions_rounded},
            {'label': 'Log', 'icon': Icons.history_edu_rounded},
            {'label': 'History', 'icon': Icons.history_rounded},
          ];

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
                            branchId: widget.branchId,
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
                    children: [
                      _stockTab(),
                      if (!_isSupervisorUser && !_isDoctorUser) ...[
                        if (!_isSupervisorOrReadOnly)
                          InventoryUpdatePage(
                            branchId: widget.branchId,
                            isAdmin: widget.isAdmin,
                            isDispenser: widget.isDispenser,
                            isDoctor: widget.isDoctor,
                            isEmbedded: true,
                            showMode: 1,
                          ),
                        if (_canRegisterMedicine)
                          InventoryUpdatePage(
                            branchId: widget.branchId,
                            isAdmin: widget.isAdmin,
                            isDispenser: widget.isDispenser,
                            isDoctor: widget.isDoctor,
                            isEmbedded: true,
                            showMode: 2,
                          ),
                        UniversalProformaSheetPage(
                          branchId: widget.branchId,
                          isAdmin: widget.isAdmin,
                          isDispenser: widget.isDispenser,
                          isEmbedded: true,
                          onBackToInventory: () {
                            _tabCtrl.animateTo(0);
                            _loadDataFromHive();
                          },
                        ),
                        // Report: the medicine ledger + stock check results in one place.
                        StockReportPage(
                          branchId: widget.branchId,
                          isEmbedded: true,
                          canAdjust: !_isDoctorUser,
                        ),
                        _pendingTab(),
                        _logTab(),
                        _historyTab(),
                      ],
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

    final docIds = List<String>.from(batchData['_docIds'] as List? ?? []);
    debugPrint('[InventoryDelete] Dialog opened for medicine: ${batchData['name']} (DocIDs: $docIds)');

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Medicine From Inventory'),
        content: Text(
          'Are you sure you want to delete "${batchData['name']}" from inventory?\n\n'
          'Type: ${batchData['type'] ?? '—'}\n'
          'Dose: ${batchData['dose'] ?? '—'}\n'
          'Total Quantity: ${batchData['quantity'] ?? 0}\n\n'
          'This action is restricted to Chairman and HQ Manager.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_forever_rounded),
            style: FilledButton.styleFrom(backgroundColor: SoftPalette.red400),
            label: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) return;

    try {
      // Stock book: hide each batch behind this row (kept for history). StockActions sends
      // the change to the LAN server and the cloud.
      int deletedHiveCount = 0;
      for (final (pool, id) in _batchRefs(batchData)) {
        await StockActions.deleteBatch(pool, id);
        deletedHiveCount++;
      }

      // Refresh UI instantly
      if (mounted) {
        _loadDataFromHive();
        AppToast.clear();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('✅ "${batchData['name']}" deleted successfully ($deletedHiveCount items removed).'),
            backgroundColor: SoftPalette.green400,
            duration: const Duration(seconds: 3),
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
                  'Are you sure you want to permanently delete the ${selectedBatches.length} selected medicine batch(es) from inventory?\n\n'
                  '• They will be removed from local storage immediately.\n'
                  '• Real-time LAN deletion will notify all connected stations.\n'
                  '• Cloud Firestore documents will be permanently purged.\n',
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
              icon: const Icon(Icons.delete_forever_rounded, size: 18),
              label: Text(
                'Delete ${selectedBatches.length} Permanently',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    try {
      // Stock book: hide every batch behind the selected rows (kept for history).
      // StockActions sends each change to the LAN server and the cloud.
      int deletedHiveCount = 0;
      for (final batch in selectedBatches) {
        for (final (pool, id) in _batchRefs(batch)) {
          await StockActions.deleteBatch(pool, id);
          deletedHiveCount++;
        }
      }

      if (mounted) {
        setState(() {
          _isSelectMode = false;
          _selectedBatchKeys.clear();
        });
        _loadDataFromHive();
        AppToast.clear();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('✅ Successfully deleted ${selectedBatches.length} medicine(s) ($deletedHiveCount local records cleaned).'),
            backgroundColor: SoftPalette.green400,
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
          CampSelectorChip(
            branchId: widget.branchId,
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
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
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
              Icon(Icons.inventory_2_outlined, size: 64, color: _teal),
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
                'Stock for this branch has not been loaded or added yet. You can add medicines from the Universal Proforma or sync from cloud.',
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
                            builder: (_) => UniversalProformaSheetPage(
                              branchId: widget.branchId,
                              isAdmin: widget.isAdmin,
                              isDispenser: widget.isDispenser,
                            ),
                          ),
                        ).then((_) => _loadDataFromHive());
                      },
                      icon: const Icon(Icons.playlist_add_rounded, size: 18),
                      label: const Text('Add From Proforma'),
                    ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _teal,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      side: BorderSide(color: _teal),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      AppToast.showSnackBar(context, 
                        const SnackBar(content: Text('🔄 Restoring and syncing branch inventory from cloud & server...'), duration: Duration(seconds: 3)),
                      );
                      if (widget.branchId.toLowerCase().contains('karachi')) {
                        await LocalStorageService.restoreAndSyncKarachiInventory(widget.branchId);
                      } else {
                        await LocalStorageService.downloadInventory(widget.branchId, forceFull: true, campId: _selectedCampFilter);
                      }
                      if (mounted) {
                        _loadDataFromHive();
                        AppToast.showSnackBar(context, 
                          const SnackBar(content: Text('✅ Inventory sync complete.'), backgroundColor: SoftPalette.teal600, duration: Duration(seconds: 2)),
                        );
                      }
                    },
                    icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                    label: const Text('Sync Cloud'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildMetricsRow(_groupedBatches, GBreakpoint.isCompact(context)),
        _buildFilterSection(),
        if (_isSelectMode) _buildSelectionActionBar(),
        Expanded(
          child: LayoutBuilder(builder: (ctx, constraints) {
            return constraints.maxWidth > 640
                ? _stockTable(_displayItems, constraints.maxWidth, _filteredBatches.length, constraints.maxHeight)
                : _stockCards(_displayItems, _filteredBatches.length);
          }),
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
            icon: const Icon(Icons.delete_forever_rounded, size: 16, color: SoftPalette.gray50),
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
          _displayLimit = 50;
          _loadDataFromHive();
        });
        CampSessionService.setActiveCamp(campId, isManual: true);
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? c.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            color: isSelected ? c.onBrand : c.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildFilterSection() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final branchCamps = CampSessionService.getCampsForBranch(widget.branchId);
    final hasCamps = (widget.branchId.toLowerCase().contains('karachi') ||
            CampSessionService.hasCampsForBranch(widget.branchId) ||
            _canDeleteInventoryItem) &&
        branchCamps.isNotEmpty;
    final ctrlHeight = isCompact ? 34.0 : 38.0;

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
          style: TextStyle(fontSize: 13, color: c.textPrimary),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded, color: c.brand, size: 18),
            suffixIcon: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close_rounded, size: 16, color: c.textSecondary),
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
                ? 'Search formula, name or barcode...'
                : 'Search medicine, formula, or barcode...',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: isCompact ? 8 : 10),
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
                    builder: (_) => UniversalProformaSheetPage(
                      branchId: widget.branchId,
                      isDispenser: widget.isDispenser,
                      isAdmin: widget.isAdmin,
                    ),
                  ),
                );
                if (res == true) _loadDataFromHive();
              },
              icon: const Icon(FontAwesomeIcons.fileExcel, size: 13),
              label: Text('Proforma Sheet', style: labelStyle),
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
                  message: 'Download Inventory Checklist / Proforma PDF',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: c.surfaceSunken,
                      foregroundColor: c.brand,
                      side: BorderSide(color: c.brand.withValues(alpha: 0.45)),
                      padding: btnPad,
                      shape: shape,
                    ),
                    onPressed: _exportPdf,
                    icon: const Icon(Icons.picture_as_pdf_rounded, size: 15),
                    label: Text(isCompact ? 'Proforma PDF' : 'PDF', style: labelStyle),
                  ),
                ),
              ),
      );

      if (_canRegisterMedicine) {
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
                        branchId: widget.branchId,
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

      if (_canDeleteInventoryItem && _showRemoveAllMeds) {
        final isSpecificCampSelected = _selectedCampFilter != null && _selectedCampFilter != 'all';
        final campLabel = isSpecificCampSelected
            ? CampSessionService.getCampLabel(_selectedCampFilter!)
            : 'Camp';
        btns.add(
          SizedBox(
            height: ctrlHeight,
            child: ElevatedButton.icon(
              onPressed: _confirmRemoveAllMedsFromCurrentCamp,
              icon: const Icon(Icons.delete_sweep_rounded, size: 15),
              label: Text(
                isCompact
                    ? 'Clear Camp'
                    : (isSpecificCampSelected
                        ? 'Remove All Meds From $campLabel'
                        : 'Remove Camp Meds (Select Camp)'),
                style: labelStyle,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isSpecificCampSelected ? SoftPalette.red550 : SoftPalette.gray550,
                foregroundColor: SoftPalette.gray50,
                elevation: 0,
                padding: btnPad,
                shape: shape,
              ),
            ),
          ),
        );
      }

      if (_canDeleteInventoryItem) {
        btns.add(
          SizedBox(
            height: ctrlHeight,
            child: ElevatedButton.icon(
              onPressed: _syncInventoryFromCloud,
              icon: const Icon(Icons.cloud_download_rounded, size: 15),
              label: Text(isCompact ? 'Sync' : 'Sync / Restore Cloud', style: labelStyle),
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.slate600,
                foregroundColor: SoftPalette.gray50,
                elevation: 0,
                padding: btnPad,
                shape: shape,
              ),
            ),
          ),
        );

        btns.add(
          SizedBox(
            height: ctrlHeight,
            child: ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _isSelectMode = !_isSelectMode;
                  if (!_isSelectMode) _selectedBatchKeys.clear();
                });
              },
              icon: Icon(
                _isSelectMode ? Icons.close_rounded : Icons.checklist_rounded,
                size: 15,
              ),
              label: Text(
                _isSelectMode ? (isCompact ? 'Cancel' : 'Cancel Selection') : 'Select & Delete',
                style: labelStyle,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isSelectMode ? SoftPalette.slate700 : SoftPalette.red500,
                foregroundColor: SoftPalette.gray50,
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
      icon: Icons.category_outlined,
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
      icon: Icons.layers_outlined,
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
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 12,
        vertical: isCompact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
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
                const SizedBox(height: 8),
                if (hasCamps && !widget.isDoctor) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: buildCampBar(),
                  ),
                  const SizedBox(height: 8),
                ],
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      batchDropdown,
                      const SizedBox(width: 6),
                      _buildMergeFormulaCheckButton(isCompact: true),
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
                if (constraints.maxWidth >= 820) {
                  return Row(
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 150),
                          child: buildSearchField(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      typeDropdown,
                      const SizedBox(width: 6),
                      batchDropdown,
                      const SizedBox(width: 6),
                      _buildMergeFormulaCheckButton(isCompact: false),
                      if (hasCamps && !widget.isDoctor) ...[
                        const SizedBox(width: 6),
                        buildCampBar(),
                      ],
                      for (final btn in buildActionButtons()) ...[
                        const SizedBox(width: 6),
                        btn,
                      ],
                    ],
                  );
                }
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(width: 220, child: buildSearchField()),
                    typeDropdown,
                    batchDropdown,
                    _buildMergeFormulaCheckButton(isCompact: false),
                    if (hasCamps && !widget.isDoctor) buildCampBar(),
                    ...buildActionButtons(),
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
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: isCompact ? 34 : 38,
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10),
          decoration: BoxDecoration(
            color: _mergeByFormula ? c.brandSoft : c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
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
                size: isCompact ? 16 : 17,
                color: _mergeByFormula ? c.brand : c.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Merge Formula',
                style: TextStyle(
                  fontSize: isCompact ? 11.5 : 12.5,
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
    AppToast.showSnackBar(context, 
      const SnackBar(
        content: Text('🔄 Downloading & restoring inventory from Firestore...'),
        duration: Duration(seconds: 2),
      ),
    );
    await LocalStorageService.downloadInventory(widget.branchId, forceFull: true, campId: _selectedCampFilter);
    if (mounted) {
      _loadDataFromHive();
      AppToast.showSnackBar(context, 
        SnackBar(
          content: Text('✅ Inventory restored successfully! Showing ${_displayItems.length} records.'),
          backgroundColor: SoftPalette.green400,
        ),
      );
    }
  }

  Future<void> _confirmRemoveAllMedsFromCurrentCamp() async {
    final activeCamp = _selectedCampFilter ?? CampSessionService.getActiveCamp(widget.branchId);

    // SAFETY GUARD: Prevent clearing all camps simultaneously!
    if (activeCamp == null || activeCamp == 'all' || activeCamp.isEmpty) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: SoftPalette.amber200, size: 28),
              SizedBox(width: 10),
              Text('Select a Specific Camp'),
            ],
          ),
          content: const Text(
            'To protect inventory from accidental total deletion, please click on a specific camp first:\n\n'
            '👉 "📍 Haji Camp" or "📍 Saddar"\n\n'
            'Then tap "Remove All Meds From [Camp]". This ensures ONLY that camp is deleted while preserving the other camp\'s stock completely.',
            style: TextStyle(fontSize: 13.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      return;
    }

    final campLabel = CampSessionService.getCampLabel(activeCamp);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: SoftPalette.red400, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete $campLabel Meds',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          '⚠️ WARNING: You are about to permanently delete all medicines assigned ONLY to:\n\n'
          '👉 "$campLabel"\n\n'
          '• Local database records for $campLabel will be erased in 0ms.\n'
          '• Real-time LAN deletion will notify all connected stations.\n'
          '• Cloud Firestore documents for $campLabel will be purged from database.\n'
          '• Other camps (such as Saddar) will remain completely intact.\n\n'
          'Are you sure you want to proceed?',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red500, foregroundColor: SoftPalette.gray50),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: Text('Yes, Delete $campLabel Meds', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      // Stock book: hide every batch of this camp's pool only (kept for history). Other
      // camps are separate pools and stay untouched. StockActions sends each change to the
      // LAN server and the cloud.
      final pool = StockPool.of(_effectiveBranchId, activeCamp);
      if (pool == null || !pool.hasCamp) {
        throw 'Could not work out the stock place for "$campLabel". Choose a camp first.';
      }
      var count = 0;
      for (final rec in StockLedger.items(pool: pool.key)) {
        final id = (rec['medicineId'] ?? rec['id'] ?? '').toString();
        if (id.isEmpty) continue;
        await StockActions.deleteBatch(pool, id);
        count++;
      }

      if (mounted) {
        _loadDataFromHive();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('✅ Removed $count medicine record(s) from $campLabel (Local & Cloud).'),
            backgroundColor: SoftPalette.green400,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Failed to clear camp meds: $e'), backgroundColor: SoftPalette.red400),
        );
      }
    }
  }

  Widget _buildUpdateStockButton() {
    return ElevatedButton.icon(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InventoryUpdatePage(
            branchId: widget.branchId,
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
    final totalStockQty = batches.fold<int>(0, (sum, b) => sum + (b['quantity'] as int));

    final numberFormat = NumberFormat('#,###');

    final card1 = _buildMetricItem(
      Icons.medication_outlined,
      c.brand,
      c.brandSoft,
      '$totalMedicines',
      'Formulas',
      onTap: _resetFilters,
    );
    final card2 = _buildMetricItem(
      Icons.inventory_2_outlined,
      c.info,
      c.infoBg,
      numberFormat.format(totalStockQty),
      'Total Units',
      onTap: _resetFilters,
    );
    final card3 = _buildMetricItem(
      Icons.warning_amber_rounded,
      c.danger,
      c.dangerBg,
      '$lowStockCount',
      'Low Stock',
      onTap: _applyLowStockSort,
    );
    final card4 = _buildMetricItem(
      Icons.event_busy_rounded,
      c.warning,
      c.warningBg,
      '$expiringSoonCount',
      'Expiring Soon',
      onTap: _applyExpirySort,
    );

    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: card1),
                const SizedBox(width: 8),
                Expanded(child: card2),
              ],
            ),
            const SizedBox(height: 8),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: bgTint,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accentColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: _isDark ? 0.22 : 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accentColor, size: 18),
              ),
              const SizedBox(width: 12),
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
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 11.5,
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

  // ── Stock Table (wide screens) ─────────────────────────────────────────────
  Widget _stockTable(
      List<Map<String, dynamic>> data, double screenWidth, int totalCount, [double? availableHeight]) {
    final c = context.comfort;
    final double cardInnerWidth = screenWidth - 32;
    final double w = cardInnerWidth < 1000 ? 1000 : cardInnerWidth;
    
    final cols = [
      _Col('#', w * 0.04, null),
      _Col('Formula', w * 0.35, 'name'),
      _Col('Barcode', w * 0.15, null),
      _Col('Type', w * 0.12, null),
      _Col('Dose', w * 0.12, 'dose'),
      _Col('Qty', w * 0.08, 'quantity'),
      _Col('Expiry', w * 0.14, 'expiry'),
    ];

    Widget buildTableRow(int i) {
      if (i == data.length) {
        return Container(
          width: w,
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          color: c.surface,
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
      final qty = b['quantity'] as int;
      final type = b['type'] as String;
      final barcode = (b['barcode'] ?? b['rollNo'] ?? '').toString().trim();
      final itemCode = (b['code'] ?? b['itemCode'] ?? '').toString().trim();
      final packBarcode = (b['packBarcode'] ?? '').toString().trim();
      final lowStock = qty < 10;
      final expSoon = _isExpiringSoon(b['expiryDate'] as String?);
      final expText = _formatDate(b['expiryDate'] as String?);
      final isWarning = lowStock || expSoon;
      final rowColor = isSelected
          ? c.dangerBg
          : (isWarning
              ? c.dangerBg.withValues(alpha: _isDark ? 0.25 : 0.45)
              : (i.isEven ? c.surface : c.surfaceSunken.withValues(alpha: 0.4)));

      final rowContent = Container(
        decoration: BoxDecoration(
          color: rowColor,
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? c.danger
                  : (isWarning ? c.danger.withValues(alpha: 0.25) : c.border),
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
        ),
        child: Stack(
          children: [
            if (_canDeleteInventoryItem && !_isSelectMode)
              Positioned(
                right: 10,
                top: 6,
                child: Tooltip(
                  message: 'Delete medicine from inventory',
                  child: InkWell(
                    onTap: () => _showDeleteInventoryDialog(b),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: c.dangerBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
                      ),
                      child: Icon(Icons.delete_forever_rounded, size: 15, color: c.danger),
                    ),
                  ),
                ),
              )
            else if (_isDoctorUser && !_isSelectMode)
              Positioned(
                right: 10,
                top: 5,
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
                          Icon(Icons.notification_important_rounded, size: 14, color: c.warning),
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
              ),
            Row(children: [
              _dCell(
                  cols[0].w,
                  _isSelectMode
                      ? Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: isSelected,
                              activeColor: c.danger,
                              onChanged: (_) => _toggleSelectItem(batchKey),
                            ),
                          ),
                        )
                      : Text('${i + 1}',
                          style: TextStyle(color: c.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w700))),
              _dCell(
                  cols[1].w,
                  RichText(
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: TextStyle(fontSize: 13, color: c.textPrimary),
                      children: [
                        TextSpan(
                          text: b['name'] ?? '',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: isWarning ? c.danger : c.textPrimary,
                          ),
                        ),
                        if (b['formula'] != null && (b['formula'] as String).isNotEmpty) ...[
                          const TextSpan(text: ' '),
                          TextSpan(
                            text: '(${b['formula']})',
                            style: TextStyle(
                              color: isWarning ? c.danger.withValues(alpha: 0.8) : c.textSecondary,
                              fontWeight: FontWeight.normal,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )),
              _dCell(cols[2].w, _barcodeCell(barcode, itemCode: itemCode, packBarcode: packBarcode)),
              _dCell(cols[3].w, _typePill(type)),
              _dCell(
                  cols[4].w,
                  Text(b['dose'] ?? '—',
                      style: TextStyle(color: c.textSecondary, fontSize: 12.5))),
              _dCell(
                  cols[5].w,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(NumberFormat('#,###').format(qty),
                          style: TextStyle(
                              color: lowStock ? c.danger : c.textPrimary,
                              fontWeight: lowStock ? FontWeight.w700 : FontWeight.w600,
                              fontSize: 12.5)),
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
                  )),
              _dCell(
                  cols[6].w,
                  Text(
                    b['hasMultipleExpiries'] == true ? '$expText (Earliest)' : expText,
                    style: TextStyle(
                        color: expSoon ? c.danger : c.textSecondary,
                        fontWeight: expSoon ? FontWeight.w700 : FontWeight.normal,
                        fontSize: 12.5))),
            ]),
          ],
        ),
      );

      void Function()? handleTap;
      if (_isSelectMode) {
        handleTap = () => _toggleSelectItem(batchKey);
      } else if (_isDoctorUser) {
        handleTap = () { _requestRestock(b); };
      } else if (_isDirectEditAllowed) {
        handleTap = () { _showEditSheet(b); };
      } else {
        handleTap = () {
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

      return InkWell(
        onTap: handleTap,
        hoverColor: c.surfaceSunken,
        child: rowContent,
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final tableContent = Column(
            children: [
              Container(
                height: 40,
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
                          height: 40,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: 22,
                            height: 22,
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
                      return _hCell(col.w, col.label, col.sort);
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
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(
                          message: 'Delete medicine from inventory',
                          child: InkWell(
                            onTap: () => _showDeleteInventoryDialog(b),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: c.dangerBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: c.danger.withValues(alpha: 0.3)),
                              ),
                              child: Icon(Icons.delete_forever_rounded, size: 15, color: c.danger),
                            ),
                          ),
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
              border: Border.all(color: c.brand.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.qr_code_rounded, size: 12, color: c.brandStrong),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  barcode,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.brandStrong, fontSize: 11, fontWeight: FontWeight.w700),
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
        branchId: widget.branchId,
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



  // ── Pending Tab ───────────────────────────────────────────────────────────
  Widget _pendingTab() => FutureBuilder<QuerySnapshot>(
        future: FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .where('status', isEqualTo: 'pending')
            .get(const GetOptions(source: Source.serverAndCache)),
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
            return _emptyState(Icons.pending_actions_rounded,
                'No pending edit requests');
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

  // ── Log Tab (Merged Cloud + Local Pending) ──────────────────────────────
  Widget _logTab() => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _logState.stream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
                child: CircularProgressIndicator(color: _teal));
          }
          
          final list = snap.data ?? [];
          if (list.isEmpty) {
            return _emptyState(Icons.history_edu_rounded,
                'No activity yet.\nStock updates will appear here.');
          }

          final sorted = list..sort((a, b) {
            final tsA = a['timestamp'] as Timestamp;
            final tsB = b['timestamp'] as Timestamp;
            return tsB.compareTo(tsA);
          });

          return ListView.builder(
            padding: const EdgeInsets.all(14),
            itemCount: sorted.length,
            itemBuilder: (ctx, i) {
              return _logCard(sorted[i]);
            },
          );
        },
      );

  Widget _logCard(Map<String, dynamic> data) {
    final c = context.comfort;
    final action = data['action']?.toString() ?? '';
    final medicineName = data['medicineName']?.toString() ?? '—';
    final medicineType = data['medicineType']?.toString() ?? '';
    final dose = data['dose']?.toString() ?? '';
    final qtyAdded = data['quantityAdded'] ?? 0;
    final performedBy = data['performedByName']?.toString() ?? 'Unknown';
    final ts = data['timestamp'] as Timestamp?;
    final price = data['price']?.toString() ?? '';
    final expiry = data['expiryDate']?.toString() ?? '';

    final isRegistration = action == 'medicine_registered' ||
        action == 'medicine_registered_directly';
    final isEdited = action == 'medicine_edited';
    final Color accentColor = isEdited ? c.info : (isRegistration ? c.brand : c.success);
    final IconData actionIcon = isEdited
        ? Icons.edit_rounded
        : (isRegistration ? Icons.medication_liquid_rounded : Icons.add_box_rounded);
    final String actionLabel = isEdited
        ? 'MEDICINE EDITED'
        : (isRegistration ? 'NEW MEDICINE' : 'STOCK ADDED');
    final Color labelBg = isEdited ? c.infoBg : (isRegistration ? c.brandSoft : c.successBg);
    final Color labelFg = isEdited ? c.info : (isRegistration ? c.brandStrong : c.success);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: labelBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(actionIcon, color: accentColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: labelBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(actionLabel,
                    style: TextStyle(
                        color: labelFg,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
              if (data['_isPending'] == true) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.warningBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.warning.withValues(alpha: 0.35)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bolt_rounded, size: 10, color: c.warning),
                    const SizedBox(width: 3),
                    Text('PENDING SYNC',
                        style: TextStyle(
                            color: c.warning,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4)),
                  ]),
                ),
              ],
            ]),
            const SizedBox(height: 6),
            Text(medicineName,
                style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 5, children: [
              if (medicineType.isNotEmpty)
                _miniChip(medicineType, c.brandStrong),
              if (dose.isNotEmpty) _miniChip(dose, c.textSecondary),
              _miniChip('+$qtyAdded units', accentColor),
              if (isRegistration && price.isNotEmpty)
                _miniChip('PKR $price', c.warning),
              if (isRegistration && expiry.isNotEmpty)
                _miniChip('Exp: ${_formatDate(expiry)}', c.textSecondary),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.person_outline_rounded,
                  size: 13, color: c.textMuted),
              const SizedBox(width: 5),
              Text(performedBy,
                  style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (ts != null) ...[
                const SizedBox(width: 10),
                Icon(Icons.access_time_rounded,
                    size: 12, color: c.textMuted),
                const SizedBox(width: 4),
                Text(
                  DateFormat('dd MMM yyyy, hh:mm a').format(ts.toDate()),
                  style: TextStyle(
                      color: c.textMuted, fontSize: 11),
                ),
              ]
            ]),
          ])),
        ]),
      ),
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

  Widget _historyList(String status) => FutureBuilder<QuerySnapshot>(
        future: FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .where('status', isEqualTo: status)
            .get(const GetOptions(source: Source.serverAndCache)),
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
                'No $status edit requests');
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

    final isKarachi = CampSessionService.isKarachiFamily(widget.branchId);
    return (_selectedCampFilter != null && _selectedCampFilter != 'all')
        ? CampSessionService.getCampLabel(_selectedCampFilter!, widget.branchId)
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
    return StockPool.of(_effectiveBranchId, camp, fallbackCamp: CampSessionService.getActiveCamp(widget.branchId));
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

  Widget _hCell(double w, String label, String? sort) {
    final c = context.comfort;
    final active = _sortField == sort;
    return InkWell(
      onTap: sort != null ? () => _sort(sort) : null,
      child: Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          Text(label,
              style: TextStyle(
                  color: active ? c.brand : c.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 0.2)),
          if (active) ...[
            const SizedBox(width: 4),
            Icon(
                _isAscending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 13,
                color: c.brand),
          ],
        ]),
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
    final color = _isDark ? _darkTypeColor(type) : _typeColor(type);
    final bg = _isDark ? color.withValues(alpha: 0.18) : color.withValues(alpha: 0.12);
    final border = _isDark ? color.withValues(alpha: 0.45) : color.withValues(alpha: 0.35);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _typeIconWidget(type, size: 10, color: color),
        const SizedBox(width: 4),
        Flexible(
            child: Text(type,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold))),
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
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
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

  Widget _emptyState(IconData icon, String msg) => Center(
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 72, color: context.adapt(SoftPalette.gray150)),
          const SizedBox(height: 14),
          Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.adapt(_textLight), fontSize: 15)),
        ]),
      );
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
        Form(
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
              Column(
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
              ]),
              const SizedBox(height: 12),
              _field(
                controller: _doseCtrl,
                label: 'Dose (e.g. 500mg, 5ml)',
                icon: Icons.vaccines_rounded,
              ),
              const SizedBox(height: 12),
              Builder(builder: (context) {
                const canEditBarcode = true;
                return _field(
                  controller: _barcodeCtrl,
                  label: 'Proforma Barcode (001–999)',
                  icon: Icons.qr_code_rounded,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  enabled: canEditBarcode,
                );
              }),
              const SizedBox(height: 12),
              _field(
                controller: _packBarcodeCtrl,
                label: 'Pack Barcode (Optional)',
                icon: Icons.qr_code_scanner_rounded,
                keyboardType: TextInputType.text,
              ),
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
              ),
              const SizedBox(height: 24),
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
  const _Col(this.label, this.w, this.sort);
}