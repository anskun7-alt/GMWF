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
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/dispensary_preferences_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_movement.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
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
import 'package:gmwf/utils/branch_labels.dart';
import '../widgets/medicine_icon_badge.dart';
import '../widgets/desk_theme.dart';
import '../doctor/patient_info.dart';

class PatientForm extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> queueEntry;
  final VoidCallback? onDispensed;
  final ValueChanged<bool>? onDispenseBusyChanged;
  final String? dispenserName;
  final bool isCompactPreview;
  const PatientForm({
    super.key,
    required this.branchId,
    required this.queueEntry,
    this.onDispensed,
    this.onDispenseBusyChanged,
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
  bool _dispenseFlowActive = false;
  bool _loadingBranch = true;
  bool _isLoadingPrescription = true;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  int? _selectedSyringeCount;
  String? _selectedSyringeHiveKey;
  int? _selectedNeedleCount;
  Timer? _claimRenewal;
  bool _doctorUpdatedLive = false;
  String? _doctorLiveUpdateSummary;

  bool get _isKarachi => BranchLabels.isKarachiBranch(widget.branchId);

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

      if (type == RealtimeEvents.savePatient ||
          type == 'save_patient' ||
          type == 'migrate_patient_key' ||
          type == 'patient_edit_approved') {
        _loadPrescription();
        return;
      }

      // Only this patient's events. One without a serial used to pass this check, so another
      // patient's prescription was shown here (or the form reloaded and came up empty).
      if (eventSerial.isEmpty || mySerial.isEmpty ||
          !CampSessionService.isSameSerial(eventSerial, mySerial, myBranch)) return;

      // When prescription arrives from doctor for this active patient, apply immediately!
      if (type == RealtimeEvents.savePrescription || type == 'prescription_created') {
        if (LocalStorageService.isOlderPrescription(data, _data)) return;
        // Not this token's prescription (same number, earlier token or another patient).
        if (!_isDispensed && !LocalStorageService.prescriptionFitsToken(data, widget.queueEntry)) return;
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
    if (_dispenseFlowActive) {
      _dispenseFlowActive = false;
      widget.onDispenseBusyChanged?.call(false);
    }
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
    // Only a prescription the doctor wrote for THIS token is shown. One stored under the same
    // token number (an earlier token, or another patient) showed medicines before the doctor
    // had prescribed anything.
    final token = widget.queueEntry;
    final alreadyDispensed = _isDispensed ||
        (token['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
    bool fits(Object? rx) => rx is Map && rx.isNotEmpty &&
        (alreadyDispensed || LocalStorageService.prescriptionFitsToken(rx, token));
    try {
      // 1. Check embedded prescription from widget.queueEntry, but DO NOT return early before
      // checking Hive: when a doctor edits a prescription (e.g. removes an injection or changes
      // timing), Hive is updated immediately while widget.queueEntry may still hold the older map.
      final rawDirect = widget.queueEntry['prescription'];
      final directEmbedded = fits(rawDirect) ? rawDirect : null;
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
        if (v.isNotEmpty) { cnic = v; break; }
      }
      Map<String, dynamic> found = {};
      final pId = widget.queueEntry['patientId']?.toString() ?? _data['patientId']?.toString();
      final pDateKey = widget.queueEntry['dateKey']?.toString() ?? _data['dateKey']?.toString();
      found = _searchHive(cleanS, cnic, patientId: pId, dateKey: pDateKey);
      if (!fits(found)) found = {};
      if (cleanS.isNotEmpty) {
        final presc = LocalStorageService.getLocalPrescription(
          cleanS,
          cnic: cnic,
          patientName: widget.queueEntry['patientName'] ?? widget.queueEntry['name'] ?? widget.queueEntry['fullName'],
          patientId: pId,
          branchId: widget.branchId,
          dateKey: pDateKey,
        );
        if (presc != null && presc.isNotEmpty && fits(presc)) {
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
        if (direct is Map && direct['prescription'] is Map && fits(direct['prescription'])) {
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
        if (!fits(found)) found = {};
        if (found.isNotEmpty) await LocalStorageService.saveLocalPrescription(found);
      }
      if (found.isEmpty && serial.isNotEmpty && canAttemptCloud) {
        found = await _fetchFromSerialsEmbedded(serial);
        if (!fits(found)) found = {};
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
        found.remove('prescription');
      }
      final rawVitals = widget.queueEntry['vitals'];
      final vitals = (rawVitals is Map) ? Map<String, dynamic>.from(rawVitals) : <String, dynamic>{};
      final dispenseStatus = (widget.queueEntry['dispenseStatus'] ?? '').toString().toLowerCase();
      if (mounted) {
        setState(() {
          // Nothing found on a refresh (or only an older copy): keep the prescription shown.
          // Nor a copy without medicines over one that has them (mayReplacePrescription).
          // A list already on screen that is not this token's (shown before this check
          // existed, or before the token's details arrived) goes.
          if (_data.isNotEmpty && _hasMeds(_data) && !fits(_data)) _data = {};
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

  String _getMedAbbrev(String? type, [String? name]) {
    final t = '${type ?? ''} ${name ?? ''}'.toLowerCase();
    if (t.contains('syrup') || t.contains('syp')) return 'syp.';
    if (t.contains('suspension') || t.contains('susp')) return 'susp.';
    if (t.contains('injection') || t.contains('inj')) return 'inj.';
    if (t.contains('tablet') || t.contains('tab')) return 'tab.';
    if (t.contains('capsule') || t.contains('cap')) return 'cap.';
    if (t.contains('drip') || t.contains('infusion')) return 'drip.';
    if (t.contains('syringe') || t.contains('syr')) return 'syr.';
    if (t.contains('drop')) return 'drops';
    if (t.contains('sachet')) return 'sachet';
    if (t.contains('cream')) return 'cream';
    if (t.contains('ointment') || t.contains('oint')) return 'oint.';
    if (t.contains('inhaler')) return 'inh.';
    return '';
  }

  /// Resolves the 3-digit Proforma barcode (001–999) for a prescribed medicine
  /// so the dispenser patient form shows only the barcode instead of the name.
  String _resolveDisplayBarcode(dynamic item) {
    if (item is! Map) return '---';
    final itemMap = Map<String, dynamic>.from(item);

    // 1. Direct valid 3-digit barcode on the prescribed line
    final rawBar = (itemMap['barcode'] ?? itemMap['rollNo'] ?? '').toString().trim();
    final normDirect = MasterProformaService.normalizeProformaBarcode(rawBar);
    if (normDirect != null) return normDirect;

    // 2. Check StockLedger / StockReader pool batches (keyed by "<pool>|<medicineId>")
    //    as well as legacy "stock:<id>" entries.
    final invId = (itemMap['inventoryId'] ?? itemMap['id'] ?? itemMap['medicineId'])?.toString().trim() ?? '';
    final pool = _patientPool();
    if (pool != null) {
      if (invId.isNotEmpty) {
        final ledgerItem = StockLedger.item(pool.key, invId);
        if (ledgerItem != null) {
          final lBar = (ledgerItem['barcode'] ?? ledgerItem['rollNo'] ?? '').toString().trim();
          final normLedger = MasterProformaService.normalizeProformaBarcode(lBar) ??
              MasterProformaService.resolveOfficialBarcodeForStockItem(ledgerItem);
          if (normLedger != null) return normLedger;
        }
      }
      final group = StockReader.groupForLine(pool, itemMap);
      if (group != null) {
        for (final b in group.batches) {
          final bBar = (b['barcode'] ?? b['rollNo'] ?? '').toString().trim();
          final normBatch = MasterProformaService.normalizeProformaBarcode(bBar) ??
              MasterProformaService.resolveOfficialBarcodeForStockItem(b);
          if (normBatch != null) return normBatch;
        }
      }
    }

    if (invId.isNotEmpty) {
      try {
        if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
          final stockItem = LocalStorageService.getLocalInventoryItem(invId);
          if (stockItem != null) {
            final sBar = (stockItem['barcode'] ?? stockItem['rollNo'] ?? '').toString().trim();
            final normStock = MasterProformaService.normalizeProformaBarcode(sBar) ??
                MasterProformaService.resolveOfficialBarcodeForStockItem(stockItem);
            if (normStock != null) return normStock;
          }
        }
      } catch (_) {}
    }

    // 3. Lookup by code / itemCode in Master Proforma catalog
    final rawCode = (itemMap['code'] ?? itemMap['itemCode'] ?? '').toString().trim();
    if (rawCode.isNotEmpty) {
      final byCode = MasterProformaService.findExactBarcodeMatch(rawCode);
      if (byCode != null) {
        final pBar = (byCode['barcode'] ?? byCode['rollNo'] ?? '').toString().trim();
        final normCode = MasterProformaService.normalizeProformaBarcode(pBar);
        if (normCode != null) return normCode;
        if (pBar.isNotEmpty) return pBar;
      }
    }
    if (rawBar.isNotEmpty) {
      final byRawBar = MasterProformaService.findExactBarcodeMatch(rawBar);
      if (byRawBar != null) {
        final pBar = (byRawBar['barcode'] ?? byRawBar['rollNo'] ?? '').toString().trim();
        final normBar = MasterProformaService.normalizeProformaBarcode(pBar);
        if (normBar != null) return normBar;
      }
    }

    // 4. Match against Master Proforma catalog (handling brand names, spoon dosages, & type aliases)
    final rawName = (itemMap['formula'] ?? itemMap['name'] ?? '').toString().trim();
    final cleanedName = MasterProformaService.cleanBrandToFormula(rawName);
    final type = (itemMap['type'] ?? '').toString().trim();
    var dose = (itemMap['dose'] ?? itemMap['dosage'] ?? '').toString().trim();
    // Ignore syrup spoon instructions or timing strings when matching catalog strength
    if (dose.toLowerCase().contains('spoon') || dose.contains('+')) {
      dose = '';
    }

    for (final candidateName in {rawName, cleanedName}) {
      if (candidateName.isEmpty) continue;
      final exactNtd = MasterProformaService.findExactNameDoseTypeMatch(candidateName, type, dose) ??
          (dose.isNotEmpty ? MasterProformaService.findExactNameDoseTypeMatch(candidateName, type, '') : null) ??
          MasterProformaService.findExactMatch(candidateName, type);
      if (exactNtd != null) {
        final pBar = (exactNtd['barcode'] ?? exactNtd['rollNo'] ?? '').toString().trim();
        final normProforma = MasterProformaService.normalizeProformaBarcode(pBar);
        if (normProforma != null) return normProforma;
        if (pBar.isNotEmpty) return pBar;
      }
    }

    // 5. Fuzzy / normalized alignment via MasterProformaService.alignStockItemWithProforma
    final probe = <String, dynamic>{
      ...itemMap,
      'name': cleanedName.isNotEmpty ? cleanedName : rawName,
      'formula': cleanedName.isNotEmpty ? cleanedName : rawName,
      'type': type,
      'dose': dose,
    };
    MasterProformaService.alignStockItemWithProforma(probe);
    final alignedBar = MasterProformaService.normalizeProformaBarcode(
      (probe['barcode'] ?? probe['rollNo'] ?? '').toString(),
    );
    if (alignedBar != null) return alignedBar;

    if (rawCode.isNotEmpty) return rawCode;
    return rawBar.isNotEmpty ? rawBar : '---';
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
  // [isInj] / [isSyrup] are kept for the callers; the rule itself is StockMath.perDay, the
  // same one the doctor's screen uses (one-time items = their quantity, syrup 1 bottle a day).
  static int _resolvePerDayQty(Map item, {required bool isInj, required bool isSyrup}) =>
      StockMath.perDay(item);

  /// One-time quantity item (injection, drip, swab, plaster, dressing…): no timing, not × days.
  static bool _isQtyOnly(Map item) => PatientFormHelper.isQuantityOnly(item);

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

  /// Partial name match between a stock record's name and a prescribed medicine's name
  /// (exact name / formula matches are checked separately). Used to find every batch of the
  /// same medicine, so it stays loose — but never matches:
  ///  • an empty name (it is "contained" in every name, so it matched every medicine);
  ///  • a combination medicine ("A + B") against a single one ("A"): Amoxicillin matched
  ///    Amoxicillin + Clavulanic acid and deducted the wrong stock;
  ///  • very short names (≤ 3 letters), which are contained in too many others.
  static bool _looseNameMatch(String stockName, String targetName) {
    if (stockName.isEmpty || targetName.isEmpty) return false;
    if (stockName == targetName) return true;
    bool isCombo(String s) => s.contains('+') || s.contains(' with ') || s.contains(' & ');
    if (isCombo(stockName) || isCombo(targetName)) return false;
    final shorter = stockName.length <= targetName.length ? stockName : targetName;
    if (shorter.length <= 3) return false;
    return stockName.contains(targetName) || targetName.contains(stockName);
  }

  /// The stock pool this patient's medicines come from (branch, or branch + the patient's
  /// camp). The doctor's screen uses the same rule, so both see the same figures.
  StockPool? _patientPool() => StockPool.of(
        widget.branchId,
        (widget.queueEntry['campId'] ?? widget.queueEntry['dispensaryId'] ?? _data['campId'] ?? _data['dispensaryId'])
            ?.toString(),
        fallbackCamp: CampSessionService.getActiveCamp(widget.branchId),
      );

  /// Units one prescription line takes from the shelf. The ONE shared rule (StockMath), so
  /// the dispensar takes exactly what the doctor's screen held back for this line.
  double _lineUnits(Map<String, dynamic> medMap, int days) => StockMath.lineUnits(medMap, days);

  /// Movements made by the last dispense on this PC (sent with dispense_completed).
  final List<StockMovement> _lastStockMoves = [];

  String get _entryUidForStock =>
      (widget.queueEntry['entryUid'] ?? _data['entryUid'] ?? '').toString();

  /// Takes this token's medicines from the stock book: FEFO over the batches of each medicine
  /// in the patient's pool, never more than a batch holds, once per token (ids come from the
  /// token, so a resend or second click takes nothing). Returns the batches taken (for the
  /// LAN message read by older app versions).
  Future<List<Map<String, dynamic>>> _deductInventoryLocally(
      String branchId, String serial, List<dynamic> medicines, int days) async {
    final pool = _patientPool();
    if (pool == null) {
      debugPrint('[PatientForm] No stock pool for this patient (camp unknown) — stock not taken');
      return const [];
    }
    final patientSerial = (widget.queueEntry['serial'] ?? widget.queueEntry['id'] ?? serial).toString();
    final lines = <Map<String, dynamic>>[];
    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      medMap['_units'] = _lineUnits(medMap, days);
      lines.add(medMap);
    }
    final res = await StockActions.dispense(
      pool: pool,
      serial: patientSerial,
      entryUid: _entryUidForStock,
      lines: lines,
      days: days,
    );
    _lastStockMoves.addAll(res.moves);
    for (final e in res.short.entries) {
      debugPrint('[PatientForm] Stock short for ${lines[e.key]['name']}: ${e.value} not in stock — not taken');
    }
    final merged = <String, Map<String, dynamic>>{};
    for (final m in res.moves) {
      final prev = merged[m.medicineId];
      if (prev == null) {
        merged[m.medicineId] = {'medicineId': m.medicineId, 'name': m.name, 'delta': m.delta, 'campId': pool.camp};
      } else {
        prev['delta'] = (prev['delta'] as double) + m.delta;
      }
    }
    return merged.values.toList();
  }

  /// Takes [units] of a consumable (syringe / needle) batch, once per token.
  Future<Map<String, dynamic>?> _takeConsumable(String kind, Map<String, dynamic> batch, double units) async {
    final pool = StockPool.fromKey(batch['pool']?.toString()) ?? _patientPool();
    final id = (batch['medicineId'] ?? batch['id'] ?? '').toString().trim();
    if (pool == null || id.isEmpty || units <= 0) return null;
    final have = StockReader.qty(StockLedger.item(pool.key, id) ?? batch);
    final take = units <= have ? units : (have > 0 ? have : 0.0);
    if (take <= 0) return null;
    final serial = (widget.queueEntry['serial'] ?? widget.queueEntry['id'] ?? '').toString();
    final m = StockMovement(
      opId: StockMovement.deterministicId(kind, [pool.key, serial, _entryUidForStock, id]),
      pool: pool.key,
      medicineId: id,
      delta: -take,
      kind: StockMoveKind.dispense,
      at: DateTime.now(),
      by: LocalStorageService.getActiveUsername(),
      ref: '$serial|$kind',
      name: (batch['name'] ?? kind).toString(),
    );
    if (await StockLedger.record(m)) _lastStockMoves.add(m);
    return {'medicineId': id, 'name': batch['name'] ?? kind, 'delta': -take, 'campId': pool.camp};
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
    final pool = _patientPool();
    if (pool == null) return [];
    final List<Map<String, dynamic>> list = [];

    // Strictly this patient's pool (the same records the doctor and the dispense use).
    for (final m in StockReader.batches(pool)) {
      {
        final key = StockLedger.itemKey(pool.key, (m['medicineId'] ?? m['id']).toString());
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
          // Only in-stock syringes of this patient's pool (never another camp's).
          if (available.isNotEmpty) {
            syringeKey = available.first['hiveKey'];
            syringeMap = Map<String, dynamic>.from(available.first);
          }
        }

        if (syringeKey != null && syringeMap != null) {
          syringeMap.remove('hiveKey');
          // One movement, once per token; never more than the batch holds.
          final dedInfo = await _takeConsumable('syr', syringeMap, totalSyringesToDeduct);
          if (dedInfo != null) deducted.add(dedInfo);
          debugPrint('[PatientForm] Syringes for $patientSerial ($patientCampId): ${dedInfo?['delta'] ?? 0}');
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
        // Needles of this patient's pool only, in-stock first, earliest expiry first.
        final pool = _patientPool();
        final candidates = pool == null
            ? <Map<String, dynamic>>[]
            : StockReader.batches(pool).where((m) {
                final type = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();
                final name = (m['name'] ?? '').toString().toLowerCase();
                return type.contains('needle') || name.contains('needle');
              }).toList();
        candidates.sort((a, b) {
          final qa = StockReader.qty(a), qb = StockReader.qty(b);
          if ((qa > 0) != (qb > 0)) return qa > 0 ? -1 : 1;
          final expA = MasterProformaService.parseExpiryDate(a['expiryDate'] ?? a['expiry'], (a['id'] ?? a['medicineId'])?.toString());
          final expB = MasterProformaService.parseExpiryDate(b['expiryDate'] ?? b['expiry'], (b['id'] ?? b['medicineId'])?.toString());
          return expA.compareTo(expB);
        });

        if (candidates.isNotEmpty) {
          // One movement, once per token; never more than the batch holds.
          final dedInfo = await _takeConsumable('ndl', candidates.first, totalNeedlesToDeduct);
          if (dedInfo != null) deducted.add(dedInfo);
          debugPrint('[PatientForm] Needles for $patientSerial ($patientCampId): ${dedInfo?['delta'] ?? 0}');
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
    if (_isDispensed || _isDispensing || _dispenseFlowActive) return;
    _dispenseFlowActive = true;
    widget.onDispenseBusyChanged?.call(true);
    try {
      await _dispenseOnlyBody();
    } finally {
      if (_dispenseFlowActive) {
        _dispenseFlowActive = false;
        widget.onDispenseBusyChanged?.call(false);
      }
    }
  }

  Future<void> _dispenseOnlyBody() async {
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

    // Check stock: the same pool and the same batch grouping the doctor's screen uses. Two
    // lines of the same medicine are added up before comparing with the shelf.
    final List<String> insufficientMeds = [];
    final stockPool = _patientPool();
    final stockGroups = stockPool == null ? const <StockGroup>[] : StockReader.groups(stockPool, withReserved: false);
    final neededByGroup = <String, double>{};
    final shownByGroup = <String, String>{};
    final shelfByGroup = <String, double>{};
    for (final med in medicines) {
      if (med is! Map) continue;
      final medMap = Map<String, dynamic>.from(med);
      final qtyNum = _lineUnits(medMap, days);
      if (qtyNum <= 0) continue;
      final g = stockPool == null ? null : StockReader.groupForLine(stockPool, medMap, within: stockGroups);
      final key = g?.key ?? 'missing:${medMap['name'] ?? medMap['formula']}';
      neededByGroup[key] = (neededByGroup[key] ?? 0) + qtyNum;
      shownByGroup[key] = (medMap['name'] ?? medMap['formula'] ?? 'Unknown Medicine').toString();
      shelfByGroup[key] = g?.onShelf ?? 0;
    }
    for (final e in neededByGroup.entries) {
      final have = shelfByGroup[e.key] ?? 0;
      if (have < e.value) {
        insufficientMeds.add('${shownByGroup[e.key]} (Required: ${e.value.toInt()}, Available: ${have.toInt()})');
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

    // No "Put On Hold" / "Dispense Available" choice any more (user, 2026-11-21): the doctor
    // can only prescribe what this pool has, so a shortfall here is rare. The dispense always
    // goes ahead, takes what is on the shelf, and the confirm dialog lists any shortfall.

    // Fallback/standard RoleTheme read to display dialogue matching exact color palette
    var t = RoleThemeScope.dataOf(context);
    if (RoleThemeScope.of(context) == RoleTheme.admin) {
      t = RoleThemeData.of(RoleTheme.dispenser);
    }
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Dispense'),
        content: Text([
          if (days > 1)
            'Give $days days\' supply of each oral medicine (tablets/capsules ×$days, syrups 1 bottle a day). '
                'Injections, drips, swabs, plasters and other items are given once only.'
          else
            'Mark this prescription as dispensed?',
          if (insufficientMeds.isNotEmpty)
            '\nNot enough on the shelf (only what is there will be taken):\n'
                '${insufficientMeds.map((m) => '• $m').join('\n')}',
          '\nThis cannot be undone.',
        ].join('\n')),
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
      _lastStockMoves.clear();
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
            // The exact stock movements (each with its own id): every PC applies them once.
            if (_lastStockMoves.isNotEmpty) 'stockMoves': _lastStockMoves.map((m) => m.toMap()).toList(),
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
    return MedicineIconBadge(
      name: name ?? '',
      type: type ?? '',
      size: 26,
      iconSize: 14,
      borderRadius: 8,
      showBorder: true,
    );
  }

  Map<String, String> _resolveMedMeta(dynamic item) {
    String rawName = (item['name'] ?? '').toString().trim();
    String formula = (item['formula'] ?? '').toString().trim();
    String dose = (item['dose'] ?? item['dosage'] ?? '').toString().trim();
    if (dose.isEmpty || dose.contains('+') || rawName.isEmpty || formula.isEmpty) {
      final invId = (item['inventoryId'] ?? item['id'] ?? item['medicineId'])?.toString();
      if (invId != null && invId.isNotEmpty) {
        try {
          if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
            final stockItem = LocalStorageService.getLocalInventoryItem(invId);
            if (stockItem != null) {
              if (dose.isEmpty || dose.contains('+')) {
                final stockDose = (stockItem['dose'] ?? stockItem['strength'] ?? '').toString().trim();
                if (stockDose.isNotEmpty) dose = stockDose;
              }
              if (rawName.isEmpty) {
                rawName = (stockItem['name'] ?? stockItem['formula'] ?? '').toString().trim();
              }
              if (formula.isEmpty) {
                formula = (stockItem['formula'] ?? '').toString().trim();
              }
            }
          }
        } catch (_) {}
      }
    }
    if (dose.contains('+')) dose = '';
    return {'name': rawName, 'formula': formula, 'dose': dose};
  }

  List<String> _buildMedTooltipLines({
    required String displayName,
    required String rawName,
    required String dose,
    required String formula,
    required String displayBarcode,
    required bool isInj,
    required bool isSyrup,
    required bool showUrduTiming,
    required String urduInstructions,
    required String englishInstructions,
    required int perDayQty,
    required int days,
    required int totalQty,
    required String qtyLabel,
  }) {
    return [
      if (displayName.isNotEmpty) displayName,
      if (!isInj && dose.isNotEmpty) 'Dose: $dose',
      if (formula.isNotEmpty && formula.toLowerCase() != rawName.toLowerCase()) 'Formula: $formula',
      if (displayBarcode.isNotEmpty && displayBarcode != '---') 'Barcode: $displayBarcode',
      if (!isInj) ...[
        if (showUrduTiming) ...[
          if (urduInstructions.isNotEmpty) 'Instructions: $urduInstructions',
        ] else ...[
          if (englishInstructions.isNotEmpty) 'Instructions: $englishInstructions',
        ],
      ],
      if (isInj)
        'Quantity: $perDayQty (one time)'
      else if (!isSyrup)
        '$perDayQty/day × $days days = $totalQty total'
      else
        '1 bottle/day × $days days = $qtyLabel',
    ];
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
        final displayBarcode = _resolveDisplayBarcode(item);
        final medAbbrev = _getMedAbbrev(item['type']?.toString(), item['name']?.toString());
        final isCustomMed = !PatientFormHelper.isInventoryMed(item is Map ? Map<String, dynamic>.from(item) : {});
        final hasNoBarcode = displayBarcode == '---' || displayBarcode.isEmpty;
        final meta = _resolveMedMeta(item);
        final rawName = meta['name']!;
        final formula = meta['formula']!;
        final dose = meta['dose']!;
        final displayName = '$medAbbrev $rawName'.trim();
        final displayLabel = (isCustomMed && hasNoBarcode)
            ? displayName
            : (medAbbrev.isNotEmpty ? '$medAbbrev $displayBarcode' : displayBarcode);
        final urduLine = PatientFormHelper.buildUrduDosageLine(item);
        final mealUrdu = PatientFormHelper.getMealUrdu(item['meal']?.toString() ?? '');
        final isInj = _isQtyOnly(item is Map ? item : const {});
        final isSyrup = !isInj && _isSyrupType(item['type']?.toString(), item['name']?.toString());
        final isUnclassified = !isInj && PatientFormHelper.isUnclassifiedMedicine(item);
        final perDayQty = _resolvePerDayQty(item, isInj: isInj, isSyrup: isSyrup);
        final totalQty = StockMath.lineUnits(item is Map ? item : const {}, days).round();
        final isDark = _isDark;
        final fullUrdu = [
          if (urduLine.isNotEmpty) urduLine,
          if (mealUrdu.isNotEmpty) mealUrdu,
        ].join('، ');

        final engTiming = PatientFormHelper.buildCompactEnglishTiming(item);
        final engMeal = PatientFormHelper.getMealEnglish(item['meal']?.toString() ?? '');
        final englishInstructions = [
          if (engTiming.isNotEmpty) engTiming,
          if (engMeal.isNotEmpty) '($engMeal)',
        ].join(' ').trim();

        final qtyLabel = isSyrup
            ? '$totalQty ${totalQty == 1 ? 'Bottle' : 'Bottles'}'
            : (isInj
                ? 'Qty $perDayQty'
                : (isUnclassified ? 'Unclassified · qty $totalQty' : '$perDayQty/day · qty $totalQty'));

        final tooltipLines = _buildMedTooltipLines(
          displayName: displayName,
          rawName: rawName,
          dose: dose,
          formula: formula,
          displayBarcode: (isCustomMed && hasNoBarcode) ? '' : displayBarcode,
          isInj: isInj,
          isSyrup: isSyrup,
          showUrduTiming: showUrduTiming,
          urduInstructions: fullUrdu,
          englishInstructions: englishInstructions,
          perDayQty: perDayQty,
          days: days,
          totalQty: totalQty,
          qtyLabel: qtyLabel,
        );

        final c = context.comfort;
        return Tooltip(
          message: tooltipLines.join('\n'),
          waitDuration: const Duration(milliseconds: 300),
          child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 12 : 16,
            vertical: isMobile ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
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
                                    color: isDark ? SoftPalette.gray50 : t.textPrimary,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: displayLabel,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontStyle: (isCustomMed && hasNoBarcode) ? FontStyle.italic : FontStyle.normal,
                                        fontSize: isMobile ? 13.5 : 15,
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
                    englishInstructions,
                    textAlign: TextAlign.left,
                    style: TextStyle(
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

    final c = context.comfort;
    final durationWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Medicine duration',
          style: TextStyle(
            fontSize: isMobile ? 12.5 : 13.5,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 14, vertical: isMobile ? 10 : 12),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Prescribed / paid',
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13,
                  fontWeight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
              Text(
                '$prescribed / $suggested day${suggested > 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: isMobile ? 13 : 14.5,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
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
            fontSize: isMobile ? 12.5 : 13.5,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
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
                horizontal: isMobile ? 10 : 12,
                vertical: isMobile ? 7 : 8,
              ),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPhysio ? Icons.spa_rounded : Icons.science_outlined,
                    color: c.brand,
                    size: 15,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
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

  // ─── Banner ───────────────────────────────────────────────────────────────
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
    final s = _resolvedSerial;
    final latestEntry = s.isNotEmpty ? LocalStorageService.getLocalEntry(widget.branchId, s) : null;
    final pId = (latestEntry?['patientId'] ?? _data['patientId'] ?? widget.queueEntry['patientId'] ?? '').toString().trim();
    final latestPatient = pId.isNotEmpty ? LocalStorageService.getLocalPatient(pId) : null;
    final canonicalFromPatient = latestPatient != null
        ? LocalStorageService.resolveCanonicalPatientName(latestPatient)
        : '';
    final candidates = [
      if (canonicalFromPatient.isNotEmpty) canonicalFromPatient,
      latestEntry?['patientName'],
      latestEntry?['name'],
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
    final s = _resolvedSerial;
    final latestEntry = s.isNotEmpty ? LocalStorageService.getLocalEntry(widget.branchId, s) : null;
    final candidates = [
      latestEntry?['patientCnic'],
      latestEntry?['cnic'],
      latestEntry?['guardianCnic'],
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
    final resolved = LocalStorageService.resolveFirstValidCnic(candidates);
    return resolved.isNotEmpty ? resolved : 'N/A';
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
    final s = _resolvedSerial;
    final latestEntry = s.isNotEmpty ? LocalStorageService.getLocalEntry(widget.branchId, s) : null;
    final pId = (latestEntry?['patientId'] ?? _data['patientId'] ?? widget.queueEntry['patientId'] ?? '').toString().trim();
    final latestPatient = pId.isNotEmpty ? LocalStorageService.getLocalPatient(pId) : null;
    final candidates = [
      latestPatient?['gender'],
      latestEntry?['patientGender'],
      latestEntry?['gender'],
      (latestEntry?['vitals'] is Map) ? latestEntry!['vitals']['gender'] : null,
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
      _gender,
    ];
    for (var val in candidates) {
      if (val != null) {
        final str = val.toString().trim();
        if (str.isNotEmpty && str != 'N/A' && str != 'null' && str.toLowerCase() != 'unknown') {
          if (str.toLowerCase() == 'm' || str.toLowerCase() == 'male') return 'Male';
          if (str.toLowerCase() == 'f' || str.toLowerCase() == 'female') return 'Female';
          return str[0].toUpperCase() + str.substring(1);
        }
      }
    }
    return 'N/A';
  }

  String _resolveAge() {
    final s = _resolvedSerial;
    final latestEntry = s.isNotEmpty ? LocalStorageService.getLocalEntry(widget.branchId, s) : null;
    final pId = (latestEntry?['patientId'] ?? _data['patientId'] ?? widget.queueEntry['patientId'] ?? '').toString().trim();
    final latestPatient = pId.isNotEmpty ? LocalStorageService.getLocalPatient(pId) : null;

    // 1. Check explicit age candidates (latest patient & Hive token first so live edits show immediately)
    final ageCandidates = [
      latestPatient?['age'],
      latestEntry?['patientAge'],
      latestEntry?['age'],
      (latestEntry?['vitals'] is Map) ? latestEntry!['vitals']['age'] : null,
      _data['patientAge'],
      _data['age'],
      widget.queueEntry['patientAge'],
      widget.queueEntry['age'],
      (widget.queueEntry['vitals'] is Map) ? widget.queueEntry['vitals']['age'] : null,
      _age,
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
      latestPatient?['dob'],
      latestPatient?['dateOfBirth'],
      latestEntry?['dob'],
      latestEntry?['dateOfBirth'],
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
    final c = context.comfort;
    final days = _daysOfMedicine;

    final dispenseLabel = _isDispensed
        ? 'Already Dispensed'
        : _isDispensing
            ? 'Dispensing...'
            : days > 1
                ? 'Dispense ($days days\' supply)'
                : 'Dispense Medicine';

    final isDisabled = _isDispensed || _isDispensing;

    final dispenseBtn = SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        onPressed: isDisabled ? null : _dispenseOnly,
        icon: _isDispensing
            ? SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.textMuted),
              )
            : Icon(
                Icons.check_circle_rounded,
                color: isDisabled ? c.textMuted : c.onBrand,
                size: 18,
              ),
        label: Text(
          dispenseLabel,
          style: TextStyle(
            fontSize: isMobile ? 13 : 14,
            fontWeight: FontWeight.w700,
            color: isDisabled ? c.textMuted : c.onBrand,
            letterSpacing: 0.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isDisabled ? c.surfaceSunken : c.brand,
          disabledBackgroundColor: c.surfaceSunken,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );

    final reportBtn = SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        onPressed: _handleDownloadPdf,
        icon: Icon(Icons.picture_as_pdf_rounded, color: c.brand, size: 18),
        label: Text(
          'Report',
          style: TextStyle(
            fontSize: isMobile ? 13 : 13.5,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
            letterSpacing: 0.2,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: c.surfaceSunken,
          side: BorderSide(color: c.borderStrong),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );

    return RepaintBoundary(
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 14 : 20,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(
            top: BorderSide(color: c.border, width: 1),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(flex: 7, child: dispenseBtn),
              const SizedBox(width: 10),
              Expanded(flex: 3, child: reportBtn),
            ],
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
    final rawBp = docBp.isNotEmpty ? docBp : recBp;
    final subBp = (hasDocUpdate && recBp.isNotEmpty && recBp != docBp) ? 'Rec: $recBp' : null;
    final bpEval = PatientInfo.evaluateBp(rawBp, isDark);

    // Weight
    final docWeightRaw = cleanVal(docVitals['weight'] ?? (hasDocUpdate ? vitals['weight'] : null));
    final recWeightRaw = cleanVal(recVitals['weight'] ?? (!hasDocUpdate ? vitals['weight'] : null));
    final rawWeight = docWeightRaw.isNotEmpty ? docWeightRaw : recWeightRaw;
    final subWeight = (hasDocUpdate && recWeightRaw.isNotEmpty && recWeightRaw != docWeightRaw) ? 'Rec: $recWeightRaw kg' : null;
    final weightEval = PatientInfo.evaluateWeight(rawWeight, isDark);

    // Sugar
    final docSugarRaw = cleanVal(docVitals['sugar'] ?? (hasDocUpdate ? vitals['sugar'] : null));
    final recSugarRaw = cleanVal(recVitals['sugar'] ?? (!hasDocUpdate ? vitals['sugar'] : null));
    final rawSugar = docSugarRaw.isNotEmpty ? docSugarRaw : recSugarRaw;
    final subSugar = (hasDocUpdate && recSugarRaw.isNotEmpty && recSugarRaw != docSugarRaw) ? 'Rec: $recSugarRaw' : null;
    final sugarEval = PatientInfo.evaluateSugar(rawSugar, isDark);

    // Temp
    final docTempRaw = cleanVal(docVitals['temp'] ?? (hasDocUpdate ? vitals['temp'] : null));
    final recTempRaw = cleanVal(recVitals['temp'] ?? (!hasDocUpdate ? vitals['temp'] : null));
    final rawTemp = docTempRaw.isNotEmpty ? docTempRaw : recTempRaw;
    final subTemp = (hasDocUpdate && recTempRaw.isNotEmpty && recTempRaw != docTempRaw) ? 'Rec: $recTempRaw' : null;
    final tempEval = PatientInfo.evaluateTemp(rawTemp, isDark);

    final statCards = <Widget>[
      Expanded(
        flex: 13,
        child: _vitalStatCard(
          label: 'BP',
          eval: bpEval,
          icon: Icons.favorite_rounded,
          unit: 'mmHg',
          subValue: subBp,
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        flex: 9,
        child: _vitalStatCard(
          label: 'TEMP',
          eval: tempEval,
          icon: Icons.thermostat_rounded,
          unit: '°C',
          subValue: subTemp,
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        flex: 9,
        child: _vitalStatCard(
          label: 'SUGAR',
          eval: sugarEval,
          icon: Icons.water_drop_rounded,
          unit: 'mg/dL',
          subValue: subSugar,
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        flex: 9,
        child: _vitalStatCard(
          label: 'WEIGHT',
          eval: weightEval,
          icon: Icons.monitor_weight_rounded,
          unit: 'kg',
          subValue: subWeight,
          isDark: isDark,
          isMobile: isMobile,
        ),
      ),
    ];

    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: statCards,
      ),
    );
  }

  Widget _vitalStatCard({
    required String label,
    required VitalEvaluation eval,
    required IconData icon,
    required String unit,
    String? subValue,
    required bool isDark,
    required bool isMobile,
  }) {
    final c = context.comfort;
    final isCrit = eval.status == VitalStatus.critical;
    final isWarn = eval.status == VitalStatus.warning;
    final isNormal = eval.status == VitalStatus.normal;

    final Color bgColor;
    final Color borderColor;
    final Color valueColor;
    final String? statusTag;
    final Color tagColor;

    if (isCrit) {
      bgColor = c.dangerBg;
      borderColor = c.danger.withValues(alpha: isDark ? 0.45 : 0.35);
      valueColor = c.danger;
      statusTag = 'HIGH';
      tagColor = c.danger;
    } else if (isWarn) {
      bgColor = c.warningBg;
      borderColor = c.warning.withValues(alpha: isDark ? 0.45 : 0.35);
      valueColor = c.warning;
      statusTag = 'WATCH';
      tagColor = c.warning;
    } else if (isNormal) {
      bgColor = c.brandSoft.withValues(alpha: isDark ? 0.25 : 0.55);
      borderColor = c.brand.withValues(alpha: isDark ? 0.35 : 0.25);
      valueColor = c.textPrimary;
      statusTag = null;
      tagColor = c.brand;
    } else {
      bgColor = c.surfaceSunken;
      borderColor = c.border;
      valueColor = c.textMuted;
      statusTag = null;
      tagColor = Colors.transparent;
    }

    final iconColor = (isCrit || isWarn)
        ? tagColor
        : (isNormal ? c.brand : c.textMuted);

    String mainVal = eval.displayValue.replaceAll('°F', '°C');
    String resolvedUnit = unit;
    if (resolvedUnit.isNotEmpty && mainVal.endsWith(resolvedUnit)) {
      mainVal = mainVal.substring(0, mainVal.length - resolvedUnit.length).trim();
    } else if (resolvedUnit.isEmpty && mainVal.endsWith('°C')) {
      resolvedUnit = '°C';
      mainVal = mainVal.substring(0, mainVal.length - 2).trim();
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 8 : 10,
        vertical: isMobile ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor,
          width: (isCrit || isWarn) ? 1.2 : 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: iconColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: isMobile ? 9.5 : 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: (isCrit || isWarn) ? tagColor : c.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (statusTag != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: tagColor.withValues(alpha: isDark ? 0.25 : 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    statusTag,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      color: tagColor,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  eval.status == VitalStatus.neutral ? '—' : mainVal,
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                ),
                if (eval.status != VitalStatus.neutral && resolvedUnit.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    resolvedUnit,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: (isCrit || isWarn)
                          ? tagColor.withValues(alpha: 0.85)
                          : c.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (subValue != null && subValue.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subValue,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
    
    final c = context.comfort;
    final isDark = _isDark;
    final serial = _resolvedSerial;
    final dispToken = LocalStorageService.formatTokenDisplay(serial);
    final tokenLabel = dispToken.isNotEmpty ? '#$dispToken' : '#---';
    final genderStr = _resolveGender();
    final ageVal = _resolveAge();
    final ageDisplay = ageVal != 'N/A' ? '$ageVal y' : '';
    final cnic = _getResolvedCnic();
    final phone = _getPatientPhone();

    final queueType = _resolvedQueueType;
    final Color qColor;
    final Color qBg;
    final String qLabel;
    if (queueType == 'gmwf') {
      qColor = SoftPalette.orange400;
      qBg = c.warningBg;
      qLabel = 'GMWF';
    } else if (queueType == 'non-zakat') {
      qColor = SoftPalette.blue550;
      qBg = c.infoBg;
      qLabel = BranchLabels.nonZakat(widget.branchId).toUpperCase();
    } else {
      qColor = c.success;
      qBg = c.successBg;
      qLabel = BranchLabels.zakat(widget.branchId).toUpperCase();
    }

    final subtitleParts = [
      if (ageDisplay.isNotEmpty) ageDisplay,
      if (genderStr != 'N/A') genderStr,
      if (cnic != 'N/A') 'CNIC $cnic',
      if (phone != null && phone.isNotEmpty) phone,
    ];

    Widget patientInfoCard = Container(
      padding: EdgeInsets.all(isMobile ? 12 : 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Tooltip(
            message: 'Serial: $serial',
            child: Container(
              constraints: const BoxConstraints(minWidth: 54, minHeight: 46),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.brand,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                tokenLabel,
                style: TextStyle(
                  color: c.onBrand,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        patientName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: isMobile ? 16 : 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: qBg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: qColor.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        qLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: qColor,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    if (isVitalsOnly) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: SoftPalette.purple600,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'VITALS ONLY',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: SoftPalette.gray50,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: isMobile ? 11.5 : 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (serial.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Text(
                serial,
                style: TextStyle(
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: isMobile ? 11 : 11.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    Widget medicineBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        patientInfoCard,
        if (hasAnyVitals || isVitalsOnly)
          _buildVitalsCard(vitals, t, isMobile: isMobile, isVitalsOnly: isVitalsOnly),
        _buildCompactDurationAndDiagnosis(labTests, diagnosis, t, isDark),
        if (isVitalsOnly && prescriptions.isEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.violet100m),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.adapt(SoftPalette.violet200)),
            ),
            child: Row(
              children: [
                Icon(Icons.health_and_safety_rounded, color: context.adapt(SoftPalette.violet550), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vitals Inspection Token',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: context.adapt(SoftPalette.violet600),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'This patient arrived for vitals inspection only. No medicines are prescribed.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: context.adapt(SoftPalette.violet550),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
          _buildSyringeSelectionCard(prescriptions, t, isMobile: isMobile),
          _buildNeedleSelectionCard(prescriptions, t, isMobile: isMobile),
        ],
      ],
    );

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 16,
        vertical: isMobile ? 10 : 12,
      ),
      child: medicineBody,
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
    
    // Theme-aware clinical palette (follows GMWF / Nexus / Twilight)
    final c = context.comfort;
    final t = RoleThemeData(
      roleLabel:             'CLINICAL',
      bg:                    c.background,
      bgCard:                c.surface,
      bgCardAlt:             c.surfaceSunken,
      bgRule:                c.border,
      accent:                c.brand,
      accentLight:           c.brandStrong,
      accentMuted:           c.brandSoft,
      accentGradient:        LinearGradient(colors: [c.brand, c.brandStrong]),
      glassTint:             c.brand.withValues(alpha: isDark ? 0.20 : 0.10),
      textPrimary:           c.textPrimary,
      textSecondary:         c.textSecondary,
      textTertiary:          c.textMuted,
      danger:                c.danger,
      zakat:                 isDark ? SoftPalette.green350 : SoftPalette.green550,
      nonZakat:              isDark ? SoftPalette.blue500 : SoftPalette.blue550,
      gmwf:                  isDark ? SoftPalette.orange350 : SoftPalette.orange400,
      cardFillTokens:        c.brand,
      cardFillPrescriptions: c.brandStrong,
      cardFillDispensary:    c.brandStrong,
      chartBar1:             c.brand,
      chartBar2:             isDark ? SoftPalette.green350 : SoftPalette.green550,
      chartBar3:             isDark ? SoftPalette.blue500 : SoftPalette.blue550,
      chartGrid:             c.border,
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

    final formColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_doctorUpdatedLive) _buildDoctorUpdatedBanner(isMobile: isMobile),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.zero,
            child: _buildContent(t, isMobile: isMobile),
          ),
        ),
        _buildActionBar(t, isMobile: isMobile),
      ],
    );

    if (isMobile) {
      return DeskCard(
        margin: const EdgeInsets.all(8),
        accentTop: true,
        child: formColumn,
      );
    }

    return Material(
      color: Colors.transparent,
      child: formColumn,
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
    final c = context.comfort;
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
      qColor = c.warning;
      qBg = c.warningBg;
      qLabel = 'GMWF';
    } else if (queueType == 'non-zakat') {
      qColor = c.info;
      qBg = c.infoBg;
      qLabel = BranchLabels.nonZakat(widget.branchId);
    } else {
      qColor = c.success;
      qBg = c.successBg;
      qLabel = BranchLabels.zakat(widget.branchId);
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
    final rawBp = docBp.isNotEmpty ? docBp : recBp;
    final bpEval = PatientInfo.evaluateBp(rawBp, isDark);

    final docTempRaw = cleanVal(docVitals['temp'] ?? (hasDocUpdate ? vitals['temp'] : null));
    final recTempRaw = cleanVal(recVitals['temp'] ?? (!hasDocUpdate ? vitals['temp'] : null));
    final rawTemp = docTempRaw.isNotEmpty ? docTempRaw : recTempRaw;
    final tempEval = PatientInfo.evaluateTemp(rawTemp, isDark);

    final docWeightRaw = cleanVal(docVitals['weight'] ?? (hasDocUpdate ? vitals['weight'] : null));
    final recWeightRaw = cleanVal(recVitals['weight'] ?? (!hasDocUpdate ? vitals['weight'] : null));
    final rawWeight = docWeightRaw.isNotEmpty ? docWeightRaw : recWeightRaw;
    final weightEval = PatientInfo.evaluateWeight(rawWeight, isDark);

    final docSugarRaw = cleanVal(docVitals['sugar'] ?? (hasDocUpdate ? vitals['sugar'] : null));
    final recSugarRaw = cleanVal(recVitals['sugar'] ?? (!hasDocUpdate ? vitals['sugar'] : null));
    final rawSugar = docSugarRaw.isNotEmpty ? docSugarRaw : recSugarRaw;
    final sugarEval = PatientInfo.evaluateSugar(rawSugar, isDark);

    Color statusColor(VitalEvaluation eval, Color normalFallback) {
      if (eval.status == VitalStatus.critical) return c.danger;
      if (eval.status == VitalStatus.warning) return c.warning;
      if (eval.status == VitalStatus.normal) return normalFallback;
      return c.textMuted;
    }

    Widget vitalRow({
      required String label,
      required String value,
      required Color valColor,
      required Color iconColor,
      required IconData icon,
    }) {
      final hasVal = value != '—' && value != 'N/A';
      return Row(
        children: [
          Icon(icon, size: 12, color: hasVal ? iconColor : c.textMuted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  hasVal ? value : '—',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: hasVal ? valColor : c.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Left Side: Circular Avatar + Patient Details ──
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.brandSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person_rounded, size: 24, color: c.brand),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            patientName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: qBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: qColor.withValues(alpha: 0.35)),
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
                    const SizedBox(height: 3),
                    Text(
                      'CNIC $cnic',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (genderAgeText.isNotEmpty) genderAgeText,
                        if (phone != null && phone.isNotEmpty) phone,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),
              Container(width: 1, height: 74, color: c.border),
              const SizedBox(width: 10),

              // ── Right Side: Vertical Vitals List ──
              SizedBox(
                width: 150,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    vitalRow(
                      label: 'BP',
                      value: bpEval.status == VitalStatus.neutral ? '—' : bpEval.displayValue,
                      valColor: statusColor(bpEval, c.textPrimary),
                      iconColor: c.danger,
                      icon: Icons.favorite_rounded,
                    ),
                    Divider(height: 6, thickness: 0.8, color: c.border),
                    vitalRow(
                      label: 'Temp',
                      value: tempEval.status == VitalStatus.neutral ? '—' : tempEval.displayValue,
                      valColor: statusColor(tempEval, c.textPrimary),
                      iconColor: c.warning,
                      icon: Icons.thermostat_rounded,
                    ),
                    Divider(height: 6, thickness: 0.8, color: c.border),
                    vitalRow(
                      label: 'Wt',
                      value: weightEval.status == VitalStatus.neutral ? '—' : weightEval.displayValue,
                      valColor: statusColor(weightEval, c.textPrimary),
                      iconColor: c.info,
                      icon: Icons.scale_rounded,
                    ),
                    Divider(height: 6, thickness: 0.8, color: c.border),
                    vitalRow(
                      label: 'Sugar',
                      value: sugarEval.status == VitalStatus.neutral ? '—' : sugarEval.displayValue,
                      valColor: statusColor(sugarEval, c.brand),
                      iconColor: c.brand,
                      icon: Icons.water_drop_rounded,
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
    final c = context.comfort;
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
      margin: EdgeInsets.only(top: widget.isCompactPreview ? 8 : 10),
      padding: EdgeInsets.symmetric(
        horizontal: widget.isCompactPreview ? 10 : 12,
        vertical: widget.isCompactPreview ? 7 : 9,
      ),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_today_outlined, size: widget.isCompactPreview ? 13 : 14, color: c.brand),
              const SizedBox(width: 6),
              Text(
                'Duration: $prescribed / $suggested d',
                style: TextStyle(
                  fontSize: widget.isCompactPreview ? 12 : 13,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              if (refundAmt > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.warningBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.warning.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    'Refund: Rs. $refundAmt',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: c.warning),
                  ),
                ),
              ] else if (extraAmt > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.dangerBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.danger.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    'Due: Rs. $extraAmt',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: c.danger),
                  ),
                ),
              ],
              if (diagnosis.isNotEmpty) ...[
                const SizedBox(width: 10),
                Container(width: 1, height: 14, color: c.borderStrong),
                const SizedBox(width: 10),
                Icon(Icons.description_outlined, size: widget.isCompactPreview ? 13 : 14, color: c.brand),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Diag: $diagnosis',
                    maxLines: widget.isCompactPreview ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: widget.isCompactPreview ? 12 : 13,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
          if (labTests.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: labTests.map((item) {
                final name = item['name']?.toString() ?? 'Test';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: c.brand.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isPhysio ? Icons.spa_rounded : Icons.science_outlined, size: 11, color: c.brand),
                      const SizedBox(width: 4),
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
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
    final c = context.comfort;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        4,
        widget.isCompactPreview ? 10 : 12,
        4,
        widget.isCompactPreview ? 4 : 6,
      ),
      child: Row(
        children: [
          Icon(icon, size: widget.isCompactPreview ? 13 : 15, color: c.brand),
          const SizedBox(width: 6),
          Text(
            count > 0 ? '$title ($count)' : title,
            style: TextStyle(
              fontSize: widget.isCompactPreview ? 12 : 13,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            'QTY',
            style: TextStyle(
              fontSize: widget.isCompactPreview ? 10.5 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMedTypeIconBadge(String? type, String? name, bool isDark) {
    return MedicineIconBadge(
      name: name ?? '',
      type: type ?? '',
      size: 22,
      iconSize: 11.5,
      borderRadius: 5,
      showBorder: true,
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
            final meta = _resolveMedMeta(item);
            final rawName = meta['name']!;
            final dose = meta['dose']!;
            final displayName = '$abbrev $rawName'.trim();
            final formula = meta['formula']!;
            final displayBarcode = _resolveDisplayBarcode(item);
            final medAbbrev = _getMedAbbrev(item['type']?.toString(), item['name']?.toString());
            // For custom medicines (no inventory ID → no real barcode), show the
            // medicine name instead of "---" so the dispenser knows what to give.
            final isCustomMed = !PatientFormHelper.isInventoryMed(item is Map ? Map<String, dynamic>.from(item) : {});
            final hasNoBarcode = displayBarcode == '---' || displayBarcode.isEmpty;
            final displayLabel = (isCustomMed && hasNoBarcode)
                ? displayName  // e.g. "Tab Panadol Extra"
                : (medAbbrev.isNotEmpty ? '$medAbbrev $displayBarcode' : displayBarcode);
            final isInj = _isQtyOnly(item is Map ? item : const {});
            final isSyrup = !isInj && _isSyrupType(item['type']?.toString(), item['name']?.toString());
            final perDayQty = StockMath.perDay(item is Map ? item : const {});
            final totalQty = StockMath.lineUnits(item is Map ? item : const {}, days).round();

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
              timingUrdu = 'مقدار $perDayQty';
            } else if (parts[0] > 0 || parts[1] > 0 || parts[2] > 0 || (parts.length > 3 && parts[3] > 0)) {
              final labels = PatientFormHelper.urduSlotLabels(parts.length);
              timingUrdu = [
                for (var i = 0; i < parts.length; i++)
                  if (parts[i] > 0) '${parts[i]} ${labels[i]}',
              ].join(' • ');
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
              numericTiming = 'Qty $perDayQty';
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
                ? 'Qty $perDayQty (one time)'
                : [
                    if (engTimes.isNotEmpty) engTimes.join(', ') else numericTiming,
                    if (mealEnglish.isNotEmpty) '($mealEnglish)',
                  ].join(' ');

            final qtyLabel = isSyrup ? '$totalQty Btl' : 'QTY $totalQty';

            final tooltipLines = _buildMedTooltipLines(
              displayName: displayName,
              rawName: rawName,
              dose: dose,
              formula: formula,
              displayBarcode: (isCustomMed && hasNoBarcode) ? '' : displayBarcode,
              isInj: isInj,
              isSyrup: isSyrup,
              showUrduTiming: showUrduTiming,
              urduInstructions: fullUrdu.isNotEmpty ? fullUrdu : compactUrdu,
              englishInstructions: fullEnglish.isNotEmpty ? fullEnglish : compactEnglish,
              perDayQty: perDayQty,
              days: days,
              totalQty: totalQty,
              qtyLabel: qtyLabel,
            );

            final hasTimingBadge = showUrduTiming ? compactUrdu.isNotEmpty : compactEnglish.isNotEmpty;

            final c = context.comfort;
            return Tooltip(
              message: tooltipLines.join('\n'),
              waitDuration: const Duration(milliseconds: 300),
              child: Container(
                margin: const EdgeInsets.only(bottom: 5),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.isCompactPreview ? 8 : 12,
                  vertical: widget.isCompactPreview ? 6 : 8,
                ),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 1. Medicine Type Icon Badge
                    _buildCompactMedTypeIconBadge(item['type']?.toString(), item['name']?.toString(), isDark),
                    const SizedBox(width: 6),

                    // 2. Medicine Barcode + Type (dispenser view); for custom
                    // medicines that have no barcode, the medicine name is shown.
                    Expanded(
                      child: Text(
                        displayLabel,
                        style: TextStyle(
                          color: isDark ? SoftPalette.gray50 : t.textPrimary,
                          fontSize: widget.isCompactPreview ? 12.5 : 13.5,
                          fontWeight: FontWeight.w800,
                          fontStyle: (isCustomMed && hasNoBarcode) ? FontStyle.italic : FontStyle.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),

                    // 3. Timing / Instruction Badge (Urdu text or 1+1+1 English format)
                    if (hasTimingBadge) ...[
                      Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: EdgeInsets.symmetric(
                          horizontal: widget.isCompactPreview ? 6 : 8,
                          vertical: showUrduTiming ? 2 : 3,
                        ),
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
                                  fontSize: widget.isCompactPreview ? 12.5 : 14,
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
                                  fontSize: widget.isCompactPreview ? 11.5 : 12,
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.brandSoft,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: c.brand.withValues(alpha: 0.25),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        qtyLabel,
                        style: TextStyle(
                          fontSize: widget.isCompactPreview ? 10.5 : 11.5,
                          fontWeight: FontWeight.w800,
                          color: c.brand,
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
    final c = context.comfort;
    final days = _daysOfMedicine;

    final dispenseLabel = _isDispensed
        ? 'Dispensed'
        : _isDispensing
            ? 'Dispensing...'
            : days > 1
                ? 'Dispense ($days days)'
                : 'Dispense Medicine';

    final isDisabled = _isDispensed || _isDispensing;

    final dispenseBtn = SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        onPressed: isDisabled ? null : _dispenseOnly,
        icon: _isDispensing
            ? SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.textMuted),
              )
            : Icon(
                Icons.check_circle_rounded,
                color: isDisabled ? c.textMuted : c.onBrand,
                size: 17,
              ),
        label: Text(
          dispenseLabel,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: isDisabled ? c.textMuted : c.onBrand,
            letterSpacing: 0.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isDisabled ? c.surfaceSunken : c.brand,
          disabledBackgroundColor: c.surfaceSunken,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );

    final reportBtn = SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: _handleDownloadPdf,
        icon: Icon(Icons.picture_as_pdf_rounded, color: c.brand, size: 16),
        label: Text(
          'Report',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
            letterSpacing: 0.2,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: c.surfaceSunken,
          side: BorderSide(color: c.borderStrong),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );

    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(
            top: BorderSide(color: c.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(flex: 7, child: dispenseBtn),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: reportBtn),
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
                        _infoSummary('Queue Type', BranchLabels.text(widget.queueType.toUpperCase(), widget.branchId)),
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
