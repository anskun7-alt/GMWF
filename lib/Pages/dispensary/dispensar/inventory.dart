// lib/pages/dispensary/dispensar/inventory.dart

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
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/widgets/global_module_wrapper.dart';
import 'package:gmwf/widgets/app_back_button.dart';
import 'package:gmwf/widgets/camp_selector_chip.dart';
import 'package:gmwf/utils/string_similarity_helper.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/sync_service.dart';
import 'inventory_pdf_helper.dart';

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

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // ── Palette ───────────────────────────────────────────────────────────────
  static const _teal = Color(0xFF00695C);
  static const _tealDark = Color(0xFF004D40);
  static const _bg = Color(0xFFF1F8F6);
  static const _white = Colors.white;
  static const _green50 = Color(0xFFE8F5E9);
  static const _green100 = Color(0xFFC8E6C9);
  static const _green600 = Color(0xFF2E7D32);
  static const _red = Color(0xFFD32F2F); // More vibrant, premium red
  static const _orange = Color(0xFFE65100);
  static const _amber = Color(0xFFF57F17);
  static const _blue = Color(0xFF1976D2);
  static const _purple = Color(0xFF6A1B9A);
  static const _indigo = Color(0xFF283593);
  static const _brown = Color(0xFF4E342E);
  static const _textDark = Color(0xFF1B2631);
  static const _textMid = Color(0xFF4A5568);
  static const _textLight = Color(0xFF718096);
  static const _border = Color(0xFFB2DFDB);
  static const _shadow = Color(0x1800695C);

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
  bool get _isSupervisorOrReadOnly => _isSupervisorUser || widget.isReadOnly;

  /// Direct edit is strictly reserved for Doctors, Admins, Global Admins, Chairmen, HQ Managers & Supervisors.
  /// Dispensers are explicitly barred from direct edits and must use "Update Stock" for approval.
  /// Direct edit is strictly reserved for Doctors, Admins, Global Admins, Chairmen, HQ Managers & Supervisors.
  /// Dispensers are explicitly barred from direct edits and must use "Update Stock" for approval.
  bool get _isDirectEditAllowed {
    if (widget.isReadOnly) return false;
    if (widget.isDispenser) return false;
    return widget.isAdmin || widget.isDoctor || widget.isSupervisor;
  }

  bool get _canRegisterMedicine {
    if (widget.isReadOnly) return false;
    return true;
  }

  static const _editRequestTypes = {'edit_medicine', 'delete_medicine'};

  static Color _typeColor(String t) => switch (t) {
        'Tablet' => const Color(0xFF1565C0),
        'Capsule' => const Color(0xFF6A1B9A),
        'Syrup' => const Color(0xFFF57F17),
        'Injection' => const Color(0xFFC62828),
        'Infusion' => const Color(0xFF00695C),
        'Drip' => const Color(0xFF00695C),
        'Drip Set' => const Color(0xFF00838F),
        'Syringe' => const Color(0xFFAD1457),
        'Cannula' => const Color(0xFFD81B60),
        'Needle' => const Color(0xFF8E24AA),
        'Nebulization' => const Color(0xFF283593),
        'Dressing Item' => const Color(0xFF455A64),
        'Consumables' => const Color(0xFF00796B),
        _ => const Color(0xFF37474F),
      };

  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  String _filterType = 'All';
  String _filterBatch = 'All Batches';
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

  bool _handleKeyboardShortcuts(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      if (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.delete) {
        setState(() {
          _showRemoveAllMeds = !_showRemoveAllMeds;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _showRemoveAllMeds
                    ? '🔓 "Remove All Meds" button unlocked and visible.'
                    : '🔒 "Remove All Meds" button hidden.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              duration: const Duration(seconds: 2),
              backgroundColor: _showRemoveAllMeds ? Colors.red.shade800 : Colors.blueGrey.shade800,
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
    int tabCount = 6; // Stock, Proforma, Ledger, Pending, Log, History
    if (_isSupervisorUser) {
      tabCount = 1;
    } else {
      if (!_isSupervisorOrReadOnly) tabCount++; // Update Stock
      if (_canRegisterMedicine) tabCount++; // Register Medicine
    }
    _tabCtrl = TabController(length: tabCount, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted && !_tabCtrl.indexIsChanging) {
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
    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      Hive.box(LocalStorageService.stockBox).listenable().addListener(_debouncedLoadDataFromHive);
      _loadDataFromHive();
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          box.listenable().addListener(_debouncedLoadDataFromHive);
          _loadDataFromHive();
        }
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
    if (active != null && active.isNotEmpty && active != 'all' && active != _selectedCampFilter) {
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
    if (b.isNotEmpty && b != 'all' && b != 'unknown') return b;
    final active = LocalStorageService.getActiveBranchId();
    if (active != null && active.isNotEmpty && active != 'all') return active.toLowerCase().trim();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final saved = Hive.box('app_settings').get('selected_branch');
        if (saved != null && saved.toString().isNotEmpty && saved != 'all') {
          return saved.toString().toLowerCase().trim();
        }
      }
    } catch (_) {}
    return 'karachi';
  }

  void _initSync() {
    // Inventory is driven 100% locally from Hive stockBox + LAN sync events.
    // Zero continuous Firestore listeners.
    try {
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        final localSyncStream = Hive.box(LocalStorageService.syncBox)
            .watch()
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
        ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Refreshing inventory from cloud...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      await LocalStorageService.downloadInventory(effBranch, forceFull: true, campId: activeCamp);
      if (mounted) {
        _loadDataFromHive();
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Inventory cloud sync complete.'),
              backgroundColor: Color(0xFF00695C),
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
      final item = Map<String, dynamic>.from(box.get(key) as Map);
      final type = item['type']?.toString();
      if (type == 'add_inventory_stock' || type == 'register_medicine') {
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
    HardwareKeyboard.instance.removeHandler(_handleKeyboardShortcuts);
    _debounceLoadTimer?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    RealtimeManager.isLanHealthyNotifier.removeListener(_onLanHealthChanged);
    try {
      if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
        Hive.box(LocalStorageService.stockBox).listenable().removeListener(_debouncedLoadDataFromHive);
      }
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

  void _debouncedLoadDataFromHive() {
    _debounceLoadTimer?.cancel();
    _debounceLoadTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _loadDataFromHive();
    });
  }

  void _loadDataFromHive() {
    final box = Hive.box(LocalStorageService.stockBox);
    final normBranch = widget.branchId.toLowerCase().trim();
    final allMapDocs = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final m = Map<String, dynamic>.from(val);
        if (m['id'] == null || m['id'].toString().isEmpty || m['id'] == 'unknown') {
          final kStr = key.toString();
          m['id'] = kStr.startsWith('stock:') ? kStr.substring(6) : kStr;
        }

        // Auto-normalize medicine name & formula to latest master catalog for unedited items
        final isCustom = m['isCustomized'] == true || m['userEdited'] == true;
        if (!isCustom) {
          final rawName = (m['name'] ?? m['formula'] ?? '').toString();
          final cleanName = MasterProformaService.cleanBrandToFormula(rawName);
          if (cleanName.isNotEmpty) {
            m['name'] = cleanName;
            m['formula'] = cleanName;
          }
        }

        // Auto-normalize Kapayya/Kapaya camp to Saddar
        final rawCamp = (m['campId'] ?? m['dispensaryId'] ?? '').toString().toLowerCase();
        final rawId = m['id'].toString().toLowerCase();
        if (rawCamp.contains('kapay') || rawCamp == 'kapayya' || rawCamp == 'kapaya' || rawId.startsWith('kapay')) {
          m['campId'] = 'saddar';
          m['dispensaryId'] = 'saddar';
        }

        allMapDocs.add(m);
      }
    }

    var filtered = allMapDocs.where((v) {
      if (normBranch == 'all' || normBranch.isEmpty) return true;
      final b = v['branchId']?.toString().toLowerCase().trim();
      if (b == null || b.isEmpty) return true; // Branch stock fallback
      return b == normBranch ||
          b == 'branch_$normBranch' ||
          'branch_$b' == normBranch ||
          (normBranch.isNotEmpty && b.contains(normBranch)) ||
          (b.isNotEmpty && normBranch.contains(b));
    }).toList();

    if (CampSessionService.hasCampsForBranch(widget.branchId) || widget.branchId.toLowerCase().contains('karachi')) {
      final activeCamp = _selectedCampFilter ?? 'all';

      if (activeCamp.isNotEmpty && activeCamp != 'all') {
        filtered = filtered.where((v) {
          return CampSessionService.matchesCamp(
            selectedCamp: activeCamp,
            dispensaryId: v['dispensaryId']?.toString(),
            campId: v['campId']?.toString(),
            dispensaryTag: v['dispensaryTag']?.toString(),
            serial: (v['barcode'] ?? v['code'] ?? v['id'])?.toString(),
          );
        }).toList();
      }
    }

    if (mounted) {
      setState(() {
        _rawItems = filtered;
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
      final type = b['type'];
      final query = _searchCtrl.text.trim().toLowerCase();
      return (name.contains(query) || formula.contains(query) || barcode.contains(query)) &&
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
        ScaffoldMessenger.of(context).showSnackBar(
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
      final type = data['type'] ?? '';
      final dose = (data['dose'] ?? '').toString().trim();
      final expiry = data['expiryDate']?.toString().trim() ?? '';
      final qty = _asInt(data['quantity']);
      final price = _parsePrice(data['price']);
      final formula = (data['formula'] ?? '').toString().trim();
      final barcode = (data['barcode'] ?? data['code'] ?? '').toString().trim();

      String monthYear = '';
      if (expiry.length == 10 && expiry[2] == '-' && expiry[5] == '-') {
        monthYear = expiry.substring(3);
      } else {
        monthYear = expiry;
      }

      String doseDisplay = dose;
      if (type == 'Nebulization' && dose.isEmpty) doseDisplay = 'per session';

      final key = '$name|$type|$dose|$monthYear';
      if (map.containsKey(key)) {
        map[key]!['quantity'] = (map[key]!['quantity'] as int) + qty;
        (map[key]!['_docIds'] as List<String>).add(data['id'] ?? data['medicineId'] ?? 'unknown');
        // Keep the first non-empty barcode found for this batch
        if ((map[key]!['barcode'] as String? ?? '').isEmpty && barcode.isNotEmpty) {
          map[key]!['barcode'] = barcode;
        }
      } else {
        map[key] = {
          'name': name,
          'type': type,
          'dose': doseDisplay,
          'formula': formula,
          'barcode': barcode,
          'expiryDate': monthYear,
          'quantity': qty,
          'price': price,
          'batchKey': key,
          '_docIds': <String>[data['id'] ?? data['medicineId'] ?? 'unknown'],
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
    final List<Map<String, dynamic>> menuItems = [
      {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
      if (!_isSupervisorOrReadOnly) {'label': 'Update Stock', 'icon': Icons.add_box_rounded},
      if (_canRegisterMedicine) {'label': 'Register Medicine', 'icon': Icons.medication_liquid_rounded},
      if (!_isSupervisorUser) {'label': 'Proforma Sheet', 'icon': Icons.list_alt_rounded},
      {'label': 'Ledger', 'icon': Icons.receipt_long_rounded},
      {'label': 'Pending', 'icon': Icons.pending_actions_rounded},
      {'label': 'Log', 'icon': Icons.history_edu_rounded},
      {'label': 'History', 'icon': Icons.history_rounded},
    ];

    final branchCamps = CampSessionService.getCampsForBranch(widget.branchId);
    final hasCamps = (widget.branchId.toLowerCase().contains('karachi') ||
        CampSessionService.hasCampsForBranch(widget.branchId) ||
        _canDeleteInventoryItem) && branchCamps.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tabs
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: _isDark ? const Color(0xFF1E293B) : Colors.white,
            border: Border(
              bottom: BorderSide(
                color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                width: 1,
              ),
            ),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isActive
                        ? (_isDark ? const Color(0xFF0F766E) : _teal)
                        : (_isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isActive ? (_isDark ? const Color(0xFF14B8A6) : _teal) : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item['icon'] as IconData,
                        size: 13,
                        color: isActive ? Colors.white : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        item['label'] as String,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                          color: isActive ? Colors.white : (_isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

      ],
    );
  }

  Widget _buildSidebarContent(BuildContext context) {
    final List<Map<String, dynamic>> menuItems = [
      {'label': 'Stock', 'icon': Icons.inventory_2_rounded},
      if (!_isSupervisorOrReadOnly) {'label': 'Update Stock', 'icon': Icons.add_box_rounded},
      if (_canRegisterMedicine) {'label': 'Register Medicine', 'icon': Icons.medication_liquid_rounded},
      if (!_isSupervisorUser) {'label': 'Proforma Sheet', 'icon': Icons.list_alt_rounded},
      {'label': 'Ledger', 'icon': Icons.receipt_long_rounded},
      {'label': 'Pending', 'icon': Icons.pending_actions_rounded},
      {'label': 'Log', 'icon': Icons.history_edu_rounded},
      {'label': 'History', 'icon': Icons.history_rounded},
    ];

    return Container(
      color: _isDark ? const Color(0xFF1E293B) : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: Row(
              children: [
                Image.asset(
                  'assets/logo/gmwf-1.webp',
                  width: 42,
                  height: 42,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _teal,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(FontAwesomeIcons.pills, color: Colors.white, size: 16),
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
                          color: _isDark ? Colors.white : _tealDark,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        '${_getBranchName()} Inventory',
                        style: TextStyle(
                          color: _isDark ? const Color(0xFF94A3B8) : _textLight,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: _isDark ? const Color(0xFF334155) : null),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: menuItems.length,
              itemBuilder: (context, index) {
                final item = menuItems[index];
                final isActive = _tabCtrl.index == index;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: isActive
                        ? (_isDark ? const Color(0xFF0F766E) : _teal)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: InkWell(
                    onTap: () {
                      _tabCtrl.animateTo(index);
                      if (MediaQuery.of(context).size.width < 800) {
                        Navigator.of(context).maybePop();
                      } else {
                        if (mounted) setState(() {});
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            item['icon'] as IconData,
                            color: isActive
                                ? Colors.white
                                : (_isDark ? const Color(0xFF94A3B8) : _textMid),
                            size: 16,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            item['label'] as String,
                            style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : (_isDark ? const Color(0xFFCBD5E1) : _textDark),
                              fontSize: 13,
                              fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
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
          Divider(height: 1, color: _isDark ? const Color(0xFF334155) : null),
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _isDark ? const Color(0xFF0F766E).withValues(alpha: 0.2) : _teal.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.store_rounded, color: _isDark ? const Color(0xFF38BDF8) : _teal, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getBranchName(),
                        style: TextStyle(
                          color: _isDark ? Colors.white : _textDark,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'v2.6.1',
                        style: TextStyle(
                          color: _isDark ? const Color(0xFF64748B) : _textLight,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bool isWrapped = GlobalModuleWrapper.isWrapped(context);
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth < 800;

    if (_isSupervisorUser) {
      return Scaffold(
        backgroundColor: _isDark ? const Color(0xFF0F172A) : _bg,
        appBar: (!widget.isEmbedded && !isWrapped) ? _buildAppBar(isMobile: isMobile) : null,
        body: _stockTab(),
      );
    }

    return Scaffold(
      backgroundColor: _isDark ? const Color(0xFF0F172A) : _bg,
      appBar: (!widget.isEmbedded && !isWrapped) ? _buildAppBar(isMobile: isMobile) : null,
      drawer: (isMobile && !widget.isDispenser) ? Drawer(
        backgroundColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
        child: _buildSidebarContent(context),
      ) : null,
      floatingActionButton: (_isSupervisorOrReadOnly || widget.isAdmin || screenWidth > 800)
          ? null
          : FloatingActionButton.extended(
              backgroundColor: _teal,
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => InventoryUpdatePage(
                            branchId: widget.branchId,
                            isAdmin: widget.isAdmin,
                            isDispenser: widget.isDispenser,
                            isDoctor: widget.isDoctor,
                          ))),
              icon: const Icon(Icons.add_rounded, color: Colors.white),
              label: const Text('Update Stock',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
      body: Row(
        children: [
          if (!isMobile)
            Container(
              width: 220,
              decoration: BoxDecoration(
                color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                border: Border(right: BorderSide(color: _isDark ? const Color(0xFF334155) : Colors.grey.shade200, width: 1)),
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
                      MedicineLedgerPage(
                        branchId: widget.branchId,
                        isEmbedded: true,
                      ),
                      _pendingTab(),
                      _logTab(),
                      _historyTab(),
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

  Widget _buildInternalActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 12, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the Chairman and HQ Manager can delete medicines from inventory.'),
          backgroundColor: Colors.red,
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            label: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) return;

    try {
      final activeCamp = (_selectedCampFilter != null && _selectedCampFilter!.isNotEmpty && _selectedCampFilter != 'all')
          ? _selectedCampFilter!
          : (CampSessionService.getActiveCamp(widget.branchId) ?? 'all');

      // 1. Delete from local Hive cache FIRST (instant 0ms response)
      final box = Hive.box(LocalStorageService.stockBox);
      int deletedHiveCount = 0;
      final targetBatchName = (batchData['name'] ?? '').toString().toLowerCase().trim();
      final targetBatchType = (batchData['type'] ?? '').toString().toLowerCase().trim();
      final targetBatchDose = (batchData['dose'] ?? '').toString().toLowerCase().trim();

      final keysToRemove = <dynamic>{};

      for (final id in docIds) {
        if (id.isNotEmpty && id != 'unknown') {
          keysToRemove.add('stock:$id');
          keysToRemove.add(id);
        }
      }

      for (final k in box.keys) {
        final kStr = k.toString().toLowerCase();
        for (final id in docIds) {
          if (id.isNotEmpty && id != 'unknown') {
            if (kStr == id.toLowerCase() || kStr == 'stock:${id.toLowerCase()}' || kStr.endsWith(':${id.toLowerCase()}')) {
              keysToRemove.add(k);
            }
          }
        }
        final val = box.get(k);
        if (val is Map) {
          final vName = (val['name'] ?? '').toString().toLowerCase().trim();
          final vType = (val['type'] ?? '').toString().toLowerCase().trim();
          final vDose = (val['dose'] ?? '').toString().toLowerCase().trim();
          if (vName == targetBatchName && vType == targetBatchType && (targetBatchDose.isEmpty || vDose == targetBatchDose)) {
            keysToRemove.add(k);
          }
        }
      }

      for (final k in keysToRemove) {
        await box.delete(k);
        deletedHiveCount++;
      }
      await box.flush();

      // Refresh UI instantly
      if (mounted) {
        _loadDataFromHive();
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ "${batchData['name']}" deleted successfully ($deletedHiveCount items removed).'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }

      // 2. Broadcast over LAN WebSocket to all peer PCs
      try {
        for (final id in docIds) {
          if (id.isNotEmpty && id != 'unknown') {
            RealtimeManager().sendMessage(RealtimeEvents.payload(
              type: RealtimeEvents.deleteStockItem,
              branchId: widget.branchId,
              data: {'medicineId': id},
            ));
          }
        }
      } catch (_) {}

      // 3. Enqueue for persistent cloud sync
      for (final id in docIds) {
        if (id.isNotEmpty && id != 'unknown') {
          await LocalStorageService.enqueueSync({
            'type': 'delete_inventory_item',
            'branchId': widget.branchId,
            'campId': activeCamp,
            'medicineId': id,
            'data': {'id': id, 'name': batchData['name']},
          });
        }
      }
      SyncService().triggerUpload();

      // 4. Background cloud delete from all potential collections
      unawaited(() async {
        try {
          final db = FirebaseFirestore.instance;
          final batch = db.batch();
          final collections = <CollectionReference>{
            db.collection('branches').doc(widget.branchId).collection('inventory'),
          };

          if (activeCamp.isNotEmpty && activeCamp != 'all') {
            final campPath = CampSessionService.getCampInventoryPath(branchId: widget.branchId, campId: activeCamp);
            collections.add(db.collection('branches').doc(widget.branchId).collection(campPath));
          }

          if (widget.branchId.toLowerCase().contains('karachi')) {
            collections.add(db.collection('branches').doc(widget.branchId).collection('inventory_haji'));
            collections.add(db.collection('branches').doc(widget.branchId).collection('inventory_haji_camp'));
            collections.add(db.collection('branches').doc(widget.branchId).collection('inventory_saddar'));
          }

          bool hasDeletes = false;
          for (final col in collections) {
            for (final id in docIds) {
              if (id.isNotEmpty && id != 'unknown') {
                batch.delete(col.doc(id));
                hasDeletes = true;
              }
            }
          }

          if (hasDeletes) {
            await batch.commit().timeout(const Duration(seconds: 8));
            debugPrint('[InventoryDelete] ✅ Background Firestore batch delete successful for $docIds');
          }
        } catch (e) {
          debugPrint('[InventoryDelete] ⚠️ Background Firestore delete deferred to sync queue: $e');
        }
      }());
    } catch (e, st) {
      debugPrint('[InventoryDelete] ❌ ERROR: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete notice: $e'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  PreferredSizeWidget _buildAppBar({bool isMobile = false}) => AppBar(
        backgroundColor: _isDark ? const Color(0xFF0F172A) : _teal,
        elevation: 1,
        toolbarHeight: 55,
        automaticallyImplyLeading: false,
        leading: (!widget.isEmbedded && Navigator.canPop(context))
            ? const AppBackButton(color: Colors.white)
            : (isMobile && !widget.isDispenser
                ? Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 22),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                  )
                : null),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Row(children: [
          const Icon(FontAwesomeIcons.pills,
              color: Colors.white70, size: 14),
          const SizedBox(width: 8),
          const Text('Inventory',
              style: TextStyle(
                  color: Colors.white,
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
            valueListenable: Hive.box(LocalStorageService.syncBox).listenable(),
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
                        const Icon(Icons.sync_problem_rounded, color: Colors.orangeAccent),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: CircleAvatar(
                            radius: 6,
                            backgroundColor: Colors.red,
                            child: Text(
                              '$failuresCount',
                              style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
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

  void _showSyncFailuresDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final box = Hive.box(LocalStorageService.syncBox);
        final failedActions = box.values
            .whereType<Map>()
            .where((action) => (action['attempts'] ?? 0) > 0)
            .toList();

        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.sync_problem_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('Sync Retry Queue'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: failedActions.isEmpty
                ? const Text('All sync operations are running smoothly.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: failedActions.length,
                    itemBuilder: (context, index) {
                      final item = failedActions[index];
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
                          leading: const Icon(Icons.error_outline_rounded, color: Colors.red),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
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
            color: _isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _isDark ? const Color(0xFF334155) : Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
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
                  color: _isDark ? Colors.white : _textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Stock for this branch has not been loaded or added yet. You can add medicines from the Universal Proforma or sync from cloud.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: _isDark ? const Color(0xFF94A3B8) : _textLight,
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
                        foregroundColor: Colors.white,
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
                      foregroundColor: _isDark ? const Color(0xFF5EEAD4) : _teal,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      side: BorderSide(color: _isDark ? const Color(0xFF5EEAD4) : _teal),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      LocalStorageService.downloadInventory(widget.branchId, forceFull: true).then((_) {
                        if (mounted) _loadDataFromHive();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('🔄 Syncing branch inventory from cloud...'), duration: Duration(seconds: 2)),
                      );
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

    final screenWidth = MediaQuery.of(context).size.width;

    return Column(
      children: [
        _buildMetricsRow(_groupedBatches, screenWidth < 800),
        _buildFilterSection(),
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

  Widget _buildCampFilterChip(String campId, String label) {
    final active = _selectedCampFilter ?? 'all';
    final isSelected = active == campId || (campId == 'haji_camp' && active == 'haji') || (campId == 'haji' && active == 'haji_camp');
    return InkWell(
      onTap: () {
        setState(() {
          _selectedCampFilter = campId;
          _displayLimit = 50;
          _loadDataFromHive();
        });
        CampSessionService.setActiveCamp(campId);
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? _teal : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : (_isDark ? Colors.grey.shade300 : const Color(0xFF374151)),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterSection() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 768;
    final branchCamps = CampSessionService.getCampsForBranch(widget.branchId);
    final hasCamps = (widget.branchId.toLowerCase().contains('karachi') ||
        CampSessionService.hasCampsForBranch(widget.branchId) ||
        _canDeleteInventoryItem) && branchCamps.isNotEmpty;

    if (isCompact) {
      return Container(
        color: _isDark ? const Color(0xFF0F172A) : _bg,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1: Search and Type Dropdown
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: _isDark ? const Color(0xFF334155) : _white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      cursorColor: _isDark ? const Color(0xFF38BDF8) : _teal,
                      onChanged: (_) => setState(() {
                        _displayLimit = 50;
                        _processData();
                      }),
                      style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : _textDark),
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded, color: _isDark ? const Color(0xFF94A3B8) : _textLight, size: 18),
                        hintText: 'Search formula, name or barcode...',
                        hintStyle: TextStyle(color: _isDark ? const Color(0xFF64748B) : _textLight, fontSize: 11.5),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: _isDark ? const Color(0xFF334155) : _white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _filterType,
                      dropdownColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
                      icon: Icon(Icons.arrow_drop_down, color: _isDark ? const Color(0xFF94A3B8) : _textLight),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _filterType = val;
                            _displayLimit = 50;
                            _processData();
                          });
                        }
                      },
                      items: _types
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(t, style: TextStyle(fontSize: 12, color: _isDark ? Colors.white : _textDark)),
                              ))
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Row 2: Camp Selection Filter (Desk selector)
            if (hasCamps && !widget.isDoctor && branchCamps.isNotEmpty) ...[
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.location_on_outlined, size: 14, color: _isDark ? const Color(0xFF38BDF8) : _teal),
                    const SizedBox(width: 4),
                    Text(
                      'Desk:',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _isDark ? Colors.white70 : Colors.black87),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildCampFilterChip('all', '🏥 All'),
                            for (final camp in branchCamps) ...[
                              const SizedBox(width: 4),
                              _buildCampFilterChip(
                                (camp['id'] ?? '').toString(),
                                '📍 ${(camp['name'] ?? camp['id'] ?? '').toString()}',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],

            // Row 3: Action Buttons (Register Med, Proforma Sheet, Proforma PDF, Batch filter)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Register Medicine Action
                  if (_canRegisterMedicine) ...[
                    ElevatedButton.icon(
                      onPressed: () {
                        final regIdx = 2;
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
                      icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 14),
                      label: const Text('Register Med', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11.5)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade800,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],

                  // Proforma Sheet Button
                  if (!_isSupervisorUser) ...[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _teal,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                        elevation: 1,
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
                        if (res == true) {
                          _loadDataFromHive();
                        }
                      },
                      icon: const Icon(FontAwesomeIcons.fileExcel, size: 12, color: Colors.white),
                      label: const Text(
                        'Proforma Sheet',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],

                  // Download Proforma / Inventory Checklist PDF button
                  _isExportingPdf
                      ? Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: _tealDark,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              ),
                              SizedBox(width: 6),
                              Text('Exporting...', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        )
                      : ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _tealDark,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                            elevation: 1,
                          ),
                          onPressed: _exportPdf,
                          icon: const Icon(Icons.picture_as_pdf_rounded, size: 14, color: Colors.white),
                          label: const Text(
                            'Proforma PDF',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11.5),
                          ),
                        ),
                  const SizedBox(width: 6),

                  // Batch Dropdown
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: _isDark ? const Color(0xFF334155) : _white,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _filterBatch,
                        dropdownColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
                        icon: Icon(Icons.arrow_drop_down, color: _isDark ? const Color(0xFF94A3B8) : _textLight, size: 18),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _filterBatch = val;
                              _displayLimit = 50;
                              _processData();
                            });
                          }
                        },
                        items: _batchKeys
                            .map((b) => DropdownMenuItem(
                                  value: b,
                                  child: Text(b, style: TextStyle(fontSize: 11.5, color: _isDark ? Colors.white : _textDark)),
                                ))
                            .toList(),
                      ),
                    ),
                  ),

                  if (_canDeleteInventoryItem && _showRemoveAllMeds) ...[
                    const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _confirmRemoveAllMedsFromCurrentCamp,
                      icon: const Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 14),
                      label: const Text('Clear Camp', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade800,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                      ),
                    ),
                  ],
                  if (_canDeleteInventoryItem) ...[
                    const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _syncInventoryFromCloud,
                      icon: const Icon(Icons.cloud_download_rounded, color: Colors.white, size: 14),
                      label: const Text('Sync', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    final widgets = [
      SizedBox(
        width: 320,
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: _isDark ? const Color(0xFF334155) : _white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
          ),
          child: TextField(
            controller: _searchCtrl,
            cursorColor: _isDark ? const Color(0xFF38BDF8) : _teal,
            onChanged: (_) => setState(() {
              _displayLimit = 50;
              _processData();
            }),
            style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : _textDark),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, color: _isDark ? const Color(0xFF94A3B8) : _textLight, size: 18),
              hintText: 'Search name, formula or barcode (Tap row to edit)...',
              hintStyle: TextStyle(color: _isDark ? const Color(0xFF64748B) : _textLight, fontSize: 11.5),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF334155) : _white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _filterType,
            dropdownColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
            icon: Icon(Icons.arrow_drop_down, color: _isDark ? const Color(0xFF94A3B8) : _textLight),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _filterType = val;
                  _displayLimit = 50;
                  _processData();
                });
              }
            },
            items: _types
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t, style: TextStyle(fontSize: 12.5, color: _isDark ? Colors.white : _textDark)),
                    ))
                .toList(),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF334155) : _white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200, width: 1),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _filterBatch,
            dropdownColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
            icon: Icon(Icons.arrow_drop_down, color: _isDark ? const Color(0xFF94A3B8) : _textLight),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _filterBatch = val;
                  _displayLimit = 50;
                  _processData();
                });
              }
            },
            items: _batchKeys
                .map((b) => DropdownMenuItem(
                      value: b,
                      child: Text(b, style: TextStyle(fontSize: 12.5, color: _isDark ? Colors.white : _textDark)),
                    ))
                .toList(),
          ),
        ),
      ),
      if (hasCamps && !widget.isDoctor && branchCamps.isNotEmpty) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: _isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _isDark ? const Color(0xFF475569) : Colors.grey.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCampFilterChip('all', '🏥 All Camps'),
              for (final camp in branchCamps) ...[
                const SizedBox(width: 4),
                _buildCampFilterChip(
                  (camp['id'] ?? '').toString(),
                  '📍 ${(camp['name'] ?? camp['id'] ?? '').toString()}',
                ),
              ],
            ],
          ),
        ),
      ],
    ];

    // Universal Proforma Sheet Button (Hidden for Supervisor)
    if (!_isSupervisorUser) {
      widgets.add(const SizedBox(width: 8));
      widgets.add(
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _teal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 2,
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
            if (res == true) {
              _loadDataFromHive();
            }
          },
          icon: const Icon(FontAwesomeIcons.fileExcel, size: 14, color: Colors.white),
          label: const Text(
            'Proforma Sheet',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
      );
    }

    // Download PDF button
    widgets.add(const SizedBox(width: 8));
    widgets.add(
      _isExportingPdf
          ? const SizedBox(
              width: 38,
              height: 38,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _teal),
                ),
              ),
            )
          : Tooltip(
              message: 'Download Inventory Checklist / Proforma PDF',
              child: InkWell(
                onTap: _exportPdf,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: _tealDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _teal.withValues(alpha: 0.3), width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.picture_as_pdf_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text('PDF', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
    );

    if (_canRegisterMedicine) {
      widgets.add(const SizedBox(width: 8));
      widgets.add(
        ElevatedButton.icon(
          onPressed: () {
            final regIdx = 2;
            if (regIdx < _tabCtrl.length) {
              _tabCtrl.animateTo(regIdx);
              setState(() {});
            }
          },
          icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 16),
          label: const Text(
            'Register Medicine',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.teal.shade800,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 38),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
    }

    if (_canDeleteInventoryItem && _showRemoveAllMeds) {
      widgets.add(const SizedBox(width: 8));
      final isSpecificCampSelected = _selectedCampFilter != null && _selectedCampFilter != 'all';
      final campLabel = isSpecificCampSelected
          ? CampSessionService.getCampLabel(_selectedCampFilter!)
          : 'Camp';
      widgets.add(
        ElevatedButton.icon(
          onPressed: _confirmRemoveAllMedsFromCurrentCamp,
          icon: const Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 16),
          label: Text(
            isSpecificCampSelected
                ? 'Remove All Meds From $campLabel'
                : 'Remove Camp Meds (Select Camp)',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: isSpecificCampSelected ? Colors.red.shade800 : Colors.grey.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 38),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
    }

    if (_canDeleteInventoryItem) {
      // Restore / Sync from Cloud button
      widgets.add(const SizedBox(width: 8));
      widgets.add(
        ElevatedButton.icon(
          onPressed: _syncInventoryFromCloud,
          icon: const Icon(Icons.cloud_download_rounded, color: Colors.white, size: 16),
          label: const Text(
            'Sync / Restore Cloud',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueGrey.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 38),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
    }

    return Container(
      color: _isDark ? const Color(0xFF0F172A) : _bg,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: widgets),
      ),
    );
  }

  Future<void> _syncInventoryFromCloud() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔄 Downloading & restoring inventory from Firestore...'),
        duration: Duration(seconds: 2),
      ),
    );
    await LocalStorageService.downloadInventory(widget.branchId, forceFull: true, campId: _selectedCampFilter);
    if (mounted) {
      _loadDataFromHive();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Inventory restored successfully! Showing ${_displayItems.length} records.'),
          backgroundColor: Colors.green,
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
              Icon(Icons.info_outline, color: Colors.amber, size: 28),
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
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: Text('Yes, Delete $campLabel Meds', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final count = await LocalStorageService.clearLocalCampStock(widget.branchId, activeCamp);

      // LAN broadcast
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.deleteStockItem,
          branchId: widget.branchId,
          data: {'clearCamp': activeCamp, 'count': count},
        ));
      } catch (_) {}

      // Background permanent Firestore purge for ONLY this camp
      unawaited(() async {
        try {
          final db = FirebaseFirestore.instance;
          final isHaji = activeCamp.toLowerCase().contains('haji');
          final isSaddar = activeCamp.toLowerCase().contains('sadd') || activeCamp.toLowerCase().contains('kap');

          for (final bId in [widget.branchId, widget.branchId.toLowerCase(), widget.branchId.toUpperCase()]) {
            final invColRef = db.collection('branches').doc(bId).collection('inventory');
            final snap = await invColRef.get();
            if (snap.docs.isNotEmpty) {
              final batch = db.batch();
              int batchCount = 0;
              for (final doc in snap.docs) {
                final dId = doc.id.toLowerCase();
                final dData = doc.data();
                final dCamp = (dData['campId'] ?? dData['dispensaryId'] ?? '').toString().toLowerCase();

                bool shouldDelete = false;
                if (isHaji && (dId.startsWith('haji') || dCamp.contains('haji'))) {
                  shouldDelete = true;
                } else if (isSaddar && (dId.startsWith('kapayya') || dId.startsWith('saddar') || dCamp.contains('sadd') || dCamp.contains('kap'))) {
                  shouldDelete = true;
                }

                if (shouldDelete) {
                  batch.delete(doc.reference);
                  batchCount++;
                }
              }
              if (batchCount > 0) {
                await batch.commit();
                debugPrint('[ClearCampMeds] Deleted $batchCount Firestore docs for $activeCamp in branches/$bId/inventory');
              }
            }

            final subColName = isHaji ? 'inventory_haji' : 'inventory_saddar';
            final subSnap = await db.collection('branches').doc(bId).collection(subColName).get();
            if (subSnap.docs.isNotEmpty) {
              final batch = db.batch();
              for (final doc in subSnap.docs) {
                batch.delete(doc.reference);
              }
              await batch.commit();
            }
          }
        } catch (e) {
          debugPrint('[ClearCampMeds] Background Firestore delete error: $e');
        }
      }());

      if (mounted) {
        _loadDataFromHive();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Removed $count medicine record(s) from $campLabel (Local & Cloud).'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to clear camp meds: $e'), backgroundColor: Colors.red),
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
      icon: const Icon(Icons.add_rounded, color: Colors.white, size: 18),
      label: const Text(
        'Update Stock',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: _teal,
        foregroundColor: Colors.white,
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
        color: _white,
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
        style: const TextStyle(color: _textDark, fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, color: _teal, size: 20),
          hintText: 'Search formula or name (Tap row to edit)...',
          hintStyle: const TextStyle(color: _textLight, fontSize: 13),
          filled: true,
          fillColor: Colors.transparent,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade200, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _teal, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onChanged: (_) => setState(() => _page = 0),
      ),
    );
  }

  Widget _buildMetricsRow(List<Map<String, dynamic>> batches, bool isMobile) {
    final totalMedicines = batches.length;
    final lowStockCount = batches.where((b) => (b['quantity'] as int) < 10).length;
    final expiringSoonCount = batches.where((b) => _isExpiringSoon(b['expiryDate'] as String?)).length;
    final totalStockQty = batches.fold<int>(0, (sum, b) => sum + (b['quantity'] as int));

    final numberFormat = NumberFormat('#,###');

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _buildMetricItem(FontAwesomeIcons.boxOpen, _teal, '$totalMedicines', 'Formulas', onTap: _resetFilters),
              _buildVerticalDivider(),
              _buildMetricItem(Icons.inventory_2_outlined, _teal, numberFormat.format(totalStockQty), 'Units', onTap: _resetFilters),
              _buildVerticalDivider(),
              _buildMetricItem(Icons.warning_amber_rounded, _red, '$lowStockCount', 'Low Stock', onTap: _applyLowStockSort),
              _buildVerticalDivider(),
              _buildMetricItem(Icons.calendar_today_rounded, _blue, '$expiringSoonCount', 'Expiring', onTap: _applyExpirySort),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1E293B) : _white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _isDark ? const Color(0xFF334155) : Colors.grey.shade200, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(child: _buildMetricItem(FontAwesomeIcons.boxOpen, _teal, '$totalMedicines', 'Formulas', onTap: _resetFilters)),
          _buildVerticalDivider(),
          Expanded(child: _buildMetricItem(Icons.inventory_2_outlined, _teal, numberFormat.format(totalStockQty), 'Units', onTap: _resetFilters)),
          _buildVerticalDivider(),
          Expanded(child: _buildMetricItem(Icons.warning_amber_rounded, _red, '$lowStockCount', 'Low Stock', onTap: _applyLowStockSort)),
          _buildVerticalDivider(),
          Expanded(child: _buildMetricItem(Icons.calendar_today_rounded, _blue, '$expiringSoonCount', 'Expiring', onTap: _applyExpirySort)),
        ],
      ),
    );
  }

  Widget _buildMetricItem(IconData icon, Color color, String value, String label, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    color: _isDark ? const Color(0xFF94A3B8) : _textLight,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalDivider() {
    return Container(
      height: 24,
      width: 1,
      color: _isDark ? const Color(0xFF475569) : Colors.grey.shade200,
      margin: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  Widget _filterDropdown(
      String value, List<String> items, ValueChanged<String?> onChange,
      {String Function(String)? display, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: _white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200, width: 1),
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
              dropdownColor: _white,
              style: const TextStyle(color: _textDark, fontSize: 13.5, fontWeight: FontWeight.w500),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _textMid, size: 20),
              items: items
                  .map((t) => DropdownMenuItem<String>(
                      value: t,
                      child: Text(display != null ? display(t) : t,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _textDark, fontSize: 13.5))))
                  .toList(),
              onChanged: onChange,
            ),
          ),
        ],
      ),
    );
  }

  // ── Stock Table (wide screens) ─────────────────────────────────────────────
  Widget _stockTable(
      List<Map<String, dynamic>> data, double screenWidth, int totalCount, [double? availableHeight]) {
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
          color: _isDark ? const Color(0xFF1E293B) : Colors.white,
          child: Text(
            data.length >= totalCount
                ? 'Showing all $totalCount medicines'
                : 'Loading more...',
            style: TextStyle(color: _isDark ? const Color(0xFF94A3B8) : _textLight, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        );
      }
      final b = data[i];
      final qty = b['quantity'] as int;
      final type = b['type'] as String;
      final barcode = (b['barcode'] ?? b['code'] ?? '').toString().trim();
      final lowStock = qty < 10;
      final expSoon = _isExpiringSoon(b['expiryDate'] as String?);
      final expText = _formatDate(b['expiryDate'] as String?);
      final isWarning = lowStock || expSoon;
      final rowColor = _isDark
          ? (isWarning
              ? const Color(0xFF2D1214)
              : (i % 2 == 0 ? const Color(0xFF1E293B) : const Color(0xFF0F172A)))
          : (isWarning
              ? const Color(0xFFFFF5F5)
              : (i % 2 == 0 ? _white : const Color(0xFFFAFAFA)));

      final rowContent = Container(
        decoration: BoxDecoration(
          color: rowColor,
          border: Border(
            bottom: BorderSide(
                color: isWarning
                    ? (_isDark ? const Color(0xFF991B1B) : _red.withValues(alpha: 0.15))
                    : (_isDark ? const Color(0xFF334155) : Colors.grey.shade100),
                width: 1.0),
          ),
        ),
        child: Stack(
          children: [
            if (_canDeleteInventoryItem)
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
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
                      ),
                      child: const Icon(Icons.delete_forever_rounded, size: 15, color: Colors.red),
                    ),
                  ),
                ),
              ),
            Row(children: [
              _dCell(
                  cols[0].w,
                  Text('${i + 1}',
                      style: TextStyle(color: _isDark ? const Color(0xFF94A3B8) : _textMid, fontSize: 12.5, fontWeight: FontWeight.bold))),
              _dCell(
                  cols[1].w,
                  RichText(
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : _textDark),
                      children: [
                        TextSpan(
                          text: b['name'] ?? '',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _isDark
                                ? (isWarning ? const Color(0xFFFF6B6B) : Colors.white)
                                : (isWarning ? _red.withValues(alpha: 0.9) : _textDark),
                          ),
                        ),
                        if (b['formula'] != null && (b['formula'] as String).isNotEmpty) ...[
                          const TextSpan(text: ' '),
                          TextSpan(
                            text: '(${b['formula']})',
                            style: TextStyle(
                              color: _isDark
                                  ? (isWarning ? const Color(0xFFFCA5A5) : const Color(0xFF94A3B8))
                                  : (isWarning ? _red.withValues(alpha: 0.7) : _textLight),
                              fontWeight: FontWeight.normal,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )),
              _dCell(cols[2].w, _barcodeCell(barcode)),
              _dCell(cols[3].w, _typePill(type)),
              _dCell(
                  cols[4].w,
                  Text(b['dose'] ?? '—',
                      style: TextStyle(color: _isDark ? const Color(0xFFF8FAFC) : _textDark, fontSize: 12.5))),
              _dCell(
                  cols[5].w,
                  Text(NumberFormat('#,###').format(qty),
                      style: TextStyle(
                          color: _isDark
                              ? (lowStock ? const Color(0xFFFF6B6B) : Colors.white)
                              : (lowStock ? _red : _textDark),
                          fontWeight: lowStock ? FontWeight.bold : FontWeight.w500,
                          fontSize: 12.5))),
              _dCell(
                  cols[6].w,
                  Text(expText,
                      style: TextStyle(
                          color: _isDark
                              ? (expSoon ? const Color(0xFFFF6B6B) : Colors.white)
                              : (expSoon ? _red : _textDark),
                          fontWeight: expSoon ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12.5))),
            ]),
          ],
        ),
      );

      return InkWell(
        onTap: _isDirectEditAllowed
            ? () => _showEditSheet(b)
            : () {
                if (widget.isDispenser && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text(
                        '💡 Dispensers must use "Update Stock" to submit medicine changes for Supervisor approval.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      backgroundColor: _isDark ? const Color(0xFF0F766E) : _teal,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              },
        hoverColor: _isDark ? const Color(0xFF334155) : const Color(0xFFF3F7F6),
        child: rowContent,
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _isDark ? const Color(0xFF334155) : Colors.grey.shade200, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: _shadow.withValues(alpha: 0.04),
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final tableContent = Column(
            children: [
              Container(
                height: 38,
                color: _isDark ? const Color(0xFF0F766E) : _teal,
                child: Row(
                    children: cols.map((c) => _hCell(c.w, c.label, c.sort)).toList()),
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
          if (i == data.length) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              child: Text(
                data.length >= totalCount
                    ? 'Showing all $totalCount medicines'
                    : 'Loading more...',
                style: TextStyle(color: _isDark ? const Color(0xFF94A3B8) : _textLight, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            );
          }
          final b = data[i];
          final qty = _asInt(b['quantity']);
          final type = b['type']?.toString() ?? '';
          final price = _parsePrice(b['price']);
          final barcode = (b['barcode'] ?? b['code'] ?? '').toString().trim();
          final lowStock = qty < 10;
          final expSoon = _isExpiringSoon(b['expiryDate']?.toString());
          final expText = _formatDate(b['expiryDate']?.toString());

          final isWarning = lowStock || expSoon;

          final card = Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _isDark
                  ? (isWarning ? const Color(0xFF2D1214) : const Color(0xFF1E293B))
                  : (isWarning ? const Color(0xFFFFEBEE) : _white),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isWarning ? (_isDark ? const Color(0xFFFF6B6B) : _red) : (_isDark ? const Color(0xFF334155) : const Color(0xFFE0E0E0)),
                width: isWarning ? 2.0 : 0.8,
              ),
              boxShadow: [
                BoxShadow(
                    color: isWarning
                        ? (_isDark ? Colors.red.withValues(alpha: 0.3) : _red.withValues(alpha: 0.18))
                        : (_isDark ? Colors.black26 : _shadow),
                    blurRadius: isWarning ? 10 : 6,
                    offset: const Offset(0, 3))
              ],
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: isWarning
                              ? (_isDark ? Colors.red.withValues(alpha: 0.2) : _red.withValues(alpha: 0.1))
                              : (_isDark ? const Color(0xFF334155) : _green50),
                          borderRadius: BorderRadius.circular(8)),
                      child: _typeIconWidget(type,
                          size: 13,
                          color: isWarning ? (_isDark ? const Color(0xFFFF6B6B) : _red) : (_isDark ? const Color(0xFF38BDF8) : null)),
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
                              color: _isDark
                                  ? (isWarning ? const Color(0xFFFF6B6B) : Colors.white)
                                  : (isWarning ? _red : _textDark),
                              fontWeight: FontWeight.bold,
                              fontSize: 13.5),
                        ),
                      ],
                    )),
                    if (_canDeleteInventoryItem)
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
                                color: Colors.red.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
                              ),
                              child: const Icon(Icons.delete_forever_rounded, size: 15, color: Colors.red),
                            ),
                          ),
                        ),
                      )
                    else
                      _qtyBadge(qty, lowStock),
                    if (_canDeleteInventoryItem) ...[
                      const SizedBox(width: 8),
                      _qtyBadge(qty, lowStock),
                    ],
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    _typePill(type),
                    if ((b['dose'] ?? '').toString().isNotEmpty)
                      _infoBadge(b['dose'].toString(), _isDark ? const Color(0xFF94A3B8) : _textMid),
                    if (barcode.isNotEmpty)
                      _infoBadge(barcode, _isDark ? const Color(0xFF38BDF8) : _indigo, icon: Icons.qr_code_rounded),
                    _priceBadge(price),
                    _expBadge(expText, expSoon),
                    if (lowStock || expSoon)
                      _statusLabel(lowStock: lowStock, expSoon: expSoon),
                  ]),
                ]),
          );

          return GestureDetector(
                onTap: _isDirectEditAllowed
                    ? () => _showEditSheet(b)
                    : () {
                        if (widget.isDispenser && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text(
                                '💡 Dispensers must use "Update Stock" to submit medicine changes for Supervisor approval.',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                              backgroundColor: _isDark ? const Color(0xFF0F766E) : _teal,
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      },
                child: card);
        },
      );

  // Small pill showing the batch barcode (or a muted placeholder when absent)
  Widget _barcodeCell(String barcode) {
    if (barcode.isEmpty) {
      return Text('—', style: TextStyle(color: _isDark ? const Color(0xFF94A3B8) : _textLight.withValues(alpha: 0.6), fontSize: 12.5));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF0C4A6E) : _indigo.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _isDark ? const Color(0xFF0284C7) : _indigo.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.qr_code_rounded, size: 12, color: _isDark ? const Color(0xFF38BDF8) : _indigo),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            barcode,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _isDark ? const Color(0xFF7DD3FC) : _indigo, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ]),
    );
  }

  void _showEditSheet(Map<String, dynamic> batchData) {
    if (!_isDirectEditAllowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔒 Direct editing is restricted for Dispensers. Use "Update Stock" for Supervisor approval.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final docIds =
        List<String>.from(batchData['_docIds'] as List? ?? []);
    if (docIds.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditMedicineSheet(
        branchId: widget.branchId,
        docIds: docIds,
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
            return const Center(
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
            return const Center(
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
    final Color accentColor = isEdited ? _purple : (isRegistration ? _blue : _green600);
    final IconData actionIcon = isEdited
        ? Icons.edit_rounded
        : (isRegistration ? Icons.medication_liquid_rounded : Icons.add_box_rounded);
    final String actionLabel = isEdited
        ? 'MEDICINE EDITED'
        : (isRegistration ? 'NEW MEDICINE' : 'STOCK ADDED');
    final Color labelBg = isEdited
        ? const Color(0xFFF3E5F5)
        : (isRegistration ? const Color(0xFFE3F2FD) : const Color(0xFFE8F5E9));
    final Color labelFg = isEdited ? _purple : (isRegistration ? _blue : _green600);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
              color: _shadow, blurRadius: 6, offset: const Offset(0, 2))
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
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
                        fontWeight: FontWeight.bold)),
              ),
              if (data['_isPending'] == true) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: _orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _orange.withValues(alpha: 0.3)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bolt_rounded, size: 9, color: _orange),
                    SizedBox(width: 3),
                    Text('PENDING SYNC',
                        style: TextStyle(
                            color: _orange,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5)),
                  ]),
                ),
              ],
            ]),
            const SizedBox(height: 6),
            Text(medicineName,
                style: const TextStyle(
                    color: _textDark,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 5, children: [
              if (medicineType.isNotEmpty)
                _miniChip(medicineType, _teal),
              if (dose.isNotEmpty) _miniChip(dose, _textMid),
              _miniChip('+$qtyAdded units', accentColor),
              if (isRegistration && price.isNotEmpty)
                _miniChip('PKR $price', _orange),
              if (isRegistration && expiry.isNotEmpty)
                _miniChip('Exp: ${_formatDate(expiry)}', _textMid),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.person_outline_rounded,
                  size: 13, color: _textLight),
              const SizedBox(width: 5),
              Text(performedBy,
                  style: const TextStyle(
                      color: _textMid,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (ts != null) ...[
                const SizedBox(width: 10),
                const Icon(Icons.access_time_rounded,
                    size: 12, color: _textLight),
                const SizedBox(width: 4),
                Text(
                  DateFormat('dd MMM yyyy, hh:mm a').format(ts.toDate()),
                  style: const TextStyle(
                      color: _textLight, fontSize: 11),
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
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Container(
          color: _white,
          child: const TabBar(
            indicatorColor: _teal,
            labelColor: _teal,
            unselectedLabelColor: _textLight,
            labelStyle: TextStyle(fontWeight: FontWeight.bold),
            isScrollable: false,
            tabs: [
              Tab(
                  icon: Icon(Icons.check_circle_rounded, size: 16),
                  text: 'Approved'),
              Tab(
                  icon: Icon(Icons.cancel_rounded, size: 16),
                  text: 'Rejected'),
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
            return const Center(
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

    return (_selectedCampFilter != null && _selectedCampFilter != 'all')
        ? CampSessionService.getCampLabel(_selectedCampFilter!)
        : 'Saddar Camp';
  }

  Widget _requestCard(
      String docId, Map<String, dynamic> data, String status) {
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
      'edit_medicine' => const Color(0xFFF3E5F5),
      'delete_medicine' => const Color(0xFFFFEBEE),
      _ => Colors.grey.shade100,
    };
    Color badgeFg = switch (requestType) {
      'edit_medicine' => _purple,
      'delete_medicine' => _red,
      _ => _textMid,
    };
    String typeLabel = switch (requestType) {
      'edit_medicine' => 'EDIT MEDICINE',
      'delete_medicine' => 'DELETE MEDICINE',
      _ => requestType.replaceAll('_', ' ').toUpperCase(),
    };

    Color statusColor = switch (status) {
      'approved' => _green600,
      'rejected' => _red,
      _ => _orange,
    };
    IconData statusIcon = switch (status) {
      'approved' => Icons.check_circle_rounded,
      'rejected' => Icons.cancel_rounded,
      _ => Icons.pending_rounded,
    };

    final rawItems = status == 'pending'
        ? (data['draftItems'] as List?) ?? (data['items'] as List?) ?? []
        : (data['items'] as List?) ?? [];
    final items = rawItems.cast<Map<String, dynamic>>();

    final campLabel = _resolveCampLabel(data);

    return Card(
      color: _green50,
      elevation: status == 'pending' ? 4 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _tealDark),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.holiday_village_rounded, size: 13, color: Color(0xFF0284C7)),
                  const SizedBox(width: 4),
                  Text(
                    campLabel.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0284C7),
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
                      fontWeight: FontWeight.bold,
                      color: badgeFg)),
            ),
          ]),
          const SizedBox(height: 10),
          FutureBuilder<String>(
            future: nameFuture,
            builder: (_, snap) => Row(children: [
              const Icon(Icons.person_rounded, size: 15, color: _teal),
              const SizedBox(width: 6),
              Text('By: ${snap.data ?? '…'}',
                  style:
                      const TextStyle(fontSize: 13, color: _textDark)),
            ]),
          ),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.location_on_rounded, size: 14, color: _tealDark),
            const SizedBox(width: 6),
            Text(
              'Facility Camp: $campLabel',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.bold,
                color: _tealDark,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          if (ts != null)
            Row(children: [
              const Icon(Icons.access_time_rounded,
                  size: 14, color: _textLight),
              const SizedBox(width: 6),
              Text(
                DateFormat('dd MMM yyyy, hh:mm a')
                    .format(ts.toDate()),
                style:
                    const TextStyle(fontSize: 12, color: _textLight),
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
                color: _white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.comment_rounded,
                      size: 14, color: _textLight),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Reason: $reason',
                          style: const TextStyle(
                              fontSize: 13, color: _textDark))),
                ],
              ),
            ),
          ],
          if (status != 'pending') ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: status == 'approved'
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: status == 'approved'
                      ? _green600.withValues(alpha: 0.35)
                      : _red.withValues(alpha: 0.35),
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
                      color: status == 'approved' ? _green600 : _red,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      status == 'approved' ? 'Approved by:' : 'Rejected by:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: status == 'approved' ? _green600 : _red,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        data['reviewedByName']?.toString() ?? '—',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: status == 'approved' ? _green600 : _red,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                  if (data['reviewedAt'] != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.access_time_rounded,
                          size: 12, color: _textLight),
                      const SizedBox(width: 5),
                      Text(
                        DateFormat('dd MMM yyyy, hh:mm a').format(
                            (data['reviewedAt'] as Timestamp).toDate()),
                        style: const TextStyle(
                            fontSize: 11, color: _textLight),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
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
                branchRef, data, itemsToUse, reviewerUid, reviewerName);
          }
        } else if (requestType == 'delete_medicine') {
          final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
              ? _safeItemList(data['draftItems'])
              : _safeItemList(data['items']);
          await _applyDeleteMedicine(branchRef, itemsToUse);
        } else if (requestType == 'register_medicine') {
          final itemsToUse = _safeItemList(data['draftItems']).isNotEmpty
              ? _safeItemList(data['draftItems'])
              : _safeItemList(data['items']);
          if (itemsToUse.isNotEmpty) {
            for (final item in itemsToUse) {
              final name = item['name']?.toString() ?? '';
              final type = item['type'] ?? '';
              final dose = item['dose'] ?? '';
              final exp  = item['expiryDate'] ?? '';
              final id = RequestUtils.generateDocId(name, type, dose, exp);
              
              await branchRef.collection('inventory').doc(id).set({
                ...item,
                'addedAt': FieldValue.serverTimestamp(),
                'createdBy': data['requestedBy'],
                'createdByName': data['requesterName'],
                'approvedBy': reviewerUid,
                'approvedByName': reviewerName ?? 'Supervisor',
              });
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Request ${newStatus.toUpperCase()}'),
          backgroundColor: newStatus == 'approved' ? _teal : _red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
      String? reviewerName) async {
    final inventory = branchRef.collection('inventory');
    final batch = FirebaseFirestore.instance.batch();

    final originalDocId = requestData['docId']?.toString();

    for (final item in items) {
      final name = (item['name'] ?? '').toString().trim();
      final type = (item['type'] ?? '').toString().trim();
      final dose = (item['dose'] ?? '').toString().trim();
      final price = item['price']?.toString() ?? '0';
      final expiry = (item['expiryDate'] ?? '').toString().trim();
      final barcode = (item['barcode'] ?? '').toString().trim();

      final updateData = <String, dynamic>{
        'name': name,
        'name_lower': name.toLowerCase(),
        'type': type,
        'dose': dose,
        'price': price,
        'barcode': barcode,
        'expiryDate': expiry,
        'updatedAt': FieldValue.serverTimestamp(),
        'approvedBy': reviewerUid,
        'approvedByName': reviewerName ?? 'Supervisor',
      };

      final targetDocId =
          originalDocId ?? item['oldId']?.toString();

      if (targetDocId != null && targetDocId.isNotEmpty) {
        batch.update(inventory.doc(targetDocId), updateData);
      }
    }

    await batch.commit();
  }

  Future<void> _applyDeleteMedicine(
      DocumentReference branchRef,
      List<Map<String, dynamic>> items) async {
    final inventory = branchRef.collection('inventory');
    final batch = FirebaseFirestore.instance.batch();

    for (final item in items) {
      final name = item['name']?.toString();
      final type = item['type']?.toString();
      if (name == null || type == null) continue;
      
      final q = await inventory
          .where('name_lower', isEqualTo: name.toLowerCase())
          .where('type', isEqualTo: type)
          .get();
      for (final doc in q.docs) {
        batch.delete(doc.reference);
      }
    }
    await batch.commit();
  }

  Widget _buildMedicineEditComparison(Map<String, dynamic> data) {
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

    final isWide = MediaQuery.of(context).size.width > 600;

    if (isWide) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border.withValues(alpha: 0.5)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(_teal.withValues(alpha: 0.05)),
            columnSpacing: 20,
            horizontalMargin: 16,
            columns: const [
              DataColumn(label: Text('Field', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('Original', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              DataColumn(label: Text('Proposed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
            ],
            rows: fields.map((f) {
              final key = f['key'] as String;
              final oldVal = getValue(originalData, key);
              final newVal = getValue(proposedData, key);
              final isChanged = oldVal != newVal && newVal != '—';

              return DataRow(cells: [
                DataCell(Text(f['label']!, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12))),
                DataCell(Text(oldVal, style: TextStyle(
                  color: isChanged ? Colors.grey : _textDark,
                  decoration: isChanged ? TextDecoration.lineThrough : null,
                  fontSize: 12,
                ))),
                DataCell(Text(newVal, style: TextStyle(
                  color: isChanged ? Colors.blue.shade700 : _textDark,
                  fontWeight: isChanged ? FontWeight.bold : FontWeight.normal,
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
        const Padding(
          padding: EdgeInsets.only(bottom: 8, top: 4),
          child: Text('Proposed Changes:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _tealDark)),
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _border.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text(label, style: const TextStyle(fontSize: 11, color: _textLight, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(oldVal, style: const TextStyle(fontSize: 11, color: Colors.grey, decoration: TextDecoration.lineThrough)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.arrow_forward, size: 10, color: Colors.grey),
                      ),
                      Text(newVal, style: TextStyle(fontSize: 12, color: Colors.blue.shade800, fontWeight: FontWeight.bold)),
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
    final isWide = MediaQuery.of(context).size.width > 600;
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
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _teal)),
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
        final barcode = m['barcode']?.toString() ?? '';
        final campId = (m['dispensaryId'] ?? m['campId'] ?? 'all').toString();
        final campLabel = CampSessionService.getCampLabel(campId);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                  color: _white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border)),
              child: _typeIconWidget(type, size: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              Text('$name ($type$dose) × $qty',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: _textDark)),
              const SizedBox(height: 2),
              Row(children: [
                _miniChip('PKR ${_fmtPrice(price)}', _green600),
                const SizedBox(width: 6),
                _miniChip(expiry, _textMid),
                const SizedBox(width: 6),
                _miniChip('Camp: $campLabel', _teal),
                if (barcode.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _miniChip(barcode, _indigo),
                ],
              ]),
            ])),
          ]),
        );
      }).toList(),
    );
  }

  Widget _hCell(double w, String label, String? sort) {
    final active = _sortField == sort;
    return InkWell(
      onTap: sort != null ? () => _sort(sort) : null,
      child: Container(
        width: w,
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          Text(label,
              style: TextStyle(
                  color: active ? Colors.white : Colors.white70,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 0.3)),
          if (active) ...[
            const SizedBox(width: 3),
            Icon(
                _isAscending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 12,
                color: Colors.white),
          ],
        ]),
      ),
    );
  }

  static Color _darkTypeColor(String type) => switch (type) {
        'Tablet' => const Color(0xFF60A5FA),
        'Capsule' => const Color(0xFFC084FC),
        'Syrup' => const Color(0xFFFDBA74),
        'Injection' => const Color(0xFFFCA5A5),
        'Infusion' => const Color(0xFF5EEAD4),
        'Drip' => const Color(0xFF5EEAD4),
        'Drip Set' => const Color(0xFF67E8F9),
        'Syringe' => const Color(0xFFF472B6),
        'Cannula' => const Color(0xFFFB7185),
        'Needle' => const Color(0xFFE879F9),
        'Nebulization' => const Color(0xFF818CF8),
        'Dressing Item' => const Color(0xFFCBD5E1),
        'Consumables' => const Color(0xFF2DD4BF),
        _ => const Color(0xFFE2E8F0),
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
          color: _isDark ? const Color(0xFF14532D).withValues(alpha: 0.35) : const Color(0xFFF3FCF4),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: _isDark ? const Color(0xFF22C55E).withValues(alpha: 0.5) : const Color(0xFF81C784).withValues(alpha: 0.6)),
        ),
        child: Text('PKR ${_fmtPrice(price)}',
            style: TextStyle(
                color: _isDark ? const Color(0xFF4ADE80) : const Color(0xFF2E7D32),
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
          color: (soon ? _red : (_isDark ? const Color(0xFF334155) : Colors.grey.shade100)).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: (soon ? _red : (_isDark ? const Color(0xFF475569) : Colors.grey.shade300)).withValues(alpha: 0.5),
              width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_today_rounded, size: 10, color: soon ? _red : (_isDark ? const Color(0xFF94A3B8) : _textMid)),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: soon ? _red : (_isDark ? const Color(0xFFCBD5E1) : _textMid),
                  fontWeight: soon ? FontWeight.bold : FontWeight.normal,
                  fontSize: 11)),
        ]),
      );

  Widget _statusDot({required bool lowStock, required bool expSoon}) {
    final Color dotColor = lowStock
        ? _red
        : (expSoon ? _amber : const Color(0xFF2E7D32));
    
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
          Icon(icon, color: Colors.white, size: isTable ? 10 : 12),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
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
          Icon(icon, size: 72, color: Colors.grey[300]),
          const SizedBox(height: 14),
          Text(msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _textLight, fontSize: 15)),
        ]),
      );
}

class _EditMedicineSheet extends StatefulWidget {
  final String branchId;
  final List<String> docIds;
  final Map<String, dynamic> initial;
  final List<String> medicineTypes;
  final String Function(String?) formatDate;
  final bool isAdmin;
  final bool isDoctor;
  final bool isDispenser;

  const _EditMedicineSheet({
    required this.branchId,
    required this.docIds,
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
  static const _teal = Color(0xFF00695C);
  static const _tealDark = Color(0xFF004D40);
  static const _green50 = Color(0xFFE8F5E9);
  static const _green600 = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _border = Color(0xFFB2DFDB);
  static const _textDark = Color(0xFF1B2631);
  static const _textLight = Color(0xFF718096);

  late final TextEditingController _nameCtrl;
  late final TextEditingController _doseCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _expiryCtrl;
  late final TextEditingController _barcodeCtrl;
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
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      final col = FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('inventory');

      final batch = FirebaseFirestore.instance.batch();
      final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
      final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;
      final perDoc = (qty / widget.docIds.length).floor();
      final remainder = qty - perDoc * widget.docIds.length;
      final barcode = _barcodeCtrl.text.trim();

      for (int i = 0; i < widget.docIds.length; i++) {
        final id = widget.docIds[i];
        final ref = col.doc(id);
        final uData = {
          'formula': '',
          'name': _nameCtrl.text.trim(),
          'name_lower': _nameCtrl.text.trim().toLowerCase(),
          'type': _selectedType,
          'dose': _doseCtrl.text.trim(),
          'quantity': perDoc + (i == 0 ? remainder : 0),
          'price': price,
          'barcode': barcode,
          'code': barcode,
          'expiryDate': _expiryCtrl.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        try {
          final stockBox = Hive.box(LocalStorageService.stockBox);
          final existing = stockBox.get('stock:$id') ?? stockBox.get(id);
          final base = (existing is Map) ? Map<String, dynamic>.from(existing) : <String, dynamic>{'id': id, 'docId': id};
          final updated = base..addAll(uData);
          LocalStorageService.saveLocalInventoryItem(updated);

          RealtimeManager().sendMessage({
            'event_type': RealtimeEvents.saveStockItem,
            'branchId': widget.branchId,
            'data': updated,
          });

          if (!RealtimeManager().isConnected) {
            LocalStorageService.enqueueSync({
              'type': 'register_medicine',
              'branchId': widget.branchId,
              'medicineId': id,
              'data': updated,
            });
          }
        } catch (_) {}
      }

      // Commit to Firestore in background without blocking UI
      unawaited(batch.commit().catchError((e) {
        debugPrint('[Inventory] Background batch commit error: $e');
      }));

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.check_circle_rounded,
                color: Colors.white, size: 18),
            SizedBox(width: 10),
            Text('Medicine updated successfully'),
          ]),
          backgroundColor: _green600,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e) {
      setState(() => _saving = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update: $e'),
          backgroundColor: _red,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 24),
      child:
          Column(mainAxisSize: MainAxisSize.min, children: [
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.edit_rounded,
                color: _teal, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              const Text('Edit Medicine',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: _tealDark)),
              Text('${widget.docIds.length} batch doc(s) will be updated',
                  style: const TextStyle(
                      fontSize: 11, color: _textLight)),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: _textLight),
            onPressed: () => Navigator.pop(context),
          ),
        ]),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
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
                const Text('Type',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _textLight)),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: _green50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedType,
                    isExpanded: true,
                    underline: const SizedBox(),
                    dropdownColor: Colors.white,
                    style: const TextStyle(
                        color: _textDark, fontSize: 14),
                    icon: const Icon(Icons.expand_more_rounded,
                        color: _teal),
                    items: widget.medicineTypes
                        .map((t) => DropdownMenuItem(
                            value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => setState(
                        () => _selectedType = v ?? _selectedType),
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
                  label: 'Barcode',
                  icon: Icons.qr_code_rounded,
                  keyboardType: TextInputType.text,
                  enabled: canEditBarcode,
                );
              }),
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
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_rounded,
                          color: Colors.white, size: 18),
                  label: Text(_saving ? 'Saving…' : 'Save Changes',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    disabledBackgroundColor:
                        _teal.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 3,
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
  }) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _textLight)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          enabled: enabled,
          readOnly: !enabled,
          cursorColor: _teal,
          style: TextStyle(color: enabled ? _textDark : Colors.grey.shade700, fontSize: 14),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, size: 17, color: enabled ? _teal : Colors.grey),
            suffixIcon: !enabled ? const Icon(Icons.lock_rounded, size: 16, color: Colors.grey) : null,
            helperText: helperText,
            helperStyle: TextStyle(color: Colors.amber.shade900, fontSize: 11, fontWeight: FontWeight.bold),
            filled: true,
            fillColor: enabled ? _green50 : Colors.grey.shade100,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _teal, width: 1.5)),
            disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade300)),
            errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _red)),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 13),
          ),
        ),
      ]);
}

class _Col {
  final String label;
  final double w;
  final String? sort;
  const _Col(this.label, this.w, this.sort);
}