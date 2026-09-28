// lib/pages/dispensary/dispensar/patient_form.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:another_flushbar/flushbar.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'patient_form_helper.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/theme/app_theme.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/widgets/file_action_helper.dart';
import 'package:gmwf/design/design_system.dart';

class PatientForm extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> queueEntry;
  final VoidCallback? onDispensed;
  final String? dispenserName;
  const PatientForm({
    super.key,
    required this.branchId,
    required this.queueEntry,
    this.onDispensed,
    this.dispenserName,
  });
  @override
  State<PatientForm> createState() => _PatientFormState();
}

class _PatientFormState extends State<PatientForm> {
  Map<String, dynamic> _data = {};
  String? _gender;
  String? _age;
  String? _branchName;
  bool _isDispensed = false;
  bool _isPrinting = false;
  bool _isDispensing = false;
  bool _loadingBranch = true;
  bool _isLoadingPrescription = true;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  int? _selectedSyringeCount;
  String? _selectedSyringeHiveKey;
  int? _selectedNeedleCount;

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  // ─── Queue-type normaliser ────────────────────────────────────────────────
  String _normaliseQueueType(String? raw) {
    final s = (raw ?? '').toLowerCase().trim();
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      if (_isKarachi) return 'zakat';
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') return 'gmwf';
    return 'zakat';
  }

  // ─── Serial resolver ──────────────────────────────────────────────────────
  String get _resolvedSerial {
    for (final f in ['serial', 'id', 'tokenSerial', 'tokenId', 'serialNumber']) {
      final v = widget.queueEntry[f]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    for (final f in ['serial', 'id', 'tokenSerial', 'tokenId']) {
      final v = _data[f]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    final embedded = widget.queueEntry['prescription'];
    if (embedded is Map) {
      for (final f in ['serial', 'id']) {
        final v = embedded[f]?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  // ─── Queue-type resolver ──────────────────────────────────────────────────
  String get _resolvedQueueType {
    final serial = _resolvedSerial;
    if (serial.isNotEmpty) {
      final raw = Hive.box(LocalStorageService.entriesBox)
          .get('${widget.branchId}-$serial')?['queueType']?.toString();
      if (raw != null && raw.isNotEmpty) return _normaliseQueueType(raw);
    }
    final fromQueue = widget.queueEntry['queueType']?.toString();
    if (fromQueue != null && fromQueue.isNotEmpty) return _normaliseQueueType(fromQueue);
    final fromData = _data['queueType']?.toString();
    if (fromData != null && fromData.isNotEmpty) return _normaliseQueueType(fromData);
    return 'zakat';
  }

  List<dynamic> _getPrescriptionsList() {
    final fromData = _data['prescriptions'] ?? _data['medicines'];
    if (fromData is List && fromData.isNotEmpty) return fromData;
    final embeddedData = _data['prescription'];
    if (embeddedData is Map) {
      final embList = embeddedData['prescriptions'] ?? embeddedData['medicines'];
      if (embList is List && embList.isNotEmpty) return embList;
    }
    final fromQueue = widget.queueEntry['prescriptions'] ?? widget.queueEntry['medicines'];
    if (fromQueue is List && fromQueue.isNotEmpty) return fromQueue;
    final embeddedQueue = widget.queueEntry['prescription'];
    if (embeddedQueue is Map) {
      final embList = embeddedQueue['prescriptions'] ?? embeddedQueue['medicines'];
      if (embList is List && embList.isNotEmpty) return embList;
    }
    return [];
  }

  String _getDiagnosisText() {
    final fromData = _data['diagnosis'];
    if (fromData != null && fromData.toString().trim().isNotEmpty) return fromData.toString().trim();
    final embeddedData = _data['prescription'];
    if (embeddedData is Map && embeddedData['diagnosis'] != null) {
      final d = embeddedData['diagnosis'].toString().trim();
      if (d.isNotEmpty) return d;
    }
    final fromQueue = widget.queueEntry['diagnosis'];
    if (fromQueue != null && fromQueue.toString().trim().isNotEmpty) return fromQueue.toString().trim();
    final embeddedQueue = widget.queueEntry['prescription'];
    if (embeddedQueue is Map && embeddedQueue['diagnosis'] != null) {
      final d = embeddedQueue['diagnosis'].toString().trim();
      if (d.isNotEmpty) return d;
    }
    return '';
  }

  List<dynamic> _getLabResultsList() {
    final fromData = _data['labResults'];
    if (fromData is List && fromData.isNotEmpty) return fromData;
    final embeddedData = _data['prescription'];
    if (embeddedData is Map && embeddedData['labResults'] is List) {
      final list = embeddedData['labResults'] as List;
      if (list.isNotEmpty) return list;
    }
    final fromQueue = widget.queueEntry['labResults'];
    if (fromQueue is List && fromQueue.isNotEmpty) return fromQueue;
    final embeddedQueue = widget.queueEntry['prescription'];
    if (embeddedQueue is Map && embeddedQueue['labResults'] is List) {
      final list = embeddedQueue['labResults'] as List;
      if (list.isNotEmpty) return list;
    }
    return [];
  }

  int get _daysOfMedicine {
    final fromData = _data['daysOfMedicine'];
    if (fromData is int && fromData >= 1) return fromData;
    final embedded = _data['prescription'];
    if (embedded is Map) {
      final d = embedded['daysOfMedicine'];
      if (d is int && d >= 1) return d;
    }
    final queueEmbedded = widget.queueEntry['prescription'];
    if (queueEmbedded is Map) {
      final d = queueEmbedded['daysOfMedicine'];
      if (d is int && d >= 1) return d;
    }
    final topLevel = widget.queueEntry['daysOfMedicine'];
    if (topLevel is int && topLevel >= 1) return topLevel;
    final suggested = _suggestedDays;
    if (suggested >= 1) return suggested;
    return 1;
  }

  // ─── Suggested days (paid at token desk) ──────────────────────────────────
  int get _suggestedDays {
    final s = widget.queueEntry['suggestedDays'];
    if (s is int && s >= 1) return s;
    
    final serial = _resolvedSerial;
    if (serial.isNotEmpty) {
      final entryRaw = Hive.box(LocalStorageService.entriesBox).get('${widget.branchId}-$serial');
      if (entryRaw != null) {
        final entry = Map<String, dynamic>.from(entryRaw);
        final sd = entry['suggestedDays'];
        if (sd is int && sd >= 1) return sd;
      }
    }
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _loadBranchName();
    _loadPrescription();
    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      final data = event['data'] as Map<String, dynamic>? ?? {};
      if (type == null) return;
      final eventSerial = data['serial']?.toString().trim().toLowerCase();
      final mySerial = _resolvedSerial.toLowerCase();
      final eventBranch = data['branchId']?.toString().trim().toLowerCase();
      final myBranch = widget.branchId.toLowerCase().trim();
      if (eventBranch != null && eventBranch != myBranch) return;
      if (eventSerial != null && eventSerial.isNotEmpty &&
          mySerial.isNotEmpty && eventSerial != mySerial) return;
      if (type == RealtimeEvents.savePrescription ||
          type == RealtimeEvents.saveEntry ||
          type == 'dispense_completed') {
        _loadPrescription();
      }
    });
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    super.dispose();
  }

  static final Map<String, String> _cachedBranchNames = {};

  Future<void> _loadBranchName() async {
    if (widget.branchId.isEmpty) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
      return;
    }
    if (_cachedBranchNames.containsKey(widget.branchId)) {
      if (mounted) setState(() {
        _branchName = _cachedBranchNames[widget.branchId];
        _loadingBranch = false;
      });
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches').doc(widget.branchId).get(const GetOptions(source: Source.cache));
      final name = doc.exists ? (doc.data()?['name'] ?? 'Free Dispensary') : 'Free Dispensary';
      _cachedBranchNames[widget.branchId] = name;
      if (mounted) setState(() {
        _branchName = name;
        _loadingBranch = false;
      });
    } catch (_) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
    }
  }

  @override
  void didUpdateWidget(covariant PatientForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queueEntry != widget.queueEntry || oldWidget.branchId != widget.branchId) {
      _selectedSyringeCount = null;
      _selectedSyringeHiveKey = null;
      _selectedNeedleCount = null;
      _loadPrescription();
    }
  }

  // ─── Prescription loader ──────────────────────────────────────────────────
  Future<void> _loadPrescription() async {
    if (!mounted) return;
    setState(() => _isLoadingPrescription = true);
    try {
      // 1. Direct embedded check from widget.queueEntry (fastest and most accurate)
      final directEmbedded = widget.queueEntry['prescription'];
      if (directEmbedded is Map && directEmbedded.isNotEmpty &&
          (directEmbedded['prescriptions'] is List || directEmbedded['complaint'] != null || directEmbedded['diagnosis'] != null)) {
        if (mounted) {
          setState(() {
            _data = Map<String, dynamic>.from(directEmbedded);
            _gender = _resolveGender();
            _age = _resolveAge();
            _isDispensed = (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
            _isLoadingPrescription = false;
          });
          return;
        }
      }

      String serial = '';
      for (final f in ['serial', 'id', 'tokenSerial', 'tokenId', 'serialNumber']) {
        final v = widget.queueEntry[f]?.toString().trim() ?? '';
        if (v.isNotEmpty) { serial = v.toLowerCase(); break; }
      }
      String cnic = '';
      for (final f in ['patientCnic', 'cnic', 'guardianCnic', 'patientCNIC', 'guardianCNIC']) {
        final v = (widget.queueEntry[f]?.toString() ?? '')
            .trim().replaceAll('-', '').replaceAll(' ', '').toLowerCase();
        if (v.isNotEmpty && v != '0000000000000') { cnic = v; break; }
      }
      Map<String, dynamic> found = {};
      found = _searchHive(serial, cnic);
      if (found.isEmpty && serial.isNotEmpty) {
        final presc = LocalStorageService.getLocalPrescription(serial);
        if (presc != null) {
          found = presc;
        }
      }
      if (found.isEmpty) {
        final normB = widget.branchId.toLowerCase().trim();
        final normS = serial.toLowerCase();
        for (final k in Hive.box(LocalStorageService.entriesBox).keys) {
          final kStr = k.toString().toLowerCase();
          if (kStr == '$normB-$normS' || kStr.endsWith('-$normS') || kStr == normS) {
            final entry = Hive.box(LocalStorageService.entriesBox).get(k);
            final embedded = (entry is Map) ? entry['prescription'] : null;
            if (embedded is Map && embedded.isNotEmpty) {
              found = Map<String, dynamic>.from(embedded);
              break;
            }
          }
        }
      }
      if (found.isEmpty && serial.isNotEmpty && cnic.isNotEmpty) {
        found = await _fetchFromPrescriptionsByCnic(serial, cnic);
        if (found.isNotEmpty) await LocalStorageService.saveLocalPrescription(found);
      }
      if (found.isEmpty && serial.isNotEmpty) {
        found = await _fetchFromSerialsEmbedded(serial);
        if (found.isNotEmpty) await LocalStorageService.saveLocalPrescription(found);
      }
      if (found.isEmpty &&
          (widget.queueEntry['status'] == 'completed' || widget.queueEntry['dispenseStatus'] == 'dispensed') &&
          (widget.queueEntry['isVitalsOnly'] == true ||
              widget.queueEntry['vitalsOnly'] == true ||
              widget.queueEntry['visitReason']?.toString().toLowerCase().contains('vitals') == true)) {
        found = {
          ...widget.queueEntry,
          'condition': widget.queueEntry['condition'] ?? widget.queueEntry['complaint'] ?? 'Vitals Inspection Only',
          'diagnosis': widget.queueEntry['diagnosis'] ?? 'Vitals Checked',
          'prescriptions': <Map<String, dynamic>>[],
          'labResults': <Map<String, dynamic>>[],
          'isVitalsOnly': true,
        };
      }
      final rawVitals = widget.queueEntry['vitals'];
      final vitals = (rawVitals is Map) ? Map<String, dynamic>.from(rawVitals) : <String, dynamic>{};
      final dispenseStatus = (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase();
      if (mounted) {
        setState(() {
          _data = found;
          _gender = _resolveGender();
          _age = _resolveAge();
          _isDispensed = dispenseStatus == 'dispensed';
        });
      }
    } catch (e) {
      debugPrint('[PatientForm] Error loading prescription: $e');
    } finally {
      if (mounted) setState(() => _isLoadingPrescription = false);
    }
  }

  Map<String, dynamic> _searchHive(String serial, String cnic) {
    final normSerial = serial.trim().toLowerCase();
    final normCnic   = cnic.trim().replaceAll('-', '').replaceAll(' ', '').toLowerCase();
    final normBranch = widget.branchId.trim().toLowerCase();
    final patientName = (widget.queueEntry['patientName'] ??
            widget.queueEntry['name'] ??
            _data['patientName'] ??
            _data['name'] ??
            '')
        .toString()
        .trim();

    // 1. Prioritize direct embedded prescription in entriesBox for this exact branch token
    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final entriesBox = Hive.box(LocalStorageService.entriesBox);
        final directEntry = entriesBox.get('$normBranch-$normSerial') ??
            entriesBox.get('$normBranch-${normSerial.toUpperCase()}') ??
            entriesBox.get(normSerial);
        if (directEntry is Map && directEntry['prescription'] is Map) {
          final emb = Map<String, dynamic>.from(directEntry['prescription'] as Map);
          emb['doctorName'] ??= directEntry['doctorName'] ?? directEntry['prescribedBy'];
          emb['doctorId'] ??= directEntry['doctorId'];
          emb['prescribedBy'] ??= directEntry['prescribedBy'] ?? directEntry['doctorName'];
          if (emb.isNotEmpty) return emb;
        }
      }
    } catch (_) {}

    // 2. Strict validated lookup in local prescriptions
    final presc = LocalStorageService.getLocalPrescription(
      normSerial,
      cnic: normCnic,
      patientName: patientName,
      branchId: widget.branchId,
    );
    if (presc != null && presc.isNotEmpty) return presc;

    return {};
  }

  Future<Map<String, dynamic>> _fetchFromPrescriptionsByCnic(String serial, String cnic) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches').doc(widget.branchId)
          .collection('prescriptions').doc(cnic)
          .collection('prescriptions').doc(serial).get()
          .timeout(const Duration(seconds: 4));
      if (snap.exists && snap.data() != null) {
        final d = Map<String, dynamic>.from(snap.data()!);
        d['id'] = snap.id; d['serial'] = snap.id;
        return d;
      }
    } catch (e) { debugPrint('[PatientForm] Firestore prescriptions/{cnic} error: $e'); }
    return {};
  }

  Future<Map<String, dynamic>> _fetchFromSerialsEmbedded(String serial) async {
    try {
      final dateKey = CampSessionService.getDateKeyFromSerial(serial).isNotEmpty
          ? CampSessionService.getDateKeyFromSerial(serial)
          : DateFormat('ddMMyy').format(DateTime.now());
      if (dateKey.isEmpty) return {};

      final explicitType = (widget.queueEntry['queueType'] ?? _data['queueType'])?.toString().toLowerCase().trim();
      final typesToCheck = (explicitType != null && explicitType.isNotEmpty && ['zakat', 'non-zakat', 'gmwf'].contains(explicitType))
          ? [explicitType]
          : ['zakat', 'non-zakat', 'gmwf'];

      final campDocKey = CampSessionService.getCampDateDocId(
        branchId: widget.branchId,
        dateKey: dateKey,
        campId: widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? _data['campId']?.toString() ?? _data['dispensaryId']?.toString(),
        dispensaryTag: widget.queueEntry['dispensaryTag']?.toString() ?? _data['dispensaryTag']?.toString(),
        serial: serial,
      );

      for (final type in typesToCheck) {
        final snap = await FirebaseFirestore.instance
            .collection('branches').doc(widget.branchId)
            .collection('serials').doc(campDocKey)
            .collection(type).doc(serial).get()
            .timeout(const Duration(seconds: 4));
        if (snap.exists && snap.data() != null) {
          final d = Map<String, dynamic>.from(snap.data()!);
          d['queueType'] = type;
          final embedded = d['prescription'];
          if (embedded is Map && embedded.isNotEmpty) {
            final result = Map<String, dynamic>.from(embedded);
            result['queueType'] = type;
            return result;
          }
          if (d.containsKey('prescriptions')) return d;
        }
      }
    } catch (e) { debugPrint('[PatientForm] Firestore serials embedded error: $e'); }
    return {};
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  bool get _hasPrintableContent {
    final lab = (_data['labResults'] ?? []) as List;
    final rx = (_data['prescriptions'] ?? _data['medicines'] ?? []) as List;
    return lab.isNotEmpty || rx.isNotEmpty;
  }

  String _getMedAbbrev(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('syrup')) return 'syp.';
    if (t.contains('injection')) return 'inj.';
    if (t.contains('tablet')) return 'tab.';
    if (t.contains('capsule')) return 'cap.';
    if (t.contains('drip')) return 'drip.';
    if (t.contains('syringe')) return 'syr.';
    return '';
  }

  String _firstNonEmpty(List<dynamic> candidates) {
    for (final c in candidates) {
      final s = c?.toString().trim() ?? '';
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  // ─── Print & Share Options ────────────────────────────────────────────────
  Future<void> _showPrintOptionsSheet() async {
    if (!_hasPrintableContent) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing to print'), backgroundColor: Colors.orange));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PatientPrintOptionsSheet(
        data: _data,
        branchName: _branchName ?? 'Free Dispensary',
        serial: _resolvedSerial,
        queueType: _resolvedQueueType,
      ),
    );
  }

  // ─── Inventory deduction ──────────────────────────────────────────────────
  static bool _isInjectableType(String? type) {
    final t = (type ?? '').toLowerCase();
    return t.contains('injection') || t.contains('inj') ||
        t.contains('infusion') || t.contains('inf') ||
        t.contains('drip') || t.contains('syringe') || t.contains('nebulization');
  }

  static bool _isSyrupType(String? type, String? name) {
    final t = (type ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    return t.contains('syrup') || t.contains('syp') || n.contains('syrup') || n.contains('syp');
  }

  int _getAutoSyringeCount(List<dynamic> allPrescriptions) {
    int totalInj = 0;
    for (final med in allPrescriptions) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final type = (medMap['type']?.toString() ?? '').toLowerCase();
      final name = (medMap['name']?.toString() ?? '').toLowerCase();
      final isInjOrDripOrIV = type.contains('injection') || type.contains('inj') ||
                              type.contains('infusion') || type.contains('inf') ||
                              type.contains('drip') || type.contains('iv') || type.contains('i.v') ||
                              name.contains('inj') || name.contains('iv') || name.contains('i.v.');
      final isSyringe = type.contains('syringe') || name.contains('syringe');
      if (isInjOrDripOrIV && !isSyringe) {
        final qtyRaw = medMap['quantity'] ?? medMap['qty'] ?? 1;
        final qty = (qtyRaw is num) ? qtyRaw.toInt() : (int.tryParse(qtyRaw.toString()) ?? 1);
        totalInj += qty > 0 ? qty : 1;
      }
    }
    return totalInj;
  }

  int _getEffectiveSyringeCount(List<dynamic> allPrescriptions) {
    final autoCount = _getAutoSyringeCount(allPrescriptions).clamp(0, 3);
    if (autoCount == 0) return 0;
    if (_selectedSyringeCount != null) {
      return _selectedSyringeCount!.clamp(0, 3);
    }
    return autoCount;
  }

  Future<List<Map<String, dynamic>>> _deductInventoryLocally(
      String branchId, String serial, List<dynamic> medicines, int days) async {
    final activeCamp = widget.queueEntry['campId']?.toString() ??
        widget.queueEntry['dispensaryId']?.toString() ??
        CampSessionService.getActiveCamp(branchId) ??
        '';
    final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString() ?? serial;
    final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();
    final List<Map<String, dynamic>> allDeductedBatches = [];

    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final rawMedicineId = (medMap['inventoryId'] ??
              medMap['medicineId'] ?? medMap['id'] ?? '').toString().trim();
      final perDayRaw = medMap['quantity'] ?? medMap['qty'] ?? 0;
      final perDay = perDayRaw is num
          ? perDayRaw.toDouble()
          : double.tryParse(perDayRaw.toString()) ?? 0.0;
      if (perDay <= 0) continue;
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final multiplier = isSyrup
          ? 1.0
          : (_isInjectableType(medMap['type']?.toString()) ? 1.0 : days.toDouble());
      final qtyNum = isSyrup ? 1.0 : perDay * multiplier;
      debugPrint('[PatientForm] FEFO deduct for ${medMap['name']} ($rawMedicineId): perDay=$perDay × $multiplier = $qtyNum');

      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        var targetName = MasterProformaService.cleanBrandToFormula((medMap['name'] ?? medMap['formula'] ?? '').toString().toLowerCase().trim());
        var targetFormula = MasterProformaService.cleanBrandToFormula((medMap['formula'] ?? medMap['name'] ?? '').toString().toLowerCase().trim());
        var targetType = (medMap['type'] ?? medMap['dosageForm'] ?? '').toString().toLowerCase().trim();
        var targetDose = (medMap['dose'] ?? medMap['dosage'] ?? '').toString().toLowerCase().trim();
        final targetId = rawMedicineId.toLowerCase();

        // Seed canonical attributes from raw medicine ID if available in stockBox
        if (rawMedicineId.isNotEmpty) {
          final refItem = stockBox.get('stock:$rawMedicineId') ?? stockBox.get(rawMedicineId);
          if (refItem is Map) {
            if (targetName.isEmpty) {
              targetName = MasterProformaService.cleanBrandToFormula((refItem['name'] ?? refItem['formula'] ?? '').toString().toLowerCase().trim());
            }
            if (targetFormula.isEmpty) {
              targetFormula = MasterProformaService.cleanBrandToFormula((refItem['formula'] ?? refItem['name'] ?? '').toString().toLowerCase().trim());
            }
            if (targetType.isEmpty) {
              targetType = (refItem['type'] ?? refItem['dosageForm'] ?? refItem['form'] ?? '').toString().toLowerCase().trim();
            }
            if (targetDose.isEmpty) {
              targetDose = (refItem['dose'] ?? refItem['dosage'] ?? '').toString().toLowerCase().trim();
            }
          }
        }

        // Find all matching batches for this medicine in this camp
        final hasCamps = CampSessionService.hasCampsForBranch(branchId);
        final List<Map<String, dynamic>> matchingBatches = [];

        for (final key in stockBox.keys) {
          final val = stockBox.get(key);
          if (val is! Map) continue;
          final vMap = Map<String, dynamic>.from(val);
          final vKey = key.toString();
          vMap['_hiveKey'] = vKey;

          if (hasCamps && activeCamp.isNotEmpty && activeCamp != 'all') {
            final campMatch = CampSessionService.matchesCamp(
              selectedCamp: activeCamp,
              dispensaryId: vMap['dispensaryId']?.toString(),
              campId: vMap['campId']?.toString(),
              serial: (vMap['barcode'] ?? vMap['code'] ?? vMap['id'])?.toString(),
            );
            if (!campMatch) continue;
          }

          final vId = (vMap['id'] ?? vMap['medicineId'] ?? vMap['docId'] ?? '').toString().trim().toLowerCase();
          final vName = MasterProformaService.cleanBrandToFormula((vMap['name'] ?? vMap['formula'] ?? '').toString().toLowerCase().trim());
          final vFormula = MasterProformaService.cleanBrandToFormula((vMap['formula'] ?? vMap['name'] ?? '').toString().toLowerCase().trim());
          final vType = (vMap['type'] ?? vMap['dosageForm'] ?? vMap['form'] ?? '').toString().toLowerCase().trim();
          final vDose = (vMap['dose'] ?? vMap['dosage'] ?? '').toString().toLowerCase().trim();

          bool isMatch = false;
          if (targetId.isNotEmpty && (vId == targetId || vKey == 'stock:$targetId' || vKey == targetId)) {
            isMatch = true;
          } else if (targetName.isNotEmpty &&
              (vName == targetName || (vFormula.isNotEmpty && vFormula == targetFormula) ||
               vName.contains(targetName) || targetName.contains(vName))) {
            final typeMatch = targetType.isEmpty || vType.isEmpty || vType == targetType ||
                (targetType.contains('tab') && vType.contains('tab')) ||
                (targetType.contains('cap') && vType.contains('cap')) ||
                (targetType.contains('syp') && vType.contains('syp')) ||
                (targetType.contains('inj') && vType.contains('inj'));
            final doseMatch = targetDose.isEmpty || vDose.isEmpty || vDose == targetDose;
            if (typeMatch && doseMatch) {
              isMatch = true;
            }
          }

          if (isMatch) {
            matchingBatches.add(vMap);
          }
        }

        // Branch-wide fallback if camp-partitioned inventory had no matching batch
        if (matchingBatches.isEmpty && hasCamps && activeCamp.isNotEmpty && activeCamp != 'all') {
          for (final key in stockBox.keys) {
            final val = stockBox.get(key);
            if (val is! Map) continue;
            final vMap = Map<String, dynamic>.from(val);
            final vKey = key.toString();
            vMap['_hiveKey'] = vKey;

            final b = (vMap['branchId'] ?? '').toString().toLowerCase().trim();
            final normB = branchId.toLowerCase().trim();
            if (b.isNotEmpty && normB.isNotEmpty && b != normB && !b.contains(normB) && !normB.contains(b)) {
              continue;
            }

            final vId = (vMap['id'] ?? vMap['medicineId'] ?? vMap['docId'] ?? '').toString().trim().toLowerCase();
            final vName = MasterProformaService.cleanBrandToFormula((vMap['name'] ?? vMap['formula'] ?? '').toString().toLowerCase().trim());
            final vFormula = MasterProformaService.cleanBrandToFormula((vMap['formula'] ?? vMap['name'] ?? '').toString().toLowerCase().trim());
            final vType = (vMap['type'] ?? vMap['dosageForm'] ?? vMap['form'] ?? '').toString().toLowerCase().trim();
            final vDose = (vMap['dose'] ?? vMap['dosage'] ?? '').toString().toLowerCase().trim();

            bool isMatch = false;
            if (targetId.isNotEmpty && (vId == targetId || vKey == 'stock:$targetId' || vKey == targetId)) {
              isMatch = true;
            } else if (targetName.isNotEmpty &&
                (vName == targetName || (vFormula.isNotEmpty && vFormula == targetFormula) ||
                 vName.contains(targetName) || targetName.contains(vName))) {
              final typeMatch = targetType.isEmpty || vType.isEmpty || vType == targetType ||
                  (targetType.contains('tab') && vType.contains('tab')) ||
                  (targetType.contains('cap') && vType.contains('cap')) ||
                  (targetType.contains('syp') && vType.contains('syp')) ||
                  (targetType.contains('inj') && vType.contains('inj'));
              final doseMatch = targetDose.isEmpty || vDose.isEmpty || vDose == targetDose;
              if (typeMatch && doseMatch) {
                isMatch = true;
              }
            }
            if (isMatch) {
              matchingBatches.add(vMap);
            }
          }
        }

        // Deduplicate batches by ID before sorting (handles stock:$id vs $id dual keys)
        final Map<String, Map<String, dynamic>> uniqueBatches = {};
        for (final b in matchingBatches) {
          final id = (b['id'] ?? b['medicineId'] ?? b['_hiveKey'] ?? '').toString().trim().toLowerCase();
          final canonId = id.startsWith('stock:') ? id.substring(6) : id;
          if (!uniqueBatches.containsKey(canonId)) {
            uniqueBatches[canonId] = b;
          }
        }
        final dedupedBatches = uniqueBatches.values.toList();

        // Sort matching batches by expiry date ascending (FEFO: earliest first)
        dedupedBatches.sort((a, b) {
          final expA = MasterProformaService.parseExpiryDate(a['expiryDate'] ?? a['expiry'], (a['id'] ?? a['medicineId'])?.toString());
          final expB = MasterProformaService.parseExpiryDate(b['expiryDate'] ?? b['expiry'], (b['id'] ?? b['medicineId'])?.toString());
          return expA.compareTo(expB);
        });

        double remainingToDeduct = qtyNum;
        final List<Map<String, dynamic>> medDeductions = [];

        // Deduct from earlier expiry batches first
        for (final batch in dedupedBatches) {
          if (remainingToDeduct <= 0) break;
          final q = batch['quantity'];
          final currentQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          if (currentQty <= 0) continue; // Batch is already 0, move to next batch

          final deductFromBatch = remainingToDeduct <= currentQty ? remainingToDeduct : currentQty;
          final newQty = currentQty - deductFromBatch;
          remainingToDeduct -= deductFromBatch;

          final updated = Map<String, dynamic>.from(batch);
          updated['quantity'] = newQty;
          final hiveKey = batch['_hiveKey']?.toString() ?? '';
          updated.remove('_hiveKey');
          if (hiveKey.isNotEmpty) {
            stockBox.put(hiveKey, updated);
            final rawId = (batch['id'] ?? batch['medicineId'] ?? batch['docId'] ?? '').toString().trim();
            if (rawId.isNotEmpty) {
              final peerKey = hiveKey.startsWith('stock:') ? rawId : 'stock:$rawId';
              if (stockBox.containsKey(peerKey)) {
                stockBox.put(peerKey, updated);
              }
            }
          }

          final bId = (batch['id'] ?? batch['medicineId'] ?? batch['docId'] ?? hiveKey).toString();
          final dedInfo = {
            'medicineId': bId,
            'name': batch['name'] ?? medMap['name'],
            'delta': -deductFromBatch,
            'expiryDate': batch['expiryDate'],
          };
          medDeductions.add(dedInfo);
          allDeductedBatches.add(dedInfo);

          debugPrint('[PatientForm] FEFO deducted $deductFromBatch from $bId (expiry: ${batch['expiryDate']}). Remaining in batch: $newQty');
        }

        // If stock was insufficient across all non-zero batches, deduct any remaining
        // from the first batch (or primary match) so it is accounted for
        if (remainingToDeduct > 0 && matchingBatches.isNotEmpty) {
          final primary = matchingBatches.first;
          final hiveKey = primary['_hiveKey'];
          final existingPrimary = stockBox.get(hiveKey);
          if (existingPrimary is Map) {
            final updated = Map<String, dynamic>.from(existingPrimary);
            final cur = (updated['quantity'] as num?)?.toDouble() ?? 0.0;
            updated['quantity'] = (cur - remainingToDeduct).clamp(0.0, double.infinity);
            final hKey = hiveKey?.toString() ?? '';
            updated.remove('_hiveKey');
            if (hKey.isNotEmpty) {
              stockBox.put(hKey, updated);
              final rawId = (primary['id'] ?? primary['medicineId'] ?? primary['docId'] ?? '').toString().trim();
              if (rawId.isNotEmpty) {
                final peerKey = hKey.startsWith('stock:') ? rawId : 'stock:$rawId';
                if (stockBox.containsKey(peerKey)) {
                  stockBox.put(peerKey, updated);
                }
              }
            }

            final bId = (primary['id'] ?? primary['medicineId'] ?? primary['docId'] ?? hiveKey).toString();
            final dedInfo = {
              'medicineId': bId,
              'name': primary['name'] ?? medMap['name'],
              'delta': -remainingToDeduct,
              'expiryDate': primary['expiryDate'],
            };
            medDeductions.add(dedInfo);
            allDeductedBatches.add(dedInfo);
          }
        } else if (matchingBatches.isEmpty && rawMedicineId.isNotEmpty) {
          // Fallback if no matching batch found by name/attributes
          final fallbackKey = stockBox.containsKey('stock:$rawMedicineId') ? 'stock:$rawMedicineId' : rawMedicineId;
          final existing = stockBox.get(fallbackKey);
          if (existing is Map) {
            final updated = Map<String, dynamic>.from(existing);
            final cur = (updated['quantity'] as num?)?.toDouble() ?? 0.0;
            updated['quantity'] = (cur - qtyNum).clamp(0.0, double.infinity);
            stockBox.put(fallbackKey, updated);
          }
          final dedInfo = {
            'medicineId': rawMedicineId,
            'name': medMap['name'],
            'delta': -qtyNum,
          };
          medDeductions.add(dedInfo);
          allDeductedBatches.add(dedInfo);
        }

        // Enqueue offline sync for each affected batch if LAN is not connected
        if (!RealtimeManager().isConnected) {
          for (final ded in medDeductions) {
            LocalStorageService.enqueueSync({
              'type': 'update_inventory',
              'branchId': branchId,
              'medicineId': ded['medicineId'],
              'inventoryId': ded['medicineId'],
              'delta': ded['delta'],
              'campId': patientCampId,
              'dispensaryId': patientCampId,
              'serial': patientSerial,
            });
          }
        }
      } catch (e) {
        debugPrint('[PatientForm] Hive stock decrement failed $rawMedicineId: $e');
      }
    }

    return allDeductedBatches;
  }

  List<Map<String, dynamic>> _getAvailableSyringeStockItems() {
    final stockBox = Hive.box(LocalStorageService.stockBox);
    final List<Map<String, dynamic>> list = [];
    final normBranch = widget.branchId.toLowerCase().trim();

    // Resolve target camp strictly for this patient / active session
    var activeCamp = widget.queueEntry['campId']?.toString() ??
        widget.queueEntry['dispensaryId']?.toString() ??
        _data['campId']?.toString() ??
        _data['dispensaryId']?.toString() ??
        CampSessionService.getActiveCamp(widget.branchId);

    if (activeCamp == null || activeCamp.isEmpty || activeCamp == 'all') {
      activeCamp = CampSessionService.getActiveCamp(widget.branchId) ?? '';
    }

    for (final key in stockBox.keys) {
      final val = stockBox.get(key);
      if (val is Map) {
        final m = Map<String, dynamic>.from(val);

        // Branch filter
        final b = (m['branchId'] ?? '').toString().toLowerCase().trim();
        if (b.isNotEmpty && normBranch.isNotEmpty && b != normBranch && !b.contains(normBranch) && !normBranch.contains(b)) {
          continue;
        }

        // Strict Camp isolation only if a specific camp is active
        if (CampSessionService.hasCampsForBranch(widget.branchId) && activeCamp.isNotEmpty && activeCamp != 'all') {
          final matches = CampSessionService.matchesCamp(
            selectedCamp: activeCamp,
            dispensaryId: m['dispensaryId']?.toString(),
            campId: m['campId']?.toString(),
            dispensaryTag: m['dispensaryTag']?.toString(),
            serial: (m['barcode'] ?? m['code'] ?? m['id'] ?? key)?.toString(),
          );
          if (!matches) continue;
        }

        final type = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();
        final name = (m['name'] ?? '').toString().toLowerCase();
        final isSyringe = type.contains('syringe') || type == 'syr' || type == 'syr.' || name.contains('syringe');
        if (isSyringe) {
          final q = m['quantity'] ?? m['stock'] ?? 0;
          final stockQty = q is num ? q.toDouble() : double.tryParse(q.toString()) ?? 0.0;
          if (stockQty > 0) {
            m['hiveKey'] = key.toString();
            list.add(m);
          }
        }
      }
    }
    final Map<String, Map<String, dynamic>> uniqueItems = {};
    for (final item in list) {
      final id = (item['id'] ?? item['medicineId'] ?? item['name'])?.toString().toLowerCase().trim() ?? '';
      if (!uniqueItems.containsKey(id)) {
        uniqueItems[id] = item;
      }
    }

    final result = uniqueItems.values.toList();
    result.sort((a, b) {
      final na = (a['name'] ?? '').toString();
      final nb = (b['name'] ?? '').toString();
      final matchA = RegExp(r'(\d+)\s*(cc|ml)', caseSensitive: false).firstMatch(na);
      final matchB = RegExp(r'(\d+)\s*(cc|ml)', caseSensitive: false).firstMatch(nb);
      if (matchA != null && matchB != null) {
        final numA = int.tryParse(matchA.group(1)!) ?? 0;
        final numB = int.tryParse(matchB.group(1)!) ?? 0;
        return numA.compareTo(numB);
      }
      return na.compareTo(nb);
    });
    return result;
  }

  static String _formatSyringeLabel(Map<String, dynamic> item) {
    final name = (item['name'] ?? '').toString();
    final dose = (item['dose'] ?? '').toString();
    final ccMatch = RegExp(r'(\d+)\s*(cc|ml)', caseSensitive: false).firstMatch('$name $dose');
    if (ccMatch != null) {
      return '${ccMatch.group(1)} cc';
    }
    final clean = name.replaceAll(RegExp(r'Disposable|Syringe', caseSensitive: false), '').trim();
    return clean.isNotEmpty ? clean : name;
  }

  Future<void> _deductSyringeIfNeeded(
      String branchId, String serial, List<dynamic> allPrescriptions) async {
    final totalSyringesToDeduct = _getEffectiveSyringeCount(allPrescriptions).toDouble();
    final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString();
    final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();
    final invCol = CampSessionService.getCampInventoryPath(
      branchId: branchId,
      campId: patientCampId,
      serial: patientSerial,
    );

    if (totalSyringesToDeduct > 0.0) {
      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        String? syringeKey = _selectedSyringeHiveKey;
        Map<String, dynamic>? syringeMap;

        if (syringeKey != null) {
          final val = stockBox.get(syringeKey);
          if (val is Map) {
            syringeMap = Map<String, dynamic>.from(val);
          }
        }

        // Fallback if not specifically selected or not found
        if (syringeMap == null) {
          final available = _getAvailableSyringeStockItems();
          if (available.isNotEmpty) {
            syringeKey = available.first['hiveKey'];
            syringeMap = available.first;
          } else {
            for (final key in stockBox.keys) {
              final val = stockBox.get(key);
              if (val is Map) {
                final type = (val['type'] ?? '').toString().toLowerCase();
                final name = (val['name'] ?? '').toString().toLowerCase();
                if (type.contains('syringe') || name.contains('syringe')) {
                  syringeKey = key.toString();
                  syringeMap = Map<String, dynamic>.from(val);
                  break;
                }
              }
            }
          }
        }

        if (syringeKey != null && syringeMap != null) {
          final q = syringeMap['quantity'] ?? syringeMap['stock'] ?? 0;
          final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          syringeMap['quantity'] = (current - totalSyringesToDeduct).clamp(0.0, double.infinity);
          syringeMap['stock'] = syringeMap['quantity'];
          await stockBox.put(syringeKey, syringeMap);
          debugPrint('[PatientForm] Auto-deducted $totalSyringesToDeduct Syringe ($syringeKey) from Hive: $current → ${syringeMap['quantity']}');

          final rawSyringeId = (syringeMap['id'] ?? syringeMap['medicineId'] ?? syringeKey.replaceFirst('stock:', '')).toString();
          Future<void> updateSyringeFirestore() async {
            // If connected to LAN, the server handles atomic inventory deduction.
            // If not connected to LAN, enqueue to sync queue for zero-read FieldValue.increment.
            if (!RealtimeManager().isConnected) {
              await LocalStorageService.enqueueSync({
                'type': 'update_inventory',
                'branchId': branchId,
                'inventoryId': rawSyringeId,
                'delta': -totalSyringesToDeduct,
                'campId': patientCampId,
                'serial': patientSerial,
              });
            }
          }
          updateSyringeFirestore();
        } else {
          debugPrint('[PatientForm] ⚠️ Auto syringe deduction skipped: No syringe item found in stock_items');
        }
      } catch (e) {
        debugPrint('[PatientForm] Error during auto syringe deduction: $e');
      }
    }
  }

  int _getAutoNeedleCount(List<dynamic> allPrescriptions) {
    int totalInj = 0;
    for (final med in allPrescriptions) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final type = (medMap['type']?.toString() ?? '').toLowerCase();
      final name = (medMap['name']?.toString() ?? '').toLowerCase();
      final isInjOrIV = type.contains('injection') || type.contains('inj') ||
                        type.contains('iv') || type.contains('i.v') ||
                        name.contains('inj') || name.contains('iv') || name.contains('i.v.');
      final isNeedleOrSyringe = type.contains('needle') || name.contains('needle') ||
                                type.contains('syringe') || name.contains('syringe');
      if (isInjOrIV && !isNeedleOrSyringe) {
        final qtyRaw = medMap['quantity'] ?? medMap['qty'] ?? 1;
        final qty = (qtyRaw is num) ? qtyRaw.toInt() : (int.tryParse(qtyRaw.toString()) ?? 1);
        totalInj += qty > 0 ? qty : 1;
      }
    }
    return totalInj;
  }

  int _getEffectiveNeedleCount(List<dynamic> allPrescriptions) {
    final autoCount = _getAutoNeedleCount(allPrescriptions).clamp(0, 3);
    if (autoCount == 0) return 0;
    if (_selectedNeedleCount != null) {
      return _selectedNeedleCount!.clamp(0, 3);
    }
    return autoCount;
  }

  Future<void> _deductNeedleIfNeeded(
      String branchId, String serial, List<dynamic> allPrescriptions) async {
    final totalNeedlesToDeduct = _getEffectiveNeedleCount(allPrescriptions).toDouble();
    final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString();
    final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();
    final invCol = CampSessionService.getCampInventoryPath(
      branchId: branchId,
      campId: patientCampId,
      serial: patientSerial,
    );

    if (totalNeedlesToDeduct > 0.0) {
      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        String? needleKey;
        Map<String, dynamic>? needleMap;
        
        for (final key in stockBox.keys) {
          final val = stockBox.get(key);
          if (val is Map) {
            final type = (val['type'] ?? '').toString().toLowerCase();
            final name = (val['name'] ?? '').toString().toLowerCase();
            if (type.contains('needle') || name.contains('needle')) {
              needleKey = key.toString();
              needleMap = Map<String, dynamic>.from(val);
              break;
            }
          }
        }
        
        if (needleKey != null && needleMap != null) {
          final q = needleMap['quantity'];
          final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          needleMap['quantity'] = (current - totalNeedlesToDeduct).clamp(0.0, double.infinity);
          await stockBox.put(needleKey, needleMap);
          debugPrint('[PatientForm] Auto-deducted $totalNeedlesToDeduct Needle ($needleKey) from Hive: $current → ${needleMap['quantity']}');
          
          final rawNeedleId = needleKey.replaceFirst('stock:', '');
          Future<void> updateNeedleFirestore() async {
            // If connected to LAN, the server handles atomic inventory deduction.
            // If not connected to LAN, enqueue to sync queue for zero-read FieldValue.increment.
            if (!RealtimeManager().isConnected) {
              await LocalStorageService.enqueueSync({
                'type': 'update_inventory',
                'branchId': branchId,
                'inventoryId': rawNeedleId,
                'delta': -totalNeedlesToDeduct,
                'campId': patientCampId,
                'serial': patientSerial,
              });
            }
          }
          updateNeedleFirestore();
        } else {
          debugPrint('[PatientForm] ⚠️ Auto needle deduction skipped: No needle item found in stock_items');
        }
      } catch (e) {
        debugPrint('[PatientForm] Error during auto needle deduction: $e');
      }
    }
  }

  // ─── Dispense ─────────────────────────────────────────────────────────────
  Future<void> _dispenseOnly() async {
    if (_isDispensed) return;
    final days = _daysOfMedicine;

    final allPrescriptions = _getPrescriptionsList();
    final medicines = allPrescriptions
        .where((m) => m is Map &&
            (m['inventoryId'] != null || m['medicineId'] != null || m['id'] != null))
        .toList();

    // Check stock levels across all matching batches
    final stockBox = Hive.box(LocalStorageService.stockBox);
    final List<String> insufficientMeds = [];
    final hasCamps = CampSessionService.hasCampsForBranch(widget.branchId);
    final normBranch = widget.branchId.toLowerCase().trim();
    final patientCamp = widget.queueEntry['campId']?.toString() ??
        widget.queueEntry['dispensaryId']?.toString() ??
        _data['campId']?.toString() ??
        _data['dispensaryId']?.toString() ??
        CampSessionService.getActiveCamp(widget.branchId) ?? '';

    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final rawMedicineId = (medMap['inventoryId'] ??
              medMap['medicineId'] ?? medMap['id'] ?? '').toString().trim();
      final perDayRaw = medMap['quantity'] ?? medMap['qty'] ?? 0;
      final perDay = perDayRaw is num
          ? perDayRaw.toDouble()
          : double.tryParse(perDayRaw.toString()) ?? 0.0;
      if (rawMedicineId.isEmpty || perDay <= 0) continue;
      
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final multiplier = isSyrup
          ? 1.0
          : (_isInjectableType(medMap['type']?.toString()) ? 1.0 : days.toDouble());
      final qtyNum = isSyrup ? 1.0 : perDay * multiplier;

      var targetName = MasterProformaService.cleanBrandToFormula((medMap['name'] ?? medMap['formula'] ?? '').toString().toLowerCase().trim());
      var targetFormula = MasterProformaService.cleanBrandToFormula((medMap['formula'] ?? medMap['name'] ?? '').toString().toLowerCase().trim());
      var targetType = (medMap['type'] ?? medMap['dosageForm'] ?? '').toString().toLowerCase().trim();
      var targetDose = (medMap['dose'] ?? medMap['dosage'] ?? '').toString().toLowerCase().trim();
      final targetId = rawMedicineId.toLowerCase();

      // Seed canonical attributes from raw medicine ID if available in stockBox
      if (rawMedicineId.isNotEmpty) {
        final refItem = stockBox.get('stock:$rawMedicineId') ?? stockBox.get(rawMedicineId);
        if (refItem is Map) {
          if (targetName.isEmpty) {
            targetName = MasterProformaService.cleanBrandToFormula((refItem['name'] ?? refItem['formula'] ?? '').toString().toLowerCase().trim());
          }
          if (targetFormula.isEmpty) {
            targetFormula = MasterProformaService.cleanBrandToFormula((refItem['formula'] ?? refItem['name'] ?? '').toString().toLowerCase().trim());
          }
          if (targetType.isEmpty) {
            targetType = (refItem['type'] ?? refItem['dosageForm'] ?? refItem['form'] ?? '').toString().toLowerCase().trim();
          }
          if (targetDose.isEmpty) {
            targetDose = (refItem['dose'] ?? refItem['dosage'] ?? '').toString().toLowerCase().trim();
          }
        }
      }

      double totalAvailableStock = 0.0;
      final seenStockCheckIds = <String>{};

      for (final key in stockBox.keys) {
        final val = stockBox.get(key);
        if (val is! Map) continue;
        final vMap = Map<String, dynamic>.from(val);
        final vKey = key.toString();

        final rawId = (vMap['id'] ?? vMap['docId'] ?? (vKey.startsWith('stock:') ? vKey.substring(6) : vKey)).toString().trim();
        if (rawId.isNotEmpty) {
          if (seenStockCheckIds.contains(rawId)) continue;
          seenStockCheckIds.add(rawId);
        }

        // Branch filter
        final b = (vMap['branchId'] ?? '').toString().toLowerCase().trim();
        if (b.isNotEmpty && normBranch.isNotEmpty && b != normBranch && !b.contains(normBranch) && !normBranch.contains(b)) {
          continue;
        }

        if (hasCamps && patientCamp.isNotEmpty && patientCamp != 'all') {
          final campMatch = CampSessionService.matchesCamp(
            selectedCamp: patientCamp,
            dispensaryId: vMap['dispensaryId']?.toString(),
            campId: vMap['campId']?.toString(),
            serial: (vMap['barcode'] ?? vMap['code'] ?? vMap['id'])?.toString(),
          );
          if (!campMatch) continue;
        }

        final vId = (vMap['id'] ?? vMap['medicineId'] ?? vMap['docId'] ?? '').toString().trim().toLowerCase();
        final vName = MasterProformaService.cleanBrandToFormula((vMap['name'] ?? vMap['formula'] ?? '').toString().toLowerCase().trim());
        final vFormula = MasterProformaService.cleanBrandToFormula((vMap['formula'] ?? vMap['name'] ?? '').toString().toLowerCase().trim());
        final vType = (vMap['type'] ?? vMap['dosageForm'] ?? vMap['form'] ?? '').toString().toLowerCase().trim();
        final vDose = (vMap['dose'] ?? vMap['dosage'] ?? '').toString().toLowerCase().trim();

        bool isMatch = false;
        if (targetId.isNotEmpty && (vId == targetId || vKey == 'stock:$targetId' || vKey == targetId)) {
          isMatch = true;
        } else if (targetName.isNotEmpty &&
            (vName == targetName || (vFormula.isNotEmpty && vFormula == targetFormula) ||
             vName.contains(targetName) || targetName.contains(vName))) {
          final typeMatch = targetType.isEmpty || vType.isEmpty || vType == targetType ||
              (targetType.contains('tab') && vType.contains('tab')) ||
              (targetType.contains('cap') && vType.contains('cap')) ||
              (targetType.contains('syp') && vType.contains('syp')) ||
              (targetType.contains('inj') && vType.contains('inj'));
          final doseMatch = targetDose.isEmpty || vDose.isEmpty || vDose == targetDose;
          if (typeMatch && doseMatch) {
            isMatch = true;
          }
        }

        if (isMatch) {
          final q = vMap['quantity'] ?? vMap['stock'];
          final currentQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          if (currentQty > 0) {
            totalAvailableStock += currentQty;
          }
        }
      }

      // Branch-wide fallback if camp-partitioned inventory check was insufficient
      if (totalAvailableStock < qtyNum && hasCamps && patientCamp.isNotEmpty && patientCamp != 'all') {
        double branchAvailableStock = 0.0;
        for (final key in stockBox.keys) {
          final val = stockBox.get(key);
          if (val is! Map) continue;
          final vMap = Map<String, dynamic>.from(val);
          final vKey = key.toString();

          final b = (vMap['branchId'] ?? '').toString().toLowerCase().trim();
          if (b.isNotEmpty && normBranch.isNotEmpty && b != normBranch && !b.contains(normBranch) && !normBranch.contains(b)) {
            continue;
          }

          final vId = (vMap['id'] ?? vMap['medicineId'] ?? vMap['docId'] ?? '').toString().trim().toLowerCase();
          final vName = MasterProformaService.cleanBrandToFormula((vMap['name'] ?? vMap['formula'] ?? '').toString().toLowerCase().trim());
          final vFormula = MasterProformaService.cleanBrandToFormula((vMap['formula'] ?? vMap['name'] ?? '').toString().toLowerCase().trim());
          final vType = (vMap['type'] ?? vMap['dosageForm'] ?? vMap['form'] ?? '').toString().toLowerCase().trim();
          final vDose = (vMap['dose'] ?? vMap['dosage'] ?? '').toString().toLowerCase().trim();

          bool isMatch = false;
          if (targetId.isNotEmpty && (vId == targetId || vKey == 'stock:$targetId' || vKey == targetId)) {
            isMatch = true;
          } else if (targetName.isNotEmpty &&
              (vName == targetName || (vFormula.isNotEmpty && vFormula == targetFormula) ||
               vName.contains(targetName) || targetName.contains(vName))) {
            final typeMatch = targetType.isEmpty || vType.isEmpty || vType == targetType ||
                (targetType.contains('tab') && vType.contains('tab')) ||
                (targetType.contains('cap') && vType.contains('cap')) ||
                (targetType.contains('syp') && vType.contains('syp')) ||
                (targetType.contains('inj') && vType.contains('inj'));
            final doseMatch = targetDose.isEmpty || vDose.isEmpty || vDose == targetDose;
            if (typeMatch && doseMatch) {
              isMatch = true;
            }
          }

          if (isMatch) {
            final q = vMap['quantity'] ?? vMap['stock'];
            final currentQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
            if (currentQty > 0) {
              branchAvailableStock += currentQty;
            }
          }
        }
        if (branchAvailableStock > totalAvailableStock) {
          totalAvailableStock = branchAvailableStock;
        }
      }

      // Direct ID fallback (e.g. stock:medId or medId)
      if (totalAvailableStock < qtyNum && rawMedicineId.isNotEmpty) {
        final directItem = stockBox.get('stock:$rawMedicineId') ?? stockBox.get(rawMedicineId);
        if (directItem is Map) {
          final q = directItem['quantity'] ?? directItem['stock'];
          final directQty = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          if (directQty > totalAvailableStock) {
            totalAvailableStock = directQty;
          }
        }
      }

      if (totalAvailableStock < qtyNum) {
        final medName = (medMap['name'] ?? (targetName.isNotEmpty ? targetName : 'Unknown Medicine')).toString();
        insufficientMeds.add('$medName (Required: ${qtyNum.toInt()}, Available: ${totalAvailableStock.toInt()})');
      }
    }

    // Check syringes if needed
    final totalSyringesToDeduct = _getEffectiveSyringeCount(allPrescriptions).toDouble();

    if (totalSyringesToDeduct > 0.0) {
      final availableSyringes = _getAvailableSyringeStockItems();
      double totalAvailableSyringes = 0.0;
      for (final s in availableSyringes) {
        final q = s['quantity'] ?? s['stock'] ?? 0;
        final sQty = q is num ? q.toDouble() : double.tryParse(q.toString()) ?? 0.0;
        if (sQty > 0) totalAvailableSyringes += sQty;
      }

      if (totalAvailableSyringes < totalSyringesToDeduct) {
        insufficientMeds.add('Syringe (Required: ${totalSyringesToDeduct.toInt()}, Available: ${totalAvailableSyringes.toInt()})');
      } else {
        if (_selectedSyringeHiveKey == null && availableSyringes.isNotEmpty) {
          _selectedSyringeHiveKey = availableSyringes.first['hiveKey'];
        }
      }
    }

    if (insufficientMeds.isNotEmpty) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
              SizedBox(width: 8),
              Text('Insufficient Stock'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('The following items do not have enough stock in local inventory:'),
                const SizedBox(height: 12),
                ...insufficientMeds.map((med) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('• $med', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                )),
                const SizedBox(height: 16),
                const Text(
                  'Choose how to handle this patient:\n'
                  '• Put On Hold: Moves patient to On-Hold section so queue can continue.\n'
                  '• Dispense Available: Dispenses remaining stock and proceeds.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'hold'),
              icon: const Icon(Icons.pause_circle_outline, color: Colors.white, size: 18),
              label: const Text('Put On Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'dispense_available'),
              icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
              label: const Text('Dispense Available'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C)),
            ),
          ],
        ),
      );

      if (action == 'hold') {
        final serial = _resolvedSerial;
        if (serial.isNotEmpty) {
          await LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'on_hold');
          if (mounted) {
            Flushbar(
              message: 'Patient #$serial moved to On-Hold list',
              backgroundColor: Colors.orange.shade800,
              duration: const Duration(seconds: 3),
            ).show(context);
          }
        }
        widget.onDispensed?.call();
        return;
      } else if (action != 'dispense_available') {
        return;
      }
    }

    // Fallback/standard RoleTheme read to display dialogue matching exact color palette
    var t = RoleThemeScope.dataOf(context);
    if (RoleThemeScope.of(context) == RoleTheme.admin) {
      t = RoleThemeData.of(RoleTheme.dispenser);
    }
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Dispense'),
        content: Text(days > 1
            ? 'Give $days days\' supply of each medicine (tablets/capsules/syrups ×$days). '
              'Injections and drips are given once only.\n\nThis cannot be undone.'
            : 'Mark this prescription as dispensed? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Dispense'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _isDispensing = true);
    try {
      final rawSerial = _resolvedSerial;
      if (rawSerial.isEmpty) throw Exception(
          'Missing serial — queueEntry keys: ${widget.queueEntry.keys.toList()}');
      final normBranch = widget.branchId.trim().toLowerCase();
      var cleanSerial = rawSerial.trim();
      if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
        cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
      }
      final normSerial = cleanSerial.toUpperCase();
      final canonicalKey = '$normBranch-$normSerial';
      final serial = normSerial;

      final queueType = _resolvedQueueType;
      final now = DateTime.now();
      final dateKey = DateFormat('ddMMyy').format(now);
      final nowIso = now.toIso8601String();
      final dispenserName = widget.dispenserName ?? 'Unknown Dispenser';

      // 1. Update local entries box immediately (preserve existing patient & prescription data)
      final entriesBox = Hive.box(LocalStorageService.entriesBox);

      Map<String, dynamic>? existingEntry;
      final direct = entriesBox.get(canonicalKey) ?? entriesBox.get('${widget.branchId}-$serial') ?? entriesBox.get(serial) ?? entriesBox.get(rawSerial);
      if (direct is Map) {
        existingEntry = Map<String, dynamic>.from(direct);
      } else {
        for (final k in entriesBox.keys) {
          final kStr = k.toString().trim();
          if (kStr.toUpperCase() == normSerial || kStr.toUpperCase().endsWith('-$normSerial')) {
            final val = entriesBox.get(k);
            if (val is Map) {
              existingEntry = Map<String, dynamic>.from(val);
              break;
            }
          }
        }
      }

      final doctorName = _firstNonEmpty([
        existingEntry?['doctorName'], existingEntry?['prescribedBy'],
        _data['doctorName'], _data['prescribedBy'], _data['updatedBy'],
        widget.queueEntry['doctorName'], widget.queueEntry['prescribedBy'],
        '',
      ]);
      final doctorId = _firstNonEmpty([
        existingEntry?['doctorId'], existingEntry?['prescribedById'],
        _data['doctorId'], _data['prescribedById'],
        widget.queueEntry['doctorId'], widget.queueEntry['prescribedById'],
        '',
      ]);
      final tokenBy = _firstNonEmpty([
        existingEntry?['createdByName'], existingEntry?['receptionistName'],
        existingEntry?['tokenBy'], existingEntry?['createdBy'],
        widget.queueEntry['createdByName'], widget.queueEntry['receptionistName'],
        widget.queueEntry['tokenBy'], widget.queueEntry['createdBy'],
        _data['createdByName'], _data['tokenBy'],
        '',
      ]);
      final createdBy = _firstNonEmpty([
        existingEntry?['createdBy'], existingEntry?['receptionistId'],
        existingEntry?['userId'], widget.queueEntry['createdBy'],
        widget.queueEntry['receptionistId'], widget.queueEntry['userId'],
        '',
      ]);

      final minimalUpdate = {
        'dispenseStatus': 'dispensed',
        'status': 'completed',
        'dispensedAt': nowIso,
        'dispensedBy': dispenserName,
        'dispenserName': dispenserName,
        'serial': normSerial,
        'dateKey': dateKey,
        'queueType': queueType,
        'branchId': widget.branchId,
        'daysOfMedicine': days,
      };

      final fullEntry = <String, dynamic>{
        if (existingEntry != null) ...existingEntry,
        ...Map<String, dynamic>.from(widget.queueEntry),
        ...Map<String, dynamic>.from(_data),
        ...minimalUpdate,
        if (doctorName.isNotEmpty && doctorName != 'Unknown') 'doctorName': doctorName,
        if (doctorName.isNotEmpty && doctorName != 'Unknown') 'prescribedBy': doctorName,
        if (doctorId.isNotEmpty) 'doctorId': doctorId,
        if (tokenBy.isNotEmpty && tokenBy != 'Unknown') 'tokenBy': tokenBy,
        if (tokenBy.isNotEmpty && tokenBy != 'Unknown') 'createdByName': tokenBy,
        if (createdBy.isNotEmpty) 'createdBy': createdBy,
      };

      await entriesBox.put(canonicalKey, fullEntry);
      // Clean up legacy non-canonical keys so duplicate records are not kept
      if (entriesBox.containsKey(rawSerial) && rawSerial != canonicalKey) {
        await entriesBox.delete(rawSerial);
      }
      if (entriesBox.containsKey(normSerial) && normSerial != canonicalKey) {
        await entriesBox.delete(normSerial);
      }
      if (canonicalKey != '${widget.branchId}-$rawSerial' && entriesBox.containsKey('${widget.branchId}-$rawSerial')) {
        await entriesBox.delete('${widget.branchId}-$rawSerial');
      }

      await LocalStorageService.updateDispenseStatus(widget.branchId, normSerial, 'dispensed');

      // 2. Save dispensary record locally
      final dispensaryRecord = {
        ...Map<String, dynamic>.from(widget.queueEntry),
        ...Map<String, dynamic>.from(_data),
        'branchId': widget.branchId,
        'serial': normSerial,
        'dateKey': dateKey,
        'date': dateKey,
        'queueType': queueType,
        'tokenCreatedAt': widget.queueEntry['createdAt'] ?? _data['createdAt'] ?? _data['tokenCreatedAt'],
        'createdAt': nowIso,
        'dispenseStatus': 'dispensed',
        'status': 'completed',
        'dispensedAt': nowIso,
        'dispensedBy': dispenserName,
        'dispenserName': dispenserName,
        'doctorName': doctorName.isNotEmpty ? doctorName : 'Unknown',
        'prescribedBy': doctorName.isNotEmpty ? doctorName : 'Unknown',
        'tokenBy': tokenBy.isNotEmpty ? tokenBy : 'Unknown',
        'createdByName': tokenBy.isNotEmpty ? tokenBy : 'Unknown',
        'daysOfMedicine': days,
      };
      await LocalStorageService.saveLocalDispensaryRecord(dispensaryRecord);

      final allPrescriptions = (_data['prescriptions'] as List?) ??
          (_data['medicines'] as List?) ??
          _getPrescriptionsList();
      final medicines = allPrescriptions
          .where((m) => m is Map &&
              (m['inventoryId'] != null || m['medicineId'] != null || m['id'] != null))
          .toList();

      // 3. Mark UI state complete immediately (Instant feedback)
      if (mounted) {
        setState(() {
          _isDispensed = true;
          _isDispensing = false;
        });
        try {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(days > 1
                  ? 'Dispensed $days-day supply successfully'
                  : 'Dispensed successfully'),
              backgroundColor: Colors.green));
        } catch (_) {}
      }
      widget.onDispensed?.call();

      // 4. Run inventory deduction, LAN broadcast & Firestore sync asynchronously in background
      unawaited(() async {
        try {
          List<Map<String, dynamic>> deductedBatches = [];
          if (medicines.isNotEmpty) {
            deductedBatches = await _deductInventoryLocally(widget.branchId, normSerial, medicines, days);
          }
          await _deductSyringeIfNeeded(widget.branchId, normSerial, allPrescriptions);
          await _deductNeedleIfNeeded(widget.branchId, normSerial, allPrescriptions);

          try {
            RealtimeManager().sendMessage(RealtimeEvents.payload(
              type: 'dispense_completed',
              data: {
                'branchId': widget.branchId,
                'serial': normSerial,
                'dateKey': dateKey,
                ...minimalUpdate,
                if (doctorName.isNotEmpty && doctorName != 'Unknown') 'doctorName': doctorName,
                if (doctorId.isNotEmpty) 'doctorId': doctorId,
                if (tokenBy.isNotEmpty && tokenBy != 'Unknown') 'createdByName': tokenBy,
                if (tokenBy.isNotEmpty && tokenBy != 'Unknown') 'tokenBy': tokenBy,
                if (createdBy.isNotEmpty) 'createdBy': createdBy,
                if (fullEntry['patientName'] != null) 'patientName': fullEntry['patientName'],
                if (fullEntry['name'] != null) 'name': fullEntry['name'],
                if (fullEntry['patientCnic'] != null) 'patientCnic': fullEntry['patientCnic'],
                if (fullEntry['cnic'] != null) 'cnic': fullEntry['cnic'],
                if (fullEntry['guardianCnic'] != null) 'guardianCnic': fullEntry['guardianCnic'],
                if (fullEntry['guardianName'] != null) 'guardianName': fullEntry['guardianName'],
                if (fullEntry['campId'] != null) 'campId': fullEntry['campId'],
                if (fullEntry['dispensaryId'] != null) 'dispensaryId': fullEntry['dispensaryId'],
                if (fullEntry['dispensaryTag'] != null) 'dispensaryTag': fullEntry['dispensaryTag'],
                if (fullEntry['session'] != null) 'session': fullEntry['session'],
                if (medicines.isNotEmpty) 'medicines': medicines,
                if (deductedBatches.isNotEmpty) 'deductedBatches': deductedBatches,
              },
            ));
          } catch (_) {}

          final upperSerial = serial.trim().toUpperCase();
          final campDocKey = CampSessionService.getCampDateDocId(
            branchId: widget.branchId,
            dateKey: dateKey,
            campId: widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? _data['campId']?.toString() ?? _data['dispensaryId']?.toString(),
            dispensaryTag: widget.queueEntry['dispensaryTag']?.toString() ?? _data['dispensaryTag']?.toString(),
            serial: upperSerial,
          );

          // Single-Writer Gateway: Only write directly to Firestore if NOT connected to LAN server.
          // When connected, the LAN server handles cloud sync from the dispense_completed event.
          if (!RealtimeManager().isConnected) {
            try {
              final branchRef = FirebaseFirestore.instance
                  .collection('branches').doc(widget.branchId);
              await branchRef.collection('serials').doc(campDocKey)
                  .collection(queueType).doc(upperSerial)
                  .set(minimalUpdate, SetOptions(merge: true));
            } catch (e) {
              await LocalStorageService.enqueueSync({
                'type': 'update_serial_status',
                'branchId': widget.branchId,
                'dateKey': dateKey,
                'queueType': queueType,
                'serial': upperSerial,
                'data': minimalUpdate,
              });
            }
            SyncService().triggerUpload();
          }
        } catch (e) {
          debugPrint('[PatientForm] Background async dispense sync error: $e');
        }
      }());
    } catch (e) {
      debugPrint('[PatientForm] Dispense error: $e');
      if (mounted) {
        setState(() => _isDispensing = false);
        try {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('Failed to dispense: $e'), backgroundColor: Colors.red));
        } catch (_) {}
      }
    }
  }

  // ─── UI builders ──────────────────────────────────────────────────────────

  Widget _sectionTitle(String title, IconData icon, RoleThemeData t, {bool isMobile = false}) {
    final isDark = _isDark;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: isMobile ? 8 : 12),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF134E4A) : t.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: isDark ? const Color(0xFF2DD4BF) : t.accent, size: isMobile ? 15 : 18),
        ),
        const SizedBox(width: 10),
        Text(
          title, 
          style: TextStyle(
            color: isDark ? const Color(0xFFF1F5F9) : t.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: isMobile ? 15 : 17,
            letterSpacing: 0.2,
          ),
        ),
      ]),
    );
  }

  Widget _buildMedTypeIconBadge(String? type, String? name, bool isDark) {
    final t = (type ?? '').toLowerCase().trim();
    final n = (name ?? '').toLowerCase().trim();

    IconData icon;
    Color color;
    if (t.contains('cap') || n.startsWith('cap')) {
      icon = FontAwesomeIcons.capsules;
      color = const Color(0xFFF59E0B); // Amber / Orange
    } else if (t.contains('inj') || t.contains('drip') || t.contains('infusion') || n.startsWith('inj')) {
      icon = FontAwesomeIcons.syringe;
      color = const Color(0xFFEF4444); // Crimson / Red
    } else if (t.contains('syp') || t.contains('syrup') || t.contains('susp') || n.startsWith('syp')) {
      icon = FontAwesomeIcons.bottleDroplet;
      color = const Color(0xFF10B981); // Emerald Green
    } else if (t.contains('drop') || n.startsWith('drop')) {
      icon = FontAwesomeIcons.eyeDropper;
      color = const Color(0xFF06B6D4); // Cyan
    } else if (t.contains('cream') || t.contains('oint') || t.contains('gel')) {
      icon = Icons.sanitizer_rounded;
      color = const Color(0xFFEC4899); // Pink
    } else if (t.contains('inhal') || t.contains('resp') || n.contains('inhal')) {
      icon = FontAwesomeIcons.lungs;
      color = const Color(0xFF8B5CF6); // Purple
    } else if (t.contains('tab') || n.startsWith('tab')) {
      icon = FontAwesomeIcons.tablets;
      color = const Color(0xFF3B82F6); // Blue
    } else {
      icon = Icons.medication_rounded;
      color = const Color(0xFF0D9488); // Teal
    }

    return Container(
      padding: const EdgeInsets.all(5.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.45 : 0.28), width: 1),
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }

  Widget _linedList(List items, RoleThemeData t, {bool isLab = false, bool isMobile = false}) {
    if (items.isEmpty) return const SizedBox.shrink();
    if (isLab) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items.map((item) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(item['name']?.toString() ?? '',
              style: PatientFormHelper.robotoBold(size: isMobile ? 13 : 16)),
        )).toList(),
      );
    }
    final days = _daysOfMedicine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items.map((item) {
        final abbrev = _getMedAbbrev(item['type']);
        final rawName = item['name']?.toString() ?? '';
        String dose = (item['dose'] ?? item['dosage'] ?? '').toString().trim();
        if (dose.isEmpty || dose.contains('+')) {
          final invId = (item['inventoryId'] ?? item['id'] ?? item['medicineId'])?.toString();
          if (invId != null && invId.isNotEmpty) {
            try {
              if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
                final stockBox = Hive.box(LocalStorageService.stockBox);
                final stockItem = stockBox.get('stock:$invId') ?? stockBox.get(invId);
                if (stockItem is Map) {
                  final stockDose = (stockItem['dose'] ?? stockItem['strength'] ?? '').toString().trim();
                  if (stockDose.isNotEmpty) dose = stockDose;
                }
              }
            } catch (_) {}
          }
        }
        if (dose.contains('+')) dose = '';
        final displayName = '$abbrev $rawName'.trim();
        final urduLine = PatientFormHelper.buildUrduDosageLine(item);
        final mealUrdu = PatientFormHelper.getMealUrdu(item['meal']?.toString() ?? '');
        final isInj = _isInjectableType(item['type']?.toString());
        final isSyrup = _isSyrupType(item['type']?.toString(), item['name']?.toString());
        final perDayQty = ((item['quantity'] ?? 1) as num).toInt();
        final totalQty = isSyrup ? 1 : (isInj ? perDayQty : perDayQty * days);
        
        final isDark = _isDark;
        final fullUrdu = [
          if (urduLine.isNotEmpty) urduLine,
          if (mealUrdu.isNotEmpty) mealUrdu,
        ].join('، ');

        final qtyLabel = isSyrup
            ? '1 Bottle'
            : (isInj ? 'Single Dose · qty $perDayQty' : '$perDayQty/day · qty $totalQty');

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 12 : 16,
            vertical: isMobile ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        _buildMedTypeIconBadge(item['type']?.toString(), item['name']?.toString(), isDark),
                        const SizedBox(width: 8),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: TextStyle(
                                fontFamily: 'Roboto',
                                color: isDark ? Colors.white : t.textPrimary,
                              ),
                              children: [
                                TextSpan(
                                  text: '$displayName ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: isMobile ? 13.5 : 15,
                                  ),
                                ),
                                if (dose.isNotEmpty)
                                  TextSpan(
                                    text: dose,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      fontSize: isMobile ? 12 : 13.5,
                                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    qtyLabel,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              if (fullUrdu.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF14532D).withValues(alpha: 0.35) : const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF166534) : const Color(0xFFBBF7D0)),
                  ),
                  child: Text(
                    fullUrdu,
                    textAlign: TextAlign.right,
                    textDirection: ui.TextDirection.rtl,
                    style: TextStyle(
                      fontFamily: 'Jameel Noori Nastaleeq',
                      fontSize: isMobile ? 15 : 17,
                      fontWeight: FontWeight.w700,
                      color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF166534),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  // ─── Lab Tests & Duration Section (Side-by-Side Capsules) ───────────────────
  Widget _buildLabAndDurationSection(
    List labTests,
    RoleThemeData t, {
    required bool isMobile,
  }) {
    final isDark = _isDark;
    final prescribed = _daysOfMedicine;
    final suggested = _suggestedDays;
    final queueType = _resolvedQueueType;

    final prices = _isKarachi
        ? const {'zakat': 20, 'non-zakat': 20, 'gmwf': 0}
        : const {'zakat': 20, 'non-zakat': 100, 'gmwf': 0};
    final rate = prices[queueType] ?? 0;

    final refundDays = suggested - prescribed;
    final extraDays = prescribed - suggested;
    final refundAmt = refundDays > 0 ? refundDays * rate : 0;
    final extraAmt = extraDays > 0 ? extraDays * rate : 0;

    final isPhysio = _data['isPhysiotherapist'] == true ||
        _data['isPhysiotherapy'] == true ||
        _data['department']?.toString().toLowerCase().contains('physio') == true ||
        _data['dpt']?.toString().toLowerCase().contains('physio') == true ||
        labTests.any((item) {
          final name = (item['name'] ?? '').toString().toLowerCase();
          return name.contains('therapy') ||
              name.contains('tens') ||
              name.contains('traction') ||
              name.contains('swd') ||
              name.contains('exercise') ||
              name.contains('diathermy') ||
              name.contains('pack') ||
              name.contains('massage') ||
              name.contains('ultrasound');
        });

    final durationWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Medicine duration',
          style: TextStyle(
            fontSize: isMobile ? 13 : 15,
            fontWeight: FontWeight.w700,
            color: t.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 10 : 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Prescribed / paid',
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13.5,
                  fontWeight: FontWeight.w500,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                ),
              ),
              Text(
                '$prescribed / $suggested day${suggested > 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: isMobile ? 13 : 15,
                  fontWeight: FontWeight.w800,
                  color: t.textPrimary,
                ),
              ),
            ],
          ),
        ),
        if (refundAmt > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF451A03) : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? const Color(0xFFD97706) : Colors.orange.shade300, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.payments_rounded, color: isDark ? const Color(0xFFFBBF24) : Colors.orange.shade900, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'REFUND REQUIRED: Rs. $refundAmt',
                        style: TextStyle(
                          color: isDark ? const Color(0xFFFBBF24) : Colors.orange.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days.',
                        style: TextStyle(color: isDark ? const Color(0xFFFDE68A) : Colors.orange.shade800, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        if (extraAmt > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF450A0A) : Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? const Color(0xFFEF4444) : Colors.red.shade300, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: isDark ? const Color(0xFFF87171) : Colors.red.shade900, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'EXTRA PAYMENT NEEDED: Rs. $extraAmt',
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF87171) : Colors.red.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days.',
                        style: TextStyle(color: isDark ? const Color(0xFFFECACA) : Colors.red.shade800, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );

    if (labTests.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: durationWidget,
      );
    }

    final labWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isPhysio ? 'Physiotherapies' : 'Lab tests',
          style: TextStyle(
            fontSize: isMobile ? 13 : 15,
            fontWeight: FontWeight.w700,
            color: t.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: labTests.map((item) {
            final name = item['name']?.toString() ?? 'Unknown';
            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 12 : 14,
                vertical: isMobile ? 8 : 10,
              ),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPhysio ? Icons.spa_rounded : Icons.science_outlined,
                    color: isDark ? const Color(0xFF2DD4BF) : t.accent,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13.5,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: isMobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labWidget,
                const SizedBox(height: 14),
                durationWidget,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: labWidget),
                const SizedBox(width: 16),
                Expanded(child: durationWidget),
              ],
            ),
    );
  }

  Widget _buildSyringeSelectionCard(List<dynamic> allPrescriptions, RoleThemeData t, {required bool isMobile}) {
    final isDark = _isDark;
    final autoCount = _getAutoSyringeCount(allPrescriptions).clamp(0, 3);
    if (autoCount == 0) return const SizedBox.shrink();
    final effectiveCount = (_selectedSyringeCount ?? autoCount).clamp(0, 3);
    final availableSyringes = _getAvailableSyringeStockItems();
    if (_selectedSyringeHiveKey == null && availableSyringes.isNotEmpty) {
      _selectedSyringeHiveKey = availableSyringes.first['hiveKey'];
    }

    return Container(
      margin: EdgeInsets.only(top: isMobile ? 12 : 16),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF134E4A).withValues(alpha: 0.3) : t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0xFF2DD4BF).withValues(alpha: 0.4) : t.accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF134E4A) : t.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.vaccines_rounded, color: isDark ? const Color(0xFF2DD4BF) : t.accent, size: isMobile ? 22 : 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Syringes To Dispense',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 14 : 16,
                      ),
                    ),
                    Text(
                      'Auto-calculated: $autoCount syringe${autoCount > 1 ? 's' : ''} (Max 3)',
                      style: TextStyle(
                        color: t.textSecondary,
                        fontSize: isMobile ? 11 : 12,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: effectiveCount > 0
                        ? () => setState(() => _selectedSyringeCount = (effectiveCount - 1).clamp(0, 3))
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                    color: isDark ? const Color(0xFF2DD4BF) : t.accent,
                    iconSize: isMobile ? 24 : 28,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? const Color(0xFF2DD4BF) : t.accent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      '$effectiveCount',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: isMobile ? 15 : 18,
                        color: t.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: effectiveCount < 3
                        ? () => setState(() => _selectedSyringeCount = (effectiveCount + 1).clamp(0, 3))
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                    color: isDark ? const Color(0xFF2DD4BF) : t.accent,
                    iconSize: isMobile ? 24 : 28,
                  ),
                ],
              ),
            ],
          ),

          // Available CC Options Selector
          if (availableSyringes.isEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF450A0A) : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? Colors.red.shade800 : Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: Colors.red.shade600),
                  const SizedBox(width: 6),
                  Text(
                    'No Syringes in Stock in local inventory',
                    style: TextStyle(fontSize: 11.5, color: isDark ? Colors.red.shade200 : Colors.red.shade800, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Select Syringe Capacity (CC):',
                  style: TextStyle(
                    color: t.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 12 : 13,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(In-stock options)',
                  style: TextStyle(
                    color: t.textTertiary,
                    fontSize: isMobile ? 10 : 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: availableSyringes.map((syr) {
                final isSelected = _selectedSyringeHiveKey == syr['hiveKey'];
                final label = _formatSyringeLabel(syr);
                final stockQty = (syr['quantity'] is num) ? syr['quantity'].toInt() : int.tryParse(syr['quantity']?.toString() ?? '') ?? 0;
                return InkWell(
                  onTap: () => setState(() => _selectedSyringeHiveKey = syr['hiveKey']),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (isDark ? const Color(0xFF0D9488) : t.accent)
                          : (isDark ? const Color(0xFF0F172A) : Colors.white),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? (isDark ? const Color(0xFF2DD4BF) : t.accent)
                            : (isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                        width: isSelected ? 1.6 : 1.0,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: t.accent.withValues(alpha: 0.25),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              )
                            ]
                          : [],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.colorize_rounded,
                          size: 14,
                          color: isSelected ? Colors.white : (isDark ? const Color(0xFF2DD4BF) : t.accent),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                            fontSize: isMobile ? 12 : 13,
                            color: isSelected ? Colors.white : t.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.25)
                                : (isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Stock: $stockQty',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.grey.shade700),
                            ),
                          ),
                        ),
                      ],
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

  Widget _buildNeedleSelectionCard(List<dynamic> allPrescriptions, RoleThemeData t, {required bool isMobile}) {
    final isDark = _isDark;
    final autoCount = _getAutoNeedleCount(allPrescriptions).clamp(0, 3);
    if (autoCount == 0) return const SizedBox.shrink();
    final effectiveCount = (_selectedNeedleCount ?? autoCount).clamp(0, 3);

    return Container(
      margin: EdgeInsets.only(top: isMobile ? 8 : 12),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF14532D).withValues(alpha: 0.3) : const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0xFF4ADE80).withValues(alpha: 0.4) : const Color(0xFFA5D6A7)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF14532D) : const Color(0xFFC8E6C9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.pin_outlined, color: isDark ? const Color(0xFF4ADE80) : const Color(0xFF2E7D32), size: isMobile ? 22 : 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Needles To Dispense',
                  style: TextStyle(
                    color: t.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 14 : 16,
                  ),
                ),
                Text(
                  'Auto-calculated: $autoCount needle${autoCount > 1 ? 's' : ''} (Max 3)',
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: isMobile ? 11 : 12,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: effectiveCount > 0
                    ? () => setState(() => _selectedNeedleCount = (effectiveCount - 1).clamp(0, 3))
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
                color: isDark ? const Color(0xFF4ADE80) : const Color(0xFF2E7D32),
                iconSize: isMobile ? 24 : 28,
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? const Color(0xFF4ADE80) : const Color(0xFFA5D6A7)),
                ),
                child: Text(
                  '$effectiveCount',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: isMobile ? 15 : 18,
                    color: t.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: effectiveCount < 3
                    ? () => setState(() => _selectedNeedleCount = (effectiveCount + 1).clamp(0, 3))
                    : null,
                icon: const Icon(Icons.add_circle_outline),
                color: isDark ? const Color(0xFF4ADE80) : const Color(0xFF2E7D32),
                iconSize: isMobile ? 24 : 28,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Header / footer ──────────────────────────────────────────────────────
  Widget _buildHeader(RoleThemeData t, {required bool isMobile}) => ClipRRect(
    borderRadius: BorderRadius.vertical(top: Radius.circular(isMobile ? 12 : 16)),
    child: Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: isMobile ? 10 : 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.accent, t.accentLight],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Image.asset('assets/logo/gmwf-1.webp', width: isMobile ? 54 : 70, height: isMobile ? 54 : 70),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              children: [
                const Text(
                  'ہو الشافی',
                  style: TextStyle(
                    fontFamily: 'Jameel Noori Nastaleeq',
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'Gulzar Madina Welfare Foundation',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 16,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Free Dispensary',
                  style: TextStyle(
                    fontSize: isMobile ? 10 : 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Transform.rotate(
            angle: -0.42,
            child: Image.asset('assets/images/moon.webp', width: isMobile ? 52 : 68, height: isMobile ? 52 : 68),
          ),
        ],
      ),
    ),
  );

  Widget _buildFooter(RoleThemeData t, {required bool isMobile}) => ClipRRect(
    borderRadius: BorderRadius.vertical(bottom: Radius.circular(isMobile ? 12 : 16)),
    child: Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 8 : 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.accent, t.accentLight],
        ),
      ),
      child: Center(
        child: Text(
          'Gulzar Madina ${_branchName ?? ''} • gulzarmadina.com',
          style: TextStyle(
            fontSize: isMobile ? 11 : 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    ),
  );

  String? _getPatientPhone() {
    final rawPhone = _data['phone'] ??
        _data['patientPhone'] ??
        _data['contact'] ??
        _data['mobile'] ??
        _data['cell'] ??
        _data['whatsapp'] ??
        _data['guardianPhone'] ??
        widget.queueEntry['phone'] ??
        widget.queueEntry['contact'] ??
        widget.queueEntry['mobile'] ??
        widget.queueEntry['cell'] ??
        widget.queueEntry['whatsapp'] ??
        widget.queueEntry['guardianPhone'] ??
        widget.queueEntry['patientPhone'];

    if (rawPhone != null && rawPhone.toString().trim().isNotEmpty) {
      return rawPhone.toString().trim();
    }

    // Try finding patient from LocalStorageService by CNIC
    final cnic = _data['cnic'] ?? _data['patientCnic'] ?? widget.queueEntry['cnic'] ?? widget.queueEntry['patientCnic'];
    if (cnic != null && cnic.toString().trim().isNotEmpty) {
      try {
        final list = LocalStorageService.searchPatientsByCnicOrGuardian(
          cnic.toString().trim(),
          branchId: widget.branchId,
        );
        if (list.isNotEmpty) {
          final pPhone = list.first['phone'] ?? list.first['guardianPhone'] ?? list.first['contact'];
          if (pPhone != null && pPhone.toString().trim().isNotEmpty) {
            return pPhone.toString().trim();
          }
        }
      } catch (_) {}
    }
    return null;
  }

  String _getResolvedPatientName() {
    final candidates = [
      _data['patientName'],
      _data['name'],
      _data['patient_name'],
      widget.queueEntry['patientName'],
      widget.queueEntry['name'],
      widget.queueEntry['patient_name'],
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['patientName'] : null,
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['name'] : null,
    ];
    for (var c in candidates) {
      if (c != null) {
        final str = c.toString().trim();
        if (str.isNotEmpty && str != '0' && str != 'null' && str.toLowerCase() != 'unknown' && str.toLowerCase() != 'unknown patient') {
          return str;
        }
      }
    }
    return 'Patient';
  }

  String _getResolvedCnic() {
    final candidates = [
      _data['patientCnic'],
      _data['cnic'],
      _data['guardianCnic'],
      _data['patientCNIC'],
      widget.queueEntry['patientCnic'],
      widget.queueEntry['cnic'],
      widget.queueEntry['guardianCnic'],
      widget.queueEntry['patientCNIC'],
      widget.queueEntry['guardianCNIC'],
    ];
    for (var c in candidates) {
      if (c != null) {
        final str = c.toString().trim();
        if (str.isNotEmpty &&
            str != '0' &&
            str != '0000000000000' &&
            str != 'null' &&
            !str.toLowerCase().startsWith('unknown_')) {
          return str;
        }
      }
    }
    return 'N/A';
  }

  Future<void> _sharePatientFormPdf() async {
    try {
      final gender = _gender ?? _data['patientGender'] ?? _data['gender'] ?? 'N/A';
      final age = _age != 'N/A' ? '$_age Years' : (_data['patientAge'] ?? _data['age'] ?? 'N/A').toString();
      final phone = _getPatientPhone();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(phone != null && phone.isNotEmpty
                ? 'Generating & attaching PDF for patient phone ($phone)...'
                : 'Generating & attaching patient form PDF...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      final pdfBytes = await PatientFormHelper.generateWhatsAppPdf(
        _data,
        _branchName ?? 'Free Dispensary',
        gender,
        age,
      );

      final patientName = _getResolvedPatientName();
      final pid = _resolvedSerial.isNotEmpty ? _resolvedSerial : 'slip';

      await FileActionHelper.sharePdfToWhatsApp(
        bytes: pdfBytes,
        fileName: 'Prescription_${patientName.replaceAll(RegExp(r'\s+'), '_')}_$pid.pdf',
        phoneNumber: phone,
        text: 'Assalam-o-Alaikum $patientName,\n\nThank you for your visit (Serial #$pid). Here is your PDF receipt from Gulzar Madina Free Dispensary:\n\nاَللّٰهُمَّ يَا شَافِيَ الْأَمْرَاضِ',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📋 WhatsApp opened & PDF copied to clipboard! Press Ctrl+V in WhatsApp to attach.'),
            backgroundColor: Color(0xFF00695C),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share PDF: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _resolveGender() {
    final candidates = [
      _gender,
      _data['patientGender'],
      _data['gender'],
      _data['sex'],
      _data['patientSex'],
      widget.queueEntry['patientGender'],
      widget.queueEntry['gender'],
      widget.queueEntry['sex'],
      widget.queueEntry['patientSex'],
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['gender'] : null,
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['sex'] : null,
    ];
    for (var val in candidates) {
      if (val != null) {
        final str = val.toString().trim();
        if (str.isNotEmpty && str != 'N/A' && str != 'null') {
          if (str.toLowerCase() == 'm' || str.toLowerCase() == 'male') return 'Male';
          if (str.toLowerCase() == 'f' || str.toLowerCase() == 'female') return 'Female';
          return str[0].toUpperCase() + str.substring(1);
        }
      }
    }
    return 'N/A';
  }

  String _resolveAge() {
    // 1. Check explicit age candidates
    final ageCandidates = [
      _age,
      _data['patientAge'],
      _data['age'],
      widget.queueEntry['patientAge'],
      widget.queueEntry['age'],
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['age'] : null,
    ];
    for (var val in ageCandidates) {
      if (val != null) {
        final str = val.toString().trim();
        if (str.isNotEmpty && str != 'N/A' && str != 'null' && str != '0') {
          return str;
        }
      }
    }

    // 2. Check DOB candidates to calculate age
    final dobCandidates = [
      _data['patientDob'],
      _data['dob'],
      _data['dateOfBirth'],
      _data['patientDateOfBirth'],
      widget.queueEntry['patientDob'],
      widget.queueEntry['dob'],
      widget.queueEntry['dateOfBirth'],
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['dob'] : null,
    ];
    for (var val in dobCandidates) {
      if (val != null) {
        if (val is DateTime) {
          final now = DateTime.now();
          int age = now.year - val.year;
          if (now.month < val.month || (now.month == val.month && now.day < val.day)) {
            age--;
          }
          if (age >= 0) return age.toString();
        } else {
          final str = val.toString().trim();
          final parsed = DateTime.tryParse(str);
          if (parsed != null) {
            final now = DateTime.now();
            int age = now.year - parsed.year;
            if (now.month < parsed.month || (now.month == parsed.month && now.day < parsed.day)) {
              age--;
            }
            if (age >= 0) return age.toString();
          } else {
            final yearMatch = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(str);
            if (yearMatch != null) {
              final year = int.tryParse(yearMatch.group(1)!);
              if (year != null) {
                final age = DateTime.now().year - year;
                if (age >= 0 && age < 120) return age.toString();
              }
            }
          }
        }
      }
    }

    return 'N/A';
  }

  Future<void> _handleDownloadPdf() async {
    try {
      final gender = _resolveGender();
      final ageVal = _resolveAge();
      final age = ageVal != 'N/A' ? '$ageVal Years' : 'N/A';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Generating Prescription Report...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      final pdfBytes = await PatientFormHelper.generateWhatsAppPdf(
        _data,
        _branchName ?? 'Free Dispensary',
        gender,
        age,
      );

      final patientName = _getResolvedPatientName();
      final pid = _resolvedSerial.isNotEmpty ? _resolvedSerial : 'slip';
      final fileName = 'Report_${patientName.replaceAll(RegExp(r'\s+'), '_')}_$pid.pdf';
      final phone = _getPatientPhone();

      final savedPath = await FileActionHelper.getTempFilePath(fileName, pdfBytes);

      if (mounted) {
        await FileActionHelper.showFileOptions(
          context,
          filePath: savedPath,
          bytes: pdfBytes,
          fileName: fileName,
          title: 'Patient Report Ready',
          phoneNumber: phone,
          shareText: 'Assalam-o-Alaikum $patientName,\n\nThank you for your visit (Serial #$pid). Here is your PDF report from Gulzar Madina Free Dispensary:\n\nاَللّٰهُمَّ يَا شَافِيَ الْأَمْرَاضِ',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate report: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildActionBar(RoleThemeData t, {required bool isMobile}) {
    final days = _daysOfMedicine;

    final dispenseLabel = _isDispensed
        ? 'Already Dispensed'
        : _isDispensing
            ? 'Dispensing...'
            : days > 1
                ? 'Dispense ($days days\' supply)'
                : 'Dispense Medicine';

    final dispenseBtn = AnimatedScale(
      scale: _isDispensing ? 0.98 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          gradient: !_isDispensed && !_isDispensing ? t.accentGradient : null,
          color: _isDispensed || _isDispensing ? Colors.grey.shade400 : null,
          borderRadius: BorderRadius.circular(27),
          boxShadow: _isDispensed || _isDispensing
              ? []
              : [
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  )
                ],
        ),
        child: ElevatedButton.icon(
          onPressed: _isDispensed || _isDispensing ? null : _dispenseOnly,
          icon: _isDispensing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.check_circle, color: Colors.white, size: 20),
          label: Text(
            dispenseLabel,
            style: TextStyle(
              fontSize: isMobile ? 12 : 14,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.3,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
          ),
        ),
      ),
    );

    final reportBtn = Container(
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFFB91C1C),
        borderRadius: BorderRadius.circular(27),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFB91C1C).withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 5),
          )
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _handleDownloadPdf,
        icon: const Icon(Icons.picture_as_pdf_rounded, color: Colors.white, size: 20),
        label: Text(
          'Report',
          style: TextStyle(
            fontSize: isMobile ? 13 : 15,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
        ),
      ),
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 16 : 28,
              vertical: isMobile ? 12 : 18,
            ),
            decoration: BoxDecoration(
              color: _isDark ? const Color(0xFF0F172A).withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.85),
              border: Border(
                top: BorderSide(color: _isDark ? const Color(0xFF334155) : t.bgRule.withValues(alpha: 0.5), width: 1.5),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(flex: 6, child: dispenseBtn),
                  const SizedBox(width: 12),
                  Expanded(flex: 4, child: reportBtn),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVitalsCard(
    Map<String, dynamic> vitals,
    RoleThemeData t, {
    required bool isMobile,
    required bool isVitalsOnly,
  }) {
    final isDark = _isDark;

    // Extract doctor vitals and receptionist vitals
    final recVitals = (vitals['receptionistVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['receptionistVitals'])
        : <String, dynamic>{};
    final docVitals = (vitals['doctorVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['doctorVitals'])
        : (_data['doctorVitals'] is Map
            ? Map<String, dynamic>.from(_data['doctorVitals'])
            : (widget.queueEntry['doctorVitals'] is Map
                ? Map<String, dynamic>.from(widget.queueEntry['doctorVitals'])
                : <String, dynamic>{}));
    final hasDocUpdate = docVitals.isNotEmpty;

    String cleanVal(dynamic v) {
      if (v == null) return '';
      final s = v.toString().trim();
      if (s == 'N/A' || s == 'null') return '';
      return s;
    }

    // BP
    final docBp = cleanVal(docVitals['bp'] ?? (hasDocUpdate ? vitals['bp'] : null));
    final recBp = cleanVal(recVitals['bp'] ?? (!hasDocUpdate ? vitals['bp'] : null));
    final primaryBp = docBp.isNotEmpty ? docBp : (recBp.isNotEmpty ? recBp : '—');
    final subBp = (hasDocUpdate && recBp.isNotEmpty && recBp != docBp) ? 'Rec: $recBp' : null;

    // Weight
    final docWeightRaw = cleanVal(docVitals['weight'] ?? (hasDocUpdate ? vitals['weight'] : null));
    final recWeightRaw = cleanVal(recVitals['weight'] ?? (!hasDocUpdate ? vitals['weight'] : null));
    final primaryWeight = docWeightRaw.isNotEmpty ? '$docWeightRaw kg' : (recWeightRaw.isNotEmpty ? '$recWeightRaw kg' : '—');
    final subWeight = (hasDocUpdate && recWeightRaw.isNotEmpty && recWeightRaw != docWeightRaw) ? 'Rec: $recWeightRaw kg' : null;

    // Sugar
    final docSugarRaw = cleanVal(docVitals['sugar'] ?? (hasDocUpdate ? vitals['sugar'] : null));
    final recSugarRaw = cleanVal(recVitals['sugar'] ?? (!hasDocUpdate ? vitals['sugar'] : null));
    final primarySugar = docSugarRaw.isNotEmpty ? '$docSugarRaw mg/dL' : (recSugarRaw.isNotEmpty ? '$recSugarRaw mg/dL' : '—');
    final subSugar = (hasDocUpdate && recSugarRaw.isNotEmpty && recSugarRaw != docSugarRaw) ? 'Rec: $recSugarRaw' : null;

    // Temp
    final docTempRaw = cleanVal(docVitals['temp'] ?? (hasDocUpdate ? vitals['temp'] : null));
    final recTempRaw = cleanVal(recVitals['temp'] ?? (!hasDocUpdate ? vitals['temp'] : null));
    final hasTemp = docTempRaw.isNotEmpty || recTempRaw.isNotEmpty;
    final primaryTemp = docTempRaw.isNotEmpty ? '$docTempRaw °C' : (recTempRaw.isNotEmpty ? '$recTempRaw °C' : '—');
    final subTemp = (hasDocUpdate && recTempRaw.isNotEmpty && recTempRaw != docTempRaw) ? 'Rec: $recTempRaw °C' : null;

    final statCards = <Widget>[
      Expanded(
        child: _vitalStatCard(
          title: 'Blood pressure',
          value: primaryBp,
          subValue: subBp,
          color: primaryBp != '—' ? const Color(0xFFDC2626) : (isDark ? Colors.white54 : Colors.grey),
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _vitalStatCard(
          title: 'Weight',
          value: primaryWeight,
          subValue: subWeight,
          color: primaryWeight != '—' ? const Color(0xFF2563EB) : (isDark ? Colors.white54 : Colors.grey),
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _vitalStatCard(
          title: 'Blood sugar',
          value: primarySugar,
          subValue: subSugar,
          color: primarySugar != '—' ? const Color(0xFF0D9488) : (isDark ? Colors.white54 : Colors.grey),
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      if (hasTemp) ...[
        const SizedBox(width: 8),
        Expanded(
          child: _vitalStatCard(
            title: 'Temperature',
            value: primaryTemp,
            subValue: subTemp,
            color: primaryTemp != '—' ? const Color(0xFFD97706) : (isDark ? Colors.white54 : Colors.grey),
            isDark: isDark,
            isMobile: isMobile,
          ),
        ),
      ],
    ];

    return Container(
      margin: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: statCards,
      ),
    );
  }

  Widget _vitalStatCard({
    required String title,
    required String value,
    String? subValue,
    required Color color,
    required bool isDark,
    required bool isMobile,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: isMobile ? 10 : 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isMobile ? 11 : 12.5,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isMobile ? 15 : 18,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          if (subValue != null && subValue.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subValue,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isMobile ? 9.5 : 10.5,
                fontWeight: FontWeight.w500,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContent(RoleThemeData t, {required bool isMobile}) {
    final prescriptions = _getPrescriptionsList();
    final labTests = _getLabResultsList();
    final diagnosis = _getDiagnosisText();
    final patientName = _getResolvedPatientName();
    final rawVitals = widget.queueEntry['vitals'] ?? _data['vitals'];
    final vitals = (rawVitals is Map) ? Map<String, dynamic>.from(rawVitals) : <String, dynamic>{};
    final isVitalsOnly = widget.queueEntry['isVitalsOnly'] == true ||
        widget.queueEntry['vitalsOnly'] == true ||
        _data['isVitalsOnly'] == true ||
        _data['vitalsOnly'] == true;

    final bp = (vitals['bp'] ?? '').toString();
    final temp = (vitals['temp'] ?? '').toString();
    final weight = (vitals['weight'] ?? '').toString();
    final sugar = (vitals['sugar'] ?? '').toString();
    final hasAnyVitals = (bp.isNotEmpty && bp != 'N/A') ||
        (temp.isNotEmpty && temp != 'N/A') ||
        (weight.isNotEmpty && weight != 'N/A') ||
        (sugar.isNotEmpty && sugar != 'N/A');

    final inventoryMeds = prescriptions.where((m) => m['inventoryId'] != null && !PatientFormHelper.isInjectable(m)).toList();
    final inventoryInjectables = prescriptions.where((m) => m['inventoryId'] != null && PatientFormHelper.isInjectable(m)).toList();
    final customMeds = prescriptions.where((m) => m['inventoryId'] == null && !PatientFormHelper.isInjectable(m)).toList();
    final customInjectables = prescriptions.where((m) => m['inventoryId'] == null && PatientFormHelper.isInjectable(m)).toList();
    
    final basePadding = isMobile ? 16.0 : 32.0;

    final serial = _resolvedSerial;
    final genderStr = _resolveGender();
    final ageVal = _resolveAge();
    final ageDisplay = ageVal != 'N/A' ? '$ageVal yrs' : '';
    final genderAgeText = [if (genderStr != 'N/A') genderStr, if (ageDisplay.isNotEmpty) ageDisplay].join(', ');
    final cnic = _getResolvedCnic();

    final isDark = _isDark;

    Widget patientInfoCard = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                patientName,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: isMobile ? 18 : 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'CNIC  $cnic',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  fontSize: isMobile ? 12 : 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              ),
              child: Text(
                serial,
                style: TextStyle(
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                  fontWeight: FontWeight.w600,
                  fontSize: isMobile ? 12 : 13.5,
                ),
              ),
            ),
            if (genderAgeText.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                genderAgeText,
                style: TextStyle(
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                  fontWeight: FontWeight.w700,
                  fontSize: isMobile ? 13 : 15,
                ),
              ),
            ],
          ],
        ),
      ],
    );

    Widget medicineBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start, 
      children: [
        patientInfoCard,
        if (hasAnyVitals || isVitalsOnly)
          _buildVitalsCard(vitals, t, isMobile: isMobile, isVitalsOnly: isVitalsOnly),
        _buildLabAndDurationSection(labTests, t, isMobile: isMobile),
        if (isVitalsOnly && prescriptions.isEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F3FF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFDDD6FE)),
            ),
            child: Row(
              children: [
                const Icon(Icons.health_and_safety_rounded, color: Color(0xFF7C3AED), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Vitals Inspection Token',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF5B21B6),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'This patient arrived for vitals inspection only. No medicines are prescribed.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6D28D9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (diagnosis.isNotEmpty) ...[
          SizedBox(height: isMobile ? 12 : 20),
          _sectionTitle('Diagnosis', Icons.medical_services, t, isMobile: isMobile),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bgCardAlt.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.bgRule.withValues(alpha: 0.4)),
            ),
            child: Text(
              diagnosis, 
              style: TextStyle(
                color: t.textPrimary,
                fontSize: isMobile ? 13 : 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (inventoryMeds.isNotEmpty) ...[
          SizedBox(height: isMobile ? 12 : 20),
          _sectionTitle('Inventory Medicines', Icons.medication, t, isMobile: isMobile),
          _linedList(inventoryMeds, t, isMobile: isMobile),
        ],
        if (inventoryInjectables.isNotEmpty) ...[
          SizedBox(height: isMobile ? 12 : 20),
          _sectionTitle('Inventory Injectables', Icons.vaccines, t, isMobile: isMobile),
          _linedList(inventoryInjectables, t, isMobile: isMobile),
        ],
        if (customMeds.isNotEmpty) ...[
          SizedBox(height: isMobile ? 12 : 20),
          _sectionTitle('Custom Medicines', Icons.medication_liquid, t, isMobile: isMobile),
          _linedList(customMeds, t, isMobile: isMobile),
        ],
        if (customInjectables.isNotEmpty) ...[
          SizedBox(height: isMobile ? 12 : 20),
          _sectionTitle('Custom Injectables', Icons.vaccines, t, isMobile: isMobile),
          _linedList(customInjectables, t, isMobile: isMobile),
        ],
        if (inventoryInjectables.isNotEmpty || customInjectables.isNotEmpty) ...[
          _buildSyringeSelectionCard(prescriptions, t, isMobile: isMobile),
          _buildNeedleSelectionCard(prescriptions, t, isMobile: isMobile),
        ],
      ],
    );

    return Container(
      color: isDark ? const Color(0xFF0F172A) : Colors.white,
      padding: EdgeInsets.all(basePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          medicineBody,
          const SizedBox(height: 20),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final isMobile = GBreakpoint.isMobile(context);
    final isDark = _isDark;
    
    // Curated GMWF Brand Clinical Theme (Dark Mode Adaptive)
    final t = isDark
        ? const RoleThemeData(
            roleLabel:             'CLINICAL',
            bg:                    Color(0xFF0F172A),
            bgCard:                Color(0xFF1E293B),
            bgCardAlt:             Color(0xFF334155),
            bgRule:                Color(0xFF475569),
            accent:                Color(0xFF0D9488),
            accentLight:           Color(0xFF14B8A6),
            accentMuted:           Color(0xFF0F766E),
            accentGradient:        LinearGradient(colors: [Color(0xFF0F766E), Color(0xFF14B8A6)]),
            glassTint:             Color(0x3300695C),
            textPrimary:           Color(0xFFF8FAFC),
            textSecondary:         Color(0xFFCBD5E1),
            textTertiary:          Color(0xFF94A3B8),
            danger:                Color(0xFFEF4444),
            zakat:                 Color(0xFF22C55E),
            nonZakat:              Color(0xFF3B82F6),
            gmwf:                  Color(0xFFF97316),
            cardFillTokens:        Color(0xFF0F766E),
            cardFillPrescriptions: Color(0xFF115E59),
            cardFillDispensary:    Color(0xFF134E4A),
            chartBar1:             Color(0xFF0D9488),
            chartBar2:             Color(0xFF22C55E),
            chartBar3:             Color(0xFF3B82F6),
            chartGrid:             Color(0xFF334155),
          )
        : const RoleThemeData(
            roleLabel:             'CLINICAL',
            bg:                    Color(0xFFF2FBF9),
            bgCard:                Color(0xFFFFFFFF),
            bgCardAlt:             Color(0xFFE6F7F4),
            bgRule:                Color(0xFFCBECE6),
            accent:                Color(0xFF00695C),
            accentLight:           Color(0xFF0D9488),
            accentMuted:           Color(0xFFE0F2F1),
            accentGradient:        LinearGradient(colors: [Color(0xFF00695C), Color(0xFF0D9488)]),
            glassTint:             Color(0x1A00695C),
            textPrimary:           Color(0xFF002521),
            textSecondary:         Color(0xFF004D43),
            textTertiary:          Color(0xFF4DB6A7),
            danger:                Color(0xFFB91C1C),
            zakat:                 Color(0xFF2E7D32),
            nonZakat:              Color(0xFF1565C0),
            gmwf:                  Color(0xFFE65100),
            cardFillTokens:        Color(0xFF00695C),
            cardFillPrescriptions: Color(0xFF004D43),
            cardFillDispensary:    Color(0xFF00332C),
            chartBar1:             Color(0xFF00695C),
            chartBar2:             Color(0xFF2E7D32),
            chartBar3:             Color(0xFF1565C0),
            chartGrid:             Color(0xFFCBECE6),
          );

    if (_isLoadingPrescription) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, 
          children: [
            CircularProgressIndicator(color: t.accent),
            const SizedBox(height: 16),
            Text('Loading prescription...', style: TextStyle(color: t.accent, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }
    if (_data.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.hourglass_empty, size: 80, color: isDark ? const Color(0xFF94A3B8) : Colors.grey),
        const SizedBox(height: 16),
        Text('No prescription found yet',
            style: TextStyle(color: isDark ? const Color(0xFFCBD5E1) : Colors.grey, fontSize: 18)),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _loadPrescription, icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: Colors.white,
          )),
      ]));
    }
    final bottomBarHeight = 76.0;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.grey[50],
      body: Stack(children: [
        SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(
              left: isMobile ? 6 : 12, right: isMobile ? 6 : 12,
              top: isMobile ? 6 : 12, bottom: bottomBarHeight + 36),
          child: Center(child: Container(
            constraints: isMobile ? const BoxConstraints() : const BoxConstraints(maxWidth: 950),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
              border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: isDark ? Colors.black26 : Colors.black.withValues(alpha: 0.04), 
                  blurRadius: 10, 
                  offset: const Offset(0, 4),
                )
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              _buildHeader(t, isMobile: isMobile),
              _buildContent(t, isMobile: isMobile),
              _buildFooter(t, isMobile: isMobile),
            ]),
          )),
        ),
        _buildActionBar(t, isMobile: isMobile),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREMIUM PRINT & SHARE OPTIONS SHEET (Matches donations design system)
// ─────────────────────────────────────────────────────────────────────────────
class _PatientPrintOptionsSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final String branchName;
  final String serial;
  final String queueType;
  final String? branchId;

  const _PatientPrintOptionsSheet({
    required this.data,
    required this.branchName,
    required this.serial,
    required this.queueType,
    this.branchId,
  });

  @override
  State<_PatientPrintOptionsSheet> createState() => _PatientPrintOptionsSheetState();
}

class _PatientPrintOptionsSheetState extends State<_PatientPrintOptionsSheet> {
  bool _isGenerating = false;
  String _loadingMessage = '';

  String _getResolvedPatientName() {
    return widget.data['patientName'] ??
        widget.data['name'] ??
        widget.data['fullName'] ??
        'Patient';
  }

  String? _getPatientPhone() {
    final rawPhone = widget.data['phone'] ??
        widget.data['patientPhone'] ??
        widget.data['guardianPhone'] ??
        widget.data['contact'] ??
        widget.data['mobile'] ??
        widget.data['cell'] ??
        widget.data['whatsapp'];
    if (rawPhone != null && rawPhone.toString().trim().isNotEmpty) {
      return rawPhone.toString().trim();
    }

    final cnic = widget.data['cnic'] ?? widget.data['patientCnic'];
    if (cnic != null && cnic.toString().trim().isNotEmpty) {
      try {
        final bId = widget.branchId ?? widget.data['branchId']?.toString();
        final list = LocalStorageService.searchPatientsByCnicOrGuardian(
          cnic.toString().trim(),
          branchId: bId,
        );
        if (list.isNotEmpty) {
          final pPhone = list.first['phone'] ?? list.first['guardianPhone'] ?? list.first['contact'];
          if (pPhone != null && pPhone.toString().trim().isNotEmpty) {
            return pPhone.toString().trim();
          }
        }
      } catch (_) {}
    }
    return null;
  }

  void _showLoading(String msg) {
    setState(() {
      _isGenerating = true;
      _loadingMessage = msg;
    });
  }

  void _hideLoading() {
    setState(() {
      _isGenerating = false;
    });
  }

  Future<void> _handlePrint() async {
    _showLoading('Preparing print slip...');
    Uint8List? pdfBytes;
    try {
      pdfBytes = await PatientFormHelper.generatePrintSlip(
        data: widget.data,
        branchName: widget.branchName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) _hideLoading();
    }

    if (pdfBytes != null) {
      await Printing.layoutPdf(
        onLayout: (_) => pdfBytes!,
        name: 'Slip_${widget.serial.isNotEmpty ? widget.serial : 'unknown'}.pdf',
      );
    }
  }

  Future<void> _handleSavePdf() async {
    _showLoading('Generating PDF file...');
    Uint8List? pdfBytes;
    try {
      pdfBytes = await PatientFormHelper.generatePrintSlip(
        data: widget.data,
        branchName: widget.branchName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save PDF failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) _hideLoading();
    }

    if (pdfBytes != null && mounted) {
      final pid = widget.serial.isNotEmpty ? widget.serial : 'unknown';
      final fileName = 'Slip_$pid.pdf';
      final phone = _getPatientPhone();
      final savedPath = await FileActionHelper.getTempFilePath(fileName, pdfBytes);
      await FileActionHelper.showFileOptions(
        context,
        filePath: savedPath,
        bytes: pdfBytes,
        fileName: fileName,
        title: 'Prescription Slip Ready',
        phoneNumber: phone,
      );
    }
  }

  Future<void> _handleWhatsAppShare() async {
    final patientName = _getResolvedPatientName();
    final phone = _getPatientPhone();

    _showLoading('Generating & attaching WhatsApp PDF...');
    Uint8List? pdfBytes;
    try {
      final gender = widget.data['patientGender'] ?? widget.data['gender'] ?? 'N/A';
      final age = (widget.data['patientAge'] ?? widget.data['age'] ?? 'N/A').toString();

      pdfBytes = await PatientFormHelper.generateWhatsAppPdf(
        widget.data,
        widget.branchName,
        gender,
        age,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('WhatsApp share failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) _hideLoading();
    }

    if (pdfBytes != null) {
      final pid = widget.serial.isNotEmpty ? widget.serial : 'N/A';
      await FileActionHelper.sharePdfToWhatsApp(
        bytes: pdfBytes,
        fileName: 'Prescription_${widget.serial.isNotEmpty ? widget.serial : 'unknown'}.pdf',
        phoneNumber: phone,
        text: 'Assalam-o-Alaikum $patientName,\n\nThank you for your visit (Serial #$pid). Here is your PDF receipt from Gulzar Madina Free Dispensary:\n\nاَللّٰهُمَّ يَا شَافِيَ الْأَمْرَاضِ',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📋 WhatsApp opened & PDF copied to clipboard! Press Ctrl+V in WhatsApp to attach.'),
            backgroundColor: Color(0xFF00695C),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Widget _infoSummary(String label, String value) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: Color(0xFF4DB6A7),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: Color(0xFF002521),
          ),
        ),
      ],
    );
  }

  Widget _premiumPrintBtn({
    required String label,
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 90,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Image.asset('assets/logo/gmwf-1.webp', height: 36, errorBuilder: (_, __, ___) => const Icon(Icons.medical_services, color: Color(0xFF00695C))),
                  const Text(
                    'Print & Share Slip',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF002521),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.grey),
                    style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Patient Info Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F7F4),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFCBECE6)),
                ),
                child: Column(
                  children: [
                    Text(
                      (widget.data['patientName'] ?? 'Unknown Patient').toString().toUpperCase(), 
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF00695C),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _infoSummary('Serial Token', '#${widget.serial}'),
                        Container(width: 1, height: 24, color: const Color(0xFFCBECE6)),
                        _infoSummary('Queue Type', widget.queueType.toUpperCase()),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.grey.shade100),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _premiumPrintBtn(
                      label: 'Print Slip',
                      color: const Color(0xFF00695C),
                      icon: Icons.print_rounded,
                      onTap: _handlePrint,
                    ),
                    _premiumPrintBtn(
                      label: 'Save PDF',
                      color: const Color(0xFFB91C1C),
                      icon: Icons.picture_as_pdf_rounded,
                      onTap: _handleSavePdf,
                    ),
                    _premiumPrintBtn(
                      label: 'WhatsApp',
                      color: const Color(0xFF2E7D32),
                      icon: Icons.share_rounded,
                      onTap: _handleWhatsAppShare,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isGenerating)
            Positioned.fill(
              child: Container(
                color: Colors.white.withOpacity(0.9),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Color(0xFF00695C)),
                      const SizedBox(height: 16),
                      Text(
                        _loadingMessage,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF002521),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
