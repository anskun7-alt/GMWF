// lib/pages/dispensary/doctor/doctor_right_panel.dart (updated)

import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/quota_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/services/prescription_template_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/design/design_system.dart';

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
  final Function(Map<String, dynamic>)? onAddMedicine;
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
    this.onAddMedicine,
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
  /// When this patient was opened here: remote prescription copies saved before it never
  /// replace the doctor's on-screen list.
  DateTime _openedAt = DateTime.now();
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

  static const Color _teal     = SoftPalette.teal600;
  static const Color _orange   = SoftPalette.orange350;
  static const Color _blueGrey = SoftPalette.slate600;

  // Dose pill colours (teal ramp)
  static const Color _dosePillBg     = SoftPalette.teal100m;
  static const Color _dosePillBorder = SoftPalette.emerald350;
  static const Color _dosePillText   = SoftPalette.emerald600;

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
  bool _showMedicinesForVitalsOnly = false;

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
    if (oldWidget.serialId != widget.serialId) _openedAt = DateTime.now();
    if (oldWidget.serialId != widget.serialId ||
        oldWidget.selectedPatientData != widget.selectedPatientData ||
        oldWidget.branchId != widget.branchId) {
      setState(() {
        _daysOfMedicine = _resolveDaysOfMedicine();
        _showMedicinesForVitalsOnly = false;
      });
      _loadInventory();
    } else if (_allInventory.isNotEmpty && widget.prescriptions.any((m) => m['_repeat'] == true)) {
      // Repeated while the panel stayed in place (e.g. from the full history page).
      _relinkRepeatedMeds();
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
      _debouncedStockBoxReload();
      return;
    } else if (type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
      final mId = (data['id'] ?? data['medicineId'])?.toString();
      if (mId != null) LocalStorageService.deleteLocalStockItem(mId);
      _debouncedStockBoxReload();
      return;
    } else if (type == 'save_prescription_template' || type == 'delete_prescription_template') {
      _loadPrescriptionTemplates();
      return;
    }

    // Rebuild reserved quantities when any dispense or prescription
    // save happens on the LAN, so stock counts stay accurate across patients.
    if (type == 'dispense_completed' || type == RealtimeEvents.savePrescription) {
      _buildReservedQuantities();
    }

    final serial = data['serial'] as String?;
    if (serial == null || serial != widget.serialId) return;

    // RealtimeManager's stream events are {'event_type','data','decoded'}: the sender id and the
    // catch-up flags live on 'decoded'. Reading event['senderId'] / event['_serverPush'] never
    // matched, so this panel treated its own echoes and every catch-up as fresh edits.
    final decoded = event['decoded'] is Map ? event['decoded'] as Map : const {};
    final myId = RealtimeManager().clientId;
    final senderId = (decoded['_clientId'] ?? event['_clientId'] ?? event['senderId'] ?? event['clientId'] ?? '').toString();
    if (senderId.isNotEmpty && myId != null && senderId == myId) return;
    final isCatchUpCopy = decoded['_serverPush'] == true ||
        decoded['isCatchUp'] == true ||
        decoded['_isReplay'] == true ||
        decoded['_resent'] == true ||
        decoded['_outboxResend'] == true;

    if (type == RealtimeEvents.saveEntry) {
      if (mounted) setState(() {});
    }

    if (type == RealtimeEvents.savePrescription) {
      final incomingPrescriptions = (data['prescriptions'] ?? data['medicines'] ?? data['items']) as List<dynamic>?;
      // Never let an empty remote event wipe out medicines the doctor has on screen
      if (incomingPrescriptions == null && widget.prescriptions.isNotEmpty) return;
      if (incomingPrescriptions != null && incomingPrescriptions.isEmpty && widget.prescriptions.isNotEmpty) return;
      // While the doctor has medicines on screen, only an edit saved elsewhere after this
      // patient was opened may replace them. A catch-up copy or another desk's reconnect replay
      // of the earlier prescription used to replace the list, wiping medicines just picked.
      if (widget.prescriptions.isNotEmpty) {
        if (isCatchUpCopy) return;
        final savedAt = DateTime.tryParse((data['updatedAt'] ?? data['completedAt'] ?? '').toString());
        if (savedAt == null || !savedAt.isAfter(_openedAt)) return;
      }

      setState(() {
        if (data['complaint'] != null || data['condition'] != null) {
          widget.complaintController.text = data['complaint'] ?? data['condition'] ?? '';
        }
        if (data['diagnosis'] != null) {
          widget.diagnosisController.text = data['diagnosis'] ?? '';
        }
        if (incomingPrescriptions != null) {
          widget.prescriptions
            ..clear()
            ..addAll(
              incomingPrescriptions
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(),
            );
        }
        final incomingLabs = (data['labResults'] ?? data['labTests'] ?? data['tests']) as List<dynamic>?;
        if (incomingLabs != null) {
          widget.labResults
            ..clear()
            ..addAll(
              incomingLabs
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(),
            );
          _selectedQuickTests
            ..clear()
            ..addAll(
              widget.labResults
                  .map((l) => l['name']?.toString() ?? '')
                  .where(_currentQuickList.contains),
            );
        }
        final d = data['daysOfMedicine'];
        if (d is int && d >= 1 && d <= 3) _daysOfMedicine = d;
      });
      if (!isCatchUpCopy && mounted) {
        Flushbar(
          message: 'Prescription updated in realtime',
          backgroundColor: SoftPalette.blue500,
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

  // ── Deterministic Medicine Sorting Hierarchy ─────────────────────────────
  // Order: 1. Name/Formula (A-Z) -> 2. Form/Type Priority -> 3. Dose (numeric ascending) -> 4. ID tiebreaker
  static int _getTypeSortPriority(String type) {
    final t = type.toLowerCase().trim();
    if (t.contains('tab')) return 1;          // 1. Tablets
    if (t.contains('cap')) return 2;          // 2. Capsules
    if (t.contains('syp') || t.contains('syrup')) return 3; // 3. Syrups
    if (t.contains('susp')) return 4;         // 4. Suspensions
    if (t.contains('drop')) return 5;         // 5. Drops
    if (t.contains('inj') || t.contains('injection')) return 6; // 6. Injections
    if (t.contains('inf') || t.contains('infusion') || t.contains('drip')) return 7; // 7. Infusions & Drips
    if (t.contains('inhal')) return 8;        // 8. Inhalers
    if (t.contains('cream') || t.contains('ointment') || t.contains('gel')) return 9; // 9. Topicals
    if (t.contains('sachet')) return 10;      // 10. Sachets
    return 11;                                // 11. Others
  }

  static double? _parseDoseNumber(String dose) {
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(dose);
    if (match != null) {
      return double.tryParse(match.group(1)!);
    }
    return null;
  }

  static int _compareDoses(String doseA, String doseB) {
    if (doseA == doseB) return 0;
    if (doseA.isEmpty) return 1;
    if (doseB.isEmpty) return -1;

    final numA = _parseDoseNumber(doseA);
    final numB = _parseDoseNumber(doseB);
    if (numA != null && numB != null && numA != numB) {
      return numA.compareTo(numB);
    }
    return doseA.compareTo(doseB);
  }

  static void _sortMedicinesDeterministic(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      // 1. Primary: Medicine Name / Formula (alphabetical)
      final na = (a['name'] ?? a['formula'] ?? '').toString().toLowerCase().trim();
      final nb = (b['name'] ?? b['formula'] ?? '').toString().toLowerCase().trim();
      final nameCmp = na.compareTo(nb);
      if (nameCmp != 0) return nameCmp;

      // 2. Secondary: Dosage Form / Type Priority (Tab -> Cap -> Syp -> Susp -> Drop -> Inj -> Inf -> Other)
      final typeA = _getMedicineType(a);
      final typeB = _getMedicineType(b);
      final prioA = _getTypeSortPriority(typeA);
      final prioB = _getTypeSortPriority(typeB);
      if (prioA != prioB) return prioA.compareTo(prioB);

      // If same priority number, sort type name string alphabetically
      final typeCmp = typeA.toLowerCase().compareTo(typeB.toLowerCase());
      if (typeCmp != 0) return typeCmp;

      // 3. Tertiary: Strength / Dose (Numeric ascending e.g. 100 < 250 < 500)
      final doseA = _getMedicineDose(a).toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final doseB = _getMedicineDose(b).toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final doseCmp = _compareDoses(doseA, doseB);
      if (doseCmp != 0) return doseCmp;

      // 4. Quaternary: Deterministic tie-breaker by ID / Code
      final idA = (a['id'] ?? a['code'] ?? a['barcode'] ?? '').toString();
      final idB = (b['id'] ?? b['code'] ?? b['barcode'] ?? '').toString();
      return idA.compareTo(idB);
    });
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

    // Fallback 1: If camp-filtered items are empty, fallback to branch-wide stock (ignore camp filter)
    if (localItems.isEmpty) {
      localItems = LocalStorageService.getAllLocalStockItems(
        branchId: widget.branchId,
        filterByCamp: false,
      ).where((m) => !_isSyringeItem(m)).toList();
    }

    // Fallback 2: If branchId matching was too restrictive, get all local stock items across boxes
    if (localItems.isEmpty) {
      localItems = LocalStorageService.getAllLocalStockItems(
        filterByCamp: false,
      ).where((m) => !_isSyringeItem(m)).toList();
    }

    // Fallback 3: MasterProforma catalog items so doctor can ALWAYS prescribe regardless of stock box status
    if (localItems.isEmpty && _allInventory.isEmpty) {
      final proforma = MasterProformaService.getAllItems().where((m) => !_isSyringeItem(m)).toList();
      for (final p in proforma) {
        localItems.add({
          'id': p['code'] ?? p['id'] ?? 'cat_${p['formula'] ?? p['name']}',
          'name': p['formula'] ?? p['name'] ?? '',
          'formula': p['formula'] ?? '',
          'type': p['type'] ?? 'Tablet',
          'dose': p['dose'] ?? '',
          'quantity': 0,
        });
      }
    }

    if (localItems.isEmpty && _allInventory.isEmpty) {
      // Auto-heal: If local stock was deleted or is empty, restore directly from Firestore
      LocalStorageService.downloadInventory(widget.branchId, forceFull: true).then((_) {
        if (mounted) {
          final restored = LocalStorageService.getAllLocalStockItems(
            branchId: widget.branchId,
            filterByCamp: false,
          ).where((m) => !_isSyringeItem(m)).toList();
          if (restored.isNotEmpty) {
            _loadInventory(overrideCamp);
          }
        }
      }).catchError((_) {});
    }

    // If localItems is empty but we already have loaded inventory in memory, don't wipe it out
    if (localItems.isEmpty && _allInventory.isNotEmpty) {
      final reserved = await _computeReservedQuantities();
      if (mounted) {
        setState(() => _reservedQuantities = reserved);
        _activeDialogSetState?.call(() {});
      }
      return;
    }

    final Map<String, List<Map<String, dynamic>>> grouped = {};

    for (final s in localItems) {
      final item = Map<String, dynamic>.from(s);
      final rawName = (item['name'] ?? item['formula'] ?? item['medicineName'] ?? '').toString().trim();
      final rawFormula = (item['formula'] ?? '').toString().trim();

      // Guard: Skip corrupt or phantom items with empty names so ghost row never appears
      if (rawName.isEmpty || rawName.toLowerCase() == 'null') {
        continue;
      }

      // Resolve and save clean medicine type and dose from raw data BEFORE brand cleaning strips them
      final resolvedType = _getMedicineType(item);
      item['type'] = resolvedType;

      final resolvedDose = _getMedicineDose(item);
      if (resolvedDose.isNotEmpty) {
        item['dose'] = resolvedDose;
      }

      final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
      if (!isCustom) {
        item['name'] = MasterProformaService.cleanBrandToFormula(rawName);
        if (rawFormula.isNotEmpty) {
          item['formula'] = MasterProformaService.cleanBrandToFormula(rawFormula);
        }
      }
      item['quantity'] = item['quantity'] ?? item['stock'] ?? 0;

      final cleanName = (item['name'] ?? item['formula'] ?? '').toString().trim().toLowerCase();
      if (cleanName.isEmpty || cleanName == 'null') {
        continue;
      }
      final cleanType = (item['type'] ?? '').toString().trim().toLowerCase();
      final cleanDose = (item['dose'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final groupKey = '$cleanName|$cleanType|$cleanDose';

      grouped.putIfAbsent(groupKey, () => []).add(item);
    }

    final List<Map<String, dynamic>> combined = [];

    for (final entry in grouped.entries) {
      final batches = entry.value;

      // FEFO Sort: Earliest expiry date first, invalid/missing dates last, with deterministic ID tiebreaker
      batches.sort((a, b) {
        final expA = MasterProformaService.parseExpiryDate(a['expiryDate'] ?? a['expiry'], (a['id'] ?? a['medicineId'])?.toString());
        final expB = MasterProformaService.parseExpiryDate(b['expiryDate'] ?? b['expiry'], (b['id'] ?? b['medicineId'])?.toString());
        final expCmp = expA.compareTo(expB);
        if (expCmp != 0) return expCmp;
        final idA = (a['id'] ?? a['medicineId'] ?? '').toString();
        final idB = (b['id'] ?? b['medicineId'] ?? '').toString();
        return idA.compareTo(idB);
      });

      // Aggregate total quantity across all batches
      double totalQty = 0;
      final List<String> batchIds = [];
      for (final b in batches) {
        final q = b['quantity'];
        final numQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
        totalQty += numQty;

        final bId = (b['id'] ?? b['medicineId'] ?? b['docId'])?.toString().trim();
        if (bId != null && bId.isNotEmpty && !batchIds.contains(bId)) {
          batchIds.add(bId);
        }
      }

      // Pick earliest batch with stock > 0, or default to earliest batch overall
      final nonZeroBatch = batches.firstWhere(
        (b) {
          final q = b['quantity'];
          final numQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          return numQty > 0;
        },
        orElse: () => batches.first,
      );

      final primary = Map<String, dynamic>.from(nonZeroBatch);
      primary['quantity'] = totalQty.toInt() == totalQty ? totalQty.toInt() : totalQty;
      primary['_batches'] = batches;
      primary['_batchIds'] = batchIds;
      primary['id'] = nonZeroBatch['id'] ?? nonZeroBatch['medicineId'] ?? (batchIds.isNotEmpty ? batchIds.first : 'unknown');

      final dose = _getMedicineDose(primary);
      if (dose.isNotEmpty && (primary['dose'] == null || primary['dose'].toString().trim().isEmpty)) {
        primary['dose'] = dose;
      }

      combined.add(primary);
    }

    // Rock-solid deterministic sort: Name -> Form/Type -> Dose -> ID
    _sortMedicinesDeterministic(combined);

    final reserved = await _computeReservedQuantities();

    if (mounted) {
      setState(() {
        _allInventory = combined;
        _reservedQuantities = reserved;
        _relinkRepeatedMeds();
      });
      _activeDialogSetState?.call(() {});
    }
  }

  /// Medicines copied from an earlier visit (Repeat / Apply) are marked '_repeat' by the
  /// doctor screen. Their inventory ids point at the batch used back then, which may be used
  /// up, deleted or from another camp, and records saved by older versions have no id at
  /// all, so each one is matched to today's stock here; without that they all showed up as
  /// custom medicines. Only a medicine with no match in this camp's stock stays custom.
  void _relinkRepeatedMeds() {
    if (_allInventory.isEmpty) return; // stock not loaded yet: tried again on the next load
    final realStock = _allInventory.where((inv) => !(inv['id']?.toString() ?? '').startsWith('cat_')).toList();
    if (realStock.isEmpty) return; // only the catalog fallback is loaded so far

    String clean(Object? v) => MasterProformaService.cleanBrandToFormula((v ?? '').toString())
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    String cleanDose(Object? v) => (v ?? '').toString().toLowerCase().replaceAll(RegExp(r'\s+'), '');

    Map<String, dynamic>? single(Iterable<Map<String, dynamic>> found) => found.length == 1 ? found.first : null;

    for (final med in widget.prescriptions) {
      if (med['_repeat'] != true) continue;
      med.remove('_repeat');

      final oldId = (med['inventoryId'] ?? med['medicineId'])?.toString().trim() ?? '';
      Map<String, dynamic>? match;

      // 1. The batch it was given from, or another batch of the same medicine.
      if (oldId.isNotEmpty) {
        match = realStock.where((inv) =>
            inv['id']?.toString() == oldId ||
            ((inv['_batchIds'] as List?)?.any((b) => b.toString() == oldId) ?? false)).firstOrNull;
      }

      // 2. Same medicine by name/formula, form and strength; then by name and form, or
      //    name alone, but only when that leaves exactly one medicine.
      if (match == null) {
        final names = {clean(med['name']), clean(med['formula'])}..remove('');
        final type = (med['type'] ?? '').toString().toLowerCase().trim();
        final dose = cleanDose(_getMedicineDose(med));
        final byName = realStock.where((inv) => names.contains(clean(inv['name'])) || names.contains(clean(inv['formula']))).toList();
        bool sameType(Map<String, dynamic> inv) => type.isEmpty || (inv['type'] ?? '').toString().toLowerCase().trim() == type;
        bool sameDose(Map<String, dynamic> inv) => dose.isEmpty || cleanDose(_getMedicineDose(inv)) == dose;
        match = single(byName.where((inv) => sameType(inv) && sameDose(inv))) ??
            single(byName.where(sameType)) ??
            single(byName.where(sameDose)) ??
            single(byName);
      }

      if (match == null) {
        // Not stocked in this camp: a custom medicine, never a link to a batch that is gone.
        med.remove('inventoryId');
        med.remove('medicineId');
        continue;
      }

      final id = match['id']?.toString();
      med['inventoryId'] = id;
      med['medicineId'] = id;
      med['name'] = match['name'] ?? med['name'];
      med['displayName'] = med['name'];
      if ((match['formula'] ?? '').toString().isNotEmpty) med['formula'] = match['formula'];
      med['type'] = _getMedicineType(match);
      final invDose = _getMedicineDose(match);
      if (invDose.isNotEmpty) med['dose'] = invDose;

      // Stock flags from the earlier visit no longer apply; set them from today's stock.
      med.remove('isExternal');
      med.remove('outOfStock');
      med.remove('stockShortage');
      final q = match['quantity'];
      final stock = (q is num ? q.toInt() : int.tryParse(q?.toString() ?? '') ?? 0) - _getReservedCount(match);
      if (stock <= 0) {
        med['isExternal'] = true;
        med['outOfStock'] = true;
      }
    }
  }

  // ── FIX: Scan ALL pending prescriptions in Hive and sum up reserved qty ──
  // A prescription is "pending" (reserved) when:
  //   • it exists in the prescriptions box (doctor has saved it), AND
  //   • the corresponding entry in entriesBox does NOT have
  //     dispenseStatus == 'dispensed'.
  // We skip the current patient's serial so their own session counts
  // are handled separately by _getAvailableStock().
  Future<Map<String, int>> _computeReservedQuantities() async {
    final Map<String, int> reserved = {};

    try {
      final prescBox   = await LocalStorageService.ensureBoxOpen(LocalStorageService.prescriptionsBox);
      final entriesBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final mySerial   = widget.serialId.trim().toLowerCase();
      final normBranch = widget.branchId.trim().toLowerCase();
      final todayKey   = CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey;

      // Fast set of serials and keys that are ALREADY dispensed, completed, or cancelled
      final Set<String> dispensedOrFinishedSerials = {};
      for (final eKey in entriesBox.keys) {
        final entryVal = entriesBox.get(eKey);
        if (entryVal is Map) {
          final dStat = (entryVal['dispenseStatus'] ?? '').toString().toLowerCase().trim();
          final sStat = (entryVal['status'] ?? '').toString().toLowerCase().trim();
          if (dStat == 'dispensed' || sStat == 'completed' || dStat == 'cancelled' || sStat == 'cancelled') {
            final eStr = eKey.toString().toLowerCase().trim();
            dispensedOrFinishedSerials.add(eStr);
            if (eStr.startsWith('$normBranch-')) {
              dispensedOrFinishedSerials.add(eStr.substring(normBranch.length + 1).trim());
            }
            final sVal = (entryVal['serial'] ?? entryVal['id'])?.toString().toLowerCase().trim();
            if (sVal != null && sVal.isNotEmpty) {
              dispensedOrFinishedSerials.add(sVal);
              if (sVal.startsWith('$normBranch-')) {
                dispensedOrFinishedSerials.add(sVal.substring(normBranch.length + 1).trim());
              }
            }
          }
        }
      }

      for (final key in prescBox.keys) {
        final raw = prescBox.get(key);
        if (raw is! Map) continue;

        final prescSerialRaw = (raw['serial'] ?? raw['id'] ?? '').toString();
        final effectiveDatePrefix = CampSessionService.getDateKeyFromSerial(prescSerialRaw);
        if (effectiveDatePrefix.isNotEmpty) {
          if (effectiveDatePrefix != todayKey) continue;
        } else {
          // If serial doesn't have a date prefix, check createdAt/timestamp so ancient test records don't lock stock
          final created = raw['createdAt'] ?? raw['timestamp'] ?? raw['date'];
          if (created != null) {
            final dt = DateTime.tryParse(created.toString());
            if (dt != null) {
              final dtKey = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
              if (dtKey != todayKey) continue;
            }
          }
        }

        final presc = Map<String, dynamic>.from(raw);

        // Skip the current patient — their session is handled in _getAvailableStock
        final prescSerial = prescSerialRaw.trim().toLowerCase();
        if (prescSerial == mySerial) continue;

        var cleanSerial = prescSerial;
        if (cleanSerial.startsWith('$normBranch-')) {
          cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
        }

        // Check if already dispensed / finished in entriesBox
        if (dispensedOrFinishedSerials.contains(prescSerial) ||
            dispensedOrFinishedSerials.contains(cleanSerial) ||
            dispensedOrFinishedSerials.contains('$normBranch-$cleanSerial') ||
            dispensedOrFinishedSerials.contains(key.toString().toLowerCase().trim())) {
          continue;
        }

        // Also check dispenseStatus on the prescription itself
        final dispenseStatusOnPresc =
            (presc['dispenseStatus'] ?? presc['status'] ?? '').toString().toLowerCase();
        if (dispenseStatusOnPresc == 'dispensed' ||
            dispenseStatusOnPresc == 'completed' ||
            dispenseStatusOnPresc == 'cancelled') {
          continue;
        }

        // Sum up quantities for each inventory medicine
        final meds = presc['prescriptions'];
        if (meds is! List) continue;

        for (final med in meds) {
          if (med is! Map) continue;
          final inventoryId = (med['inventoryId'] ?? '').toString().trim();
          if (inventoryId.isEmpty) continue;

          final medQty = med['quantity'];
          final qty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
          final rawDays = presc['daysOfMedicine'];
          final days = (rawDays is num ? rawDays.toInt() : int.tryParse(rawDays?.toString() ?? '1') ?? 1);
          final type = (med['type'] ?? '').toString().toLowerCase();
          final name = (med['name'] ?? '').toString().toLowerCase();
          final isSyrup = type.contains('syrup') || type.contains('syp') || type.contains('susp') ||
              name.contains('syp') || name.contains('syrup');
          final isInj = type.contains('injection') || type.contains('inj') ||
              type.contains('drip') || type.contains('syringe') ||
              type.contains('nebulization');
          final effectiveQty = isSyrup ? 1 : (isInj ? qty : qty * days);

          reserved[inventoryId] = (reserved[inventoryId] ?? 0) + effectiveQty;
        }
      }
    } catch (e) {
      debugPrint('[DoctorPanel] _computeReservedQuantities error: $e');
    }

    return reserved;
  }

  Future<void> _buildReservedQuantities() async {
    final reserved = await _computeReservedQuantities();
    if (mounted) {
      setState(() => _reservedQuantities = reserved);
      _activeDialogSetState?.call(() {});
    }
  }

  void _debouncedStockBoxReload() {
    _stockBoxDebounce?.cancel();
    _stockBoxDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _loadInventory();
    });
  }

  @override
  void dispose() {
    debugPrint('[DoctorPanel] panel State disposed (serial ${widget.serialId})');
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

  /// Single source of truth for how a prescribed medicine is labelled everywhere
  /// (dialog chips, panel chips): "<abbrev> <name> ×<qty> (<timing>)".
  String _medChipLabel(Map<String, dynamic> m) {
    final abbrev = _getMedAbbrev(m);
    final name = _getFormattedMedicine(m);
    final timing = (m['timing'] ?? '').toString().trim();
    final qty = m['quantity'] ?? 1;
    final prefix = abbrev.isNotEmpty && !name.toLowerCase().startsWith(abbrev.toLowerCase()) ? '$abbrev ' : '';
    return '$prefix$name ×$qty${timing.isNotEmpty ? " ($timing)" : ""}';
  }

  /// Text for the "Added (...)" badge on a medicine row: the timing for timed medicines,
  /// otherwise the real quantity (never a hard-coded "1 unit").
  String _medAddedText(Map<String, dynamic>? m) {
    if (m == null) return 'Added';
    final timing = (m['timing'] ?? '').toString().trim();
    if (timing.isNotEmpty) return 'Added ($timing)';
    final q = m['quantity'] ?? 1;
    return 'Added ($q ${q == 1 ? "unit" : "units"})';
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

  static bool _isInventoryMed(Map<String, dynamic> m) {
    final id = (m['inventoryId'] ?? m['medicineId'])?.toString().trim();
    return id != null && id.isNotEmpty && id != 'null' && id != 'unknown';
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
      return (bg: SoftPalette.gray100, border: SoftPalette.slate200, text: SoftPalette.slate550);
    }
    final t = type.toLowerCase();
    if (t.contains('tab')) {
      return (bg: SoftPalette.slate100, border: SoftPalette.blue300, text: SoftPalette.blue550); // Blue
    } else if (t.contains('cap')) {
      return (bg: SoftPalette.violet100m, border: SoftPalette.violet300, text: SoftPalette.violet550); // Purple
    } else if (t.contains('inj')) {
      return (bg: SoftPalette.red100m, border: SoftPalette.red300, text: SoftPalette.red550); // Rose/Red
    } else if (t.contains('inf') || t.contains('drip')) {
      return (bg: SoftPalette.slate50, border: SoftPalette.cyan200, text: SoftPalette.sky550); // Cyan
    } else if (t.contains('syp') || t.contains('syrup') || t.contains('susp')) {
      return (bg: SoftPalette.yellow50m, border: SoftPalette.yellow150, text: SoftPalette.orange500); // Amber
    } else if (t.contains('drop')) {
      return (bg: SoftPalette.emerald50, border: SoftPalette.emerald200, text: SoftPalette.emerald550); // Emerald
    }
    return (bg: SoftPalette.gray50, border: SoftPalette.slate200, text: SoftPalette.slate600); // Slate
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

  static String _getMedicineDose(Map<String, dynamic> med) {
    final d = (med['dose'] ?? med['dosage'] ?? '').toString().trim();
    if (d.isNotEmpty && d.toLowerCase() != 'null') return d;
    final n = (med['name'] ?? '').toString();
    final reg = RegExp(r'(\d+(?:\.\d+)?\s*(?:mg|g|ml|mcg|iu|%))', caseSensitive: false);
    final m = reg.firstMatch(n);
    if (m != null) return m.group(1)!.trim();
    return '';
  }

  int _getReservedCount(Map<String, dynamic>? inventoryMed) {
    if (inventoryMed == null) return 0;
    final batchIds = (inventoryMed['_batchIds'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
    final id = inventoryMed['id']?.toString() ?? '';
    if (id.isNotEmpty) batchIds.add(id);
    int sum = 0;
    for (final bId in batchIds) {
      sum += _reservedQuantities[bId] ?? 0;
    }
    return sum;
  }

  bool _medicineExists(String name, {String? inventoryId, String? type, String? dose}) {
    final lower = name.trim().toLowerCase();
    final candType = (type ?? '').toLowerCase().trim();
    final candDose = (dose ?? '').toLowerCase().trim();
    return widget.prescriptions.any((m) {
      if (inventoryId != null && m['inventoryId'] != null) {
        return m['inventoryId'].toString() == inventoryId;
      }
      final mName = (m['name'] ?? '').toString().trim().toLowerCase();
      final mType = (m['type'] ?? '').toString().toLowerCase().trim();
      final mDose = (m['dose'] ?? m['dosage'] ?? '').toString().toLowerCase().trim();
      if (mName == lower) {
        if (candType.isNotEmpty && mType.isNotEmpty && candType != mType) {
          return false; // Different forms/types (e.g. Tablet vs Syrup vs Injection)
        }
        if (candDose.isNotEmpty && mDose.isNotEmpty && candDose != mDose) {
          return false; // Different strengths/doses (e.g. 20 mg vs 500 mg)
        }
        return true;
      }
      return false;
    });
  }

  // ── FIX: Available stock = total stock − reserved by other patients
  //         − already added in this session across all consolidated batches
  int _getAvailableStock(Map<String, dynamic>? inventoryMed) {
    if (inventoryMed == null) return 999999;

    final invQty = inventoryMed['quantity'];
    final totalStock = (invQty is num ? invQty.toInt() : int.tryParse(invQty?.toString() ?? '') ?? 0);
    
    final batchIds = (inventoryMed['_batchIds'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
    final inventoryId = inventoryMed['id']?.toString() ?? '';
    if (inventoryId.isNotEmpty) batchIds.add(inventoryId);

    // Quantity reserved by OTHER pending patients (from Hive scan across all batch IDs)
    int reservedByOthers = 0;
    for (final bId in batchIds) {
      reservedByOthers += _reservedQuantities[bId] ?? 0;
    }

    // Quantity already added in THIS doctor session for this patient
    int sessionQty = 0;
    for (final med in widget.prescriptions) {
      final medInvId = med['inventoryId']?.toString() ?? '';
      if (batchIds.contains(medInvId)) {
        final medQty = med['quantity'];
        sessionQty += (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
      } else if (medInvId.isEmpty) {
        // Fallback for custom entries matching name, type, and dose
        final medName = (med['name'] ?? '').toString().toLowerCase().trim();
        final invName = (inventoryMed['name'] ?? '').toString().toLowerCase().trim();
        final medType = (med['type'] ?? '').toString().toLowerCase().trim();
        final invType = (inventoryMed['type'] ?? '').toString().toLowerCase().trim();
        final medDose = (med['dose'] ?? med['dosage'] ?? '').toString().toLowerCase().trim();
        final invDose = (inventoryMed['dose'] ?? inventoryMed['dosage'] ?? '').toString().toLowerCase().trim();
        if (medName == invName &&
            (medType.isEmpty || invType.isEmpty || medType == invType) &&
            (medDose.isEmpty || invDose.isEmpty || medDose == invDose)) {
          final medQty = med['quantity'];
          sessionQty += (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
        }
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
    String? stockWarningNotice;

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

    final rootNav = Navigator.of(context, rootNavigator: true);
    try {
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (dialogCtx) {
          void closeSelectionDialog() {
            if (rootNav.canPop()) {
              rootNav.pop();
            }
          }

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
            _sortMedicinesDeterministic(filteredMeds);

            final mediaQuery = MediaQuery.of(context);
            final isCompact = GBreakpoint.isMobile(context);

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
                  color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: isDark ? SoftPalette.slate700 : Colors.transparent),
                  boxShadow: [
                    BoxShadow(
                      color: SoftPalette.gray900.withValues(alpha: 0.22),
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
                          colors: [_teal, SoftPalette.teal700],
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
                              color: SoftPalette.gray50.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const FaIcon(FontAwesomeIcons.pills, color: SoftPalette.gray50, size: 18),
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
                                          color: SoftPalette.gray50,
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
                                          color: SoftPalette.gray900.withValues(alpha: 0.25),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.3), width: 0.8),
                                        ),
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            value: dialogCamp,
                                            dropdownColor: SoftPalette.teal700,
                                            icon: const Icon(Icons.arrow_drop_down, color: SoftPalette.gray50A70, size: 16),
                                            isDense: true,
                                            style: const TextStyle(color: SoftPalette.gray50, fontSize: 11.5, fontWeight: FontWeight.bold),
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
                                        color: SoftPalette.gray50.withValues(alpha: 0.22),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '$countAll Stock Items',
                                        style: const TextStyle(
                                          color: SoftPalette.gray50,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: SoftPalette.emerald350.withValues(alpha: 0.35),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.3), width: 0.6),
                                      ),
                                      child: Text(
                                        '$inStockCount In-Stock',
                                        style: const TextStyle(
                                          color: SoftPalette.gray50,
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
                                          color: SoftPalette.gray50.withValues(alpha: 0.22),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          CampSessionService.getCampLabel(dialogCamp),
                                          style: const TextStyle(
                                            color: SoftPalette.gray50,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                // Prominent Active Patient Badge
                                Builder(
                                  builder: (_) {
                                    final pData = widget.selectedPatientData;
                                    // Skip placeholder values such as '0' / 'null' that bad records carry,
                                    // so the header never reads "Prescribing for: 0".
                                    String cleanName(dynamic v) {
                                      final s = (v ?? '').toString().trim();
                                      return (s == '0' || s.toLowerCase() == 'null') ? '' : s;
                                    }
                                    final pName = [pData?['patientName'], pData?['name'], pData?['fullName']]
                                        .map(cleanName)
                                        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
                                    final pSerial = (pData?['serial'] ?? pData?['id'] ?? widget.serialId).toString().trim();
                                    final pVitals = (pData?['vitals'] is Map) ? Map<String, dynamic>.from(pData!['vitals']) : {};
                                    final pAge = (pVitals['age'] ?? pData?['age'] ?? '').toString().trim();
                                    final pGender = (pVitals['gender'] ?? pData?['gender'] ?? '').toString().trim();
                                    final qLabel = widget.queueType.isNotEmpty ? widget.queueType.toUpperCase() : (pData?['category'] ?? '').toString().trim().toUpperCase();

                                    return Container(
                                      margin: const EdgeInsets.only(top: 6),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: SoftPalette.gray900.withValues(alpha: 0.26),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: SoftPalette.gray50.withValues(alpha: 0.25), width: 0.8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.person, color: SoftPalette.gray50, size: 13),
                                          const SizedBox(width: 5),
                                          Flexible(
                                            child: Text(
                                              pName.isNotEmpty ? 'Prescribing for: $pName' : 'Active Patient',
                                              style: const TextStyle(
                                                color: SoftPalette.gray50,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (pSerial.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: SoftPalette.gray50.withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(5),
                                              ),
                                              child: Text(
                                                '#$pSerial',
                                                style: const TextStyle(color: SoftPalette.gray50, fontSize: 10.5, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                          if (pGender.isNotEmpty || pAge.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '• ${[if (pGender.isNotEmpty) pGender, if (pAge.isNotEmpty) '$pAge yrs'].join(', ')}',
                                              style: const TextStyle(color: SoftPalette.gray50A70, fontSize: 11),
                                            ),
                                          ],
                                          if (qLabel.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: SoftPalette.amber300,
                                                borderRadius: BorderRadius.circular(5),
                                              ),
                                              child: Text(
                                                qLabel,
                                                style: const TextStyle(color: SoftPalette.gray900A87, fontSize: 9.5, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const FaIcon(FontAwesomeIcons.arrowsRotate, color: SoftPalette.gray50A70, size: 15),
                            tooltip: 'Restore & Sync Inventory from Cloud',
                            onPressed: () async {
                              await LocalStorageService.downloadInventory(widget.branchId, forceFull: true);
                              await _loadInventory(dialogCamp);
                              setDialogState(() {});
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: SoftPalette.gray50),
                            tooltip: 'Close (Esc)',
                            onPressed: closeSelectionDialog,
                          ),
                        ],
                      ),
                    ),

                    // ── Search & Filter Controls ──────────────────────
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                        border: Border(bottom: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Search Box
                          TextField(
                            controller: queryCtrl,
                            autofocus: true,
                            onChanged: (_) => setDialogState(() {}),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                            decoration: InputDecoration(
                              hintText: 'Search by generic formula, name, dosage, form...',
                              hintStyle: TextStyle(fontSize: 13.5, color: isDark ? SoftPalette.slate550 : SoftPalette.gray300),
                              prefixIcon: Icon(Icons.search, color: context.adapt(_teal), size: 22),
                              suffixIcon: queryCtrl.text.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(Icons.clear, size: 18, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray350),
                                      onPressed: () {
                                        queryCtrl.clear();
                                        setDialogState(() {});
                                      },
                                    )
                                  : null,
                              filled: true,
                              fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: context.adapt(_teal), width: 2),
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
                                    color: isDark ? SoftPalette.slate350 : SoftPalette.gray350,
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
                                          color: isActive ? context.adapt(_teal).withValues(alpha: 0.25) : (isDark ? SoftPalette.slate900 : SoftPalette.gray50),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: isActive ? context.adapt(_teal) : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                                            width: isActive ? 1.2 : 0.8,
                                          ),
                                        ),
                                        child: Text(
                                          kw,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                                            color: isActive ? context.adapt(_teal) : (isDark ? SoftPalette.slate200 : SoftPalette.gray700),
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
                                      color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.teal300 : _teal),
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
                                                ? SoftPalette.gray50.withValues(alpha: 0.25)
                                                : (isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '$count',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.gray50 : SoftPalette.gray700),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    selected: isSelected,
                                    selectedColor: _teal,
                                    backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                                    labelStyle: TextStyle(
                                      color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : SoftPalette.gray700),
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                        color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
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
                          if (stockWarningNotice != null) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: stockWarningNotice!.contains('Out of Stock')
                                    ? (isDark ? SoftPalette.red800 : SoftPalette.red150m)
                                    : (isDark ? SoftPalette.orange800 : SoftPalette.yellow100),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: stockWarningNotice!.contains('Out of Stock')
                                      ? context.adapt(SoftPalette.red400)
                                      : context.adapt(SoftPalette.amber200),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    stockWarningNotice!.contains('Out of Stock')
                                        ? Icons.cancel_outlined
                                        : Icons.warning_amber_rounded,
                                    color: stockWarningNotice!.contains('Out of Stock') ? context.adapt(SoftPalette.red500) : context.adapt(SoftPalette.orange350),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      stockWarningNotice!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: stockWarningNotice!.contains('Out of Stock') ? context.adapt(SoftPalette.red550) : context.adapt(SoftPalette.orange350),
                                      ),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => setDialogState(() => stockWarningNotice = null),
                                    child: Icon(Icons.close, size: 16, color: context.adapt(SoftPalette.gray350)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.prescriptions.isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                          border: Border(bottom: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.check_circle, size: 14, color: context.adapt(_teal)),
                                const SizedBox(width: 6),
                                Text(
                                  'Selected Medicines (${widget.prescriptions.length})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? SoftPalette.teal300 : _teal,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  'Tap to edit • ✕ to remove',
                                  style: TextStyle(fontSize: 10.5, color: isDark ? SoftPalette.slate350 : SoftPalette.gray350),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: widget.prescriptions.map((m) {
                                  final name = _getFormattedMedicine(m);
                                  final abbrev = _getMedAbbrev(m);
                                  final isInj = _isInjectionOrDrip(m);
                                  final isCust = !_isInventoryMed(m);
                                  final timing = (m['timing'] ?? '').toString().trim();
                                  final qty = m['quantity'] ?? 1;
                                  final chipBg = isInj
                                      ? SoftPalette.orange400
                                      : (isCust ? SoftPalette.slate600 : _teal);

                                  return Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: InputChip(
                                      avatar: Icon(isCust ? Icons.auto_awesome : Icons.edit, size: 11, color: SoftPalette.gray50A70),
                                      label: Text(
                                        _medChipLabel(m),
                                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
                                      ),
                                      backgroundColor: chipBg,
                                      deleteIconColor: SoftPalette.gray50A70,
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      onPressed: () async {
                                        await _addMedicineDialog(
                                          existingPrescriptionMed: m,
                                          callerContext: dialogCtx,
                                        );
                                        if (dialogCtx.mounted) {
                                          setDialogState(() {});
                                        }
                                      },
                                      onDeleted: () {
                                        setState(() {
                                          widget.prescriptions.remove(m);
                                        });
                                        setDialogState(() {});
                                      },
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── Medicine Results List ─────────────────────────
                    Flexible(
                      child: filteredMeds.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(36),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search_off_rounded, size: 54, color: context.adapt(SoftPalette.gray150)),
                                    const SizedBox(height: 14),
                                    Text(
                                      queryCtrl.text.isNotEmpty
                                          ? 'No formulary medicines found matching "${queryCtrl.text}"'
                                          : 'No medicines in this category',
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: context.adapt(SoftPalette.gray550),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      onPressed: () async {
                                        await _addMedicineDialog(callerContext: dialogCtx);
                                        if (dialogCtx.mounted) {
                                          setDialogState(() {});
                                        }
                                      },
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('Add as Custom Medicine'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _teal,
                                        foregroundColor: SoftPalette.gray50,
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
                                color: context.adapt(SoftPalette.gray100),
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
                                final reservedCount = _getReservedCount(m);

                                final existingPrescriptionIdx = widget.prescriptions.indexWhere((cm) {
                                  if (m['id'] != null && cm['inventoryId'] != null) {
                                    final batchIds = (m['_batchIds'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
                                    batchIds.add(m['id'].toString());
                                    if (batchIds.contains(cm['inventoryId'].toString())) return true;
                                  }
                                  final cmName = (cm['name'] ?? '').toString().trim().toLowerCase();
                                  final cmType = (cm['type'] ?? '').toString().toLowerCase().trim();
                                  final cmDose = (cm['dose'] ?? cm['dosage'] ?? '').toString().toLowerCase().trim();
                                  if (cmName == medicineName.toLowerCase()) {
                                    if (medType.isNotEmpty && cmType.isNotEmpty && medType.toLowerCase() != cmType) return false;
                                    if (dose.isNotEmpty && cmDose.isNotEmpty && dose.toLowerCase() != cmDose) return false;
                                    return true;
                                  }
                                  return false;
                                });
                                final isAlreadyPrescribed = existingPrescriptionIdx != -1;
                                final existingMed = isAlreadyPrescribed ? widget.prescriptions[existingPrescriptionIdx] : null;

                                final itemBg = isOutOfStock
                                    ? (isDark ? SoftPalette.red800 : SoftPalette.red100t)
                                    : (isLowStock ? (isDark ? SoftPalette.orange800 : SoftPalette.yellow50m) : (isDark ? SoftPalette.slate800 : SoftPalette.gray50));
                                final itemBorder = isOutOfStock
                                    ? (isDark ? SoftPalette.red400 : SoftPalette.red200)
                                    : (isLowStock ? (isDark ? SoftPalette.orange350 : SoftPalette.yellow150) : (isDark ? SoftPalette.slate700 : SoftPalette.slate150));

                                return InkWell(
                                  key: ValueKey('med_item_${m['id'] ?? ''}_${medicineName}_${medType}_$dose'),
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () async {
                                    // No stock: not selectable (a medicine already on this
                                    // prescription can still be opened to edit or remove it).
                                    if (isOutOfStock && !isAlreadyPrescribed) {
                                      setDialogState(() {
                                        stockWarningNotice =
                                            'Out of Stock: "$medicineName" has none available and cannot be selected.';
                                      });
                                      return;
                                    }
                                    setDialogState(() {
                                      stockWarningNotice = null;
                                    });

                                    await _addMedicineDialog(
                                      inventoryMed: m,
                                      existingPrescriptionMed: existingMed,
                                      callerContext: dialogCtx,
                                    );
                                    if (dialogCtx.mounted) {
                                      setDialogState(() {});
                                    }
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
                                                      color: isOutOfStock ? context.adapt(SoftPalette.gray100) : context.adapt(typeColors.bg),
                                                      border: Border.all(
                                                        color: isOutOfStock ? context.adapt(SoftPalette.gray150) : context.adapt(typeColors.border),
                                                        width: 0.9,
                                                      ),
                                                      borderRadius: BorderRadius.circular(20),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        FaIcon(
                                                          _getMedicineIcon(m),
                                                          color: isOutOfStock ? context.adapt(SoftPalette.gray500) : context.adapt(typeColors.text),
                                                          size: 13,
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Text(
                                                          medType,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            fontWeight: FontWeight.bold,
                                                            color: isOutOfStock ? context.adapt(SoftPalette.gray500) : context.adapt(typeColors.text),
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
                                                            ? (isDark ? SoftPalette.red300 : SoftPalette.red550)
                                                            : (isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                                                      ),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),

                                                  if (dose.isNotEmpty) ...[
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: context.adapt(_dosePillBg),
                                                        border: Border.all(
                                                          color: context.adapt(_dosePillBorder),
                                                          width: 0.8,
                                                        ),
                                                        borderRadius: BorderRadius.circular(20),
                                                      ),
                                                      child: Text(
                                                        dose,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          fontWeight: FontWeight.w600,
                                                          color: context.adapt(_dosePillText),
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
                                                    Icon(Icons.biotech_rounded, size: 13, color: context.adapt(SoftPalette.teal550)),
                                                    const SizedBox(width: 4),
                                                    Expanded(
                                                      child: Text(
                                                        formula,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          color: context.adapt(SoftPalette.gray500),
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
                                                  color: context.adapt(SoftPalette.red150m),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: context.adapt(SoftPalette.red400), width: 0.8),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.cancel_outlined, size: 12, color: context.adapt(SoftPalette.red500)),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      'Avail: 0',
                                                      style: TextStyle(
                                                        color: context.adapt(SoftPalette.red550),
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
                                                  color: context.adapt(SoftPalette.amber100m),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: context.adapt(SoftPalette.amber300), width: 0.8),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.warning_amber_rounded, size: 13, color: context.adapt(SoftPalette.orange400)),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      'Avail: $availableStock',
                                                      style: TextStyle(
                                                        color: context.adapt(SoftPalette.orange400),
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
                                                  color: context.adapt(SoftPalette.green100m),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: context.adapt(SoftPalette.green300), width: 0.8),
                                                ),
                                                child: Text(
                                                  'Avail: $availableStock',
                                                  style: TextStyle(
                                                    color: context.adapt(SoftPalette.green550),
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
                                                    color: context.adapt(SoftPalette.orange350),
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(width: 10),

                                        // Action Buttons: One-Tap Add OR Added (Edit / Remove)
                                        if (isAlreadyPrescribed) ...[
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                                decoration: BoxDecoration(
                                                  color: context.adapt(_teal).withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(color: context.adapt(_teal), width: 1),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.check_circle, color: context.adapt(_teal), size: 14),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      _medAddedText(existingMed),
                                                      style: TextStyle(
                                                        color: context.adapt(_teal),
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 5),
                                              InkWell(
                                                onTap: () async {
                                                  final res = await _addMedicineDialog(
                                                    inventoryMed: m,
                                                    existingPrescriptionMed: existingMed,
                                                    callerContext: dialogCtx,
                                                  );
                                                  if (res == true && dialogCtx.mounted) {
                                                    await Future.delayed(const Duration(milliseconds: 100));
                                                    closeSelectionDialog();
                                                  } else if (dialogCtx.mounted) {
                                                    setDialogState(() {});
                                                  }
                                                },
                                                borderRadius: BorderRadius.circular(6),
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                                                  decoration: BoxDecoration(
                                                    color: isDark ? SoftPalette.slate700 : SoftPalette.gray100,
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.edit, size: 12, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray700),
                                                      const SizedBox(width: 3),
                                                      Text(
                                                        'Edit',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.w600,
                                                          color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray700,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              InkWell(
                                                onTap: () {
                                                  setState(() {
                                                    widget.prescriptions.remove(existingMed);
                                                  });
                                                  setDialogState(() {});
                                                },
                                                borderRadius: BorderRadius.circular(6),
                                                child: Container(
                                                  padding: const EdgeInsets.all(5),
                                                  decoration: BoxDecoration(
                                                    color: context.adapt(SoftPalette.red400).withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Icon(Icons.close, size: 13, color: context.adapt(SoftPalette.red400)),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ] else ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isOutOfStock
                                                  ? (isDark ? SoftPalette.slate600 : SoftPalette.gray350)
                                                  : (isLowStock ? (isDark ? SoftPalette.orange550 : SoftPalette.orange350) : _teal),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (isOutOfStock) ...[
                                                  const Icon(
                                                    Icons.block,
                                                    color: SoftPalette.gray50,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Text(
                                                  isOutOfStock ? 'Out of Stock' : '+ Select',
                                                  style: const TextStyle(
                                                    color: SoftPalette.gray50,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),

                    // ── Footer ────────────────────────────────────────
                    Divider(height: 1, thickness: 1, color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : SoftPalette.gray100,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(24),
                          bottomRight: Radius.circular(24),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          OutlinedButton(
                            onPressed: () async {
                              final res = await _addMedicineDialog(callerContext: dialogCtx);
                              if (res == true) {
                                closeSelectionDialog();
                              } else if (dialogCtx.mounted) {
                                setDialogState(() {});
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              backgroundColor: isDark
                                  ? SoftPalette.teal400.withValues(alpha: 0.10)
                                  : _teal.withValues(alpha: 0.06),
                              foregroundColor: isDark ? SoftPalette.teal300 : _teal,
                              side: BorderSide(
                                color: (isDark ? SoftPalette.teal400 : _teal).withValues(alpha: 0.35),
                                width: 1.2,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: (isDark ? SoftPalette.teal300 : _teal).withValues(alpha: 0.16),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.add_rounded,
                                    size: 15,
                                    color: isDark ? SoftPalette.teal300 : _teal,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Add Custom Medicine',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.1,
                                    color: isDark ? SoftPalette.teal300 : _teal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: closeSelectionDialog,
                            style: ElevatedButton.styleFrom(
                              elevation: widget.prescriptions.isNotEmpty ? 2 : 0,
                              shadowColor: _teal.withValues(alpha: 0.35),
                              backgroundColor: widget.prescriptions.isNotEmpty
                                  ? _teal
                                  : (isDark ? SoftPalette.slate700 : SoftPalette.gray200),
                              foregroundColor: widget.prescriptions.isNotEmpty
                                  ? SoftPalette.gray50
                                  : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  widget.prescriptions.isNotEmpty
                                      ? Icons.check_circle_rounded
                                      : Icons.close_rounded,
                                  size: 17,
                                  color: widget.prescriptions.isNotEmpty
                                      ? SoftPalette.gray50
                                      : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  widget.prescriptions.isNotEmpty ? 'Done' : 'Close',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.2,
                                    color: widget.prescriptions.isNotEmpty
                                        ? SoftPalette.gray50
                                        : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                                  ),
                                ),
                                if (widget.prescriptions.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: SoftPalette.gray50.withValues(alpha: 0.24),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: SoftPalette.gray50.withValues(alpha: 0.35),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Text(
                                      '${widget.prescriptions.length}',
                                      style: const TextStyle(
                                        color: SoftPalette.gray50,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
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
                ),
              ),
            );
          },
        );
      },
    );
  } finally {
    _activeDialogSetState = null;
    if (mounted) setState(() {});
  }
  }

  Future<bool?> _addMedicineDialog({
    Map<String, dynamic>? inventoryMed,
    Map<String, dynamic>? existingPrescriptionMed,
    BuildContext? callerContext,
  }) async {
    final isEditing = existingPrescriptionMed != null;
    final isInventory = inventoryMed != null || (isEditing && existingPrescriptionMed['inventoryId'] != null);

    Map<String, dynamic>? effectiveInv = inventoryMed;
    if (effectiveInv == null && isEditing && existingPrescriptionMed['inventoryId'] != null) {
      final invId = existingPrescriptionMed['inventoryId'].toString();
      try {
        effectiveInv = _allInventory.firstWhere(
          (m) => (m['id'] ?? '').toString() == invId,
          orElse: () => {},
        );
        if (effectiveInv.isEmpty) effectiveInv = null;
      } catch (_) {
        effectiveInv = null;
      }
    }

    final formula = (isEditing
        ? (existingPrescriptionMed['formula'] ?? effectiveInv?['formula'] ?? '')
        : (effectiveInv?['formula'] ?? '')).toString().trim();

    final initialName = (isEditing
        ? (existingPrescriptionMed['name'] ?? '')
        : (effectiveInv?['name'] ?? '')).toString().trim();

    final nameCtrl = TextEditingController(text: initialName);

    final initialTiming = isEditing
        ? (existingPrescriptionMed['timing'] ?? '1+0+1').toString().trim()
        : '1+0+1';
    final timingCtrl = TextEditingController(text: initialTiming);

    final initialQty = isEditing
        ? (existingPrescriptionMed['quantity'] ?? 1).toString()
        : '1';
    final qtyCtrl = TextEditingController(text: initialQty);

    const validMealTimings = ['Empty Stomach', 'Before Meal', 'During Meal', 'After Meal', 'Before Sleep'];
    final rawMeal = isEditing
        ? (existingPrescriptionMed['meal'] ?? 'After Meal').toString()
        : 'After Meal';
    String mealTiming = 'After Meal';
    final lowerMeal = rawMeal.toLowerCase();
    if (lowerMeal.contains('empty')) {
      mealTiming = 'Empty Stomach';
    } else if (lowerMeal.contains('before') && (lowerMeal.contains('sleep') || lowerMeal.contains('bed'))) {
      mealTiming = 'Before Sleep';
    } else if (lowerMeal.contains('before')) {
      mealTiming = 'Before Meal';
    } else if (lowerMeal.contains('during') || lowerMeal.contains('with')) {
      mealTiming = 'During Meal';
    } else if (validMealTimings.contains(rawMeal)) {
      mealTiming = rawMeal;
    }

    const validDosages = ['1 spoon', '1/2 spoon', '1/3 spoon', '1/4 spoon'];
    final rawDosage = isEditing
        ? (existingPrescriptionMed['dosage'] ?? '1 spoon').toString()
        : '1 spoon';
    String dosage = validDosages.contains(rawDosage) ? rawDosage : '1 spoon';
    bool isSyrup = false;
    bool isInjection = false;

    void updateFields() {
      final inv = effectiveInv;
      final existing = existingPrescriptionMed;
      if (inv != null) {
        final type  = (inv['type'] ?? '').toString().toLowerCase();
        final name  = (inv['name'] ?? '').toString().toLowerCase();
        isInjection = type.contains('injection') || type.contains('inj') ||
                      type.contains('infusion') || type.contains('inf') ||
                      type.contains('drip') ||
                      name.contains('inj') || name.contains('infusion') || name.contains('drip');
        isSyrup     = type.contains('syrup') || type.contains('syp') || name.contains('syp') || name.contains('syrup');
      } else if (isEditing && existing != null) {
        final type  = (existing['type'] ?? '').toString().toLowerCase();
        final name  = (existing['name'] ?? '').toString().toLowerCase();
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
    if (isInjection && !isEditing) {
      timingCtrl.text = '';
    }

    String? stockError;
    if (effectiveInv != null) {
      final availableStock = _getAvailableStock(effectiveInv);
      final dynamic rawQty = effectiveInv['quantity'];
      final double rawStock = (rawQty is num ? rawQty.toDouble() : double.tryParse(rawQty?.toString() ?? '') ?? 0.0);
      if (!isEditing && rawStock > 0 && availableStock <= 0) {
        stockError = '⛔ Out of stock: all remaining units are reserved for other patients, so this cannot be prescribed.';
      } else if (!isEditing && availableStock <= 0) {
        stockError = '⛔ Out of stock: this medicine has none available, so it cannot be prescribed.';
      }
    }

    // The selection dialog that called us can outlive this State (the parent may have
    // re-created the panel underneath it). Its context is still valid, so keep going:
    // adding a medicine only touches widget.prescriptions and the parent callbacks.
    if (!mounted && (callerContext == null || !callerContext.mounted)) {
      debugPrint('[DoctorPanel] _addMedicineDialog aborted: panel State and caller dialog are both gone');
      return null;
    }
    if (!mounted) {
      debugPrint('[DoctorPanel] panel State was disposed under the open dialog; continuing with the dialog context');
    }
    final dialogTargetContext = callerContext ?? context;

    final dialogResult = await showDialog<bool>(
      context: dialogTargetContext,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setStateDialog) {
          final isDark = _resolveIsDark(ctx);

          void commitMedicine({required bool closeAll}) {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) {
              setStateDialog(() => stockError = 'Please enter medicine name');
              return;
            }

            Map<String, dynamic>? currentInv = effectiveInv;
            if (!isEditing && currentInv == null) {
              final matched = _allInventory.firstWhere(
                (m) => (m['name'] ?? '').toString().trim().toLowerCase() == name.toLowerCase(),
                orElse: () => {},
              );
              if (matched.isNotEmpty) {
                currentInv = matched;
                effectiveInv = matched;
              }
            }
            final inv = currentInv;
            final existing = existingPrescriptionMed;

            final candidateType = isInjection
                ? (inv != null
                    ? (inv['type'] ?? 'Injection')
                    : (name.toLowerCase().contains('inf') || name.toLowerCase().contains('drip') ? 'Infusion' : 'Injection'))
                : (isSyrup
                    ? 'Syrup'
                    : (inv != null ? (inv['type'] ?? 'Tablet') : ((existing?['type']) ?? 'Tablet')));

            final candidateDose = (inv != null
                ? (inv['dose'] ?? inv['dosage'] ?? '')
                : ((existing?['dose'] ?? existing?['dosage']) ?? '')).toString().trim();

            // Stock available for THIS prescription line. _getAvailableStock already subtracts
            // everything added in this session, including the line being edited, so give that
            // line's own quantity back before comparing.
            int avail = inv != null ? _getAvailableStock(inv) : 999999;
            if (inv != null && existing != null) {
              final batchIds = (inv['_batchIds'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
              final invId = inv['id']?.toString() ?? '';
              if (invId.isNotEmpty) batchIds.add(invId);
              if (batchIds.contains(existing['inventoryId']?.toString() ?? '')) {
                final q = existing['quantity'];
                avail += (q is num ? q.toInt() : int.tryParse(q?.toString() ?? '') ?? 0);
              }
            }
            final isStockZero = inv != null && avail <= 0;
            if (isStockZero) {
              setStateDialog(() => stockError =
                  '⛔ Out of stock: "${(inv['name'] ?? name)}" has none available, so it cannot be prescribed.');
              return;
            }

            final effectiveId = inv?['id'] ??
                inv?['medicineId'] ??
                inv?['docId'] ??
                (existing != null ? (existing['inventoryId'] ?? existing['medicineId']) : null);

            final resolvedDose = (inv != null
                ? (inv['dose'] ?? inv['dosage'] ?? '')
                : (existing != null ? (existing['dose'] ?? existing['dosage'] ?? '') : '')).toString().trim();

            Map<String, dynamic> newMed;
            bool exceedsStock = false;
            int totalNeeded = 1;

            if (isInjection) {
              final qty = int.tryParse(qtyCtrl.text.trim()) ?? 1;
              if (qty <= 0) {
                setStateDialog(() => stockError = 'Quantity must be at least 1');
                return;
              }
              totalNeeded = qty;
              exceedsStock = inv != null && qty > avail;
              if (exceedsStock) {
                setStateDialog(() => stockError =
                    '⛔ Only $avail available in stock — cannot prescribe $qty.');
                return;
              }

              final medType = inv != null
                  ? (inv['type'] ?? 'Injection')
                  : (name.toLowerCase().contains('inf') || name.toLowerCase().contains('drip') ? 'Infusion' : 'Injection');
              newMed = {
                'name': name,
                'formula': formula,
                'quantity': qty,
                'type': medType,
                'dose': resolvedDose,
                'dosage': resolvedDose,
                'inventoryId': effectiveId,
                'medicineId': effectiveId,
                if (isStockZero || exceedsStock) 'isExternal': true,
                if (isStockZero) 'outOfStock': true,
                if (exceedsStock) 'stockShortage': qty - (avail > 0 ? avail : 0),
              };
            } else {
              final rawTiming = timingCtrl.text.trim();
              final timingStr = rawTiming.isNotEmpty ? rawTiming : '1+0+1';
              final digits = timingStr.replaceAll('+', '').trim();
              final m      = int.tryParse(digits.isNotEmpty ? digits[0] : '1') ?? 1;
              final e      = digits.length > 1 ? int.tryParse(digits[1]) ?? 0 : 0;
              final n      = digits.length > 2 ? int.tryParse(digits[2]) ?? 1 : 1;
              int sum      = m + e + n;
              if (sum == 0 && digits.length == 1) {
                sum = int.tryParse(digits) ?? 1;
              }
              final qty = isSyrup
                  ? 1
                  : ((mealTiming == 'Before Sleep' && sum == 0) ? 1 : (sum > 0 ? sum : 1));
              final totalRequired = isSyrup ? 1 : qty * _daysOfMedicine;
              totalNeeded = totalRequired;
              exceedsStock = inv != null && totalRequired > avail;
              if (exceedsStock) {
                setStateDialog(() => stockError =
                    '⛔ Only $avail available in stock — this dose and number of days needs $totalRequired.');
                return;
              }

              final medType = isSyrup
                  ? 'Syrup'
                  : (inv != null
                      ? (inv['type'] ?? 'Tablet')
                      : ((existing?['type']) ?? 'Tablet'));

              newMed = {
                'name': name,
                'formula': formula,
                'quantity': qty,
                'timing': timingStr,
                'meal': mealTiming,
                'dosage': isSyrup ? dosage : resolvedDose,
                'dose': resolvedDose,
                'type': medType,
                'inventoryId': effectiveId,
                'medicineId': effectiveId,
                if (isStockZero || exceedsStock) 'isExternal': true,
                if (isStockZero) 'outOfStock': true,
                if (exceedsStock) 'stockShortage': totalRequired - (avail > 0 ? avail : 0),
              };
            }

            bool isNew = false;
            // Mutate widget.prescriptions (the parent's list) directly instead of inside
            // setState: if the panel State was disposed while this dialog was open,
            // setState would throw and the medicine would silently never be added.
            void applyMedicine() {
              if (isEditing && existing != null) {
                final idx = widget.prescriptions.indexOf(existing);
                if (idx != -1) {
                  widget.prescriptions[idx] = newMed;
                } else {
                  final fIdx = widget.prescriptions.indexWhere((m) {
                    if (m['inventoryId'] != null && newMed['inventoryId'] != null) {
                      return m['inventoryId'].toString() == newMed['inventoryId'].toString();
                    }
                    final mName = (m['name'] ?? '').toString().trim().toLowerCase();
                    final mType = (m['type'] ?? '').toString().toLowerCase().trim();
                    final mDose = (m['dose'] ?? m['dosage'] ?? '').toString().toLowerCase().trim();
                    final nName = name.toLowerCase();
                    final nType = (newMed['type'] ?? '').toString().toLowerCase().trim();
                    final nDose = (newMed['dose'] ?? newMed['dosage'] ?? '').toString().toLowerCase().trim();
                    if (mType.isNotEmpty && nType.isNotEmpty && mType != nType) return false;
                    if (mDose.isNotEmpty && nDose.isNotEmpty && mDose != nDose) return false;
                    return mName == nName &&
                        (mType == nType || mType.isEmpty || nType.isEmpty) &&
                        (mDose == nDose || mDose.isEmpty || nDose.isEmpty);
                  });
                  if (fIdx != -1) {
                    widget.prescriptions[fIdx] = newMed;
                  } else {
                    widget.prescriptions.add(newMed);
                    isNew = true;
                  }
                }
              } else {
                final matchIdx = widget.prescriptions.indexWhere((m) {
                  final invIdStr = inv?['id']?.toString().trim();
                  final mInvIdStr = m['inventoryId']?.toString().trim();
                  if (invIdStr != null && invIdStr.isNotEmpty && invIdStr != 'unknown' &&
                      mInvIdStr != null && mInvIdStr.isNotEmpty && mInvIdStr != 'unknown') {
                    final batchIds = (inv!['_batchIds'] as List?)?.map((e) => e.toString().trim()).toSet() ?? <String>{};
                    batchIds.add(invIdStr);
                    if (batchIds.contains(mInvIdStr)) return true;
                  }
                  final mName = (m['name'] ?? '').toString().trim().toLowerCase();
                  final nName = name.trim().toLowerCase();
                  if (mName.isEmpty || nName.isEmpty || mName != nName) return false;
                  final mType = (m['type'] ?? '').toString().toLowerCase().trim();
                  final mDose = (m['dose'] ?? m['dosage'] ?? '').toString().toLowerCase().trim();
                  final nType = (newMed['type'] ?? '').toString().toLowerCase().trim();
                  final nDose = (newMed['dose'] ?? newMed['dosage'] ?? '').toString().toLowerCase().trim();
                  if (mType.isNotEmpty && nType.isNotEmpty && mType != nType) return false;
                  if (mDose.isNotEmpty && nDose.isNotEmpty && mDose != nDose) return false;
                  return true;
                });
                if (matchIdx != -1) {
                  widget.prescriptions[matchIdx] = newMed;
                } else {
                  widget.prescriptions.add(newMed);
                  isNew = true;
                }
              }

              if (_isInjectionOrDrip(newMed) && _daysOfMedicine > 1) {
                _daysOfMedicine = 1;
              }
            }

            applyMedicine();
            if (mounted) {
              setState(() {});
            } else {
              debugPrint('[DoctorPanel] medicine added to the parent list while the panel State was disposed; parent will rebuild');
            }

            if (isNew) {
              widget.onAddMedicine?.call(newMed);
            } else {
              widget.onEditMedicine.call(newMed);
            }

            if (isStockZero && mounted) {
              AppToast.hideCurrent();
              AppToast.showSnackBar(dialogCtx, 
                SnackBar(
                  content: Text('⚠️ "$name" added (0 shelf stock — prescribed for external purchase / indent).'),
                  backgroundColor: SoftPalette.orange400,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            } else if (exceedsStock && mounted) {
              AppToast.hideCurrent();
              AppToast.showSnackBar(dialogCtx, 
                SnackBar(
                  content: Text('⚠️ "$name" added (Shelf stock: $avail, needed: $totalNeeded — excess for external purchase).'),
                  backgroundColor: SoftPalette.orange400,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            }

            Navigator.of(ctx, rootNavigator: true).pop(true);
          }

          final pData = widget.selectedPatientData;
          final pName = (pData?['patientName'] ?? pData?['name'] ?? '').toString().trim();
          final pSerial = (pData?['serial'] ?? pData?['id'] ?? widget.serialId).toString().trim();
          final pVitals = (pData?['vitals'] is Map) ? Map<String, dynamic>.from(pData!['vitals']) : {};
          final pAge = (pVitals['age'] ?? pData?['age'] ?? '').toString().trim();
          final pGender = (pVitals['gender'] ?? pData?['gender'] ?? '').toString().trim();

          return AlertDialog(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: dialogCtx.adapt(_teal).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        isEditing ? Icons.edit_note_rounded : (isInjection ? Icons.vaccines_rounded : Icons.medication_rounded),
                        color: dialogCtx.adapt(_teal),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isEditing
                            ? (isInventory ? 'Edit Inventory Medicine' : 'Edit Custom Medicine')
                            : (isInventory ? 'Add Inventory Medicine' : 'Add Custom Medicine'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                if (pName.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate800 : SoftPalette.teal100m,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: dialogCtx.adapt(_teal).withValues(alpha: 0.3), width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_outline, size: 13, color: dialogCtx.adapt(_teal)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Patient: $pName',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: dialogCtx.adapt(_teal)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (pSerial.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            '(#$pSerial)',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550),
                          ),
                        ],
                        if (pGender.isNotEmpty || pAge.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            '• ${[if (pGender.isNotEmpty) pGender, if (pAge.isNotEmpty) '$pAge yrs'].join(', ')}',
                            style: TextStyle(fontSize: 10.5, color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray500),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stockError != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: dialogCtx.adapt(SoftPalette.pink100m),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: dialogCtx.adapt(SoftPalette.red400)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline_rounded, color: dialogCtx.adapt(SoftPalette.red550), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              stockError!,
                              style: TextStyle(
                                color: dialogCtx.adapt(SoftPalette.red550),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  TextField(
                    controller: nameCtrl,
                    readOnly: isInventory,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    decoration: InputDecoration(
                      labelText: isInventory ? 'Formula / Brand' : 'Medicine Name',
                      labelStyle: TextStyle(color: isDark ? SoftPalette.slate350 : null),
                      border: const OutlineInputBorder(),
                      filled: isInventory,
                      fillColor: isInventory ? (isDark ? SoftPalette.slate800 : SoftPalette.gray100) : null,
                      isDense: true,
                    ),
                    onChanged: (isInventory || isEditing) ? null : (v) => setStateDialog(() {
                      updateFields();
                      stockError = null;
                    }),
                  ),
                  if (effectiveInv != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.inventory_2, size: 16, color: dialogCtx.adapt(SoftPalette.gray350)),
                        const SizedBox(width: 4),
                        Text(
                          'Available: ${_getAvailableStock(effectiveInv)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: _getAvailableStock(effectiveInv) < 10
                                ? dialogCtx.adapt(SoftPalette.red400)
                                : (isDark ? SoftPalette.slate200 : SoftPalette.gray550),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_getReservedCount(effectiveInv) > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            '(${_getReservedCount(effectiveInv)} reserved)',
                            style: TextStyle(
                              fontSize: 11,
                              color: dialogCtx.adapt(SoftPalette.orange350),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (formula.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.biotech_rounded, size: 15, color: dialogCtx.adapt(SoftPalette.teal600)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              formula,
                              style: TextStyle(
                                fontSize: 12,
                                color: dialogCtx.adapt(SoftPalette.teal600),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Timing (Morning+Evening+Night):',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'e.g. 1+0+1',
                          style: TextStyle(fontSize: 11, color: dialogCtx.adapt(SoftPalette.gray500), fontStyle: FontStyle.italic),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: timingCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [const DoseTimingInputFormatter()],
                      decoration: const InputDecoration(
                        hintText: 'e.g. 1+0+1 or 1+1+1',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) {
                        // '+' is inserted by DoseTimingInputFormatter as the doctor types.
                        setStateDialog(() => stockError = null);
                      },
                      onSubmitted: (_) => commitMedicine(closeAll: true),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: ['1+0+1', '1+1+1', '1+0+0', '0+0+1', '0+1+0', '1+1+0'].map((chip) {
                        final isSelected = timingCtrl.text.trim() == chip;
                        return InkWell(
                          onTap: () {
                            setStateDialog(() {
                              timingCtrl.text = chip;
                              timingCtrl.selection = TextSelection.collapsed(offset: chip.length);
                              stockError = null;
                            });
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSelected ? _teal : (isDark ? SoftPalette.slate800 : SoftPalette.gray100),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                              ),
                            ),
                            child: Text(
                              chip,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.gray50A70 : SoftPalette.gray700),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: validMealTimings.contains(mealTiming) ? mealTiming : 'After Meal',
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Timing Instruction',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: validMealTimings
                          .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 13))))
                          .toList(),
                      onChanged: (v) => setStateDialog(() => mealTiming = v ?? mealTiming),
                    ),
                    if (isSyrup) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: validDosages.contains(dosage) ? dosage : '1 spoon',
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: 'Dosage', border: OutlineInputBorder(), isDense: true,
                        ),
                        items: validDosages
                            .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 13))))
                            .toList(),
                        onChanged: (v) => setStateDialog(() => dosage = v ?? dosage),
                      ),
                    ],
                    Builder(
                      builder: (_) {
                        final digits = timingCtrl.text.replaceAll('+', '').trim();
                        final m = int.tryParse(digits.isNotEmpty ? digits[0] : '0') ?? 0;
                        final e = digits.length > 1 ? int.tryParse(digits[1]) ?? 0 : 0;
                        final n = digits.length > 2 ? int.tryParse(digits[2]) ?? 0 : 0;
                        int sum = m + e + n;
                        if (sum == 0 && digits.length == 1) {
                          sum = int.tryParse(digits) ?? 0;
                        }
                        final dailyCount = (mealTiming == 'Before Sleep' && sum == 0) ? 1 : (sum > 0 ? sum : 1);
                        final totalUnits = isSyrup ? 1 : (dailyCount * _daysOfMedicine);

                        return Container(
                          margin: const EdgeInsets.only(top: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: dialogCtx.adapt(_teal).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: dialogCtx.adapt(_teal).withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSyrup ? Icons.science_outlined : Icons.calculate_outlined,
                                color: dialogCtx.adapt(_teal),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  isSyrup
                                      ? 'Quantity: 1 bottle • Dose: $dosage ($mealTiming)'
                                      : 'Total Dispense: $totalUnits unit(s) ($dailyCount/day × $_daysOfMedicine day${_daysOfMedicine > 1 ? "s" : ""})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: dialogCtx.adapt(_teal),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Quantity (Units / Vials / Ampoules):',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Shelf: ${effectiveInv != null ? _getAvailableStock(effectiveInv) : "-"}',
                          style: TextStyle(fontSize: 11, color: dialogCtx.adapt(SoftPalette.gray500), fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        IconButton(
                          onPressed: () {
                            final current = int.tryParse(qtyCtrl.text.trim()) ?? 1;
                            if (current > 1) {
                              setStateDialog(() {
                                qtyCtrl.text = (current - 1).toString();
                                stockError = null;
                              });
                            }
                          },
                          icon: Icon(Icons.remove_circle_outline, color: dialogCtx.adapt(_teal)),
                          tooltip: 'Decrease Quantity',
                        ),
                        Expanded(
                          child: TextField(
                            controller: qtyCtrl,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            decoration: const InputDecoration(
                              labelText: 'Quantity',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) => setStateDialog(() => stockError = null),
                            onSubmitted: (_) => commitMedicine(closeAll: true),
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            final current = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                            setStateDialog(() {
                              qtyCtrl.text = (current + 1).toString();
                              stockError = null;
                            });
                          },
                          icon: Icon(Icons.add_circle_outline, color: dialogCtx.adapt(_teal)),
                          tooltip: 'Increase Quantity',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: ['1', '2', '3', '4', '5'].map((chip) {
                        final isSelected = qtyCtrl.text.trim() == chip;
                        return InkWell(
                          onTap: () {
                            setStateDialog(() {
                              qtyCtrl.text = chip;
                              stockError = null;
                            });
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSelected ? _teal : (isDark ? SoftPalette.slate800 : SoftPalette.gray100),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                              ),
                            ),
                            child: Text(
                              chip,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.gray50A70 : SoftPalette.gray700),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (isEditing) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: dialogCtx.adapt(SoftPalette.red400)),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                  onPressed: () {
                    setState(() {
                      widget.prescriptions.remove(existingPrescriptionMed);
                    });
                    Navigator.of(ctx, rootNavigator: true).pop(false);
                  },
                ),
                const SizedBox(width: 24),
                TextButton(
                  onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: SoftPalette.gray50,
                  ),
                  onPressed: () => commitMedicine(closeAll: true),
                  child: const Text('Update'),
                ),
              ] else ...[
                TextButton(
                  onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(null),
                  child: Text('Cancel', style: TextStyle(color: dialogCtx.adapt(_teal))),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: SoftPalette.gray50,
                  ),
                  onPressed: () => commitMedicine(closeAll: true),
                  child: const Text('Add & Done'),
                ),
              ],
            ],
          );
        },
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
      timingCtrl.dispose();
      qtyCtrl.dispose();
    });

    if (mounted) setState(() {});
    return dialogResult;
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
            child: Text('Cancel', style: TextStyle(color: context.adapt(_teal))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: SoftPalette.gray50,
            ),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty || widget.labResults.any((l) => (l['name'] ?? '').toString().trim() == name)) {
                AppToast.showSnackBar(context, SnackBar(
                    content: Text(errorText), backgroundColor: SoftPalette.red400));
                return;
              }
              setState(() => widget.labResults.add({'name': name}));
              Navigator.pop(context);
            },
            child: const Text('Add', style: TextStyle(color: SoftPalette.gray50)),
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
              FaIcon(icon, color: context.adapt(_teal), size: compact ? 16 : 20),
              SizedBox(width: compact ? 6 : 10),
              Text(title, style: TextStyle(
                  fontSize: compact ? 14 : 18, fontWeight: FontWeight.bold, color: context.adapt(_teal))),
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
            final isExt = m['isExternal'] == true || m['outOfStock'] == true;
            final label = _medChipLabel(m);
            return InputChip(
              avatar: Icon(isExt ? Icons.warning_amber_rounded : Icons.edit, size: 12, color: SoftPalette.gray50A70),
              label: Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 11 : 12.5,
                  fontWeight: FontWeight.w600,
                  color: SoftPalette.gray50,
                ),
              ),
              backgroundColor: isExt ? (_isDark ? SoftPalette.red600 : SoftPalette.red400) : chipColor,
              padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8),
              onPressed: () => _addMedicineDialog(existingPrescriptionMed: m),
              onDeleted: () => setState(() => widget.prescriptions.remove(m)),
              deleteIconColor: SoftPalette.gray50,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  // ── Prescription Templates Management ─────────────────────────────────────
  Future<void> _loadPrescriptionTemplates({bool syncCloud = true}) async {
    try {
      final tpls = await PrescriptionTemplateService.loadTemplates(widget.branchId, doctorId: widget.doctorId, syncCloud: syncCloud);
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
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.orange700 : SoftPalette.yellow150,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.inventory_2_rounded, color: isDark ? SoftPalette.amber200 : SoftPalette.orange350, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Inventory Stock Verification',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                    Text('Real-time audit for "${template['name']}"',
                        style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray500)),
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
                  style: TextStyle(fontSize: 12.5, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                ),
                const SizedBox(height: 12),
                ...outOfStockList.map((item) {
                  final med = item['med'] as Map<String, dynamic>;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.red800 : SoftPalette.red100t,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isDark ? SoftPalette.red400 : SoftPalette.red300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.cancel, color: context.adapt(SoftPalette.red400), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${med['name']} (${med['type']})',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDark ? SoftPalette.red300 : SoftPalette.red550)),
                              Text('Status: 0 In Stock (Unavailable in dispensary)', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.red400))),
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
                        color: isDark ? SoftPalette.orange800 : SoftPalette.yellow50m,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isDark ? SoftPalette.orange350 : SoftPalette.yellow200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: isDark ? SoftPalette.amber200 : SoftPalette.orange350, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${med['name']} (${med['type']})',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isDark ? SoftPalette.yellow150 : SoftPalette.orange350)),
                                Text('Low Stock: Only $stock units left in dispensary',
                                    style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.yellow200 : SoftPalette.orange350)),
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
              style: OutlinedButton.styleFrom(foregroundColor: isDark ? SoftPalette.orange350 : SoftPalette.orange400),
              onPressed: () {
                Navigator.pop(ctx);
                _finalizeTemplateApplication(template, resolvedMeds);
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.done_all_rounded, size: 16),
              label: const Text('Apply Anyway (Custom)'),
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: SoftPalette.gray50),
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
      AppToast.showSnackBar(context, 
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
        backgroundColor: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        title: Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: context.adapt(SoftPalette.red400), size: 24),
            const SizedBox(width: 8),
            Text('Delete Template', style: TextStyle(color: _isDark ? SoftPalette.gray50 : SoftPalette.gray900A87, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          'Are you sure you want to delete the "$templateName" template?',
          style: TextStyle(color: _isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400, foregroundColor: SoftPalette.gray50),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await PrescriptionTemplateService.deleteTemplate(widget.branchId, templateId, doctorId: widget.doctorId);
      await _loadPrescriptionTemplates(syncCloud: false);
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('🗑️ Deleted "$templateName"'),
            backgroundColor: SoftPalette.red500,
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
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          title: Row(
            children: [
              Icon(Icons.edit_note_rounded, color: context.adapt(_teal), size: 24),
              const SizedBox(width: 8),
              Text('Edit Prescription Template',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Template Title:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: titleCtrl,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Category:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: selectedCategory,
                    dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                    items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho', 'Infectious']
                        .map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87))))
                        .toList(),
                    onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Patient Condition / Complaints:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: complaintCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Diagnosis:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: diagnosisCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Default Duration (Days):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
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
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.teal200 : _teal)),
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
                        color: isDark ? SoftPalette.slate900 : SoftPalette.gray100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${m['name']} (${m['timing'] ?? m['dose'] ?? '1+1+1'}) • ${m['meal'] ?? m['instructions'] ?? ''}',
                              style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close, size: 16, color: context.adapt(SoftPalette.red400)),
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
              style: TextButton.styleFrom(foregroundColor: context.adapt(SoftPalette.red400)),
              child: const Text('Delete Template'),
            ),
            const SizedBox(width: 24),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: SoftPalette.gray50),
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
                await _loadPrescriptionTemplates(syncCloud: false);
                if (ctx.mounted) Navigator.pop(ctx);

                if (mounted) {
                  AppToast.showSnackBar(context, 
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
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          title: Row(
            children: [
              Icon(Icons.tune_rounded, color: context.adapt(_teal), size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Manage Templates',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                    Text('${_prescriptionTemplates.length} saved template(s)',
                        style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray500)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.add_rounded, color: context.adapt(_teal)),
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
                        Icon(Icons.bookmark_border_rounded, size: 48, color: isDark ? SoftPalette.gray50A38 : SoftPalette.gray300),
                        const SizedBox(height: 10),
                        Text('No templates added yet',
                            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                        const SizedBox(height: 4),
                        Text('Fill a prescription and click "Save as Template"',
                            style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray350)),
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
                          color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isDark ? SoftPalette.teal700 : _dosePillBg,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.medical_services_rounded, color: isDark ? SoftPalette.teal300 : _teal, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tpl['name'] ?? '', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${tpl['category'] ?? 'General'} • $medCount Meds • $labCount Labs • ${tpl['defaultDays'] ?? 1} Day(s)',
                                    style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray500),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.bolt, color: SoftPalette.amber200, size: 20),
                              tooltip: 'Apply to Current Patient',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _applyPrescriptionTemplate(tpl);
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.edit_outlined, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550, size: 18),
                              tooltip: 'Edit Template',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showEditTemplateDialog(tpl);
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: context.adapt(SoftPalette.red400), size: 18),
                              tooltip: 'Delete Template',
                              onPressed: () async {
                                await PrescriptionTemplateService.deleteTemplate(
                                  widget.branchId,
                                  tpl['id'],
                                  doctorId: widget.doctorId,
                                );
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
      AppToast.showSnackBar(context, 
        SnackBar(
          content: const Text('⚠️ Maximum limit reached (5 templates). Please edit or delete an existing template.'),
          backgroundColor: SoftPalette.orange350,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (complaint.isEmpty && diagnosis.isEmpty && widget.prescriptions.isEmpty) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('Please fill Diagnosis or Medicines first to save as a Template!'),
          backgroundColor: SoftPalette.amber300,
        ),
      );
      return;
    }

    final titleCtrl = TextEditingController(text: diagnosis.isNotEmpty ? diagnosis : 'Prescription Template');
    String selectedCategory = 'General';
    var savingTemplate = false;
    final isDark = _isDark;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          title: Row(
            children: [
              Icon(Icons.bookmark_add_rounded, color: context.adapt(_teal), size: 24),
              const SizedBox(width: 8),
              Text('Save As Reusable Template',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87)),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Template Name / Title:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                  decoration: InputDecoration(
                    hintText: 'e.g. Acute URTI (Adult)',
                    filled: true,
                    fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Category:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray550)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                  items: ['General', 'Respiratory', 'Gastro', 'Cardio', 'Pediatric', 'ENT', 'Ortho']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87))))
                      .toList(),
                  onChanged: (v) => setDlgState(() => selectedCategory = v ?? 'General'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.teal700 : _dosePillBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? SoftPalette.teal300 : _dosePillBorder, width: 0.6),
                  ),
                  child: Text(
                    'Includes: ${widget.prescriptions.length} Medicine(s) • ${widget.labResults.length} Lab Test(s) • Day: $_daysOfMedicine',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.teal200 : _teal),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: SoftPalette.gray50),
              onPressed: () async {
                final name = titleCtrl.text.trim();
                if (name.isEmpty || savingTemplate) return;
                savingTemplate = true; // ignore repeat taps while this save is in progress

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
                  await _loadPrescriptionTemplates(syncCloud: false);
                  if (ctx.mounted) Navigator.pop(ctx);

                  if (mounted) {
                    AppToast.showSnackBar(context, 
                      SnackBar(
                        content: Text('⭐ Saved "$name" to your templates!'),
                        backgroundColor: _teal,
                        duration: const Duration(seconds: 3),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                } catch (e) {
                  savingTemplate = false;
                  if (ctx.mounted) {
                    AppToast.showSnackBar(ctx, 
                      SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: SoftPalette.red400),
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
    final muted = isDark ? SoftPalette.slate350 : SoftPalette.gray500;
    final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.emerald150;

    Widget headerButton({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool filled = false,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: filled ? (isDark ? SoftPalette.teal550 : _teal) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: filled ? Colors.transparent : borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: filled ? SoftPalette.gray50 : (isDark ? SoftPalette.teal300 : _teal)),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: filled ? SoftPalette.gray50 : (isDark ? SoftPalette.teal300 : _teal),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.emerald50m,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + the two actions, always in the same place
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 18, color: isDark ? SoftPalette.teal300 : _teal),
              const SizedBox(width: 6),
              Text(
                'Quick Templates',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
              ),
              const Spacer(),
              headerButton(
                icon: Icons.bookmark_add_outlined,
                label: compact ? 'Save' : 'Save as Template',
                onTap: _showSaveCurrentAsTemplateDialog,
                filled: true,
              ),
              const SizedBox(width: 6),
              headerButton(
                icon: Icons.tune_rounded,
                label: 'Manage',
                onTap: _showManageTemplatesDialog,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_prescriptionTemplates.isEmpty)
            Text(
              'No templates yet. Add medicines to this prescription, then tap "Save as Template" '
              'to reuse the whole set in one tap.',
              style: TextStyle(fontSize: 11.5, color: muted, height: 1.35),
            )
          else ...[
            Text(
              'Tap a template to fill the prescription:',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(height: 6),
            // All templates visible at once (wraps) — no hidden horizontal scrolling
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _prescriptionTemplates.map((tpl) {
                final name = tpl['name']?.toString() ?? 'Template';
                final iconData = PrescriptionTemplateService.getIcon(tpl['icon']?.toString());
                final medCount = (tpl['medicines'] as List<dynamic>?)?.length ?? 0;

                return Tooltip(
                  message: '$name • $medCount medicine${medCount == 1 ? "" : "s"}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _applyPrescriptionTemplate(tpl),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 38),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FaIcon(iconData, size: 13, color: isDark ? SoftPalette.teal300 : _teal),
                          const SizedBox(width: 7),
                          Text(
                            name,
                            style: TextStyle(
                              color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: (isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$medCount',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
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
            color: isDark ? SoftPalette.slate800 : SoftPalette.emerald50m,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: isDark ? SoftPalette.slate700 : SoftPalette.emerald100,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? SoftPalette.gray900A26 : SoftPalette.teal500.withValues(alpha: 0.05),
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
                  FaIcon(FontAwesomeIcons.calendarDays, color: isDark ? SoftPalette.teal300 : _teal, size: 15),
                  const SizedBox(width: 8),
                  Text(
                    'Days of Medicine',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: isDark ? SoftPalette.teal200 : _teal,
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
                            color: isDark ? SoftPalette.slate600 : SoftPalette.gray150,
                          ),
                        InkWell(
                          onTap: isDisabled
                              ? () {
                                  AppToast.showSnackBar(context, const SnackBar(
                                    content: Text('💉 Injection prescribed — only 1 day of medicine allowed'),
                                    backgroundColor: SoftPalette.amber300,
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
                                          color: SoftPalette.gray50,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: isDark ? SoftPalette.teal300 : _teal,
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
                                              ? (isDark ? SoftPalette.slate550 : SoftPalette.gray300)
                                              : (isDark ? SoftPalette.gray50A70 : _teal),
                                        ),
                                      ),
                                      if (extra > 0 && !isDisabled)
                                        Text(
                                          '+$extra',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.bold,
                                            color: context.adapt(SoftPalette.orange400),
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
                    color: isDark ? SoftPalette.slate600 : SoftPalette.gray150,
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
                              color: isDark ? SoftPalette.teal200 : _teal,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.info_outline_rounded,
                            size: 15,
                            color: isDark ? SoftPalette.teal200 : _teal,
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
              color: context.adapt(SoftPalette.amber100m),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.adapt(SoftPalette.amber300)),
            ),
            child: Row(children: [
              FaIcon(FontAwesomeIcons.syringe, size: 12, color: context.adapt(SoftPalette.orange350)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Injection prescribed — only 1 day of medicine allowed.',
                  style: TextStyle(
                      fontSize: compact ? 9.5 : 10.5,
                      color: context.adapt(SoftPalette.orange400),
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
                  ? (isDark ? SoftPalette.orange800 : SoftPalette.amber50m)
                  : context.adapt(_teal).withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _extraCharge > 0
                    ? (isDark ? SoftPalette.orange350 : SoftPalette.amber300)
                    : context.adapt(_teal).withValues(alpha: 0.2),
              ),
            ),
            child: Row(children: [
              Icon(
                _extraCharge > 0 ? Icons.monetization_on_outlined : Icons.info_outline,
                size: 14,
                color: _extraCharge > 0
                    ? (isDark ? SoftPalette.orange350 : SoftPalette.orange400)
                    : context.adapt(_teal).withValues(alpha: 0.8),
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
                        ? (isDark ? SoftPalette.amber150 : SoftPalette.orange400)
                        : (isDark ? SoftPalette.teal200 : _teal.withValues(alpha: 0.85)),
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
        backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
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
                      color: isDark ? SoftPalette.teal700 : SoftPalette.teal100,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: isDark ? SoftPalette.teal300 : _teal,
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
                        color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray500,
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
                  color: isDark ? SoftPalette.teal200 : _teal,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
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
                  color: isDark ? SoftPalette.teal200 : _teal,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '• Dosages remain per-day (e.g. 1+1+1 stays 1+1+1).\n'
                '• The dispenser multiplies the daily dose by the selected days and hands over the full stock at once.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                ),
              ),
              const SizedBox(height: 12),
              // Section 3: Injection rule
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.adapt(SoftPalette.amber100m),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.adapt(SoftPalette.amber300)),
                ),
                child: Row(
                  children: [
                    FaIcon(FontAwesomeIcons.syringe, size: 14, color: context.adapt(SoftPalette.orange400)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Injections are strictly restricted to 1 Day only.',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: context.adapt(SoftPalette.orange400),
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
                    foregroundColor: SoftPalette.gray50,
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
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate600)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400)),
      ],
    );
  }

  // ── Main save ──────────────────────────────────────────────────────────────
  Future<void> _savePrescriptionHiveFirst() async {
    final complaint = widget.complaintController.text.trim();
    final diagnosis = widget.diagnosisController.text.trim();

    if (complaint.isEmpty || diagnosis.isEmpty) {
      AppToast.showSnackBar(context, const SnackBar(
          content: Text(
            'Both Patient Condition and Diagnosis are required!',
            style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold),
          ),
          backgroundColor: SoftPalette.red500));
      return;
    }
    final isVitalsOnly = widget.selectedPatientData?['isVitalsOnly'] == true ||
        widget.selectedPatientData?['vitalsOnly'] == true;

    if (!isVitalsOnly && widget.prescriptions.isEmpty && widget.labResults.isEmpty) {
      AppToast.showSnackBar(context, const SnackBar(
          content: Text(
            'Please add at least one medicine or lab test!',
            style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold),
          ),
          backgroundColor: SoftPalette.orange400));
      return;
    }

    // ── FIX: Final stock check at save time to catch any race conditions
    // Refresh reserved quantities once before checking all medicines
    await _buildReservedQuantities();

    for (final med in widget.prescriptions) {
      final inventoryId = med['inventoryId']?.toString() ?? '';
      if (inventoryId.isEmpty) continue;

      final inventoryMed = _allInventory.firstWhere(
        (m) => m['id']?.toString() == inventoryId ||
               ((m['_batchIds'] as List?)?.contains(inventoryId) ?? false),
        orElse: () => {},
      );
      if (inventoryMed.isEmpty) continue;

      final available = _getAvailableStock(inventoryMed);
      // At save time we include THIS session's qty in available (since
      // _getAvailableStock subtracts session qty already), so compare
      // against the required quantity.
      final medQty = med['quantity'];
      final perDayQty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
      // Re-add session qty to get "others only" available
      final othersOnly = available + perDayQty;

      final medType = (med['type'] ?? '').toString().toLowerCase();
      final medName = (med['name'] ?? '').toString().toLowerCase();
      final isSyrup = medType.contains('syrup') || medType.contains('syp') || medType.contains('susp') ||
          medName.contains('syp') || medName.contains('syrup');
      final isInj = _isInjectionOrDrip(med);
      final required = isSyrup ? 1 : (isInj ? perDayQty : perDayQty * _daysOfMedicine);

      if (required > othersOnly) {
        final rawStock = (inventoryMed['quantity'] as num?)?.toInt() ?? 0;
        if (mounted) {
          AppToast.showSnackBar(context, SnackBar(
            content: Text(
              '⚠️ "${med['name']}": Need $required (${rawStock > 0 ? "$rawStock on dispensary shelf" : "0 in stock"}). Dispensary will verify.',
            ),
            backgroundColor: SoftPalette.orange400,
            duration: const Duration(seconds: 3),
          ));
        }
        // Do NOT block saving! The dispensary is the physical source of truth for stock.
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
      final serialClean = CampSessionService.cleanSerial(widget.serialId, widget.branchId).trim().toLowerCase();
      String resolvedPatientName = (patientData['patientName'] ?? patientData['name'] ?? patientData['fullName'])?.toString().trim() ?? '';
      if (resolvedPatientName.isEmpty || resolvedPatientName.toLowerCase() == 'unknown' || resolvedPatientName.toLowerCase() == 'unknown patient') {
        final normB = widget.branchId.toLowerCase().trim();
        final normS = serialClean.toLowerCase();
        try {
          if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            final eBox = Hive.box(LocalStorageService.entriesBox);
            final directEntry = eBox.get('$normB-$normS') ??
                eBox.get('$normB-${normS.toUpperCase()}') ??
                eBox.get(normS) ??
                eBox.get(normS.toUpperCase());
            if (directEntry is Map) {
              final n = (directEntry['patientName'] ?? directEntry['name'] ?? directEntry['fullName'])?.toString().trim();
              if (n != null && n.isNotEmpty && n.toLowerCase() != 'unknown' && n.toLowerCase() != 'unknown patient') {
                resolvedPatientName = n;
              }
            }
          }
        } catch (_) {}
      }
      if (resolvedPatientName.isEmpty) resolvedPatientName = 'Unknown Patient';

      final dateKey = CampSessionService.getDateKeyFromSerial(serialClean).isNotEmpty
          ? CampSessionService.getDateKeyFromSerial(serialClean)
          : (patientData['dateKey']?.toString() ?? LocalStorageService.getTodayDateKey());

      final medicineList = widget.prescriptions.map((m) {
        return {
          'name':        m['name'],
          'formula':     m['formula'] ?? '',
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
        'medicines':       medicineList,
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
        // Lets peers link a no-CNIC patient's multi-day restriction to the family phone.
        'phone':           (patientData['phone'] ?? patientData['contactNumber'] ?? patientData['mobile'])?.toString(),
        'patientName':     resolvedPatientName,
        'name':            resolvedPatientName,
        'patientAge':      patientData['age']?.toString() ?? 'N/A',
        'patientGender':   patientData['gender']?.toString() ?? 'N/A',
        'complaint':       complaint,
        'condition':       complaint,
        'diagnosis':       diagnosis,
        'prescriptions':   medicineList,
        'medicines':       medicineList,
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
            // Same fields the LAN receivers store, so this desk's record (the one synced to
            // Firestore) matches theirs and the no-CNIC fallback can use it.
            patientName: resolvedPatientName,
            guardianCnic: patientData['guardianCnic']?.toString(),
            phone: (patientData['phone'] ?? patientData['contactNumber'] ?? patientData['mobile'])?.toString(),
          );
          debugPrint('[DoctorPanel] ✅ Individual restriction saved for: $pId ($days days)');
        } else {
          debugPrint('[DoctorPanel] ⚠️ Cannot save restriction: No patientId found.');
        }
      }

      // 2. Embed into Hive entriesBox (updating exact matching serial keys)
      final entriesBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final normBranch = widget.branchId.trim().toLowerCase();
      final normSerialUpper = serialClean.toUpperCase();
      final canonicalKey = '$normBranch-$normSerialUpper';

      final matchingKeys = <dynamic>[];
      final candidateVariants = <String>{
        canonicalKey,
        '$normBranch-$serialClean',
        normSerialUpper,
        serialClean,
      };
      for (final ck in candidateVariants) {
        if (entriesBox.containsKey(ck)) {
          matchingKeys.add(ck);
        }
      }

      if (matchingKeys.isEmpty) {
        matchingKeys.add(canonicalKey);
      }

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
        base['medicines']      = medicineList;
        base['prescriptions']  = medicineList;
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


      // 3. LAN broadcast — send clinical prescription update ONLY (do not re-broadcast receptionist entry fields)
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.savePrescription,
          branchId: widget.branchId,
          data: fullPrescriptionData,
        ));
      } catch (e) {
        debugPrint('[DoctorPanel] LAN Broadcast notice: $e');
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
          messageColor: SoftPalette.gray50,
          backgroundColor: SoftPalette.red500,
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
      final chargeData = {
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
      };

      // Always through the LAN outbox: it is kept until the server confirms it, so a charge
      // made while the server was unreachable reaches it on reconnect. (It used to go to this
      // PC's cloud queue only, which is cleared of dispensary items once the PC is back on
      // the LAN, so the charge was lost.)
      RealtimeManager().sendMessage(RealtimeEvents.payload(
        type: 'save_dispensary_charge',
        branchId: branchId,
        data: chargeData,
      ));
      if (RealtimeManager().hasServerLink) return;

      LocalStorageService.enqueueSync({
        'type':      'save_dispensary_charge',
        'branchId':  branchId,
        'serial':    serial,
        'dateKey':   dateKey,
        'queueType': queueType,
        'data': chargeData,
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

      if (isOnline && !QuotaService.isPausedForDailyReset) {
        final branchRef = CloudDb.instance.collection('branches').doc(widget.branchId.toLowerCase().trim());

        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: widget.branchId,
          dateKey: dateKey,
          campId: fullData['campId']?.toString() ?? fullData['dispensaryId']?.toString(),
          dispensaryTag: fullData['dispensaryTag']?.toString(),
          serial: serial,
        );

        // Single canonical write: updates the serial doc with clinical details + status via CloudDb REST
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
            .timeout(const Duration(seconds: 15));

        // Update local entry ONLY after confirmed CloudDb write
        try {
          if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            final eBox = Hive.box(LocalStorageService.entriesBox);
            final normBranch = widget.branchId.toLowerCase().trim();
            final canonicalKey = '$normBranch-${serial.toUpperCase()}';
            final existing = eBox.get(canonicalKey) ?? eBox.get(serial);
            if (existing is Map) {
              final upd = Map<String, dynamic>.from(existing);
              upd['pendingSync'] = false;
              upd['synced'] = true;
              upd['prescriptionSynced'] = true;
              upd['syncStatus'] = 'synced';
              await eBox.put(canonicalKey, upd);
            }
          }
        } catch (_) {}
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
    if (RealtimeManager().isConnected) {
      debugPrint('[DoctorPanel] LAN connected — skipping cloud enqueue for $serial');
      return;
    }
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
    final isVitalsOnly = widget.selectedPatientData?['isVitalsOnly'] == true ||
        widget.selectedPatientData?['vitalsOnly'] == true;
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
                    color: isDark ? SoftPalette.violet800 : SoftPalette.purple150m,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isDark ? SoftPalette.violet500 : SoftPalette.purple400, width: 1.5),
                  ),
                  child: Row(children: [
                    Icon(Icons.monitor_heart, color: isDark ? SoftPalette.purple300 : SoftPalette.purple600, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🩺 Vitals Inspection Only',
                            style: TextStyle(
                              color: isDark ? SoftPalette.purple150 : SoftPalette.violet700,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'This patient has come only for vitals inspection. No medicines or lab tests are required. Simply save to complete.',
                            style: TextStyle(
                              color: isDark ? SoftPalette.purple150 : SoftPalette.purple600,
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
                Icon(Icons.description, color: context.adapt(_teal), size: compact ? 18 : 22),
                SizedBox(width: compact ? 6 : 10),
                Text('Patient Condition',
                    style: TextStyle(
                        fontSize: compact ? 15 : 18, fontWeight: FontWeight.bold, color: context.adapt(_teal))),
              ]),
              const SizedBox(height: 8),
              TextField(
                focusNode: _complaintFocus,
                controller: widget.complaintController,
                maxLines: 2,
                style: TextStyle(fontSize: compact ? 13 : 15, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  hintText: "Describe patient's condition...",
                  hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray350),
                  filled: true,
                  fillColor: isDark ? SoftPalette.slate900 : SoftPalette.green100m,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none),
                  contentPadding: const EdgeInsets.all(12), isDense: compact,
                ),
              ),
              SizedBox(height: compact ? 12 : 16),

              // ── Diagnosis ─────────────────────────────────────────────
              Row(children: [
                Icon(Icons.medical_services, color: context.adapt(_teal), size: compact ? 18 : 22),
                SizedBox(width: compact ? 6 : 10),
                Text('Diagnosis',
                    style: TextStyle(
                        fontSize: compact ? 15 : 18, fontWeight: FontWeight.bold, color: context.adapt(_teal))),
              ]),
              const SizedBox(height: 8),
              TextField(
                focusNode: _diagnosisFocus,
                controller: widget.diagnosisController,
                maxLines: 2,
                style: TextStyle(fontSize: compact ? 13 : 15, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                decoration: InputDecoration(
                  hintText: 'Enter diagnosis...',
                  hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray350),
                  filled: true,
                  fillColor: isDark ? SoftPalette.slate900 : SoftPalette.green100m,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: isDark ? const BorderSide(color: SoftPalette.slate700) : BorderSide.none),
                  contentPadding: const EdgeInsets.all(12), isDense: compact,
                ),
              ),
              SizedBox(height: compact ? 12 : 16),

              // ── For Vitals Only: Immediate Action & Optional Prescribing ───
              if (isVitalsOnly) ...[
                if (!_showMedicinesForVitalsOnly) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      focusNode: _saveButtonFocus,
                      onPressed: widget.isSaving ? null : _savePrescriptionHiveFirst,
                      icon: widget.isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                            )
                          : const Icon(Icons.check_circle_outline, color: SoftPalette.gray50, size: 20),
                      label: Text(
                        widget.isSaving ? 'Saving...' : 'Save & Complete Vitals Inspection',
                        style: TextStyle(
                          fontSize: compact ? 13.5 : 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SoftPalette.purple600,
                        foregroundColor: SoftPalette.gray50,
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: compact ? 12 : 16,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Center(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showMedicinesForVitalsOnly = !_showMedicinesForVitalsOnly),
                    icon: Icon(
                      _showMedicinesForVitalsOnly ? Icons.expand_less : Icons.add_circle_outline,
                      size: 16,
                      color: isDark ? SoftPalette.purple350 : SoftPalette.purple600,
                    ),
                    label: Text(
                      _showMedicinesForVitalsOnly
                          ? 'Hide Medicines & Lab Tests'
                          : '＋ Prescribe Medicines or Labs (Optional)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isDark ? SoftPalette.purple350 : SoftPalette.purple600,
                      ),
                    ),
                  ),
                ),
                if (_showMedicinesForVitalsOnly) const SizedBox(height: 10),
              ],

              if (!isVitalsOnly || _showMedicinesForVitalsOnly) ...[
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
                        icon: FaIcon(FontAwesomeIcons.arrowsRotate, size: 14, color: context.adapt(_teal)),
                        tooltip: 'Restore & Refresh Inventory from Cloud',
                        onPressed: () async {
                          await LocalStorageService.downloadInventory(widget.branchId, forceFull: true);
                          await _loadInventory();
                          if (mounted) {
                            AppToast.showSnackBar(context, 
                              const SnackBar(
                                content: Text('✅ Medicines restored and synced from Cloud'),
                                backgroundColor: SoftPalette.green400,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton.icon(
                        onPressed: () => _addMedicineDialog(),
                        icon: const Icon(Icons.add, size: 14),
                        label: Text('Custom', style: TextStyle(fontSize: compact ? 11 : 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDark ? SoftPalette.teal300 : _teal,
                          side: BorderSide(color: isDark ? SoftPalette.teal300 : _teal, width: 1),
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
                            color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isFocused ? _teal : (isDark ? SoftPalette.slate700 : _teal.withValues(alpha: 0.35)),
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
                                  color: context.adapt(_teal).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(Icons.search, color: context.adapt(_teal), size: 18),
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
                                        color: isDark ? SoftPalette.gray50 : SoftPalette.gray700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Click to search inventory by name, formula, or type',
                                      style: TextStyle(
                                        fontSize: compact ? 10.5 : 11.5,
                                        color: isDark ? SoftPalette.slate350 : SoftPalette.gray350,
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
                                        color: SoftPalette.gray50,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(Icons.arrow_forward_ios_rounded, color: SoftPalette.gray50, size: 10),
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
                    widget.prescriptions.where((m) => _isInventoryMed(m) && !_isInjectionOrDrip(m)).toList(),
                    _teal, compact: compact),
                _buildMedicineSection(
                    'Inventory Injectables', FontAwesomeIcons.syringe,
                    widget.prescriptions.where((m) => _isInventoryMed(m) && _isInjectionOrDrip(m)).toList(),
                    _orange, compact: compact),
                _buildMedicineSection(
                    'Custom Medicines', FontAwesomeIcons.prescriptionBottle,
                    widget.prescriptions.where((m) => !_isInventoryMed(m) && !_isInjectionOrDrip(m)).toList(),
                    _blueGrey, compact: compact),
                _buildMedicineSection(
                    'Custom Injectables', FontAwesomeIcons.syringe,
                    widget.prescriptions.where((m) => !_isInventoryMed(m) && _isInjectionOrDrip(m)).toList(),
                    _orange, compact: compact),

                const Divider(height: 1),
                SizedBox(height: compact ? 12 : 20),

                // ── Lab tests ─────────────────────────────────────────────
                _sectionHeader(widget.isPhysiotherapist ? 'Physiotherapies' : 'Lab Tests', widget.isPhysiotherapist ? FontAwesomeIcons.personWalking : FontAwesomeIcons.flask,
                    compact: compact,
                    action: IconButton(
                      icon: Icon(Icons.add_circle_outline, color: context.adapt(_teal), size: compact ? 20 : 24),
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
                      backgroundColor: isDark ? SoftPalette.slate900 : null,
                      side: BorderSide(color: selected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
                      checkmarkColor: SoftPalette.gray50,
                      labelStyle: TextStyle(color: selected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : SoftPalette.gray900A87)),
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
                          fontSize: compact ? 13 : 16, fontWeight: FontWeight.bold, color: context.adapt(_teal))),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: widget.labResults
                        .where((l) => !_currentQuickList.contains(l['name']))
                        .map((l) => Chip(
                              label: Text(l['name'], style: TextStyle(fontSize: compact ? 11 : 13)),
                              backgroundColor: SoftPalette.orange350,
                              labelStyle: const TextStyle(color: SoftPalette.gray50),
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
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    focusNode: _saveButtonFocus,
                    onPressed: widget.isSaving ? null : _savePrescriptionHiveFirst,
                    icon: widget.isSaving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                        : Icon(isVitalsOnly ? Icons.check_circle_outline : Icons.save, color: SoftPalette.gray50),
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
                      backgroundColor: isVitalsOnly ? SoftPalette.purple600 : _teal,
                      foregroundColor: SoftPalette.gray50,
                      padding: EdgeInsets.symmetric(
                          horizontal: 24, vertical: compact ? 14 : 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                      elevation: 6,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      );
    });
  }

  bool get _isDark => _resolveIsDark();

  bool _resolveIsDark([BuildContext? ctx]) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    try {
      final c = ctx ?? (mounted ? context : null);
      if (c != null) return Theme.of(c).brightness == Brightness.dark;
    } catch (_) {}
    return false;
  }
}
