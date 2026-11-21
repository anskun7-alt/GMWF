// lib/pages/dispensary/dispensar/add_medicine_page.dart
//
// Redesigned "Add Medicine" screen (replacing the legacy Universal Proforma Sheet).
//
// Two user-selectable modes:
//   1. Guided  (default) — one medicine at a time in 3 clear steps: Find -> Quantity & Expiry -> Done.
//   2. Express — multi-medicine queue + rapid barcode scanning + bulk expiry + batch save.
//
// Write path:
//   Uses the EXACT existing StockActions / StockLedger / StockSync / StockCloud +
//   LocalStorageService.saveLocalInventoryLog + save_inventory_log sync queue path
//   so stock totals, batches, expiry alerts, low-stock counts, Medicine Ledger,
//   and Log/History tabs behave identically to before.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/design/design_system.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind, GIcons;
import 'package:gmwf/services/stock/expiry_rules.dart';
import 'package:gmwf/services/stock/stock_log.dart';
import 'package:gmwf/pages/dispensary/dispensar/inventory.dart';
import 'package:gmwf/pages/dispensary/dispensar/inventory_update.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/services/add_medicine_mode_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
import 'package:gmwf/utils/string_similarity_helper.dart';
import 'package:gmwf/widgets/app_back_button.dart';
import 'package:gmwf/widgets/blurred_dialog_observer.dart';

class AddMedicinePage extends StatefulWidget {
  final String branchId;
  final bool isDispenser;
  final bool isAdmin;
  final bool isEmbedded;
  final VoidCallback? onBackToInventory;
  final VoidCallback? onOpenRegisterMedicine;

  const AddMedicinePage({
    super.key,
    required this.branchId,
    this.isDispenser = true,
    this.isAdmin = false,
    this.isEmbedded = false,
    this.onBackToInventory,
    this.onOpenRegisterMedicine,
  });

  @override
  State<AddMedicinePage> createState() => _AddMedicinePageState();
}

enum _GuidedStep { find, details, done }

class _ExpressItemDraft {
  final Map<String, dynamic> catalogItem;
  final String keyCode;
  final TextEditingController qtyController;
  DateTime? expiryDate;

  _ExpressItemDraft({
    required this.catalogItem,
    required this.keyCode,
    DateTime? initialExpiry,
  })  : qtyController = TextEditingController(),
        expiryDate = initialExpiry;

  int get quantity => int.tryParse(qtyController.text.trim()) ?? 0;

  void dispose() => qtyController.dispose();
}

class _SessionAddedRecord {
  final String barcode;
  final String name;
  final String dose;
  final String type;
  final int qtyAdded;
  final int previousStock;
  final int newStock;
  final String expiryDate;
  final DateTime addedAt;

  const _SessionAddedRecord({
    required this.barcode,
    required this.name,
    required this.dose,
    required this.type,
    required this.qtyAdded,
    required this.previousStock,
    required this.newStock,
    required this.expiryDate,
    required this.addedAt,
  });
}

class _CommitEntry {
  final Map<String, dynamic> catalogItem;
  final int qty;
  final DateTime? expiryDate;

  const _CommitEntry({
    required this.catalogItem,
    required this.qty,
    required this.expiryDate,
  });
}

class _AddMedicinePageState extends State<AddMedicinePage> {
  // ── Mode & First-run Preference ───────────────────────────────────────────
  AddMedicineMode _mode = AddMedicineMode.guided;
  bool _showFirstRunBanner = false;

  // ── Catalog & Live Stock State ────────────────────────────────────────────
  List<Map<String, dynamic>> _catalogItems = [];
  final Map<String, int> _inStockQuantities = {};
  List<String> _availableTypes = const [
    'All',
    'Tablet',
    'Capsule',
    'Syrup',
    'Injection',
    'Nebulization',
    'Dressing Item',
    'Consumables',
  ];

  // ── Shared Search & Expandable Full List ──────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _showFullList = false;
  String _selectedTypeFilter = 'All';

  // ── Guided Mode State ─────────────────────────────────────────────────────
  _GuidedStep _guidedStep = _GuidedStep.find;
  Map<String, dynamic>? _guidedSelectedItem;
  final TextEditingController _guidedQtyCtrl = TextEditingController();
  final FocusNode _guidedQtyFocus = FocusNode();
  DateTime? _guidedExpiryDate;
  _SessionAddedRecord? _guidedLastResult;

  // ── Express Mode State (persists across mode toggles within the visit) ────
  final List<_ExpressItemDraft> _expressList = [];
  bool _expressShowDone = false;
  List<_SessionAddedRecord> _expressLastResults = [];
  DateTime? _expressBulkExpiry;

  // ── Session History & Saving Flag ─────────────────────────────────────────
  final List<_SessionAddedRecord> _sessionAdded = [];
  bool _isSaving = false;

  // ── Reactive Subscriptions ────────────────────────────────────────────────
  Timer? _stockDebounce;
  ValueListenable<Box>? _stockListenable;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;

  static const List<String> _preferredTypeOrder = [
    'Tablet',
    'Capsule',
    'Syrup',
    'Injection',
    'Nebulization',
    'Dressing Item',
    'Consumables',
    'Infusion',
    'Cannula',
    'Syringe',
    'Drip Set',
    'Others',
  ];

  // ── Role & Permission Helpers ─────────────────────────────────────────────
  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ??
            Hive.box('app_settings').get('currentUser');
        if (uData is Map) return Map<String, dynamic>.from(uData);
      }
    } catch (_) {}
    return {};
  }

  /// Chairman / HQ Manager / Admin can edit, delete, and audit catalog entries.
  bool get _canManageCatalog {
    if (widget.isDispenser && !widget.isAdmin) return false;
    final uData = _getUserData();
    final role = (uData['role'] ?? uData['userRole'] ?? uData['roleType'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (role.contains('dispenser') ||
        role.contains('dispensary') ||
        role.contains('doctor') ||
        role.contains('pharmacist') ||
        role.contains('receptionist')) {
      if (!role.contains('admin') &&
          !role.contains('chairman') &&
          !role.contains('hq') &&
          !role.contains('manager') &&
          !role.contains('super')) {
        return false;
      }
    }
    return widget.isAdmin ||
        role.contains('admin') ||
        role.contains('chairman') ||
        role.contains('hq') ||
        role.contains('manager') ||
        role.contains('super');
  }

  /// Respects the exact existing "Register Medicine" role gating:
  /// Dispensers and doctors can restock but must NOT see "Register new medicine".
  bool get _canRegisterMedicine {
    if (widget.isDispenser && !widget.isAdmin) return false;
    if (widget.isAdmin) return true;
    final uData = _getUserData();
    if (uData.isEmpty) return false;
    return InventoryPage.canRegisterMedicineFromRole(uData);
  }

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    if (!mounted) return false;
    return Theme.of(context).brightness == Brightness.dark;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _mode = AddMedicineModeService.getPreferredMode();
    _showFirstRunBanner = AddMedicineModeService.shouldShowFirstRunPrompt();

    _loadCatalogAndStock();
    _searchCtrl.addListener(_onSearchChanged);
    _guidedQtyCtrl.addListener(_onGuidedInputChanged);

    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      _stockListenable = Hive.box(LocalStorageService.stockBox).listenable()
        ..addListener(_debouncedReload);
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          _stockListenable = box.listenable()..addListener(_debouncedReload);
          _loadCatalogAndStock();
        }
      });
    }

    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      // Legacy 'proforma' LAN event names preserved for cross-version sync.
      if (type == RealtimeEvents.saveProformaItem ||
          type == 'save_proforma_item' ||
          type == RealtimeEvents.proformaItemUpdated ||
          type == 'proforma_item_updated') {
        if (mounted) _loadCatalogAndStock();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusSearch();
    });
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _stockDebounce?.cancel();
    try {
      _stockListenable?.removeListener(_debouncedReload);
      _stockListenable = null;
    } catch (_) {}
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    _guidedQtyCtrl.removeListener(_onGuidedInputChanged);
    _guidedQtyCtrl.dispose();
    _guidedQtyFocus.dispose();
    for (final draft in _expressList) {
      draft.dispose();
    }
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _onGuidedInputChanged() {
    if (mounted) setState(() {});
  }

  void _focusSearch() {
    if (!mounted) return;
    if ((_mode == AddMedicineMode.guided && _guidedStep == _GuidedStep.find) ||
        (_mode == AddMedicineMode.express && !_expressShowDone)) {
      _searchFocusNode.requestFocus();
    }
  }

  void _debouncedReload() {
    _stockDebounce?.cancel();
    _stockDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _loadCatalogAndStock();
    });
  }

  // ── Branch & Pool Helpers ─────────────────────────────────────────────────
  String _resolvedBranch() {
    var b = widget.branchId.trim();
    if (b.isEmpty || b.toLowerCase() == 'default' || b.toLowerCase() == 'all' || b.toLowerCase() == 'unknown') {
      b = LocalStorageService.getActiveBranchId() ?? 'karachi';
    }
    return b;
  }

  StockPool? _stockPool(String branch) => StockPool.of(
        branch,
        CampSessionService.getActiveCamp(branch),
        fallbackCamp: CampSessionService.getActiveCamp(branch),
      );

  String _activeScopeLabel() {
    final branch = _resolvedBranch();
    final bName = LocalStorageService.getBranchName(branch);
    final pool = _stockPool(branch);
    if (pool == null) return '$bName (Select camp)';
    if (pool.camp != null && pool.camp!.isNotEmpty) {
      return '$bName • ${CampSessionService.getCampLabel(pool.camp!, branch)}';
    }
    return bName;
  }

  // ── Catalog & Stock Loading ───────────────────────────────────────────────
  void _loadCatalogAndStock() {
    // Legacy MasterProformaService reads from local Hive box `master_proforma_catalog`.
    final list = MasterProformaService.getAllProformaItems();
    final List<Map<String, dynamic>> existingStock = [];
    try {
      final pool = _stockPool(_resolvedBranch());
      if (pool != null) {
        for (final rec in StockReader.batches(pool)) {
          if (rec['status'] == 'deleted') continue;
          existingStock.add(Map<String, dynamic>.from(rec));
        }
      }
    } catch (_) {}

    final nextStockMap = <String, int>{};
    final presentTypes = <String>{};

    for (final item in list) {
      final code = _itemKey(item);
      final name = (item['name'] as String? ?? '').trim().toLowerCase();
      final formula = (item['formula'] as String? ?? name).trim().toLowerCase();
      final type = (item['type'] as String? ?? 'Tablet').trim();
      final typeLower = type.toLowerCase();
      final dose = (item['dose'] as String? ?? '').trim().toLowerCase();
      final cleanCode = code.trim().toLowerCase();
      if (type.isNotEmpty) presentTypes.add(type);

      int inStockQty = 0;
      for (final stockItem in existingStock) {
        final sName = (stockItem['name'] as String? ?? '').trim().toLowerCase();
        final sFormula = (stockItem['formula'] as String? ?? sName).trim().toLowerCase();
        final sType = (stockItem['type'] as String? ?? '').trim().toLowerCase();
        final sDose = (stockItem['dose'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final sBarcode = (stockItem['code'] as String? ?? stockItem['barcode'] as String? ?? '').trim().toLowerCase();

        bool isMatch = false;
        if (cleanCode.isNotEmpty && sBarcode.isNotEmpty && cleanCode == sBarcode) {
          isMatch = true;
        } else if ((sFormula == formula ||
                sName == name ||
                sFormula == name ||
                sName == formula) &&
            sType == typeLower &&
            (dose.isEmpty || sDose == dose.replaceAll(RegExp(r'\s+'), ''))) {
          isMatch = true;
        }

        if (isMatch) {
          final q = (stockItem['quantity'] as num?)?.toInt() ?? 0;
          if (q > 0) inStockQty += q;
        }
      }

      if (inStockQty > 0) {
        nextStockMap[code] = inStockQty;
      }
    }

    final orderedTypes = <String>['All'];
    for (final t in _preferredTypeOrder) {
      if (presentTypes.contains(t) ||
          const {
            'Tablet',
            'Capsule',
            'Syrup',
            'Injection',
            'Nebulization',
            'Dressing Item',
            'Consumables',
          }.contains(t)) {
        orderedTypes.add(t);
      }
    }
    for (final t in presentTypes) {
      if (!orderedTypes.contains(t)) orderedTypes.add(t);
    }

    if (!mounted) return;
    setState(() {
      _catalogItems = list;
      _inStockQuantities
        ..clear()
        ..addAll(nextStockMap);
      _availableTypes = orderedTypes;
      if (!_availableTypes.contains(_selectedTypeFilter)) {
        _selectedTypeFilter = 'All';
      }
    });
  }

  // ── Item Display & Search Helpers ─────────────────────────────────────────
  String _itemKey(Map<String, dynamic> item) =>
      (item['code'] ?? item['barcode'] ?? item['rollNo'] ?? item['name'] ?? 'MED').toString().trim();

  String _itemBarcode(Map<String, dynamic> item) {
    final raw = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim();
    final norm = MasterProformaService.normalizeProformaBarcode(raw);
    if (norm != null) return norm;
    if (raw.isNotEmpty) return raw;
    return '---';
  }

  String _itemName(Map<String, dynamic> item) {
    final f = (item['formula'] ?? '').toString().trim();
    final n = (item['name'] ?? '').toString().trim();
    return f.isNotEmpty ? f : (n.isNotEmpty ? n : 'Unknown Medicine');
  }

  String _itemDose(Map<String, dynamic> item) => (item['dose'] ?? '').toString().trim();

  String _itemType(Map<String, dynamic> item) {
    final t = (item['type'] ?? 'Tablet').toString().trim();
    return t.isEmpty ? 'Tablet' : t;
  }

  int _currentStockFor(Map<String, dynamic> item) => _inStockQuantities[_itemKey(item)] ?? 0;

  /// Exact barcode / packBarcode / legacy code match used when a barcode scanner hits Enter.
  Map<String, dynamic>? _findExactBarcodeMatch(String rawQuery) {
    final q = rawQuery.trim();
    if (q.isEmpty) return null;
    final lower = q.toLowerCase();
    final normBar = MasterProformaService.normalizeProformaBarcode(q);

    for (final item in _catalogItems) {
      final itemBar = MasterProformaService.normalizeProformaBarcode(
        (item['barcode'] ?? item['rollNo'] ?? '').toString(),
      );
      if (normBar != null && itemBar != null && itemBar == normBar) {
        return item;
      }
      final pack = (item['packBarcode'] ?? '').toString().trim().toLowerCase();
      if (pack.isNotEmpty && pack == lower) {
        return item;
      }
      final legacyCode = (item['code'] ?? item['itemCode'] ?? '').toString().trim().toLowerCase();
      if (legacyCode.isNotEmpty && legacyCode == lower) {
        return item;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _searchCatalog({required bool applyTypeFilter, int? limit}) {
    final query = _searchCtrl.text.trim().toLowerCase();
    final queryNum = int.tryParse(query);
    final normQueryBar = MasterProformaService.normalizeProformaBarcode(query);

    bool matchesType(Map<String, dynamic> item) {
      if (!applyTypeFilter || _selectedTypeFilter == 'All') return true;
      final t = _itemType(item);
      if (t == _selectedTypeFilter) return true;
      if (_selectedTypeFilter == 'Infusion' && (t == 'Infusion' || t == 'Drip')) return true;
      return false;
    }

    var matches = _catalogItems.where((item) {
      if (!matchesType(item)) return false;
      if (query.isEmpty) return true;

      final name = (item['name'] ?? '').toString().toLowerCase();
      final formula = (item['formula'] ?? '').toString().toLowerCase();
      final dose = (item['dose'] ?? '').toString().toLowerCase();
      final barcode = (item['barcode'] ?? '').toString().toLowerCase();
      final rollNo = (item['rollNo'] ?? '').toString().toLowerCase();
      final packBarcode = (item['packBarcode'] ?? '').toString().toLowerCase();
      final legacyCode = (item['code'] ?? item['itemCode'] ?? '').toString().toLowerCase();

      bool barMatch = barcode.contains(query) || rollNo.contains(query) || packBarcode.contains(query);
      if (!barMatch && normQueryBar != null) {
        final normItemBar = MasterProformaService.normalizeProformaBarcode(
          (item['barcode'] ?? item['rollNo'] ?? '').toString(),
        );
        if (normItemBar == normQueryBar) barMatch = true;
      }
      if (!barMatch && queryNum != null) {
        final rNum = int.tryParse(rollNo);
        final bNum = int.tryParse(barcode);
        if ((rNum != null && rNum == queryNum) || (bNum != null && bNum == queryNum)) {
          barMatch = true;
        }
      }

      return barMatch ||
          name.contains(query) ||
          formula.contains(query) ||
          dose.contains(query) ||
          legacyCode.contains(query);
    }).toList();

    if (matches.isEmpty && query.length >= 3) {
      matches = _catalogItems.where((item) {
        if (!matchesType(item)) return false;
        final name = (item['name'] ?? '').toString().toLowerCase();
        final formula = (item['formula'] ?? '').toString().toLowerCase();
        final simName = StringSimilarityHelper.calculateSimilarity(query, name);
        final simForm = StringSimilarityHelper.calculateSimilarity(query, formula);
        return simName >= 0.55 || simForm >= 0.55;
      }).toList();
    }

    // Rank exact barcode / prefix name hits first when searching.
    if (query.isNotEmpty) {
      matches.sort((a, b) {
        int score(Map<String, dynamic> it) {
          final bar = _itemBarcode(it).toLowerCase();
          final n = _itemName(it).toLowerCase();
          if (normQueryBar != null && bar == normQueryBar) return 0;
          if (bar == query) return 0;
          if (n.startsWith(query)) return 1;
          if (bar.startsWith(query)) return 2;
          return 3;
        }

        final sCmp = score(a).compareTo(score(b));
        if (sCmp != 0) return sCmp;
        return _itemName(a).toLowerCase().compareTo(_itemName(b).toLowerCase());
      });
    }

    if (limit != null && matches.length > limit) {
      return matches.sublist(0, limit);
    }
    return matches;
  }

  // ── Date Helpers & Validation ─────────────────────────────────────────────
  DateTime _todayDateOnly() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// True when the expiry is NOT accepted: in the past OR in the current month
  /// (user rule 2026-11-21: expiry must be after this month).
  bool _isPastDate(DateTime? d) {
    if (d == null) return false;
    return !isExpiryAcceptable(d);
  }

  /// Expiry is month + year only; the day is always 01 (user rule 2026-11-21).
  DateTime _addMonths(int months) {
    final now = DateTime.now();
    return DateTime(now.year, now.month + months, 1);
  }

  String _formatDisplayDate(DateTime d) => DateFormat('MMM yyyy').format(d);

  String _formatStorageDate(DateTime d) => DateFormat('yyyy-MM-01').format(d);

  Future<DateTime?> _openExpiryPicker({DateTime? initialDate}) async {
    final c = context.comfort;
    final now = DateTime.now();
    final first = DateTime(now.year, now.month + 1, 1);
    var init = initialDate ?? DateTime(now.year + 1, now.month, 1);
    if (init.isBefore(first)) init = first;
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      // Only months after the current one can be picked; the chosen day is replaced by 01.
      firstDate: first,
      lastDate: DateTime(now.year + 10, 12, 31),
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Expiry month (day is set to 01)',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
                primary: c.brand,
                onPrimary: c.onBrand,
                surface: c.surface,
                onSurface: c.textPrimary,
              ),
        ),
        child: child!,
      ),
    );
    return picked == null ? null : DateTime(picked.year, picked.month, 1);
  }

  // ── Mode Switching & Navigation ───────────────────────────────────────────
  Future<void> _switchMode(AddMedicineMode next) async {
    if (_mode == next && !_showFirstRunBanner) return;
    setState(() {
      _mode = next;
      _showFirstRunBanner = false;
    });
    await AddMedicineModeService.setPreferredMode(
      next,
      branchId: _resolvedBranch(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearch());
  }

  Future<void> _dismissFirstRun() async {
    setState(() => _showFirstRunBanner = false);
    await AddMedicineModeService.dismissFirstRunPrompt();
  }

  void _goBackToInventory() {
    if (widget.isEmbedded && widget.onBackToInventory != null) {
      widget.onBackToInventory!.call();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openRegisterNewMedicine() async {
    if (!_canRegisterMedicine) return;
    if (widget.onOpenRegisterMedicine != null) {
      widget.onOpenRegisterMedicine!.call();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryUpdatePage(
          branchId: _resolvedBranch(),
          isAdmin: widget.isAdmin,
          isDispenser: widget.isDispenser,
          showMode: 2,
        ),
      ),
    );
    if (mounted) _loadCatalogAndStock();
  }

  // ── Guided Actions ────────────────────────────────────────────────────────
  void _selectForGuided(Map<String, dynamic> item) {
    setState(() {
      _guidedSelectedItem = item;
      _guidedQtyCtrl.clear();
      _guidedExpiryDate = null;
      _guidedStep = _GuidedStep.details;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _guidedQtyFocus.requestFocus();
    });
  }

  void _resetGuidedToFind() {
    setState(() {
      _guidedSelectedItem = null;
      _guidedQtyCtrl.clear();
      _guidedExpiryDate = null;
      _guidedStep = _GuidedStep.find;
      _searchCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearch());
  }

  void _adjustGuidedQty(int delta) {
    final cur = int.tryParse(_guidedQtyCtrl.text.trim()) ?? 0;
    final next = cur + delta;
    setState(() {
      if (next <= 0) {
        _guidedQtyCtrl.clear();
      } else {
        _guidedQtyCtrl.text = '$next';
        _guidedQtyCtrl.selection = TextSelection.collapsed(offset: _guidedQtyCtrl.text.length);
      }
    });
  }

  Future<void> _submitGuided() async {
    final item = _guidedSelectedItem;
    if (item == null || _isSaving) return;
    final qty = int.tryParse(_guidedQtyCtrl.text.trim()) ?? 0;
    final exp = _guidedExpiryDate;

    if (qty <= 0 && exp == null) return;
    if (_isPastDate(exp)) return;

    final results = await _commitEntries([
      _CommitEntry(catalogItem: item, qty: qty, expiryDate: exp),
    ]);
    if (results == null || results.isEmpty || !mounted) return;

    setState(() {
      _guidedLastResult = results.first;
      _guidedStep = _GuidedStep.done;
    });
  }

  // ── Express Actions ───────────────────────────────────────────────────────
  bool _isInExpressList(Map<String, dynamic> item) {
    final key = _itemKey(item);
    return _expressList.any((d) => d.keyCode == key);
  }

  void _toggleExpressItem(Map<String, dynamic> item) {
    final key = _itemKey(item);
    final idx = _expressList.indexWhere((d) => d.keyCode == key);
    setState(() {
      _expressShowDone = false;
      if (idx >= 0) {
        final removed = _expressList.removeAt(idx);
        removed.dispose();
      } else {
        final draft = _ExpressItemDraft(
          catalogItem: item,
          keyCode: key,
          initialExpiry: _expressBulkExpiry,
        );
        draft.qtyController.addListener(_onExpressDraftChanged);
        _expressList.add(draft);
      }
    });
  }

  void _onExpressDraftChanged() {
    if (mounted) setState(() {});
  }

  void _removeExpressItem(String keyCode) {
    final idx = _expressList.indexWhere((d) => d.keyCode == keyCode);
    if (idx < 0) return;
    setState(() {
      final removed = _expressList.removeAt(idx);
      removed.dispose();
    });
  }

  void _clearExpressList() {
    setState(() {
      for (final d in _expressList) {
        d.dispose();
      }
      _expressList.clear();
      _expressBulkExpiry = null;
    });
  }

  void _applyBulkExpiryToExpressList(DateTime? date) {
    setState(() {
      _expressBulkExpiry = date;
      for (final d in _expressList) {
        d.expiryDate = date;
      }
    });
  }

  bool get _canSubmitExpress {
    if (_isSaving || _expressList.isEmpty) return false;
    for (final d in _expressList) {
      if (d.quantity <= 0 && d.expiryDate == null) return false;
      if (_isPastDate(d.expiryDate)) return false;
    }
    return true;
  }

  Future<void> _submitExpress() async {
    if (!_canSubmitExpress) return;
    final entries = _expressList
        .map((d) => _CommitEntry(
              catalogItem: d.catalogItem,
              qty: d.quantity,
              expiryDate: d.expiryDate,
            ))
        .toList();

    final results = await _commitEntries(entries);
    if (results == null || !mounted) return;

    setState(() {
      for (final d in _expressList) {
        d.dispose();
      }
      _expressList.clear();
      _expressBulkExpiry = null;
      _expressLastResults = results;
      _expressShowDone = true;
    });
  }

  void _handleSearchSubmitted(String value) {
    final exact = _findExactBarcodeMatch(value);
    if (exact == null) return;

    if (_mode == AddMedicineMode.guided) {
      _selectForGuided(exact);
    } else {
      final alreadyAdded = _isInExpressList(exact);
      if (!alreadyAdded) {
        _toggleExpressItem(exact);
      } else {
        AppToast.showSnackBar(
          context,
          SnackBar(
            content: Text('"${_itemName(exact)}" is already in your list.'),
            backgroundColor: context.comfort.brand,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _searchCtrl.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearch());
    }
  }

  // ── EXACT EXISTING WRITE PATH ─────────────────────────────────────────────
  Future<void> _uploadInventoryLog(String branch, Map<String, dynamic> logData) async {
    // Already saved locally (with its id); StockLog sends it to every PC over the LAN and
    // the LAN server / a standalone PC uploads it to the cloud.
    logData['branchId'] ??= branch;
    await StockLog.share(logData);
  }

  /// Writes stock & activity logs through the EXACT same StockActions + StockLedger +
  /// LocalStorageService.saveLocalInventoryLog + sync queue pipeline as the old Proforma Sheet.
  Future<List<_SessionAddedRecord>?> _commitEntries(List<_CommitEntry> entries) async {
    if (entries.isEmpty) return null;

    setState(() => _isSaving = true);

    try {
      final String activeBranch = _resolvedBranch();
      final pool = _stockPool(activeBranch);
      if (pool == null) {
        if (mounted) {
          setState(() => _isSaving = false);
          AppToast.showSnackBar(
            context,
            SnackBar(
              content: const Text('Please choose a camp first, then add medicines to stock.'),
              backgroundColor: context.comfort.danger,
            ),
          );
        }
        return null;
      }

      final poolBatches = StockReader.batches(pool);
      final user = FirebaseAuth.instance.currentUser;
      String addedBy = 'Dispenser';
      String performedByRole = 'Dispenser';
      String performedByEmail = user?.email ?? '';
      String performedByUid = user?.uid ?? '';

      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ??
              Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            addedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? addedBy).toString();
            performedByRole = (uData['role'] ?? uData['userRole'] ?? performedByRole).toString();
            if (performedByUid.isEmpty) performedByUid = (uData['uid'] ?? uData['id'] ?? '').toString();
            if (performedByEmail.isEmpty) performedByEmail = (uData['email'] ?? '').toString();
          }
        }
      } catch (_) {}

      if (addedBy == 'Dispenser' && user != null) {
        final local = LocalStorageService.getLocalUserByUid(user.uid);
        if (local != null) {
          addedBy = (local['username'] ?? local['name'] ?? local['displayName'] ?? addedBy).toString();
          performedByRole = (local['role'] ?? performedByRole).toString();
        }
      }
      if (addedBy == 'Dispenser' && user?.displayName != null && user!.displayName!.isNotEmpty) {
        addedBy = user.displayName!;
      } else if (addedBy == 'Dispenser' && user?.email != null && user!.email!.isNotEmpty) {
        addedBy = user.email!.split('@').first;
      }

      final String activeCamp = pool.camp ?? '';
      final committed = <_SessionAddedRecord>[];
      var seq = 0;

      for (final entry in entries) {
        seq++;
        final prof = Map<String, dynamic>.from(entry.catalogItem);
        final String name = (prof['name'] as String? ?? _itemName(prof));
        final String formula = (prof['formula'] as String? ?? '');
        final String type = (prof['type'] as String? ?? 'Tablet');
        final String dose = (prof['dose'] as String? ?? '');
        final String code = (prof['code'] as String? ?? '');
        final int qty = entry.qty;
        final String exp = entry.expiryDate != null ? _formatStorageDate(entry.expiryDate!) : '';
        final String nowIso = DateTime.now().toIso8601String();

        // Match existing batch in this pool identically to the previous sheet:
        // Name/Formula + Type + Dose, or exact code/barcode.
        final cleanCode = code.trim().toLowerCase();
        final cleanN = (formula.isNotEmpty ? formula : name)
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
        final cleanF = formula.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final cleanT = type.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final cleanD = dose.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

        // A restock with an expiry joins only a batch of the SAME expiry month (or one with no
        // expiry yet). A different expiry is a new batch: old units must keep their own expiry
        // (it used to overwrite the old batch's expiry for every unit).
        final newExpMonth = exp.isEmpty ? null : parseExpiryMonth(exp);
        bool expiryFits(Map map) {
          if (qty <= 0 || newExpMonth == null) return true; // expiry-only update / no expiry given
          final have = parseExpiryMonth((map['expiryDate'] ?? '').toString());
          return have == null || (have.year == newExpMonth.year && have.month == newExpMonth.month);
        }

        Map<String, dynamic>? existingStockData;
        for (final val in poolBatches) {
          final map = Map<String, dynamic>.from(val);
          final itemN = MasterProformaService.cleanBrandToFormula(
            (map['name'] ?? '').toString().toLowerCase().trim(),
          ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
          final itemF = MasterProformaService.cleanBrandToFormula(
            (map['formula'] ?? '').toString().toLowerCase().trim(),
          ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
          final itemT = (map['type'] ?? map['dosageForm'] ?? '').toString().toLowerCase().replaceAll(RegExp(r'\s+'), '');
          // Spaces removed on both sides: "200 mg" and "200mg" are the same dose.
          final itemD = (map['dose'] ?? '').toString().toLowerCase().replaceAll(RegExp(r'\s+'), '');
          final itemCode = (map['code'] ?? map['barcode'] ?? '').toString().trim().toLowerCase();

          bool isMatch = false;
          if ((itemN == cleanN ||
                  itemF == cleanN ||
                  itemN == cleanF ||
                  (map['name']?.toString().toLowerCase().trim() == cleanN)) &&
              itemT == cleanT &&
              // No "standard" wildcard: it sent 300 mg Sodamint stock into the "Standard" batch.
              (cleanD.isEmpty || itemD == cleanD)) {
            isMatch = true;
          } else if (cleanCode.isNotEmpty && itemCode.isNotEmpty && itemCode == cleanCode) {
            isMatch = true;
          }

          if (isMatch && expiryFits(map)) {
            existingStockData = val;
            break;
          }
        }

        if (existingStockData != null) {
          final oldQty = (existingStockData['quantity'] as num?)?.toInt() ?? 0;
          final newTotalQty = oldQty + qty;
          final existingDocId = (existingStockData['medicineId'] ?? existingStockData['id'] ?? code).toString();
          final detailsUpdate = <String, dynamic>{
            if (exp.isNotEmpty) 'expiryDate': exp,
            'lastUpdated': nowIso,
          };

          if (qty > 0) {
            // Same StockActions.restock write path as legacy Proforma Sheet.
            await StockActions.restock(
              pool,
              existingDocId,
              qty.toDouble(),
              details: detailsUpdate,
              ref: 'proforma restock', // Legacy 'proforma' ref tag preserved for ledger history.
            );
          } else if (exp.isNotEmpty) {
            // Quantity left blank ("Save Expiry Date"): update batch details without moving stock.
            await StockActions.saveDetails(pool, existingDocId, detailsUpdate);
          }

          existingStockData['quantity'] = newTotalQty;
          if (exp.isNotEmpty) existingStockData['expiryDate'] = exp;

          final detailMsg = qty > 0
              ? 'Restocked +$qty units of $name ($type $dose, New Total: $newTotalQty${exp.isNotEmpty ? ', Expiry: $exp' : ''}) via Add Medicine by $addedBy ($performedByRole)'
              : 'Updated expiry date of $name ($type $dose, Expiry: $exp) via Add Medicine by $addedBy ($performedByRole)';

          final logData = {
            'id': 'inv_${DateTime.now().microsecondsSinceEpoch}_$seq',
            'action': 'add_stock',
            'medicineName': name,
            'medicineFormula': formula,
            'medicineType': type,
            'medicineDose': dose,
            'medicineCode': code,
            'medicineId': existingDocId,
            'docId': existingDocId,
            'quantityAdded': qty,
            'previousQuantity': oldQty,
            'newQuantity': newTotalQty,
            'price': 0.0,
            'expiryDate': exp,
            'branchId': activeBranch,
            'dispensaryId': activeCamp.isNotEmpty ? activeCamp : 'all',
            'campId': activeCamp.isNotEmpty ? activeCamp : 'all',
            // Legacy 'proforma' field name kept for Firestore/audit log compatibility.
            'isProforma': true,
            'source': 'Add Medicine (Restock)',
            'performedBy': performedByUid,
            'performedByName': addedBy,
            'performedByRole': performedByRole,
            'performedByEmail': performedByEmail,
            'details': detailMsg,
            'timestamp': nowIso,
            'createdAt': nowIso,
          };

          await LocalStorageService.saveLocalInventoryLog(logData);
          await _uploadInventoryLog(activeBranch, logData);

          committed.add(_SessionAddedRecord(
            barcode: _itemBarcode(prof),
            name: _itemName(prof),
            dose: dose,
            type: type,
            qtyAdded: qty,
            previousStock: oldQty,
            newStock: newTotalQty,
            expiryDate: exp,
            addedAt: DateTime.now(),
          ));
          continue;
        }

        // Brand-new batch in this pool (exact same docId & schema as legacy sheet).
        final docId = RequestUtils.generateDocId(name, type, dose, exp, campId: activeCamp);
        final barcode = (prof['barcode'] ?? prof['rollNo'] ?? '').toString();
        final itemCode = (prof['itemCode'] ?? prof['code'] ?? '').toString();
        final packBarcode = (prof['packBarcode'] ?? '').toString().trim();

        final stockData = {
          'docId': docId,
          'id': docId,
          'medicineId': docId,
          'code': itemCode.isNotEmpty ? itemCode : code,
          'itemCode': itemCode.isNotEmpty ? itemCode : code,
          'barcode': barcode.isNotEmpty ? barcode : code,
          'rollNo': barcode,
          if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
          'name': name,
          'formula': formula,
          'type': type,
          'dose': dose,
          'price': 0.0,
          'expiryDate': exp,
          // Legacy 'proforma' field name kept for Firestore/Hive data compatibility.
          'isProforma': true,
          'source': 'Add Medicine',
          'addedBy': addedBy,
          'performedByName': addedBy,
          'performedByRole': performedByRole,
          'performedByUid': performedByUid,
          'createdAt': nowIso,
          'lastUpdated': nowIso,
        };

        await StockActions.addBatch(
          pool,
          docId,
          stockData,
          initialQty: qty.toDouble(),
          // Legacy 'proforma' ref & opKey prefix kept for movement idempotency & history.
          ref: 'proforma import',
          opKey: 'proforma-${DateTime.now().microsecondsSinceEpoch}_$seq',
        );
        poolBatches.add({
          ...stockData,
          'id': docId,
          'medicineId': docId,
          'pool': pool.key,
          'quantity': qty,
        });

        final detailMsg = qty > 0
            ? 'Added $qty units of $name ($type $dose${exp.isNotEmpty ? ', Expiry: $exp' : ', No expiry'}) via Add Medicine by $addedBy ($performedByRole)'
            : 'Saved expiry date ($exp) for $name ($type $dose) via Add Medicine by $addedBy ($performedByRole)';

        final logData = {
          'id': 'inv_${DateTime.now().microsecondsSinceEpoch}_$seq',
          // Legacy 'proforma' action & field names kept for Firestore & Medicine Ledger compatibility.
          'action': 'add_from_proforma',
          'medicineName': name,
          'medicineFormula': formula,
          'medicineType': type,
          'medicineDose': dose,
          'medicineCode': code,
          'medicineId': docId,
          'docId': docId,
          'quantityAdded': qty,
          'quantity': qty,
          'previousQuantity': 0,
          'newQuantity': qty,
          'price': 0.0,
          'totalAmount': 0.0,
          'expiryDate': exp,
          'branchId': activeBranch,
          'dispensaryId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'campId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'isProforma': true,
          'source': 'Add Medicine',
          'proformaCode': code,
          'performedBy': performedByUid,
          'performedByName': addedBy,
          'performedByRole': performedByRole,
          'performedByEmail': performedByEmail,
          'details': detailMsg,
          'timestamp': nowIso,
          'createdAt': nowIso,
        };

        await LocalStorageService.saveLocalInventoryLog(logData);
        await _uploadInventoryLog(activeBranch, logData);

        committed.add(_SessionAddedRecord(
          barcode: _itemBarcode(prof),
          name: _itemName(prof),
          dose: dose,
          type: type,
          qtyAdded: qty,
          previousStock: 0,
          newStock: qty,
          expiryDate: exp,
          addedAt: DateTime.now(),
        ));
      }

      if (!mounted) return committed;

      setState(() {
        _isSaving = false;
        _sessionAdded.insertAll(0, committed);
      });
      _loadCatalogAndStock();
      return committed;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _isSaving = false);
      AppToast.showSnackBar(
        context,
        SnackBar(
          content: Text('Failed to save stock: $e'),
          backgroundColor: context.comfort.danger,
        ),
      );
      return null;
    }
  }

  // ── Admin-only Catalog Management Dialogs (kept for HQ/Chairman/Admin) ────
  void _showEditCatalogMedicineDialog(Map<String, dynamic> item) {
    final c = context.comfort;
    final code = _itemKey(item);
    final barcode = _itemBarcode(item);
    final currentName = _itemName(item);
    final currentType = _itemType(item);
    final currentDose = _itemDose(item);

    final nameCtrl = TextEditingController(text: currentName);
    final doseCtrl = TextEditingController(text: currentDose);
    final reasonCtrl = TextEditingController();
    final allTypes = _preferredTypeOrder;
    String selectedType = allTypes.contains(currentType) ? currentType : 'Tablet';

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.edit_note_rounded, color: c.brand, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Edit Catalog Medicine',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _barcodeChip(barcode),
                  const SizedBox(height: 14),
                  Text('Medicine Name / Formula *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.brandStrong)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: c.textPrimary, fontSize: 14),
                    decoration: _dialogInputDec(c, hint: 'Medicine formula / name'),
                  ),
                  const SizedBox(height: 12),
                  Text('Type *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.brandStrong)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: selectedType,
                    dropdownColor: c.surface,
                    style: TextStyle(color: c.textPrimary, fontSize: 14),
                    decoration: _dialogInputDec(c),
                    items: allTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selectedType = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  Text('Dose', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.brandStrong)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: doseCtrl,
                    style: TextStyle(color: c.textPrimary, fontSize: 14),
                    decoration: _dialogInputDec(c, hint: 'e.g. 500 mg, 5 ml'),
                  ),
                  const SizedBox(height: 12),
                  Text('Reason for Modification (Mandatory Audit) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.warning)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: c.textPrimary, fontSize: 13.5),
                    decoration: _dialogInputDec(c, hint: 'e.g. Corrected dose per HQ directive'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                minimumSize: const Size(44, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final newName = nameCtrl.text.trim();
                final newDose = doseCtrl.text.trim();
                final reason = reasonCtrl.text.trim();
                if (newName.isEmpty) {
                  AppToast.showSnackBar(context, SnackBar(content: const Text('Medicine name cannot be empty.'), backgroundColor: c.danger));
                  return;
                }
                if (reason.isEmpty) {
                  AppToast.showSnackBar(context, SnackBar(content: const Text('A reason is required for audit logging.'), backgroundColor: c.danger));
                  return;
                }
                final uData = _getUserData();
                final performedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? 'HQ Manager').toString();
                final role = (uData['role'] ?? uData['userRole'] ?? 'HQ Manager').toString();
                final uid = (uData['uid'] ?? uData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();

                final auditLog = {
                  'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                  // Legacy 'proforma' audit action name preserved.
                  'action': 'edit_proforma_medicine',
                  'medicineCode': code,
                  'oldName': currentName,
                  'newName': newName,
                  'oldType': currentType,
                  'newType': selectedType,
                  'oldDose': currentDose,
                  'newDose': newDose,
                  'reason': reason,
                  'performedBy': uid,
                  'performedByName': performedBy,
                  'performedByRole': role,
                  'timestamp': DateTime.now().toIso8601String(),
                  'branchId': _resolvedBranch(),
                };

                final ok = await MasterProformaService.editProformaItem(
                  code: code,
                  newName: newName,
                  newType: selectedType,
                  newDose: newDose,
                  auditLog: auditLog,
                );
                if (ok) {
                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                  if (!mounted) return;
                  _loadCatalogAndStock();
                  AppToast.showSnackBar(
                    context,
                    SnackBar(
                      content: Text('Updated "$currentName" to "$newName" ($selectedType / $newDose).'),
                      backgroundColor: c.brand,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Update Medicine'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteCatalogMedicineDialog(Map<String, dynamic> item) {
    final c = context.comfort;
    final code = _itemKey(item);
    final barcode = _itemBarcode(item);
    final name = _itemName(item);
    final reasonCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.delete_forever_rounded, color: c.danger, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete from Medicine Catalog',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Remove "$name" (Barcode $barcode) permanently from the Master Medicine Catalog?',
                style: TextStyle(fontSize: 14, color: c.textPrimary),
              ),
              const SizedBox(height: 14),
              Text('Mandatory Reason for Deletion *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.danger)),
              const SizedBox(height: 6),
              TextField(
                controller: reasonCtrl,
                maxLines: 2,
                style: TextStyle(color: c.textPrimary, fontSize: 13.5),
                decoration: _dialogInputDec(c, hint: 'e.g. Discontinued formulation per HQ decision'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: c.danger,
              foregroundColor: c.onBrand,
              minimumSize: const Size(44, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final reason = reasonCtrl.text.trim();
              if (reason.isEmpty) {
                AppToast.showSnackBar(
                  context,
                  SnackBar(content: const Text('A reason is required to delete a catalog medicine.'), backgroundColor: c.danger),
                );
                return;
              }
              Navigator.pop(dialogCtx);

              final uData = _getUserData();
              final performedByName = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? 'HQ Manager').toString();
              final performedByRole = (uData['role'] ?? uData['userRole'] ?? 'HQ Manager').toString();
              final performedByUid = (uData['uid'] ?? uData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();

              final auditLog = {
                'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                // Legacy 'proforma' audit action name preserved.
                'action': 'delete_proforma_medicine',
                'medicineCode': code,
                'medicineName': name,
                'reason': reason,
                'performedBy': performedByUid,
                'performedByName': performedByName,
                'performedByRole': performedByRole,
                'timestamp': DateTime.now().toIso8601String(),
                'branchId': _resolvedBranch(),
              };

              final ok = await MasterProformaService.deleteProformaItem(code: code, auditLog: auditLog);
              if (ok && mounted) {
                AppToast.showSnackBar(
                  context,
                  SnackBar(content: Text('Removed "$name" from the Medicine Catalog.'), backgroundColor: c.brand),
                );
                _loadCatalogAndStock();
              }
            },
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
  }

  void _showCatalogAuditDialog(Map<String, dynamic> item) {
    final c = context.comfort;
    final code = _itemKey(item);
    final barcode = _itemBarcode(item);
    final name = _itemName(item);
    final audits = MasterProformaService.getAuditTrailForItem(code);

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.history_rounded, color: c.brand, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Catalog Audit Trail', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
                  Text('$name • Barcode $barcode', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: audits.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Standard catalog medicine (no edits recorded).',
                      style: TextStyle(fontSize: 13.5, color: c.textSecondary),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: audits.length,
                  separatorBuilder: (_, _) => Divider(height: 16, color: c.border),
                  itemBuilder: (_, idx) {
                    final log = audits[audits.length - 1 - idx];
                    final action = (log['action'] ?? '').toString();
                    final user = (log['performedByName'] ?? log['performedBy'] ?? 'Authorized User').toString();
                    final role = (log['performedByRole'] ?? 'Staff').toString();
                    final time = (log['timestamp'] ?? log['savedAt'] ?? '').toString();
                    final reason = (log['reason'] ?? 'No reason provided').toString();
                    final oldN = log['oldName']?.toString();
                    final newN = log['newName']?.toString();
                    final isEdit = action.contains('edit');

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isEdit ? c.infoBg : c.successBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isEdit ? 'Modified' : 'Added to Catalog',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: isEdit ? c.info : c.success,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (time.isNotEmpty)
                              Text(
                                time.length > 16 ? time.substring(0, 16).replaceAll('T', ' ') : time,
                                style: TextStyle(fontSize: 11.5, color: c.textMuted),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('By $user ($role)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary)),
                        if (oldN != null && newN != null) ...[
                          const SizedBox(height: 3),
                          Text('Changed from "$oldN" to "$newN"', style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                        ],
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: c.warningBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: c.warning.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            'Reason: $reason',
                            style: TextStyle(fontSize: 12.5, color: c.warning, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  InputDecoration _dialogInputDec(GComfortColors c, {String? hint}) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
        filled: true,
        fillColor: c.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.brand, width: 2),
        ),
      );

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final hideAppBar = widget.isEmbedded || HomeModuleHost.isModuleRoot(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: hideAppBar
          ? null
          : AppBar(
              backgroundColor: c.surface,
              foregroundColor: c.textPrimary,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              automaticallyImplyLeading: false,
              leading: (!widget.isEmbedded && Navigator.canPop(context))
                  ? AppBackButton(color: c.textPrimary)
                  : null,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.playlist_add_rounded, color: c.brand, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Add Medicine',
                          style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 17),
                        ),
                        Text(
                          'Add stock or expiry dates to dispensary inventory',
                          style: TextStyle(color: c.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(height: 1, color: c.border),
              ),
            ),
      body: BlurredUnderDialogBackground(
        child: Column(
          children: [
            _buildTopModeHeader(c),
            if (_showFirstRunBanner) _buildFirstRunBanner(c),
            Expanded(
              child: _mode == AddMedicineMode.guided
                  ? _buildGuidedBody(c)
                  : _buildExpressBody(c),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top Header + Guided | Express Switch ──────────────────────────────────
  Widget _buildTopModeHeader(GComfortColors c) {
    final poolMissing = _stockPool(_resolvedBranch()) == null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: LayoutBuilder(
        builder: (ctx, box) {
          final isNarrow = box.maxWidth < 680;
          final titleBlock = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.brandSoft,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                ),
                child: Icon(Icons.medication_rounded, color: c.brand, size: 22),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Add Medicine',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          poolMissing ? Icons.warning_amber_rounded : Icons.location_on_outlined,
                          size: 14,
                          color: poolMissing ? c.danger : c.brandStrong,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _activeScopeLabel(),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: poolMissing ? c.danger : c.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );

          final modeSwitch = _buildModeSegmentedSwitch(c);

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBlock,
                const SizedBox(height: 12),
                modeSwitch,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: titleBlock),
              const SizedBox(width: 16),
              modeSwitch,
            ],
          );
        },
      ),
    );
  }

  Widget _buildModeSegmentedSwitch(GComfortColors c) {
    Widget seg(AddMedicineMode m, IconData icon, String subtitleHint) {
      final selected = _mode == m;
      return Semantics(
        button: true,
        selected: selected,
        label: '${m.label} mode: $subtitleHint',
        child: InkWell(
          onTap: () => _switchMode(m),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 44, minWidth: 126),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? c.brand : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: selected ? c.onBrand : c.textSecondary),
                const SizedBox(width: 8),
                Text(
                  m.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected ? c.onBrand : c.textPrimary,
                  ),
                ),
                if (m == AddMedicineMode.express && _expressList.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: selected ? c.onBrand.withValues(alpha: 0.22) : c.brandSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_expressList.length}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: selected ? c.onBrand : c.brandStrong,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.borderStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(AddMedicineMode.guided, Icons.looks_one_rounded, 'One medicine at a time'),
          const SizedBox(width: 4),
          seg(AddMedicineMode.express, Icons.flash_on_rounded, 'Several medicines at once'),
        ],
      ),
    );
  }

  // ── Optional First-Run Mode Choice Card ───────────────────────────────────
  Widget _buildFirstRunBanner(GComfortColors c) {
    Widget choiceTile({
      required AddMedicineMode mode,
      required IconData icon,
      required String title,
      required String desc,
      bool recommended = false,
    }) {
      return InkWell(
        onTap: () => _switchMode(mode),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: recommended ? c.brand : c.borderStrong,
              width: recommended ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.brandSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: c.brand, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary),
                        ),
                        if (recommended) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.brandSoft,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Easy default',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.brandStrong),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.brandSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.brand.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: c.brandStrong, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'How do you want to add medicines?',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss and keep Guided mode',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(Icons.close_rounded, color: c.textSecondary, size: 20),
                onPressed: _dismissFirstRun,
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (ctx, box) {
              final guidedTile = choiceTile(
                mode: AddMedicineMode.guided,
                icon: Icons.looks_one_rounded,
                title: 'Guided',
                desc: 'Add one medicine at a time in 3 simple steps — find it, enter quantity & expiry, confirm.',
                recommended: true,
              );
              final expressTile = choiceTile(
                mode: AddMedicineMode.express,
                icon: Icons.flash_on_rounded,
                title: 'Express',
                desc: 'Scan or pick several medicines into a list and add them all to stock in one go.',
              );
              if (box.maxWidth < 680) {
                return Column(
                  children: [guidedTile, const SizedBox(height: 10), expressTile],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: guidedTile),
                  const SizedBox(width: 12),
                  Expanded(child: expressTile),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MODE 1: GUIDED (3 STEPS)
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildGuidedBody(GComfortColors c) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildGuidedStepper(c),
              const SizedBox(height: 16),
              if (_guidedStep == _GuidedStep.find) _buildGuidedStep1Find(c),
              if (_guidedStep == _GuidedStep.details) _buildGuidedStep2Details(c),
              if (_guidedStep == _GuidedStep.done) _buildGuidedStep3Done(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuidedStepper(GComfortColors c) {
    Widget stepPill(int num, String label, bool active, bool done) {
      final bg = active ? c.brand : (done ? c.successBg : c.surfaceSunken);
      final fg = active ? c.onBrand : (done ? c.success : c.textMuted);
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: active ? c.brandSoft : c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? c.brand : (done ? c.success.withValues(alpha: 0.4) : c.border),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                child: done
                    ? Icon(Icons.check_rounded, size: 15, color: fg)
                    : Text('$num', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: fg)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: active ? c.brandStrong : (done ? c.textPrimary : c.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        stepPill(1, 'Find', _guidedStep == _GuidedStep.find, _guidedStep != _GuidedStep.find),
        const SizedBox(width: 8),
        stepPill(2, 'Quantity & Expiry', _guidedStep == _GuidedStep.details, _guidedStep == _GuidedStep.done),
        const SizedBox(width: 8),
        stepPill(3, 'Done', _guidedStep == _GuidedStep.done, false),
      ],
    );
  }

  Widget _buildGuidedStep1Find(GComfortColors c) {
    final query = _searchCtrl.text.trim();
    final hasQuery = query.isNotEmpty;
    final results = _showFullList
        ? _searchCatalog(applyTypeFilter: true)
        : (hasQuery ? _searchCatalog(applyTypeFilter: false, limit: 6) : const <Map<String, dynamic>>[]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Step 1: Find the medicine',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                'Scan a barcode (press Enter to open immediately) or type a medicine name.',
                style: TextStyle(fontSize: 13.5, color: c.textSecondary),
              ),
              const SizedBox(height: 14),
              _buildSearchField(c),
              const SizedBox(height: 12),
              _buildFullListToggleRow(c),
              if (_showFullList) ...[
                const SizedBox(height: 12),
                _buildTypeFilterPills(c),
              ],
              const SizedBox(height: 14),
              if (!hasQuery && !_showFullList)
                _buildSearchIdleHint(c, isExpress: false)
              else if (results.isEmpty)
                _buildNoMatchesState(c, query)
              else ...[
                if (!_showFullList)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Showing ${results.length} matching medicine${results.length == 1 ? '' : 's'} (max 6)',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textSecondary),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Showing ${results.length} of ${_catalogItems.length} medicines',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textSecondary),
                    ),
                  ),
                if (_showFullList)
                  SizedBox(
                    height: 420,
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _buildCatalogResultRow(
                        c,
                        results[i],
                        isExpress: false,
                        showAdminActions: _canManageCatalog,
                      ),
                    ),
                  )
                else
                  Column(
                    children: [
                      for (int i = 0; i < results.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _buildCatalogResultRow(c, results[i], isExpress: false),
                      ],
                    ],
                  ),
              ],
            ],
          ),
        ),
        if (_sessionAdded.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildSessionAddedCard(c),
        ],
      ],
    );
  }

  Widget _buildGuidedStep2Details(GComfortColors c) {
    final item = _guidedSelectedItem;
    if (item == null) {
      return const SizedBox.shrink();
    }

    final currentStock = _currentStockFor(item);
    final qty = int.tryParse(_guidedQtyCtrl.text.trim()) ?? 0;
    final exp = _guidedExpiryDate;
    final expIsPast = _isPastDate(exp);
    final hasValidInput = (qty > 0 || exp != null) && !expIsPast;
    final newTotal = currentStock + qty;

    String primaryLabel;
    if (qty > 0 && exp != null) {
      primaryLabel = 'Add $qty to Stock';
    } else if (qty > 0 && exp == null) {
      primaryLabel = 'Add $qty to Stock (no expiry)';
    } else if (qty == 0 && exp != null) {
      primaryLabel = 'Save Expiry Date';
    } else {
      primaryLabel = 'Enter quantity or expiry date';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: c.brandStrong,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: _isSaving ? null : _resetGuidedToFind,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Change medicine', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 8),

          // Selected Medicine Summary Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.brandSoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.brand.withValues(alpha: 0.3)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _barcodeChip(_itemBarcode(item), large: true),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _itemName(item),
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.textPrimary),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _typeBadge(_itemType(item)),
                              if (_itemDose(item).isNotEmpty)
                                Text(
                                  _itemDose(item),
                                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textSecondary),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                _stockStatusPill(c, currentStock, large: true),
              ],
            ),
          ),
          const SizedBox(height: 22),

          // Quantity Section
          Text(
            'Quantity to add (optional)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _stepperIconButton(
                c,
                icon: Icons.remove_rounded,
                tooltip: 'Decrease quantity by 1',
                onTap: qty > 0 ? () => _adjustGuidedQty(-1) : null,
                size: 52,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  label: 'Quantity to add',
                  textField: true,
                  child: SizedBox(
                    height: 52,
                    child: TextField(
                      controller: _guidedQtyCtrl,
                      focusNode: _guidedQtyFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: '0',
                        hintStyle: TextStyle(color: c.textMuted, fontSize: 22, fontWeight: FontWeight.w600),
                        filled: true,
                        fillColor: c.surfaceSunken,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.borderStrong),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.borderStrong),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.brand, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _stepperIconButton(
                c,
                icon: Icons.add_rounded,
                tooltip: 'Increase quantity by 1',
                onTap: () => _adjustGuidedQty(1),
                size: 52,
                primaryTint: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final add in const [10, 50, 100, 500])
                _actionChipButton(
                  c,
                  label: '+$add',
                  onTap: () => _adjustGuidedQty(add),
                ),
              _actionChipButton(
                c,
                label: 'Clear',
                isMuted: true,
                onTap: _guidedQtyCtrl.text.isEmpty
                    ? null
                    : () => setState(() => _guidedQtyCtrl.clear()),
              ),
            ],
          ),
          if (qty > 0) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: c.successBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.success.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up_rounded, color: c.success, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Stock after adding: $currentStock + $qty = $newTotal',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: c.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Expiry Date Section
          Text(
            'Expiry date (optional)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _expiryQuickChip(c, '6 months', _addMonths(6), exp, (d) => setState(() => _guidedExpiryDate = d)),
              _expiryQuickChip(c, '1 year', _addMonths(12), exp, (d) => setState(() => _guidedExpiryDate = d)),
              _expiryQuickChip(c, '2 years', _addMonths(24), exp, (d) => setState(() => _guidedExpiryDate = d)),
              _expiryQuickChip(c, '3 years', _addMonths(36), exp, (d) => setState(() => _guidedExpiryDate = d)),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  foregroundColor: c.brandStrong,
                  backgroundColor: c.surfaceSunken,
                  side: BorderSide(color: c.brand.withValues(alpha: 0.45)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  final picked = await _openExpiryPicker(initialDate: exp);
                  if (picked != null && mounted) {
                    setState(() => _guidedExpiryDate = picked);
                  }
                },
                icon: const Icon(Icons.calendar_month_rounded, size: 18),
                label: Text(
                  exp != null ? _formatDisplayDate(exp) : 'Pick exact date',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
              if (exp != null)
                _actionChipButton(
                  c,
                  label: 'Clear date',
                  isMuted: true,
                  onTap: () => setState(() => _guidedExpiryDate = null),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (expIsPast)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.dangerBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.danger.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: c.danger, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Expiry (${_formatDisplayDate(exp!)}) must be after this month. Pick next month or later.',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.danger),
                    ),
                  ),
                ],
              ),
            )
          else if (exp == null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.warningBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.warning.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: c.warning, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No expiry date set. Expiry alerts will not work for this batch.',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.warning),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.event_available_rounded, color: c.brand, size: 19),
                  const SizedBox(width: 8),
                  Text(
                    'Selected expiry: ${_formatDisplayDate(exp)}',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),

          // Full-width Primary Button
          SizedBox(
            height: 54,
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                disabledBackgroundColor: c.surfaceSunken,
                disabledForegroundColor: c.textMuted,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: (hasValidInput && !_isSaving) ? _submitGuided : null,
              icon: _isSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2.5),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 22),
              label: Text(
                _isSaving ? 'Saving...' : primaryLabel,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuidedStep3Done(GComfortColors c) {
    final res = _guidedLastResult;
    if (res == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: c.successBg,
              shape: BoxShape.circle,
              border: Border.all(color: c.success.withValues(alpha: 0.4), width: 2),
            ),
            child: Icon(Icons.check_rounded, color: c.success, size: 38),
          ),
          const SizedBox(height: 16),
          Text(
            res.qtyAdded > 0 ? 'Added to Stock!' : 'Expiry Date Saved!',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: c.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            res.qtyAdded > 0
                ? 'Saved locally and queued for clinic & cloud sync.'
                : 'Batch expiry date updated locally and synced.',
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _barcodeChip(res.barcode),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        res.name,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c.textPrimary),
                      ),
                    ),
                    _typeBadge(res.type),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (res.dose.isNotEmpty)
                      _infoTag(c, Icons.science_outlined, res.dose),
                    if (res.qtyAdded > 0)
                      _infoTag(c, Icons.add_circle_outline_rounded, 'Added: +${res.qtyAdded}', highlight: c.brandStrong),
                    _infoTag(c, Icons.inventory_2_outlined, 'New stock: ${res.newStock}', highlight: c.success),
                    _infoTag(
                      c,
                      Icons.event_outlined,
                      res.expiryDate.isNotEmpty ? 'Expiry: ${res.expiryDate}' : 'No expiry set',
                      highlight: res.expiryDate.isEmpty ? c.warning : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (ctx, box) {
              final addAnother = SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.brand,
                    foregroundColor: c.onBrand,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _resetGuidedToFind,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Add another medicine', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              );
              final backBtn = SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textPrimary,
                    side: BorderSide(color: c.borderStrong),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _goBackToInventory,
                  icon: const Icon(Icons.inventory_2_outlined, size: 19),
                  label: const Text('Back to inventory', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              );

              if (box.maxWidth < 500) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [addAnother, const SizedBox(height: 10), backBtn],
                );
              }
              return Row(
                children: [
                  Expanded(child: addAnother),
                  const SizedBox(width: 12),
                  Expanded(child: backBtn),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSessionAddedCard(GComfortColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded, color: c.success, size: 19),
              const SizedBox(width: 8),
              Text(
                'Added in this session (${_sessionAdded.length})',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (int i = 0; i < _sessionAdded.length; i++) ...[
            if (i > 0) Divider(height: 14, color: c.border),
            Builder(builder: (_) {
              final r = _sessionAdded[i];
              return Row(
                children: [
                  _barcodeChip(r.barcode),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.name,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary),
                        ),
                        Text(
                          [
                            if (r.dose.isNotEmpty) r.dose,
                            r.type,
                            if (r.expiryDate.isNotEmpty) 'Exp: ${r.expiryDate}' else 'No expiry',
                          ].join(' • '),
                          style: TextStyle(fontSize: 12, color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        r.qtyAdded > 0 ? '+${r.qtyAdded}' : 'Expiry saved',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: c.brandStrong),
                      ),
                      Text(
                        'Stock: ${r.newStock}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.success),
                      ),
                    ],
                  ),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MODE 2: EXPRESS (MULTI-MEDICINE)
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildExpressBody(GComfortColors c) {
    if (_expressShowDone) {
      return _buildExpressDoneScreen(c);
    }

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final isWide = constraints.maxWidth >= 920;

        if (isWide) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: _buildExpressSearchPane(c, expandList: true)),
                const SizedBox(width: 16),
                Expanded(flex: 6, child: _buildExpressYourListPane(c, expandList: true)),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildExpressSearchPane(c, expandList: false),
              const SizedBox(height: 16),
              _buildExpressYourListPane(c, expandList: false),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExpressSearchPane(GComfortColors c, {required bool expandList}) {
    final query = _searchCtrl.text.trim();
    final hasQuery = query.isNotEmpty;
    final results = _showFullList
        ? _searchCatalog(applyTypeFilter: true)
        : (hasQuery ? _searchCatalog(applyTypeFilter: false) : const <Map<String, dynamic>>[]);

    Widget listArea;
    if (!hasQuery && !_showFullList) {
      listArea = _buildSearchIdleHint(c, isExpress: true);
    } else if (results.isEmpty) {
      listArea = _buildNoMatchesState(c, query);
    } else {
      listArea = _buildCatalogTable(
        c,
        results,
        expand: expandList,
        showAdminActions: _showFullList && _canManageCatalog,
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandList ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Text(
            'Find & scan medicines',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c.textPrimary),
          ),
          const SizedBox(height: 3),
          Text(
            'Scan box after box (Enter adds & clears) or search by name.',
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          _buildSearchField(c),
          const SizedBox(height: 10),
          _buildFullListToggleRow(c),
          if (_showFullList) ...[
            const SizedBox(height: 10),
            _buildTypeFilterPills(c),
          ],
          const SizedBox(height: 12),
          if (hasQuery || _showFullList)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Showing ${results.length} of ${_catalogItems.length} medicines',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textSecondary),
              ),
            ),
          if (expandList) Expanded(child: listArea) else listArea,
        ],
      ),
    );
  }

  Widget _buildExpressYourListPane(GComfortColors c, {required bool expandList}) {
    final count = _expressList.length;
    final invalidCount = _expressList.where((d) => (d.quantity <= 0 && d.expiryDate == null) || _isPastDate(d.expiryDate)).length;

    final listContent = _expressList.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GEmptyIllustration(GEmptyIllustrationKind.inventory, size: 140),
                  const SizedBox(height: 12),
                  Text(
                    'Your list is empty',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Scan barcodes or tap "+ Add" on medicines to build your batch.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13.5, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          )
        : ListView.separated(
            shrinkWrap: !expandList,
            physics: expandList ? null : const NeverScrollableScrollPhysics(),
            itemCount: _expressList.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _buildExpressDraftCard(c, _expressList[i]),
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandList ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your list ($count)',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.textPrimary),
                ),
              ),
              if (count > 0)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: c.danger,
                    minimumSize: const Size(44, 44),
                  ),
                  onPressed: _isSaving ? null : _clearExpressList,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear all', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          if (count > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Same expiry for everything on the list?',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _expiryQuickChip(c, '6 months', _addMonths(6), _expressBulkExpiry, _applyBulkExpiryToExpressList),
                      _expiryQuickChip(c, '1 year', _addMonths(12), _expressBulkExpiry, _applyBulkExpiryToExpressList),
                      _expiryQuickChip(c, '2 years', _addMonths(24), _expressBulkExpiry, _applyBulkExpiryToExpressList),
                      _expiryQuickChip(c, '3 years', _addMonths(36), _expressBulkExpiry, _applyBulkExpiryToExpressList),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          foregroundColor: c.brandStrong,
                          side: BorderSide(color: c.brand.withValues(alpha: 0.4)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          final picked = await _openExpiryPicker(initialDate: _expressBulkExpiry);
                          if (picked != null && mounted) _applyBulkExpiryToExpressList(picked);
                        },
                        icon: const Icon(Icons.calendar_today_rounded, size: 15),
                        label: const Text('Pick date', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                      ),
                      if (_expressBulkExpiry != null)
                        _actionChipButton(
                          c,
                          label: 'Clear all dates',
                          isMuted: true,
                          onTap: () => _applyBulkExpiryToExpressList(null),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (expandList) Expanded(child: listContent) else listContent,
          const SizedBox(height: 14),
          if (count > 0 && invalidCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 17, color: c.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$invalidCount item${invalidCount == 1 ? '' : 's'} need a quantity or valid future expiry date.',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.warning),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 54,
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                disabledBackgroundColor: c.surfaceSunken,
                disabledForegroundColor: c.textMuted,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _canSubmitExpress ? _submitExpress : null,
              icon: _isSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2.5),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 22),
              label: Text(
                _isSaving
                    ? 'Saving...'
                    : (count == 0
                        ? 'Add medicines to Stock'
                        : 'Add $count medicine${count == 1 ? '' : 's'} to Stock'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpressDraftCard(GComfortColors c, _ExpressItemDraft draft) {
    final item = draft.catalogItem;
    final currentStock = _currentStockFor(item);
    final qty = draft.quantity;
    final exp = draft.expiryDate;
    final isPast = _isPastDate(exp);
    final isMissingBoth = qty <= 0 && exp == null;
    final borderColor = isPast
        ? c.danger.withValues(alpha: 0.65)
        : (isMissingBoth ? c.warning.withValues(alpha: 0.55) : c.borderStrong);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: (isPast || isMissingBoth) ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _barcodeChip(_itemBarcode(item)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _itemName(item),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _typeBadge(_itemType(item)),
                        if (_itemDose(item).isNotEmpty)
                          Text(_itemDose(item), style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                        _stockStatusPill(c, currentStock),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove ${_itemName(item)} from list',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(Icons.close_rounded, color: c.danger, size: 20),
                onPressed: () => _removeExpressItem(draft.keyCode),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Quantity Stepper
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _stepperIconButton(
                    c,
                    icon: Icons.remove_rounded,
                    tooltip: 'Decrease quantity',
                    onTap: qty > 0
                        ? () {
                            final next = qty - 1;
                            draft.qtyController.text = next > 0 ? '$next' : '';
                          }
                        : null,
                    size: 44,
                  ),
                  const SizedBox(width: 6),
                  Semantics(
                    label: 'Quantity for ${_itemName(item)}',
                    textField: true,
                    child: SizedBox(
                      width: 82,
                      height: 44,
                      child: TextField(
                        controller: draft.qtyController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Qty',
                          hintStyle: TextStyle(color: c.textMuted, fontSize: 13.5),
                          filled: true,
                          fillColor: c.surface,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: c.borderStrong),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: c.borderStrong),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: c.brand, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _stepperIconButton(
                    c,
                    icon: Icons.add_rounded,
                    tooltip: 'Increase quantity',
                    onTap: () => draft.qtyController.text = '${qty + 1}',
                    size: 44,
                    primaryTint: true,
                  ),
                ],
              ),
              // Expiry Picker
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      backgroundColor: c.surface,
                      foregroundColor: isPast ? c.danger : (exp != null ? c.brandStrong : c.textSecondary),
                      side: BorderSide(color: isPast ? c.danger : c.borderStrong),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      final picked = await _openExpiryPicker(initialDate: exp);
                      if (picked != null && mounted) {
                        setState(() => draft.expiryDate = picked);
                      }
                    },
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(
                      exp != null ? _formatDisplayDate(exp) : 'Expiry date',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (exp != null)
                    IconButton(
                      tooltip: 'Clear expiry date',
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      icon: Icon(Icons.clear_rounded, size: 18, color: c.textMuted),
                      onPressed: () => setState(() => draft.expiryDate = null),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isPast)
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: c.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Expiry must be after this month.',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.danger),
                  ),
                ),
              ],
            )
          else if (isMissingBoth)
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enter a quantity or pick an expiry date.',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.warning),
                  ),
                ),
              ],
            )
          else if (qty > 0 && exp == null)
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Stock after adding: $currentStock + $qty = ${currentStock + qty} • No expiry set (alerts disabled).',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.warning),
                  ),
                ),
              ],
            )
          else if (qty > 0)
            Text(
              'Stock after adding: $currentStock + $qty = ${currentStock + qty}',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.success),
            )
          else
            Text(
              'Will update expiry date only (stock stays $currentStock).',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.brandStrong),
            ),
        ],
      ),
    );
  }

  Widget _buildExpressDoneScreen(GComfortColors c) {
    final totalUnits = _expressLastResults.fold<int>(0, (s, r) => s + r.qtyAdded);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    color: c.successBg,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.success.withValues(alpha: 0.4), width: 2),
                  ),
                  child: Icon(Icons.check_rounded, color: c.success, size: 36),
                ),
                const SizedBox(height: 14),
                Text(
                  '${_expressLastResults.length} Medicine${_expressLastResults.length == 1 ? '' : 's'} Updated!',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: c.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  totalUnits > 0
                      ? 'Added $totalUnits total units • Saved locally and synced.'
                      : 'Expiry dates updated • Saved locally and synced.',
                  style: TextStyle(fontSize: 14, color: c.textSecondary),
                ),
                const SizedBox(height: 20),
                for (int i = 0; i < _expressLastResults.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Builder(builder: (_) {
                    final r = _expressLastResults[i];
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.border),
                      ),
                      child: Row(
                        children: [
                          _barcodeChip(r.barcode),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary)),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    if (r.dose.isNotEmpty) r.dose,
                                    r.type,
                                    if (r.expiryDate.isNotEmpty) 'Expiry: ${r.expiryDate}' else 'No expiry',
                                  ].join(' • '),
                                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                r.qtyAdded > 0 ? '+${r.qtyAdded}' : 'Expiry saved',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: c.brandStrong),
                              ),
                              Text(
                                'New stock: ${r.newStock}',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.success),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.brand,
                            foregroundColor: c.onBrand,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            setState(() {
                              _expressShowDone = false;
                              _searchCtrl.clear();
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearch());
                          },
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('Add more medicines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: c.textPrimary,
                            side: BorderSide(color: c.borderStrong),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _goBackToInventory,
                          icon: const Icon(Icons.inventory_2_outlined, size: 19),
                          label: const Text('Back to inventory', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
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

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED BUILDING BLOCKS
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildSearchField(GComfortColors c) {
    return Semantics(
      label: 'Search medicine by barcode or name',
      textField: true,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocusNode,
        textInputAction: TextInputAction.search,
        onSubmitted: _handleSearchSubmitted,
        cursorColor: c.brand,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary),
        decoration: InputDecoration(
          labelText: 'Barcode or medicine name',
          labelStyle: TextStyle(color: c.textSecondary, fontSize: 14, fontWeight: FontWeight.w600),
          hintText: 'Scan barcode (e.g. 079) or type medicine name...',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 14.5, fontWeight: FontWeight.w400),
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Icon(Icons.qr_code_scanner_rounded, color: c.brand, size: 24),
          ),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear search',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.close_rounded, color: c.textSecondary, size: 20),
                  onPressed: () {
                    _searchCtrl.clear();
                    _focusSearch();
                  },
                )
              : null,
          filled: true,
          fillColor: c.surfaceSunken,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: c.borderStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: c.borderStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: c.brand, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _buildFullListToggleRow(GComfortColors c) {
    return Row(
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(44, 44),
            backgroundColor: _showFullList ? c.brandSoft : c.surfaceSunken,
            foregroundColor: _showFullList ? c.brandStrong : c.textPrimary,
            side: BorderSide(color: _showFullList ? c.brand : c.borderStrong),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          onPressed: () => setState(() => _showFullList = !_showFullList),
          icon: Icon(
            _showFullList ? Icons.unfold_less_rounded : Icons.view_list_rounded,
            size: 19,
          ),
          label: Text(
            _showFullList
                ? 'Hide full list (${_catalogItems.length})'
                : 'Show full list (${_catalogItems.length})',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildTypeFilterPills(GComfortColors c) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < _availableTypes.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Builder(builder: (_) {
              final cat = _availableTypes[i];
              final selected = _selectedTypeFilter == cat;
              return InkWell(
                onTap: () => setState(() => _selectedTypeFilter = cat),
                borderRadius: BorderRadius.circular(22),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  constraints: const BoxConstraints(minHeight: 44),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? c.brand : c.surfaceSunken,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: selected ? c.brand : c.borderStrong),
                  ),
                  child: Text(
                    cat,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected ? c.onBrand : c.textPrimary,
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchIdleHint(GComfortColors c, {required bool isExpress}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GEmptyIllustration(GEmptyIllustrationKind.search, size: 128),
          const SizedBox(height: 10),
          Text(
            isExpress
                ? 'Scan a barcode or type to find medicines'
                : 'Start typing a medicine name or scan its barcode',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Or tap "Show full list (${_catalogItems.length})" above to browse by medicine type.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildNoMatchesState(GComfortColors c, String query) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 42, color: c.textMuted),
          const SizedBox(height: 10),
          Text(
            query.isEmpty
                ? 'No medicines in this category'
                : 'No medicine found for "$query"',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: c.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            _canRegisterMedicine
                ? 'Check the spelling or register it as a brand-new medicine in the catalog.'
                : 'Check the spelling or barcode number. Only authorized supervisors/admins can register new medicines.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: c.textSecondary),
          ),
          if (_canRegisterMedicine) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 46,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.brand,
                  foregroundColor: c.onBrand,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _openRegisterNewMedicine,
                icon: const Icon(Icons.add_circle_outline_rounded, size: 19),
                label: const Text('Register new medicine', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Express list as a dense table: # · Barcode · Medicine · (Dose · Type on wide panes) ·
  /// Stock · actions · Add. Header stays put while rows scroll.
  Widget _buildCatalogTable(
    GComfortColors c,
    List<Map<String, dynamic>> results, {
    required bool expand,
    required bool showAdminActions,
  }) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 720;
      const idxW = 40.0;
      const barW = 72.0;
      const doseW = 90.0;
      const typeW = 96.0;
      const stockW = 84.0;
      final actW = showAdminActions ? 40.0 : 0.0;
      const addW = 92.0;

      TextStyle head() => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: c.textMuted,
          );

      Widget header = Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(children: [
          SizedBox(width: idxW, child: Text('#', style: head(), textAlign: TextAlign.center)),
          SizedBox(width: barW, child: Text('BARCODE', style: head())),
          Expanded(child: Text('MEDICINE', style: head())),
          if (wide) SizedBox(width: doseW, child: Text('DOSE', style: head())),
          if (wide) SizedBox(width: typeW, child: Text('TYPE', style: head())),
          SizedBox(width: stockW, child: Text('STOCK', style: head(), textAlign: TextAlign.end)),
          SizedBox(width: actW),
          const SizedBox(width: addW),
        ]),
      );

      Widget row(int i) {
        final item = results[i];
        final barcode = _itemBarcode(item);
        final name = _itemName(item);
        final dose = _itemDose(item);
        final type = _itemType(item);
        final qty = _currentStockFor(item);
        final added = _isInExpressList(item);
        final bg = added ? c.brandSoft : (i.isEven ? c.surface : c.surfaceSunken.withValues(alpha: 0.45));
        return Material(
          color: bg,
          child: InkWell(
            onTap: () => _toggleExpressItem(item),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border.withValues(alpha: 0.6)))),
              child: Row(children: [
                SizedBox(
                  width: idxW,
                  child: Text('${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ),
                SizedBox(
                  width: barW,
                  child: Align(alignment: AlignmentDirectional.centerStart, child: _barcodeChip(barcode)),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.textPrimary)),
                    if (!wide && (dose.isNotEmpty || type.isNotEmpty))
                      Text(
                        [if (dose.isNotEmpty) dose, if (type.isNotEmpty) type].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                      ),
                  ]),
                ),
                if (wide)
                  SizedBox(
                    width: doseW,
                    child: Text(dose.isEmpty ? '—' : dose,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                  ),
                if (wide)
                  SizedBox(
                    width: typeW,
                    child: Align(alignment: AlignmentDirectional.centerStart, child: _typeBadge(type)),
                  ),
                SizedBox(
                  width: stockW,
                  child: Text(
                    qty > 0 ? '$qty' : '—',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: qty > 0 ? c.success : c.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (showAdminActions)
                  SizedBox(
                    width: actW,
                    child: PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: Icon(GIcons.more, size: 18, color: c.textMuted),
                      onSelected: (v) {
                        if (v == 'edit') _showEditCatalogMedicineDialog(item);
                        if (v == 'delete') _showDeleteCatalogMedicineDialog(item);
                        if (v == 'history') _showCatalogAuditDialog(item);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Row(children: [Icon(GIcons.edit, size: 17, color: c.brand), const SizedBox(width: 10), const Text('Edit catalog medicine')])),
                        PopupMenuItem(value: 'history', child: Row(children: [Icon(GIcons.history, size: 17, color: c.textMuted), const SizedBox(width: 10), const Text('Audit history')])),
                        PopupMenuItem(value: 'delete', child: Row(children: [Icon(GIcons.delete, size: 17, color: c.danger), const SizedBox(width: 10), const Text('Delete from catalog')])),
                      ],
                    ),
                  ),
                SizedBox(
                  width: addW,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SizedBox(
                      height: 34,
                      child: added
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: c.brand,
                                foregroundColor: c.onBrand,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => _toggleExpressItem(item),
                              icon: const Icon(GIcons.check, size: 15),
                              label: const Text('Added', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            )
                          : OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.brandStrong,
                                side: BorderSide(color: c.brand),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => _toggleExpressItem(item),
                              icon: const Icon(GIcons.add, size: 15),
                              label: const Text('Add', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                            ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      }

      final body = ListView.builder(
        shrinkWrap: !expand,
        itemCount: results.length,
        itemBuilder: (_, i) => row(i),
      );

      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            header,
            if (expand)
              Expanded(child: body)
            else
              ConstrainedBox(constraints: const BoxConstraints(maxHeight: 360), child: body),
          ],
        ),
      );
    });
  }

  Widget _buildCatalogResultRow(
    GComfortColors c,
    Map<String, dynamic> item, {
    required bool isExpress,
    bool showAdminActions = false,
  }) {
    final barcode = _itemBarcode(item);
    final name = _itemName(item);
    final dose = _itemDose(item);
    final type = _itemType(item);
    final inStockQty = _currentStockFor(item);
    final isAdded = isExpress && _isInExpressList(item);

    return Material(
      color: isAdded ? c.brandSoft : c.surfaceSunken,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          if (isExpress) {
            _toggleExpressItem(item);
          } else {
            _selectForGuided(item);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isAdded ? c.brand : c.borderStrong,
              width: isAdded ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              _barcodeChip(barcode),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c.textPrimary),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (dose.isNotEmpty)
                          Text(dose, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSecondary)),
                        _typeBadge(type),
                        _stockStatusPill(c, inStockQty),
                      ],
                    ),
                  ],
                ),
              ),
              if (showAdminActions) ...[
                IconButton(
                  tooltip: 'Edit catalog medicine',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.edit_note_rounded, color: c.brand, size: 20),
                  onPressed: () => _showEditCatalogMedicineDialog(item),
                ),
                IconButton(
                  tooltip: 'Delete from catalog',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.delete_outline_rounded, color: c.danger, size: 19),
                  onPressed: () => _showDeleteCatalogMedicineDialog(item),
                ),
                IconButton(
                  tooltip: 'View audit history',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.history_rounded, color: c.textMuted, size: 19),
                  onPressed: () => _showCatalogAuditDialog(item),
                ),
              ],
              const SizedBox(width: 8),
              if (isExpress)
                SizedBox(
                  height: 44,
                  child: isAdded
                      ? ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.brand,
                            foregroundColor: c.onBrand,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => _toggleExpressItem(item),
                          icon: const Icon(Icons.check_rounded, size: 17),
                          label: const Text('Added', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                        )
                      : OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: c.brandStrong,
                            backgroundColor: c.surface,
                            side: BorderSide(color: c.brand),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => _toggleExpressItem(item),
                          child: const Text('+ Add', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                        ),
                )
              else
                SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.brand,
                      foregroundColor: c.onBrand,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _selectForGuided(item),
                    child: const Text('Select', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Visual Chips & Controls ───────────────────────────────────────────────
  Widget _barcodeChip(String barcode, {bool large = false}) {
    final c = context.comfort;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 9, vertical: large ? 7 : 5),
      decoration: BoxDecoration(
        color: c.brandSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.brand.withValues(alpha: 0.35)),
      ),
      child: Text(
        barcode,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: large ? 14.5 : 13,
          fontWeight: FontWeight.w800,
          color: c.brandStrong,
        ),
      ),
    );
  }

  Widget _stockStatusPill(GComfortColors c, int qty, {bool large = false}) {
    final inStock = qty > 0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 9, vertical: large ? 6 : 3),
      decoration: BoxDecoration(
        color: inStock ? c.successBg : c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: inStock ? c.success.withValues(alpha: 0.4) : c.borderStrong,
        ),
      ),
      child: Text(
        inStock ? 'In stock: $qty' : 'Not in stock',
        style: TextStyle(
          fontSize: large ? 13.5 : 12,
          fontWeight: FontWeight.w700,
          color: inStock ? c.success : c.textSecondary,
        ),
      ),
    );
  }

  Widget _typeBadge(String type) {
    final raw = _getTypeBadgeColor(type);
    final color = _isDark ? Color.lerp(raw, SoftPalette.gray50, 0.3)! : raw;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _isDark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        type,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  Widget _stepperIconButton(
    GComfortColors c, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    double size = 44,
    bool primaryTint = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: onTap == null
                ? c.surfaceSunken
                : (primaryTint ? c.brandSoft : c.surface),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: onTap == null
                  ? c.border
                  : (primaryTint ? c.brand.withValues(alpha: 0.45) : c.borderStrong),
            ),
          ),
          child: Icon(
            icon,
            size: 22,
            color: onTap == null
                ? c.textMuted
                : (primaryTint ? c.brandStrong : c.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _actionChipButton(
    GComfortColors c, {
    required String label,
    required VoidCallback? onTap,
    bool isMuted = false,
  }) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(56, 44),
        backgroundColor: isMuted ? c.surfaceSunken : c.surface,
        foregroundColor: isMuted ? c.textSecondary : c.brandStrong,
        side: BorderSide(color: isMuted ? c.borderStrong : c.brand.withValues(alpha: 0.4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
    );
  }

  Widget _expiryQuickChip(
    GComfortColors c,
    String label,
    DateTime targetDate,
    DateTime? selected,
    ValueChanged<DateTime> onSelected,
  ) {
    final isMatch = selected != null &&
        selected.year == targetDate.year &&
        selected.month == targetDate.month &&
        selected.day == targetDate.day;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: isMatch ? c.brand : c.surface,
        foregroundColor: isMatch ? c.onBrand : c.textPrimary,
        side: BorderSide(color: isMatch ? c.brand : c.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      onPressed: () => onSelected(targetDate),
      child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
    );
  }

  Widget _infoTag(GComfortColors c, IconData icon, String label, {Color? highlight}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: (highlight ?? c.borderStrong).withValues(alpha: highlight != null ? 0.35 : 1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: highlight ?? c.textSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: highlight ?? c.textPrimary),
          ),
        ],
      ),
    );
  }

  Color _getTypeBadgeColor(String type) {
    if (_isDark) {
      switch (type.trim().toLowerCase()) {
        case 'tablet':
          return SoftPalette.blue550;
        case 'capsule':
          return SoftPalette.violet550;
        case 'syrup':
          return SoftPalette.orange550;
        case 'injection':
          return SoftPalette.red550;
        case 'drip':
        case 'infusion':
          return SoftPalette.teal550;
        case 'drip set':
          return SoftPalette.sky550;
        case 'syringe':
          return SoftPalette.pink550;
        case 'cannula':
        case 'needle':
        case 'cannula & needle':
        case 'cannula / needle':
          return SoftPalette.pink600;
        case 'nebulization':
          return SoftPalette.indigo600;
        case 'dressing item':
          return SoftPalette.slate700;
        case 'consumables':
          return SoftPalette.teal550;
        default:
          return SoftPalette.slate700;
      }
    }
    switch (type.trim().toLowerCase()) {
      case 'tablet':
        return SoftPalette.blue550;
      case 'capsule':
        return SoftPalette.purple600;
      case 'syrup':
        return SoftPalette.orange400;
      case 'injection':
        return SoftPalette.red550;
      case 'drip':
      case 'infusion':
        return SoftPalette.teal600;
      case 'drip set':
        return SoftPalette.cyan500;
      case 'syringe':
        return SoftPalette.pink550;
      case 'cannula':
      case 'needle':
      case 'cannula & needle':
      case 'cannula / needle':
        return SoftPalette.purple600;
      case 'nebulization':
        return SoftPalette.indigo700;
      case 'dressing item':
        return SoftPalette.slate600;
      case 'consumables':
        return SoftPalette.teal550;
      default:
        return SoftPalette.slate600;
    }
  }
}
