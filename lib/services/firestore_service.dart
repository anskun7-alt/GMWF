// lib/services/firestore_service.dart
//
// CHANGES IN THIS VERSION:
//   FIX: savePatient() now follows local-first pattern:
//     1. Save to Hive (always, instant)
//     2. Try direct Firestore write with 5s timeout (fast path when online)
//     3. On failure, enqueue for SyncService retry — no patient is ever lost
//     4. LAN broadcast for same-network devices
//     5. triggerUpload() to flush queue immediately if online
//   Previously the method only called enqueueSync(), which was silently
//   dropped because SyncService had no 'save_patient' handler.

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';

import '../models/patient.dart';
import '../models/token.dart';
import 'local_storage_service.dart';
import 'sync_service.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';
import 'serials_service.dart';
import 'camp_session_service.dart';
import 'cloud/lan_firestore_gate.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── Availability ping cache (60s TTL) — avoids a Firestore read per call ──
  bool? _availabilityCache;
  DateTime? _availabilityCachedAt;
  static const _availabilityTtl = Duration(seconds: 60);

  static DateTime _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime)  return value;
    if (value is String) {
      try { return DateTime.parse(value); } catch (_) {}
    }
    return DateTime.now();
  }

  Future<bool> _isFirestoreAvailable() async {
    if (LanFirestoreGate.isLanDesk) return false; // a dispensary desk on the LAN uses local data
    if (kIsWeb || !Platform.isWindows) return true;

    // Return cached result if it's still fresh
    final cached = _availabilityCache;
    final cachedAt = _availabilityCachedAt;
    if (cached != null && cachedAt != null &&
        DateTime.now().difference(cachedAt) < _availabilityTtl) {
      return cached;
    }

    try {
      await _db.collection('_ping').limit(1).get();
      _availabilityCache = true;
    } catch (_) {
      _availabilityCache = false;
    }
    _availabilityCachedAt = DateTime.now();
    return _availabilityCache!;
  }

  // ── Save patient ──────────────────────────────────────────────────────────

  Future<void> savePatient({
    required String branchId,
    required String patientId,
    required Map<String, dynamic> patientData,
  }) async {
    if (branchId.trim().isEmpty || patientId.trim().isEmpty) {
      Logger().d("ERROR: savePatient → branchId or patientId empty");
      return;
    }

    final cleanBranch = LocalStorageService.sanitizeBranchId(branchId);
    final data = Map<String, dynamic>.from(patientData);
    data['branchId']  = cleanBranch;
    data['patientId'] = patientId;
    data.remove('id');

    // Normalise dob to ISO string for Hive storage.
    // SyncService converts it back to Timestamp before writing to Firestore.
    if (data['dob'] is DateTime) {
      data['dob'] = (data['dob'] as DateTime).toIso8601String();
    } else if (data['dob'] is Timestamp) {
      data['dob'] = (data['dob'] as Timestamp).toDate().toIso8601String();
    }
    // Normalize raw 13-digit CNIC into standardized format: xxxxx-xxxxxxx-x
    final rawCnic = (data['cnic'] ?? data['patientCnic'])?.toString().trim();
    if (rawCnic != null && RegExp(r'^\d{13}$').hasMatch(rawCnic)) {
      final formatted = '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}';
      data['cnic'] = formatted;
      if (data.containsKey('patientCnic')) {
        data['patientCnic'] = formatted;
      }
    }
    final rawGuard = data['guardianCnic']?.toString().trim();
    if (rawGuard != null && RegExp(r'^\d{13}$').hasMatch(rawGuard)) {
      data['guardianCnic'] = '${rawGuard.substring(0, 5)}-${rawGuard.substring(5, 12)}-${rawGuard.substring(12, 13)}';
    }

    Logger().d('[FirestoreService] savePatient → $patientId | ${data['name'] ?? 'unknown'}');

    // STEP 1 — Hive: always save locally first (works offline, instant)
    await LocalStorageService.saveLocalPatient(data, isFromSync: true);
    Logger().d('[FirestoreService] ✅ Hive write: $patientId');

    // STEP 2 — LAN/WebSocket: deliver locally before touching Firestore.
    // Firestore quota or internet failures must not delay other LAN users.
    try {
      RealtimeManager().sendMessage(
        RealtimeEvents.payload(
          type: RealtimeEvents.savePatient,
          data: {
            'branchId':  cleanBranch,
            'patientId': patientId,
            'data':      data,
          },
        ),
      );
    } catch (e) {
      Logger().d('[FirestoreService] LAN broadcast failed: $e');
    }

    // On a dispensary desk connected to the LAN server, STEP 2 is the whole job: the server
    // saves the patient and uploads it. Queuing it here as well (save_patient is not dropped
    // on LAN desks) uploaded it again later, and the direct write below went past the server.
    if (LanFirestoreGate.isLanDesk) return;

    // STEP 3 — Enqueue for sync immediately (0ms durable write)
    final sanitized = LocalStorageService.sanitize(data);
    await LocalStorageService.enqueueSync({
      'type':      'save_patient',
      'branchId':  cleanBranch,
      'patientId': patientId,
      'data':      sanitized,
    });
    Logger().d('[FirestoreService] 📥 Enqueued for sync: $patientId');

    // STEP 4 — Flush queue in background via CloudDb REST API (no-op if offline)
    SyncService().triggerUpload();
    Logger().d('[FirestoreService] triggerUpload called after savePatient');
  }

  // ── Save entry ────────────────────────────────────────────────────────────

  Future<void> saveEntry({
    required String branchId,
    required String patientId,
    required Map<String, dynamic> vitals,
  }) async {
    if (branchId.trim().isEmpty || patientId.trim().isEmpty) {
      Logger().d('ERROR: Cannot save entry — branchId or patientId empty');
      return;
    }

    final dateKey = DateFormat('ddMMyy').format(DateTime.now());
    final serial  = await _generateNextSerial(branchId, dateKey);
    final now     = DateTime.now();

    String queueType    = 'zakat';
    String patientName  = 'Unknown Patient';
    String patientCnic  = '';
    String guardianCnic = '';

    try {
      final patientData =
          Hive.box(LocalStorageService.patientsBox).get(patientId);
      if (patientData is Map) {
        final status = (patientData['status'] as String?)?.toLowerCase().trim() ?? 'zakat';
        patientName  = (patientData['name'] as String?)?.trim() ?? 'Unknown Patient';
        patientCnic  = (patientData['cnic'] as String?)?.trim() ?? '';
        guardianCnic = (patientData['guardianCnic'] as String?)?.trim() ?? '';

        if (status.contains('non-zakat') || status == 'non zakat') {
          queueType = 'non-zakat';
        } else if (status.contains('gmwf') || status == 'gm wf') {
          queueType = 'gmwf';
        }
      }
    } catch (e) {
      Logger().d('Could not fetch patient from Hive for $patientId: $e');
    }

    if (patientCnic.isEmpty &&
        guardianCnic.isEmpty &&
        patientName == 'Unknown Patient') {
      try {
        final patientDoc = await _db
            .collection('branches')
            .doc(branchId)
            .collection('patients')
            .doc(patientId)
            .get();

        if (patientDoc.exists) {
          final d      = patientDoc.data()!;
          patientName  = d['name']?.toString().trim() ?? 'Unknown Patient';
          patientCnic  = d['cnic']?.toString().trim() ?? '';
          guardianCnic = d['guardianCnic']?.toString().trim() ?? '';
        }
      } catch (e) {
        Logger().d('Firestore fallback for patient $patientId failed: $e');
      }
    }

    final data = {
      'serial':       serial,
      'patientId':    patientId,
      'patientName':  patientName,
      'patientCnic':  patientCnic,
      'guardianCnic': guardianCnic,
      'branchId':     branchId,
      'vitals':       vitals,
      'dateKey':      dateKey,
      'queueType':    queueType,
      'timestamp':    now.toIso8601String(),
      'createdAt':    now.toIso8601String(),
      'status':       'waiting',
    };

    Logger().d('Saving entry locally → Serial: $serial | Patient: $patientName | CNIC: $patientCnic | Guardian CNIC: $guardianCnic');

    await LocalStorageService.saveEntryLocal(branchId, serial, data);

    RealtimeManager().sendMessage(
      RealtimeEvents.payload(
        type: RealtimeEvents.saveEntry,
        data: {
          'branchId':  branchId,
          'datePart':  dateKey,
          'queueType': queueType,
          'serial':    serial,
          'data':      data,
        },
      ),
    );

    await LocalStorageService.enqueueSync({
      'type':      'save_entry',
      'branchId':  branchId,
      'dateKey':   dateKey,
      'queueType': queueType,
      'serial':    serial,
      'data':      data,
    });

    Logger().d("Entry enqueued → serial: $serial | queue size: ${Hive.box(LocalStorageService.syncBox).length}");

    SyncService().triggerUpload();
    Logger().d("triggerUpload called after entry enqueue");
  }

  Future<String> _generateNextSerial(String branchId, String dateKey) async {
    final localEntries = LocalStorageService.getLocalEntries(branchId)
        .where((e) => (e['dateKey'] as String?) == dateKey);
    int maxSeq = 0;
    for (final e in localEntries) {
      final serial = (e['serial'] ?? e['id'] ?? '').toString();
      final seq = parseSequenceFromSerial(serial);
      if (seq < 999999 && seq > maxSeq) {
        maxSeq = seq;
      }
    }
    final nextNumber = maxSeq + 1;
    return '$dateKey-${nextNumber.toString().padLeft(3, '0')}';
  }

  // ── User / patient / token helpers (unchanged) ────────────────────────────

  Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    if (!await _isFirestoreAvailable()) {
      return LocalStorageService.getLocalUserByEmail(email);
    }

    final q = await _db
        .collection('users')
        .where('email', isEqualTo: email.trim().toLowerCase())
        .limit(1)
        .get();

    if (q.docs.isEmpty) return null;

    final data = q.docs.first.data();
    if (data['createdAt'] is Timestamp) data['createdAt'] = _toDateTime(data['createdAt']);
    if (data['updatedAt'] is Timestamp) data['updatedAt'] = _toDateTime(data['updatedAt']);
    return data;
  }

  Future<Map<String, dynamic>?> getPatientByCnic(String cnic) async {
    if (cnic.trim().isEmpty) return null;

    if (!await _isFirestoreAvailable()) {
      return LocalStorageService.getLocalPatientByCnic(cnic);
    }

    final doc = await _db.collection('patients').doc(cnic).get();
    if (!doc.exists) return null;

    final data = doc.data()!;
    if (data['dob'] != null) data['dob'] = _toDateTime(data['dob']);
    return data;
  }

  Stream<List<Map<String, dynamic>>> streamPatientsByBranch(String branchId) async* {
    yield LocalStorageService.getAllLocalPatients(branchId: branchId);
  }

  Future<List<Patient>> getAllPatientsForBranch(String branchId) async {
    if (!await _isFirestoreAvailable()) {
      return LocalStorageService.getAllLocalPatients(branchId: branchId)
          .map((map) => Patient.fromMap(map))
          .toList();
    }

    final snapshot = await _db
        .collection('branches')
        .doc(branchId)
        .collection('patients')
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      if (data['dob'] != null) data['dob'] = _toDateTime(data['dob']);
      return Patient.fromMap(data);
    }).toList();
  }

  Future<List<Token>> getTodayTokensForBranch(String branchId) async {
    final String todayKey = DateFormat('ddMMyy').format(DateTime.now());

    if (!await _isFirestoreAvailable()) {
      return LocalStorageService.getLocalEntries(branchId)
          .where((e) => (e['dateKey'] as String?) == todayKey)
          .map((map) => Token.fromMap(map))
          .toList();
    }

    final snapshot = await _db
        .collection('branches')
        .doc(branchId)
        .collection('serials')
        .doc(todayKey)
        .collection('zakat')
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      if (data['timestamp'] != null) data['timestamp'] = _toDateTime(data['timestamp']);
      return Token.fromMap(data);
    }).toList();
  }

  Stream<List<Map<String, dynamic>>> streamEntriesByBranch(String branchId) async* {
    yield LocalStorageService.getLocalEntries(branchId);
  }

  Future<void> savePrescription({
    required String branchId,
    required Map<String, dynamic> prescriptionData,
  }) async {
    final id = prescriptionData['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      Logger().d('ERROR: Cannot save prescription — missing or empty ID');
      return;
    }

    final sanitized = LocalStorageService.sanitize(prescriptionData);

    Logger().d('Saving prescription locally → ID: $id');

    await LocalStorageService.saveLocalPrescription(sanitized);

    final serial = id.trim().toUpperCase();
    final existingEntry = LocalStorageService.getLocalEntry(branchId, serial);
    if (existingEntry != null && existingEntry['dispenseStatus'] != null && sanitized['dispenseStatus'] == null) {
      sanitized['dispenseStatus'] = existingEntry['dispenseStatus'];
    }

    RealtimeManager().sendMessage(
      RealtimeEvents.payload(
        type: RealtimeEvents.savePrescription,
        data: {
          'branchId': branchId,
          'serial':   id,
          'data':     sanitized,
        },
      ),
    );

    if (LanFirestoreGate.isLanDesk) return;

    await LocalStorageService.enqueueSync({
      'type':     'save_prescription',
      'branchId': branchId,
      'serial':   id,
      'data':     sanitized,
    });

    Logger().d('Prescription enqueued ⇒ ID: $id');

    SyncService().triggerUpload();
  }
}
