// lib/pages/dispensary/dispensar/patient_form.dart

import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/dispensary_preferences_service.dart';
import 'patient_form_helper.dart';
import 'dispense_queue.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/theme/app_theme.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/widgets/file_action_helper.dart';
import 'package:gmwf/design/design_system.dart';

class PatientForm extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> queueEntry;
  final VoidCallback? onDispensed;
  final String? dispenserName;
  final bool isCompactPreview;
  const PatientForm({
    super.key,
    required this.branchId,
    required this.queueEntry,
    this.onDispensed,
    this.dispenserName,
    this.isCompactPreview = false,
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
  Timer? _claimRenewal;
  bool _doctorUpdatedLive = false;
  String? _doctorLiveUpdateSummary;

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
    if (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
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

  /// Everything about a medicine list that changes what is handed over. Used to notice a
  /// doctor's edit (live, via sync or reload) and to refuse a dispense whose list changed
  /// between the stock check / confirm dialogs and the actual save.
  static String _rxFingerprint(List<dynamic> list) {
    const fields = [
      'name', 'medicineName', 'inventoryId', 'medicineId', 'quantity', 'qty', 'timing',
      'dose', 'dosage', 'type', 'form', 'route', 'daysOfMedicine', 'days', 'duration',
    ];
    final b = StringBuffer('${list.length}#');
    for (final m in list) {
      if (m is! Map) {
        b.write('?|');
        continue;
      }
      for (final f in fields) {
        b
          ..write(m[f]?.toString().trim().toLowerCase() ?? '')
          ..write(',');
      }
      b.write('|');
    }
    return b.toString();
  }

  /// Flags the banner/acknowledge step when an already-shown prescription was replaced by a
  /// different one (any path: LAN event, Firestore sync, queue refresh).
  void _flagIfPrescriptionChanged(String? beforeFingerprint) {
    if (beforeFingerprint == null || _isDispensed) return;
    final list = _getPrescriptionsList();
    if (_rxFingerprint(list) != beforeFingerprint) {
      _doctorUpdatedLive = true;
      _doctorLiveUpdateSummary = 'Doctor updated prescription (${list.length} items)';
      // Reset manual syringe/needle overrides so removed/added injections recalculate immediately
      _selectedSyringeCount = null;
      _selectedNeedleCount = null;
    }
  }

  List<dynamic> _getPrescriptionsList() {
    final fromData = _data['prescriptions'] ?? _data['medicines'] ?? _data['items'];
    if (fromData is List && fromData.isNotEmpty) return fromData;
    final embeddedData = _data['prescription'];
    if (embeddedData is Map) {
      final embList = embeddedData['prescriptions'] ?? embeddedData['medicines'] ?? embeddedData['items'];
      if (embList is List && embList.isNotEmpty) return embList;
    }
    final fromQueue = widget.queueEntry['prescriptions'] ?? widget.queueEntry['medicines'] ?? widget.queueEntry['items'];
    if (fromQueue is List && fromQueue.isNotEmpty) return fromQueue;
    final embeddedQueue = widget.queueEntry['prescription'];
    if (embeddedQueue is Map) {
      final embList = embeddedQueue['prescriptions'] ?? embeddedQueue['medicines'] ?? embeddedQueue['items'];
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
      final entry = LocalStorageService.getLocalEntry(widget.branchId, serial);
      final eDays = entry?['suggestedDays'];
      if (eDays is int && eDays >= 1) return eDays;
    }
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _loadBranchName();
    _loadPrescription();
    _claimForThisDesk();
    _claimRenewal = Timer.periodic(DispenseQueue.claimRenewal, (_) => _claimForThisDesk());
    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = rawData is Map ? Map<String, dynamic>.from(rawData) : <String, dynamic>{};
      if (type == null) return;
      final eventSerial = (data['serial'] ?? data['id'])?.toString().trim() ?? '';
      final mySerial = _resolvedSerial.trim();
      final eventBranch = data['branchId']?.toString().trim().toLowerCase();
      final myBranch = widget.branchId.toLowerCase().trim();
      if (eventBranch != null && eventBranch.isNotEmpty && myBranch.isNotEmpty &&
          eventBranch != myBranch && !CampSessionService.areBranchesMatching(eventBranch, myBranch)) return;
      // Only this patient's events. One without a serial used to pass this check, so another
      // patient's prescription was shown here (or the form reloaded and came up empty).
      if (eventSerial.isEmpty || mySerial.isEmpty ||
          !CampSessionService.isSameSerial(eventSerial, mySerial, myBranch)) return;

      // When prescription arrives from doctor for this active patient, apply immediately!
      if (type == RealtimeEvents.savePrescription || type == 'prescription_created') {
        if (LocalStorageService.isOlderPrescription(data, _data)) return;
        final embedded = LocalStorageService.prescriptionForEmbedding(data);
        if (!LocalStorageService.mayReplacePrescription(embedded, _data)) return;
        final rxList = embedded['prescriptions'] ?? embedded['medicines'];
        if (rxList is List && rxList.isNotEmpty) {
          final before = _data.isNotEmpty ? _rxFingerprint(_getPrescriptionsList()) : null;
          if (mounted) {
            setState(() {
              _data = embedded;
              _gender = _resolveGender();
              _age = _resolveAge();
              // Never flip a dispensed form back to dispensable because a later edit arrived
              // carrying the stale queue entry's status.
              _isDispensed = _isDispensed ||
                  (data['dispenseStatus'] ?? widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
              _isLoadingPrescription = false;
              _flagIfPrescriptionChanged(before);
            });
          }
          return;
        }
      }

      if (type == RealtimeEvents.savePrescription ||
          type == RealtimeEvents.saveEntry ||
          type == 'dispense_completed') {
        _loadPrescription();
      }
    });
  }

  /// Tells the other desks this patient is being dispensed here, so they don't open them too.
  void _claimForThisDesk() {
    final serial = _resolvedSerial;
    if (serial.isEmpty || _isDispensed ||
        (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') {
      return;
    }
    DispenseQueue.listenForClaims();
    DispenseQueue.claim(serial, widget.branchId, deskName: widget.dispenserName);
  }

  @override
  void dispose() {
    _claimRenewal?.cancel();
    DispenseQueue.release(_resolvedSerial, widget.branchId);
    _realtimeSub?.cancel();
    _stockWatch?.cancel();
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
      // The host hands over a fresh map for the same patient on every refresh (prescription
      // re-sent, queue rebuilt). Clearing then left the form empty, and the syringe/needle
      // picks reset, mid-dispense. Start over only for a different patient.
      final oldSerial = (oldWidget.queueEntry['serial'] ?? oldWidget.queueEntry['id'])?.toString();
      final newSerial = (widget.queueEntry['serial'] ?? widget.queueEntry['id'])?.toString();
      if (oldWidget.branchId != widget.branchId || !DispenseQueue.sameSerial(oldSerial, newSerial)) {
        if (oldSerial != null && oldSerial.isNotEmpty) {
          DispenseQueue.release(oldSerial, oldWidget.branchId);
        }
        _data = {};
        _doctorUpdatedLive = false;
        _doctorLiveUpdateSummary = null;
        _selectedSyringeCount = null;
        _selectedSyringeHiveKey = null;
        _selectedNeedleCount = null;
        _isDispensed = (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
        _isDispensing = false;
        _claimForThisDesk();
      }
      _loadPrescription();
    }
  }

  // ─── Prescription loader ──────────────────────────────────────────────────
  Future<void> _loadPrescription() async {
    if (!mounted) return;
    // A refresh keeps what is on screen; the spinner is only for the first load.
    if (_data.isEmpty) setState(() => _isLoadingPrescription = true);
    final beforeFingerprint = _data.isNotEmpty ? _rxFingerprint(_getPrescriptionsList()) : null;
    try {
      // 1. Check embedded prescription from widget.queueEntry, but DO NOT return early before
      // checking Hive: when a doctor edits a prescription (e.g. removes an injection or changes
      // timing), Hive is updated immediately while widget.queueEntry may still hold the older map.
      final directEmbedded = widget.queueEntry['prescription'];
      final directRxList = directEmbedded is Map
          ? (directEmbedded['prescriptions'] ?? directEmbedded['medicines'] ?? directEmbedded['items'])
          : null;
      final directHasMeds = directRxList is List && directRxList.isNotEmpty;
      final directIsVitals = directEmbedded is Map &&
          (directEmbedded['isVitalsOnly'] == true || directEmbedded['vitalsOnly'] == true) &&
          directEmbedded['completedAt'] != null;
      final Map<String, dynamic>? validDirect =
          (directEmbedded is Map && directEmbedded.isNotEmpty && (directHasMeds || directIsVitals))
              ? LocalStorageService.prescriptionForEmbedding(directEmbedded)
              : null;

      String serial = '';
      for (final f in ['serial', 'id', 'tokenSerial', 'tokenId', 'serialNumber']) {
        final v = widget.queueEntry[f]?.toString().trim() ?? '';
        if (v.isNotEmpty) { serial = v; break; }
      }
      final cleanS = CampSessionService.cleanSerial(serial, widget.branchId);

      String cnic = '';
      for (final f in ['patientCnic', 'cnic', 'guardianCnic', 'patientCNIC', 'guardianCNIC']) {
        final v = (widget.queueEntry[f]?.toString() ?? '')
            .trim().replaceAll('-', '').replaceAll(' ', '').toLowerCase();
        if (v.isNotEmpty && v != '0000000000000') { cnic = v; break; }
      }
      Map<String, dynamic> found = {};
      final pId = widget.queueEntry['patientId']?.toString() ?? _data['patientId']?.toString();
      final pDateKey = widget.queueEntry['dateKey']?.toString() ?? _data['dateKey']?.toString();
      found = _searchHive(cleanS, cnic, patientId: pId, dateKey: pDateKey);
      if (cleanS.isNotEmpty) {
        final presc = LocalStorageService.getLocalPrescription(
          cleanS,
          cnic: cnic,
          patientName: widget.queueEntry['patientName'] ?? widget.queueEntry['name'] ?? widget.queueEntry['fullName'],
          patientId: pId,
          branchId: widget.branchId,
          dateKey: pDateKey,
        );
        if (presc != null && presc.isNotEmpty) {
          if (found.isEmpty || LocalStorageService.mayReplacePrescription(presc, found)) {
            found = presc;
          }
        }
      }
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final normB = widget.branchId.toLowerCase().trim();
        final normS = cleanS.toLowerCase();
        final normSUpper = cleanS.toUpperCase();
        final eBox = Hive.box(LocalStorageService.entriesBox);
        final direct = eBox.get('$normB-$normS') ??
            eBox.get('$normB-$normSUpper') ??
            eBox.get(normS) ??
            eBox.get(normSUpper);
        if (direct is Map && direct['prescription'] is Map && (direct['prescription'] as Map).isNotEmpty) {
          final entryRx = Map<String, dynamic>.from(direct['prescription'] as Map);
          if (found.isEmpty || LocalStorageService.mayReplacePrescription(entryRx, found)) {
            found = entryRx;
          }
        }
      }

      if (validDirect != null) {
        if (found.isEmpty) {
          found = validDirect;
        } else {
          final preferred = LocalStorageService.preferredPrescription(found, validDirect);
          if (preferred != null && preferred.isNotEmpty) {
            found = preferred;
          }
        }
      }
      final status = (widget.queueEntry['status'] ?? '').toString().toLowerCase();
      final isPrescribedOrCompleted = status == 'completed' ||
          status == 'dispensed' ||
          (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';

      // Zero-Quota & Offline Guard: Only attempt cloud Firestore fallback if:
      // 1. Record is supposed to have a prescription (completed/dispensed)
      // 2. LAN server is NOT connected (server has full local cache)
      // 3. Device has stable internet
      final bool canAttemptCloud = isPrescribedOrCompleted &&
          !RealtimeManager().isConnected &&
          !ConnectionManager().isConnected &&
          NetworkHealthService().isStableOnline;

      if (found.isEmpty && serial.isNotEmpty && cnic.isNotEmpty && canAttemptCloud) {
        found = await _fetchFromPrescriptionsByCnic(serial, cnic);
        if (found.isNotEmpty) await LocalStorageService.saveLocalPrescription(found);
      }
      if (found.isEmpty && serial.isNotEmpty && canAttemptCloud) {
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
          // Nothing found on a refresh (or only an older copy): keep the prescription shown.
          // Nor a copy without medicines over one that has them (mayReplacePrescription).
          if (found.isNotEmpty && LocalStorageService.mayReplacePrescription(found, _data)) {
            _data = LocalStorageService.prescriptionForEmbedding(found);
          } else if (directEmbedded is Map && _data.isEmpty) {
            _data = LocalStorageService.prescriptionForEmbedding(directEmbedded);
          }
          _gender = _resolveGender();
          _age = _resolveAge();
          _isDispensed = _isDispensed || dispenseStatus == 'dispensed';
          _flagIfPrescriptionChanged(beforeFingerprint);
        });
      }
    } catch (e) {
      debugPrint('[PatientForm] Error loading prescription: $e');
    } finally {
      if (mounted) setState(() => _isLoadingPrescription = false);
    }
  }

  Map<String, dynamic> _searchHive(String serial, String cnic, {String? patientId, String? dateKey}) {
    final cleanS = CampSessionService.cleanSerial(serial, widget.branchId);
    final normSerial = cleanS.trim().toLowerCase();
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
    Map<String, dynamic>? directFallback;
    try {
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final entriesBox = Hive.box(LocalStorageService.entriesBox);
        final directEntry = entriesBox.get('$normBranch-$normSerial') ??
            entriesBox.get('$normBranch-${normSerial.toUpperCase()}') ??
            entriesBox.get(normSerial) ??
            entriesBox.get(normSerial.toUpperCase());
        if (directEntry is Map && directEntry['prescription'] is Map) {
          final emb = LocalStorageService.prescriptionForEmbedding(directEntry['prescription'] as Map);
          emb['doctorName'] ??= directEntry['doctorName'] ?? directEntry['prescribedBy'];
          emb['doctorId'] ??= directEntry['doctorId'];
          emb['prescribedBy'] ??= directEntry['prescribedBy'] ?? directEntry['doctorName'];
          // The token's own list when the embedded copy lost its medicines.
          if (!_hasMeds(emb)) {
            final entryMeds = [directEntry['prescriptions'], directEntry['medicines']]
                .firstWhere((v) => v is List && v.isNotEmpty, orElse: () => null);
            if (entryMeds != null) {
              emb['prescriptions'] = entryMeds;
              emb['medicines'] = entryMeds;
            }
          }
          // A copy without medicines is not returned straight away: the lookup below may
          // still find them ("as if never prescribed" on the dispenser).
          if (emb.isNotEmpty) directFallback = emb;
          if (_hasMeds(emb)) return emb;
        }
      }
    } catch (_) {}

    // 2. Strict validated lookup in local prescriptions
    final presc = LocalStorageService.getLocalPrescription(
      normSerial,
      cnic: normCnic,
      patientName: patientName,
      patientId: patientId,
      branchId: widget.branchId,
      dateKey: dateKey,
    );
    final kept = LocalStorageService.preferredPrescription(presc, directFallback);
    return kept ?? {};
  }

  static bool _hasMeds(Map m) => [m['prescriptions'], m['medicines'], m['items']]
      .any((v) => v is List && v.isNotEmpty);

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
      AppToast.showSnackBar(context, const SnackBar(
          content: Text('Nothing to print'), backgroundColor: SoftPalette.amber300));
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
  static bool _isInjectableType(String? type, [String? name]) {
    final t = (type ?? '').toLowerCase().trim();
    if (t.contains('syringe') || t.contains('nebulization')) return true;
    return PatientFormHelper.isInjectablePrescription(t, name ?? '');
  }

  static bool _isSyrupType(String? type, String? name) {
    final t = (type ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    return t.contains('syrup') || t.contains('syp') || n.contains('syrup') || n.contains('syp');
  }

  /// Resolves the authoritative daily unit count for a prescribed medicine:
  /// - Syrups: always 1 bottle
  /// - Injections: prescribed quantity
  /// - Oral/other medicines with a timing string (e.g. "1+0+0", "1+0+1", "1+1+1"):
  ///   always equals the sum of timing slots so 1-time is strictly 1/day and 2-time is 2/day.
  static int _resolvePerDayQty(Map item, {required bool isInj, required bool isSyrup}) {
    if (isSyrup) return 1;
    final rawQty = item['quantity'] ?? item['qty'] ?? 1;
    final storedQty = rawQty is num
        ? rawQty.toInt()
        : (int.tryParse(rawQty.toString()) ?? 1);
    if (isInj) return storedQty > 0 ? storedQty : 1;

    final timing = (item['timing'] ?? '').toString().trim();
    if (timing.isNotEmpty) {
      final fromTiming = PatientFormHelper.totalPerDay(timing);
      if (fromTiming > 0) return fromTiming;
    }
    return storedQty > 0 ? storedQty : 1;
  }

  static RegExp get _ivWord => PatientFormHelper.ivWord;
  static bool isInjectablePrescription(String type, String name) =>
      PatientFormHelper.isInjectablePrescription(type, name);
  static bool isSyringeStockItem(String type, String name, String category) =>
      PatientFormHelper.isSyringeStockItem(type, name, category);

  int _getAutoSyringeCount(List<dynamic> allPrescriptions) {
    int totalInj = 0;
    for (final med in allPrescriptions) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final type = (medMap['type']?.toString() ?? '').toLowerCase();
      final name = (medMap['name']?.toString() ?? '').toLowerCase();
      final isInjOrDripOrIV = isInjectablePrescription(type, name);
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
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final isInj = _isInjectableType(medMap['type']?.toString(), medMap['name']?.toString());
      final perDay = _resolvePerDayQty(medMap, isInj: isInj, isSyrup: isSyrup).toDouble();
      if (perDay <= 0) continue;
      final multiplier = isSyrup ? 1.0 : (isInj ? 1.0 : days.toDouble());
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
        if (remainingToDeduct > 0 && dedupedBatches.isNotEmpty) {
          final primary = dedupedBatches.first;
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

        // Enqueue offline/server sync for each affected batch (enqueueSync delegates when a LAN client is linked to a LAN server)
        for (final ded in medDeductions) {
          await LocalStorageService.enqueueSync({
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
      } catch (e) {
        debugPrint('[PatientForm] Hive stock decrement failed $rawMedicineId: $e');
      }
    }

    return allDeductedBatches;
  }

  // Build-time copy of the syringe list. Scanning the whole stock box on every
  // setState was costly; it is recomputed only when the stock box changes (or the
  // camp context does). The dispense path still reads fresh stock.
  List<Map<String, dynamic>>? _syringeCache;
  String _syringeCacheKey = '';
  StreamSubscription<BoxEvent>? _stockWatch;

  List<Map<String, dynamic>> _syringeItemsForBuild() {
    final key = '${widget.queueEntry['campId']}|${widget.queueEntry['dispensaryId']}|'
        '${_data['campId']}|${_data['dispensaryId']}|${CampSessionService.getActiveCamp(widget.branchId)}';
    final cached = _syringeCache;
    if (cached != null && key == _syringeCacheKey) return cached;
    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      _stockWatch ??= Hive.box(LocalStorageService.stockBox).watch().listen((_) => _syringeCache = null);
    }
    _syringeCacheKey = key;
    return _syringeCache = _getAvailableSyringeStockItems();
  }

  List<Map<String, dynamic>> _getAvailableSyringeStockItems() {
    if (!Hive.isBoxOpen(LocalStorageService.stockBox)) return [];
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
        final matchesBranch = b.isEmpty || normBranch.isEmpty || normBranch == 'all' ||
            CampSessionService.areBranchesMatching(normBranch, b) ||
            (CampSessionService.isKarachiFamily(normBranch) && CampSessionService.isKarachiFamily(b)) ||
            b == normBranch || b.contains(normBranch) || normBranch.contains(b);
        if (!matchesBranch) {
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
        final category = (m['category'] ?? m['group'] ?? '').toString().toLowerCase();
        final isSyringe = isSyringeStockItem(type, name, category);
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

  Future<List<Map<String, dynamic>>> _deductSyringeIfNeeded(
      String branchId, String serial, List<dynamic> allPrescriptions) async {
    final totalSyringesToDeduct = _getEffectiveSyringeCount(allPrescriptions).toDouble();
    final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString();
    final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();
    final List<Map<String, dynamic>> deducted = [];

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
            syringeMap = Map<String, dynamic>.from(available.first);
          } else {
            for (final key in stockBox.keys) {
              final val = stockBox.get(key);
              if (val is Map) {
                final type = (val['type'] ?? val['dosageForm'] ?? '').toString().toLowerCase();
                final name = (val['name'] ?? '').toString().toLowerCase();
                final category = (val['category'] ?? val['group'] ?? '').toString().toLowerCase();
                final q = val['quantity'] ?? val['stock'] ?? 0;
                final inStock = (q is num ? q.toDouble() : double.tryParse(q.toString()) ?? 0.0) > 0;
                // Same rule as the picker, and never an out-of-stock item (it was picked here
                // and its stock clamped at 0, so the dispensed syringe was never counted).
                if (inStock && isSyringeStockItem(type, name, category)) {
                  syringeKey = key.toString();
                  syringeMap = Map<String, dynamic>.from(val);
                  break;
                }
              }
            }
          }
        }

        if (syringeKey != null && syringeMap != null) {
          syringeMap.remove('hiveKey');
          final q = syringeMap['quantity'] ?? syringeMap['stock'] ?? 0;
          final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          syringeMap['quantity'] = (current - totalSyringesToDeduct).clamp(0.0, double.infinity);
          syringeMap['stock'] = syringeMap['quantity'];
          await stockBox.put(syringeKey, syringeMap);
          final rawSyringeId = (syringeMap['id'] ?? syringeMap['medicineId'] ?? syringeKey.replaceFirst('stock:', '')).toString().trim();
          if (rawSyringeId.isNotEmpty) {
            final peerKey = syringeKey.startsWith('stock:') ? rawSyringeId : 'stock:$rawSyringeId';
            if (stockBox.containsKey(peerKey)) {
              await stockBox.put(peerKey, syringeMap);
            }
          }
          debugPrint('[PatientForm] Auto-deducted $totalSyringesToDeduct Syringe ($syringeKey) from Hive: $current → ${syringeMap['quantity']}');

          final dedInfo = {
            'medicineId': rawSyringeId,
            'name': syringeMap['name'] ?? 'Syringe',
            'delta': -totalSyringesToDeduct,
            'campId': patientCampId,
          };
          deducted.add(dedInfo);

          await LocalStorageService.enqueueSync({
            'type': 'update_inventory',
            'branchId': branchId,
            'medicineId': rawSyringeId,
            'inventoryId': rawSyringeId,
            'delta': -totalSyringesToDeduct,
            'campId': patientCampId,
            'dispensaryId': patientCampId,
            'serial': patientSerial,
          });
        } else {
          debugPrint('[PatientForm] ⚠️ Auto syringe deduction skipped: No syringe item found in stock_items');
          if (mounted) {
            AppToast.showSnackBar(
              context,
              const SnackBar(
                content: Text('⚠️ Injectable prescribed but no syringe stock item found in inventory.'),
                backgroundColor: SoftPalette.amber300,
                duration: Duration(seconds: 4),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('[PatientForm] Error during auto syringe deduction: $e');
      }
    }
    return deducted;
  }

  int _getAutoNeedleCount(List<dynamic> allPrescriptions) {
    int totalInj = 0;
    for (final med in allPrescriptions) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final type = (medMap['type']?.toString() ?? '').toLowerCase();
      final name = (medMap['name']?.toString() ?? '').toLowerCase();
      // Needles: injections and IV only (drips/infusions were never counted here).
      final isInjOrIV = isInjectablePrescription(type, name) &&
          (type.contains('inj') || name.contains('inj') || _ivWord.hasMatch(type) || _ivWord.hasMatch(name));
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

  Future<List<Map<String, dynamic>>> _deductNeedleIfNeeded(
      String branchId, String serial, List<dynamic> allPrescriptions) async {
    final totalNeedlesToDeduct = _getEffectiveNeedleCount(allPrescriptions).toDouble();
    final patientSerial = widget.queueEntry['serial']?.toString() ?? widget.queueEntry['id']?.toString();
    final patientCampId = widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? CampSessionService.getActiveCamp();
    final List<Map<String, dynamic>> deducted = [];

    if (totalNeedlesToDeduct > 0.0) {
      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        final normBranch = branchId.toLowerCase().trim();
        final hasCamps = CampSessionService.hasCampsForBranch(branchId);
        final activeCamp = (patientCampId ?? '').trim();

        final List<Map<String, dynamic>> candidates = [];
        for (final key in stockBox.keys) {
          final val = stockBox.get(key);
          if (val is! Map) continue;
          final m = Map<String, dynamic>.from(val);
          final type = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();
          final name = (m['name'] ?? '').toString().toLowerCase();
          if (!type.contains('needle') && !name.contains('needle')) continue;

          final b = (m['branchId'] ?? '').toString().toLowerCase().trim();
          final matchesBranch = b.isEmpty || normBranch.isEmpty || normBranch == 'all' ||
              CampSessionService.areBranchesMatching(normBranch, b) ||
              (CampSessionService.isKarachiFamily(normBranch) && CampSessionService.isKarachiFamily(b)) ||
              b == normBranch || b.contains(normBranch) || normBranch.contains(b);
          if (!matchesBranch) continue;

          if (hasCamps && activeCamp.isNotEmpty && activeCamp != 'all') {
            final campMatch = CampSessionService.matchesCamp(
              selectedCamp: activeCamp,
              dispensaryId: m['dispensaryId']?.toString(),
              campId: m['campId']?.toString(),
              dispensaryTag: m['dispensaryTag']?.toString(),
              serial: (m['barcode'] ?? m['code'] ?? m['id'] ?? key)?.toString(),
            );
            if (!campMatch) continue;
          }

          m['_hiveKey'] = key.toString();
          candidates.add(m);
        }

        // Sort positive-stock candidates first by FEFO expiry
        candidates.sort((a, b) {
          final qa = (a['quantity'] is num) ? (a['quantity'] as num).toDouble() : (double.tryParse(a['quantity']?.toString() ?? '0') ?? 0.0);
          final qb = (b['quantity'] is num) ? (b['quantity'] as num).toDouble() : (double.tryParse(b['quantity']?.toString() ?? '0') ?? 0.0);
          if ((qa > 0) != (qb > 0)) return qa > 0 ? -1 : 1;
          final expA = MasterProformaService.parseExpiryDate(a['expiryDate'] ?? a['expiry'], (a['id'] ?? a['medicineId'])?.toString());
          final expB = MasterProformaService.parseExpiryDate(b['expiryDate'] ?? b['expiry'], (b['id'] ?? b['medicineId'])?.toString());
          return expA.compareTo(expB);
        });

        String? needleKey;
        Map<String, dynamic>? needleMap;
        if (candidates.isNotEmpty) {
          needleKey = candidates.first['_hiveKey']?.toString();
          needleMap = Map<String, dynamic>.from(candidates.first)..remove('_hiveKey');
        }

        if (needleKey != null && needleMap != null) {
          final q = needleMap['quantity'];
          final current = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
          needleMap['quantity'] = (current - totalNeedlesToDeduct).clamp(0.0, double.infinity);
          needleMap['stock'] = needleMap['quantity'];
          await stockBox.put(needleKey, needleMap);
          final rawNeedleId = (needleMap['id'] ?? needleMap['medicineId'] ?? needleKey.replaceFirst('stock:', '')).toString().trim();
          if (rawNeedleId.isNotEmpty) {
            final peerKey = needleKey.startsWith('stock:') ? rawNeedleId : 'stock:$rawNeedleId';
            if (stockBox.containsKey(peerKey)) {
              await stockBox.put(peerKey, needleMap);
            }
          }
          debugPrint('[PatientForm] Auto-deducted $totalNeedlesToDeduct Needle ($needleKey) from Hive: $current → ${needleMap['quantity']}');

          final dedInfo = {
            'medicineId': rawNeedleId,
            'name': needleMap['name'] ?? 'Needle',
            'delta': -totalNeedlesToDeduct,
            'campId': patientCampId,
          };
          deducted.add(dedInfo);

          await LocalStorageService.enqueueSync({
            'type': 'update_inventory',
            'branchId': branchId,
            'medicineId': rawNeedleId,
            'inventoryId': rawNeedleId,
            'delta': -totalNeedlesToDeduct,
            'campId': patientCampId,
            'dispensaryId': patientCampId,
            'serial': patientSerial,
          });
        } else {
          debugPrint('[PatientForm] ⚠️ Auto needle deduction skipped: No needle item found in stock_items');
        }
      } catch (e) {
        debugPrint('[PatientForm] Error during auto needle deduction: $e');
      }
    }
    return deducted;
  }

  // ─── Dispense ─────────────────────────────────────────────────────────────
  Future<void> _dispenseOnly() async {
    if (_isDispensed || _isDispensing) return;
    final days = _daysOfMedicine;

    // The list the stock check and the dispenser's confirmation are based on. If the doctor's
    // edit lands while the dialogs below are open, we stop instead of dispensing a list the
    // dispenser never reviewed (or deducting stock for a different list than was checked).
    final checkedFingerprint = _rxFingerprint(_getPrescriptionsList());

    final allPrescriptions = _getPrescriptionsList();
    final medicines = allPrescriptions
        .where((m) => m is Map && PatientFormHelper.isInventoryMed(m))
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
      final isSyrup = _isSyrupType(medMap['type']?.toString(), medMap['name']?.toString());
      final isInj = _isInjectableType(medMap['type']?.toString(), medMap['name']?.toString());
      final perDay = _resolvePerDayQty(medMap, isInj: isInj, isSyrup: isSyrup).toDouble();
      if (rawMedicineId.isEmpty || perDay <= 0) continue;
      
      final multiplier = isSyrup ? 1.0 : (isInj ? 1.0 : days.toDouble());
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
              Icon(Icons.warning_amber_rounded, color: SoftPalette.amber300, size: 28),
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
                  child: Text('• $med', style: const TextStyle(fontWeight: FontWeight.bold, color: SoftPalette.red400)),
                )),
                const SizedBox(height: 16),
                Text(
                  'Choose how to handle this patient:\n'
                  '• Put On Hold: Moves patient to On-Hold section so queue can continue.\n'
                  '• Dispense Available: Dispenses remaining stock and proceeds.',
                  style: TextStyle(fontSize: 13, color: ctx.adapt(SoftPalette.gray350)),
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
              icon: const Icon(Icons.pause_circle_outline, color: SoftPalette.gray50, size: 18),
              label: const Text('Put On Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.orange400),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'dispense_available'),
              icon: const Icon(Icons.check_circle_outline, color: SoftPalette.gray50, size: 18),
              label: const Text('Dispense Available'),
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.teal600),
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
              backgroundColor: SoftPalette.orange400,
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
              foregroundColor: SoftPalette.gray50,
            ),
            child: const Text('Dispense'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    if (_doctorUpdatedLive) {
      final reviewed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: SoftPalette.orange400, size: 28),
              SizedBox(width: 10),
              Expanded(child: Text('Prescription Was Modified')),
            ],
          ),
          content: const Text(
            'The doctor updated this prescription while this form was open.\n\nHave you verified that the physical medicines packed match the doctor\'s latest changes?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Review Prescription First'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.green400, foregroundColor: SoftPalette.gray50),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, Dispense Updated'),
            ),
          ],
        ),
      );
      if (reviewed != true || !mounted) return;
      setState(() => _doctorUpdatedLive = false);
    }
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

      // Claims are keyed by the serial as the claiming desk held it (_resolvedSerial, which may
      // carry the branch prefix), so check both spellings.
      final claimedKey = DispenseQueue.isClaimedByOtherDesk(normSerial)
          ? normSerial
          : (DispenseQueue.isClaimedByOtherDesk(rawSerial.trim()) ? rawSerial.trim() : null);
      if (claimedKey != null) {
        final otherDesk = DispenseQueue.claimingDeskName(claimedKey) ?? 'Another Counter';
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Parallel Counter Warning'),
            content: Text('Patient #$normSerial is currently open on $otherDesk.\n\nDo you want to take over and complete this dispense?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.orange400, foregroundColor: SoftPalette.gray50),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Take Over & Dispense'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          setState(() => _isDispensing = false);
          return;
        }
      }

      final serial = normSerial;

      final queueType = _resolvedQueueType;
      final now = DateTime.now();
      // The token's own date (from its serial), not today's: dispensing a night-shift or
      // previous-day token wrote a stub under today's serials document, which inflated today's
      // count while the real token never showed as dispensed.
      final serialDateKey = CampSessionService.getDateKeyFromSerial(serial);
      final dateKey = serialDateKey.length == 6
          ? serialDateKey
          : (widget.queueEntry['dateKey']?.toString().trim().isNotEmpty == true
              ? widget.queueEntry['dateKey'].toString().trim()
              : DateFormat('ddMMyy').format(now));
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

      // Concurrency check: if another counter already dispensed this patient, stop. Only the
      // dispense markers count: status 'completed' is the normal "doctor prescribed, waiting
      // for dispense" state (realtime_router sets it on every save_prescription), so treating
      // it as dispensed blocked every ordinary patient.
      if ((existingEntry?['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' ||
          (existingEntry?['status'] ?? '').toString().toLowerCase() == 'dispensed' ||
          (existingEntry?['dispensedAt'] ?? '').toString().trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _isDispensed = true;
            _isDispensing = false;
          });
          AppToast.showSnackBar(
            context,
            const SnackBar(
              content: Text('⚠️ Patient was already dispensed by another desk! Stock was not deducted twice.'),
              backgroundColor: SoftPalette.orange400,
            ),
          );
        }
        return;
      }

      // The doctor's edit can arrive while the confirm / take-over dialogs were open (or via a
      // sync reload). The stock check and the dispenser's review were for the old list, so stop
      // and make them review the new one. Freeze the list from here on: every await below could
      // otherwise let another edit swap _data between the save and the stock deduction.
      final frozenPrescriptions = List<dynamic>.from(_getPrescriptionsList());
      if (_rxFingerprint(frozenPrescriptions) != checkedFingerprint) {
        if (mounted) {
          setState(() {
            _isDispensing = false;
            _doctorUpdatedLive = true;
            _doctorLiveUpdateSummary =
                'Doctor updated prescription (${frozenPrescriptions.length} items)';
          });
          AppToast.showSnackBar(
            context,
            const SnackBar(
              content: Text('The doctor changed this prescription while you were confirming. '
                  'Nothing was dispensed - review the updated list and dispense again.'),
              backgroundColor: SoftPalette.orange400,
            ),
          );
        }
        return;
      }

      // One counter per token: the LAN server approves this dispense. Each PC's own check
      // above reads only its own copy, so two counters clicking within a second both passed it
      // and both dispensed. Without a server link (or an older server) the local check stands.
      final lock = await RealtimeManager().requestDispenseLock(normSerial, widget.branchId);
      if (lock != null && lock['result'] != 'granted') {
        if (mounted) {
          final already = lock['result'] == 'already_dispensed';
          setState(() {
            _isDispensing = false;
            if (already) _isDispensed = true;
          });
          AppToast.showSnackBar(
            context,
            SnackBar(
              content: Text(already
                  ? 'Patient #$normSerial was already dispensed at another counter. Nothing was deducted.'
                  : 'Patient #$normSerial is being dispensed right now at ${lock['holder'] ?? 'another counter'}. '
                      'Nothing was dispensed here.'),
              backgroundColor: SoftPalette.orange400,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }
      if (!mounted) return;

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

      // The spread above let widget.queueEntry's prescription (the snapshot taken when this
      // patient was opened) replace a newer one the doctor saved since. Keep the newest copy
      // that has medicines, with what this form showed as the fallback.
      final storedRx = LocalStorageService.preferredPrescription(
        widget.queueEntry['prescription'],
        existingEntry?['prescription'],
      );
      final keptRx = LocalStorageService.preferredPrescription(storedRx, _data);
      if (keptRx != null) fullEntry['prescription'] = keptRx;

      await entriesBox.put(canonicalKey, fullEntry);

      final allPrescriptions = frozenPrescriptions;
      final medicines = allPrescriptions
          .where((m) => m is Map && PatientFormHelper.isInventoryMed(m))
          .toList();

      // Deduct stock locally (FEFO batches + syringes + needles) before sending dispense_completed
      // so the LAN Server and peer desks receive the exact deductedBatches.
      final deductedBatches = <Map<String, dynamic>>[];
      try {
        if (medicines.isNotEmpty) {
          deductedBatches.addAll(await _deductInventoryLocally(widget.branchId, normSerial, medicines, days));
        }
        deductedBatches.addAll(await _deductSyringeIfNeeded(widget.branchId, normSerial, allPrescriptions));
        deductedBatches.addAll(await _deductNeedleIfNeeded(widget.branchId, normSerial, allPrescriptions));
      } catch (e) {
        debugPrint('[PatientForm] Local stock deduction warning: $e');
      }

      // Tell the other desks now, right after the local save. It used to go out only after the
      // stock deduction, in the background: a PC closed in between never sent it, and the
      // other desks kept the patient as waiting (open to a second dispense). sendMessage saves
      // it to the outbox first, so it survives a restart. Peers deduct their stock from
      // 'deductedBatches' / 'medicines' once per token, so this is the only dispense message.
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: 'dispense_completed',
          data: {
            'branchId': widget.branchId,
            'serial': normSerial,
            'dateKey': dateKey,
            'daysOfMedicine': days,
            if ((fullEntry['entryUid'] ?? widget.queueEntry['entryUid'] ?? _data['entryUid']) != null)
              'entryUid': (fullEntry['entryUid'] ?? widget.queueEntry['entryUid'] ?? _data['entryUid']),
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

      // 3. Mark UI state complete immediately (Instant feedback)
      if (mounted) {
        setState(() {
          _isDispensed = true;
          _isDispensing = false;
        });
        try {
          AppToast.showSnackBar(context, SnackBar(
              content: Text(days > 1
                  ? 'Dispensed $days-day supply successfully'
                  : 'Dispensed successfully'),
              backgroundColor: SoftPalette.green400));
        } catch (_) {}
      }
      widget.onDispensed?.call();

      // 4. Run Firestore sync asynchronously in background
      unawaited(() async {
        try {
          final upperSerial = serial.trim().toUpperCase();
          final campDocKey = CampSessionService.getCampDateDocId(
            branchId: widget.branchId,
            dateKey: dateKey,
            campId: widget.queueEntry['campId']?.toString() ?? widget.queueEntry['dispensaryId']?.toString() ?? _data['campId']?.toString() ?? _data['dispensaryId']?.toString(),
            dispensaryTag: widget.queueEntry['dispensaryTag']?.toString() ?? _data['dispensaryTag']?.toString(),
            serial: upperSerial,
          );

          // Single-Writer Gateway: Only write directly to Firestore if NOT a LAN client desk.
          // When a LAN client is connected to the LAN server, the server handles cloud sync.
          if (!LanFirestoreGate.isLanDesk) {
            try {
              // Same folded branch id as the uploaders ('grt' → 'gujrat'); the raw id put the
              // dispense in a branch document the dashboard never reads.
              final branchRef = CloudDb.instance
                  .collection('branches').doc(LocalStorageService.sanitizeBranchId(widget.branchId));
              await branchRef.collection('serials').doc(campDocKey)
                  .collection(queueType).doc(upperSerial)
                  .set(minimalUpdate, SetOptions(merge: true));

              try {
                if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                  final eBox = Hive.box(LocalStorageService.entriesBox);
                  final normB = widget.branchId.toLowerCase().trim();
                  final targetKey = '$normB-$upperSerial';
                  final existing = eBox.get(targetKey) ?? eBox.get(upperSerial);
                  if (existing is Map) {
                    final upd = Map<String, dynamic>.from(existing);
                    upd['dispenseSynced'] = true;
                    upd['pendingSync'] = false;
                    upd['synced'] = true;
                    upd['syncStatus'] = 'synced';
                    await eBox.put(targetKey, upd);
                  }
                }
              } catch (_) {}
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
          AppToast.showSnackBar(context, 
              SnackBar(content: Text('Failed to dispense: $e'), backgroundColor: SoftPalette.red400));
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
            color: isDark ? SoftPalette.teal700 : t.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: isDark ? SoftPalette.teal300 : t.accent, size: isMobile ? 15 : 18),
        ),
        const SizedBox(width: 10),
        Text(
          title, 
          style: TextStyle(
            color: isDark ? SoftPalette.slate100 : t.textPrimary,
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
      color = SoftPalette.amber300; // Amber / Orange
    } else if (t.contains('inj') || t.contains('drip') || t.contains('infusion') || n.startsWith('inj')) {
      icon = FontAwesomeIcons.syringe;
      color = SoftPalette.red400; // Crimson / Red
    } else if (t.contains('syp') || t.contains('syrup') || t.contains('susp') || n.startsWith('syp')) {
      icon = FontAwesomeIcons.bottleDroplet;
      color = SoftPalette.emerald350; // Emerald Green
    } else if (t.contains('drop') || n.startsWith('drop')) {
      icon = FontAwesomeIcons.eyeDropper;
      color = SoftPalette.cyan350; // Cyan
    } else if (t.contains('cream') || t.contains('oint') || t.contains('gel')) {
      icon = Icons.sanitizer_rounded;
      color = SoftPalette.pink400; // Pink
    } else if (t.contains('inhal') || t.contains('resp') || n.contains('inhal')) {
      icon = FontAwesomeIcons.lungs;
      color = SoftPalette.violet500; // Purple
    } else if (t.contains('tab') || n.startsWith('tab')) {
      icon = FontAwesomeIcons.tablets;
      color = SoftPalette.blue500; // Blue
    } else {
      icon = Icons.medication_rounded;
      color = SoftPalette.teal500; // Teal
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
    if (isLab || !Hive.isBoxOpen('app_settings')) {
      return _linedListBody(items, t, isLab: isLab, isMobile: isMobile, showUrduTiming: true);
    }
    // User preference (Urdu text vs 1+1+1) applies on every screen and updates live.
    return ValueListenableBuilder<Box>(
      valueListenable: DispensaryPreferencesService.showUrduTimingListenable(),
      builder: (context, box, _) => _linedListBody(
        items,
        t,
        isLab: isLab,
        isMobile: isMobile,
        showUrduTiming: DispensaryPreferencesService.isShowUrduTiming(),
      ),
    );
  }

  Widget _linedListBody(
    List items,
    RoleThemeData t, {
    bool isLab = false,
    bool isMobile = false,
    required bool showUrduTiming,
  }) {
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
        final isInj = _isInjectableType(item['type']?.toString(), item['name']?.toString());
        final isSyrup = _isSyrupType(item['type']?.toString(), item['name']?.toString());
        final isUnclassified = PatientFormHelper.isUnclassifiedMedicine(item);
        final perDayQty = _resolvePerDayQty(item, isInj: isInj, isSyrup: isSyrup);
        final totalQty = isSyrup ? 1 : (isInj ? perDayQty : perDayQty * days);
        
        final formula = (item['formula'] ?? '').toString().trim();
        final isDark = _isDark;
        final fullUrdu = [
          if (urduLine.isNotEmpty) urduLine,
          if (mealUrdu.isNotEmpty) mealUrdu,
        ].join('، ');

        final qtyLabel = isSyrup
            ? '1 Bottle'
            : (isInj
                ? 'Single Dose · qty $perDayQty'
                : (isUnclassified ? 'Unclassified · qty $totalQty' : '$perDayQty/day · qty $totalQty'));

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 12 : 16,
            vertical: isMobile ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RichText(
                                text: TextSpan(
                                  style: TextStyle(
                                    fontFamily: 'Roboto',
                                    color: isDark ? SoftPalette.gray50 : t.textPrimary,
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
                                          color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (formula.isNotEmpty && formula.toLowerCase() != rawName.toLowerCase()) ...[
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.biotech_rounded, size: 12, color: isDark ? SoftPalette.teal300 : t.accent),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        formula,
                                        style: TextStyle(
                                          fontSize: isMobile ? 11 : 12,
                                          fontStyle: FontStyle.italic,
                                          color: isDark ? SoftPalette.teal300 : t.accent,
                                          fontWeight: FontWeight.w500,
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
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    qtyLabel,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                    ),
                  ),
                ],
              ),
              if (showUrduTiming && fullUrdu.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.green700.withValues(alpha: 0.35) : SoftPalette.emerald100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? SoftPalette.green600 : SoftPalette.emerald150),
                  ),
                  child: Text(
                    fullUrdu,
                    textAlign: TextAlign.right,
                    textDirection: ui.TextDirection.rtl,
                    style: TextStyle(
                      fontFamily: 'Jameel Noori Nastaleeq',
                      fontSize: isMobile ? 15 : 17,
                      fontWeight: FontWeight.w700,
                      color: isDark ? SoftPalette.emerald200 : SoftPalette.green600,
                    ),
                  ),
                ),
              ] else if (!showUrduTiming) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.sky700.withValues(alpha: 0.25) : SoftPalette.blue500A10,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? SoftPalette.sky600.withValues(alpha: 0.35) : SoftPalette.blue200),
                  ),
                  child: Text(
                    [
                      PatientFormHelper.buildCompactEnglishTiming(item),
                      if (PatientFormHelper.getMealEnglish(item['meal']?.toString() ?? '').isNotEmpty)
                        '(${PatientFormHelper.getMealEnglish(item['meal']?.toString() ?? '')})',
                    ].join(' '),
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: isMobile ? 13.5 : 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: isDark ? SoftPalette.sky200 : SoftPalette.blue550,
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
            color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Prescribed / paid',
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13.5,
                  fontWeight: FontWeight.w500,
                  color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
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
              color: isDark ? SoftPalette.orange800 : SoftPalette.amber100m,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? SoftPalette.orange400 : SoftPalette.amber300, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.payments_rounded, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'REFUND REQUIRED: Rs. $refundAmt',
                        style: TextStyle(
                          color: isDark ? SoftPalette.amber200 : SoftPalette.orange400,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days.',
                        style: TextStyle(color: isDark ? SoftPalette.yellow150 : SoftPalette.orange400, fontSize: 11),
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
              color: isDark ? SoftPalette.red800 : SoftPalette.pink100m,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? SoftPalette.red400 : SoftPalette.red400, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: isDark ? SoftPalette.red350 : SoftPalette.red550, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'EXTRA PAYMENT NEEDED: Rs. $extraAmt',
                        style: TextStyle(
                          color: isDark ? SoftPalette.red350 : SoftPalette.red550,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                      Text(
                        'Patient paid for $suggested days but got $prescribed days.',
                        style: TextStyle(color: isDark ? SoftPalette.red200 : SoftPalette.red550, fontSize: 11),
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
                color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPhysio ? Icons.spa_rounded : Icons.science_outlined,
                    color: isDark ? SoftPalette.teal300 : t.accent,
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
    final availableSyringes = _syringeItemsForBuild();
    if (_selectedSyringeHiveKey == null && availableSyringes.isNotEmpty) {
      _selectedSyringeHiveKey = availableSyringes.first['hiveKey'];
    }

    return Container(
      margin: EdgeInsets.only(top: isMobile ? 12 : 16),
      padding: EdgeInsets.all(isMobile ? 12 : 16),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.teal700.withValues(alpha: 0.3) : t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.teal300.withValues(alpha: 0.4) : t.accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.teal700 : t.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.vaccines_rounded, color: isDark ? SoftPalette.teal300 : t.accent, size: isMobile ? 22 : 26),
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
                    color: isDark ? SoftPalette.teal300 : t.accent,
                    iconSize: isMobile ? 24 : 28,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? SoftPalette.teal300 : t.accent.withValues(alpha: 0.4)),
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
                    color: isDark ? SoftPalette.teal300 : t.accent,
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
                color: isDark ? SoftPalette.red800 : SoftPalette.pink100m,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? SoftPalette.red550 : SoftPalette.red300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: SoftPalette.red500),
                  const SizedBox(width: 6),
                  Text(
                    'No Syringes in Stock in local inventory',
                    style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.red300 : SoftPalette.red550, fontWeight: FontWeight.w600),
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
                          ? (isDark ? SoftPalette.teal500 : t.accent)
                          : (isDark ? SoftPalette.slate900 : SoftPalette.gray50),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? (isDark ? SoftPalette.teal300 : t.accent)
                            : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
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
                          color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.teal300 : t.accent),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                            fontSize: isMobile ? 12 : 13,
                            color: isSelected ? SoftPalette.gray50 : t.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? SoftPalette.gray50.withValues(alpha: 0.25)
                                : (isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Stock: $stockQty',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.gray50A70 : SoftPalette.gray550),
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
        color: isDark ? SoftPalette.green700.withValues(alpha: 0.3) : SoftPalette.green100m,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.green300.withValues(alpha: 0.4) : SoftPalette.green300),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.green700 : SoftPalette.green200,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.pin_outlined, color: isDark ? SoftPalette.green300 : SoftPalette.green550, size: isMobile ? 22 : 26),
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
                color: isDark ? SoftPalette.green300 : SoftPalette.green550,
                iconSize: isMobile ? 24 : 28,
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? SoftPalette.green300 : SoftPalette.green300),
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
                color: isDark ? SoftPalette.green300 : SoftPalette.green550,
                iconSize: isMobile ? 24 : 28,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Header / footer ──────────────────────────────────────────────────────
  Widget _buildDoctorUpdatedBanner({required bool isMobile}) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.all(isMobile ? 8 : 12),
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: 10),
      decoration: BoxDecoration(
        color: SoftPalette.orange400.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SoftPalette.orange400, width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.notification_important_rounded, color: SoftPalette.orange400, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Prescription Modified by Doctor',
                  style: TextStyle(fontWeight: FontWeight.bold, color: SoftPalette.orange400, fontSize: 13),
                ),
                Text(
                  _doctorLiveUpdateSummary ?? 'Doctor updated medicines while this desk was viewing. Please review before dispensing.',
                  style: TextStyle(color: _isDark ? SoftPalette.slate200 : SoftPalette.gray700, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => setState(() => _doctorUpdatedLive = false),
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.orange400,
              foregroundColor: SoftPalette.gray50,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
              elevation: 0,
            ),
            child: const Text('Review Done', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

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
                    color: SoftPalette.gray50,
                  ),
                ),
                Text(
                  'Gulzar Madina Welfare Foundation',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 16,
                    fontWeight: FontWeight.w900,
                    color: SoftPalette.gray50,
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
                    color: SoftPalette.gray50.withValues(alpha: 0.85),
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
            color: SoftPalette.gray50,
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
        AppToast.showSnackBar(context, 
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
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('📋 WhatsApp opened & PDF copied to clipboard! Press Ctrl+V in WhatsApp to attach.'),
            backgroundColor: SoftPalette.teal600,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Failed to share PDF: $e'), backgroundColor: SoftPalette.red400),
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
        AppToast.showSnackBar(context, 
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Failed to generate report: $e'), backgroundColor: SoftPalette.red400),
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
          color: _isDispensed || _isDispensing ? SoftPalette.gray300 : null,
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                )
              : const Icon(Icons.check_circle, color: SoftPalette.gray50, size: 20),
          label: Text(
            dispenseLabel,
            style: TextStyle(
              fontSize: isMobile ? 12 : 14,
              fontWeight: FontWeight.w800,
              color: SoftPalette.gray50,
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
        color: SoftPalette.red550,
        borderRadius: BorderRadius.circular(27),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.red550.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 5),
          )
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _handleDownloadPdf,
        icon: const Icon(Icons.picture_as_pdf_rounded, color: SoftPalette.gray50, size: 20),
        label: Text(
          'Report',
          style: TextStyle(
            fontSize: isMobile ? 13 : 15,
            fontWeight: FontWeight.w800,
            color: SoftPalette.gray50,
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
      // Solid bar (no BackdropFilter blur): the blur re-rendered on every frame while
      // scrolling/typing, which is costly on the clinics' low-end PCs.
      child: RepaintBoundary(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 16 : 28,
            vertical: isMobile ? 12 : 18,
          ),
          decoration: BoxDecoration(
            color: _isDark ? SoftPalette.slate900 : SoftPalette.gray50,
            border: Border(
              top: BorderSide(color: _isDark ? SoftPalette.slate700 : t.bgRule.withValues(alpha: 0.5), width: 1.5),
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
          color: primaryBp != '—' ? SoftPalette.red500 : (isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
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
          color: primaryWeight != '—' ? SoftPalette.blue550 : (isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
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
          color: primarySugar != '—' ? SoftPalette.teal500 : (isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
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
            color: primaryTemp != '—' ? SoftPalette.orange400 : (isDark ? SoftPalette.gray50A54 : SoftPalette.gray350),
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
        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
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
              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
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
                color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
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

    final inventoryMeds = prescriptions.where((m) => PatientFormHelper.isInventoryMed(m) && !PatientFormHelper.isInjectable(m)).toList();
    final inventoryInjectables = prescriptions.where((m) => PatientFormHelper.isInventoryMed(m) && PatientFormHelper.isInjectable(m)).toList();
    final customMeds = prescriptions.where((m) => !PatientFormHelper.isInventoryMed(m) && !PatientFormHelper.isInjectable(m)).toList();
    final customInjectables = prescriptions.where((m) => !PatientFormHelper.isInventoryMed(m) && PatientFormHelper.isInjectable(m)).toList();
    
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
                  color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
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
                color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
              ),
              child: Text(
                serial,
                style: TextStyle(
                  color: isDark ? SoftPalette.slate200 : SoftPalette.slate600,
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
                  color: isDark ? SoftPalette.slate150 : SoftPalette.slate700,
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
              color: context.adapt(SoftPalette.violet100m),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.adapt(SoftPalette.violet200)),
            ),
            child: Row(
              children: [
                Icon(Icons.health_and_safety_rounded, color: context.adapt(SoftPalette.violet550), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vitals Inspection Token',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: context.adapt(SoftPalette.violet600),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'This patient arrived for vitals inspection only. No medicines are prescribed.',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.adapt(SoftPalette.violet550),
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
      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
            bg:                    SoftPalette.slate900,
            bgCard:                SoftPalette.slate800,
            bgCardAlt:             SoftPalette.slate700,
            bgRule:                SoftPalette.slate600,
            accent:                SoftPalette.teal500,
            accentLight:           SoftPalette.teal350,
            accentMuted:           SoftPalette.teal550,
            accentGradient:        LinearGradient(colors: [SoftPalette.teal550, SoftPalette.teal350]),
            glassTint:             SoftPalette.teal600A20,
            textPrimary:           SoftPalette.gray50,
            textSecondary:         SoftPalette.slate200,
            textTertiary:          SoftPalette.slate350,
            danger:                SoftPalette.red400,
            zakat:                 SoftPalette.green350,
            nonZakat:              SoftPalette.blue500,
            gmwf:                  SoftPalette.orange350,
            cardFillTokens:        SoftPalette.teal550,
            cardFillPrescriptions: SoftPalette.teal600,
            cardFillDispensary:    SoftPalette.teal700,
            chartBar1:             SoftPalette.teal500,
            chartBar2:             SoftPalette.green350,
            chartBar3:             SoftPalette.blue500,
            chartGrid:             SoftPalette.slate700,
          )
        : const RoleThemeData(
            roleLabel:             'CLINICAL',
            bg:                    SoftPalette.teal50t,
            bgCard:                SoftPalette.gray50,
            bgCardAlt:             SoftPalette.teal100m,
            bgRule:                SoftPalette.teal150,
            accent:                SoftPalette.teal600,
            accentLight:           SoftPalette.teal500,
            accentMuted:           SoftPalette.teal100m,
            accentGradient:        LinearGradient(colors: [SoftPalette.teal600, SoftPalette.teal500]),
            glassTint:             SoftPalette.teal600A10,
            textPrimary:           SoftPalette.teal900,
            textSecondary:         SoftPalette.teal700,
            textTertiary:          SoftPalette.teal350,
            danger:                SoftPalette.red550,
            zakat:                 SoftPalette.green550,
            nonZakat:              SoftPalette.blue550,
            gmwf:                  SoftPalette.orange400,
            cardFillTokens:        SoftPalette.teal600,
            cardFillPrescriptions: SoftPalette.teal700,
            cardFillDispensary:    SoftPalette.teal800,
            chartBar1:             SoftPalette.teal600,
            chartBar2:             SoftPalette.green550,
            chartBar3:             SoftPalette.blue550,
            chartGrid:             SoftPalette.teal150,
          );

    if (_isLoadingPrescription) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, 
          children: [
            SizedBox(
              width: widget.isCompactPreview ? 24 : 36,
              height: widget.isCompactPreview ? 24 : 36,
              child: CircularProgressIndicator(color: t.accent, strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text('Loading prescription...', style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: widget.isCompactPreview ? 12 : 14)),
          ],
        ),
      );
    }
    if (_data.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.hourglass_empty, size: widget.isCompactPreview ? 44 : 80, color: isDark ? SoftPalette.slate350 : SoftPalette.gray350),
        const SizedBox(height: 12),
        Text('No prescription found yet',
            style: TextStyle(color: isDark ? SoftPalette.slate200 : SoftPalette.gray350, fontSize: widget.isCompactPreview ? 13 : 18)),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _loadPrescription, icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: SoftPalette.gray50,
            visualDensity: widget.isCompactPreview ? VisualDensity.compact : VisualDensity.standard,
          )),
      ]));
    }

    if (widget.isCompactPreview) {
      return _buildCompactPreview(t, isDark: isDark);
    }

    final bottomBarHeight = 76.0;
    return Scaffold(
      backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
      body: Stack(children: [
        SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(
              left: isMobile ? 6 : 12, right: isMobile ? 6 : 12,
              top: isMobile ? 6 : 12, bottom: bottomBarHeight + 36),
          child: Center(child: Container(
            constraints: isMobile ? const BoxConstraints() : const BoxConstraints(maxWidth: 950),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
              borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
              border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
              boxShadow: [
                BoxShadow(
                  color: isDark ? SoftPalette.gray900A26 : SoftPalette.gray900.withValues(alpha: 0.04), 
                  blurRadius: 10, 
                  offset: const Offset(0, 4),
                )
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              if (_doctorUpdatedLive) _buildDoctorUpdatedBanner(isMobile: isMobile),
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

  // ─── Compact Preview Layout for All-In-One Desk ─────────────────────────────
  Widget _buildCompactPreview(RoleThemeData t, {required bool isDark}) {
    final prescriptions = _getPrescriptionsList();
    final labTests = _getLabResultsList();
    final diagnosis = _getDiagnosisText();
    final rawVitals = widget.queueEntry['vitals'] ?? _data['vitals'];
    final vitals = (rawVitals is Map) ? Map<String, dynamic>.from(rawVitals) : <String, dynamic>{};
    final isVitalsOnly = widget.queueEntry['isVitalsOnly'] == true ||
        widget.queueEntry['vitalsOnly'] == true ||
        _data['isVitalsOnly'] == true ||
        _data['vitalsOnly'] == true;

    final inventoryMeds = prescriptions.where((m) => PatientFormHelper.isInventoryMed(m) && !PatientFormHelper.isInjectable(m)).toList();
    final inventoryInjectables = prescriptions.where((m) => PatientFormHelper.isInventoryMed(m) && PatientFormHelper.isInjectable(m)).toList();
    final customMeds = prescriptions.where((m) => !PatientFormHelper.isInventoryMed(m) && !PatientFormHelper.isInjectable(m)).toList();
    final customInjectables = prescriptions.where((m) => !PatientFormHelper.isInventoryMed(m) && PatientFormHelper.isInjectable(m)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_doctorUpdatedLive) _buildDoctorUpdatedBanner(isMobile: true),
                _buildCompactPatientAndVitalsHeader(vitals, t, isDark, isVitalsOnly),
                _buildCompactDurationAndDiagnosis(labTests, diagnosis, t, isDark),
                if (inventoryMeds.isNotEmpty) ...[
                  _buildCompactSectionTitle('Inventory Medicines', inventoryMeds.length, Icons.medication_rounded, t, isDark),
                  _buildCompactMedicinesList(inventoryMeds, t, isDark),
                ],
                if (inventoryInjectables.isNotEmpty) ...[
                  _buildCompactSectionTitle('Inventory Injectables', inventoryInjectables.length, Icons.vaccines_rounded, t, isDark),
                  _buildCompactMedicinesList(inventoryInjectables, t, isDark),
                ],
                if (customMeds.isNotEmpty) ...[
                  _buildCompactSectionTitle('Custom Medicines', customMeds.length, Icons.medication_liquid_rounded, t, isDark),
                  _buildCompactMedicinesList(customMeds, t, isDark),
                ],
                if (customInjectables.isNotEmpty) ...[
                  _buildCompactSectionTitle('Custom Injectables', customInjectables.length, Icons.vaccines_rounded, t, isDark),
                  _buildCompactMedicinesList(customInjectables, t, isDark),
                ],
                if (inventoryInjectables.isNotEmpty || customInjectables.isNotEmpty) ...[
                  _buildSyringeSelectionCard(prescriptions, t, isMobile: true),
                  _buildNeedleSelectionCard(prescriptions, t, isMobile: true),
                ],
                if (prescriptions.isEmpty && !isVitalsOnly)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded, size: 17, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No medicines prescribed for this visit.',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        _buildCompactActionBar(t, isDark),
      ],
    );
  }

  Widget _buildCompactPatientAndVitalsHeader(
    Map<String, dynamic> vitals,
    RoleThemeData t,
    bool isDark,
    bool isVitalsOnly,
  ) {
    final patientName = _getResolvedPatientName();
    final cnic = _getResolvedCnic();
    final genderStr = _resolveGender();
    final ageVal = _resolveAge();
    final ageDisplay = ageVal != 'N/A' ? '$ageVal yrs' : '';
    final genderAgeText = [if (genderStr != 'N/A') genderStr, if (ageDisplay.isNotEmpty) ageDisplay].join(', ');
    final phone = _getPatientPhone();
    final queueType = _resolvedQueueType;

    Color qColor;
    Color qBg;
    String qLabel;
    if (queueType == 'gmwf') {
      qColor = SoftPalette.orange400;
      qBg = SoftPalette.orange100m;
      qLabel = 'GMWF';
    } else if (queueType == 'non-zakat') {
      qColor = SoftPalette.blue550;
      qBg = SoftPalette.blue500A10;
      qLabel = 'Non-Zakat';
    } else {
      qColor = SoftPalette.green550;
      qBg = SoftPalette.green100m;
      qLabel = 'Zakat';
    }

    // Vitals extraction:
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

    final docBp = cleanVal(docVitals['bp'] ?? (hasDocUpdate ? vitals['bp'] : null));
    final recBp = cleanVal(recVitals['bp'] ?? (!hasDocUpdate ? vitals['bp'] : null));
    final primaryBp = docBp.isNotEmpty ? docBp : (recBp.isNotEmpty ? recBp : '—');
    final subBp = (hasDocUpdate && recBp.isNotEmpty && recBp != docBp) ? 'Rec: $recBp' : null;

    final docWeightRaw = cleanVal(docVitals['weight'] ?? (hasDocUpdate ? vitals['weight'] : null));
    final recWeightRaw = cleanVal(recVitals['weight'] ?? (!hasDocUpdate ? vitals['weight'] : null));
    final primaryWeight = docWeightRaw.isNotEmpty ? '$docWeightRaw kg' : (recWeightRaw.isNotEmpty ? '$recWeightRaw kg' : '—');
    final subWeight = (hasDocUpdate && recWeightRaw.isNotEmpty && recWeightRaw != docWeightRaw) ? 'Rec: $recWeightRaw kg' : null;

    final docSugarRaw = cleanVal(docVitals['sugar'] ?? (hasDocUpdate ? vitals['sugar'] : null));
    final recSugarRaw = cleanVal(recVitals['sugar'] ?? (!hasDocUpdate ? vitals['sugar'] : null));
    final primarySugar = docSugarRaw.isNotEmpty ? '$docSugarRaw mg/dL' : (recSugarRaw.isNotEmpty ? '$recSugarRaw mg/dL' : '—');
    final subSugar = (hasDocUpdate && recSugarRaw.isNotEmpty && recSugarRaw != docSugarRaw) ? 'Rec: $recSugarRaw' : null;

    final docTempRaw = cleanVal(docVitals['temp'] ?? (hasDocUpdate ? vitals['temp'] : null));
    final recTempRaw = cleanVal(recVitals['temp'] ?? (!hasDocUpdate ? vitals['temp'] : null));
    final primaryTemp = docTempRaw.isNotEmpty ? '$docTempRaw °C' : (recTempRaw.isNotEmpty ? '$recTempRaw °C' : '—');
    final subTemp = (hasDocUpdate && recTempRaw.isNotEmpty && recTempRaw != docTempRaw) ? 'Rec: $recTempRaw °C' : null;

    Widget vitalCell({
      required String label,
      required String value,
      String? subValue,
      required Color color,
      required IconData icon,
    }) {
      final hasVal = value != '—';
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate700.withValues(alpha: 0.5) : SoftPalette.gray100,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isDark ? SoftPalette.slate600 : SoftPalette.slate150),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: hasVal ? color : (isDark ? SoftPalette.slate400 : SoftPalette.gray350),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Left Side: Patient Details ──
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: isDark ? SoftPalette.teal700 : SoftPalette.teal100m,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              Icons.person_rounded,
                              size: 15,
                              color: isDark ? SoftPalette.teal200 : SoftPalette.teal600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            patientName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: t.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isDark ? qColor.withValues(alpha: 0.2) : qBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: qColor.withValues(alpha: isDark ? 0.45 : 0.3)),
                          ),
                          child: Text(
                            qLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: qColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CNIC $cnic',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                      ),
                    ),
                    const SizedBox(height: 2.5),
                    Row(
                      children: [
                        if (genderAgeText.isNotEmpty)
                          Text(
                            genderAgeText,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                            ),
                          ),
                        if (phone != null && phone.isNotEmpty) ...[
                          Text(
                            ' · ',
                            style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                          ),
                          Expanded(
                            child: Text(
                              phone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),
              Container(
                width: 1,
                height: 56,
                color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
              ),
              const SizedBox(width: 8),

              // ── Right Side: Vitals 2x2 Grid ──
              SizedBox(
                width: 205,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        vitalCell(
                          label: 'BP',
                          value: primaryBp,
                          subValue: subBp,
                          color: SoftPalette.red500,
                          icon: Icons.favorite_rounded,
                        ),
                        const SizedBox(width: 4),
                        vitalCell(
                          label: 'Temp',
                          value: primaryTemp,
                          subValue: subTemp,
                          color: SoftPalette.orange400,
                          icon: Icons.thermostat_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        vitalCell(
                          label: 'Wt',
                          value: primaryWeight,
                          subValue: subWeight,
                          color: SoftPalette.blue550,
                          icon: Icons.scale_rounded,
                        ),
                        const SizedBox(width: 4),
                        vitalCell(
                          label: 'Sugar',
                          value: primarySugar,
                          subValue: subSugar,
                          color: SoftPalette.teal500,
                          icon: Icons.water_drop_rounded,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (isVitalsOnly) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
              decoration: BoxDecoration(
                color: context.adapt(SoftPalette.violet100m),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: context.adapt(SoftPalette.violet200)),
              ),
              child: Row(
                children: [
                  Icon(Icons.health_and_safety_rounded, color: context.adapt(SoftPalette.violet550), size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Vitals Inspection Token · No medicines prescribed',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: context.adapt(SoftPalette.violet600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactDurationAndDiagnosis(
    List labTests,
    String diagnosis,
    RoleThemeData t,
    bool isDark,
  ) {
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

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 13, color: isDark ? SoftPalette.teal300 : t.accent),
              const SizedBox(width: 5),
              Text(
                'Duration: $prescribed / $suggested d',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: t.textPrimary,
                ),
              ),
              if (refundAmt > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.orange800 : SoftPalette.amber100m,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: isDark ? SoftPalette.orange400 : SoftPalette.amber300),
                  ),
                  child: Text(
                    'Refund: Rs. $refundAmt',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400),
                  ),
                ),
              ] else if (extraAmt > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.red800 : SoftPalette.pink100m,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: isDark ? SoftPalette.red400 : SoftPalette.red400),
                  ),
                  child: Text(
                    'Due: Rs. $extraAmt',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.red350 : SoftPalette.red550),
                  ),
                ),
              ],
              if (diagnosis.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(width: 1, height: 14, color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                const SizedBox(width: 8),
                Icon(Icons.medical_services_outlined, size: 13, color: isDark ? SoftPalette.teal300 : t.accent),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Diag: $diagnosis',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: t.textPrimary,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
          if (labTests.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: labTests.map((item) {
                final name = item['name']?.toString() ?? 'Test';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.teal700.withValues(alpha: 0.3) : SoftPalette.teal100m,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: isDark ? SoftPalette.teal600 : SoftPalette.teal200),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isPhysio ? Icons.spa_rounded : Icons.science_outlined, size: 11, color: isDark ? SoftPalette.teal300 : t.accent),
                      const SizedBox(width: 4),
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 11,
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
        ],
      ),
    );
  }

  Widget _buildCompactSectionTitle(String title, int count, IconData icon, RoleThemeData t, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 9, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: isDark ? SoftPalette.teal300 : t.accent),
          const SizedBox(width: 5),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: isDark ? SoftPalette.slate300 : SoftPalette.slate700,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isDark ? SoftPalette.teal700 : SoftPalette.teal100m,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
                ),
              ),
            ),
          ],
          const SizedBox(width: 7),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 0.8,
              color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMedTypeIconBadge(String? type, String? name, bool isDark) {
    final t = (type ?? '').toLowerCase().trim();
    final n = (name ?? '').toLowerCase().trim();

    IconData icon;
    Color color;
    if (t.contains('cap') || n.startsWith('cap')) {
      icon = FontAwesomeIcons.capsules;
      color = SoftPalette.amber300;
    } else if (t.contains('inj') || t.contains('drip') || t.contains('infusion') || n.startsWith('inj')) {
      icon = FontAwesomeIcons.syringe;
      color = SoftPalette.red400;
    } else if (t.contains('syp') || t.contains('syrup') || t.contains('susp') || n.startsWith('syp')) {
      icon = FontAwesomeIcons.bottleDroplet;
      color = SoftPalette.emerald350;
    } else if (t.contains('drop') || n.startsWith('drop')) {
      icon = FontAwesomeIcons.eyeDropper;
      color = SoftPalette.cyan350;
    } else if (t.contains('cream') || t.contains('oint') || t.contains('gel')) {
      icon = Icons.sanitizer_rounded;
      color = SoftPalette.pink400;
    } else if (t.contains('inhal') || t.contains('resp') || n.contains('inhal')) {
      icon = FontAwesomeIcons.lungs;
      color = SoftPalette.violet500;
    } else if (t.contains('tab') || n.startsWith('tab')) {
      icon = FontAwesomeIcons.tablets;
      color = SoftPalette.blue500;
    } else {
      icon = Icons.medication_rounded;
      color = SoftPalette.teal500;
    }

    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.45 : 0.28), width: 0.8),
      ),
      child: Center(
        child: Icon(icon, size: 11.5, color: color),
      ),
    );
  }

  Widget _buildCompactMedicinesList(List items, RoleThemeData t, bool isDark) {
    if (items.isEmpty) return const SizedBox.shrink();
    final days = _daysOfMedicine;

    if (!Hive.isBoxOpen('app_settings')) {
      return _buildCompactMedicinesColumn(items, t, isDark, days, true);
    }

    return ValueListenableBuilder<Box>(
      valueListenable: DispensaryPreferencesService.showUrduTimingListenable(),
      builder: (context, box, _) {
        final bool showUrduTiming = DispensaryPreferencesService.isShowUrduTiming();
        return _buildCompactMedicinesColumn(items, t, isDark, days, showUrduTiming);
      },
    );
  }

  Widget _buildCompactMedicinesColumn(
    List items,
    RoleThemeData t,
    bool isDark,
    int days,
    bool showUrduTiming,
  ) {
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
            final isInj = _isInjectableType(item['type']?.toString());
            final isSyrup = _isSyrupType(item['type']?.toString(), item['name']?.toString());
            final qRaw = item['quantity'] ?? item['qty'] ?? 1;
            final perDayQty = (qRaw is num) ? qRaw.toInt() : (int.tryParse(qRaw.toString()) ?? 1);
            final totalQty = isSyrup ? 1 : (isInj ? perDayQty : perDayQty * days);
            final formula = (item['formula'] ?? '').toString().trim();

            // ── Dosage Timing Construction ──
            final timing = item['timing']?.toString() ?? '';
            final parts = PatientFormHelper.parseTiming(timing);
            final rawMeal = (item['meal'] ?? '').toString().trim();
            final mealLower = rawMeal.toLowerCase();

            // Proper full Urdu meal text (کھانے کے بعد / کھانے سے پہلے / نہار منہ / سونے سے پہلے)
            String mealUrdu = '';
            if (mealLower.contains('after') || mealLower.contains('بعد')) {
              mealUrdu = 'کھانے کے بعد';
            } else if (mealLower.contains('before sleep') || mealLower.contains('سونے') || mealLower.contains('سوتے') || mealLower.contains('bedtime')) {
              mealUrdu = 'سونے سے پہلے';
            } else if (mealLower.contains('before') || mealLower.contains('پہلے')) {
              mealUrdu = 'کھانے سے پہلے';
            } else if (mealLower.contains('empty') || mealLower.contains('خالی') || mealLower.contains('نہار')) {
              mealUrdu = 'نہار منہ';
            } else if (mealLower.contains('during') || mealLower.contains('دوران') || mealLower.contains('with meal')) {
              mealUrdu = 'کھانے کے دوران';
            } else if (rawMeal.isNotEmpty) {
              mealUrdu = rawMeal;
            }

            // Proper full English meal text (After Meal / Before Meal / Empty Stomach / Bedtime)
            String mealEnglish = '';
            if (mealLower.contains('after') || mealLower.contains('بعد')) {
              mealEnglish = 'After Meal';
            } else if (mealLower.contains('before sleep') || mealLower.contains('سونے') || mealLower.contains('سوتے') || mealLower.contains('bedtime')) {
              mealEnglish = 'Bedtime';
            } else if (mealLower.contains('before') || mealLower.contains('پہلے')) {
              mealEnglish = 'Before Meal';
            } else if (mealLower.contains('empty') || mealLower.contains('خالی') || mealLower.contains('نہار')) {
              mealEnglish = 'Empty Stomach';
            } else if (mealLower.contains('during') || mealLower.contains('دوران') || mealLower.contains('with meal')) {
              mealEnglish = 'With Meal';
            } else if (rawMeal.isNotEmpty) {
              mealEnglish = rawMeal;
            }

            // 1. Urdu text format
            String timingUrdu = '';
            if (isInj) {
              timingUrdu = 'ایک خوراک';
            } else if (parts[0] > 0 || parts[1] > 0 || parts[2] > 0 || (parts.length > 3 && parts[3] > 0)) {
              List<String> times = [];
              if (parts[0] > 0) times.add('${parts[0]} صبح');
              if (parts[1] > 0) times.add('${parts[1]} دوپہر');
              if (parts[2] > 0) times.add('${parts[2]} شام');
              if (parts.length > 3 && parts[3] > 0) times.add('${parts[3]} رات');
              timingUrdu = times.join(' • ');
            } else {
              timingUrdu = PatientFormHelper.buildUrduDosageLine(item);
            }

            final compactUrdu = [
              if (timingUrdu.isNotEmpty) timingUrdu,
              if (mealUrdu.isNotEmpty) '($mealUrdu)',
            ].join(' ');

            // 2. Compact 1+1+1 English format
            String numericTiming = '';
            if (isInj) {
              numericTiming = 'Single Dose';
            } else if (parts[0] > 0 || parts[1] > 0 || parts[2] > 0 || (parts.length > 3 && parts[3] > 0)) {
              final activeParts = parts.length > 3 && parts[3] > 0 ? parts.sublist(0, 4) : parts.sublist(0, 3);
              numericTiming = activeParts.join('+');
            } else if (timing.isNotEmpty) {
              numericTiming = timing;
            } else {
              numericTiming = '$perDayQty/day';
            }

            final compactEnglish = [
              numericTiming,
              if (mealEnglish.isNotEmpty) '($mealEnglish)',
            ].join(' ');

            // Full instructions for tooltips
            final fullUrdu = [
              if (PatientFormHelper.buildUrduDosageLine(item).isNotEmpty)
                PatientFormHelper.buildUrduDosageLine(item)
              else if (timingUrdu.isNotEmpty)
                timingUrdu,
              if (mealUrdu.isNotEmpty) '($mealUrdu)',
            ].join(' ');

            List<String> engTimes = [];
            if (parts[0] > 0) engTimes.add('${parts[0]} Morning');
            if (parts[1] > 0) engTimes.add('${parts[1]} Noon');
            if (parts[2] > 0) engTimes.add('${parts[2]} Night');
            if (parts.length > 3 && parts[3] > 0) engTimes.add('${parts[3]} Bedtime');
            final fullEnglish = isInj
                ? 'Single Dose'
                : [
                    if (engTimes.isNotEmpty) engTimes.join(', ') else numericTiming,
                    if (mealEnglish.isNotEmpty) '($mealEnglish)',
                  ].join(' ');

            final qtyLabel = isSyrup ? '1 Btl' : (isInj ? 'QTY $perDayQty' : 'QTY $totalQty');

            final tooltipLines = [
              displayName,
              if (dose.isNotEmpty) 'Dose: $dose',
              if (formula.isNotEmpty && formula.toLowerCase() != rawName.toLowerCase()) 'Formula: $formula',
              if (showUrduTiming) ...[
                if (fullUrdu.isNotEmpty) 'Instructions: $fullUrdu' else if (compactUrdu.isNotEmpty) 'Instructions: $compactUrdu',
              ] else ...[
                if (fullEnglish.isNotEmpty) 'Instructions: $fullEnglish' else if (compactEnglish.isNotEmpty) 'Instructions: $compactEnglish',
              ],
              if (!isSyrup && !isInj) '$perDayQty/day × $days days = $totalQty total' else 'Total: $qtyLabel',
            ];

            final hasTimingBadge = showUrduTiming ? compactUrdu.isNotEmpty : compactEnglish.isNotEmpty;

            return Tooltip(
              message: tooltipLines.join('\n'),
              waitDuration: const Duration(milliseconds: 300),
              child: Container(
                margin: const EdgeInsets.only(bottom: 3.5),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 1. Medicine Type Icon Badge
                    _buildCompactMedTypeIconBadge(item['type']?.toString(), item['name']?.toString(), isDark),
                    const SizedBox(width: 6),

                    // 2. Medicine Title & Strength
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: TextStyle(
                            fontFamily: 'Roboto',
                            color: isDark ? SoftPalette.gray50 : t.textPrimary,
                            fontSize: 12.5,
                          ),
                          children: [
                            TextSpan(
                              text: displayName,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            if (dose.isNotEmpty) ...[
                              const TextSpan(text: ' '),
                              TextSpan(
                                text: dose,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11.5,
                                  color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                                ),
                              ),
                            ],
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),

                    // 3. Timing / Instruction Badge (Urdu text or 1+1+1 English format)
                    if (hasTimingBadge) ...[
                      Container(
                        constraints: const BoxConstraints(maxWidth: 240),
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: showUrduTiming ? 1.5 : 2.5),
                        decoration: BoxDecoration(
                          color: showUrduTiming
                              ? (isDark ? SoftPalette.green700.withValues(alpha: 0.22) : SoftPalette.emerald100)
                              : (isDark ? SoftPalette.sky700.withValues(alpha: 0.25) : SoftPalette.blue500A10),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: showUrduTiming
                                ? (isDark ? SoftPalette.green600.withValues(alpha: 0.3) : SoftPalette.emerald200)
                                : (isDark ? SoftPalette.sky600.withValues(alpha: 0.35) : SoftPalette.blue200),
                            width: 0.8,
                          ),
                        ),
                        child: showUrduTiming
                            ? Text(
                                compactUrdu,
                                textAlign: TextAlign.center,
                                textDirection: ui.TextDirection.rtl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Jameel Noori Nastaleeq',
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? SoftPalette.emerald200 : SoftPalette.green600,
                                ),
                              )
                            : Text(
                                compactEnglish,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Roboto',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.3,
                                  color: isDark ? SoftPalette.sky200 : SoftPalette.blue550,
                                ),
                              ),
                      ),
                      const SizedBox(width: 6),
                    ],

                    // 4. Quantity Badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.teal700.withValues(alpha: 0.3) : SoftPalette.teal100m,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isDark ? SoftPalette.teal600.withValues(alpha: 0.4) : SoftPalette.teal200,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        qtyLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: isDark ? SoftPalette.teal200 : SoftPalette.teal700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
  }

  Widget _buildCompactActionBar(RoleThemeData t, bool isDark) {
    final days = _daysOfMedicine;

    final dispenseLabel = _isDispensed
        ? 'Dispensed'
        : _isDispensing
            ? 'Dispensing...'
            : days > 1
                ? 'Dispense ($days days)'
                : 'Dispense Medicine';

    final dispenseBtn = Container(
      height: 42,
      decoration: BoxDecoration(
        gradient: !_isDispensed && !_isDispensing ? t.accentGradient : null,
        color: _isDispensed || _isDispensing ? SoftPalette.gray300 : null,
        borderRadius: BorderRadius.circular(21),
        boxShadow: _isDispensed || _isDispensing
            ? []
            : [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                )
              ],
      ),
      child: ElevatedButton.icon(
        onPressed: _isDispensed || _isDispensing ? null : _dispenseOnly,
        icon: _isDispensing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
              )
            : const Icon(Icons.check_circle, color: SoftPalette.gray50, size: 18),
        label: Text(
          dispenseLabel,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SoftPalette.gray50,
            letterSpacing: 0.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(21)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );

    final reportBtn = Container(
      height: 42,
      decoration: BoxDecoration(
        color: SoftPalette.red550,
        borderRadius: BorderRadius.circular(21),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.red550.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _handleDownloadPdf,
        icon: const Icon(Icons.picture_as_pdf_rounded, color: SoftPalette.gray50, size: 17),
        label: const Text(
          'Report',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SoftPalette.gray50,
            letterSpacing: 0.3,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(21)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );

    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          border: Border(
            top: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200, width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(flex: 6, child: dispenseBtn),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: reportBtn),
          ],
        ),
      ),
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Print failed: $e'), backgroundColor: SoftPalette.red400),
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('Save PDF failed: $e'), backgroundColor: SoftPalette.red400),
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
        AppToast.showSnackBar(context, 
          SnackBar(content: Text('WhatsApp share failed: $e'), backgroundColor: SoftPalette.red400),
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
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('📋 WhatsApp opened & PDF copied to clipboard! Press Ctrl+V in WhatsApp to attach.'),
            backgroundColor: SoftPalette.teal600,
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
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: context.adapt(SoftPalette.teal350),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: context.adapt(SoftPalette.teal900),
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
      decoration: BoxDecoration(
        color: context.adapt(SoftPalette.gray50),
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
                  color: context.adapt(SoftPalette.gray100),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Image.asset('assets/logo/gmwf-1.webp', height: 36, errorBuilder: (_, __, ___) => const Icon(Icons.medical_services, color: SoftPalette.teal600)),
                  Text(
                    'Print & Share Slip',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: context.adapt(SoftPalette.teal900),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: context.adapt(SoftPalette.gray350)),
                    style: IconButton.styleFrom(backgroundColor: context.adapt(SoftPalette.gray100)),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Patient Info Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.adapt(SoftPalette.teal100m),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.adapt(SoftPalette.teal150)),
                ),
                child: Column(
                  children: [
                    Text(
                      (widget.data['patientName'] ?? 'Unknown Patient').toString().toUpperCase(), 
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: context.adapt(SoftPalette.teal600),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _infoSummary('Serial Token', '#${widget.serial}'),
                        Container(width: 1, height: 24, color: context.adapt(SoftPalette.teal150)),
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
                  color: context.adapt(SoftPalette.gray50),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: context.adapt(SoftPalette.gray100)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _premiumPrintBtn(
                      label: 'Print Slip',
                      color: context.adapt(SoftPalette.teal600),
                      icon: Icons.print_rounded,
                      onTap: _handlePrint,
                    ),
                    _premiumPrintBtn(
                      label: 'Save PDF',
                      color: context.adapt(SoftPalette.red550),
                      icon: Icons.picture_as_pdf_rounded,
                      onTap: _handleSavePdf,
                    ),
                    _premiumPrintBtn(
                      label: 'WhatsApp',
                      color: context.adapt(SoftPalette.green550),
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
                color: context.adapt(SoftPalette.gray50).withOpacity(0.9),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: SoftPalette.teal600),
                      const SizedBox(height: 16),
                      Text(
                        _loadingMessage,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: context.adapt(SoftPalette.teal900),
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
