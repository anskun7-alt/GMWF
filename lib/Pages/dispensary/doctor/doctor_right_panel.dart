// lib/pages/dispensary/doctor/doctor_right_panel.dart (updated)

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:another_flushbar/flushbar.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/services/prescription_template_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';

class DoctorRightPanel extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic>? selectedPatientData;
  final TextEditingController complaintController;
  final TextEditingController diagnosisController;
  final List<Map<String, dynamic>> prescriptions;
  final List<Map<String, dynamic>> labResults;
  final bool isSaving;
  final VoidCallback onAddLabResult;
  final Function(int) onRemoveLabResult;
  final Function(Map<String, dynamic>) onEditMedicine;
  final Function(int) onRemoveMedicine;
  final Future Function()? onSavePrescription;
  final VoidCallback? onEntryCompleted;
  final VoidCallback? onSkipPatient;
  final String serialId;
  final Function(Map<String, dynamic> repeatData)? onRepeatData;

  final String doctorId;
  final String doctorName;
  final bool isPhysiotherapist;

  /// Already-normalised queue type: 'zakat' | 'non-zakat' | 'gmwf'
  final String queueType;

  const DoctorRightPanel({
    super.key,
    required this.branchId,
    required this.selectedPatientData,
    required this.complaintController,
    required this.diagnosisController,
    required this.prescriptions,
    required this.labResults,
    required this.isSaving,
    required this.onAddLabResult,
    required this.onRemoveLabResult,
    required this.onRemoveMedicine,
    required this.onEditMedicine,
    this.onSavePrescription,
    this.onEntryCompleted,
    this.onSkipPatient,
    required this.serialId,
    this.onRepeatData,
    required this.doctorId,
    required this.doctorName,
    required this.queueType,
    required this.isPhysiotherapist,
  });

  @override
  State<DoctorRightPanel> createState() => _DoctorRightPanelState();
}

class _DoctorRightPanelState extends State<DoctorRightPanel> {
  final FocusNode _complaintFocus  = FocusNode();
  final FocusNode _diagnosisFocus  = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _saveButtonFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _allInventory  = [];

  /// Number of days of medicine to dispense (1 = default, 2, 3)
  int _daysOfMedicine = 1;

  // ── FIX: Cross-patient reserved quantities ─────────────────────────────
  // Maps inventoryId → total quantity already prescribed across ALL
  // pending (not-yet-dispensed) patients in Hive.
  // Rebuilt by _buildReservedQuantities() on load and before each add.
    Map<String, int> _reservedQuantities = {};
  Timer? _stockBoxDebounce;

  static const Color _teal     = Color(0xFF00695C);
  static const Color _orange   = Color(0xFFFF6D00);
  static const Color _blueGrey = Color(0xFF455A64);

  // Dose pill colours (teal ramp)
  static const Color _dosePillBg     = Color(0xFFE1F5EE);
  static const Color _dosePillBorder = Color(0xFF5DCAA5);
  static const Color _dosePillText   = Color(0xFF0F6E56);

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  // Base price per day per queue type
  Map<String, int> get _baseDayPrice => {
    'zakat':     20,
    'non-zakat': _isKarachi ? 20 : 100,
    'gmwf':      0,
  };

  final List<String> _quickLabTests = const [
    "CBC", "LFT", "RFT", "HbA1C", "BMP",
    "Urine R/E", "Lipid Profile", "ECG", "X-ray", "Ultrasound Abdomen",
  ];

  final List<String> _quickPhysiotherapies = const [
    "SWD (Shortwave Diathermy)", "Ultrasound Therapy", "TENS Therapy", "Cervical Traction", "Lumbar Traction",
    "Manual Therapy", "Therapeutic Exercises", "Hot Pack / Cold Pack", "Infrared Therapy (IRR)", "Laser Therapy",
  ];

  List<String> get _currentQuickList => widget.isPhysiotherapist ? _quickPhysiotherapies : _quickLabTests;

  final Set<String> _selectedQuickTests = {};

  List<Map<String, dynamic>> _prescriptionTemplates = [];

  late final List<FocusNode> _tabOrder = [
    _complaintFocus,
    _diagnosisFocus,
    _searchFocusNode,
    _saveButtonFocus,
  ];

  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  void Function(void Function())? _activeDialogSetState;

  // ── Derived: extra charge (PKR) ────────────────────────────────────────────
  int get _extraCharge {
    final pricePerDay = _baseDayPrice[widget.queueType] ?? 0;
    if (pricePerDay == 0) return 0;
    return (_daysOfMedicine - 1) * pricePerDay;
  }

  // ── Rule: if any injection is prescribed, only 1 day is allowed ───────────
  bool get _hasInjection => widget.prescriptions.any(_isInjectionOrDrip);

  @override
  void initState() {
    super.initState();
    _loadInventory();
    _loadPrescriptionTemplates();

    final quickList = _currentQuickList;
    for (final lab in widget.labResults) {
      final name = lab['name']?.toString() ?? '';
      if (quickList.contains(name)) _selectedQuickTests.add(name);
    }

    _daysOfMedicine = _resolveDaysOfMedicine();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _complaintFocus.requestFocus();
    });

        _realtimeSub = RealtimeManager().messageStream.listen(_handleRealtimeUpdate);

    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      Hive.box(LocalStorageService.stockBox).listenable().addListener(_debouncedStockBoxReload);
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          box.listenable().addListener(_debouncedStockBoxReload);
        }
      });
    }
  }

  int _resolveDaysOfMedicine() {
    final existing = widget.selectedPatientData?['prescription'];
    if (existing is Map) {
      final d = existing['daysOfMedicine'];
      if (d is int && d >= 1 && d <= 3) return d;
    }
    final topLevel = widget.selectedPatientData?['daysOfMedicine'];
    if (topLevel is int && topLevel >= 1 && topLevel <= 3) return topLevel;

    final suggested = widget.selectedPatientData?['suggestedDays'];
    if (suggested is int && suggested >= 1 && suggested <= 3) return suggested;

    return 1;
  }

  String? _getEffectiveCamp() {
    final patientCamp = widget.selectedPatientData?['dispensaryId'] ??
        widget.selectedPatientData?['campId'] ??
        widget.selectedPatientData?['dispensaryTag'];
    if (patientCamp != null && patientCamp.toString().trim().isNotEmpty) {
      return patientCamp.toString().trim().toLowerCase();
    }
    if (CampSessionService.hasCampsForBranch(widget.branchId)) {
      final available = CampSessionService.getAvailableCampOptions();
      if (available.isNotEmpty) return available.first['id'];
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant DoctorRightPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serialId != widget.serialId ||
        oldWidget.selectedPatientData != widget.selectedPatientData ||
        oldWidget.branchId != widget.branchId) {
      setState(() {
        _daysOfMedicine = _resolveDaysOfMedicine();
      });
      _loadInventory();
    }
  }

  void _handleRealtimeUpdate(Map<String, dynamic> event) {
    final type = event['event_type'] as String?;
    final rawData = event['data'];
    final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
    if (type == null || data.isEmpty) return;

    final msgBranch = (data['branchId'] ?? event['branchId'] ?? '').toString().toLowerCase().trim();
    final myBranch  = widget.branchId.toLowerCase().trim();
    if (msgBranch.isNotEmpty && myBranch.isNotEmpty && msgBranch != myBranch &&
        !msgBranch.contains(myBranch) && !myBranch.contains(msgBranch) &&
        msgBranch != 'all' && msgBranch != 'default') {
      return;
    }

    if (type == RealtimeEvents.saveStockItem || type == 'save_stock_item' || type == 'medicine_registered') {
      final rawDelta = data['_quantityDelta'];
      final medId = (data['id'] ?? data['medicineId'] ?? data['_docId'] ?? data['docId'])?.toString();
      if (rawDelta != null && medId != null && medId.isNotEmpty) {
        final delta = (rawDelta is num) ? rawDelta.toDouble() : double.tryParse(rawDelta.toString()) ?? 0.0;
        final existing = LocalStorageService.getLocalInventoryItem(medId);
        if (existing != null) {
          if (delta != 0) {
            LocalStorageService.updateLocalStockQuantity(medId, delta);
          }
        } else {
          LocalStorageService.saveLocalInventoryItem(data);
        }
      } else {
        LocalStorageService.saveLocalInventoryItem(data);
      }
      _loadInventory();
      return;
    } else if (type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
      final mId = (data['id'] ?? data['medicineId'])?.toString();
      if (mId != null) LocalStorageService.deleteLocalStockItem(mId);
      _loadInventory();
      return;
    } else if (type == 'save_prescription_template' || type == 'delete_prescription_template') {
      _loadPrescriptionTemplates();
      return;
    }

    final serial = data['serial'] as String?;
    if (serial == null || serial != widget.serialId) return;

    if (type == RealtimeEvents.saveEntry) {
      if (mounted) setState(() {});
    }

    // ── FIX: Rebuild reserved quantities when any dispense or prescription
    //         save happens on the LAN, so stock counts stay accurate.
    if (type == 'dispense_completed' || type == RealtimeEvents.savePrescription) {
      _buildReservedQuantities();
    }

    if (type == RealtimeEvents.savePrescription) {
      setState(() {
        widget.complaintController.text = data['complaint'] ?? data['condition'] ?? '';
        widget.diagnosisController.text = data['diagnosis'] ?? '';
        widget.prescriptions
          ..clear()
          ..addAll(
            (data['prescriptions'] as List<dynamic>?)
                    ?.map((e) => Map<String, dynamic>.from(e as Map))
                    .toList() ?? [],
          );
        widget.labResults
          ..clear()
          ..addAll(
            (data['labResults'] as List<dynamic>?)
                    ?.map((e) => Map<String, dynamic>.from(e as Map))
                    .toList() ?? [],
          );
        _selectedQuickTests
          ..clear()
          ..addAll(
            widget.labResults
                .map((l) => l['name']?.toString() ?? '')
                .where(_currentQuickList.contains),
          );
        final d = data['daysOfMedicine'];
        if (d is int && d >= 1 && d <= 3) _daysOfMedicine = d;
      });
      final isReplay = event['_serverPush'] == true ||
          event['_resent'] == true ||
          event['isCatchUp'] == true ||
          event['_isReplay'] == true ||
          data['_serverPush'] == true ||
          data['_resent'] == true ||
          data['isCatchUp'] == true ||
          data['_isReplay'] == true;
      if (!isReplay && mounted) {
        Flushbar(
          message: 'Prescription updated in realtime',
          backgroundColor: Colors.blue.shade700,
          duration: const Duration(seconds: 4),
        ).show(context);
      }
    }
  }

  static bool _isSyringeItem(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().toLowerCase().trim();
    final name = (m['name'] ?? '').toString().toLowerCase().trim();
    return type.contains('syringe') || type == 'syr' || type == 'syr.' || name.contains('syringe');
  }

  Future<void> _loadInventory([String? overrideCamp]) async {
    final effCamp = overrideCamp ?? _getEffectiveCamp() ?? CampSessionService.getActiveCamp(widget.branchId);
    final hasCamps = CampSessionService.hasCampsForBranch(widget.branchId);
    final bool shouldFilterByCamp = hasCamps && effCamp != null && effCamp.isNotEmpty && effCamp != 'all';

    // 1. Get physical local stock items strictly for this branch and camp
    var localItems = LocalStorageService.getAllLocalStockItems(
      branchId: widget.branchId,
      dispensaryId: shouldFilterByCamp ? effCamp : null,
      filterByCamp: shouldFilterByCamp,
    ).where((m) => !_isSyringeItem(m)).toList();

    if (localItems.isEmpty && !hasCamps) {
      localItems = LocalStorageService.getAllLocalStockItems(
        branchId: widget.branchId,
        filterByCamp: false,
      ).where((m) => !_isSyringeItem(m)).toList();
    }

    final List<Map<String, dynamic>> combined = [];

    for (final s in localItems) {
      final item = Map<String, dynamic>.from(s);
      final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
      if (!isCustom) {
        final rawName = (item['name'] ?? '').toString();
        item['name'] = MasterProformaService.cleanBrandToFormula(rawName);
        final rawFormula = (item['formula'] ?? '').toString();
        if (rawFormula.isNotEmpty) {
          item['formula'] = MasterProformaService.cleanBrandToFormula(rawFormula);
        }
      }
      item['quantity'] = item['quantity'] ?? item['stock'] ?? 0;
      combined.add(item);
    }

    // Sort combined alphabetically by name / formula
    combined.sort((a, b) {
      final na = (a['name'] ?? a['formula'] ?? '').toString().toLowerCase();
      final nb = (b['name'] ?? b['formula'] ?? '').toString().toLowerCase();
      return na.compareTo(nb);
    });

    if (mounted) {
      setState(() => _allInventory = combined);
      _activeDialogSetState?.call(() {});
    }
    // Build reserved map after inventory is loaded
    await _buildReservedQuantities();
    _activeDialogSetState?.call(() {});
  }

  // ── FIX: Scan ALL pending prescriptions in Hive and sum up reserved qty ──
  // A prescription is "pending" (reserved) when:
  //   • it exists in the prescriptions box (doctor has saved it), AND
  //   • the corresponding entry in entriesBox does NOT have
  //     dispenseStatus == 'dispensed'.
  // We skip the current patient's serial so their own session counts
  // are handled separately by _getAvailableStock().
  Future<void> _buildReservedQuantities() async {
    final Map<String, int> reserved = {};

    try {
      final prescBox   = await LocalStorageService.ensureBoxOpen(LocalStorageService.prescriptionsBox);
      final entriesBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final mySerial   = widget.serialId.trim().toLowerCase();
      // PERF FIX: prescriptionsBox accumulates every prescription ever
      // written locally. Scanning the whole box on every dialog-open and
      // every save is what caused the doctor-panel freeze — only TODAY's
      // prescriptions can possibly still be "reserved" (unreleased) stock,
      // so skip everything else using the cheap date prefix on the serial
      // before doing any Map/lookup work.
      final todayKey = CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey;

      for (final key in prescBox.keys) {
        final raw = prescBox.get(key);
        if (raw is! Map) continue;

        final prescSerialRaw = (raw['serial'] ?? raw['id'] ?? '').toString();
        final effectiveDatePrefix = CampSessionService.getDateKeyFromSerial(prescSerialRaw);
        if (effectiveDatePrefix.isNotEmpty && effectiveDatePrefix != todayKey) {
          continue;
        }

        final presc = Map<String, dynamic>.from(raw);

        // Skip the current patient — their session is handled in _getAvailableStock
        final prescSerial = prescSerialRaw.trim().toLowerCase();
        if (prescSerial == mySerial) continue;

        // Check if already dispensed — look up in entriesBox
        final entryKey = '${widget.branchId}-$prescSerial';
        final entry    = entriesBox.get(entryKey);
        if (entry is Map) {
          final dispenseStatus =
              (entry['dispenseStatus'] ?? '').toString().toLowerCase();
          if (dispenseStatus == 'dispensed') continue;
        }

        // Also check dispenseStatus on the prescription itself
        final dispenseStatusOnPresc =
            (presc['dispenseStatus'] ?? '').toString().toLowerCase();
        if (dispenseStatusOnPresc == 'dispensed') continue;

        // Sum up quantities for each inventory medicine
        final meds = presc['prescriptions'];
        if (meds is! List) continue;

        for (final med in meds) {
          if (med is! Map) continue;
          final inventoryId = (med['inventoryId'] ?? '').toString().trim();
          if (inventoryId.isEmpty) continue;

          final medQty = med['quantity'];
          final qty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
          final days = (presc['daysOfMedicine'] as int?) ?? 1;
          final type = (med['type'] ?? '').toString().toLowerCase();
          final isInj = type.contains('injection') || type.contains('inj') ||
              type.contains('drip') || type.contains('syringe') ||
              type.contains('nebulization');
          final effectiveQty = isInj ? qty : qty * days;

          reserved[inventoryId] = (reserved[inventoryId] ?? 0) + effectiveQty;
        }
      }
    } catch (e) {
      debugPrint('[DoctorPanel] _buildReservedQuantities error: $e');
    }

    if (mounted) {
      setState(() => _reservedQuantities = reserved);
      _activeDialogSetState?.call(() {});
    }
  }

    void _debouncedStockBoxReload() {
    _stockBoxDebounce?.cancel();
    _stockBoxDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _loadInventory();
    });
  }

  @override
  void dispose() {
    _activeDialogSetState = null;
    _stockBoxDebounce?.cancel();
    try {
      if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
        Hive.box(LocalStorageService.stockBox).listenable().removeListener(_debouncedStockBoxReload);
      }
    } catch (_) {}
    _realtimeSub?.cancel();
    _searchFocusNode.dispose();
    _complaintFocus.dispose();
    _diagnosisFocus.dispose();
    _saveButtonFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _getFormattedMedicine(Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString().trim();
    final dose = m['dose'] != null && m['dose'].toString().isNotEmpty ? ' ${m['dose']}' : '';
    return '$name$dose'.trim();
  }

  String _getMedAbbrev(Map<String, dynamic> med) {
    final rawName = (med['name'] ?? '').toString().trim().toLowerCase();
    final rawType = (med['type'] ?? '').toString().trim().toLowerCase();
    final prefixes = {
      'syrup': 'syp.', 'syp': 'syp.',
      'capsule': 'cap.', 'cap': 'cap.',
      'tablet': 'tab.', 'tab': 'tab.',
      'injection': 'inj.', 'inj': 'inj.',
      'drip': 'drip.',
      'syringe': 'syr.', 'syr': 'syr.',
    };
    String? abbrev;
    for (final entry in prefixes.entries) {
      if (rawType.contains(entry.key) || rawName.contains(entry.key)) {
        abbrev = entry.value; break;
      }
    }
    if (abbrev == null) return '';
    if (rawName.startsWith(abbrev.toLowerCase())) return '';
    return abbrev;
  }

  static String _getMedicineType(Map<String, dynamic> med) {
    final rawType = (med['type'] ?? med['dosageForm'] ?? med['form'] ?? med['category'] ?? '').toString().trim();
    if (rawType.isNotEmpty && rawType.toLowerCase() != 'null') return rawType;
    final rawName = (med['name'] ?? '').toString().trim().toLowerCase();
    if (rawName.contains('cap')) return 'Capsule';
    if (rawName.contains('tab')) return 'Tablet';
    if (rawName.contains('syp') || rawName.contains('syrup')) return 'Syrup';
    if (rawName.contains('susp')) return 'Suspension';
    if (rawName.contains('inj')) return 'Injection';
    if (rawName.contains('infusion') || rawName.contains('drip')) return 'Infusion';
    if (rawName.contains('drop')) return 'Drops';
    return 'Medicine';
  }

  static ({Color bg, Color border, Color text}) _getTypeBadgeColors(String type, bool isOutOfStock) {
    if (isOutOfStock) {
      return (bg: const Color(0xFFF3F4F6), border: const Color(0xFFD1D5DB), text: const Color(0xFF6B7280));
    }
    final t = type.toLowerCase();
    if (t.contains('tab')) {
      return (bg: const Color(0xFFEFF6FF), border: const Color(0xFF93C5FD), text: const Color(0xFF1D4ED8)); // Blue
    } else if (t.contains('cap')) {
      return (bg: const Color(0xFFF5F3FF), border: const Color(0xFFC4B5FD), text: const Color(0xFF6D28D9)); // Purple
    } else if (t.contains('inj')) {
      return (bg: const Color(0xFFFFF1F2), border: const Color(0xFFFDA4AF), text: const Color(0xFFBE123C)); // Rose/Red
    } else if (t.contains('inf') || t.contains('drip')) {
      return (bg: const Color(0xFFECFEFF), border: const Color(0xFF67E8F9), text: const Color(0xFF0E7490)); // Cyan
    } else if (t.contains('syp') || t.contains('syrup') || t.contains('susp')) {
      return (bg: const Color(0xFFFFFBEB), border: const Color(0xFFFDE68A), text: const Color(0xFFB45309)); // Amber
    } else if (t.contains('drop')) {
      return (bg: const Color(0xFFECFDF5), border: const Color(0xFF6EE7B7), text: const Color(0xFF047857)); // Emerald
    }
    return (bg: const Color(0xFFF8FAFC), border: const Color(0xFFCBD5E1), text: const Color(0xFF475569)); // Slate
  }

  IconData _getMedicineIcon(Map<String, dynamic> med) {
    final t = (med['type'] ?? med['dosageForm'] ?? med['form'] ?? '').toString().trim().toLowerCase();
    final n = (med['name'] ?? '').toString().trim().toLowerCase();
    if (t.contains('tab') || n.contains('tab')) return FontAwesomeIcons.tablets;
    if (t.contains('cap') || n.contains('cap')) return FontAwesomeIcons.capsules;
    if (t.contains('syp') || t.contains('syrup') || t.contains('susp') || n.contains('syp') || n.contains('syrup')) return FontAwesomeIcons.bottleDroplet;
    if (t.contains('inj') || t.contains('injection') || n.contains('inj')) return FontAwesomeIcons.syringe;
    if (t.contains('inf') || t.contains('infusion') || t.contains('drip') || n.contains('infusion') || n.contains('drip')) return FontAwesomeIcons.flask;
    if (t.contains('drop') || n.contains('drop')) return FontAwesomeIcons.eyeDropper;
    if (t.contains('cream') || t.contains('oint') || n.contains('ointment')) return FontAwesomeIcons.handHoldingMedical;
    return FontAwesomeIcons.pills;
  }

  bool _isInjectionOrDrip(Map<String, dynamic> med) {
    final t = (med['type'] ?? '').toString().trim().toLowerCase();
    final n = (med['name'] ?? '').toString().trim().toLowerCase();
    return t.contains('injection') || t.contains('inj') ||
        t.contains('infusion') || t.contains('inf') ||
        t.contains('drip') || t.contains('syringe') || t.contains('nebulization') ||
        n.contains('inj') || n.contains('infusion') || n.contains('drip');
  }

  bool _medicineExists(String name, {String? inventoryId}) {
    final lower = name.trim().toLowerCase();
    return widget.prescriptions.any((m) =>
        (m['name'] ?? '').toString().trim().toLowerCase() == lower &&
        (inventoryId == null || m['inventoryId'] == inventoryId));
  }

  // ── FIX: Available stock = total stock − reserved by other patients
  //         − already added in this session
  int _getAvailableStock(Map<String, dynamic>? inventoryMed) {
    if (inventoryMed == null) return 999999;

    final invQty = inventoryMed['quantity'];
    final totalStock = (invQty is num ? invQty.toInt() : int.tryParse(invQty?.toString() ?? '') ?? 0);
    final inventoryId = inventoryMed['id']?.toString() ?? '';

    // Quantity reserved by OTHER pending patients (from Hive scan)
    final reservedByOthers = _reservedQuantities[inventoryId] ?? 0;

    // Quantity already added in THIS doctor session for this patient
    int sessionQty = 0;
    for (final med in widget.prescriptions) {
      if (med['inventoryId']?.toString() == inventoryId) {
        final medQty = med['quantity'];
        sessionQty += (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
      }
    }

    final available = totalStock - reservedByOthers - sessionQty;
    return available < 0 ? 0 : available;
  }

  Future<void> _showMedicineSelectionDialog() async {
    final availableCampOptions = CampSessionService.getAvailableCampOptions();
    final userAssigned = CampSessionService.getAssignedCampsFromHive();
    final bool hasMultipleCamps = CampSessionService.hasCampsForBranch(widget.branchId) &&
        (availableCampOptions.length > 1 && userAssigned.length != 1);
    String dialogCamp = _getEffectiveCamp() ?? (availableCampOptions.isNotEmpty ? availableCampOptions.first['id']! : 'haji_camp');

    await _loadInventory(dialogCamp);
    if (!mounted) return;

    final queryCtrl = TextEditingController();
    String selectedCategory = 'All';

    final quickSearchKeywords = [
      'Panadol',
      'Amoxil',
      'Flagyl',
      'Augmentin',
      'Brufen',
      'Ponstan',
      'Piriton',
      'Disprin',
      'Risek',
      'Avil',
      'No-Spa',
      'Gravinate',
      'Cefspan',
      'Ceftriaxone',
      'Mucaine',
      'Surbex',
    ];

    try {
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (dialogCtx) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              _activeDialogSetState = setDialogState;
            final query = queryCtrl.text.trim().toLowerCase();

            // Compute category counts across all inventory
            int countAll = 0, countTab = 0, countCap = 0, countSyp = 0, countInj = 0, countDrop = 0, countOther = 0;
            int inStockCount = 0;

            for (final m in _allInventory) {
              if (_isSyringeItem(m)) continue;
              final type = (m['type'] ?? m['dosageForm'] ?? m['form'] ?? '').toString().toLowerCase();
              final name = (m['name'] ?? '').toString().toLowerCase();
              final avail = _getAvailableStock(m);
              if (avail > 0) inStockCount++;
              countAll++;

              if (type.contains('tab') || name.contains('tab')) {
                countTab++;
              } else if (type.contains('cap') || name.contains('cap')) {
                countCap++;
              } else if (type.contains('syp') || type.contains('syrup') || type.contains('susp') || name.contains('syp') || name.contains('syrup')) {
                countSyp++;
              } else if (_isInjectionOrDrip(m)) {
                countInj++;
              } else if (type.contains('drop') || name.contains('drop')) {
                countDrop++;
              } else {
                countOther++;
              }
            }

            final filteredMeds = _allInventory.where((m) {
              if (_isSyringeItem(m)) return false;
              final name = (m['name'] ?? '').toString().toLowerCase();
              final type = (m['type'] ?? m['dosageForm'] ?? m['form'] ?? '').toString().toLowerCase();
              final dose = (m['dose'] ?? '').toString().toLowerCase();
              final formula = (m['formula'] ?? '').toString().toLowerCase();

              if (selectedCategory != 'All') {
                final cat = selectedCategory.toLowerCase();
                if (cat == 'tablets' && !type.contains('tab') && !name.contains('tab')) return false;
                if (cat == 'capsules' && !type.contains('cap') && !name.contains('cap')) return false;
                if (cat == 'syrups' && !type.contains('syp') && !type.contains('syrup') && !type.contains('susp') && !name.contains('syp') && !name.contains('syrup')) return false;
                if (cat == 'injectables' && !_isInjectionOrDrip(m)) return false;
                if (cat == 'drops' && !type.contains('drop') && !name.contains('drop')) return false;
                if (cat == 'others') {
                  final isKnown = type.contains('tab') || name.contains('tab') ||
                      type.contains('cap') || name.contains('cap') ||
                      type.contains('syp') || type.contains('syrup') || type.contains('susp') || name.contains('syp') || name.contains('syrup') ||
                      _isInjectionOrDrip(m) ||
                      type.contains('drop') || name.contains('drop');
                  if (isKnown) return false;
                }
              }

              if (query.isEmpty) return true;
              return name.contains(query) ||
                  type.contains(query) ||
                  dose.contains(query) ||
                  formula.contains(query);
            }).toList();

            final mediaQuery = MediaQuery.of(context);
            final isCompact = mediaQuery.size.width < 650;

            final categoryTabs = [
              {'id': 'All', 'label': 'All', 'icon': Icons.medical_services_outlined, 'count': countAll},
              {'id': 'Tablets', 'label': 'Tablets', 'icon': Icons.medication_rounded, 'count': countTab},
              {'id': 'Capsules', 'label': 'Capsules', 'icon': Icons.medication_liquid_rounded, 'count': countCap},
              {'id': 'Syrups', 'label': 'Syrups', 'icon': Icons.science_rounded, 'count': countSyp},
              {'id': 'Injectables', 'label': 'Injectables & Drips', 'icon': Icons.vaccines_rounded, 'count': countInj},
              {'id': 'Drops', 'label': 'Drops', 'icon': Icons.water_drop_rounded, 'count': countDrop},
              {'id': 'Others', 'label': 'Others & Topicals', 'icon': Icons.healing_rounded, 'count': countOther},
            ];

            final isDark = _isDark;
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: EdgeInsets.symmetric(
                horizontal: isCompact ? 10 : 24,
                vertical: isCompact ? 12 : 20,
              ),
              child: Container(
                width: 860,
                constraints: BoxConstraints(
                  maxHeight: mediaQuery.size.height * 0.88,
                ),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.transparent),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Header ──────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [_teal, Color(0xFF004D40)],
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(24),
                          topRight: Radius.circular(24),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const FaIcon(FontAwesomeIcons.pills, color: Colors.white, size: 18),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        'Select Prescription Medicine',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.2,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (hasMultipleCamps) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.25),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 0.8),
                                        ),
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            value: dialogCamp,
                                            dropdownColor: const Color(0xFF004D40),
                                            icon: const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 16),
                                            isDense: true,
                                            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                                            items: availableCampOptions.map((opt) {
                                              return DropdownMenuItem<String>(
                                                value: opt['id'],
                                                child: Text('📍 ${opt['label']}'),
                                              );
                                            }).toList(),
                                            onChanged: (newCamp) async {
                                              if (newCamp != null && newCamp != dialogCamp) {
                                                dialogCamp = newCamp;
                                                await _loadInventory(newCamp);
                                                setDialogState(() {});
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.22),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '$countAll Stock Items',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.35),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 0.6),
                                      ),
                                      child: Text(
                                        '$inStockCount In-Stock',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    if (!hasMultipleCamps && CampSessionService.hasCampsForBranch(widget.branchId)) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.22),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          CampSessionService.getCampLabel(dialogCamp),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const FaIcon(FontAwesomeIcons.arrowsRotate, color: Colors.white70, size: 15),
                            tooltip: 'Refresh & Sync Inventory',
                            onPressed: () async {
                              await LocalStorageService.downloadInventory(widget.branchId);
                              await _loadInventory(dialogCamp);
                              setDialogState(() {});
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            tooltip: 'Close (Esc)',
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                    ),

                    // ── Search & Filter Controls ──────────────────────
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                        border: Border(bottom: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade200)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Search Box
                          TextField(
                            controller: queryCtrl,
                            autofocus: true,
                            onChanged: (_) => setDialogState(() {}),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black87),
                            decoration: InputDecoration(
                              hintText: 'Search by generic formula, name, dosage, form...',
                              hintStyle: TextStyle(fontSize: 13.5, color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.search, color: _teal, size: 22),
                              suffixIcon: queryCtrl.text.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(Icons.clear, size: 18, color: isDark ? Colors.white70 : Colors.grey),
                                      onPressed: () {
                                        queryCtrl.clear();
                                        setDialogState(() {});
                                      },
                                    )
                                  : null,
                              filled: true,
                              fillColor: isDark ? const Color(0xFF0F172A) : Colors.white,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: _teal, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          // Quick Search Keywords
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                Text(
                                  'Quick: ',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                                  ),
                                ),
                                ...quickSearchKeywords.map((kw) {
                                  final isActive = queryCtrl.text.toLowerCase() == kw.toLowerCase();
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 5),
                                    child: InkWell(
                                      onTap: () {
                                        setDialogState(() {
                                          if (isActive) {
                                            queryCtrl.clear();
                                          } else {
                                            queryCtrl.text = kw;
                                          }
                                        });
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: isActive ? _teal.withValues(alpha: 0.25) : (isDark ? const Color(0xFF0F172A) : Colors.white),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: isActive ? _teal : (isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                                            width: isActive ? 1.2 : 0.8,
                                          ),
                                        ),
                                        child: Text(
                                          kw,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                                            color: isActive ? _teal : (isDark ? const Color(0xFFCBD5E1) : Colors.grey.shade800),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),

                          // Category Filter Chips
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: categoryTabs.map((cat) {
                                final id = cat['id'] as String;
                                final label = cat['label'] as String;
                                final icon = cat['icon'] as IconData;
                                final count = cat['count'] as int;
                                final isSelected = selectedCategory == id;

                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: FilterChip(
                                    showCheckmark: false,
                                    avatar: Icon(
                                      icon,
                                      size: 14,
                                      color: isSelected ? Colors.white : (isDark ? const Color(0xFF2DD4BF) : _teal),
                                    ),
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(label),
                                        const SizedBox(width: 5),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.25)
                                                : (isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '$count',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: isSelected ? Colors.white : (isDark ? Colors.white : Colors.grey.shade800),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    selected: isSelected,
                                    selectedColor: _teal,
                                    backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
                                    labelStyle: TextStyle(
                                      color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : Colors.grey.shade800),
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                        color: isSelected ? _teal : (isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                                        width: isSelected ? 1.5 : 0.8,
                                      ),
                                    ),
                                    onSelected: (selected) {
                                      if (selected) {
                                        setDialogState(() => selectedCategory = id);
                                      }
                                    },
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── Medicine Results List ─────────────────────────
                    Flexible(
                      child: filteredMeds.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(36),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search_off_rounded, size: 54, color: Colors.grey.shade300),
                                    const SizedBox(height: 14),
                                    Text(
                                      queryCtrl.text.isNotEmpty
                                          ? 'No formulary medicines found matching "${queryCtrl.text}"'
                                          : 'No medicines in this category',
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade700,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(dialogCtx);
                                        _addMedicineDialog();
                                      },
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('Add as Custom Medicine'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _teal,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                              itemCount: filteredMeds.length,
                              separatorBuilder: (_, index) => Divider(
                                height: 1,
                                thickness: 0.8,
                                color: Colors.grey.shade200,
                                indent: 14,
                                endIndent: 14,
                              ),
                              itemBuilder: (_, i) {
                                final m = filteredMeds[i];
                                final availableStock = _getAvailableStock(m);
                                final isOutOfStock = availableStock <= 0;
                                final isLowStock = availableStock > 0 && availableStock <= 10;
                                final formula = (m['formula'] ?? '').toString().trim();
                                final dose = (m['dose'] ?? '').toString().trim();
                                final medicineName = (m['name'] ?? '').toString().trim();
                                final medType = _getMedicineType(m);
                                final typeColors = _getTypeBadgeColors(medType, false);
                                final reservedCount = _reservedQuantities[m['id']?.toString() ?? ''] ?? 0;

                                final itemBg = isOutOfStock
                                    ? (isDark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2))
                                    : (isLowStock ? (isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB)) : (isDark ? const Color(0xFF1E293B) : Colors.white));
                                final itemBorder = isOutOfStock
                                    ? (isDark ? const Color(0xFFEF4444) : const Color(0xFFFECACA))
                                    : (isLowStock ? (isDark ? const Color(0xFFF97316) : const Color(0xFFFDE68A)) : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)));

                                return InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    Navigator.pop(dialogCtx);
                                    _addMedicineDialog(inventoryMed: m);
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: itemBg,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(color: itemBorder, width: isOutOfStock || isLowStock ? 1.2 : 0.8),
                                    ),
                                    child: Row(
                                      children: [
                                        // Medicine Info with unified single-bubble Icon+Type before name
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Row(
                                                children: [
                                                  // Unified Icon + Type Single Bubble (Enlarged & Positioned First)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                                                    decoration: BoxDecoration(
                                                      color: isOutOfStock ? Colors.grey.shade100 : typeColors.bg,
                                                      border: Border.all(
                                                        color: isOutOfStock ? Colors.grey.shade300 : typeColors.border,
                                                        width: 0.9,
                                                      ),
                                                      borderRadius: BorderRadius.circular(20),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        FaIcon(
                                                          _getMedicineIcon(m),
                                                          color: isOutOfStock ? Colors.grey.shade600 : typeColors.text,
                                                          size: 13,
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Text(
                                                          medType,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            fontWeight: FontWeight.bold,
                                                            color: isOutOfStock ? Colors.grey.shade600 : typeColors.text,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),

                                                  // Medicine Name
                                                  Flexible(
                                                    child: Text(
                                                      medicineName,
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight: FontWeight.bold,
                                                        color: isOutOfStock
                                                            ? (isDark ? const Color(0xFFFCA5A5) : Colors.red.shade900)
                                                            : (isDark ? Colors.white : const Color(0xFF0F172A)),
                                                      ),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),

                                                  if (dose.isNotEmpty) ...[
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: _dosePillBg,
                                                        border: Border.all(
                                                          color: _dosePillBorder,
                                                          width: 0.8,
                                                        ),
                                                        borderRadius: BorderRadius.circular(20),
                                                      ),
                                                      child: Text(
                                                        dose,
                                                        style: const TextStyle(
                                                          fontSize: 11.5,
                                                          fontWeight: FontWeight.w600,
                                                          color: _dosePillText,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              if (formula.isNotEmpty && formula.toLowerCase() != medicineName.toLowerCase()) ...[
                                                const SizedBox(height: 4),
                                                Row(
                                                  children: [
                                                    Icon(Icons.biotech_rounded, size: 13, color: Colors.teal.shade700),
                                                    const SizedBox(width: 4),
                                                    Expanded(
                                                      child: Text(
                                                        formula,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          color: Colors.grey.shade600,
                                                          fontStyle: FontStyle.italic,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 10),

                                        // Stock Badges & Prescribe Button
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            if (isOutOfStock) ...[
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFEE2E2),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: Colors.red.shade300, width: 0.8),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.cancel_outlined, size: 12, color: Colors.red.shade700),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      'Avail: 0',
                                                      style: TextStyle(
                                                        color: Colors.red.shade800,
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ] else if (isLowStock) ...[
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: Colors.orange.shade50,
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: Colors.orange.shade300, width: 0.8),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange.shade800),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      'Avail: $availableStock',
                                                      style: TextStyle(
                                                        color: Colors.orange.shade900,
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ] else ...[
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: Colors.green.shade50,
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: Colors.green.shade300, width: 0.8),
                                                ),
                                                child: Text(
                                                  'Avail: $availableStock',
                                                  style: TextStyle(
                                                    color: Colors.green.shade800,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ),
                                            ],
                                            if (reservedCount > 0)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 2),
                                                child: Text(
                                                  '$reservedCount reserved',
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    color: Colors.orange.shade700,
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(width: 10),

                                        // Action Button
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isOutOfStock ? Colors.red.shade600 : _teal,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.add, color: Colors.white, size: 14),
                                              SizedBox(width: 4),
                                              Text(
                                                'Select',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),

                    // ── Footer ────────────────────────────────────────
                    Divider(height: 1, thickness: 1, color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade100,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(24),
                          bottomRight: Radius.circular(24),
                        ),
                      ),
                      child: Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(dialogCtx);
                              _addMedicineDialog();
                            },
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add Custom Medicine'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isDark ? const Color(0xFF2DD4BF) : _teal,
                              side: BorderSide(color: isDark ? const Color(0xFF2DD4BF) : _teal),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'Click any medicine to configure dosage • Esc to close',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  } finally {
    _activeDialogSetState = null;
  }
  }

  Future<void> _addMedicineDialog({Map<String, dynamic>? inventoryMed}) async {
    // ── FIX: Refresh reserved quantities right before showing the dialog
    //         so we have the freshest picture of stock even if another
    //         patient was just saved while this doctor was typing.
    await _buildReservedQuantities();

    final isInventory = inventoryMed != null;

    if (isInventory) {
      final availableStock = _getAvailableStock(inventoryMed);
      final rawStock = (inventoryMed['quantity'] as num?)?.toDouble() ?? 0;
      if (rawStock > 0 && availableStock <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(availableStock == 0
                ? '⚠️ Out of Stock on shelf! (Reserved by pending patients)'
                : '⚠️ Stock Limit: $availableStock available'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 2),
          ));
        }
      }
    }

    final nameCtrl   = TextEditingController(text: isInventory ? inventoryMed['name'] : '');
    final timingCtrl = TextEditingController();
    final qtyCtrl    = TextEditingController(text: '1');
    String mealTiming = 'After Meal';
    String dosage     = '1 spoon';
    bool isSyrup      = false;
    bool isInjection  = false;

    final formula = isInventory
        ? (inventoryMed['formula'] ?? '').toString().trim()
        : '';

    void updateFields() {
      if (isInventory) {
        final type  = (inventoryMed['type'] ?? '').toString().toLowerCase();
        final name  = (inventoryMed['name'] ?? '').toString().toLowerCase();
        isInjection = type.contains('injection') || type.contains('inj') ||
                      type.contains('infusion') || type.contains('inf') ||
                      type.contains('drip') ||
                      name.contains('inj') || name.contains('infusion') || name.contains('drip');
        isSyrup     = type.contains('syrup') || type.contains('syp') || name.contains('syp') || name.contains('syrup');
      } else {
        final text  = nameCtrl.text.toLowerCase();
        isInjection = text.contains('inj.') || text.contains('inj') ||
                      text.contains('inf.') || text.contains('infusion') ||
                      text.contains('drip');
        isSyrup     = text.contains('syp.') || text.contains('syrup');
      }
    }

    updateFields();
    if (!isInventory) nameCtrl.addListener(() => setState(() => updateFields()));

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isInventory ? 'Add Inventory Medicine' : 'Add Custom Medicine',
          style: const TextStyle(fontSize: 16),
        ),
        content: StatefulBuilder(
          builder: (context, setStateDialog) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  readOnly: isInventory,
                  decoration: InputDecoration(
                    labelText: 'Formula',
                    border: const OutlineInputBorder(),
                    filled: isInventory,
                    fillColor: isInventory ? Colors.grey[200] : null,
                    isDense: true,
                  ),
                  onChanged: isInventory ? null : (v) => setStateDialog(() => updateFields()),
                ),
                if (isInventory) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.inventory_2, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      'Available: ${_getAvailableStock(inventoryMed)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: _getAvailableStock(inventoryMed) < 10 ? Colors.red : Colors.grey[700],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // ── FIX: Show how many are reserved by other patients
                    if ((_reservedQuantities[inventoryMed['id']?.toString() ?? ''] ?? 0) > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '(${_reservedQuantities[inventoryMed['id']?.toString() ?? '']} reserved)',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade700,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ]),
                  if (formula.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.biotech_rounded, size: 15, color: Color(0xFF00695C)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            formula,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF00695C),
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                if (!isInjection) ...[
                  const Text('Timing (M+E+N):', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: timingCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    decoration: const InputDecoration(
                      hintText: 'e.g. 1+1+1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) {
                      final digits    = v.replaceAll('+', '');
                      if (digits.length > 3) return;
                      final formatted = digits.split('').join('+');
                      if (timingCtrl.text != formatted) {
                        timingCtrl.text      = formatted;
                        timingCtrl.selection = TextSelection.collapsed(offset: formatted.length);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: mealTiming,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Timing Instruction',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: ['Empty Stomach', 'Before Meal', 'During Meal', 'After Meal', 'Before Sleep']
                        .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (v) => setStateDialog(() => mealTiming = v!),
                  ),
                  if (isSyrup) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: dosage,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Dosage', border: OutlineInputBorder(), isDense: true,
                      ),
                      items: ['1 spoon', '1/2 spoon', '1/3 spoon', '1/4 spoon']
                          .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 13))))
                          .toList(),
                      onChanged: (v) => setStateDialog(() => dosage = v!),
                    ),
                  ],
                ] else
                  TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Quantity', border: OutlineInputBorder(), isDense: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: _teal)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Enter medicine name'), backgroundColor: Colors.redAccent));
                return;
              }
              if (_medicineExists(name, inventoryId: inventoryMed?['id'])) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Medicine already added'), backgroundColor: Colors.orange));
                return;
              }

              Map<String, dynamic> newMed;
              if (isInjection) {
                final qty = int.tryParse(qtyCtrl.text) ?? 1;
                if (qty <= 0) return;
                if (isInventory) {
                  final rawStock = (inventoryMed['quantity'] as num?)?.toDouble() ?? 0;
                  if (rawStock > 0) {
                    final availableStock = _getAvailableStock(inventoryMed);
                    if (qty > availableStock) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('⚠️ Stock Limit Exceeded! Available: $availableStock'),
                          backgroundColor: Colors.red));
                      return;
                    }
                  }
                }
                final medType = isInventory
                    ? (inventoryMed['type'] ?? 'Injection')
                    : (name.toLowerCase().contains('inf') || name.toLowerCase().contains('drip') ? 'Infusion' : 'Injection');
                newMed = {'name': name, 'quantity': qty, 'type': medType, 'inventoryId': inventoryMed?['id']};
              } else {
                final digits = timingCtrl.text.replaceAll('+', '');
                final m      = int.tryParse(digits.isNotEmpty ? digits[0] : '0') ?? 0;
                final e      = digits.length > 1 ? int.tryParse(digits[1]) ?? 0 : 0;
                final n      = digits.length > 2 ? int.tryParse(digits[2]) ?? 0 : 0;
                final sum    = m + e + n;
                final qty    = (mealTiming == 'Before Sleep' && sum == 0) ? 1 : sum;
                if (qty == 0) return;
                if (isInventory) {
                  final rawStock = (inventoryMed['quantity'] as num?)?.toDouble() ?? 0;
                  if (rawStock > 0) {
                    final availableStock = _getAvailableStock(inventoryMed);
                    final totalRequired = qty * _daysOfMedicine;
                    if (totalRequired > availableStock) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('⚠️ Stock Limit Exceeded! Need $totalRequired but only $availableStock available.'),
                          backgroundColor: Colors.red));
                      return;
                    }
                  }
                }
                newMed = {
                  'name': name, 'quantity': qty,
                  'timing': '$m+$e+$n', 'meal': mealTiming,
                  'dosage': isSyrup ? dosage : '',
                  'type': isSyrup ? 'Syrup' : 'Tablet',
                  'inventoryId': inventoryMed?['id'],
                };
              }

              bool wasReset = false;
              setState(() {
                widget.prescriptions.add(newMed);
                // ── Rule: injection prescribed → force 1 day ───────────────
                if (_isInjectionOrDrip(newMed) && _daysOfMedicine > 1) {
                  _daysOfMedicine = 1;
                  wasReset = true;
                }
              });
              Navigator.pop(ctx);
              
              if (wasReset) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                      content: Text('Added $name. 💉 Duration reset to 1 day due to injection.'),
                      backgroundColor: Colors.orange.shade800,
                      duration: const Duration(seconds: 4)));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added $name'), backgroundColor: Colors.green));
              }
            },
            child: const Text('Add', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _addCustomLabTest() async {
    final ctrl = TextEditingController();
    final titleText = widget.isPhysiotherapist ? 'Add Custom Physiotherapy' : 'Add Custom Lab Test';
    final hintText = widget.isPhysiotherapist ? 'Therapy name' : 'Test name';
    final errorText = widget.isPhysiotherapist ? 'Invalid or duplicate therapy' : 'Invalid or duplicate test';
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(titleText, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl, autofocus: true,
          decoration: InputDecoration(hintText: hintText, border: const OutlineInputBorder(), isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: _teal)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty || widget.labResults.any((l) => (l['name'] ?? '').toString().trim() == name)) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(errorText), backgroundColor: Colors.redAccent));
                return;
              }
              setState(() => widget.labResults.add({'name': name}));
              Navigator.pop(context);
            },
            child: const Text('Add', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon, {Widget? action, bool compact = false}) =>
      Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              FaIcon(icon, color: _teal, size: compact ? 16 : 20),
              SizedBox(width: compact ? 6 : 10),
              Text(title, style: TextStyle(
                  fontSize: compact ? 14 : 18, fontWeight: FontWeight.bold, color: _teal)),
            ]),
            if (action != null) action,
          ],
        ),
      );

  Widget _buildMedicineSection(
    String title, IconData icon,
    List<Map<String, dynamic>> meds,
    Color chipColor, {bool compact = false}) {
    if (meds.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(title, icon, compact: compact),
        Wrap(
          spacing: 6, runSpacing: 6,
          children: meds.map((m) {
            final abbrev   = _getMedAbbrev(m);
            final namePart = _getFormattedMedicine(m);
            final label = abbrev.isNotEmpty &&
                    !namePart.toLowerCase().startsWith(abbrev.toLowerCase())
                ? '$abbrev $namePart ×${m['quantity']}'
                : '$namePart ×${m['quantity']}';
            return Chip(
              label: Text(label,
                  style: TextStyle(fontSize: compact ? 11 : 13, color: Colors.white)),
              backgroundColor: chipColor,
              padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10),
              onDeleted: () => setState(() => widget.prescriptions.remove(m)),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  // ── Prescription Templates Management ─────────────────────────────────────
  Future<void> _loadPrescriptionTemplates() async {
    try {
      final tpls = await PrescriptionTemplateService.loadTemplates(widget.branchId, doctorId: widget.doctorId);
      if (mounted) {
        setState(() {
          _prescriptionTemplates = tpls;
        });
      }
    } catch (e) {
      debugPrint('[DoctorRightPanel] _loadPrescriptionTemplates error: $e');
    }
  }

  Map<String, dynamic>? _findMatchingInventoryItem(String searchName) {
    if (_allInventory.isEmpty) return null;
    final clean = searchName.trim().toLowerCase();
    if (clean.isEmpty) return null;

    // 1. Exact Name or Formula match
    for (final inv in _allInventory) {
      final invName = (inv['name'] ?? '').toString().trim().toLowerCase();
      final invFormula = (inv['formula'] ?? '').toString().trim().toLowerCase();
      if (invName == clean || (invFormula.isNotEmpty && invFormula == clean)) {
        return inv;
      }
    }

    // 2. Contains match
    for (final inv in _allInventory) {
      final invName = (inv['name'] ?? '').toString().trim().toLowerCase();
      final invFormula = (inv['formula'] ?? '').toString().trim().toLowerCase();
      if (invName.contains(clean) || clean.contains(invName) ||
          (invFormula.isNotEmpty && (invFormula.contains(clean) || clean.contains(invFormula)))) {
        return inv;
      }
    }

    return null;
  }

  Future<void> _applyPrescriptionTemplate(Map<String, dynamic> template) async {
    await _loadInventory();
    await _buildReservedQuantities();

    final meds = (template['medicines'] as List<dynamic>?) ?? [];
    final List<Map<String, dynamic>> resolvedMeds = [];
    final List<Map<String, dynamic>> outOfStockMeds = [];
    final List<Map<String, dynamic>> lowStockMeds = [];

    for (final raw in meds) {
      final tplMed = Map<String, dynamic>.from(raw as Map);
      final rawName = tplMed['name']?.toString() ?? '';
      final invMatch = _findMatchingInventoryItem(rawName);

      int availableStock = 999;
      String? inventoryId;
      String medName = rawName;
      String medType = tplMed['type'] ?? 'Tablet';

      if (invMatch != null) {
        inventoryId = invMatch['id']?.toString();
        medName = invMatch['name'] ?? rawName;
        medType = _getMedicineType(invMatch);
        availableStock = _getAvailableStock(invMatch);
      }

      final timing = tplMed['timing'] ?? tplMed['dose'] ?? '1+1+1';
      final digits = timing.toString().replaceAll('+', '');
      final m = int.tryParse(digits.isNotEmpty ? digits[0] : '0') ?? 0;
      final e = digits.length > 1 ? int.tryParse(digits[1]) ?? 0 : 0;
      final n = digits.length > 2 ? int.tryParse(digits[2]) ?? 0 : 0;
      final sum = m + e + n;
      final perDayQty = (tplMed['quantity'] is num)
          ? (tplMed['quantity'] as num).toInt()
          : (sum > 0 ? sum : 1);

      final isInj = _isInjectionOrDrip({'type': medType, 'name': medName});
      final totalNeeded = isInj ? perDayQty : perDayQty * (template['defaultDays'] as int? ?? 1);

      final medEntry = {
        'name': medName,
        'quantity': perDayQty,
        'timing': timing,
        'meal': tplMed['instructions'] ?? tplMed['meal'] ?? 'After Meal',
        'dosage': tplMed['dosage'] ?? '',
        'type': medType,
        'inventoryId': inventoryId,
      };

      if (invMatch != null && availableStock <= 0) {
        outOfStockMeds.add({'med': medEntry, 'stock': availableStock, 'match': invMatch});
      } else if (invMatch != null && availableStock < totalNeeded) {
        lowStockMeds.add({'med': medEntry, 'stock': availableStock, 'match': invMatch});
        resolvedMeds.add(medEntry);
      } else {
        resolvedMeds.add(medEntry);
      }
    }

    if (outOfStockMeds.isNotEmpty) {
      _showTemplateStockWarningDialog(
        template: template,
        outOfStockList: outOfStockMeds,
        lowStockList: lowStockMeds,
        resolvedMeds: resolvedMeds,
      );
    } else {
      _finalizeTemplateApplication(template, resolvedMeds);
    }
  }

  void _showTemplateStockWarningDialog({
    required Map<String, dynamic> template,
    required List<Map<String, dynamic>> outOfStockList,
    required List<Map<String, dynamic>> lowStockList,
    required List<Map<String, dynamic>> resolvedMeds,
  }) {
    final isDark = _isDark;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF78350F) : Colors.amber.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.inventory_2_rounded, color: isDark ? const Color(0xFFFBBF24) : Colors.amber.shade900, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Inventory Stock Verification',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
                    Text('Real-time audit for "${template['name']}"',
                        style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.grey.shade600)),
                  ],
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
                  'The following medicines in this template have inventory stock alerts:',
                  style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white70 : Colors.black87),
                ),
                const SizedBox(height: 12),
                ...outOfStockList.map((item) {
                  final med = item['med'] as Map<String, dynamic>;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isDark ? const Color(0xFFEF4444) : Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.cancel, color: Colors.red, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${med['name']} (${med['type']})',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDark ? const Color(0xFFFCA5A5) : Colors.red.shade900)),
                              const Text('Status: 0 In Stock (Unavailable in dispensary)', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (lowStockList.isNotEmpty) ...[
                  ...lowStockList.map((item) {
                    final med = item['med'] as Map<String, dynamic>;
                    final stock = item['stock'];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isDark ? const Color(0xFFF97316) : Colors.amber.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: isDark ? const Color(0xFFFBBF24) : Colors.amber.shade900, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${med['name']} (${med['type']})',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDark ? const Color(0xFFFDE68A) : Colors.amber.shade900)),
                                Text('Low Stock: Only $stock units left in dispensary',
                                    style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFFFCD34D) : Colors.amber.shade800)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
              label: const Text('Apply In-Stock Only'),
              style: OutlinedButton.styleFrom(foregroundColor: isDark ? const Color(0xFFF97316) : Colors.orange.shade900),
              onPressed: () {
                Navigator.pop(ctx);
                _finalizeTemplateApplication(template, resolvedMeds);
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.done_all_rounded, size: 16),
              label: const Text('Apply Anyway (Custom)'),
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(ctx);
                // Convert out-of-stock medicines to Custom (no inventoryId = external purchase)
                final customMeds = outOfStockList.map((e) {
                  final med = Map<String, dynamic>.from(e['med'] as Map);
                  med.remove('inventoryId');  // Strip inventory link → becomes Custom
                  return med;
                }).toList();
                final allCombined = [...resolvedMeds, ...customMeds];
                _finalizeTemplateApplication(template, allCombined);
              },
            ),
          ],
        );
      },
    );
  }

  void _finalizeTemplateApplication(Map<String, dynamic> template, List<Map<String, dynamic>> meds) {
    setState(() {
      widget.complaintController.text = template['complaint']?.toString() ?? '';
      widget.diagnosisController.text = template['diagnosis']?.toString() ?? '';
      
      final days = (template['defaultDays'] as int?) ?? 1;
      _daysOfMedicine = (days >= 1 && days <= 3) ? days : 1;

      widget.prescriptions
        ..clear()
        ..addAll(meds);

      // Force 1 day if any injection is in template
      if (widget.prescriptions.any(_isInjectionOrDrip)) {
        _daysOfMedicine = 1;
      }

      // Add template lab tests
      final tplLabs = (template['labResults'] as List<dynamic>?) ?? [];
      widget.labResults.clear();
      _selectedQuickTests.clear();
      for (final raw in tplLabs) {
        if (raw is Map) {
          final lMap = Map<String, dynamic>.from(raw);
          widget.labResults.add(lMap);
          final n = lMap['name']?.toString() ?? '';
          if (_currentQuickList.contains(n)) _selectedQuickTests.add(n);
        }
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚡ Applied "${template['name']}" — ${meds.length} medicine(s) loaded'),
          backgroundColor: _teal,
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteTemplate(String templateId, String templateName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: _isDark ? const Color(0xFF1E293B) : Colors.white,
        title: Row(
          children: [
            const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 24),
            const SizedBox(width: 8),
            Text('Delete Template', style: TextStyle(color: _isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          'Are you sure you want to delete the "$templateName" template?',
          style: TextStyle(color: _isDark ? Colors.white70 : Colors.black87),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await PrescriptionTemplateService.deleteTemplate(widget.branchId, templateId, doctorId: widget.doctorId);
      await _loadPrescriptionTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🗑️ Deleted "$templateName"'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showEditTemplateDialog(Map<String, dynamic> template) async {
    final titleCtrl = TextEditingController(text: template['name'] ?? '');
    final complaintCtrl = TextEditingController(text: template['complaint'] ?? '');
    final diagnosisCtrl = TextEditingController(text: template['diagnosis'] ?? '');
    String selectedCategory = template['category'] ?? 'General';
    int defaultDays = (template['defaultDays'] as int?) ?? 1;
    final isDark = _isDark;

    List<Map<String, dynamic>> tempMeds = List<Map<String, dynamic>>.from(
      (template['medicines'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? [],
    );

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          title: Row(
            children: [
              const Icon(Icons.edit_note_rounded, color: _teal, size: 24),
              const SizedBox(width: 8),
              Text('Edit Prescription Template',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : Colors.black87)),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Template Title:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: titleCtrl,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Category:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: selectedCategory,
                    dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                    items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho', 'Infectious']
                        .map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(color: isDark ? Colors.white : Colors.black87))))
                        .toList(),
                    onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Patient Condition / Complaints:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: complaintCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Diagnosis:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: diagnosisCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Default Duration (Days):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                      Row(
                        children: [1, 2, 3].map((d) {
                          return Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: ChoiceChip(
                              label: Text('$d Day${d > 1 ? "s" : ""}'),
                              selected: defaultDays == d,
                              onSelected: (_) => setDlgState(() => defaultDays = d),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Medicines in Template (${tempMeds.length}):',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF5EEAD4) : _teal)),
                      TextButton.icon(
                        icon: const Icon(Icons.sync, size: 14),
                        label: const Text('Update with Current Form', style: TextStyle(fontSize: 11)),
                        onPressed: () {
                          setDlgState(() {
                            tempMeds = List<Map<String, dynamic>>.from(widget.prescriptions);
                            complaintCtrl.text = widget.complaintController.text;
                            diagnosisCtrl.text = widget.diagnosisController.text;
                            defaultDays = _daysOfMedicine;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...tempMeds.map((m) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${m['name']} (${m['timing'] ?? m['dose'] ?? '1+1+1'}) • ${m['meal'] ?? m['instructions'] ?? ''}',
                              style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white : Colors.black87),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16, color: Colors.red),
                            onPressed: () => setDlgState(() => tempMeds.remove(m)),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _deleteTemplate(template['id'], template['name']);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete Template'),
            ),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
              onPressed: () async {
                final newName = titleCtrl.text.trim();
                if (newName.isEmpty) return;

                final updated = Map<String, dynamic>.from(template);
                updated['name'] = newName;
                updated['category'] = selectedCategory;
                updated['complaint'] = complaintCtrl.text.trim();
                updated['diagnosis'] = diagnosisCtrl.text.trim();
                updated['defaultDays'] = defaultDays;
                updated['medicines'] = tempMeds;

                await PrescriptionTemplateService.saveTemplate(widget.branchId, updated, doctorId: widget.doctorId);
                await _loadPrescriptionTemplates();
                if (ctx.mounted) Navigator.pop(ctx);

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✏️ Updated "$newName" template'),
                      backgroundColor: _teal,
                      duration: const Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showManageTemplatesDialog() async {
    final isDark = _isDark;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          title: Row(
            children: [
              const Icon(Icons.tune_rounded, color: _teal, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Manage Prescription Presets',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : Colors.black87)),
                    Text('${_prescriptionTemplates.length} custom preset(s) saved',
                        style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white60 : Colors.grey.shade600)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded, color: _teal),
                tooltip: 'Create New from Current Form',
                onPressed: () {
                  Navigator.pop(ctx);
                  _showSaveCurrentAsTemplateDialog();
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            height: 400,
            child: _prescriptionTemplates.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.bookmark_border_rounded, size: 48, color: isDark ? Colors.white38 : Colors.grey.shade400),
                        const SizedBox(height: 10),
                        Text('No templates added yet',
                            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                        const SizedBox(height: 4),
                        Text('Fill a prescription and click "Save as Preset"',
                            style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _prescriptionTemplates.length,
                    itemBuilder: (context, idx) {
                      final tpl = _prescriptionTemplates[idx];
                      final medCount = (tpl['medicines'] as List?)?.length ?? 0;
                      final labCount = (tpl['labResults'] as List?)?.length ?? 0;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF134E4A) : _dosePillBg,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.medical_services_rounded, color: isDark ? const Color(0xFF2DD4BF) : _teal, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tpl['name'] ?? '', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: isDark ? Colors.white : Colors.black87)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${tpl['category'] ?? 'General'} • $medCount Meds • $labCount Labs • ${tpl['defaultDays'] ?? 1} Day(s)',
                                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.bolt, color: Colors.amber, size: 20),
                              tooltip: 'Apply to Current Patient',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _applyPrescriptionTemplate(tpl);
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.edit_outlined, color: isDark ? Colors.white70 : Colors.grey.shade700, size: 18),
                              tooltip: 'Edit Template',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showEditTemplateDialog(tpl);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                              tooltip: 'Delete Template',
                              onPressed: () async {
                                await PrescriptionTemplateService.deleteTemplate(widget.branchId, tpl['id']);
                                await _loadPrescriptionTemplates();
                                setDlgState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  Future<void> _showSaveCurrentAsTemplateDialog() async {
    final complaint = widget.complaintController.text.trim();
    final diagnosis = widget.diagnosisController.text.trim();

    if (_prescriptionTemplates.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('⚠️ Maximum limit reached (5 disease presets). Please edit or delete an existing preset.'),
          backgroundColor: Colors.amber.shade800,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (complaint.isEmpty && diagnosis.isEmpty && widget.prescriptions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill Diagnosis or Medicines first to save as a Template!'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final titleCtrl = TextEditingController(text: diagnosis.isNotEmpty ? diagnosis : 'Prescription Preset');
    String selectedCategory = 'General';
    final isDark = _isDark;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          title: Row(
            children: [
              const Icon(Icons.bookmark_add_rounded, color: _teal, size: 24),
              const SizedBox(width: 8),
              Text('Save As Reusable Template',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : Colors.black87)),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Template Name / Title:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                  decoration: InputDecoration(
                    hintText: 'e.g. Acute URTI (Adult)',
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Category:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.grey.shade700)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                  items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(color: isDark ? Colors.white : Colors.black87))))
                      .toList(),
                  onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF134E4A) : _dosePillBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF2DD4BF) : _dosePillBorder, width: 0.6),
                  ),
                  child: Text(
                    'Includes: ${widget.prescriptions.length} Medicine(s) • ${widget.labResults.length} Lab Test(s) • Day: $_daysOfMedicine',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF5EEAD4) : _teal),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
              onPressed: () async {
                final name = titleCtrl.text.trim();
                if (name.isEmpty) return;

                final newTpl = {
                  'id': 'tpl_${DateTime.now().millisecondsSinceEpoch}',
                  'name': name,
                  'category': selectedCategory,
                  'complaint': complaint,
                  'diagnosis': diagnosis,
                  'defaultDays': _daysOfMedicine,
                  'medicines': List<Map<String, dynamic>>.from(widget.prescriptions),
                  'labResults': List<Map<String, dynamic>>.from(widget.labResults),
                };

                try {
                  await PrescriptionTemplateService.saveTemplate(widget.branchId, newTpl, doctorId: widget.doctorId);
                  await _loadPrescriptionTemplates();
                  if (ctx.mounted) Navigator.pop(ctx);

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('⭐ Saved "$name" to your Presets library!'),
                        backgroundColor: _teal,
                        duration: const Duration(seconds: 3),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: Colors.red),
                    );
                  }
                }
              },
              child: const Text('Save Template'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickTemplatesBar(bool compact, bool isDark) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFA7F3D0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black26 : Colors.teal.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xFFF59E0B), size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Disease Presets (Templates)',
                  style: TextStyle(
                    fontSize: compact ? 12.5 : 13.5,
                    fontWeight: FontWeight.w800,
                    color: isDark ? const Color(0xFF5EEAD4) : _teal,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _showManageTemplatesDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF475569) : Colors.grey.shade300, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded, size: 13, color: isDark ? Colors.white70 : Colors.grey.shade700),
                      const SizedBox(width: 4),
                      Text(
                        'Manage',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white70 : Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _showSaveCurrentAsTemplateDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF2DD4BF) : _teal, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmark_add_outlined, size: 13, color: isDark ? const Color(0xFF2DD4BF) : _teal),
                      const SizedBox(width: 4),
                      Text(
                        'Save as Preset',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF2DD4BF) : _teal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_prescriptionTemplates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14, color: isDark ? Colors.white54 : Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'No presets created yet. Fill diagnosis & medicines, then click "Save as Preset" above.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? Colors.white60 : Colors.grey.shade700,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _prescriptionTemplates.map((tpl) {
                  final name = tpl['name']?.toString() ?? 'Preset';
                  final iconName = tpl['icon']?.toString();
                  final iconData = PrescriptionTemplateService.getIcon(iconName);

                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: FaIcon(iconData, size: 12, color: Colors.white),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => _showEditTemplateDialog(tpl),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 2),
                              child: Icon(Icons.more_vert, size: 13, color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                      backgroundColor: isDark ? const Color(0xFF0F766E) : _teal,
                      elevation: 1,
                      pressElevation: 3,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onPressed: () => _applyPrescriptionTemplate(tpl),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ── Days-of-medicine selector ──────────────────────────────────────────────
  Widget _buildDaysSelector(bool compact) {
    final pricePerDay = _baseDayPrice[widget.queueType] ?? 0;
    final isDark      = _isDark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFD1FAE5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black26 : Colors.teal.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaIcon(FontAwesomeIcons.calendarDays, color: isDark ? const Color(0xFF2DD4BF) : _teal, size: 15),
                  const SizedBox(width: 8),
                  Text(
                    'Days of Medicine',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: isDark ? const Color(0xFF5EEAD4) : _teal,
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 3 Items with dividers
                  ...[1, 2, 3].map((day) {
                    final isSelected = _daysOfMedicine == day;
                    final isDisabled = _hasInjection && day > 1;
                    final extra = (pricePerDay > 0 && day > 1) ? (day - 1) * pricePerDay : 0;

                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (day > 1)
                          Container(
                            width: 1,
                            height: 20,
                            margin: const EdgeInsets.symmetric(horizontal: 10),
                            color: isDark ? const Color(0xFF475569) : Colors.grey.shade300,
                          ),
                        InkWell(
                          onTap: isDisabled
                              ? () {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                    content: Text('💉 Injection prescribed — only 1 day of medicine allowed'),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 2),
                                  ));
                                }
                              : () => setState(() => _daysOfMedicine = day),
                          borderRadius: BorderRadius.circular(20),
                          child: isSelected
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 30,
                                      height: 30,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _teal,
                                        boxShadow: [
                                          BoxShadow(
                                            color: _teal.withValues(alpha: 0.35),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Text(
                                        '$day',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF2DD4BF) : _teal,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ],
                                )
                              : Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '$day',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.bold,
                                          color: isDisabled
                                              ? (isDark ? const Color(0xFF64748B) : Colors.grey.shade400)
                                              : (isDark ? Colors.white70 : _teal),
                                        ),
                                      ),
                                      if (extra > 0 && !isDisabled)
                                        Text(
                                          '+$extra',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.orange.shade800,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    );
                  }),
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    color: isDark ? const Color(0xFF475569) : Colors.grey.shade300,
                  ),
                  InkWell(
                    onTap: () => _showDaysInfoDialog(context),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Info',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? const Color(0xFF5EEAD4) : _teal,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.info_outline_rounded,
                            size: 15,
                            color: isDark ? const Color(0xFF5EEAD4) : _teal,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_hasInjection) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(children: [
              FaIcon(FontAwesomeIcons.syringe, size: 12, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Injection prescribed — only 1 day of medicine allowed.',
                  style: TextStyle(
                      fontSize: compact ? 9.5 : 10.5,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
        ] else if (_daysOfMedicine > 1) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _extraCharge > 0
                  ? (isDark ? const Color(0xFF451A03) : const Color(0xFFFFF7ED))
                  : _teal.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _extraCharge > 0
                    ? (isDark ? const Color(0xFFF97316) : Colors.orange.shade300)
                    : _teal.withValues(alpha: 0.2),
              ),
            ),
            child: Row(children: [
              Icon(
                _extraCharge > 0 ? Icons.monetization_on_outlined : Icons.info_outline,
                size: 14,
                color: _extraCharge > 0
                    ? (isDark ? const Color(0xFFFB923C) : Colors.orange.shade800)
                    : _teal.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _extraCharge > 0
                      ? 'Extra Token Charge: +PKR $_extraCharge will be collected. Dispenser will issue $_daysOfMedicine days of medicine in one go.'
                      : 'Dispenser will issue $_daysOfMedicine days of medicine in one go (No extra charge for ${widget.queueType} patients).',
                  style: TextStyle(
                    fontSize: compact ? 9.5 : 10.5,
                    color: _extraCharge > 0
                        ? (isDark ? const Color(0xFFFED7AA) : Colors.orange.shade900)
                        : (isDark ? const Color(0xFF5EEAD4) : _teal.withValues(alpha: 0.85)),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
          ),
        ],
      ],
    );
  }

  void _showDaysInfoDialog(BuildContext context) {
    final isDark = _isDark;
    final pricePerDay = _baseDayPrice[widget.queueType] ?? 0;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF134E4A) : const Color(0xFFCCFBF1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: isDark ? const Color(0xFF2DD4BF) : _teal,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Days of Medicine & Token Rules',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: isDark ? Colors.white60 : Colors.grey.shade600,
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const Divider(height: 24),
              // Section 1: Pricing Breakdown
              Text(
                '💰 Token Charges Breakdown (${widget.queueType.toUpperCase()} Patients):',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFF5EEAD4) : _teal,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    _buildDaysDialogRow('1 Day:', pricePerDay > 0 ? 'PKR $pricePerDay (Paid at Token Desk)' : 'Free (No fee)', isDark),
                    const SizedBox(height: 6),
                    _buildDaysDialogRow('2 Days:', pricePerDay > 0 ? 'PKR $pricePerDay + PKR $pricePerDay (Extra PKR $pricePerDay at Dispense)' : 'Free (No fee)', isDark),
                    const SizedBox(height: 6),
                    _buildDaysDialogRow('3 Days:', pricePerDay > 0 ? 'PKR $pricePerDay + PKR ${pricePerDay * 2} (Extra PKR ${pricePerDay * 2} at Dispense)' : 'Free (No fee)', isDark),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Section 2: Dispensing Rule
              Text(
                '💊 Dispensing & Dosage Rule:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFF5EEAD4) : _teal,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '• Dosages remain per-day (e.g. 1+1+1 stays 1+1+1).\n'
                '• The dispenser multiplies the daily dose by the selected days and hands over the full stock at once.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                ),
              ),
              const SizedBox(height: 12),
              // Section 3: Injection rule
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade300),
                ),
                child: Row(
                  children: [
                    FaIcon(FontAwesomeIcons.syringe, size: 14, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Injections are strictly restricted to 1 Day only.',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDaysDialogRow(String label, String value, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isDark ? Colors.white70 : const Color(0xFF475569))),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706))),
      ],
    );
  }

  // ── Main save ──────────────────────────────────────────────────────────────
  Future<void> _savePrescriptionHiveFirst() async {
    final complaint = widget.complaintController.text.trim();
    final diagnosis = widget.diagnosisController.text.trim();

    if (complaint.isEmpty || diagnosis.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Both Patient Condition and Diagnosis are required!'),
          backgroundColor: Colors.red));
      return;
    }
    final isVitalsOnly = widget.selectedPatientData?['isVitalsOnly'] == true ||
        widget.selectedPatientData?['vitalsOnly'] == true;

    if (!isVitalsOnly && widget.prescriptions.isEmpty && widget.labResults.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please add at least one medicine or lab test!'),
          backgroundColor: Colors.orange));
      return;
    }

    // ── FIX: Final stock check at save time to catch any race conditions
    for (final med in widget.prescriptions) {
      final inventoryId = med['inventoryId']?.toString() ?? '';
      if (inventoryId.isEmpty) continue;

      // Refresh reserved quantities one more time before saving
      await _buildReservedQuantities();

      final inventoryMed = _allInventory.firstWhere(
        (m) => m['id']?.toString() == inventoryId,
        orElse: () => {},
      );
      if (inventoryMed.isEmpty) continue;

      final available = _getAvailableStock(inventoryMed);
      // At save time we include THIS session's qty in available (since
      // _getAvailableStock subtracts session qty already), so compare
      // against the raw per-day qty.
      final medQty = med['quantity'];
      final perDayQty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
      // Re-add session qty to get "others only" available
      final othersOnly = available + perDayQty;

      final isInj = _isInjectionOrDrip(med);
      final required = isInj ? perDayQty : perDayQty * _daysOfMedicine;

      if (required > othersOnly) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              '⚠️ "${med['name']}" stock insufficient! '
              'Need $required but only $othersOnly available after reservations.',
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ));
        }
        return;
      }
    }

    try {
      final patientData = Map<String, dynamic>.from(widget.selectedPatientData ?? {});

      String patientCnic = (patientData['cnic']?.toString() ??
              patientData['guardianCnic']?.toString() ??
              patientData['patientCnic']?.toString() ?? '')
          .trim()
          .replaceAll(RegExp(r'[-\s]'), '');
      if (patientCnic.isEmpty || patientCnic == '0000000000000') {
        patientCnic = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
      }

      final doctorId    = widget.doctorId;
      final doctorName  = widget.doctorName;
      final queueType   = widget.queueType;
      final days        = _daysOfMedicine;
      final extraCharge = _extraCharge;

      debugPrint('[DoctorPanel] saving — doctor="$doctorName" '
          'queue="$queueType" serial="${widget.serialId}" '
          'days=$days extraCharge=$extraCharge');

      final now         = DateTime.now();
      final nowIso      = now.toIso8601String();
      final serialClean = widget.serialId.trim().toLowerCase();
      String resolvedPatientName = (patientData['patientName'] ?? patientData['name'] ?? patientData['fullName'])?.toString().trim() ?? '';
      if (resolvedPatientName.isEmpty || resolvedPatientName.toLowerCase() == 'unknown' || resolvedPatientName.toLowerCase() == 'unknown patient') {
        final normB = widget.branchId.toLowerCase().trim();
        final normS = serialClean.toLowerCase();
        try {
          if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            final eBox = Hive.box(LocalStorageService.entriesBox);
            for (final k in eBox.keys) {
              final kStr = k.toString().toLowerCase();
              if (kStr == '$normB-$normS' || kStr.endsWith('-$normS') || kStr == normS) {
                final entry = eBox.get(k);
                if (entry is Map) {
                  final n = (entry['patientName'] ?? entry['name'] ?? entry['fullName'])?.toString().trim();
                  if (n != null && n.isNotEmpty && n.toLowerCase() != 'unknown' && n.toLowerCase() != 'unknown patient') {
                    resolvedPatientName = n;
                    break;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }
      if (resolvedPatientName.isEmpty) resolvedPatientName = 'Unknown Patient';

      final parts       = serialClean.split('-');
      final dateKey     = (parts.isNotEmpty && parts[0] == 'x')
          ? (parts.length > 1 ? parts[1] : '')
          : (parts.isNotEmpty ? parts[0] : '');

      final medicineList = widget.prescriptions.map((m) {
        return {
          'name':        m['name'],
          'quantity':    m['quantity'],   // per-day, unchanged
          'type':        m['type'] ?? 'Tablet',
          'timing':      m['timing'] ?? '',
          'meal':        m['meal'] ?? '',
          'dosage':      m['dosage'] ?? '',
          'dose':        m['dose'] ?? m['dosage'] ?? '',
          'inventoryId': m['inventoryId'],
        };
      }).toList();

      final labList = widget.labResults.map((l) => {'name': l['name']}).toList();

      final rawVitals = patientData['vitals'];
      final vitalsMap = rawVitals is Map
          ? Map<String, dynamic>.from(rawVitals)
          : <String, dynamic>{
              if (patientData['bp'] != null && patientData['bp'] != 'N/A') 'bp': patientData['bp'],
              if (patientData['temp'] != null && patientData['temp'] != 'N/A') 'temp': patientData['temp'],
              if (patientData['sugar'] != null && patientData['sugar'] != 'N/A') 'sugar': patientData['sugar'],
              if (patientData['weight'] != null && patientData['weight'] != 'N/A') 'weight': patientData['weight'],
            };

      final medicalData = <String, dynamic>{
        'complaint':       complaint,
        'condition':       complaint,
        'diagnosis':       diagnosis,
        'prescriptions':   medicineList,
        'labResults':      labList,
        'patientName':     resolvedPatientName,
        'name':            resolvedPatientName,
        'vitals':          vitalsMap,
        'daysOfMedicine':  days,
        'extraCharge':     extraCharge,
        'completedAt':     nowIso,
        'updatedAt':       nowIso,
        'doctorId':        doctorId,
        'doctorName':      doctorName,
        'prescribedBy':    doctorName,
        'updatedBy':       doctorName,
        'isPhysiotherapist': widget.isPhysiotherapist,
      };

      final fullPrescriptionData = <String, dynamic>{
        'id':              serialClean,
        'serial':          serialClean,
        'patientCnic':     patientCnic,
        'cnic':            patientCnic,
        'patientId':       LocalStorageService.resolveIndividualPatientId(patientData),
        'guardianCnic':    patientData['guardianCnic']?.toString(),
        'patientName':     resolvedPatientName,
        'name':            resolvedPatientName,
        'patientAge':      patientData['age']?.toString() ?? 'N/A',
        'patientGender':   patientData['gender']?.toString() ?? 'N/A',
        'complaint':       complaint,
        'condition':       complaint,
        'diagnosis':       diagnosis,
        'prescriptions':   medicineList,
        'labResults':      labList,
        'vitals':          vitalsMap,
        'daysOfMedicine':  days,
        'extraCharge':     extraCharge,
        'completedAt':     nowIso,
        'updatedAt':       nowIso,
        'status':          'completed',
        'queueType':       queueType,
        'createdAt':       nowIso,
        'branchId':        widget.branchId,
        'dateKey':         dateKey,
        'doctorId':        doctorId,
        'doctorName':      doctorName,
        'prescribedBy':    doctorName,
        'updatedBy':       doctorName,
        'dispensaryTag':   patientData['dispensaryTag']?.toString(),
        'dispensaryId':    patientData['dispensaryId']?.toString(),
        'campId':          patientData['campId']?.toString(),
        'campName':        patientData['campName']?.toString(),
        'session':         patientData['session']?.toString() ?? CampSessionService.getCurrentSession(null, widget.branchId),
        // ── FIX: Mark as not yet dispensed so _buildReservedQuantities
        //         picks it up correctly for subsequent patients
        'dispenseStatus':  'pending',
        'isPhysiotherapist': widget.isPhysiotherapist,
      };

      // 1. Hive prescriptions box
      await LocalStorageService.saveLocalPrescription(fullPrescriptionData);

      // Save medicine restriction for multi-day prescriptions
      if (days > 1) {
        final pId = LocalStorageService.resolveIndividualPatientId(patientData);
        
        if (pId.isNotEmpty) {
          await LocalStorageService.saveMedicineRestriction(
            branchId:    widget.branchId,
            patientId:   pId,
            daysCovered: days,
          );
          debugPrint('[DoctorPanel] ✅ Individual restriction saved for: $pId ($days days)');
        } else {
          debugPrint('[DoctorPanel] ⚠️ Cannot save restriction: No patientId found.');
        }
      }

      // 2. Embed into Hive entriesBox (updating ALL matching serial keys)
      final entriesBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final rawSerial  = widget.serialId.trim().toLowerCase();
      final targetBranch = widget.branchId.trim().toLowerCase();

      final matchingKeys = <dynamic>[];
      for (final k in entriesBox.keys) {
        final kStr = k.toString().toLowerCase();
        if (kStr == '$targetBranch-$rawSerial' ||
            kStr.endsWith('-$rawSerial') ||
            kStr == rawSerial) {
          matchingKeys.add(k);
        } else {
          final val = entriesBox.get(k);
          if (val is Map && (val['serial']?.toString().toLowerCase() == rawSerial)) {
            matchingKeys.add(k);
          }
        }
      }

      if (matchingKeys.isEmpty) {
        matchingKeys.add('${widget.branchId}-${widget.serialId.trim()}');
      }

      final normBranch = widget.branchId.trim().toLowerCase();
      final normSerialUpper = serialClean.toUpperCase();
      final canonicalKey = '$normBranch-$normSerialUpper';

      Map<String, dynamic>? updated;
      for (final k in matchingKeys) {
        final current = entriesBox.get(k);
        final base = current != null
            ? Map<String, dynamic>.from(current as Map)
            : Map<String, dynamic>.from(patientData);

        final curName = (base['patientName'] ?? base['name'])?.toString().trim();
        if (resolvedPatientName != 'Unknown Patient' || curName == null || curName.isEmpty || curName.toLowerCase() == 'unknown' || curName.toLowerCase() == 'unknown patient') {
          base['patientName'] = resolvedPatientName;
          base['name'] = resolvedPatientName;
        }

        base['status']         = 'completed';
        base['completedAt']    = nowIso;
        base['prescription']   = medicalData;
        base['prescriptionId'] = serialClean;
        base['queueType']      = queueType;
        base['doctorName']     = doctorName;
        base['doctorId']       = doctorId;
        base['daysOfMedicine'] = days;
        base['extraCharge']    = extraCharge;
        base['vitals']         = vitalsMap;
        base['dispenseStatus'] ??= 'pending';
        base['dateKey']        ??= dateKey;
        base['session']        ??= (patientData['session'] ?? CampSessionService.getCurrentSession(null, widget.branchId));
        base['branchId']       ??= widget.branchId;
        base['serial']         ??= serialClean;
        base['patientCnic']    ??= patientCnic;
        base['cnic']           ??= patientCnic;
        base['guardianCnic']   ??= patientData['guardianCnic']?.toString();
        base['patientAge']     ??= (patientData['age'] ?? patientData['patientAge'])?.toString();
        base['patientGender']  ??= (patientData['gender'] ?? patientData['patientGender'])?.toString();
        base['dispensaryTag']  ??= patientData['dispensaryTag']?.toString();
        base['dispensaryId']   ??= patientData['dispensaryId']?.toString();
        base['campId']         ??= patientData['campId']?.toString();
        base['campName']       ??= patientData['campName']?.toString();
        base['createdBy']      ??= (patientData['createdBy'] ?? base['createdBy']);
        base['createdByName']  ??= (patientData['createdByName'] ?? base['createdByName']);
        base['receptionistId'] ??= (patientData['receptionistId'] ?? base['receptionistId']);
        base['receptionistName'] ??= (patientData['receptionistName'] ?? base['receptionistName']);
        base['tokenBy']        ??= (patientData['tokenBy'] ?? base['tokenBy']);

        updated = base;
      }

      final finalUpdated = updated ?? Map<String, dynamic>.from(patientData);
      await entriesBox.put(canonicalKey, finalUpdated);

      // Clean up redundant non-canonical keys
      for (final k in matchingKeys) {
        if (k.toString() != canonicalKey && entriesBox.containsKey(k)) {
          await entriesBox.delete(k);
        }
      }

      // 3. Update Firestore Cloud Document (un-awaited background sync so network latency never blocks UI/LAN)
      final campDocKey = CampSessionService.getCampDateDocId(
        branchId: widget.branchId,
        dateKey: dateKey,
        campId: patientData['campId']?.toString() ?? patientData['dispensaryId']?.toString(),
        dispensaryTag: patientData['dispensaryTag']?.toString(),
        serial: widget.serialId.trim(),
      );

      final cloudUpdatePayload = <String, dynamic>{
        'status':         'completed',
        'completedAt':    nowIso,
        'prescription':   medicalData,
        'patientName':     resolvedPatientName,
        'patientCnic':     patientCnic,
        'doctorName':     doctorName,
        'doctorId':       doctorId,
        'daysOfMedicine': days,
        'vitals':         vitalsMap,
        'dispenseStatus': 'pending',
        'updatedAt':      FieldValue.serverTimestamp(),
      };

      final serialsCol = FirebaseFirestore.instance
          .collection('branches').doc(widget.branchId)
          .collection('serials');

      serialsCol.doc(campDocKey)
          .collection(queueType.toLowerCase())
          .doc(widget.serialId.trim())
          .set(cloudUpdatePayload, SetOptions(merge: true))
          .then((_) {
        debugPrint('[DoctorPanel] ☁️ Updated Firestore serials/$campDocKey/$queueType/${widget.serialId.trim()} to completed');
      }).catchError((e) {
        debugPrint('[DoctorPanel] ⚠️ Cloud Firestore update deferred: $e');
      });

      if (campDocKey != dateKey) {
        serialsCol.doc(dateKey)
            .collection(queueType.toLowerCase())
            .doc(widget.serialId.trim())
            .set(cloudUpdatePayload, SetOptions(merge: true))
            .catchError((_) {});
      }

      // 4. LAN broadcast — send clinical prescription update ONLY (do not re-broadcast receptionist entry fields)
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.savePrescription,
          branchId: widget.branchId,
          data: fullPrescriptionData,
        ));
      } catch (e) {
        debugPrint('[DoctorPanel] Broadcast failed: $e');
      }

      // 4. Clear UI
      widget.complaintController.clear();
      widget.diagnosisController.clear();
      widget.prescriptions.clear();
      widget.labResults.clear();
      _selectedQuickTests.clear();
      setState(() => _daysOfMedicine = 1);
      widget.onEntryCompleted?.call();
      if (widget.onSavePrescription != null) await widget.onSavePrescription!();

      // 5. Firestore background sync
      _syncToFirestoreInBackground(
          dateKey, queueType, serialClean, patientCnic,
          fullPrescriptionData, medicalData);

      // 6. Enqueue extra-charge sync op
      if (extraCharge > 0) {
        _enqueueExtraChargeSync(
          branchId:    widget.branchId,
          serial:      serialClean,
          dateKey:     dateKey,
          queueType:   queueType,
          patientCnic: patientCnic,
          patientName: fullPrescriptionData['patientName'] as String,
          amount:      extraCharge,
          days:        days,
          doctorName:  doctorName,
          nowIso:      nowIso,
        );
      }

      // 7. ── FIX: Rebuild reserved quantities so the NEXT patient the
      //           doctor opens immediately sees accurate stock numbers
      await _buildReservedQuantities();

    } catch (e, stack) {
      debugPrint('[DoctorPanel] Save failed: $e\n$stack');
      if (mounted) {
        Flushbar(
          message: 'Failed to save: $e',
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ).show(context);
      }
    }
  }

  void _enqueueExtraChargeSync({
    required String branchId,
    required String serial,
    required String dateKey,
    required String queueType,
    required String patientCnic,
    required String patientName,
    required int amount,
    required int days,
    required String doctorName,
    required String nowIso,
  }) {
    try {
      LocalStorageService.enqueueSync({
        'type':      'save_dispensary_charge',
        'branchId':  branchId,
        'serial':    serial,
        'dateKey':   dateKey,
        'queueType': queueType,
        'data': {
          'serial':          serial,
          'branchId':        branchId,
          'dateKey':         dateKey,
          'queueType':       queueType,
          'patientCnic':     patientCnic,
          'patientName':     patientName,
          'amount':          amount,
          'daysOfMedicine':  days,
          'chargeType':      'extra_days',
          'prescribedBy':    doctorName,
          'createdAt':       nowIso,
        },
      });
      SyncService().triggerUpload();
    } catch (e) {
      debugPrint('[DoctorPanel] Extra-charge enqueue failed: $e');
    }
  }

  Future<void> _syncToFirestoreInBackground(
    String dateKey, String queueType, String serial, String patientCnic,
    Map<String, dynamic> fullData, Map<String, dynamic> medicalData,
  ) async {
    // [DEDUP] If connected to LAN server, the prescription already traveled
    // via WebSocket → Server SSM → Firestore. Skip direct write.
    final lanConnected = RealtimeManager().isConnected;
    if (lanConnected) {
      debugPrint('[DoctorPanel] LAN connected — server will sync prescription $serial');
      return;
    }

    try {
      final isOnline = NetworkHealthService().isStableOnline;

      if (isOnline) {
        final branchRef = FirebaseFirestore.instance.collection('branches').doc(widget.branchId);

        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: widget.branchId,
          dateKey: dateKey,
          campId: fullData['campId']?.toString() ?? fullData['dispensaryId']?.toString(),
          dispensaryTag: fullData['dispensaryTag']?.toString(),
          serial: serial,
        );

        // Single canonical write: updates the serial doc with clinical details + status
        await branchRef
            .collection('serials').doc(campDocKey)
            .collection(queueType).doc(serial)
            .set({
              'status':          'completed',
              'completedAt':     fullData['completedAt'],
              'doctorName':      fullData['doctorName'],
              'doctorId':        fullData['doctorId'],
              'daysOfMedicine':  fullData['daysOfMedicine'],
              'extraCharge':     fullData['extraCharge'],
              'prescription':    medicalData,
              'dispenseStatus':  'pending',
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 4));
      } else {
        await _enqueueSync(dateKey, queueType, serial, patientCnic, fullData, medicalData);
      }
    } catch (e) {
      debugPrint('[DoctorPanel] Firestore sync failed: $e');
      await _enqueueSync(dateKey, queueType, serial, patientCnic, fullData, medicalData);
    }
  }

  Future<void> _enqueueSync(
    String dateKey, String queueType, String serial, String patientCnic,
    Map<String, dynamic> fullData, Map<String, dynamic> medicalData,
  ) async {
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_prescription',
        'branchId': widget.branchId,
        'dateKey': dateKey,
        'queueType': queueType,
        'serial': serial,
        'data': {
          'serial':          serial,
          'status':          'completed',
          'completedAt':     fullData['completedAt'],
          'doctorName':      fullData['doctorName'],
          'doctorId':        fullData['doctorId'],
          'daysOfMedicine':  fullData['daysOfMedicine'],
          'extraCharge':     fullData['extraCharge'],
          'prescription':    medicalData,
          'dispenseStatus':  'pending',
          'campId':          fullData['campId']?.toString() ?? fullData['dispensaryId']?.toString(),
          'dispensaryTag':   fullData['dispensaryTag']?.toString(),
        },
      });
      SyncService().triggerUpload();
    } catch (e) {
      debugPrint('[DoctorPanel] Enqueue failed: $e');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 500;

      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.tab) {
            final cur     = _tabOrder.indexWhere((n) => n.hasFocus);
            final isShift = HardwareKeyboard.instance.physicalKeysPressed
                .contains(PhysicalKeyboardKey.shiftLeft);
            final next = isShift
                ? (cur <= 0 ? _tabOrder.length - 1 : cur - 1)
                : (cur + 1) % _tabOrder.length;
            _tabOrder[next].requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: EdgeInsets.all(compact ? 12 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.selectedPatientData?['isVitalsOnly'] == true ||
                  widget.selectedPatientData?['vitalsOnly'] == true) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF3B0764) : Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isDark ? const Color(0xFF9333EA) : Colors.purple.shade300, width: 1.5),
                  ),
                  child: Row(children: [
                    Icon(Icons.monitor_heart, color: isDark ? const Color(0xFFD8B4FE) : Colors.purple.shade700, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🩺 Vitals Inspection Only',
                            style: TextStyle(
                              color: isDark ? const Color(0xFFF5D0FE) : Colors.purple.shade900,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'This patient has come only for vitals inspection. No medicines or lab tests are required. Simply save to complete.',
                            style: TextStyle(
                              color: isDark ? const Color(0xFFE9D5FF) : Colors.purple.shade800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ]),
                ),
              ],

              // ── Quick Disease Presets / Templates ─────────────────────
              _buildQuickTemplatesBar(compact, isDark),

              // ── Patient condition ─────────────────────────────────────
              Row(children: [
                Icon(Icons.description, color: _teal, size: compact ? 18 : 22),
                SizedBox(width: compact ? 6 : 10),
                Text('Patient Condition',
                    style: TextStyle(
                        fontSize: compact ? 15 : 18, fontWeight: FontWeight.bold, color: _teal)),
              ]),
              const SizedBox(height: 8),
              TextField(
                focusNode: _complaintFocus,
                controller: widget.complaintController,
                maxLines: 2,
                style: TextStyle(fontSize: compact ? 13 : 15, color: isDark ? Colors.white : Colors.black87),
                decoration: InputDecoration(
                  hintText: "Describe patient's condition...",
                  hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF0F172A) : Colors.green[50],
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: Color(0xFF334155)) : BorderSide.none),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: Color(0xFF334155)) : BorderSide.none),
                  contentPadding: const EdgeInsets.all(12), isDense: compact,
                ),
              ),
              SizedBox(height: compact ? 12 : 16),

              // ── Diagnosis ─────────────────────────────────────────────
              Row(children: [
                Icon(Icons.medical_services, color: _teal, size: compact ? 18 : 22),
                SizedBox(width: compact ? 6 : 10),
                Text('Diagnosis',
                    style: TextStyle(
                        fontSize: compact ? 15 : 18, fontWeight: FontWeight.bold, color: _teal)),
              ]),
              const SizedBox(height: 8),
              TextField(
                focusNode: _diagnosisFocus,
                controller: widget.diagnosisController,
                maxLines: 2,
                style: TextStyle(fontSize: compact ? 13 : 15, color: isDark ? Colors.white : Colors.black87),
                decoration: InputDecoration(
                  hintText: 'Enter diagnosis...',
                  hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF0F172A) : Colors.green[50],
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: Color(0xFF334155)) : BorderSide.none),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: Color(0xFF334155)) : BorderSide.none),
                  contentPadding: const EdgeInsets.all(12), isDense: compact,
                ),
              ),
              SizedBox(height: compact ? 12 : 20),

              // ── Days selector ─────────────────────────────────────────
              _buildDaysSelector(compact),
              SizedBox(height: compact ? 12 : 20),
              const Divider(height: 1),
              SizedBox(height: compact ? 12 : 20),

              // ── Medicine search / picker ───────────────────────────────
              _sectionHeader(
                'Medicines',
                FontAwesomeIcons.pills,
                compact: compact,
                action: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const FaIcon(FontAwesomeIcons.arrowsRotate, size: 14, color: _teal),
                      tooltip: 'Refresh Inventory',
                      onPressed: () async {
                        await LocalStorageService.downloadInventory(widget.branchId);
                        _loadInventory();
                      },
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton.icon(
                      onPressed: () => _addMedicineDialog(),
                      icon: const Icon(Icons.add, size: 14),
                      label: Text('Custom', style: TextStyle(fontSize: compact ? 11 : 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? const Color(0xFF2DD4BF) : _teal,
                        side: BorderSide(color: isDark ? const Color(0xFF2DD4BF) : _teal, width: 1),
                        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ),

              Focus(
                focusNode: _searchFocusNode,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.enter ||
                       event.logicalKey == LogicalKeyboardKey.space)) {
                    _showMedicineSelectionDialog();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (fCtx) {
                    final isFocused = Focus.of(fCtx).hasFocus;
                    return InkWell(
                      onTap: _showMedicineSelectionDialog,
                      borderRadius: BorderRadius.circular(16),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 10 : 12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isFocused ? _teal : (isDark ? const Color(0xFF334155) : _teal.withValues(alpha: 0.35)),
                            width: isFocused ? 2 : 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _teal.withValues(alpha: isFocused ? 0.15 : 0.05),
                              blurRadius: isFocused ? 10 : 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _teal.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.search, color: _teal, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Search & Select Medicines...',
                                    style: TextStyle(
                                      fontSize: compact ? 13 : 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? Colors.white : Colors.grey.shade800,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Click to search inventory by name, formula, or type',
                                    style: TextStyle(
                                      fontSize: compact ? 10.5 : 11.5,
                                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _teal,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Browse',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 10),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 12),

              // ── Medicine chips ────────────────────────────────────────
              _buildMedicineSection(
                  'Inventory Medicines', FontAwesomeIcons.pills,
                  widget.prescriptions.where((m) => m['inventoryId'] != null && !_isInjectionOrDrip(m)).toList(),
                  _teal, compact: compact),
              _buildMedicineSection(
                  'Inventory Injectables', FontAwesomeIcons.syringe,
                  widget.prescriptions.where((m) => m['inventoryId'] != null && _isInjectionOrDrip(m)).toList(),
                  _orange, compact: compact),
              _buildMedicineSection(
                  'Custom Medicines', FontAwesomeIcons.prescriptionBottle,
                  widget.prescriptions.where((m) => m['inventoryId'] == null && !_isInjectionOrDrip(m)).toList(),
                  _blueGrey, compact: compact),
              _buildMedicineSection(
                  'Custom Injectables', FontAwesomeIcons.syringe,
                  widget.prescriptions.where((m) => m['inventoryId'] == null && _isInjectionOrDrip(m)).toList(),
                  _orange, compact: compact),

              const Divider(height: 1),
              SizedBox(height: compact ? 12 : 20),

              // ── Lab tests ─────────────────────────────────────────────
              _sectionHeader(widget.isPhysiotherapist ? 'Physiotherapies' : 'Lab Tests', widget.isPhysiotherapist ? FontAwesomeIcons.personWalking : FontAwesomeIcons.flask,
                  compact: compact,
                  action: IconButton(
                    icon: Icon(Icons.add_circle_outline, color: _teal, size: compact ? 20 : 24),
                    onPressed: _addCustomLabTest,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  )),

              Wrap(
                spacing: compact ? 6 : 10, runSpacing: compact ? 6 : 10,
                children: _currentQuickList.map((t) {
                  final selected = _selectedQuickTests.contains(t);
                  return FilterChip(
                    label: Text(t, style: TextStyle(fontSize: compact ? 11 : 13)),
                    selected: selected,
                    selectedColor: _teal,
                    backgroundColor: isDark ? const Color(0xFF0F172A) : null,
                    side: BorderSide(color: selected ? _teal : (isDark ? const Color(0xFF334155) : Colors.grey.shade300)),
                    checkmarkColor: Colors.white,
                    labelStyle: TextStyle(color: selected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : Colors.black87)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      setState(() {
                        if (selected) {
                          _selectedQuickTests.remove(t);
                          widget.labResults.removeWhere((l) => l['name'] == t);
                        } else {
                          _selectedQuickTests.add(t);
                          if (!widget.labResults.any((l) => l['name'] == t)) {
                            widget.labResults.add({'name': t});
                          }
                        }
                      });
                    },
                  );
                }).toList(),
              ),

              if (widget.labResults.any((l) => !_currentQuickList.contains(l['name']))) ...[
                const SizedBox(height: 12),
                Text(widget.isPhysiotherapist ? 'Custom Physiotherapies' : 'Custom Tests',
                    style: TextStyle(
                        fontSize: compact ? 13 : 16, fontWeight: FontWeight.bold, color: _teal)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: widget.labResults
                      .where((l) => !_currentQuickList.contains(l['name']))
                      .map((l) => Chip(
                            label: Text(l['name'], style: TextStyle(fontSize: compact ? 11 : 13)),
                            backgroundColor: Colors.orange.shade600,
                            labelStyle: const TextStyle(color: Colors.white),
                            onDeleted: () => setState(() => widget.labResults.remove(l)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ))
                      .toList(),
                ),
              ],

              SizedBox(height: compact ? 16 : 30),
              const Divider(height: 1),
              SizedBox(height: compact ? 16 : 30),

              // ── Save button ───────────────────────────────────────────
              Builder(builder: (_) {
                final isVitalsOnly = widget.selectedPatientData?['isVitalsOnly'] == true ||
                    widget.selectedPatientData?['vitalsOnly'] == true;
                return SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    focusNode: _saveButtonFocus,
                    onPressed: widget.isSaving ? null : _savePrescriptionHiveFirst,
                    icon: widget.isSaving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(isVitalsOnly ? Icons.check_circle_outline : Icons.save, color: Colors.white),
                    label: Text(
                      widget.isSaving
                          ? 'Saving...'
                          : isVitalsOnly
                              ? 'Save & Complete Vitals Inspection'
                              : _extraCharge > 0
                                  ? 'Save Prescription  (+PKR $_extraCharge)'
                                  : 'Save Prescription',
                      style: TextStyle(
                          fontSize: compact ? 14 : 16,
                          fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isVitalsOnly ? Colors.purple.shade700 : _teal,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                          horizontal: 24, vertical: compact ? 14 : 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                      elevation: 6,
                    ),
                  ),
                );
              }),
              const SizedBox(height: 20),
            ],
          ),
        ),
      );
    });
  }

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }
}
