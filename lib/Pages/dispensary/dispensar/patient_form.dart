// lib/pages/dispensary/dispensar/patient_form.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:another_flushbar/flushbar.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'patient_form_helper.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/theme/app_theme.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/widgets/file_action_helper.dart';

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
    final fromData = _data['prescriptions'];
    if (fromData is List && fromData.isNotEmpty) return fromData;
    final embeddedData = _data['prescription'];
    if (embeddedData is Map && embeddedData['prescriptions'] is List) {
      final list = embeddedData['prescriptions'] as List;
      if (list.isNotEmpty) return list;
    }
    final fromQueue = widget.queueEntry['prescriptions'];
    if (fromQueue is List && fromQueue.isNotEmpty) return fromQueue;
    final embeddedQueue = widget.queueEntry['prescription'];
    if (embeddedQueue is Map && embeddedQueue['prescriptions'] is List) {
      final list = embeddedQueue['prescriptions'] as List;
      if (list.isNotEmpty) return list;
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
      if (found.isEmpty && serial.isNotEmpty) {
        found = await _fetchFromPrescriptionsScanAll(serial);
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

  Future<Map<String, dynamic>> _fetchFromPrescriptionsScanAll(String serial) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collectionGroup('prescriptions')
          .where('serial', isEqualTo: serial)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 4));
      if (snapshot.docs.isNotEmpty) {
        final prescSnap = snapshot.docs.first;
        final d = Map<String, dynamic>.from(prescSnap.data());
        d['id'] = prescSnap.id; d['serial'] = prescSnap.id;
        final parentPath = prescSnap.reference.parent.parent;
        if (parentPath != null) {
          d['patientCnic'] = parentPath.id; 
          d['cnic'] = parentPath.id;
        }
        return d;
      }
    } catch (e) { debugPrint('[PatientForm] Firestore collectionGroup error: $e'); }
    return {};
  }

  Future<Map<String, dynamic>> _fetchFromSerialsEmbedded(String serial) async {
    try {
      final dateKey = serial.contains('-')
          ? serial.split('-')[0]
          : DateFormat('ddMMyy').format(DateTime.now());
      if (dateKey.isEmpty) return {};
      for (final type in ['zakat', 'non-zakat', 'gmwf']) {
        final snap = await FirebaseFirestore.instance
            .collection('branches').doc(widget.branchId)
            .collection('serials').doc(dateKey)
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
    final rx = (_data['prescriptions'] ?? []) as List;
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

  Future<void> _deductInventoryLocally(
      String branchId, String serial, List<dynamic> medicines, int days) async {
    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      var medicineId = (medMap['inventoryId'] ??
              medMap['medicineId'] ?? medMap['id'] ?? '').toString().trim();
      final perDayRaw = medMap['quantity'] ?? medMap['qty'] ?? 0;
      final perDay = perDayRaw is num
          ? perDayRaw.toDouble()
          : double.tryParse(perDayRaw.toString()) ?? 0.0;
      if (medicineId.isEmpty || perDay <= 0) continue;
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final multiplier = isSyrup
          ? 1.0
          : (_isInjectableType(medMap['type']?.toString()) ? 1.0 : days.toDouble());
      final qtyNum = isSyrup ? 1.0 : perDay * multiplier;
      debugPrint('[PatientForm] deduct $medicineId: (isSyrup=$isSyrup) perDay=${perDay}/day × $multiplier = $qtyNum');
      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        var existing = stockBox.get('stock:$medicineId');
        var keyUsed = 'stock:$medicineId';
        if (existing == null) {
          existing = stockBox.get(medicineId);
          if (existing != null) {
            keyUsed = medicineId;
          }
        }
        // Name fallback
        if (existing == null) {
          for (final key in stockBox.keys) {
            final val = stockBox.get(key);
            if (val is Map && (val['name']?.toString().toLowerCase().trim() == medMap['name']?.toString().toLowerCase().trim())) {
              existing = val;
              keyUsed = key.toString();
              // Update medicineId for Firestore deduction to match the correct ID
              medicineId = (val['id'] ?? val['medicineId'] ?? medicineId).toString();
              break;
            }
          }
        }
        if (existing is Map) {
          final updated = Map<String, dynamic>.from(existing);
          final q = updated['quantity'];
          final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          updated['quantity'] = (current - qtyNum).clamp(0.0, double.infinity);
          stockBox.put(keyUsed, updated);
          debugPrint('[PatientForm] Hive stock $medicineId: $current → ${updated['quantity']}');
        }
      } catch (e) {
        debugPrint('[PatientForm] Hive stock decrement failed $medicineId: $e');
      }
      // Fire and forget Firestore update so it doesn't block UI loop
      final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString();
      final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();

      // If LAN server is connected, ServerSyncManager handles inventory deduction via WebSocket broadcast
      if (RealtimeManager().isConnected) {
        debugPrint('[PatientForm] LAN connected — server handles cloud inventory deduction for $medicineId');
        continue;
      }

      final invCol = CampSessionService.getCampInventoryPath(
        branchId: branchId,
        campId: patientCampId,
        serial: patientSerial,
      );

      // Enqueue sync for background processing without UI lag
      LocalStorageService.enqueueSync({
        'type': 'update_inventory',
        'branchId': branchId,
        'inventoryId': medicineId,
        'delta': -qtyNum,
        'campId': patientCampId,
        'serial': patientSerial,
      });

    }
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
      activeCamp = CampSessionService.getActiveCamp(widget.branchId) ?? 'haji_camp';
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

        // Strict Camp isolation
        if (CampSessionService.hasCampsForBranch(widget.branchId)) {
          if (activeCamp.isNotEmpty && activeCamp != 'all') {
            final matches = CampSessionService.matchesCamp(
              selectedCamp: activeCamp,
              dispensaryId: m['dispensaryId']?.toString(),
              campId: m['campId']?.toString(),
              dispensaryTag: m['dispensaryTag']?.toString(),
              serial: (m['barcode'] ?? m['code'] ?? m['id'] ?? key)?.toString(),
            );
            if (!matches) continue;
          }
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
            try {
              final conn = await Connectivity().checkConnectivity();
              final online = !conn.contains(ConnectivityResult.none);
              if (online) {
                final docRef = FirebaseFirestore.instance
                    .collection('branches').doc(branchId)
                    .collection(invCol).doc(rawSyringeId);
                await FirebaseFirestore.instance.runTransaction((transaction) async {
                  final snapshot = await transaction.get(docRef);
                  if (snapshot.exists) {
                    final sq = snapshot.data()?['quantity'] ?? snapshot.data()?['stock'];
                    final scurrent = sq is num ? sq.toDouble() : double.tryParse(sq?.toString() ?? '') ?? 0.0;
                    final updated = (scurrent - totalSyringesToDeduct).clamp(0.0, double.infinity);
                    transaction.update(docRef, {'quantity': updated, 'stock': updated});
                  }
                });
                debugPrint('[PatientForm] ✅ Auto-deducted $totalSyringesToDeduct Syringe ($rawSyringeId) in Firestore $invCol');
                return;
              }
            } catch (e) {
              debugPrint('[PatientForm] Auto-deducted syringe Firestore update failed: $e');
            }
            // If offline or failed, enqueue sync
            await LocalStorageService.enqueueSync({
              'type': 'update_inventory', 'branchId': branchId,
              'inventoryId': rawSyringeId, 'delta': -totalSyringesToDeduct,
              'campId': patientCampId,
              'serial': patientSerial,
            });
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
            try {
              final conn = await Connectivity().checkConnectivity();
              final online = !conn.contains(ConnectivityResult.none);
              if (online) {
                final docRef = FirebaseFirestore.instance
                    .collection('branches').doc(branchId)
                    .collection(invCol).doc(rawNeedleId);
                await FirebaseFirestore.instance.runTransaction((transaction) async {
                  final snapshot = await transaction.get(docRef);
                  if (snapshot.exists) {
                    final q = snapshot.data()?['quantity'];
                    final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
                    final updated = (current - totalNeedlesToDeduct).clamp(0.0, double.infinity);
                    transaction.update(docRef, {'quantity': updated});
                  }
                });
                debugPrint('[PatientForm] ✅ Auto-deducted $totalNeedlesToDeduct Needle ($rawNeedleId) in Firestore');
                return;
              }
            } catch (e) {
              debugPrint('[PatientForm] Auto-deducted needle Firestore update failed: $e');
            }
            await LocalStorageService.enqueueSync({
              'type': 'update_inventory', 'branchId': branchId,
              'inventoryId': rawNeedleId, 'delta': -totalNeedlesToDeduct,
              'campId': patientCampId,
              'serial': patientSerial,
            });
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

    // Check stock levels first
    final stockBox = Hive.box(LocalStorageService.stockBox);
    final List<String> insufficientMeds = [];

    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final medicineId = (medMap['inventoryId'] ??
              medMap['medicineId'] ?? medMap['id'] ?? '').toString().trim();
      final perDayRaw = medMap['quantity'] ?? medMap['qty'] ?? 0;
      final perDay = perDayRaw is num
          ? perDayRaw.toDouble()
          : double.tryParse(perDayRaw.toString()) ?? 0.0;
      if (medicineId.isEmpty || perDay <= 0) continue;
      
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final multiplier = isSyrup
          ? 1.0
          : (_isInjectableType(medMap['type']?.toString()) ? 1.0 : days.toDouble());
      final qtyNum = isSyrup ? 1.0 : perDay * multiplier;

      var existing = stockBox.get('stock:$medicineId');
      if (existing == null) {
        existing = stockBox.get(medicineId);
      }
      // Name fallback
      if (existing == null) {
        for (final val in stockBox.values) {
          if (val is Map && (val['name']?.toString().toLowerCase().trim() == medMap['name']?.toString().toLowerCase().trim())) {
            existing = val;
            break;
          }
        }
      }

      double currentStock = 0.0;
      if (existing is Map) {
        final q = existing['quantity'];
        currentStock = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
      }

      if (currentStock < qtyNum) {
        final medName = medMap['name'] ?? 'Unknown Medicine';
        insufficientMeds.add('$medName (Required: ${qtyNum.toInt()}, Stock: ${currentStock.toInt()})');
      }
    }

    // Check syringes if needed
    final totalSyringesToDeduct = _getEffectiveSyringeCount(allPrescriptions).toDouble();

    if (totalSyringesToDeduct > 0.0) {
      final availableSyringes = _getAvailableSyringeStockItems();
      if (availableSyringes.isEmpty) {
        insufficientMeds.add('Syringe (Required: ${totalSyringesToDeduct.toInt()}, Stock: 0)');
      } else {
        if (_selectedSyringeHiveKey == null) {
          _selectedSyringeHiveKey = availableSyringes.first['hiveKey'];
        }
        Map<String, dynamic>? syringeMap;
        if (_selectedSyringeHiveKey != null) {
          final val = stockBox.get(_selectedSyringeHiveKey);
          if (val is Map) {
            syringeMap = Map<String, dynamic>.from(val);
          }
        }
        syringeMap ??= availableSyringes.first;

        final q = syringeMap['quantity'] ?? syringeMap['stock'] ?? 0;
        final currentSyringes = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;

        if (currentSyringes < totalSyringesToDeduct) {
          final label = _formatSyringeLabel(syringeMap);
          final name = syringeMap['name'] ?? 'Syringe $label';
          insufficientMeds.add('$name (Required: ${totalSyringesToDeduct.toInt()}, Stock: ${currentSyringes.toInt()})');
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
      final serial = _resolvedSerial;
      if (serial.isEmpty) throw Exception(
          'Missing serial — queueEntry keys: ${widget.queueEntry.keys.toList()}');
      final queueType = _resolvedQueueType;
      final now = DateTime.now();
      final dateKey = DateFormat('ddMMyy').format(now);
      final nowIso = now.toIso8601String();
      final dispenserName = widget.dispenserName ?? 'Unknown Dispenser';
      final doctorName = _firstNonEmpty([
        _data['doctorName'], _data['prescribedBy'], _data['updatedBy'],
        widget.queueEntry['doctorName'], 'Unknown',
      ]);
      final tokenBy = _firstNonEmpty([
        widget.queueEntry['createdByName'], widget.queueEntry['tokenBy'],
        widget.queueEntry['createdBy'], 'Unknown',
      ]);
      final minimalUpdate = {
        'dispenseStatus': 'dispensed',
        'status': 'completed',
        'dispensedAt': nowIso,
        'dispensedBy': dispenserName,
        'dispenserName': dispenserName,
        'serial': serial,
        'dateKey': dateKey,
        'queueType': queueType,
        'branchId': widget.branchId,
        'daysOfMedicine': days,
      };

      // 1. Update local entries box immediately (preserve existing patient & prescription data)
      final normBranch = widget.branchId.trim().toLowerCase();
      final normSerial = serial.trim().toUpperCase();
      final canonicalKey = '$normBranch-$normSerial';
      final entriesBox = Hive.box(LocalStorageService.entriesBox);

      Map<String, dynamic>? existingEntry;
      final direct = entriesBox.get(canonicalKey) ?? entriesBox.get('${widget.branchId}-$serial') ?? entriesBox.get(serial);
      if (direct is Map) {
        existingEntry = Map<String, dynamic>.from(direct);
      } else {
        for (final k in entriesBox.keys) {
          final kStr = k.toString();
          if (kStr.toUpperCase() == normSerial || kStr.toUpperCase().endsWith('-$normSerial')) {
            final val = entriesBox.get(k);
            if (val is Map) {
              existingEntry = Map<String, dynamic>.from(val);
              break;
            }
          }
        }
      }

      final fullEntry = <String, dynamic>{
        if (existingEntry != null) ...existingEntry,
        ...Map<String, dynamic>.from(widget.queueEntry),
        ...Map<String, dynamic>.from(_data),
        ...minimalUpdate,
        'doctorName': doctorName,
        'prescribedBy': doctorName,
        'tokenBy': tokenBy,
        'createdByName': tokenBy,
      };

      await entriesBox.put(canonicalKey, fullEntry);
      // Clean up legacy non-canonical keys so duplicate records are not kept
      if (entriesBox.containsKey(serial)) {
        await entriesBox.delete(serial);
      }
      if (entriesBox.containsKey(serial.toUpperCase())) {
        await entriesBox.delete(serial.toUpperCase());
      }
      if (canonicalKey != '${widget.branchId}-$serial' && entriesBox.containsKey('${widget.branchId}-$serial')) {
        await entriesBox.delete('${widget.branchId}-$serial');
      }

      await LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'dispensed');

      // 2. Save dispensary record locally
      final dispensaryRecord = {
        ...Map<String, dynamic>.from(widget.queueEntry),
        ...Map<String, dynamic>.from(_data),
        'branchId': widget.branchId,
        'serial': serial,
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
        'doctorName': doctorName,
        'prescribedBy': doctorName,
        'tokenBy': tokenBy,
        'createdByName': tokenBy,
        'daysOfMedicine': days,
      };
      await LocalStorageService.saveLocalDispensaryRecord(dispensaryRecord);

      final allPrescriptions = (_data['prescriptions'] as List?) ?? [];
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
          if (medicines.isNotEmpty) {
            await _deductInventoryLocally(widget.branchId, serial, medicines, days);
          }
          await _deductSyringeIfNeeded(widget.branchId, serial, allPrescriptions);
          await _deductNeedleIfNeeded(widget.branchId, serial, allPrescriptions);

          try {
            RealtimeManager().sendMessage(RealtimeEvents.payload(
              type: 'dispense_completed',
              data: {
                'branchId': widget.branchId,
                'serial': serial,
                'dateKey': dateKey,
                ...minimalUpdate,
                if (medicines.isNotEmpty) 'medicines': medicines,
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
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 12 : 16,
            vertical: isMobile ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : t.bgCardAlt.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? const Color(0xFF334155) : t.bgRule.withValues(alpha: 0.7)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          displayName,
                          style: TextStyle(
                            color: isDark ? Colors.white : t.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: isMobile ? 13.5 : 16,
                          ),
                        ),
                        if (dose.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF134E4A) : t.accent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: isDark ? const Color(0xFF2DD4BF) : t.accent.withValues(alpha: 0.4)),
                            ),
                            child: Text(
                              dose,
                              style: TextStyle(
                                color: isDark ? const Color(0xFF2DD4BF) : t.accent,
                                fontSize: isMobile ? 10 : 11.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF134E4A) : t.accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isSyrup ? '1 Bottle' : (isInj ? 'Single Dose' : '$perDayQty/day'),
                            style: TextStyle(
                              color: isDark ? const Color(0xFF2DD4BF) : t.accent,
                              fontSize: isMobile ? 10 : 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!isInj)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF14532D) : t.zakat.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Qty: $totalQty total',
                              style: TextStyle(
                                color: isDark ? const Color(0xFF4ADE80) : t.zakat,
                                fontSize: isMobile ? 10 : 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (urduLine.isNotEmpty)
                      Text(
                        urduLine,
                        textAlign: TextAlign.right,
                        textDirection: ui.TextDirection.rtl,
                        style: TextStyle(
                          fontFamily: 'Jameel Noori Nastaleeq',
                          fontSize: isMobile ? 15 : 18,
                          color: isDark ? const Color(0xFFE2E8F0) : t.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (mealUrdu.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          mealUrdu,
                          textAlign: TextAlign.right,
                          textDirection: ui.TextDirection.rtl,
                          style: TextStyle(
                            fontFamily: 'Jameel Noori Nastaleeq',
                            fontSize: isMobile ? 13 : 15,
                            color: isDark ? const Color(0xFF94A3B8) : t.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ─── "Medicines for X days" banner ────────────────────────────────────────
  Widget _buildDaysBanner(RoleThemeData t, {required bool isMobile}) {
    final prescribed = _daysOfMedicine;
    final suggested  = _suggestedDays;
    final queueType  = _resolvedQueueType;

    final prices = _isKarachi
        ? const {'zakat': 20, 'non-zakat': 20, 'gmwf': 0}
        : const {'zakat': 20, 'non-zakat': 100, 'gmwf': 0};
    final rate = prices[queueType] ?? 0;

    final refundDays = suggested - prescribed;
    final extraDays  = prescribed - suggested;
    final refundAmt  = refundDays > 0 ? refundDays * rate : 0;
    final extraAmt   = extraDays > 0 ? extraDays * rate : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: EdgeInsets.only(bottom: isMobile ? 8 : 10),
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: t.accent.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.accent.withValues(alpha: 0.15)),
          ),
          child: Row(
            children: [
              Icon(Icons.calendar_today, color: t.accent, size: isMobile ? 24 : 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Medicine Duration Summary',
                      style: PatientFormHelper.robotoBold(size: isMobile ? 14 : 16, color: t.accent),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _dayPill('Paid: $suggested day${suggested > 1 ? 's' : ''}', t.textSecondary),
                        const SizedBox(width: 8),
                        _dayPill('Prescribed: $prescribed day${prescribed > 1 ? 's' : ''}', t.accent),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Refund Alert
        if (refundAmt > 0)
          Container(
            margin: EdgeInsets.only(bottom: isMobile ? 12 : 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.shade300, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.payments_rounded, color: Colors.orange.shade900, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'REFUND REQUIRED: Rs. $refundAmt',
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 13 : 15,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days. Please return the extra amount.',
                        style: TextStyle(color: Colors.orange.shade800, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        // Extra Payment Alert
        if (extraAmt > 0)
          Container(
            margin: EdgeInsets.only(bottom: isMobile ? 12 : 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade300, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.red.shade900, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'EXTRA PAYMENT NEEDED: Rs. $extraAmt',
                        style: TextStyle(
                          color: Colors.red.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 13 : 15,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days. Please collect the remaining amount.',
                        style: TextStyle(color: Colors.red.shade800, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
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

  Widget _infoTile(IconData icon, String label, String value, RoleThemeData t, bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: t.textTertiary, size: isMobile ? 12 : 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: t.textTertiary,
                fontSize: isMobile ? 9 : 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: t.textPrimary,
            fontSize: isMobile ? 12 : 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildVitalsCard(Map<String, dynamic> vitals, RoleThemeData t, {required bool isMobile, required bool isVitalsOnly}) {
    final bp = (vitals['bp'] ?? 'N/A').toString();
    final temp = (vitals['temp'] ?? 'N/A').toString();
    final weight = (vitals['weight'] ?? 'N/A').toString();
    final sugar = (vitals['sugar'] ?? 'N/A').toString();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: isVitalsOnly ? const Color(0xFFF3E8FF) : const Color(0xFFE6FFFA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isVitalsOnly ? const Color(0xFFD8B4FE) : const Color(0xFF99F6E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isVitalsOnly ? Icons.health_and_safety_rounded : Icons.monitor_heart_rounded,
                color: isVitalsOnly ? const Color(0xFF7E22CE) : const Color(0xFF0F766E),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isVitalsOnly ? '🩺 Vitals Inspection Token (Vital Signs)' : '🩺 Patient Vital Signs',
                style: TextStyle(
                  fontSize: isMobile ? 13 : 15,
                  fontWeight: FontWeight.bold,
                  color: isVitalsOnly ? const Color(0xFF6B21A8) : const Color(0xFF0F766E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _vitalBadge(
                  label: 'Blood Pressure',
                  value: (bp.isEmpty || bp == 'N/A') ? 'N/A' : bp,
                  icon: Icons.favorite_rounded,
                  color: const Color(0xFFDC2626),
                  isMobile: isMobile,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _vitalBadge(
                  label: 'Temperature',
                  value: (temp.isEmpty || temp == 'N/A') ? 'N/A' : '$temp °C',
                  icon: Icons.thermostat_rounded,
                  color: const Color(0xFFD97706),
                  isMobile: isMobile,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _vitalBadge(
                  label: 'Weight',
                  value: (weight.isEmpty || weight == 'N/A') ? 'N/A' : '$weight kg',
                  icon: Icons.scale_rounded,
                  color: const Color(0xFF2563EB),
                  isMobile: isMobile,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _vitalBadge(
                  label: 'Blood Sugar',
                  value: (sugar.isEmpty || sugar == 'N/A') ? 'N/A' : '$sugar mg/dL',
                  icon: Icons.water_drop_rounded,
                  color: const Color(0xFF0D9488),
                  isMobile: isMobile,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _vitalBadge({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isMobile,
  }) {
    final isDark = _isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF334155) : color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Icon(icon, size: isMobile ? 14 : 16, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: isMobile ? 8.5 : 10,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: isMobile ? 10.5 : 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(RoleThemeData t, {required bool isMobile}) {
    final prescriptions = _getPrescriptionsList();
    final labTests = _getLabResultsList();
    final diagnosis = _getDiagnosisText();
    final patientName = _getResolvedPatientName();
    
    final serial = _resolvedSerial;
    final genderStr = _resolveGender();
    final ageVal = _resolveAge();
    final ageDisplay = ageVal != 'N/A' ? '$ageVal Years' : 'N/A';
    final cnic = _getResolvedCnic();
    final queueType = _resolvedQueueType.toUpperCase();

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

    Widget patientInfoCard = Container(
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: t.bgCardAlt.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: isMobile ? 20 : 24,
                backgroundColor: t.accent.withValues(alpha: 0.1),
                child: Icon(Icons.person, color: t.accent, size: isMobile ? 20 : 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patientName,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: isMobile ? 16 : 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'CNIC: $cnic',
                      style: TextStyle(
                        color: t.textTertiary,
                        fontSize: isMobile ? 11 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (isVitalsOnly)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3E8FF),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFC084FC)),
                  ),
                  child: const Text(
                    '🩺 VITALS',
                    style: TextStyle(
                      color: Color(0xFF7E22CE),
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _resolvedQueueType == 'zakat'
                      ? t.zakat.withValues(alpha: 0.15)
                      : _resolvedQueueType == 'non-zakat'
                          ? t.nonZakat.withValues(alpha: 0.15)
                          : t.gmwf.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _resolvedQueueType == 'zakat'
                        ? t.zakat
                        : _resolvedQueueType == 'non-zakat'
                            ? t.nonZakat
                            : t.gmwf,
                  ),
                ),
                child: Text(
                  queueType,
                  style: TextStyle(
                    color: _resolvedQueueType == 'zakat'
                        ? t.zakat
                        : _resolvedQueueType == 'non-zakat'
                            ? t.nonZakat
                            : t.gmwf,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 10 : 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _infoTile(Icons.wc, 'GENDER', genderStr, t, isMobile),
              _infoTile(Icons.cake, 'AGE', ageDisplay, t, isMobile),
              _infoTile(Icons.tag, 'TOKEN SERIAL', serial, t, isMobile),
            ],
          ),
        ],
      ),
    );

    Widget medicineBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start, 
      children: [
        _buildDaysBanner(t, isMobile: isMobile),
        const SizedBox(height: 12),
        patientInfoCard,
        if (hasAnyVitals || isVitalsOnly)
          _buildVitalsCard(vitals, t, isMobile: isMobile, isVitalsOnly: isVitalsOnly),
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
        if (isMobile && labTests.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildLabOrPhysioSection(labTests, t, isMobile: true),
          const SizedBox(height: 12),
          Divider(color: Colors.grey.shade200, height: 20),
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

    final isDark = _isDark;
    return Container(
      color: isDark ? const Color(0xFF0F172A) : Colors.white,
      padding: EdgeInsets.all(basePadding),
      child: isMobile
          ? Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [medicineBody, const SizedBox(height: 20)])
          : IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (labTests.isNotEmpty) ...[
                Expanded(flex: 3, child: _buildLabOrPhysioSection(labTests, t, isMobile: false)),
                Container(width: 1, color: isDark ? const Color(0xFF334155) : Colors.grey.shade300,
                    margin: const EdgeInsets.symmetric(horizontal: 20)),
              ],
              Expanded(flex: 7, child: medicineBody),
            ])),
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
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;
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

  Widget _buildLabOrPhysioSection(List labTests, RoleThemeData t, {required bool isMobile}) {
    if (labTests.isEmpty) return const SizedBox.shrink();
    
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

    final title = isPhysio ? 'Physiotherapies' : 'Lab Tests';
    final icon = isPhysio ? Icons.accessibility_new_rounded : Icons.biotech_rounded;
    final themeColor = isPhysio ? Colors.indigo : t.accent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(title, icon, t, isMobile: isMobile),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: labTests.map((item) {
            final name = item['name']?.toString() ?? 'Unknown';
            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 10 : 14,
                vertical: isMobile ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: themeColor.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: themeColor.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPhysio ? Icons.spa_rounded : Icons.science_rounded,
                    color: themeColor,
                    size: isMobile ? 14 : 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 14,
                      fontWeight: FontWeight.w700,
                      color: themeColor.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
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
