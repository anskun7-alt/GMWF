// lib/pages/dispensary/dispensar/inventory_update.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/design/design_system.dart' hide AppFeedback;
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/expiry_rules.dart';
import 'package:gmwf/services/stock/stock_log.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
import 'package:gmwf/utils/string_similarity_helper.dart';
import 'package:gmwf/pages/dispensary/dispensar/add_medicine_page.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/widgets/app_back_button.dart';
import 'package:gmwf/widgets/camp_selector_chip.dart';
import 'package:gmwf/services/cloud_messaging_service.dart';
import 'package:gmwf/widgets/app_feedback.dart';
import 'package:gmwf/pages/dispensary/widgets/medicine_icon_badge.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GIcons;

class InventoryUpdatePage extends StatefulWidget {
  final String branchId;
  final bool isAdmin;
  final bool isDispenser;
  final bool isDoctor;
  final bool isEmbedded;
  final int showMode; // 0: both, 1: Add Stock, 2: Register New

  const InventoryUpdatePage({
    super.key,
    required this.branchId,
    this.isAdmin = false,
    this.isDispenser = false,
    this.isDoctor = false,
    this.isEmbedded = false,
    this.showMode = 0,
  });

  @override
  State<InventoryUpdatePage> createState() => _InventoryUpdatePageState();
}

class _InventoryUpdatePageState extends State<InventoryUpdatePage>
    with TickerProviderStateMixin {
  // ── Palette ───────────────────────────────────────────────────────────────
  Color get _teal => context.comfort.brand;
  static const _green600 = SoftPalette.green550;
  static const _red = SoftPalette.red500; // Vibrant red
  static const _textDark = SoftPalette.slate800;
  static const _textMid = SoftPalette.slate600;
  static const _shadow = SoftPalette.teal600A9;

  late TabController _tabCtrl;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  // ── Add Stock state ───────────────────────────────────────────────────────
  final _searchCtrl = TextEditingController();
  bool _isSearching = false;
  List<Map<String, dynamic>> _allConsolidatedMeds = [];
  List<Map<String, dynamic>> _searchResults = [];
  bool _hasSearched = false;
  Map<String, dynamic>? _selectedMed;
  String? _selectedDocId;
  final _addQtyCtrl = TextEditingController(text: '1');
  bool _isSubmittingStock = false;
  late String _currentBranchId;
  String _selectedCampFilter = 'all';
  String _selectedTypeFilter = 'All';
  String _stockStatusFilter = 'all'; // 'all', 'low', 'in_stock'

  String get _effectiveBranchId =>
      CampSessionService.isKarachiFamily(_currentBranchId) ? 'karachi' : _currentBranchId;

  String _initialCampFilter() {
    if (!_hasMultiCamps) return 'all';
    final active = CampSessionService.getActiveCamp(_effectiveBranchId);
    return (active != null && active.isNotEmpty && active != 'all') ? active : 'all';
  }

  void _onActiveCampChanged() {
    if (!mounted || !_hasMultiCamps) return;
    final active = CampSessionService.getActiveCamp(_effectiveBranchId);
    if (active != null && active.isNotEmpty && active != _selectedCampFilter) {
      setState(() {
        _selectedCampFilter = active;
        _selectedMed = null;
        _selectedDocId = null;
      });
      _loadAllMedicines();
    }
  }

  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) return Map<String, dynamic>.from(uData);
      }
    } catch (_) {}
    return {};
  }

  bool get _isMultiBranchUser {
    if (widget.isAdmin) return true;
    final uData = _getUserData();
    final role = (uData['role'] ?? uData['userRole'] ?? '').toString().toLowerCase();
    if (role.contains('admin') || role.contains('director') || role.contains('supervisor') || role.contains('head') || role.contains('president') || role.contains('chairman') || role.contains('manager')) {
      return true;
    }
    final branches = uData['accessibleBranches'] ?? uData['branches'];
    if (branches is List && branches.length > 1) return true;
    return false;
  }

  List<String> get _availableBranches {
    final uData = _getUserData();
    final branches = uData['accessibleBranches'] ?? uData['branches'];
    if (branches is List && branches.isNotEmpty) {
      final list = branches.map((e) => e.toString().toLowerCase().trim()).toSet().toList();
      if (!list.contains(_currentBranchId.toLowerCase().trim())) {
        list.add(_currentBranchId.toLowerCase().trim());
      }
      return list;
    }
    return [_currentBranchId.toLowerCase().trim()];
  }

  void _onBranchChanged(String newBranch) {
    if (newBranch == _currentBranchId) return;
    setState(() {
      _currentBranchId = newBranch;
      _selectedCampFilter = _initialCampFilter();
      _selectedMed = null;
      _selectedDocId = null;
    });
    _loadAllMedicines();
  }

  String get _effectiveTargetCamp {
    if (!_hasMultiCamps) return '';
    if (_selectedMed != null) {
      final mCamp = (_selectedMed!['campId'] ?? _selectedMed!['dispensaryId'])?.toString().toLowerCase().trim();
      if (mCamp != null && mCamp.isNotEmpty && mCamp != 'all') return mCamp;
    }
    if (_selectedCampFilter != 'all') return _selectedCampFilter;
    final active = CampSessionService.getActiveCamp(_effectiveBranchId);
    if (active != null && active.isNotEmpty && active != 'all') return active;
    final configuredCamps = CampSessionService.getCampsForBranch(_effectiveBranchId);
    if (configuredCamps.isNotEmpty) {
      return configuredCamps.first['id']?.toString() ?? '';
    }
    return CampSessionService.isKarachiFamily(_effectiveBranchId) ? 'saddar' : '';
  }

  bool get _hasMultiCamps => CampSessionService.hasCampsForBranch(_effectiveBranchId);

  // ── Stock book ────────────────────────────────────────────────────────────
  /// Pools this screen lists: the selected camp's pool, or every pool of the branch.
  List<StockPool> _viewPools() {
    final sel = _selectedCampFilter.trim();
    if (sel.isEmpty || sel.toLowerCase() == 'all') return StockPool.allFor(_effectiveBranchId);
    final p = StockPool.of(_effectiveBranchId, sel,
        fallbackCamp: CampSessionService.getActiveCamp(_effectiveBranchId));
    return p == null ? const [] : [p];
  }

  /// Every ledger batch of the listed pools; each keeps its own `pool` and `id`.
  List<Map<String, dynamic>> _ledgerItems() {
    final out = <Map<String, dynamic>>[];
    for (final pool in _viewPools()) {
      for (final rec in StockReader.batches(pool)) {
        final m = Map<String, dynamic>.from(rec);
        m['id'] = (m['medicineId'] ?? m['id']).toString();
        m['pool'] = pool.key;
        out.add(m);
      }
    }
    return out;
  }

  /// Sends an audit entry to the cloud inventory_log (Medicine Ledger history). Stock
  /// figures themselves travel as stock-book movements, never through this.
  Future<void> _uploadInventoryLog(Map<String, dynamic> logData) async {
    // The entry is already saved locally (saveLocalInventoryLog gave it its id). StockLog
    // sends it over the LAN to every PC; the LAN server / a standalone PC uploads it.
    logData['branchId'] ??= _effectiveBranchId;
    await StockLog.share(logData);
    SyncService().triggerUpload();
  }

  /// Pool of a listed record (its own `pool`), else the pool of [camp] in this branch.
  StockPool? _poolFor(Map med, [String? camp]) =>
      StockActions.poolOf(med) ??
      StockPool.of(_effectiveBranchId, camp, fallbackCamp: CampSessionService.getActiveCamp(_effectiveBranchId));

  // ── Register New Medicine state ───────────────────────────────────────────
  final _regFormKey = GlobalKey<FormState>();
  final _regNameCtrl = TextEditingController();
  final _regQtyCtrl = TextEditingController(text: '1');
  final _regExpCtrl = TextEditingController();
  final _regPriceCtrl = TextEditingController();
  final _regDoseCtrl = TextEditingController();
  final _regCodeCtrl = TextEditingController();
  final _regPackBarcodeCtrl = TextEditingController();
  final _regReasonCtrl = TextEditingController();
  String _regType = 'Tablet';
  String? _regSelectedDose;
  bool _isSubmittingReg = false;
  Map<String, dynamic>? _liveSpellingSuggestion;

  bool get _canRegisterMedicine {
    if (widget.isDispenser || widget.isDoctor) return false;
    if (widget.isAdmin) return true;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) {
          final raw = (uData['role'] ?? uData['userRole'] ?? '').toString();
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
      }
    } catch (_) {}
    return false;
  }

  void _onRegNameChanged() {
    final text = _regNameCtrl.text.trim();
    if (text.length < 3) {
      if (_liveSpellingSuggestion != null) setState(() => _liveSpellingSuggestion = null);
      return;
    }
    final candidates = <Map<String, dynamic>>[
      ...MasterProformaService.getAllItems(),
      ..._searchResults,
    ];
    final matches = StringSimilarityHelper.findSimilarMedicines(text, candidates, threshold: 0.60);
    if (matches.isNotEmpty) {
      final best = matches.first;
      final bestName = (best['name'] as String? ?? '').trim();
      if (bestName.toLowerCase() != text.toLowerCase()) {
        if (_liveSpellingSuggestion != best) {
          setState(() => _liveSpellingSuggestion = best);
        }
        return;
      }
    }
    if (_liveSpellingSuggestion != null) setState(() => _liveSpellingSuggestion = null);
  }

  final List<String> _allTypes = [
    'Tablet', 'Capsule', 'Syrup', 'Injection', 'Infusion',
    'Drip Set', 'Syringe', 'Cannula', 'Nebulization', 'Dressing Item', 'Consumables', 'Others',
  ];

  final Map<String, List<String>> _doseOptions = {
    'Tablet': [
      '2 mg',
      '5 mg',
      '8 mg',
      '20 mg',
      '40 mg',
      '50 mg',
      '100 mg',
      '250 mg',
      '300 mg',
      '400 mg',
      '500 mg',
      '650 mg',
      '1 g'
    ],
    'Capsule': [
      '2 mg',
      '5 mg',
      '10 mg',
      '20 mg',
      '25 mg',
      '40 mg',
      '50 mg',
      '100 mg',
      '250 mg',
      '500 mg'
    ],
    'Syrup': ['5 ml', '10 ml', '15 ml', '20 ml', '30 ml', '60 ml', '90 ml', '120 ml', '250 ml'],
    'Injection': ['1cc', '2cc', '3cc', '5cc', '10cc'],
    'Infusion': ['100 ml', '250 ml', '450 ml', '500 ml', '1000 ml'],
    'Drip': ['100 ml', '250 ml', '450 ml', '500 ml', '1000 ml'],
    'Syringe': ['1cc', '3cc', '5cc', '10cc', '20cc', '50cc'],
    'Cannula': ['18"', '20"', '21"', '22"', '23"', '24"', '25"', '26"', '27"', '30"'],
  };

  bool get _hasDoseDropdown => _doseOptions.containsKey(_regType);
  bool get _usesFreeTextDose =>
      !_doseOptions.containsKey(_regType) &&
      _regType != 'Drip Set' &&
      _regType != 'Syringe' &&
      _regType != 'Cannula';

  // ── INIT & LIFECYCLE ────────────────────────────────═══════════════════════
  @override
  void initState() {
    super.initState();
    _currentBranchId = widget.branchId;
    _selectedCampFilter = _initialCampFilter();

    _tabCtrl = TabController(length: _canRegisterMedicine ? 2 : 1, vsync: this);
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _fadeAnim =
        CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();

    _regNameCtrl.addListener(_onRegNameChanged);
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    _loadAllMedicines();
  }

  @override
  void didUpdateWidget(covariant InventoryUpdatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchId != widget.branchId) {
      _currentBranchId = widget.branchId;
      _selectedCampFilter = _initialCampFilter();
      _loadAllMedicines();
    }
  }

  @override
  void dispose() {
    debugPrint('[InventoryUpdate] page State disposed (showMode ${widget.showMode}, embedded ${widget.isEmbedded})');
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    _regNameCtrl.removeListener(_onRegNameChanged);
    _tabCtrl.dispose();
    _fadeCtrl.dispose();
    _searchCtrl.dispose();
    _addQtyCtrl.dispose();
    _regNameCtrl.dispose();
    _regQtyCtrl.dispose();
    _regExpCtrl.dispose();
    _regPriceCtrl.dispose();
    _regDoseCtrl.dispose();
    _regCodeCtrl.dispose();
    _regPackBarcodeCtrl.dispose();
    _regReasonCtrl.dispose();
    super.dispose();
  }

  // ── Helper methods ────────────────────────────────────────────────────────
  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    if (err) {
      AppFeedback.showError(context, msg);
    } else {
      AppFeedback.showSuccess(context, msg);
    }
  }

  // ── Barcode uniqueness check ────────────────────────────────────────────
  Future<bool> _isBarcodeTaken(String code, {String? excludeDocId}) async {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return false;

    // 1. Check Master Proforma catalog
    final profMatch = MasterProformaService.findExactBarcodeMatch(code);
    if (profMatch != null) return true;

    // 2. Check local stock items in active camp
    final localItems = _ledgerItems();
    final queryInt = int.tryParse(normalized);
    final localMatch = localItems.any((item) {
      final itemCode = (item['code']?.toString().trim().toLowerCase() ?? item['barcode']?.toString().trim().toLowerCase() ?? '');
      final itemPack = (item['packBarcode']?.toString().trim().toLowerCase() ?? '');
      if (itemCode.isEmpty && itemPack.isEmpty) return false;
      final itemDocId = item['_docId'] ?? item['id'] ?? item['docId'];
      if (excludeDocId != null && itemDocId == excludeDocId) return false;
      if (itemCode == normalized || (itemPack.isNotEmpty && itemPack == normalized)) return true;
      if (queryInt != null) {
        final itemInt = int.tryParse(itemCode);
        if (itemInt != null && itemInt == queryInt) return true;
      }
      return false;
    });
    return localMatch;
  }

  /// Returns existing medicine matching barcode if found
  Future<Map<String, dynamic>?> _findExistingByBarcode(String code) async {
    final cleanCode = code.trim().toLowerCase();
    if (cleanCode.isEmpty) return null;

    final profMatch = MasterProformaService.findExactBarcodeMatch(code);
    if (profMatch != null) return profMatch;

    final localItems = _ledgerItems();
    final queryInt = int.tryParse(cleanCode);
    for (final item in localItems) {
      final itemCode = (item['code']?.toString().trim().toLowerCase() ?? item['barcode']?.toString().trim().toLowerCase() ?? '');
      if (itemCode.isNotEmpty) {
        if (itemCode == cleanCode) return item;
        if (queryInt != null) {
          final itemInt = int.tryParse(itemCode);
          if (itemInt != null && itemInt == queryInt) return item;
        }
      }
    }
    return null;
  }

  /// Checks if a medicine with exact Name + Dose + Type already exists in catalog or local stock
  Future<Map<String, dynamic>?> _findExistingNameDoseTypeMatch(String name, String type, String dose, {String? excludeDocId}) async {
    final cleanN = name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final cleanT = type.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final cleanD = dose.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (cleanN.isEmpty) return null;

    final profMatch = MasterProformaService.findExactNameDoseTypeMatch(name, type, dose);
    if (profMatch != null) return profMatch;

    final localItems = _ledgerItems();
    for (final item in localItems) {
      final itemDocId = item['_docId'] ?? item['id'] ?? item['docId'];
      if (excludeDocId != null && itemDocId == excludeDocId) continue;

      final itemN = (item['name'] as String? ?? item['formula'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final itemT = (item['type'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final itemD = (item['dose'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

      final matchesName = (itemN == cleanN);
      final matchesType = (itemT == cleanT);
      final matchesDose = (cleanD.isEmpty || itemD == cleanD || itemD == 'standard');

      if (matchesName && matchesType && matchesDose) {
        return item;
      }
    }

    return null;
  }

  // ── Submit: Edit Request (needs approval or direct update for admin) ─────
  Future<void> _submitEditRequest(
      Map<String, dynamic> originalMed, Map<String, dynamic> updatedFields) async {
    try {
      final userInfo = await _getUserInfo();

      if (!_editNeedsApproval) {
        final docId = (originalMed['_docId'] ?? originalMed['id'] ?? originalMed['medicineId'])?.toString();
        if (docId != null && docId.isNotEmpty) {
          // Stock book: details via saveDetails (never quantity); a changed quantity is
          // recorded as a counted difference on this one batch. StockActions sends both to
          // the LAN server and the cloud.
          final pool = _poolFor(originalMed, (originalMed['campId'] ?? originalMed['dispensaryId'])?.toString());
          if (pool == null) {
            _snack('Please select a specific camp above before editing.', err: true);
            return;
          }
          final details = Map<String, dynamic>.from(updatedFields)
            ..removeWhere((k, _) => const {'quantity', 'stock', '_quantityDelta', 'pool', 'id', 'medicineId', '_docId', '_docIds', 'reason'}.contains(k));
          await StockActions.saveDetails(pool, docId, details);
          if (updatedFields.containsKey('quantity')) {
            final newQ = updatedFields['quantity'];
            final oldQ = originalMed['quantity'];
            final n = newQ is num ? newQ.toDouble() : double.tryParse(newQ?.toString() ?? '');
            final o = oldQ is num ? oldQ.toDouble() : double.tryParse(oldQ?.toString() ?? '');
            if (n != null && n != o) {
              await StockActions.setCounted(pool, docId, n, reason: 'edit medicine');
            }
          }

          final logData = {
            'action': 'edit_medicine_directly',
            'medicineName': originalMed['name'],
            'medicineId': docId,
            'pool': pool.key,
            'expiryBefore': originalMed['expiryDate'],
            'quantityBefore': originalMed['quantity'],
            'reason': updatedFields['reason'] ?? '',
            'updatedFields': updatedFields,
            'performedBy': userInfo['uid'],
            'performedByName': userInfo['username'],
            'branchId': widget.branchId,
            'timestamp': DateTime.now().toIso8601String(),
            'createdAt': DateTime.now().toIso8601String(),
          };
          await LocalStorageService.saveLocalInventoryLog(logData);
          await _uploadInventoryLog(logData);

          _snack('Medicine updated successfully!');
          _loadAllMedicines();
          return;
        }
      }

      final rawCamp = (originalMed['campId'] ?? originalMed['dispensaryId'] ?? CampSessionService.getActiveCamp()).toString().toLowerCase().trim();
      final activeCamp = rawCamp.contains('kapay') ? 'saddar' : (rawCamp.isNotEmpty ? rawCamp : 'saddar');
      final campLabel = CampSessionService.getCampLabel(activeCamp);

      final requestId = 'req_edit_${userInfo['uid'] ?? 'dispenser'}_${DateTime.now().millisecondsSinceEpoch}';
      final reqMap = <String, dynamic>{
        'id': requestId,
        'requestId': requestId,
        'requestType': 'edit_medicine',
        'requestedBy': userInfo['uid'],
        'requestedByName': userInfo['username'],
        'requesterName': userInfo['username'],
        'requestedAt': DateTime.now().toIso8601String(),
        'status': 'pending',
        'reason': updatedFields['reason'] ?? '',
        'campId': activeCamp,
        'dispensaryId': activeCamp,
        'campName': campLabel,
        'campLabel': campLabel,
        'branchId': widget.branchId,
        'docId': originalMed['_docId'] ?? originalMed['id'],
        'originalData': {
          'name': originalMed['name'],
          'type': originalMed['type'],
          'dose': originalMed['dose'],
          'price': originalMed['price'],
          'expiryDate': originalMed['expiryDate'],
          'quantity': originalMed['quantity'],
          'campId': activeCamp,
          'dispensaryId': activeCamp,
          'campName': campLabel,
        },
        'draftItems': [{
          ...updatedFields,
          'oldId': originalMed['_docId'] ?? originalMed['id'],
          'campId': activeCamp,
          'dispensaryId': activeCamp,
          'campName': campLabel,
        }],
        'items': [{
          ...updatedFields,
          'oldId': originalMed['_docId'] ?? originalMed['id'],
          'campId': activeCamp,
          'dispensaryId': activeCamp,
          'campName': campLabel,
        }],
      };

      await LocalStorageService.saveLocalEditRequest(reqMap);
      unawaited(StockLog.record({
        'action': 'edit_requested',
        'requestId': requestId,
        'medicineName': originalMed['name'],
        'medicineType': originalMed['type'],
        'dose': originalMed['dose'],
        'medicineId': originalMed['_docId'] ?? originalMed['id'],
        'pool': originalMed['pool'],
        'expiryDate': originalMed['expiryDate'],
        'quantityBefore': originalMed['quantity'],
        'reason': updatedFields['reason'] ?? '',
        'performedBy': userInfo['uid'],
        'performedByName': userInfo['username'],
        'branchId': widget.branchId,
        'campId': activeCamp,
      }));
      await LocalStorageService.enqueueSync({
        'type': 'save_inventory_edit_request',
        'branchId': widget.branchId,
        'requestId': requestId,
        'data': reqMap,
      });

      RealtimeManager().sendMessage({
        ...RealtimeEvents.payload(
          type: 'request_created',
          branchId: widget.branchId,
          data: reqMap,
        ),
      });

      // The queue item above is the only cloud write: a direct SDK set() (no merge, status
      // pending) could land after the decision and turn the request back to pending.
      SyncService().triggerUpload();

      try {
        CloudMessagingService().notifySupervisorPendingRequests(
          branchId: widget.branchId,
          campId: activeCamp,
          requestType: 'Inventory Edit',
          details: 'Inventory edit request for ${originalMed['name'] ?? 'medicine'} submitted for approval',
        );
      } catch (e) {
        debugPrint('[InventoryUpdate] Supervisor notification error: $e');
      }

      _snack('Edit request submitted for supervisor approval');
    } catch (e) {
      _snack('Error submitting request: $e', err: true);
    }
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    if (widget.isEmbedded) {
      return Container(
        color: c.background,
        child: widget.showMode == 1
            ? _addStockTab()
            : (_canRegisterMedicine ? _registerTab() : _addStockTab()),
      );
    }
    return Scaffold(
      backgroundColor: c.background,
      appBar: _buildAppBar(),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: _canRegisterMedicine
            ? TabBarView(
                controller: _tabCtrl,
                children: [_addStockTab(), _registerTab()],
              )
            : _addStockTab(),
      ),
    );
  }

  static const List<String> _primaryTypeFilters = [
    'All',
    'Tablet',
    'Capsule',
    'Syrup',
    'Injection',
    'Infusion',
    'Dressing Item',
    'Nebulization',
    'Syringe',
    'Consumables',
    'Others',
  ];

  IconData _typeIcon(String t) => switch (t.trim()) {
        'All' => Icons.grid_view_rounded,
        'Tablet' => Icons.medication_rounded,
        'Capsule' => Icons.local_pharmacy_rounded,
        'Syrup' => Icons.medication_liquid_rounded,
        'Injection' => Icons.vaccines_rounded,
        'Infusion' => Icons.water_drop_rounded,
        'Drip' => Icons.water_drop_rounded,
        'Drip Set' => Icons.cable_rounded,
        'Syringe' => Icons.colorize_rounded,
        'Cannula' => Icons.medical_information_rounded,
        'Needle' => Icons.colorize_rounded,
        'Nebulization' => Icons.air_rounded,
        'Dressing Item' => Icons.healing_rounded,
        'Consumables' => Icons.health_and_safety_rounded,
        _ => Icons.medical_services_rounded,
      };

  bool _isLowStock(int qty, String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('inj') || t.contains('drip') || t.contains('iv') || t.contains('infusion')) {
      return qty <= 10;
    }
    if (t.contains('syp') || t.contains('syrup') || t.contains('drop') || t.contains('susp') || t.contains('ointment') || t.contains('cream') || t.contains('inhaler') || t.contains('spray')) {
      return qty <= 15;
    }
    return qty <= 30;
  }

  bool _isExpiringSoon(String? exp) {
    if (exp == null || exp.isEmpty) return false;
    try {
      final parts = exp.split('-');
      if (parts.length != 3) return false;
      final day = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final year = int.parse(parts[2]);
      final date = DateTime(year, month, day);
      final diff = date.difference(DateTime.now()).inDays;
      return diff <= 30 && diff >= 0;
    } catch (_) {
      return false;
    }
  }

  Widget _statusLabel({required bool lowStock, required bool expSoon}) {
    String label = '';
    if (lowStock && expSoon) {
      label = 'CRITICAL: LOW STOCK & NEAR EXPIRY';
    } else if (lowStock) {
      label = 'WARNING: LOW STOCK';
    } else if (expSoon) {
      label = 'ALERT: NEAR EXPIRY';
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: _red, // Solid red background
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: _red.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, color: SoftPalette.gray50, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: SoftPalette.gray50, // High contrast white text
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }





  Future<Map<String, String>> _getUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {'uid': '', 'username': 'Unknown'};
    final email = user.email ?? '';
    final cached = LocalStorageService.getLocalUserByEmail(email) ?? LocalStorageService.getLocalUserByUid(user.uid);
    final username = cached?['username']?.toString() ?? cached?['name']?.toString() ?? user.displayName ?? (email.isNotEmpty ? email : 'Unknown');
    return {'uid': user.uid, 'username': username};
  }

  // ── Load all medicines on start (Hive-first for instant offline updates) ───
  Future<void> _loadAllMedicines() async {
    setState(() => _isSearching = true);
    try {
      // Stock book: the ledger batches of the selected pool(s). Each record is one real
      // batch, so no camp guessing or de-duplication is needed.
      final localItems = _ledgerItems();
      final Map<String, Map<String, dynamic>> consolidated = {};

      void processItem(Map<String, dynamic> d) {
        final docId = (d['medicineId'] ?? d['id'])?.toString().trim();
        final itemCamp = (d['pool'] ?? '').toString();

        final expiry = (d['expiryDate'] ?? '').toString().trim();
        String monthYear = '';
        if (expiry.length == 10 && expiry[2] == '-' && expiry[5] == '-') {
          monthYear = expiry.substring(3);
        } else {
          monthYear = expiry;
        }

        final dQty = (d['quantity'] as num?)?.toInt() ?? 0;
        final key = '${d['name']}|${d['type']}|${d['dose']}|$monthYear|$itemCamp';
        if (!consolidated.containsKey(key)) {
          consolidated[key] = {
            ...d,
            'quantity': dQty,
            '_docId': docId,
            '_docIds': docId != null ? <String>[docId] : <String>[],
          };
        } else {
          final existing = consolidated[key]!;
          final existingDocIds = List<String>.from(existing['_docIds'] as List? ?? []);
          existing['_docIds'] = existingDocIds;
          if (docId != null && !existingDocIds.contains(docId)) {
            existingDocIds.add(docId);
            existing['quantity'] = ((existing['quantity'] as num?)?.toInt() ?? 0) + dQty;
          }
        }
      }

      for (final item in localItems) {
        processItem(item);
      }

      final allSorted = consolidated.values.toList()
        ..sort((a, b) => (a['name'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['name'] ?? '').toString().toLowerCase()));

      if (mounted) {
        setState(() {
          _allConsolidatedMeds = allSorted;
          _searchResults = _filterConsolidatedMedicines(allSorted);
          _isSearching = false;
          _hasSearched = true;
        });
      }
    } catch (e) {
      debugPrint('InventoryUpdate: _loadAllMedicines Error: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  bool _matchesTypeCategory(String itemType, String selectedFilter) {
    final filter = selectedFilter.trim().toLowerCase();
    if (filter.isEmpty || filter == 'all') return true;
    final cleanType = itemType.trim().toLowerCase();
    if (filter == 'others') {
      if (cleanType == 'others' || cleanType.isEmpty) return true;
      final explicitTabs = _primaryTypeFilters
          .where((t) => t != 'All' && t != 'Others')
          .map((t) => t.toLowerCase())
          .toSet();
      return !explicitTabs.contains(cleanType);
    }
    if (filter == 'infusion' && (cleanType == 'infusion' || cleanType == 'drip')) {
      return true;
    }
    return cleanType == filter;
  }

  List<Map<String, dynamic>> _filterConsolidatedMedicines(List<Map<String, dynamic>> source) {
    final q = _searchCtrl.text.toLowerCase().trim();
    final qNum = int.tryParse(q);

    return source.where((item) {
      final itemType = (item['type'] ?? 'Tablet').toString();
      if (!_matchesTypeCategory(itemType, _selectedTypeFilter)) {
        return false;
      }

      final qty = _safeInt(item['quantity']);
      final lowStock = _isLowStock(qty, itemType);
      if (_stockStatusFilter == 'low' && !lowStock) return false;
      if (_stockStatusFilter == 'in_stock' && (qty <= 0 || lowStock)) return false;

      if (q.isEmpty) return true;

      final name = (item['name'] ?? '').toString().toLowerCase();
      final formula = (item['formula'] ?? '').toString().toLowerCase();
      final dose = (item['dose'] ?? '').toString().toLowerCase();
      final barcode = (item['barcode'] ?? item['rollNo'] ?? item['code'] ?? '').toString().toLowerCase();
      final packBarcode = (item['packBarcode'] ?? '').toString().toLowerCase();
      final bNum = int.tryParse(barcode);
      final numMatch = qNum != null && bNum != null && qNum == bNum;

      return name.contains(q) ||
          formula.contains(q) ||
          dose.contains(q) ||
          barcode.contains(q) ||
          packBarcode.contains(q) ||
          numMatch;
    }).toList();
  }

  // ── Search (filters the persistent list) ─────────────────────────────────
  void _searchMedicine(String query) {
    setState(() {
      if (_selectedMed != null) {
        _selectedMed = null;
        _selectedDocId = null;
      }
      _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
      _hasSearched = true;
    });
  }

  void _selectMedForStock(Map<String, dynamic> med) {
    setState(() {
      _selectedMed = med;
      _selectedDocId = med['_docId']?.toString();
      _addQtyCtrl.text = '1';
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedMed = null;
      _selectedDocId = null;
      _addQtyCtrl.text = '1';
    });
  }

  // ── Submit: Add Stock ─────────────────────────────────────────────────────
  Future<void> _submitAddStock() async {
    if (_selectedMed == null || _selectedDocId == null) {
      _snack('Select a medicine from the list first', err: true);
      return;
    }

    final targetCamp = _effectiveTargetCamp;
    if (_hasMultiCamps && (targetCamp == 'all' || targetCamp.isEmpty)) {
      _snack('Please select a specific camp above before adding stock.', err: true);
      return;
    }

    final qty = int.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty < 1) {
      _snack('Enter a valid quantity (min 1)', err: true);
      return;
    }

    setState(() => _isSubmittingStock = true);
    try {
      final userInfo = await _getUserInfo();
      final medId = _selectedDocId!;
      final campLabel = CampSessionService.getCampLabel(targetCamp);

      // Stock book: ONE restock movement on the batch's own pool. It is applied here at
      // once and StockActions sends it to the LAN server and the cloud.
      final pool = _poolFor(_selectedMed!, targetCamp);
      if (pool == null) {
        _snack('Please select a specific camp above before adding stock.', err: true);
        return;
      }
      await StockActions.restock(pool, medId, qty.toDouble(), ref: 'add stock');

      final logData = {
        'action': 'add_stock',
        'medicineName': _selectedMed!['name'],
        'medicineId': medId,
        'quantityAdded': qty,
        'branchId': _effectiveBranchId,
        'dispensaryId': targetCamp,
        'campId': targetCamp,
        'campName': campLabel,
        'performedBy': userInfo['uid'],
        'performedByName': userInfo['username'],
        'timestamp': DateTime.now().toIso8601String(),
        'createdAt': DateTime.now().toIso8601String(),
      };
      await LocalStorageService.saveLocalInventoryLog(logData);
      await _uploadInventoryLog(logData);

      _snack('+$qty added to ${_selectedMed!['name']} at $campLabel (${_currentBranchId.toUpperCase()})!');
      _clearSelection();
      _loadAllMedicines();
    } catch (e) {
      _snack('Error: $e', err: true);
    } finally {
      if (mounted) setState(() => _isSubmittingStock = false);
    }
  }



  /// Checks for exact or fuzzy matches in  and stock catalog to avoid duplicate & spelling mistakes
  Future<bool> _verifySpellingAndDuplicates(String name, String type) async {
    // 1. Check exact match in Master Proforma
    final exact = MasterProformaService.findExactMatch(name, type);
    if (exact != null) {
      final String profName = exact['name'] ?? name;
      final String profCode = exact['code'] ?? '';
      final String profFormula = exact['formula'] ?? '';

      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(FontAwesomeIcons.circleExclamation, color: SoftPalette.orange400, size: 26),
              SizedBox(width: 10),
              Text('Medicine Exists in Catalog'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The medicine formula "${profFormula.isNotEmpty ? profFormula : profName}" ($type) is already registered in our Medicine Catalog!',
                style: TextStyle(fontWeight: FontWeight.bold, color: context.adapt(_textDark)),
              ),
              const SizedBox(height: 8),
              if (profCode.isNotEmpty)
                Text('Catalog Code: $profCode', style: TextStyle(fontSize: 13, color: context.adapt(_textMid))),
              const SizedBox(height: 12),
              const Text(
                'Duplicate registration is blocked. Please select this medicine from Add Medicine instead.',
                style: TextStyle(fontSize: 13, color: _red, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: context.adapt(_textMid))),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _teal,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(context).pop(false);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AddMedicinePage(
                      branchId: widget.branchId,
                      isDispenser: widget.isDispenser,
                      isAdmin: widget.isAdmin,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.playlist_add_rounded, size: 16, color: SoftPalette.gray50),
              label: const Text('Open Add Medicine', style: TextStyle(color: SoftPalette.gray50)),
            ),
          ],
        ),
      );
      return false; // Stop custom registration
    }

    // 2. Collect all candidates for fuzzy spelling match
    final List<Map<String, dynamic>> candidates = [];
    final items = MasterProformaService.getAllItems();
    candidates.addAll(items);

    candidates.addAll(StockLedger.items());

    final matches = StringSimilarityHelper.findSimilarMedicines(name, candidates, threshold: 0.65);
    if (matches.isNotEmpty) {
      final bestMatch = matches.first;
      final String bestName = bestMatch['name'] ?? '';
      final double score = (bestMatch['_similarityScore'] as double? ?? 0.0);

      if (bestName.toLowerCase() != name.toLowerCase() && score < 1.0) {
        final choice = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(FontAwesomeIcons.lightbulb, color: SoftPalette.blue500, size: 24),
                SizedBox(width: 10),
                Text('Did You Mean...?'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 14, color: context.adapt(_textDark)),
                    children: [
                      const TextSpan(text: 'You entered '),
                      TextSpan(
                        text: '"$name"',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: _red),
                      ),
                      const TextSpan(text: ', which is very similar to our standard catalog medicine:'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.adapt(SoftPalette.green100m),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.adapt(SoftPalette.green300)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(FontAwesomeIcons.pills, size: 16, color: _green600),
                          const SizedBox(width: 8),
                          Text(
                            bestName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _green600),
                          ),
                        ],
                      ),
                      if (bestMatch['formula'] != null && bestMatch['formula'].toString().isNotEmpty)
                        Text('Formula: ${bestMatch['formula']}', style: TextStyle(fontSize: 12, color: context.adapt(_textMid))),
                      if (bestMatch['type'] != null)
                        Text('Type: ${bestMatch['type']} | Dose: ${bestMatch['dose'] ?? 'Standard'}', style: TextStyle(fontSize: 12, color: context.adapt(_textMid))),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Would you like to use the suggested standard medicine or register your new custom spelling?',
                  style: TextStyle(fontSize: 13, color: context.adapt(_textMid)),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('custom'),
                child: Text('Keep Custom "$name"', style: TextStyle(color: context.adapt(_textMid))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green600,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => Navigator.of(context).pop('suggested'),
                child: Text('Use "$bestName"', style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );

        if (choice == 'suggested') {
          _regNameCtrl.text = bestName;
          if (bestMatch['type'] != null && _allTypes.contains(bestMatch['type'])) {
            setState(() {
              _regType = bestMatch['type'];
            });
          }
          return true;
        } else if (choice == 'custom') {
          return true;
        } else {
          return false;
        }
      }
    }

    return true;
  }

  // ── Submit: Register New Medicine into Master Proforma ─────────────────────
  Future<void> _submitRegister() async {
    if (!_regFormKey.currentState!.validate()) return;

    final name = _regNameCtrl.text.trim();
    final reason = _regReasonCtrl.text.trim();
    if (reason.isEmpty) {
      _snack('A mandatory reason is required to register a medicine into the Medicine Catalog!', err: true);
      return;
    }

    final rawProformaBarcode = _regCodeCtrl.text.trim();
    final proformaBarcode = rawProformaBarcode.isEmpty
        ? MasterProformaService.getNextRollNumber()
        : MasterProformaService.normalizeProformaBarcode(rawProformaBarcode);
    if (proformaBarcode == null) {
      _snack('Barcode must be a 3-digit number from 001 to 999', err: true);
      return;
    }
    if (MasterProformaService.findExactBarcodeMatch(proformaBarcode) != null) {
      _snack('Barcode $proformaBarcode is already assigned to another medicine', err: true);
      return;
    }
    final packBarcode = _regPackBarcodeCtrl.text.trim();

    final dose = _hasDoseDropdown
        ? (_regSelectedDose ?? '')
        : (_usesFreeTextDose ? _regDoseCtrl.text.trim() : '');

    final allowed = await _verifySpellingAndDuplicates(name, _regType);
    if (!allowed) return;

    final finalName = _regNameCtrl.text.trim();
    final cleanFormula = MasterProformaService.cleanBrandToFormula(finalName);

    final initials = cleanFormula.split(RegExp(r'\s+')).take(3).map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join();
    final code = 'MED-$initials-${DateTime.now().millisecondsSinceEpoch % 10000}';

    setState(() => _isSubmittingReg = true);
    try {
      final userInfo = await _getUserInfo();

      final proformaItem = {
        'code': code,
        'itemCode': code,
        'barcode': proformaBarcode,
        'rollNo': proformaBarcode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
        'name': cleanFormula,
        'formula': cleanFormula,
        'type': _regType,
        'dose': dose,
        'defaultPrice': 0.0,
        'expiryDate': '2099-12-31',
        // Legacy 'proforma' field name kept for Hive/Firestore catalog compatibility.
        'isProformaMaster': true,
        'createdAt': DateTime.now().toIso8601String(),
        'createdBy': userInfo['uid'] ?? '',
        'createdByName': userInfo['username'] ?? '',
      };

      final auditLog = {
        'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
        // Legacy 'proforma' audit action name kept for audit log compatibility.
        'action': 'register_proforma_medicine',
        'medicineCode': code,
        'barcode': proformaBarcode,
        'rollNo': proformaBarcode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
        'medicineName': cleanFormula,
        'medicineType': _regType,
        'medicineDose': dose,
        'reason': reason,
        'performedBy': userInfo['uid'],
        'performedByName': userInfo['username'],
        'performedByRole': userInfo['role'] ?? 'HQ Manager / Chairman',
        'timestamp': DateTime.now().toIso8601String(),
        'branchId': widget.branchId,
      };

      await MasterProformaService.saveProformaItem(proformaItem, auditLog: auditLog);

            RealtimeManager().sendMessage({
        'event_type': RealtimeEvents.saveProformaItem,
        'branchId': widget.branchId,
        'data': proformaItem,
        'logData': auditLog,
      });

      _snack('"$cleanFormula" registered permanently into Medicine Catalog with Audit Trail!');
      _resetRegForm();
      _loadAllMedicines();
    } catch (e) {
      _snack('Error: $e', err: true);
    } finally {
      if (mounted) setState(() => _isSubmittingReg = false);
    }
  }

  void _resetRegForm() {
    _regNameCtrl.clear();
    _regQtyCtrl.text = '1';
    _regExpCtrl.clear();
    _regPriceCtrl.clear();
    _regDoseCtrl.clear();
    _regCodeCtrl.clear();
    _regPackBarcodeCtrl.clear();
    _regReasonCtrl.clear();
    setState(() {
      _regType = 'Tablet';
      _regSelectedDose = null;
      _liveSpellingSuggestion = null;
    });
  }



  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final val = Hive.box('app_settings').get('is_dark_mode');
        if (val != null) return val == true;
      }
    } catch (_) {}
    if (!mounted) return false;
    return Theme.of(context).brightness == Brightness.dark;
  }

  static Color _typeColor(String t) => switch (t.trim()) {
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
        'Dressing Item' => SoftPalette.teal550,
        'Consumables' => SoftPalette.green550,
        _ => SoftPalette.slate700,
      };

  InputDecoration _inputDec(String label, {IconData? icon, String? hint}) {
    final c = context.comfort;
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: c.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      hintText: hint,
      hintStyle: TextStyle(
        color: c.textMuted,
        fontSize: 12.5,
      ),
      prefixIcon: icon != null ? Icon(icon, color: c.brand, size: 18) : null,
      filled: true,
      fillColor: c.surfaceSunken,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c.brand, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  PreferredSizeWidget _buildAppBar() => AppBar(
        backgroundColor: _isDark ? SoftPalette.slate900 : _teal,
        elevation: 4,
        shadowColor: _shadow,
        automaticallyImplyLeading: false,
        leading: (!widget.isEmbedded && Navigator.canPop(context))
            ? AppBackButton(color: SoftPalette.gray50)
            : null,
        iconTheme: const IconThemeData(color: SoftPalette.gray50),
        title: const Text('Inventory Update',
            style: TextStyle(
                color: SoftPalette.gray50,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        actions: [
          CampSelectorChip(
            branchId: _effectiveBranchId,
            onCampChanged: (newCamp) {
              setState(() {
                _selectedCampFilter = newCamp;
                _selectedMed = null;
                _selectedDocId = null;
              });
              _loadAllMedicines();
            },
          ),
          const SizedBox(width: 8),
        ],
        bottom: _canRegisterMedicine
            ? TabBar(
                controller: _tabCtrl,
                indicatorColor: SoftPalette.gray50,
                indicatorWeight: 3,
                labelColor: SoftPalette.gray50,
                unselectedLabelColor: SoftPalette.gray50A60,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13),
                tabs: const [
                  Tab(
                      icon: Icon(Icons.add_box_rounded, size: 18),
                      text: 'Add Stock'),
                  Tab(
                      icon: Icon(Icons.medication_liquid_rounded, size: 18),
                      text: 'Register New'),
                ],
              )
            : null,
      );

  // ══════════════════════════════════════════════════════════════════════════
  // TAB 1 — Add Stock & Inventory Manager Redesign
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildKpiMetricCard({
    required IconData icon,
    required Color accentColor,
    required Color bgTint,
    String? value,
    Widget? valueWidget,
    required String label,
    String? badgeText,
    bool isActive = false,
    VoidCallback? onTap,
  }) {
    final c = context.comfort;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isActive ? bgTint : c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? accentColor : c.border,
              width: isActive ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isActive
                      ? accentColor.withValues(alpha: _isDark ? 0.28 : 0.18)
                      : bgTint,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.24),
                  ),
                ),
                child: Icon(icon, color: accentColor, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (valueWidget != null)
                          Expanded(child: valueWidget)
                        else
                          Flexible(
                            child: Text(
                              value ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 17.5,
                                fontWeight: FontWeight.w800,
                                height: 1.1,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        if (badgeText != null && badgeText.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badgeText,
                              style: TextStyle(
                                color: accentColor,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive ? accentColor : c.textSecondary,
                        fontSize: 11.5,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
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

  Widget _buildContextBanner() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final baseList = _allConsolidatedMeds.isNotEmpty ? _allConsolidatedMeds : _searchResults;
    final totalCount = baseList.length;
    final totalUnits = baseList.fold<int>(0, (s, m) => s + _safeInt(m['quantity']));
    final lowStockCount = baseList
        .where((m) => _isLowStock(_safeInt(m['quantity']), m['type']?.toString() ?? ''))
        .length;
    final outOfStockCount = baseList.where((m) => _safeInt(m['quantity']) <= 0).length;
    final numberFormat = NumberFormat('#,###');

    final card1 = _buildKpiMetricCard(
      icon: GIcons.medicine,
      accentColor: c.brand,
      bgTint: c.brandSoft,
      value: '$totalCount',
      label: 'Total Medicines',
      isActive: _stockStatusFilter == 'all' && _selectedTypeFilter == 'All',
      onTap: () {
        setState(() {
          _stockStatusFilter = 'all';
          _selectedTypeFilter = 'All';
          _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
        });
      },
    );
    final card2 = _buildKpiMetricCard(
      icon: GIcons.inventory,
      accentColor: c.info,
      bgTint: c.infoBg,
      value: numberFormat.format(totalUnits),
      label: 'Total Units in Stock',
      isActive: _stockStatusFilter == 'in_stock',
      onTap: () {
        setState(() {
          _stockStatusFilter = _stockStatusFilter == 'in_stock' ? 'all' : 'in_stock';
          _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
        });
      },
    );
    final card3 = _buildKpiMetricCard(
      icon: GIcons.lowStock,
      accentColor: c.danger,
      bgTint: c.dangerBg,
      value: '$lowStockCount',
      badgeText: outOfStockCount > 0 ? '$outOfStockCount OUT' : null,
      label: 'Low / Out of Stock',
      isActive: _stockStatusFilter == 'low',
      onTap: () {
        setState(() {
          _stockStatusFilter = _stockStatusFilter == 'low' ? 'all' : 'low';
          _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
        });
      },
    );

    final activeBranchValue = _availableBranches.contains(_currentBranchId.toLowerCase().trim())
        ? _currentBranchId.toLowerCase().trim()
        : _availableBranches.first;
    final branchSubLabel = _hasMultiCamps && _selectedCampFilter != 'all'
        ? CampSessionService.getCampLabel(_selectedCampFilter, _effectiveBranchId)
        : 'Active Facility';

    final card4 = _buildKpiMetricCard(
      icon: GIcons.branch,
      accentColor: c.success,
      bgTint: c.successBg,
      value: (_isMultiBranchUser && _availableBranches.length > 1)
          ? null
          : _currentBranchId.toUpperCase(),
      valueWidget: (_isMultiBranchUser && _availableBranches.length > 1)
          ? DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: activeBranchValue,
                isDense: true,
                dropdownColor: c.surface,
                icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.success),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
                items: _availableBranches
                    .map((b) => DropdownMenuItem<String>(
                          value: b,
                          child: Text(
                            b.toUpperCase(),
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ))
                    .toList(),
                onChanged: (newBranch) {
                  if (newBranch != null) _onBranchChanged(newBranch);
                },
              ),
            )
          : null,
      label: branchSubLabel,
    );

    if (isCompact) {
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

  Widget _campPillButton({
    required String label,
    required String campId,
    required IconData icon,
  }) {
    final c = context.comfort;
    final isSelected = (_selectedCampFilter == campId) ||
        (campId == 'haji_camp' && _selectedCampFilter == 'haji');

    return InkWell(
      onTap: () {
        setState(() {
          _selectedCampFilter = campId;
          _selectedMed = null;
          _selectedDocId = null;
        });
        if (campId != 'all') {
          CampSessionService.setActiveCamp(campId);
        }
        _loadAllMedicines();
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? c.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isSelected ? c.onBrand : c.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? c.onBrand : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stockStatusSegmentChip({
    required String keyId,
    required String label,
    required IconData icon,
    required Color activeColor,
  }) {
    final c = context.comfort;
    final isSel = _stockStatusFilter == keyId;
    return InkWell(
      onTap: () {
        setState(() {
          _stockStatusFilter = keyId;
          _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSel ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13.5,
              color: isSel ? c.onBrand : c.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSel ? FontWeight.w700 : FontWeight.w600,
                color: isSel ? c.onBrand : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TAB 1 — Add Stock & Inventory Manager Redesign
  // ══════════════════════════════════════════════════════════════════════════
  Widget _addStockTab() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final types = _primaryTypeFilters;

    final searchField = Container(
      height: 38,
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.borderStrong),
      ),
      child: TextField(
        controller: _searchCtrl,
        cursorColor: c.brand,
        style: TextStyle(color: c.textPrimary, fontSize: 13),
        onChanged: _searchMedicine,
        decoration: InputDecoration(
          prefixIcon: _isSearching
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: c.brand),
                  ),
                )
              : Icon(GIcons.search, color: c.brand, size: 17),
          hintText: 'Search by formula, medicine name, dose, or #barcode...',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: Icon(GIcons.close, color: c.textSecondary, size: 15),
                  padding: EdgeInsets.zero,
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchCtrl.clear();
                    _searchMedicine('');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );

    final statusFilterBar = Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stockStatusSegmentChip(
            keyId: 'all',
            label: 'All Stock',
            icon: Icons.layers_rounded,
            activeColor: c.brand,
          ),
          const SizedBox(width: 2),
          _stockStatusSegmentChip(
            keyId: 'low',
            label: 'Low / Out',
            icon: GIcons.lowStock,
            activeColor: c.danger,
          ),
          const SizedBox(width: 2),
          _stockStatusSegmentChip(
            keyId: 'in_stock',
            label: 'Healthy',
            icon: GIcons.checkCircle,
            activeColor: c.success,
          ),
        ],
      ),
    );

    final refreshBtn = Tooltip(
      message: 'Reload stock list',
      child: InkWell(
        onTap: _loadAllMedicines,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Icon(GIcons.refresh, size: 17, color: c.brand),
        ),
      ),
    );

    final typePillsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < types.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Builder(builder: (_) {
            final t = types[i];
            final isSel = _selectedTypeFilter == t;
            final rawCol = t == 'All' ? c.brand : _typeColor(t);
            final iconCol = isSel
                ? c.onBrand
                : (_isDark ? Color.lerp(rawCol, SoftPalette.gray50, 0.35)! : rawCol);
            return InkWell(
              onTap: () {
                setState(() {
                  _selectedTypeFilter = t;
                  _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
                });
              },
              borderRadius: BorderRadius.circular(9),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: isSel ? c.brand : c.surfaceSunken,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: isSel ? c.brand : c.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MedicineTypeIcon(type: t, size: 15, color: iconCol),
                    const SizedBox(width: 6),
                    Text(
                      t,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: isSel ? FontWeight.w700 : FontWeight.w600,
                        color: isSel ? c.onBrand : c.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );

    final hasActiveFilters = _searchCtrl.text.trim().isNotEmpty ||
        _selectedTypeFilter != 'All' ||
        _stockStatusFilter != 'all';

    return Column(
      children: [
        // ── KPI Cards Row ─────────────────────────────────────────────────
        _buildContextBanner(),

        // ── Unified Search & Filter Card ──────────────────────────────────
        Container(
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCompact) ...[
                Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 8),
                    refreshBtn,
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: statusFilterBar,
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: typePillsRow,
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 10),
                    statusFilterBar,
                    const SizedBox(width: 8),
                    refreshBtn,
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: typePillsRow,
                ),
              ],

              if (_hasMultiCamps) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(GIcons.location, size: 14, color: c.brand),
                    const SizedBox(width: 5),
                    Text(
                      'Target Camp:',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: c.surfaceSunken,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _campPillButton(
                                label: 'All Camps',
                                campId: 'all',
                                icon: Icons.domain_rounded,
                              ),
                              for (final camp in CampSessionService.getCampsForBranch(_effectiveBranchId)) ...[
                                const SizedBox(width: 2),
                                _campPillButton(
                                  label: (camp['name'] ??
                                          CampSessionService.getCampLabel(
                                            (camp['id'] ?? '').toString(),
                                            _effectiveBranchId,
                                          ))
                                      .toString(),
                                  campId: (camp['id'] ?? '').toString(),
                                  icon: GIcons.location,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              if (_selectedCampFilter == 'all' && _hasMultiCamps) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.warningBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.warning.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(GIcons.info, size: 15, color: c.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Viewing consolidated stock from all camps. Choose a destination camp when adding stock.',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: c.warning,
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

        // ── Section header ─────────────────────────────────────────────────
        if (_hasSearched && _searchResults.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Row(
              children: [
                Icon(Icons.playlist_add_check_circle_rounded, size: 15, color: c.brand),
                const SizedBox(width: 6),
                Text(
                  !hasActiveFilters
                      ? 'Available Medicines (${_searchResults.length})'
                      : 'Filtered Medicines (${_searchResults.length} of ${_allConsolidatedMeds.length})',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
                if (hasActiveFilters) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _searchCtrl.clear();
                        _selectedTypeFilter = 'All';
                        _stockStatusFilter = 'all';
                        _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
                      });
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.brandSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(GIcons.close, size: 11, color: c.brandStrong),
                          const SizedBox(width: 3),
                          Text(
                            'Reset filters',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: c.brandStrong,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Icon(GIcons.dispensary, size: 13, color: c.textMuted),
                const SizedBox(width: 5),
                Text(
                  _hasMultiCamps
                      ? (_selectedCampFilter == 'all'
                          ? 'Camp: All Camps (Combined)'
                          : 'Camp: ${CampSessionService.getCampLabel(_effectiveTargetCamp, _effectiveBranchId)}')
                      : 'Main Facility • Tap any row to add stock',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),

        // ── Persistent medicine list ───────────────────────────────────────
        Expanded(
          child: _isSearching && !_hasSearched
              ? Center(child: CircularProgressIndicator(color: c.brand))
              : _searchResults.isEmpty && _hasSearched
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const GEmptyIllustration(
                            GEmptyIllustrationKind.search,
                            size: 144,
                            fallbackIcon: Icons.search_off_rounded,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No medicines found in this camp/filter',
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (hasActiveFilters) ...[
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _searchCtrl.clear();
                                  _selectedTypeFilter = 'All';
                                  _stockStatusFilter = 'all';
                                  _searchResults = _filterConsolidatedMedicines(_allConsolidatedMeds);
                                });
                              },
                              icon: const Icon(GIcons.close, size: 15),
                              label: const Text('Clear Filters'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (ctx, constraints) {
                        final isWideTable = constraints.maxWidth >= 880;
                        return Column(
                          children: [
                            if (isWideTable) _buildStructuredTableHeader(),
                            Expanded(
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(12, 2, 12, 20),
                                itemCount: _searchResults.length,
                                itemBuilder: (ctx, i) => _searchResultRow(
                                  _searchResults[i],
                                  index: i,
                                  isWideTable: isWideTable,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
        ),
      ],
    );
  }

  // ── Column widths for wide structured layout ──────────────────────────────
  static const double _colTypeWidth = 136;
  static const double _colDoseWidth = 112;
  static const double _colExpiryWidth = 142;
  static const double _colStockWidth = 166;
  static const double _colActionsWidth = 154;

  Widget _buildStructuredTableHeader() {
    final c = context.comfort;
    TextStyle colHeaderStyle() => TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: c.textMuted,
        );

    return Container(
      height: 34,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                const SizedBox(width: 52), // Aligns past the 40px icon avatar + 12px gap
                Text('MEDICINE & CATALOG CODE', style: colHeaderStyle()),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _colTypeWidth,
            child: Text('CATEGORY', style: colHeaderStyle()),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _colDoseWidth,
            child: Text('STRENGTH / DOSE', style: colHeaderStyle()),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _colExpiryWidth,
            child: Text('EXPIRY (BATCH)', style: colHeaderStyle()),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _colStockWidth,
            child: Text('STOCK STATUS', style: colHeaderStyle()),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _colActionsWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('ACTIONS', style: colHeaderStyle()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeadingTypeAvatar(String type, Color typeColor, bool isDark) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: typeColor.withValues(alpha: isDark ? 0.20 : 0.11),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: typeColor.withValues(alpha: isDark ? 0.38 : 0.25)),
      ),
      alignment: Alignment.center,
      child: MedicineTypeIcon(type: type, size: 21, color: typeColor),
    );
  }

  Widget _buildUniformBarcodeBadge(String barcode, GComfortColors c) {
    final hasCode = barcode.isNotEmpty;
    return Container(
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: hasCode ? c.brandSoft : c.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: hasCode ? c.brand.withValues(alpha: 0.28) : c.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            GIcons.qr,
            size: 11,
            color: hasCode ? c.brandStrong : c.textMuted,
          ),
          const SizedBox(width: 4),
          Text(
            hasCode ? '#$barcode' : 'No Code',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: hasCode ? c.brandStrong : c.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUniformCategoryBadge(String type, Color typeColor, bool isDark, {double? width}) {
    return Container(
      width: width,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: typeColor.withValues(alpha: isDark ? 0.18 : 0.09),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: typeColor.withValues(alpha: isDark ? 0.34 : 0.24)),
      ),
      child: Row(
        mainAxisSize: width != null ? MainAxisSize.max : MainAxisSize.min,
        children: [
          MedicineTypeIcon(type: type, size: 15, color: typeColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              type,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: typeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUniformDoseBadge(String dose, GComfortColors c, {double? width}) {
    final cleanDose = dose.trim().isNotEmpty ? dose.trim() : 'Standard';
    final isStandard = dose.trim().isEmpty || cleanDose.toLowerCase() == 'standard';
    return Container(
      width: width,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: width != null ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(
            Icons.science_rounded,
            size: 13,
            color: isStandard ? c.textMuted : c.brand,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              cleanDose,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isStandard ? FontWeight.w600 : FontWeight.w700,
                color: isStandard ? c.textSecondary : c.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUniformExpiryBadge(String expiry, bool expSoon, GComfortColors c, {double? width}) {
    final hasExpiry = expiry.isNotEmpty;
    final fg = !hasExpiry ? c.textMuted : (expSoon ? c.danger : c.textSecondary);
    final bg = !hasExpiry ? c.surfaceSunken : (expSoon ? c.dangerBg : c.surfaceSunken);
    final borderCol = !hasExpiry
        ? c.border
        : (expSoon ? c.danger.withValues(alpha: 0.4) : c.border);
    final icon = !hasExpiry
        ? Icons.event_note_rounded
        : (expSoon ? GIcons.overdue : Icons.event_available_rounded);

    return Container(
      width: width,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: borderCol),
      ),
      child: Row(
        mainAxisSize: width != null ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              hasExpiry ? _formatExpiryDisplay(expiry) : 'No Expiry',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: expSoon ? FontWeight.w700 : FontWeight.w600,
                color: hasExpiry ? (expSoon ? c.danger : c.textPrimary) : c.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUniformStockStatusPill(int qty, bool lowStock, GComfortColors c, {double? width}) {
    final isOut = qty <= 0;
    final Color bg = isOut ? c.dangerBg : (lowStock ? c.warningBg : c.successBg);
    final Color fg = isOut ? c.danger : (lowStock ? c.warning : c.success);
    final IconData statusIcon = isOut
        ? GIcons.error
        : (lowStock ? GIcons.warning : GIcons.checkCircle);
    final String statusTag = isOut ? 'OUT' : (lowStock ? 'LOW' : 'OK');

    return Container(
      width: width,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: width != null ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, size: 13.5, color: fg),
              const SizedBox(width: 6),
              Text(
                '$qty in stock',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              statusTag,
              style: TextStyle(
                color: fg,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowActionButtons(Map<String, dynamic> med, GComfortColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          width: 112,
          height: 34,
          child: ElevatedButton.icon(
            onPressed: () => _showAddStockDialog(med),
            icon: const Icon(Icons.add_box_rounded, size: 15),
            label: const Text(
              'Add Stock',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.brand,
              foregroundColor: c.onBrand,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Edit Batch / Request Changes',
          child: InkWell(
            onTap: () => _showEditRequestSheet(med),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Icon(GIcons.edit, size: 15.5, color: c.textSecondary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchResultRow(
    Map<String, dynamic> med, {
    int index = 0,
    bool isWideTable = true,
  }) {
    final c = context.comfort;
    final isDark = _isDark;
    final qty = _safeInt(med['quantity']);
    final type = med['type']?.toString() ?? 'Tablet';
    final name = (med['name'] ?? med['formula'] ?? '').toString();
    final formula = (med['formula'] ?? '').toString().trim();
    final showFormulaSub = formula.isNotEmpty && formula.toLowerCase() != name.toLowerCase();
    final dose = (med['dose'] ?? '').toString();
    final barcode = (med['barcode'] ?? med['rollNo'] ?? '').toString().trim();
    final lowStock = _isLowStock(qty, type);
    final expSoon = _isExpiringSoon(med['expiryDate']?.toString());
    final expiry = (med['expiryDate'] ?? '').toString().trim();

    final rawCamp = (med['campId'] ?? med['dispensaryId'] ?? '').toString().toLowerCase();
    String campTag = '';
    final isKarachi = CampSessionService.isKarachiFamily(_effectiveBranchId);
    if (isKarachi) {
      if (rawCamp.contains('haji')) {
        campTag = 'Haji Camp';
      } else if (rawCamp.contains('sadd') || rawCamp.contains('kap')) {
        campTag = 'Saddar Camp';
      }
    } else if (rawCamp.isNotEmpty && rawCamp != 'all') {
      campTag = CampSessionService.getCampLabel(rawCamp, _effectiveBranchId);
    } else if (_selectedCampFilter != 'all' && _selectedCampFilter.isNotEmpty) {
      campTag = CampSessionService.getCampLabel(_selectedCampFilter, _effectiveBranchId);
    } else if (_hasMultiCamps) {
      campTag = 'General Stock';
    }

    final rawTypeColor = _typeColor(type);
    final typeColor = isDark ? Color.lerp(rawTypeColor, SoftPalette.gray50, 0.35)! : rawTypeColor;

    return _StructuredMedicineRowCard(
      onTap: () => _showAddStockDialog(med),
      accentColor: qty <= 0 ? c.danger : (lowStock ? c.warning : typeColor),
      child: isWideTable
          ? Row(
              children: [
                // 1. Medicine & Catalog Code (Uniform 40x40 Icon Avatar + Name + Code)
                Expanded(
                  child: Row(
                    children: [
                      _buildLeadingTypeAvatar(type, typeColor, isDark),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                _buildUniformBarcodeBadge(barcode, c),
                                if (_hasMultiCamps && campTag.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    height: 21,
                                    padding: const EdgeInsets.symmetric(horizontal: 7),
                                    decoration: BoxDecoration(
                                      color: c.infoBg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: c.info.withValues(alpha: 0.25)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(GIcons.location, size: 10.5, color: c.info),
                                        const SizedBox(width: 3),
                                        Text(
                                          campTag,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            color: c.info,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (showFormulaSub) ...[
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      formula,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: c.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // 2. Uniform Category Column
                SizedBox(
                  width: _colTypeWidth,
                  child: _buildUniformCategoryBadge(type, typeColor, isDark, width: _colTypeWidth),
                ),
                const SizedBox(width: 10),

                // 3. Uniform Strength / Dose Column
                SizedBox(
                  width: _colDoseWidth,
                  child: _buildUniformDoseBadge(dose, c, width: _colDoseWidth),
                ),
                const SizedBox(width: 10),

                // 4. Uniform Expiry (Batch) Column
                SizedBox(
                  width: _colExpiryWidth,
                  child: _buildUniformExpiryBadge(expiry, expSoon, c, width: _colExpiryWidth),
                ),
                const SizedBox(width: 10),

                // 5. Uniform Stock Status Column
                SizedBox(
                  width: _colStockWidth,
                  child: _buildUniformStockStatusPill(qty, lowStock, c, width: _colStockWidth),
                ),
                const SizedBox(width: 10),

                // 6. Uniform Actions Column
                SizedBox(
                  width: _colActionsWidth,
                  child: _buildRowActionButtons(med, c),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildLeadingTypeAvatar(type, typeColor, isDark),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _buildUniformBarcodeBadge(barcode, c),
                              if (_hasMultiCamps && campTag.isNotEmpty)
                                Container(
                                  height: 21,
                                  padding: const EdgeInsets.symmetric(horizontal: 7),
                                  decoration: BoxDecoration(
                                    color: c.infoBg,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: c.info.withValues(alpha: 0.25)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(GIcons.location, size: 10.5, color: c.info),
                                      const SizedBox(width: 3),
                                      Text(
                                        campTag,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: c.info,
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
                    const SizedBox(width: 8),
                    _buildUniformStockStatusPill(qty, lowStock, c),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _buildUniformCategoryBadge(type, typeColor, isDark),
                          _buildUniformDoseBadge(dose, c),
                          _buildUniformExpiryBadge(expiry, expSoon, c),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildRowActionButtons(med, c),
                  ],
                ),
              ],
            ),
    );
  }

  // ── Expiry Date Helpers ───────────────────────────────────────────────────
  String _formatExpiryDisplay(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '—';
    final str = raw.trim();
    final dt = MasterProformaService.parseExpiryDate(str);
    if (dt.year >= 3000) return str;
    final clean = str.replaceAll('/', '-');
    final parts = clean.split('-');
    if (parts.length == 3) {
      return DateFormat('dd-MM-yyyy').format(dt);
    }
    return DateFormat('MM-yyyy').format(dt);
  }

  int _expiryDaysRemaining(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 99999;
    final dt = MasterProformaService.parseExpiryDate(raw);
    if (dt.year >= 3000) return 99999;
    final today = DateTime.now();
    return dt.difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  Widget _badgeChip(String label, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }

  Widget _quickDateChip(String label, VoidCallback onTap, GComfortColors c) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: c.brandStrong,
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _getExistingBatchesForMed(Map<String, dynamic> med, String targetCamp) {
    final pool = _poolFor(med, targetCamp);
    if (pool == null) return const [];

    final medName = (med['name'] ?? med['formula'] ?? '').toString().trim();
    final medFormula = (med['formula'] ?? med['name'] ?? '').toString().trim();
    final medType = (med['type'] ?? '').toString().trim().toLowerCase();
    final medDose = (med['dose'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final medCode = (med['code'] ?? med['itemCode'] ?? '').toString().trim().toLowerCase();
    final medGroupKey = StockReader.groupKey(med);

    final rawBatches = StockReader.batches(pool);
    final matching = <Map<String, dynamic>>[];

    for (final b in rawBatches) {
      if (b['deleted'] == true) continue;

      // GroupKey match
      if (StockReader.groupKey(b) == medGroupKey) {
        matching.add(b);
        continue;
      }

      // Exact code match
      final bCode = (b['code'] ?? b['itemCode'] ?? '').toString().trim().toLowerCase();
      if (medCode.isNotEmpty && bCode.isNotEmpty && bCode == medCode) {
        matching.add(b);
        continue;
      }

      // Name/formula + type + dose match
      final bName = (b['name'] ?? b['formula'] ?? '').toString().trim().toLowerCase();
      final bFormula = (b['formula'] ?? b['name'] ?? '').toString().trim().toLowerCase();
      final bType = (b['type'] ?? '').toString().trim().toLowerCase();
      final bDose = (b['dose'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

      final nameMatches = bName == medName.toLowerCase() ||
          bName == medFormula.toLowerCase() ||
          bFormula == medName.toLowerCase() ||
          bFormula == medFormula.toLowerCase();

      final typeMatches = medType.isEmpty || bType == medType;
      final doseMatches = medDose.isEmpty || bDose == medDose;

      if (nameMatches && typeMatches && doseMatches) {
        matching.add(b);
      }
    }

    if (matching.isEmpty && (med['_docId'] != null || med['id'] != null)) {
      matching.add(med);
    }

    // Consolidate any records sharing the same normalized expiry
    final Map<String, Map<String, dynamic>> consolidated = {};
    for (final b in matching) {
      final exp = (b['expiryDate'] ?? b['expiry'] ?? '').toString().trim();
      final normKey = exp.isEmpty ? 'no_exp' : exp.toLowerCase();
      if (!consolidated.containsKey(normKey)) {
        consolidated[normKey] = Map<String, dynamic>.from(b);
      } else {
        final existing = consolidated[normKey]!;
        final q1 = StockReader.qty(existing);
        final q2 = StockReader.qty(b);
        existing['quantity'] = q1 + q2;
      }
    }

    final result = consolidated.values.toList();
    StockReader.sortFefo(result);
    return result;
  }

  // ── Add Stock Pop-up Dialog ────────────────────────────────────────────────
  void _showAddStockDialog(Map<String, dynamic> med) {
    final medName = (med['name'] ?? med['formula'] ?? 'Medicine').toString();
    final medType = med['type']?.toString() ?? 'Tablet';
    final medDose = med['dose']?.toString() ?? '';
    final curQty = _safeInt(med['quantity']);

    final isKarachi = CampSessionService.isKarachiFamily(_effectiveBranchId);
    String targetCamp = (med['campId'] ?? med['dispensaryId'] ?? '').toString().toLowerCase().trim();
    if (isKarachi) {
      if (targetCamp.contains('haji')) {
        targetCamp = 'haji_camp';
      } else if (targetCamp.contains('sadd') || targetCamp.contains('kap')) {
        targetCamp = 'saddar';
      } else {
        targetCamp = _effectiveTargetCamp;
        if (targetCamp == 'all' || targetCamp.isEmpty) {
          targetCamp = 'saddar';
        }
      }
    } else {
      if (_hasMultiCamps) {
        if (targetCamp.isEmpty || targetCamp == 'all') {
          targetCamp = _effectiveTargetCamp.isNotEmpty && _effectiveTargetCamp != 'all'
              ? _effectiveTargetCamp
              : (CampSessionService.getCampsForBranch(_effectiveBranchId).isNotEmpty
                  ? CampSessionService.getCampsForBranch(_effectiveBranchId).first['id']?.toString() ?? ''
                  : '');
        }
      } else {
        targetCamp = '';
      }
    }

    final qtyCtrl = TextEditingController(text: '10');
    bool isSubmitting = false;

    // Load initial batches for targetCamp
    List<Map<String, dynamic>> existingBatches = _getExistingBatchesForMed(med, targetCamp);
    bool isNewBatchMode = existingBatches.isEmpty;

    // Pre-select matching batch if possible
    final clickedDocId = (med['_docId'] ?? med['id'] ?? med['medicineId'])?.toString();
    final clickedExpiry = (med['expiryDate'] ?? '').toString().trim();
    Map<String, dynamic>? selectedExistingBatch;
    if (existingBatches.isNotEmpty) {
      selectedExistingBatch = existingBatches.firstWhere(
        (b) {
          final bId = (b['medicineId'] ?? b['id'] ?? b['_docId'])?.toString();
          if (clickedDocId != null && clickedDocId.isNotEmpty && bId == clickedDocId) return true;
          final bExp = (b['expiryDate'] ?? '').toString().trim();
          if (clickedExpiry.isNotEmpty && bExp == clickedExpiry) return true;
          return false;
        },
        orElse: () => existingBatches.first,
      );
    }

    // Default new expiry date: 1 year from now
    DateTime newExpiryDate = DateTime(DateTime.now().year + 1, DateTime.now().month, 1); // expiry day is always 01
    final newExpiryCtrl = TextEditingController(text: DateFormat('dd-MM-yyyy').format(newExpiryDate));

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final c = ctx.comfort;
          final campLabel = targetCamp.isNotEmpty && targetCamp != 'all' && targetCamp != 'main'
              ? CampSessionService.getCampLabel(targetCamp, _effectiveBranchId)
              : (isKarachi ? 'Saddar Dispensary' : 'Inventory');

          final int batchStock = selectedExistingBatch != null
              ? _safeInt(selectedExistingBatch!['quantity'])
              : (isNewBatchMode ? 0 : curQty);

          return Dialog(
            backgroundColor: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: c.border),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 520,
                maxHeight: MediaQuery.of(ctx).size.height * 0.92,
              ),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.brandSoft,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.add_box_rounded, color: c.brand, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Add Stock to Inventory',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: c.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Select an existing expiry date or create a new batch',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded, color: c.textMuted, size: 20),
                            onPressed: () => Navigator.of(dialogCtx).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Med Info Card
                      Builder(builder: (_) {
                        final rawTypeCol = _typeColor(medType);
                        final typeCol = _isDark
                            ? Color.lerp(rawTypeCol, SoftPalette.gray50, 0.35)!
                            : rawTypeCol;
                        final barcodeStr = (med['barcode'] ?? med['rollNo'] ?? '').toString().trim();
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: c.surfaceSunken,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            children: [
                              _buildLeadingTypeAvatar(medType, typeCol, _isDark),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      medName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14.5,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        _buildUniformBarcodeBadge(barcodeStr, c),
                                        _buildUniformCategoryBadge(medType, typeCol, _isDark),
                                        _buildUniformDoseBadge(medDose, c),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: (isNewBatchMode ? 0 : batchStock) == 0 ? c.dangerBg : c.successBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: ((isNewBatchMode ? 0 : batchStock) == 0 ? c.danger : c.success).withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      isNewBatchMode ? 'New Batch' : 'Batch Stock',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: (isNewBatchMode ? 0 : batchStock) == 0 ? c.danger : c.success,
                                      ),
                                    ),
                                    Text(
                                      isNewBatchMode ? '0' : '$batchStock',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: (isNewBatchMode ? 0 : batchStock) == 0 ? c.danger : c.success,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 14),

                      // Target Facility Camp Selector
                      if (_hasMultiCamps) ...[
                        Text(
                          'Target Facility Camp:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: c.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Builder(
                          builder: (_) {
                            final branchCamps = CampSessionService.getCampsForBranch(_effectiveBranchId);
                            final campsToShow = branchCamps.isNotEmpty
                                ? branchCamps
                                : (isKarachi
                                    ? [
                                        {'id': 'saddar', 'name': 'Saddar Camp'},
                                        {'id': 'haji_camp', 'name': 'Haji Camp'},
                                      ]
                                    : <Map<String, dynamic>>[]);
                            if (campsToShow.isEmpty) return const SizedBox.shrink();
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: campsToShow.map((camp) {
                                final cId = (camp['id'] ?? '').toString();
                                final cName = (camp['name'] ??
                                        CampSessionService.getCampLabel(cId, _effectiveBranchId))
                                    .toString();
                                final isSelected = targetCamp == cId ||
                                    (isKarachi &&
                                        cId == 'saddar' &&
                                        (targetCamp.isEmpty || targetCamp == 'saddar'));
                                return InkWell(
                                  onTap: () {
                                    setDialogState(() {
                                      targetCamp = cId;
                                      existingBatches = _getExistingBatchesForMed(med, targetCamp);
                                      if (existingBatches.isEmpty) {
                                        isNewBatchMode = true;
                                        selectedExistingBatch = null;
                                      } else {
                                        selectedExistingBatch = existingBatches.first;
                                      }
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected ? c.brand : c.surfaceSunken,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isSelected ? c.brand : c.border,
                                      ),
                                    ),
                                    child: Text(
                                      cName,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: isSelected ? c.onBrand : c.textPrimary,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                      ],

                      // ── Expiry Date (Batch) Mode Selector ───────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.event_note_rounded, size: 16, color: c.brand),
                              const SizedBox(width: 6),
                              Text(
                                'Expiry Date (Batch):',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: c.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          if (existingBatches.isNotEmpty)
                            Text(
                              '${existingBatches.length} old batch${existingBatches.length > 1 ? 'es' : ''} available',
                              style: TextStyle(fontSize: 11, color: c.textMuted, fontWeight: FontWeight.w500),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Segmented Mode Switch: [Select Old Expiry]  [+ Add New Expiry]
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: c.surfaceSunken,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: c.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: existingBatches.isEmpty
                                    ? null
                                    : () {
                                        setDialogState(() {
                                          isNewBatchMode = false;
                                          selectedExistingBatch ??= existingBatches.first;
                                        });
                                      },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: !isNewBatchMode ? c.surface : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: !isNewBatchMode
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.05),
                                              blurRadius: 4,
                                              offset: const Offset(0, 1),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.history_rounded,
                                        size: 15,
                                        color: !isNewBatchMode ? c.brand : (existingBatches.isEmpty ? c.textMuted : c.textSecondary),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Select Old Expiry',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: !isNewBatchMode ? FontWeight.w700 : FontWeight.w500,
                                          color: !isNewBatchMode ? c.brand : (existingBatches.isEmpty ? c.textMuted : c.textSecondary),
                                        ),
                                      ),
                                      if (existingBatches.isNotEmpty) ...[
                                        const SizedBox(width: 5),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: !isNewBatchMode ? c.brandSoft : c.border,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            '${existingBatches.length}',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: !isNewBatchMode ? c.brandStrong : c.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: InkWell(
                                onTap: () {
                                  setDialogState(() {
                                    isNewBatchMode = true;
                                  });
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isNewBatchMode ? c.surface : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: isNewBatchMode
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.05),
                                              blurRadius: 4,
                                              offset: const Offset(0, 1),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.add_circle_outline_rounded,
                                        size: 15,
                                        color: isNewBatchMode ? c.brand : c.textSecondary,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '+ Add New Expiry',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isNewBatchMode ? FontWeight.w700 : FontWeight.w500,
                                          color: isNewBatchMode ? c.brand : c.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Existing Batches List
                      if (!isNewBatchMode) ...[
                        if (existingBatches.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: c.warningBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: c.warning.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline_rounded, color: c.warning, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'No old batches found in $campLabel. Please choose "Add New Expiry" to set an expiry date.',
                                    style: TextStyle(fontSize: 11.5, color: c.warning, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Container(
                            constraints: const BoxConstraints(maxHeight: 180),
                            decoration: BoxDecoration(
                              color: c.surfaceSunken,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: c.border),
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.all(6),
                              itemCount: existingBatches.length,
                              separatorBuilder: (_, index) => const SizedBox(height: 4),
                              itemBuilder: (ctx, idx) {
                                final batch = existingBatches[idx];
                                final bExp = (batch['expiryDate'] ?? '').toString();
                                final bStock = _safeInt(batch['quantity']);
                                final isSelected = selectedExistingBatch != null &&
                                    (selectedExistingBatch!['medicineId'] ?? selectedExistingBatch!['id'] ?? selectedExistingBatch!['_docId']) ==
                                        (batch['medicineId'] ?? batch['id'] ?? batch['_docId']);
                                final daysRemaining = _expiryDaysRemaining(bExp);
                                final isExpired = daysRemaining < 0;
                                final isNearExpiry = !isExpired && daysRemaining <= 60;

                                return InkWell(
                                  onTap: () {
                                    setDialogState(() {
                                      selectedExistingBatch = batch;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected ? c.brandSoft : c.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isSelected ? c.brand : c.border,
                                        width: isSelected ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                                          size: 17,
                                          color: isSelected ? c.brand : c.textMuted,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    'Exp: ${_formatExpiryDisplay(bExp)}',
                                                    style: TextStyle(
                                                      fontSize: 12.5,
                                                      fontWeight: FontWeight.w700,
                                                      color: isSelected ? c.brandStrong : c.textPrimary,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  if (isExpired)
                                                    _badgeChip('EXPIRED', c.danger, c.dangerBg)
                                                  else if (isNearExpiry)
                                                    _badgeChip('EXPIRING SOON', c.warning, c.warningBg),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                'Current stock in this batch: $bStock units',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isSelected ? c.brandStrong.withValues(alpha: 0.8) : c.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: bStock == 0 ? c.dangerBg : c.successBg,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '$bStock in stock',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: bStock == 0 ? c.danger : c.success,
                                            ),
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

                      // New Batch Expiry Picker
                      if (isNewBatchMode) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: c.surfaceSunken,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: c.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.calendar_today_rounded, size: 16, color: c.brand),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Set Expiry Date for New Batch:',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textPrimary),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              // Date Picker Row
                              Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: () async {
                                        final picked = await showDatePicker(
                                          context: ctx,
                                          initialDate: newExpiryDate,
                                          firstDate: DateTime(DateTime.now().year, DateTime.now().month + 1, 1),
                                          lastDate: DateTime.now().add(const Duration(days: 365 * 15)),
                                          initialDatePickerMode: DatePickerMode.year,
                                          builder: (context, child) {
                                            return Theme(
                                              data: Theme.of(context).copyWith(
                                                colorScheme: ColorScheme.light(
                                                  primary: c.brand,
                                                  onPrimary: c.onBrand,
                                                  surface: c.surface,
                                                  onSurface: c.textPrimary,
                                                ),
                                              ),
                                              child: child!,
                                            );
                                          },
                                        );
                                        if (picked != null) {
                                          setDialogState(() {
                                            newExpiryDate = DateTime(picked.year, picked.month, 1);
                                            newExpiryCtrl.text = DateFormat('01-MM-yyyy').format(picked);
                                          });
                                        }
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: c.surface,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: c.borderStrong),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.event_available_rounded, size: 18, color: c.brand),
                                            const SizedBox(width: 8),
                                            Text(
                                              DateFormat('dd-MM-yyyy').format(newExpiryDate),
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: c.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '(${DateFormat('MMM yyyy').format(newExpiryDate)})',
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: c.textMuted,
                                              ),
                                            ),
                                            const Spacer(),
                                            Icon(Icons.calendar_month_rounded, size: 17, color: c.brand),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Quick Expiry Shortcut Chips
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _quickDateChip('+1 Year', () {
                                    final d = DateTime(DateTime.now().year + 1, DateTime.now().month, 1);
                                    setDialogState(() {
                                      newExpiryDate = d;
                                      newExpiryCtrl.text = DateFormat('dd-MM-yyyy').format(d);
                                    });
                                  }, c),
                                  _quickDateChip('+2 Years', () {
                                    final d = DateTime(DateTime.now().year + 2, DateTime.now().month, 1);
                                    setDialogState(() {
                                      newExpiryDate = d;
                                      newExpiryCtrl.text = DateFormat('dd-MM-yyyy').format(d);
                                    });
                                  }, c),
                                  _quickDateChip('+3 Years', () {
                                    final d = DateTime(DateTime.now().year + 3, DateTime.now().month, 1);
                                    setDialogState(() {
                                      newExpiryDate = d;
                                      newExpiryCtrl.text = DateFormat('dd-MM-yyyy').format(d);
                                    });
                                  }, c),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),

                      // Quantity Input with Steppers & Quick Increment Chips
                      Text(
                        'Quantity to Add:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _qtyBtn(Icons.remove_rounded, () {
                            final v = int.tryParse(qtyCtrl.text) ?? 1;
                            if (v > 1) setDialogState(() => qtyCtrl.text = '${v - 1}');
                          }),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: qtyCtrl,
                              textAlign: TextAlign.center,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              cursorColor: c.brand,
                              onChanged: (_) => setDialogState(() {}),
                              style: TextStyle(
                                color: c.brand,
                                fontWeight: FontWeight.w800,
                                fontSize: 20,
                              ),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: c.surfaceSunken,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: c.border),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: c.border),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(color: c.brand, width: 1.8),
                                ),
                                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _qtyBtn(Icons.add_rounded, () {
                            final v = int.tryParse(qtyCtrl.text) ?? 0;
                            setDialogState(() => qtyCtrl.text = '${v + 1}');
                          }),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Quick Increment Chips
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [10, 50, 100, 500].map((increment) {
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 3),
                              child: InkWell(
                                onTap: () {
                                  final v = int.tryParse(qtyCtrl.text) ?? 0;
                                  setDialogState(() => qtyCtrl.text = '${v + increment}');
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  decoration: BoxDecoration(
                                    color: c.surfaceSunken,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: c.border),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '+$increment',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: c.brandStrong,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),

                      // Resulting Stock Impact Preview Box
                      Builder(builder: (_) {
                        final addQty = int.tryParse(qtyCtrl.text) ?? 0;
                        final int beforeQty = isNewBatchMode ? 0 : batchStock;
                        final int afterQty = beforeQty + addQty;
                        final String targetExpDesc = isNewBatchMode
                            ? 'New Batch: ${DateFormat('dd-MM-yyyy').format(newExpiryDate)}'
                            : (selectedExistingBatch != null
                                ? 'Existing Batch: ${_formatExpiryDisplay(selectedExistingBatch!['expiryDate'])}'
                                : 'No batch selected');
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: c.brandSoft.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: c.brand.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.inventory_rounded, size: 16, color: c.brand),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Stock Impact: $beforeQty + $addQty = $afterQty units',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: c.brandStrong,
                                      ),
                                    ),
                                    Text(
                                      targetExpDesc,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: c.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 18),

                      // Submit & Cancel Buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: isSubmitting ? null : () => Navigator.of(dialogCtx).pop(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.textSecondary,
                                side: BorderSide(color: c.borderStrong),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: Text(
                                'Cancel',
                                style: TextStyle(color: c.textSecondary, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed: isSubmitting
                                  ? null
                                  : () async {
                                      final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                                      if (qty < 1) {
                                        _snack('Enter a valid quantity (min 1)', err: true);
                                        return;
                                      }
                                      if (!isNewBatchMode && selectedExistingBatch == null) {
                                        _snack('Please select an existing expiry batch', err: true);
                                        return;
                                      }
                                      final expToSubmit = isNewBatchMode
                                          ? DateFormat('dd-MM-yyyy').format(newExpiryDate)
                                          : (selectedExistingBatch!['expiryDate'] ?? '').toString();

                                      setDialogState(() => isSubmitting = true);
                                      Navigator.of(dialogCtx).pop();
                                      await _submitAddStockForMed(
                                        med: med,
                                        qty: qty,
                                        targetCamp: targetCamp,
                                        isNewBatch: isNewBatchMode,
                                        expiryDateStr: expToSubmit,
                                        selectedExistingBatch: selectedExistingBatch,
                                      );
                                    },
                              icon: isSubmitting
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand),
                                    )
                                  : const Icon(Icons.add_task_rounded, size: 18),
                              label: Text(
                                _hasMultiCamps && campLabel.isNotEmpty && campLabel != 'Inventory'
                                    ? 'Add Stock to $campLabel'
                                    : 'Add Stock to Inventory',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: c.brand,
                                foregroundColor: c.onBrand,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                elevation: 0,
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
        },
      ),
    );
  }

  // ── Submit Add Stock for specific medicine ──────────────────────────────────
  Future<void> _submitAddStockForMed({
    required Map<String, dynamic> med,
    required int qty,
    required String targetCamp,
    required bool isNewBatch,
    required String expiryDateStr,
    Map<String, dynamic>? selectedExistingBatch,
  }) async {
    final campLabel = CampSessionService.getCampLabel(targetCamp);
    final medName = (med['name'] ?? med['formula'] ?? 'Medicine').toString();
    final medFormula = (med['formula'] ?? med['name'] ?? medName).toString();
    final medType = (med['type'] ?? 'Tablet').toString();
    final medDose = (med['dose'] ?? '').toString();

    try {
      final userInfo = await _getUserInfo();

      final pool = _poolFor(med, targetCamp);
      if (pool == null) {
        _snack('Please select a specific camp above before adding stock.', err: true);
        return;
      }

      // ── Option A: Restock to Existing Batch ────────────────────────────────
      if (!isNewBatch && selectedExistingBatch != null) {
        final medId = (selectedExistingBatch['medicineId'] ?? selectedExistingBatch['id'] ?? selectedExistingBatch['_docId'])?.toString() ?? '';
        if (medId.isEmpty) {
          _snack('Invalid batch ID', err: true);
          return;
        }
        await StockActions.restock(pool, medId, qty.toDouble(), ref: 'add stock');

        final logData = {
          'action': 'add_stock',
          'medicineName': medName,
          'medicineFormula': medFormula,
          'medicineType': medType,
          'medicineDose': medDose,
          'medicineId': medId,
          'quantityAdded': qty,
          'expiryDate': selectedExistingBatch['expiryDate'] ?? expiryDateStr,
          'isNewBatch': false,
          'branchId': _effectiveBranchId,
          'dispensaryId': targetCamp,
          'campId': targetCamp,
          'campName': campLabel,
          'performedBy': userInfo['uid'],
          'performedByName': userInfo['username'],
          'timestamp': DateTime.now().toIso8601String(),
          'createdAt': DateTime.now().toIso8601String(),
          'details': 'Restocked +$qty units to $medName (Exp: ${selectedExistingBatch['expiryDate'] ?? expiryDateStr}) at $campLabel',
        };
        await LocalStorageService.saveLocalInventoryLog(logData);
        await _uploadInventoryLog(logData);

        _snack('+$qty added to $medName (Exp: ${_formatExpiryDisplay(selectedExistingBatch['expiryDate'] ?? expiryDateStr)}) at $campLabel!');
        _loadAllMedicines();
        return;
      }

      // ── Option B: New Expiry Date ──────────────────────────────────────────
      // Check if an existing batch with the exact same expiry date already exists in this camp
      final existingBatches = _getExistingBatchesForMed(med, targetCamp);
      final targetParsed = MasterProformaService.parseExpiryDate(expiryDateStr);
      Map<String, dynamic>? matchExisting;
      for (final b in existingBatches) {
        final bExp = (b['expiryDate'] ?? '').toString().trim();
        if (bExp.isNotEmpty && bExp == expiryDateStr.trim()) {
          matchExisting = b;
          break;
        }
        final bParsed = MasterProformaService.parseExpiryDate(bExp);
        if (bParsed.year < 3000 && targetParsed.year < 3000) {
          if (bParsed.year == targetParsed.year && bParsed.month == targetParsed.month) {
            matchExisting = b;
            break;
          }
        }
      }

      if (matchExisting != null) {
        final medId = (matchExisting['medicineId'] ?? matchExisting['id'] ?? matchExisting['_docId'])?.toString() ?? '';
        await StockActions.restock(pool, medId, qty.toDouble(), ref: 'add stock');

        final logData = {
          'action': 'add_stock',
          'medicineName': medName,
          'medicineFormula': medFormula,
          'medicineType': medType,
          'medicineDose': medDose,
          'medicineId': medId,
          'quantityAdded': qty,
          'expiryDate': matchExisting['expiryDate'] ?? expiryDateStr,
          'isNewBatch': false,
          'branchId': _effectiveBranchId,
          'dispensaryId': targetCamp,
          'campId': targetCamp,
          'campName': campLabel,
          'performedBy': userInfo['uid'],
          'performedByName': userInfo['username'],
          'timestamp': DateTime.now().toIso8601String(),
          'createdAt': DateTime.now().toIso8601String(),
          'details': 'Restocked +$qty units of $medName into existing batch (Exp: ${matchExisting['expiryDate']}) at $campLabel',
        };
        await LocalStorageService.saveLocalInventoryLog(logData);
        await _uploadInventoryLog(logData);

        _snack('+$qty added to existing batch of $medName (Exp: ${_formatExpiryDisplay(matchExisting['expiryDate'])}) at $campLabel!');
        _loadAllMedicines();
        return;
      }

      // Create brand new batch in the pool
      final newDocId = RequestUtils.generateDocId(
        medName,
        medType,
        medDose,
        expiryDateStr,
        campId: targetCamp,
      );

      final barcode = (med['barcode'] ?? med['rollNo'] ?? '').toString();
      final itemCode = (med['itemCode'] ?? med['code'] ?? '').toString();
      final packBarcode = (med['packBarcode'] ?? '').toString();
      final price = med['price'] is num
          ? (med['price'] as num).toDouble()
          : (double.tryParse(med['price']?.toString() ?? '') ?? 0.0);

      final stockData = {
        'docId': newDocId,
        'id': newDocId,
        'medicineId': newDocId,
        if (itemCode.isNotEmpty) 'code': itemCode,
        if (itemCode.isNotEmpty) 'itemCode': itemCode,
        if (barcode.isNotEmpty) 'barcode': barcode,
        if (barcode.isNotEmpty) 'rollNo': barcode,
        if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
        'name': medName,
        'formula': medFormula,
        'type': medType,
        'dose': medDose,
        'price': price,
        'expiryDate': expiryDateStr,
        'isCustomized': med['isCustomized'] == true,
        'branchId': _effectiveBranchId,
        'dispensaryId': targetCamp,
        'campId': targetCamp,
        'addedBy': userInfo['username'] ?? '',
        'performedByName': userInfo['username'] ?? '',
        'performedByUid': userInfo['uid'] ?? '',
        'createdAt': DateTime.now().toIso8601String(),
        'lastUpdated': DateTime.now().toIso8601String(),
      };

      await StockActions.addBatch(
        pool,
        newDocId,
        stockData,
        initialQty: qty.toDouble(),
        ref: 'add stock (new expiry)',
        opKey: 'add_stock_${DateTime.now().microsecondsSinceEpoch}',
      );

      final logData = {
        'action': 'add_stock',
        'medicineName': medName,
        'medicineFormula': medFormula,
        'medicineType': medType,
        'medicineDose': medDose,
        'medicineId': newDocId,
        'docId': newDocId,
        'quantityAdded': qty,
        'expiryDate': expiryDateStr,
        'isNewBatch': true,
        'branchId': _effectiveBranchId,
        'dispensaryId': targetCamp,
        'campId': targetCamp,
        'campName': campLabel,
        'performedBy': userInfo['uid'],
        'performedByName': userInfo['username'],
        'timestamp': DateTime.now().toIso8601String(),
        'createdAt': DateTime.now().toIso8601String(),
        'details': 'Created new batch & added +$qty units of $medName (New Exp: $expiryDateStr) at $campLabel',
      };
      await LocalStorageService.saveLocalInventoryLog(logData);
      await _uploadInventoryLog(logData);

      _snack('+$qty added to $medName with new expiry (${_formatExpiryDisplay(expiryDateStr)}) at $campLabel!');
      _loadAllMedicines();
    } catch (e) {
      _snack('Error updating stock: $e', err: true);
    }
  }

  /// Only the dispenser asks for approval; every other role (doctor, supervisor, managers,
  /// executives) changes the batch directly (user rule, 2026-11-21).
  bool get _editNeedsApproval => widget.isDispenser && !widget.isAdmin && !widget.isDoctor;

  /// Every real batch (one per expiry) of the same medicine in the same pool, earliest
  /// expiry first, so the user picks exactly which batch to edit.
  List<Map<String, dynamic>> _batchesOf(Map<String, dynamic> med) {
    String norm(Object? v) => (v ?? '').toString().trim().toLowerCase();
    final pool = norm(med['pool']);
    final out = <Map<String, dynamic>>[];
    for (final b in _ledgerItems()) {
      if (norm(b['pool']) != pool) continue;
      if (norm(b['name']) != norm(med['name'])) continue;
      if (norm(b['type']) != norm(med['type'])) continue;
      if (norm(b['dose']).replaceAll(' ', '') != norm(med['dose']).replaceAll(' ', '')) continue;
      final id = (b['medicineId'] ?? b['id']).toString();
      out.add({...b, '_docId': id, '_docIds': [id], 'quantity': StockReader.qty(b).toInt()});
    }
    StockReader.sortFefo(out);
    return out.isEmpty ? [med] : out;
  }

  // ── Edit Request Sheet ─────────────────────────────────────────────────────
  void _showEditRequestSheet(Map<String, dynamic> med) {
    final batches = _batchesOf(med);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditRequestSheet(
        branchId: widget.branchId,
        medicine: med,
        batches: batches,
        needsApproval: _editNeedsApproval,
        allTypes: _allTypes,
        doseOptions: _doseOptions,
        isAdmin: widget.isAdmin,
        isDoctor: widget.isDoctor,
        isDispenser: widget.isDispenser,
        isBarcodeTaken: _isBarcodeTaken,
        onSubmit: (batch, updatedFields) =>
            _submitEditRequest(batch, updatedFields),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback fn) {
    final c = context.comfort;
    return InkWell(
      onTap: fn,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: c.brandSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.brand.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, color: c.brand, size: 22),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TAB 2 — Register New Medicine
  // ══════════════════════════════════════════════════════════════════════════
  Widget _registerTab() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);

    if (!_canRegisterMedicine) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 64, color: c.warning),
              const SizedBox(height: 16),
              Text(
                'Access Restricted',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: c.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Registering permanent medicines into the Medicine Catalog is restricted to Chairman, HQ Managers, and Admins.\nDispensary staff and doctors can restock and add branch inventory from Add Medicine.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: c.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    final proformaBarcodeField = TextFormField(
      controller: _regCodeCtrl,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(3),
      ],
      style: TextStyle(color: c.textPrimary, fontSize: 14.5),
      cursorColor: c.brand,
      decoration: _inputDec(
        'Barcode (001–999)',
        icon: Icons.qr_code_rounded,
        hint: 'e.g. ${MasterProformaService.getNextRollNumber()} (auto if blank)',
      ),
      validator: (v) {
        final raw = v?.trim() ?? '';
        if (raw.isEmpty) return null; // Auto-assigned if left empty
        if (!MasterProformaService.isValidProformaBarcode(raw)) {
          return 'Must be a 3-digit number from 001 to 999';
        }
        return null;
      },
    );

    final packBarcodeField = TextFormField(
      controller: _regPackBarcodeCtrl,
      style: TextStyle(color: c.textPrimary, fontSize: 14.5),
      cursorColor: c.brand,
      decoration: _inputDec(
        'Pack Barcode (Optional)',
        icon: Icons.qr_code_scanner_rounded,
        hint: 'External barcode (e.g. 8964000123456)',
      ),
    );

    final typeDropdown = DropdownButtonFormField<String>(
      initialValue: _regType,
      dropdownColor: c.surface,
      style: TextStyle(color: c.textPrimary, fontSize: 14),
      decoration: _inputDec('Type', icon: _typeIcon(_regType)),
      items: _allTypes
          .map((t) => DropdownMenuItem(
                value: t,
                child: Row(
                  children: [
                    MedicineTypeIcon(type: t, size: 16, color: _typeColor(t)),
                    const SizedBox(width: 8),
                    Text(t, style: TextStyle(color: c.textPrimary)),
                  ],
                ),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) {
          setState(() {
            _regType = v;
            _regSelectedDose = null;
            _regDoseCtrl.clear();
          });
        }
      },
    );

    final Widget? doseField = _hasDoseDropdown
        ? DropdownButtonFormField<String>(
            initialValue: _regSelectedDose,
            dropdownColor: c.surface,
            style: TextStyle(color: c.textPrimary, fontSize: 14),
            decoration: _inputDec('Dose', icon: Icons.science_rounded),
            hint: Text('Select dose', style: TextStyle(color: c.textMuted)),
            items: (_doseOptions[_regType] ?? [])
                .map((d) => DropdownMenuItem(
                      value: d,
                      child: Text(d, style: TextStyle(color: c.textPrimary)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _regSelectedDose = v),
            validator: (v) =>
                (_regType == 'Tablet') ? null : (v == null ? 'Select a dose' : null),
          )
        : (_usesFreeTextDose
            ? TextFormField(
                controller: _regDoseCtrl,
                style: TextStyle(color: c.textPrimary, fontSize: 14.5),
                cursorColor: c.brand,
                decoration: _inputDec(
                  _regType == 'Nebulization'
                      ? 'Dose per session'
                      : 'Dose / Variant (e.g. 500mg)',
                  icon: Icons.science_rounded,
                ),
              )
            : null);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _card(
            child: Form(
              key: _regFormKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('Register Medicine to Catalog'),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(
                      'Creates a permanent generic catalog item available to all branches and camps.',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Name (Formula)
                  TextFormField(
                    controller: _regNameCtrl,
                    style: TextStyle(color: c.textPrimary, fontSize: 15),
                    cursorColor: c.brand,
                    decoration: _inputDec(
                      'Formula',
                      icon: Icons.medication_rounded,
                      hint: 'e.g. Amoxicillin, Panadol Extra',
                    ),
                    validator: (v) =>
                        v?.trim().isEmpty ?? true ? 'Formula is required' : null,
                  ),
                  if (_liveSpellingSuggestion != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.infoBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: c.info.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lightbulb_outline_rounded, size: 18, color: c.info),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                style: TextStyle(fontSize: 12, color: c.textPrimary),
                                children: [
                                  const TextSpan(text: 'Did you mean '),
                                  TextSpan(
                                    text: '${_liveSpellingSuggestion!['name']}',
                                    style: TextStyle(fontWeight: FontWeight.w700, color: c.info),
                                  ),
                                  if (_liveSpellingSuggestion!['formula'] != null)
                                    TextSpan(text: ' (${_liveSpellingSuggestion!['formula']})'),
                                  const TextSpan(text: '?'),
                                ],
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _regNameCtrl.text = _liveSpellingSuggestion!['name'] ?? '';
                                _liveSpellingSuggestion = null;
                              });
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: c.info,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Apply Fix',
                                style: TextStyle(
                                  color: c.onBrand,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),

                  // Proforma Barcode (001–999) + Pack Barcode
                  if (isCompact) ...[
                    proformaBarcodeField,
                    const SizedBox(height: 14),
                    packBarcodeField,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: proformaBarcodeField),
                        const SizedBox(width: 14),
                        Expanded(child: packBarcodeField),
                      ],
                    ),
                  const SizedBox(height: 14),

                  // Type Dropdown & Dose side-by-side on desktop
                  if (doseField != null && !isCompact)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: typeDropdown),
                        const SizedBox(width: 14),
                        Expanded(child: doseField),
                      ],
                    )
                  else ...[
                    typeDropdown,
                    if (doseField != null) ...[
                      const SizedBox(height: 14),
                      doseField,
                    ],
                  ],
                  const SizedBox(height: 14),

                  // Reason for Registration (MANDATORY AUDIT)
                  TextFormField(
                    controller: _regReasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: c.textPrimary, fontSize: 14),
                    cursorColor: c.brand,
                    decoration: _inputDec(
                      'Reason for Registration (Mandatory Audit) *',
                      icon: Icons.history_edu_rounded,
                      hint: 'e.g. Approved generic formula per Chairman / HQ decision',
                    ),
                    validator: (v) => v?.trim().isEmpty ?? true
                        ? 'Reason is required for Medicine Catalog audit logging'
                        : null,
                  ),
                  const SizedBox(height: 22),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isSubmittingReg ? null : _submitRegister,
                      icon: _isSubmittingReg
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.onBrand,
                              ),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(
                        _isSubmittingReg
                            ? 'Registering...'
                            : 'Save Permanently to Medicine Catalog',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.brand,
                        foregroundColor: c.onBrand,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────────────────
  Widget _card({required Widget child}) {
    final c = context.comfort;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }

  Widget _sectionLabel(String text) {
    final c = context.comfort;
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: c.brand,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  int _safeInt(dynamic val) {
    if (val == null) return 0;
    if (val is int) return val;
    if (val is double) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Edit Request Bottom Sheet
// ═══════════════════════════════════════════════════════════════════════════════
class _EditRequestSheet extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> medicine;
  final List<String> allTypes;
  final Map<String, List<String>> doseOptions;
  final bool isAdmin;
  final bool isDoctor;
  final bool isDispenser;
  /// Real batches of this medicine (one per expiry), earliest expiry first.
  final List<Map<String, dynamic>> batches;
  /// true: a request a supervisor approves (dispenser). false: the change applies now.
  final bool needsApproval;
  final Future<bool> Function(String code, {String? excludeDocId}) isBarcodeTaken;
  final Future<void> Function(Map<String, dynamic> batch, Map<String, dynamic> updatedFields) onSubmit;

  const _EditRequestSheet({
    required this.branchId,
    required this.medicine,
    required this.batches,
    required this.needsApproval,
    required this.allTypes,
    required this.doseOptions,
    this.isAdmin = false,
    this.isDoctor = false,
    this.isDispenser = false,
    required this.isBarcodeTaken,
    required this.onSubmit,
  });

  @override
  State<_EditRequestSheet> createState() => _EditRequestSheetState();
}

class _EditRequestSheetState extends State<_EditRequestSheet> {
  late TextEditingController _nameCtrl;
  late TextEditingController _doseCtrl;
  late TextEditingController _priceCtrl;
  late TextEditingController _qtyCtrl;
  late TextEditingController _expiryCtrl;
  late TextEditingController _reasonCtrl;
  late TextEditingController _codeCtrl;
  late TextEditingController _barcodeCtrl;
  late TextEditingController _packBarcodeCtrl;
  late String _selectedType;

  bool _submitting = false;
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

  /// The batch being edited (one expiry, one record).
  late Map<String, dynamic> _batch;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _doseCtrl = TextEditingController();
    _qtyCtrl = TextEditingController();
    _priceCtrl = TextEditingController();
    _expiryCtrl = TextEditingController();
    _reasonCtrl = TextEditingController();
    _codeCtrl = TextEditingController();
    _barcodeCtrl = TextEditingController();
    _packBarcodeCtrl = TextEditingController();
    final wanted = (widget.medicine['_docId'] ?? widget.medicine['id'] ?? '').toString();
    _batch = widget.batches.firstWhere(
      (b) => (b['_docId'] ?? b['id']).toString() == wanted,
      orElse: () => widget.batches.first,
    );
    _fillFrom(_batch);
  }

  /// Loads the fields from one batch (also when the user picks another batch).
  void _fillFrom(Map<String, dynamic> med) {
    _nameCtrl.text = med['name']?.toString() ?? '';
    _doseCtrl.text = med['dose']?.toString() ?? '';
    _qtyCtrl.text = med['quantity']?.toString() ?? '0';
    _priceCtrl.text = _fmtPrice(_parsePrice(med['price']));
    _expiryCtrl.text = med['expiryDate']?.toString() ?? '';
    _codeCtrl.text = (med['code'] ?? med['itemCode'] ?? '').toString();
    _barcodeCtrl.text = (med['barcode'] ?? med['rollNo'] ?? '').toString();
    _packBarcodeCtrl.text = med['packBarcode']?.toString() ?? '';
    _selectedType = widget.allTypes.contains(med['type'])
        ? med['type'].toString()
        : widget.allTypes.first;
  }

  void _pickBatch(Map<String, dynamic> b) {
    setState(() {
      _batch = b;
      _fillFrom(b);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _doseCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _expiryCtrl.dispose();
    _reasonCtrl.dispose();
    _codeCtrl.dispose();
    _barcodeCtrl.dispose();
    _packBarcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    {
      // Every user: only quantity and expiry may change here; everything else is sent
      // exactly as the batch has it, so neither a direct save nor an approval can rename,
      // re-type or re-code a medicine (user rule 2026-11-21).
      final b = _batch;
      final locked = <String, dynamic>{
        'name': b['name'],
        'formula': b['formula'] ?? b['name'],
        'type': b['type'],
        'dose': b['dose'] ?? '',
        if ((b['code'] ?? b['itemCode']) != null) 'code': b['code'] ?? b['itemCode'],
        if ((b['code'] ?? b['itemCode']) != null) 'itemCode': b['code'] ?? b['itemCode'],
        if ((b['barcode'] ?? b['rollNo']) != null) 'barcode': b['barcode'] ?? b['rollNo'],
        if ((b['barcode'] ?? b['rollNo']) != null) 'rollNo': b['barcode'] ?? b['rollNo'],
        if (b['packBarcode'] != null) 'packBarcode': b['packBarcode'],
        'price': (b['price'] ?? '').toString(),
        'quantity': int.tryParse(_qtyCtrl.text.trim()) ?? 0,
        'expiryDate': _expiryCtrl.text.trim(),
        'reason': _reasonCtrl.text.trim(),
      };
      try {
        await widget.onSubmit(_batch, locked);
        if (!mounted) return;
        Navigator.pop(context);
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
    }
  }

  // ── Compact layout (2026-11-21): current values at a glance, fields in two columns,
  // expiry picker, quick reasons, and the Submit button always visible below the fields.
  static const _quickReasons = [
    'Wrong expiry',
    'Wrong quantity',
    'Counted again',
    'Damaged',
  ];

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month + 1, 1);
    final current = parseExpiryMonth(_expiryCtrl.text);
    final initial = (current != null && !current.isBefore(first)) ? current : first;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(now.year + 10, 12, 31),
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Expiry month',
    );
    if (picked != null && mounted) {
      setState(() => _expiryCtrl.text = DateFormat('MM-yyyy').format(picked));
    }
  }

  /// One card per batch: expiry + quantity. Tapping a card edits that batch only.
  Widget _batchPicker() {
    final c = context.comfort;
    final selectedId = (_batch['_docId'] ?? _batch['id']).toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${widget.batches.length} batches · pick the one to edit',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textSecondary)),
      const SizedBox(height: 6),
      SizedBox(
        height: 58,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: widget.batches.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final b = widget.batches[i];
            final id = (b['_docId'] ?? b['id']).toString();
            final selected = id == selectedId;
            final exp = (b['expiryDate'] ?? '').toString().trim();
            final d = parseExpiryMonth(exp);
            final expLabel = d == null ? (exp.isEmpty ? 'No expiry' : exp) : DateFormat('MMM yyyy').format(d);
            return InkWell(
              onTap: _submitting ? null : () => _pickBatch(b),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 132,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? c.brandSoft : c.surfaceSunken,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? c.brand : c.border, width: selected ? 1.6 : 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Exp $expLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.textPrimary)),
                    const SizedBox(height: 2),
                    Text('${b['quantity'] ?? 0} in stock${i == 0 ? ' · used first' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: c.textMuted)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _pair(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)],
      );

  Widget _currentChip(String label, String value) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 11.5, color: c.textMuted),
          children: [
            TextSpan(text: '$label  '),
            TextSpan(
              text: value.isEmpty ? '—' : value,
              style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final med = _batch;
    final originalExpiry = (med['expiryDate'] ?? '').toString().trim();
    final ask = widget.needsApproval;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: c.borderStrong, borderRadius: BorderRadius.circular(2)),
              ),
            ),

            // Title + current values
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    '${ask ? 'Request edit' : 'Edit batch'} · ${med['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                      ask
                          ? 'A supervisor approves it before anything changes.'
                          : 'Changes apply to the selected batch right away and are logged.',
                      style: TextStyle(fontSize: 11.5, color: c.textSecondary)),
                ]),
              ),
              IconButton(
                icon: Icon(GIcons.close, color: c.textMuted),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            const SizedBox(height: 8),
            if (widget.batches.length > 1) ...[
              _batchPicker(),
              const SizedBox(height: 10),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                _currentChip('Now', '${med['quantity'] ?? 0}'),
                _currentChip('Expiry', originalExpiry),
                _currentChip('Barcode', (med['barcode'] ?? med['rollNo'] ?? '').toString()),
                _currentChip('Type', (med['type'] ?? '').toString()),
                if ((med['dose'] ?? '').toString().trim().isNotEmpty) _currentChip('Dose', med['dose'].toString()),
              ]),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: c.border),
            const SizedBox(height: 12),

            Flexible(
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(children: [
                    // Name, type, dose and barcodes are fixed for every user (user rule
                    // 2026-11-21): only quantity and expiry can be changed here.
                    ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: c.surfaceSunken,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: c.border),
                        ),
                        child: Row(children: [
                          Icon(GIcons.lock, size: 16, color: c.textMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Name, type, dose and barcode cannot be changed here. '
                              '${widget.needsApproval ? 'You can ask for a new quantity or expiry.' : 'Only the quantity and expiry can be changed.'}',
                              style: TextStyle(fontSize: 12, color: c.textSecondary),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _pair(
                      _field(
                        controller: _qtyCtrl,
                        label: 'Total quantity',
                        icon: GIcons.inventory,
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          if (int.tryParse(v.trim()) == null) return 'Invalid number';
                          return null;
                        },
                      ),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Expanded(
                          child: _field(
                            controller: _expiryCtrl,
                            label: 'Expiry (MM-YYYY)',
                            icon: GIcons.calendar,
                            // Only a changed expiry is checked against "after this month".
                            validator: (v) => (v ?? '').trim() == originalExpiry
                                ? null
                                : expiryInputError(v ?? ''),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: IconButton.filledTonal(
                            tooltip: 'Pick month',
                            onPressed: _pickExpiry,
                            icon: const Icon(GIcons.calendar, size: 18),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    _field(
                      controller: _reasonCtrl,
                      label: 'Reason for edit',
                      icon: GIcons.edit,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Reason is required' : null,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final r in _quickReasons)
                          ActionChip(
                            label: Text(r, style: const TextStyle(fontSize: 11.5)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() => _reasonCtrl.text = r),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand))
                    : Icon(ask ? GIcons.send : GIcons.check, size: 18),
                label: Text(
                    _submitting
                        ? (ask ? 'Submitting…' : 'Saving…')
                        : (ask ? 'Submit for approval' : 'Save changes'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.brand,
                  foregroundColor: c.onBrand,
                  disabledBackgroundColor: c.brand.withValues(alpha: 0.45),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
    int maxLines = 1,
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
        maxLines: maxLines,
        enabled: enabled,
        readOnly: !enabled,
        cursorColor: c.brand,
        style: TextStyle(color: enabled ? c.textPrimary : c.textMuted, fontSize: 14),
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

// ── Expiry Date Formatter ──────────────────────────────────────────────────────
class ExpiryDateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    String text =
        newValue.text.replaceAll(RegExp(r'\D'), '');
    if (text.length > 8) text = text.substring(0, 8);

    String formatted = '';
    if (text.length >= 2) {
      formatted += text.substring(0, 2);
      if (text.length > 2) formatted += '-';
    } else {
      formatted = text;
    }
    if (text.length >= 4) {
      formatted += text.substring(2, 4);
      if (text.length > 4) formatted += '-';
    } else if (text.length > 2) {
      formatted += text.substring(2);
    }
    if (text.length > 4) {
      formatted += text.substring(4);
    }

    return TextEditingValue(
      text: formatted,
      selection:
          TextSelection.collapsed(offset: formatted.length),
    );
  }

  static String? validate(String? v) {
    if (v == null || v.isEmpty) return 'Enter expiry date';
    if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(v)) {
      return 'Use dd-MM-yyyy format';
    }
    try {
      final p = v.split('-');
      final day = int.parse(p[0]);
      final month = int.parse(p[1]);
      final year = int.parse(p[2]);
      if (month < 1 || month > 12) return 'Invalid month';
      if (day < 1 || day > 31) return 'Invalid day';
      final date = DateTime(year, month, day);
      final now = DateTime.now();
      if (date.isBefore(
          DateTime(now.year, now.month, now.day))) {
        return 'Past date not allowed';
      }
      if (year < 2025) return 'Year too early';
      if (year > 2100) return 'Year too far';
    } catch (_) {
      return 'Invalid date';
    }
    return null;
  }
}

class _StructuredMedicineRowCard extends StatefulWidget {
  final VoidCallback onTap;
  final Color accentColor;
  final Widget child;

  const _StructuredMedicineRowCard({
    required this.onTap,
    required this.accentColor,
    required this.child,
  });

  @override
  State<_StructuredMedicineRowCard> createState() => _StructuredMedicineRowCardState();
}

class _StructuredMedicineRowCardState extends State<_StructuredMedicineRowCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: _hovered ? Color.lerp(c.surface, c.brandSoft, 0.18) : c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hovered ? c.brand.withValues(alpha: 0.45) : c.border,
            width: _hovered ? 1.2 : 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 3.5,
                    color: widget.accentColor.withValues(alpha: _hovered ? 0.95 : 0.72),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
