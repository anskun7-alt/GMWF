// lib/realtime/server_sync_manager.dart
//
// [ARCH DECISION] This ServerSyncManager is dead code as of 2026-08-27 (only its static initHive helper is called at startup).
// The live ServerSyncManager is embedded in lib/pages/server.dart (Server Dashboard).
//
// FULLY UPDATED — Deduplication, User Attribution, Failed Box & Complete Downloads
//
// EXISTING (preserved):
//
//   [USER-TRACK] Full user identity captured per message.
//     - _connectedUsers map tracks {username, role, branchId, clientId}
//       for every identified socket.
//     - Every _interceptMessage() call resolves the performer:
//         primary:  _senderUsername from enriched message
//         fallback: stored connection identity from _connectedUsers
//         last:     'unknown_<clientId>'
//     - All save operations (_saveEntry, _savePrescription, _saveDispense,
//       _savePatient, _saveDispensaryRecord) embed:
//           performedBy, performedByRole, performedByClientId, performedAt
//     - _executeOp() writes these audit fields to Firestore.
//
//   [FAIL-BOX] Dead-letter box 'server_sync_failed'
//     - Operations that exhaust max attempts (5) are moved to the failed
//       box with failedAt, reason, originalKey metadata — instead of being
//       silently deleted.
//     - retryFailedBox() moves entries back to the main queue.
//     - Called automatically on every connectivity-restore event.
//
// NEW IN THIS REVISION:
//
//   [DOWNLOADS] All previously-stubbed download methods are now fully
//     implemented:
//       _downloadTodayTokens()     — fetches today's serials for all queue types
//       _downloadPatients()        — fetches all patients for the branch
//       _downloadInventory()       — fetches all inventory items
//       _downloadPrescriptions()   — fetches all CNIC-keyed prescriptions
//       _downloadTodayDispensary() — fetches today's dispensary records

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../services/local_storage_service.dart';
import '../services/camp_session_service.dart';
import 'lan_server.dart';
import 'realtime_events.dart';

// ── Lightweight user context record ───────────────────────────────────────────
class _UserContext {
  final String username;
  final String role;
  final String clientId;

  const _UserContext({
    required this.username,
    required this.role,
    required this.clientId,
  });

  Map<String, dynamic> toAuditMap() => {
    'performedBy':         username,
    'performedByRole':     role,
    'performedByClientId': clientId,
    'performedAt':         DateTime.now().toIso8601String(),
  };
}

class ServerSyncManager {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final ServerSyncManager _i = ServerSyncManager._();
  factory ServerSyncManager() => _i;
  ServerSyncManager._();

  // ── State ──────────────────────────────────────────────────────────────────
  LanServer? _server;
  String? _branchId;
  bool _running   = false;
  bool _uploading = false;

  Function(Map<String, dynamic>)? _prevOnMessage;
  Function(String socketId, Map<String, dynamic>)? _prevOnConnected;
  Function(String socketId)? _prevOnDisconnected;

  Timer? _syncTimer;
  Timer? _downloadTimer;
  Timer? _catchUpTimer;
  StreamSubscription? _connSub;

  final Map<String, Map<String, dynamic>> _pendingPrescriptions = {};

  // Per-client serial tracking
  final Map<String, Set<String>> _clientSeenSerials = {};
  static const int _maxSeenPerClient = 2000;

  // [USER-TRACK] Connected user identity by socketId
  final Map<String, _UserContext> _connectedUsers = {};

  static const _serverQueueBox  = 'server_sync_queue';
  static const _editRequestsBox = 'local_edit_requests';
  static const _failedBox       = 'server_sync_failed';

  final _db = FirebaseFirestore.instance;

  // ── Queue-type resolver ────────────────────────────────────────────────────
  static String resolveQueueType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'zakat';
    final s = raw.toLowerCase().trim();
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') return 'gmwf';
    if (s == 'zakat') return 'zakat';
    debugPrint('[SSM] ⚠️ Unknown queueType "$raw" — defaulting to zakat');
    return 'zakat';
  }

  static String _dateKeyFromSerial(String serial, String fallback) {
    if (serial.contains('-')) {
      final parts = serial.split('-');
      if (parts.isNotEmpty) {
        final part = parts[0].toUpperCase() == 'X'
            ? (parts.length > 1 ? parts[1] : '')
            : parts[0];
        if (part.length == 6 && int.tryParse(part) != null) return part;
      }
    }
    return fallback;
  }

  // ── Public API ─────────────────────────────────────────────────────────────
  Future<void> start({
    required LanServer server,
    required String branchId,
  }) async {
    final cleanBranch = branchId.toLowerCase().trim();

    if (_running && _branchId == cleanBranch && _server == server) {
      debugPrint('[SSM] Already running for branch $cleanBranch — skipping');
      return;
    }

    stop();

    _server   = server;
    _branchId = cleanBranch;
    _running  = true;
    _clientSeenSerials.clear();
    _connectedUsers.clear();

    debugPrint('╔══════════════════════════════════════════════════════╗');
    debugPrint('║  ServerSyncManager  STARTED  branch: $_branchId');
    debugPrint('╚══════════════════════════════════════════════════════╝');

    _prevOnMessage = server.onMessageReceived;
    server.onMessageReceived = (msg) {
      _interceptMessage(msg);
      _prevOnMessage?.call(msg);
    };

        _prevOnConnected = server.onClientConnected;
    server.onClientConnected = (socketId, info) {
      _clientSeenSerials[socketId] = {};

      // [USER-TRACK] Store identity for this socket as fallback source.
      final username = (info['username'] as String?)?.trim() ?? '';
      final role     = (info['role']     as String?)?.trim() ?? 'unknown';
      final clientId = (info['clientId'] as String?)?.trim() ?? socketId;
      _connectedUsers[socketId] = _UserContext(
        username: username.isNotEmpty ? username : role,
        role:     role,
        clientId: clientId,
      );

      _prevOnConnected?.call(socketId, info);

      // Refresh today's tokens from Firestore FIRST, then push catch-up.
      // Without this, catch-up only sees what was already sitting in this
      // server's local Hive cache, which can be stale for a reconnecting
      // client that needs exactly the records created during the gap.
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (!_running) return;
        await _downloadTodayTokens();
        if (_running) _pushCatchUpToSocket(socketId, info).ignore();
      });
    };

    _prevOnDisconnected = server.onClientDisconnected;
    server.onClientDisconnected = (socketId) {
      _clientSeenSerials.remove(socketId);
      _connectedUsers.remove(socketId);
      debugPrint('[SSM] Cleaned seen-set & user for disconnected: $socketId');
      _prevOnDisconnected?.call(socketId);
    };

    purgeDuplicateServerQueue().ignore();
    _uploadQueue().ignore();

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_running) _uploadQueue().ignore();
    });

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _running) {
        retryFailedBox();
        _uploadQueue().ignore();
      }
    });
  }

  void stop() {
    _running = false;
    _syncTimer?.cancel();
    _downloadTimer?.cancel();
    _catchUpTimer?.cancel();
    _connSub?.cancel();
    _clientSeenSerials.clear();
    _connectedUsers.clear();

    if (_server != null) {
      _server!.onMessageReceived    = _prevOnMessage;
      _server!.onClientConnected    = _prevOnConnected;
      _server!.onClientDisconnected = _prevOnDisconnected;
    }
    _prevOnMessage = _prevOnConnected = _prevOnDisconnected = null;
    _server = null;

    debugPrint('[SSM] Stopped');
  }

  static Future<void> initHive() async {
    await LocalStorageService.openBoxSafe(_serverQueueBox);
    await LocalStorageService.openBoxSafe(_editRequestsBox);
    await LocalStorageService.openBoxSafe(_failedBox);
  }


  // ── [FAIL-BOX] Move dead-letter entries back to main queue ─────────────────
  void retryFailedBox() {
    try {
      final failed = Hive.box(_failedBox);
      if (failed.isEmpty) return;

      final queue  = Hive.box(_serverQueueBox);
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      int moved    = 0;

      for (final key in failed.keys.toList()) {
        final raw = failed.get(key);
        if (raw is! Map) { failed.delete(key); continue; }

        final item = Map<String, dynamic>.from(raw);

        // Expire entries older than 24 h
        final tsStr = (item['createdAt'] ?? item['_failedAt'])?.toString();
        final ts    = tsStr != null ? DateTime.tryParse(tsStr) : null;
        if (ts != null && ts.isBefore(cutoff)) {
          failed.delete(key);
          debugPrint('[SSM] Expired failed entry: ${item['type']}');
          continue;
        }

        item.remove('_attempts');
        item.remove('_err');
        item.remove('_failedAt');
        item.remove('_originalKey');
        final newKey = 'ssync_retry_${DateTime.now().microsecondsSinceEpoch}';
        queue.put(newKey, LocalStorageService.sanitize(item));
        failed.delete(key);
        moved++;
      }

      if (moved > 0) {
        debugPrint('[SSM] ♻️ Moved $moved failed entries back to upload queue');
        _uploadQueue().ignore();
      }
    } catch (e) {
      debugPrint('[SSM] retryFailedBox error: $e');
    }
  }

  // ── Periodic Catch-up ─────────────────────────────────────────────────────
    void _periodicCatchUpAll() async {
    if (_server == null || _branchId == null || !_running) return;
    final clients = _server!.getConnectedClients();
    if (clients.isEmpty) return;

    await _downloadTodayTokens();
    if (!_running) return;

    debugPrint('[SSM] Periodic catch-up: pushing to ${clients.length} client(s)');
    for (final client in clients) {
      final socketId = client['socketId']?.toString();
      if (socketId == null || socketId.isEmpty) continue;
      _pushCatchUpToSocket(socketId, Map<String, dynamic>.from(client)).ignore();
    }
  }

  // ── Message Interception ───────────────────────────────────────────────────
  void _interceptMessage(Map<String, dynamic> msg) {
    if (_branchId == null || !_running) return;

    final type = msg['event_type']?.toString() ?? '';
    final data = (msg['data'] is Map)
        ? Map<String, dynamic>.from(msg['data'] as Map)
        : Map<String, dynamic>.from(msg);

    for (final field in ['queueType', 'dateKey', 'serial', 'branchId']) {
      if (!data.containsKey(field) && msg.containsKey(field)) {
        data[field] = msg[field];
      }
    }

    if (type == 'ack_serials') {
      _handleClientAck(msg);
      return;
    }

        if (type == 'request_catch_up') {
      final socketId = msg['_socketId']?.toString();
      final info = socketId == null
          ? null
          : _server?.getConnectedClients().cast<Map<String, dynamic>?>().firstWhere(
                (client) => client?['socketId']?.toString() == socketId,
                orElse: () => null,
              );
      if (socketId != null && info != null) {
        _downloadTodayTokens().then((_) {
          if (_running) _pushCatchUpToSocket(socketId, info);
        });
      }
      return;
    }

    if (type == 'force_all_users_cloud_sync') {
      debugPrint('[SSM] ☁️ Force Global Sync requested: immediately flushing upload queue...');
      _uploadQueue().ignore();
      return;
    }

    final user = _resolveUser(msg);
    debugPrint('[SSM] intercept: $type | serial=${data['serial']} | by=${user.username}');

    switch (type) {
      case 'save_entry':
      case 'token_created':
        _saveEntry(data, msg, user: user);
        _flushPendingPrescription(data['serial']?.toString().trim());
        break;

      case 'save_prescription':
      case 'prescription_created':
        _savePrescription(data, msg, user: user);
        _handlePrescriptionRestriction(data, msg);
        break;

      case 'dispense_completed':
        _saveDispense(data, msg, user: user);
        break;

      case 'save_patient':
        _savePatient(data, msg, user: user);
        break;

      case 'save_dispensary_record':
        _saveDispensaryRecord(data, msg, user: user);
        break;

      case 'save_stock_item':
        final medData = data['data'] is Map ? Map<String, dynamic>.from(data['data']) : data;
        final medicineId = data['medicineId']?.toString() ?? medData['id']?.toString() ?? medData['medicineId']?.toString() ?? medData['docId']?.toString();
        final delta = data['_quantityDelta'] ?? medData['_quantityDelta'];

        if (delta != null && medicineId != null) {
          final deltaVal = (delta is num)
              ? delta.toDouble()
              : double.tryParse(delta.toString()) ?? 0.0;

          if (deltaVal != 0) {
            debugPrint('[SSM] Intercepted stock addition for $medicineId delta=$deltaVal');
            // Update local Hive for immediate visual consistency on host
            final existing = LocalStorageService.getLocalInventoryItem(medicineId);
            if (existing != null) {
              LocalStorageService.updateLocalStockQuantity(medicineId, deltaVal);
            } else {
              LocalStorageService.saveLocalInventoryItem(medData);
            }

            // Enqueue for Firestore
            _enqueue({
              'type': 'add_inventory_stock',
              'branchId': data['branchId'] ?? _branchId,
              'medicineId': medicineId,
              'quantity': deltaVal,
              'performedBy': data['performedBy'] ?? user.clientId,
              'performedByName': data['performedByName'] ?? user.username,
              'logData': data['logData'] ?? msg['logData'],
              'createdAt': DateTime.now().toIso8601String(),
            });
          }
        } else if (medicineId != null) {
          debugPrint('[SSM] Intercepted new medicine registration: $medicineId');
          // Update local Hive
          LocalStorageService.saveLocalInventoryItem(medData);

          // Enqueue for Firestore
          _enqueue({
            'type': 'register_medicine',
            'branchId': data['branchId'] ?? _branchId,
            'medicineId': medicineId,
            'data': medData,
            'logData': data['logData'] ?? msg['logData'],
            'createdAt': DateTime.now().toIso8601String(),
          });
        }
        break;

      case RealtimeEvents.tokenExceptionRequest:
        _saveTokenExceptionRequest(data, msg, user: user);
        break;

      case RealtimeEvents.tokenExceptionApproved:
        _saveTokenExceptionApproval(data, msg, user: user);
        break;

      case RealtimeEvents.workflowRequest:
      case RealtimeEvents.workflowDecision:
        _saveWorkflowEvent(type, data, msg, user: user);
        break;

      // ── ATTENDANCE ────────────────────────────────────────────────────────
      case RealtimeEvents.saveBiometricLog:
      case RealtimeEvents.saveEmployeeAttendance:
      case RealtimeEvents.saveFacultyAttendance:
      case RealtimeEvents.saveStudentAttendance:
        _saveAttendance(type, data, msg, user: user);
        break;

      // ── MADRASSA & SCHOOL ──────────────────────────────────────────────────
      case RealtimeEvents.saveMadrassaAdmission:
      case RealtimeEvents.saveMadrassaStudent:
      case RealtimeEvents.saveMadrassaAttendance:
      case RealtimeEvents.saveMadrassaDailyLog:
      case RealtimeEvents.saveMadrassaFee:
      case RealtimeEvents.saveMadrassaFeePayment:
      case RealtimeEvents.saveMadrassaHifzProgress:
      case RealtimeEvents.saveExamResult:
        _saveMadrassa(type, data, msg, user: user);
        break;

      // ── FINANCE ───────────────────────────────────────────────────────────
      case RealtimeEvents.saveExpense:
      case RealtimeEvents.deleteExpense:
      case RealtimeEvents.saveLoan:
      case RealtimeEvents.deleteLoan:
      case RealtimeEvents.saveFinanceEntry:
        _saveFinance(type, data, msg, user: user);
        break;

      // ── DONATIONS ─────────────────────────────────────────────────────────
      case RealtimeEvents.saveDonationReceipt:
      case RealtimeEvents.saveDonor:
      case RealtimeEvents.saveDonationCollection:
        _saveDonation(type, data, msg, user: user);
        break;

      // ── DASTERKHWAAN ──────────────────────────────────────────────────────
      case RealtimeEvents.saveDasterkhwanEntry:
      case RealtimeEvents.saveDasterkhwanStock:
      case RealtimeEvents.saveOfficeBoyToken:
      case RealtimeEvents.saveKitchenServeLog:
        _saveDasterkhwan(type, data, msg, user: user);
        break;

      // ── SUPERVISOR ────────────────────────────────────────────────────────
      case RealtimeEvents.saveSupervisorAction:
      case RealtimeEvents.approveEditRequest:
      case RealtimeEvents.rejectEditRequest:
        _saveSupervisor(type, data, msg, user: user);
        break;

      // ── EMPLOYEES ─────────────────────────────────────────────────────────
      case RealtimeEvents.saveEmployee:
        _saveEmployee(data, msg, user: user);
        break;

      case RealtimeEvents.deleteEmployee:
        _deleteEmployee(data, msg, user: user);
        break;
    }
  }

  // ── [USER-TRACK] Resolve user context from message ─────────────────────────
  _UserContext _resolveUser(Map<String, dynamic> msg) {
    final username = (msg['_senderUsername'] as String?)?.trim() ??
                     (msg['_username']       as String?)?.trim();
    final role     = (msg['_senderRole']   as String?)?.trim() ?? 'unknown';
    final clientId = (msg['_clientId']     as String?)?.trim() ?? '';
    final socketId = (msg['_socketId']     as String?)?.trim() ?? '';

    if (username != null && username.isNotEmpty) {
      return _UserContext(username: username, role: role, clientId: clientId);
    }

    if (socketId.isNotEmpty && _connectedUsers.containsKey(socketId)) {
      return _connectedUsers[socketId]!;
    }

    final fallbackUsername = role != 'unknown' ? role : 'unknown_$clientId';
    debugPrint('[SSM] ⚠️ Username not found for socket=$socketId, using: $fallbackUsername');
    return _UserContext(
      username: fallbackUsername,
      role:     role,
      clientId: clientId,
    );
  }

  void _handleClientAck(Map<String, dynamic> msg) {
    final socketId = (msg['_socketId'] ?? msg['_clientId'] ?? '').toString();
    final serials  = msg['serials'];
    if (socketId.isEmpty || serials is! List) return;

    _clientSeenSerials[socketId] ??= {};
    for (final s in serials) {
      final serial = s?.toString().trim() ?? '';
      if (serial.isNotEmpty) _clientSeenSerials[socketId]!.add(serial);
    }

    final seen = _clientSeenSerials[socketId]!;
    if (seen.length > _maxSeenPerClient) {
      final overflow = seen.length - _maxSeenPerClient;
      seen.removeAll(seen.take(overflow).toList());
    }
  }

  void _flushPendingPrescription(String? serial) {
    if (serial == null || serial.isEmpty) return;
    final pending = _pendingPrescriptions.remove(serial);
    if (pending != null) {
      _savePrescription(pending, pending);
    }
  }

  // ── Save Methods ───────────────────────────────────────────────────────────

  void _saveEntry(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final serial   = data['serial']?.toString().trim();
    if (serial == null || serial.isEmpty) return;
    final dateKey   = data['dateKey']?.toString() ??
        _dateKeyFromSerial(serial, _todayKey());
    final queueType = resolveQueueType(
        (data['queueType'] ?? full['queueType'])?.toString());

    final entry = <String, dynamic>{
      'serial':      serial,
      'branchId':    branchId,
      'queueType':   queueType,
      'patientId':   data['patientId']   ?? '',
      'patientName': data['patientName'] ?? data['name'] ?? 'Unknown',
      'patientCnic': data['patientCnic'] ?? data['cnic'] ?? '',
      'createdAt':   data['createdAt']   ?? data['time'] ?? data['timestamp'] ?? DateTime.now().toIso8601String(),
      'status':      data['status']      ?? 'waiting',
      'dateKey':     dateKey,
      if (data['session'] != null) 'session': data['session'],
      if (data['shift'] != null) 'shift': data['shift'],
      if (data['createdBy'] != null) 'createdBy': data['createdBy'],
      if (data['createdByName'] != null) 'createdByName': data['createdByName'],
    };

    data.forEach((k, v) {
      if (!entry.containsKey(k) && v != null) entry[k] = v;
    });

    if (user != null) {
      final audit = user.toAuditMap();
      audit.forEach((k, v) {
        if (!entry.containsKey(k) && v != null) entry[k] = v;
      });
    }

    LocalStorageService.saveEntryLocal(branchId, serial, entry);
    _enqueue({
      'type':      'save_entry',
      'branchId':  branchId,
      'dateKey':   dateKey,
      'queueType': queueType,
      'serial':    serial,
      'data':      entry,
    });
  }

  void _savePrescription(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final serial   = (data['serial'] ?? data['id'])?.toString().trim();
    if (serial == null || serial.isEmpty) return;
    final prescWithBranch = {
      ...data,
      'branchId': branchId,
      'serial':   serial,
      ...?user?.toAuditMap(),
    };

    LocalStorageService.saveLocalPrescription(prescWithBranch);
    LocalStorageService.saveLocalPrescription({...prescWithBranch, 'serial': serial});

    final normBranch = branchId.toLowerCase().trim();
    final normSerial = serial.toUpperCase();
    final canonicalKey = '$normBranch-$normSerial';
    final box      = Hive.box(LocalStorageService.entriesBox);

    Map<String, dynamic>? existing;
    final direct = box.get(canonicalKey) ?? box.get('$branchId-$serial') ?? box.get(serial);
    if (direct is Map) {
      existing = Map<String, dynamic>.from(direct);
    } else {
      for (final k in box.keys) {
        final kStr = k.toString().toUpperCase();
        if (kStr == normSerial || kStr.endsWith('-$normSerial')) {
          final val = box.get(k);
          if (val is Map) {
            existing = Map<String, dynamic>.from(val);
            break;
          }
        }
      }
    }

    if (existing != null) {
      final upd = Map<String, dynamic>.from(existing);
      upd['status']      = 'completed';
      upd['completedAt'] = data['completedAt'] ?? DateTime.now().toIso8601String();
      upd['prescription'] = prescWithBranch;
      if (data['doctorName'] != null) upd['doctorName'] = data['doctorName'];
      if (data['doctorId'] != null) upd['doctorId'] = data['doctorId'];
      if (data['daysOfMedicine'] != null) upd['daysOfMedicine'] = data['daysOfMedicine'];
      if (user != null) {
        final audit = user.toAuditMap();
        audit.forEach((k, v) {
          if (k != 'createdBy' && k != 'createdByName' && k != 'receptionistId' && k != 'receptionistName') {
            upd[k] = v;
          }
        });
      }
      box.put(canonicalKey, upd);
      if (box.containsKey('$branchId-$serial') && canonicalKey != '$branchId-$serial') {
        box.delete('$branchId-$serial');
      }
      if (box.containsKey(serial)) {
        box.delete(serial);
      }
    } else {
      _pendingPrescriptions[serial] = data;
    }

    final cnic = _cleanCnic(
      data['patientCnic']?.toString() ??
          data['cnic']?.toString() ??
          'unknown_$serial',
    );

    final queueType = resolveQueueType(
        (existing?['queueType'] ?? data['queueType'])?.toString());
    final dateKey   = existing?['dateKey']?.toString() ??
        _dateKeyFromSerial(serial, _todayKey());

    _enqueue({
      'type':     'save_prescription',
      'branchId': branchId,
      'cnic':     cnic,
      'serial':   serial,
      'data':     prescWithBranch,
    });

    _enqueue({
      'type':      'update_serial_status',
      'branchId':  branchId,
      'serial':    serial,
      'queueType': queueType,
      'dateKey':   dateKey,
      'data': {
        'status':      'completed',
        'completedAt': data['completedAt'] ?? DateTime.now().toIso8601String(),
        ...?user?.toAuditMap(),
      },
    });
  }

  void _saveDispense(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final serial   = data['serial']?.toString().trim();
    if (serial == null || serial.isEmpty) return;

    final now    = DateTime.now().toIso8601String();
    final update = {
      'dispenseStatus': 'dispensed',
      'status':         'completed',
      'dispensedAt':    data['dispensedAt'] ?? now,
      'dispensedBy':    data['dispensedBy'] ?? user?.username ?? '',
      'completedAt':    data['completedAt'] ?? now,
      ...?user?.toAuditMap(),
    };

    LocalStorageService.updateLocalEntryField(branchId, serial, update);
    debugPrint('[SSM] ✅ dispense saved: $branchId-$serial by ${user?.username}');

    final entryKey  = '$branchId-$serial';
    final box       = Hive.box(LocalStorageService.entriesBox);
    final existing  = box.get(entryKey);

    final rawQT     = (existing?['queueType'] ?? data['queueType'])?.toString();
    final queueType = resolveQueueType(rawQT);
    final dateKey   = existing?['dateKey']?.toString() ??
        _dateKeyFromSerial(serial, _todayKey());

    _enqueue({
      'type':      'update_serial_status',
      'branchId':  branchId,
      'serial':    serial,
      'queueType': queueType,
      'dateKey':   dateKey,
      'data':      update,
    });

  }

  void _maybeDeductInventoryFromRemote(
      String branchId, String serial, Map<String, dynamic> data) {
    if (data['_serverPush'] == true) return;
    _deductInventory(branchId, serial, data);
  }

  void _deductInventory(
      String branchId, String serial, Map<String, dynamic> data) {
    try {
      final medicines = data['medicines'] as List? ?? [];
      for (final med in medicines) {
        if (med is! Map) continue;
        final medMap     = Map<String, dynamic>.from(med);
        final medicineId =
            (medMap['medicineId'] ?? medMap['id'] ?? '').toString().trim();
        final qtyNum = (medMap['quantity'] ?? medMap['qty'] ?? 0) as num;

        if (medicineId.isEmpty || qtyNum <= 0) continue;

        _enqueue({
          'type':       'update_inventory',
          'branchId':   branchId,
          'medicineId': medicineId,
          'delta':      -qtyNum.toDouble(),
          'serial':     serial,
          'data': {
            'medicineId': medicineId,
            'delta':      -qtyNum.toDouble(),
            'serial':     serial,
          },
        });
      }
    } catch (e) {
      debugPrint('[SSM] _deductInventory error: $e');
    }
  }

  void _savePatient(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final p = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'])
        : data;
    final patientData = {
      ...p,
      'branchId': _branchId,
      ...?user?.toAuditMap(),
    };
    LocalStorageService.saveLocalPatient(patientData, isFromSync: true);
  }

  void _saveWorkflowEvent(
    String eventType,
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final requestId = (data['requestId'] ?? data['id'])?.toString().trim();
    if (requestId == null || requestId.isEmpty) return;

    final request = <String, dynamic>{
      ...data,
      'requestId': requestId,
      'branchId': _field(data, full, 'branchId') ?? _branchId,
      'eventType': eventType,
      'updatedAt': DateTime.now().toIso8601String(),
      ...?user?.toAuditMap(),
    };
    final box = Hive.box(_editRequestsBox);
    box.put(requestId, LocalStorageService.sanitize(request));
    _enqueue({
      'type': 'workflow_request',
      'branchId': request['branchId'],
      'requestId': requestId,
      'data': request,
    });
  }

  void _saveDispensaryRecord(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final serial   = data['serial']?.toString().trim();
    final dateKey  = data['dateKey']?.toString() ?? _todayKey();
    if (serial == null || serial.isEmpty) return;

    final record = {
      ...data,
      'branchId': branchId,
      'dateKey':  dateKey,
      ...?user?.toAuditMap(),
    };
    LocalStorageService.saveLocalDispensaryRecord(record);

    _enqueue({
      'type':     'save_dispensary_record',
      'branchId': branchId,
      'dateKey':  dateKey,
      'serial':   serial,
      'data':     record,
    });
  }

  void _saveAttendance(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final id = data['id']?.toString() ?? data['punchId']?.toString() ?? 'att_${DateTime.now().microsecondsSinceEpoch}';
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': 'save_attendance',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveMadrassa(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final String id;
    if (eventType == RealtimeEvents.saveMadrassaDailyLog || eventType == RealtimeEvents.saveMadrassaAttendance) {
      id = (data['dateKey'] ?? data['date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now())).toString();
    } else if (eventType == RealtimeEvents.saveMadrassaStudent || eventType == RealtimeEvents.saveMadrassaAdmission) {
      id = (data['studentId'] ?? data['id'] ?? 'stu_${DateTime.now().microsecondsSinceEpoch}').toString();
    } else if (eventType == RealtimeEvents.saveMadrassaFeePayment) {
      id = (data['id'] ?? '${data['year']}_${data['month']}_${data['studentId']}').toString();
    } else {
      id = data['id']?.toString() ?? data['receiptNo']?.toString() ?? data['admissionNo']?.toString() ?? 'mad_${DateTime.now().microsecondsSinceEpoch}';
    }
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': 'save_madrassa',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveFinance(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final id = data['id']?.toString() ?? 'fin_${DateTime.now().microsecondsSinceEpoch}';
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': eventType.contains('delete') ? 'delete_finance' : 'save_finance',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveDonation(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final id = data['id']?.toString() ?? data['receiptNumber']?.toString() ?? 'don_${DateTime.now().microsecondsSinceEpoch}';
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': 'save_donation',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveDasterkhwan(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final id = data['id']?.toString() ?? 'das_${DateTime.now().microsecondsSinceEpoch}';
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': 'save_dasterkhwan',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveSupervisor(String eventType, Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final id = data['requestId']?.toString() ?? data['id']?.toString() ?? 'sup_${DateTime.now().microsecondsSinceEpoch}';
    final rec = {...data, 'branchId': branchId, ...?user?.toAuditMap()};
    _enqueue({
      'type': 'save_supervisor',
      'subType': eventType,
      'branchId': branchId,
      'docId': id,
      'data': rec,
    });
  }

  void _saveEmployee(Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final localId = data['localId']?.toString() ?? data['id']?.toString() ?? '';
    if (localId.isEmpty) return;

    final rec = {...data, 'branchId': branchId, 'localId': localId, ...?user?.toAuditMap()};

    // Update local Hive box on host
    try {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final box = Hive.box(LocalStorageService.employeesBox);
        final existing = box.get(localId);
        final merged = existing is Map ? (Map<String, dynamic>.from(existing)..addAll(rec)) : rec;
        merged['syncStatus'] = 'synced';
        box.put(localId, LocalStorageService.sanitize(merged));
      }
    } catch (_) {}

    _enqueue({
      'type': 'save_employee',
      'branchId': branchId,
      'localId': localId,
      'data': rec,
    });
  }

  void _deleteEmployee(Map<String, dynamic> data, Map<String, dynamic> full, {_UserContext? user}) {
    final branchId = _field(data, full, 'branchId') ?? _branchId!;
    final localId = data['localId']?.toString() ?? data['id']?.toString() ?? '';
    if (localId.isEmpty) return;

    try {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        Hive.box(LocalStorageService.employeesBox).delete(localId);
      }
    } catch (_) {}

    _enqueue({
      'type': 'delete_employee',
      'branchId': branchId,
      'localId': localId,
    });
  }

  // ── Catch-up Push ─────────────────────────────────────────────────────────
  Future<void> _pushCatchUpToSocket(
      String socketId, Map<String, dynamic> info) async {
    if (_server == null || _branchId == null || !_running) return;

    final role = (info['role'] ?? '').toString().toLowerCase();
    if (role == 'receptionist') return;

    final today   = CampSessionService.resolveShiftAndDateKey().dateKey;
    final entries = LocalStorageService.getLocalEntries(_branchId!)
        .where((e) {
          final dk = (e['dateKey'] ?? '').toString().trim();
          final serial = (e['serial'] ?? '').toString().trim();
          final serialDk = _dateKeyFromSerial(serial, '');
          return dk == today || serialDk == today;
        })
        .toList();

    final clientSeen = _clientSeenSerials[socketId] ?? <String>{};
    final unseen = entries.where((e) {
      final serial = e['serial']?.toString().trim() ?? '';
      return serial.isNotEmpty && !clientSeen.contains(serial);
    }).toList();

    if (unseen.isEmpty) return;

    debugPrint('[SSM] Catch-up to $role ($socketId): ${unseen.length} unseen');

    for (final entry in unseen) {
      if (!_running || _server == null) break;

      final serial = entry['serial']?.toString() ?? '';
      if (serial.isEmpty) continue;

      final entryCopy = Map<String, dynamic>.from(entry);
      final presc = LocalStorageService.getLocalPrescription(serial) ??
          entry['prescription'] as Map<String, dynamic>?;
      if (presc != null && presc.isNotEmpty) {
        entryCopy['status'] = 'completed';
        entryCopy['prescription'] = presc;
        entryCopy['prescriptionId'] = presc['id'] ?? serial;
      }
      if ((entry['dispenseStatus'] ?? '') == 'dispensed') {
        entryCopy['status'] = 'completed';
        entryCopy['dispenseStatus'] = 'dispensed';
      }

      _sendToSocket(socketId, {
        'event_type':  'save_entry',
        'branchId':    _branchId,
        'data':        entryCopy,
        '_serverPush': true,
        'isCatchUp':   true,
        '_isReplay':   true,
      });

      if (presc != null && presc.isNotEmpty) {
        _sendToSocket(socketId, {
          'event_type':  'save_prescription',
          'branchId':    _branchId,
          'data':        presc,
          '_serverPush': true,
          'isCatchUp':   true,
          '_isReplay':   true,
        });
      }

      if ((entryCopy['dispenseStatus'] ?? '') == 'dispensed') {
        _sendToSocket(socketId, {
          'event_type':  'dispense_completed',
          'branchId':    _branchId,
          'data':        entryCopy,
          '_serverPush': true,
          'isCatchUp':   true,
          '_isReplay':   true,
        });
      }

      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  bool _sendToSocket(String socketId, Map<String, dynamic> payload) {
    try {
      return _server?.sendToSocket(socketId, jsonEncode(payload)) ?? false;
    } catch (e) {
      debugPrint('[SSM] sendToSocket failed: $e');
      return false;
    }
  }

  // ── Upload Queue ───────────────────────────────────────────────────────────
  // ── Upload Queue ───────────────────────────────────────────────────────────
  static Future<int> purgeDuplicateServerQueue() async {
    try {
      if (!Hive.isBoxOpen(_serverQueueBox)) return 0;
      final box = Hive.box(_serverQueueBox);
      final initialCount = box.length;
      if (initialCount <= 1) return 0;

      final Map<String, dynamic> uniqueLatest = {};
      final List<dynamic> keysToDelete = [];

      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null || raw is! Map) {
          keysToDelete.add(key);
          continue;
        }
        final item = Map<String, dynamic>.from(raw);
        final type = (item['type'] ?? '').toString();
        final serial = (item['serial'] ?? item['data']?['serial'] ?? '').toString();
        final patientId = (item['patientId'] ?? item['data']?['patientId'] ?? item['id'] ?? '').toString();
        final medicineId = (item['medicineId'] ?? '').toString();
        final empId = (item['employeeId'] ?? item['data']?['employeeId'] ?? '').toString();
        final docId = (item['docId'] ?? item['data']?['id'] ?? '').toString();
        final dateKey = (item['dateKey'] ?? item['date'] ?? item['data']?['dateKey'] ?? item['data']?['date'] ?? '').toString();

        final uniqueKey = '${type}_${serial}_${patientId}_${medicineId}_${empId}_${docId}_${dateKey}';
        if (uniqueKey.replaceAll('_', '').isEmpty) continue;

        if (uniqueLatest.containsKey(uniqueKey)) {
          final existingKey = uniqueLatest[uniqueKey]['_boxKey'];
          keysToDelete.add(existingKey);
        }
        uniqueLatest[uniqueKey] = {...item, '_boxKey': key};
      }

      for (final key in keysToDelete) {
        await box.delete(key);
      }
      final purged = initialCount - box.length;
      if (purged > 0) {
        debugPrint('[SSM] 🧹 Purged $purged redundant duplicate server queue items. Remaining: ${box.length}');
      }
      return purged;
    } catch (e) {
      debugPrint('[SSM] Error purging duplicate server queue: $e');
      return 0;
    }
  }

  void _enqueue(Map<String, dynamic> op) {
    try {
      final box = Hive.box(_serverQueueBox);
      final opCopy = Map<String, dynamic>.from(op);
      final type = (opCopy['type'] ?? 'unknown').toString();
      final serial = (opCopy['serial'] ?? opCopy['data']?['serial'] ?? '').toString();
      final patientId = (opCopy['patientId'] ?? opCopy['data']?['patientId'] ?? opCopy['id'] ?? '').toString();
      final medicineId = (opCopy['medicineId'] ?? '').toString();
      final empId = (opCopy['employeeId'] ?? opCopy['data']?['employeeId'] ?? '').toString();
      final docId = (opCopy['docId'] ?? opCopy['data']?['id'] ?? '').toString();
      final dateKey = (opCopy['dateKey'] ?? opCopy['date'] ?? opCopy['data']?['dateKey'] ?? opCopy['data']?['date'] ?? '').toString();

      final targetUniqueKey = '${type}_${serial}_${patientId}_${medicineId}_${empId}_${docId}_${dateKey}';
      
      // Deterministic key for instant O(1) deduplication without scanning the box
      final String key = targetUniqueKey.replaceAll('_', '').isNotEmpty
          ? 'ssync_${type}_${serial}_${patientId}_${medicineId}_${empId}_${docId}_${dateKey}'
          : 'ssync_${DateTime.now().microsecondsSinceEpoch}';

      opCopy['createdAt'] = DateTime.now().toIso8601String();
      box.put(key, LocalStorageService.sanitize(opCopy));
    } catch (e) {
      debugPrint('[SSM] _enqueue failed: $e');
    }
  }

  Future<void> _uploadQueue() async {
    if (_uploading || !_running) return;

    final conn = await Connectivity().checkConnectivity();
    if (conn.every((r) => r == ConnectivityResult.none)) return;

    _uploading = true;
    try {
      final box  = Hive.box(_serverQueueBox);
      final keys = box.keys.take(100).toList();

      for (final key in keys) {
        if (!_running) break;

        final raw = box.get(key);
        if (raw == null || raw is! Map) {
          box.delete(key);
          continue;
        }

        final op       = Map<String, dynamic>.from(raw);
        final attempts = (op['_attempts'] as int?) ?? 0;

        // Token and prescription writes are durable until Firestore accepts
        // them. Quota exhaustion must never remove a LAN-delivered record.
        if (attempts >= 5) {
          final type = op['type']?.toString() ?? '';
          if (type == 'save_entry' || type == 'save_prescription' ||
              type == 'update_serial_status') {
            op['_attempts'] = 0;
            await box.put(key, op);
          } else {
            _moveToFailedBox(key, op, reason: op['_err']?.toString() ?? 'max attempts');
            box.delete(key);
          }
          continue;
        }

        try {
          await _executeOp(op);
          box.delete(key);
        } catch (e) {
          op['_attempts'] = attempts + 1;
          op['_err']      =
              e.toString().substring(0, e.toString().length.clamp(0, 200));
          await box.put(key, op);
        }

        await Future.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      _uploading = false;
    }
  }

  // ── [FAIL-BOX] Move op to dead-letter box ─────────────────────────────────
  void _moveToFailedBox(dynamic originalKey, Map<String, dynamic> op,
      {String? reason}) {
    try {
      final failed    = Hive.box(_failedBox);
      final failedKey = 'failed_${DateTime.now().microsecondsSinceEpoch}';
      final entry     = Map<String, dynamic>.from(op);
      entry['_failedAt']    = DateTime.now().toIso8601String();
      entry['_failReason']  =
          reason?.substring(0, reason.length.clamp(0, 300));
      entry['_originalKey'] = originalKey?.toString();
      failed.put(failedKey, LocalStorageService.sanitize(entry));

      debugPrint('[SSM] ⚠️ Op moved to failed box: ${op['type']} '
          'serial=${op['serial']} key=$failedKey');
    } catch (e) {
      debugPrint('[SSM] _moveToFailedBox error: $e');
    }
  }

  // ── Execute Op ────────────────────────────────────────────────────────────
  Future<void> _executeOp(Map<String, dynamic> op) async {
    final type      = op['type']?.toString() ?? '';
    final branchId  = (op['branchId'] ?? _branchId!).toString();
    final data      = Map<String, dynamic>.from(op['data'] ?? {});
    final cleanData = LocalStorageService.sanitize(data);

    switch (type) {
      case 'save_entry':
        final dateKey = (op['dateKey'] ?? cleanData['dateKey'])?.toString();
        final serial  = op['serial']?.toString();
        if (dateKey == null || serial == null) return;

        final queueType = resolveQueueType(
            (op['queueType'] ?? cleanData['queueType'])?.toString());

        final upperSerial = serial.trim().toUpperCase();
        cleanData['serial'] = upperSerial;
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: branchId,
          dateKey: dateKey,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: upperSerial,
        );

        await _db
            .collection('branches').doc(branchId)
            .collection('serials').doc(campDocKey)
            .collection(queueType).doc(upperSerial)
            .set(cleanData, SetOptions(merge: true));

        if (serial != upperSerial) {
          try {
            await _db
                .collection('branches').doc(branchId)
                .collection('serials').doc(campDocKey)
                .collection(queueType).doc(serial.toLowerCase())
                .delete();
          } catch (_) {}
        }

        final num = int.tryParse(upperSerial.split('-').last);
        if (num != null) {
          await _db
              .collection('branches').doc(branchId)
              .collection('serials').doc(campDocKey)
              .set({'lastSerialNumber': num}, SetOptions(merge: true));
        }
        break;

      case 'save_prescription':
        final serial = op['serial']?.toString();
        if (serial == null) return;
        final upperSerial = serial.trim().toUpperCase();
        cleanData['serial'] = upperSerial;

        String? rawQT   = (op['queueType'] ?? data['queueType'])?.toString();
        String? dateKey = (op['dateKey']   ?? data['dateKey'])?.toString();

        Map<String, dynamic>? local;
        if (rawQT == null || dateKey == null) {
          local = LocalStorageService.getLocalEntry(branchId, serial);
          rawQT   ??= local?['queueType']?.toString();
          dateKey ??= local?['dateKey']?.toString() ?? _todayKey();
        }
        final queueType = resolveQueueType(rawQT);
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: branchId,
          dateKey: dateKey,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString() ?? local?['campId']?.toString() ?? local?['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString() ?? local?['dispensaryTag']?.toString(),
          serial: upperSerial,
        );

        final updateMap = <String, dynamic>{
          'status':         'completed',
          'completedAt':    cleanData['completedAt'] ?? DateTime.now().toIso8601String(),
          'dispenseStatus': cleanData['dispenseStatus'] ?? 'pending',
        };
        for (final f in ['doctorName', 'doctorId', 'daysOfMedicine', 'extraCharge', 'vitals', 'prescription', 'medicines', 'diagnosis', 'complaints']) {
          if (cleanData.containsKey(f) && cleanData[f] != null) {
            updateMap[f] = cleanData[f];
          }
        }

        await _db
            .collection('branches').doc(branchId)
            .collection('serials').doc(campDocKey)
            .collection(queueType).doc(upperSerial)
            .set(updateMap, SetOptions(merge: true));

        // Delete any legacy standalone prescription doc if present
        try {
          final cnic = (op['cnic'] ?? _cleanCnic(cleanData['patientCnic']?.toString() ?? '')).toString();
          if (cnic.isNotEmpty) {
            await _db.collection('branches').doc(branchId)
                .collection('prescriptions').doc(cnic)
                .collection('prescriptions').doc(serial).delete();
          }
        } catch (_) {}

        _handlePrescriptionRestriction(cleanData, op);
        break;

      case 'update_serial_status':
        final serial = op['serial']?.toString();
        if (serial == null) return;

        String? rawQT   = (op['queueType'] ?? data['queueType'])?.toString();
        String? dateKey = (op['dateKey']   ?? data['dateKey'])?.toString();

        Map<String, dynamic>? local;
        if (rawQT == null || dateKey == null) {
          local = LocalStorageService.getLocalEntry(branchId, serial);
          rawQT   ??= local?['queueType']?.toString();
          dateKey ??= local?['dateKey']?.toString() ?? _todayKey();
        }

        final upperSerial = serial.trim().toUpperCase();
        cleanData['serial'] = upperSerial;
        final queueType = resolveQueueType(rawQT);
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: branchId,
          dateKey: dateKey,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString() ?? local?['campId']?.toString() ?? local?['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString() ?? local?['dispensaryTag']?.toString(),
          serial: upperSerial,
        );

        await _db
            .collection('branches').doc(branchId)
            .collection('serials').doc(campDocKey)
            .collection(queueType).doc(upperSerial)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'save_dispensary_record':
        final serial = op['serial']?.toString();
        if (serial == null) return;
        final upperSerial = serial.trim().toUpperCase();
        cleanData['serial'] = upperSerial;

        String? rawQT   = (op['queueType'] ?? data['queueType'])?.toString();
        String? dateKey = (op['dateKey']   ?? data['dateKey'])?.toString();

        Map<String, dynamic>? local;
        if (rawQT == null || dateKey == null) {
          local = LocalStorageService.getLocalEntry(branchId, serial);
          rawQT   ??= local?['queueType']?.toString();
          dateKey ??= local?['dateKey']?.toString() ?? _todayKey();
        }
        final queueType = resolveQueueType(rawQT);
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: branchId,
          dateKey: dateKey,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString() ?? local?['campId']?.toString() ?? local?['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString() ?? local?['dispensaryTag']?.toString(),
          serial: upperSerial,
        );

        final statusPatch = {
          'dispenseStatus': cleanData['dispenseStatus'] ?? 'dispensed',
          'status': 'completed',
          if (cleanData['dispensedAt'] != null) 'dispensedAt': cleanData['dispensedAt'],
          if (cleanData['dispensedBy'] != null) 'dispensedBy': cleanData['dispensedBy'],
          if (cleanData['completedAt'] != null) 'completedAt': cleanData['completedAt'],
        };

        await _db
            .collection('branches').doc(branchId)
            .collection('serials').doc(campDocKey)
            .collection(queueType).doc(upperSerial)
            .set(statusPatch, SetOptions(merge: true));

        // Delete any legacy standalone dispensary doc if present
        try {
          await _db.collection('branches').doc(branchId)
              .collection('dispensary').doc(dateKey)
              .collection(dateKey).doc(serial).delete();
        } catch (_) {}
        break;

      case 'save_patient':
        final patientId = op['patientId']?.toString();
        if (patientId == null) return;
        await _db
            .collection('branches').doc(branchId)
            .collection('patients').doc(patientId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'workflow_request':
        final requestId = op['requestId']?.toString() ?? cleanData['requestId']?.toString();
        if (requestId == null || requestId.isEmpty) return;
        await _db
            .collection('branches').doc(branchId)
            .collection('edit_requests').doc(requestId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'update_inventory':
        final medicineId = op['medicineId']?.toString();
        if (medicineId == null || medicineId.isEmpty) return;
        final delta = (op['delta'] is num)
            ? (op['delta'] as num).toDouble()
            : double.tryParse(op['delta']?.toString() ?? '') ?? 0.0;
        if (delta == 0) return;

        final invCol = CampSessionService.getCampInventoryPath(
          branchId: branchId,
          campId: op['campId']?.toString() ?? cleanData['campId']?.toString(),
          serial: op['serial']?.toString() ?? cleanData['serial']?.toString(),
        );

        final docRef = _db
            .collection('branches').doc(branchId)
            .collection(invCol).doc(medicineId);
        await docRef.set({
          'quantity': FieldValue.increment(delta),
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        break;

      case 'approve_token_exception':
        final pId = op['patientId']?.toString() ?? cleanData['patientId']?.toString();
        final reqId = op['requestId']?.toString() ?? cleanData['requestId']?.toString();
        if (pId != null && pId.isNotEmpty) {
          await LocalStorageService.grantTokenException(
            branchId,
            pId,
            reason: cleanData['doctorReason']?.toString() ?? 'Approved by Doctor',
            approvedBy: cleanData['approvedBy']?.toString() ?? 'Doctor',
            requestId: reqId,
          );
        }
        if (reqId != null) {
          await _db
              .collection('branches').doc(branchId)
              .collection('edit_requests').doc(reqId)
              .set(cleanData, SetOptions(merge: true));
        }
        break;

      case 'save_token_exception_request':
        final requestId = op['requestId']?.toString() ?? cleanData['requestId']?.toString();
        if (requestId == null) return;
        await _db
              .collection('branches').doc(branchId)
              .collection('edit_requests').doc(requestId)
              .set(cleanData, SetOptions(merge: true));
        break;

      case 'add_inventory_stock':
        final medicineId = op['medicineId']?.toString();
        final qty = op['quantity'];
        if (medicineId == null) return;

        final qtyVal = (qty is num) ? qty.toDouble() : double.tryParse(qty?.toString() ?? '') ?? 0.0;
        if (qtyVal == 0) return;

        final addInvCol = CampSessionService.getCampInventoryPath(
          branchId: branchId,
          campId: op['campId']?.toString() ?? cleanData['campId']?.toString(),
          serial: op['serial']?.toString() ?? cleanData['serial']?.toString(),
        );

        await _db
            .collection('branches').doc(branchId)
            .collection(addInvCol).doc(medicineId)
            .update({'quantity': FieldValue.increment(qtyVal)});

        // Log the action
        final opLog = op['logData'] != null ? Map<String, dynamic>.from(op['logData']) : null;
        if (opLog != null) {
          await _db
              .collection('branches').doc(branchId)
              .collection('inventory_log').add({
            ...opLog,
            'timestamp': FieldValue.serverTimestamp(),
          });
        } else {
          await _db
              .collection('branches').doc(branchId)
              .collection('inventory_log').add({
            'action': 'add_stock',
            'medicineId': medicineId,
            'quantityAdded': qtyVal,
            'performedBy': op['performedBy'] ?? '',
            'performedByName': op['performedByName'] ?? '',
            'timestamp': FieldValue.serverTimestamp(),
          });
        }
        break;

      case 'register_medicine':
      case 'add_stock':
      case 'add_proforma_stock':
        final medData = Map<String, dynamic>.from(op['data'] ?? {});
        final medicineId = op['medicineId']?.toString() ?? medData['id']?.toString() ?? medData['docId']?.toString() ?? '';
        if (medicineId.isEmpty) return;

        // Clean local-only fields
        final fsData = Map<String, dynamic>.from(medData)
          ..remove('id')
          ..remove('syncStatus');

        final regInvCol = CampSessionService.getCampInventoryPath(
          branchId: branchId,
          campId: op['campId']?.toString() ?? medData['campId']?.toString() ?? medData['dispensaryId']?.toString(),
        );

        await _db
            .collection('branches').doc(branchId)
            .collection(regInvCol).doc(medicineId)
            .set(fsData, SetOptions(merge: true));

        final logData = op['logData'] != null ? Map<String, dynamic>.from(op['logData']) : null;
        if (logData != null) {
          await _db
              .collection('branches').doc(branchId)
              .collection('inventory_log').add({
            ...logData,
            'timestamp': FieldValue.serverTimestamp(),
          });
        } else {
          // Log the action
          await _db
              .collection('branches').doc(branchId)
              .collection('inventory_log').add({
            'action': op['action'] ?? 'medicine_registered_directly',
            'medicineName': fsData['name'] ?? '',
            'medicineType': fsData['type'] ?? '',
            'dose': fsData['dose'] ?? '',
            'expiryDate': fsData['expiryDate'] ?? '',
            'quantityAdded': fsData['quantity'] ?? 0,
            'price': fsData['price'] ?? '',
            'performedBy': fsData['createdBy'] ?? op['performedBy'] ?? '',
            'performedByName': fsData['createdByName'] ?? op['performedByName'] ?? '',
            'timestamp': FieldValue.serverTimestamp(),
            'docId': medicineId,
          });
        }
        break;

      case 'save_inventory_log':
        final logData = Map<String, dynamic>.from(op['data'] ?? op['logData'] ?? {});
        await _db
            .collection('branches').doc(branchId)
            .collection('inventory_log').add({
          ...logData,
          'timestamp': FieldValue.serverTimestamp(),
        });
        break;

      case 'save_attendance':
        final docId = op['docId']?.toString() ?? 'att_${DateTime.now().microsecondsSinceEpoch}';
        final today = _todayKey();
        await _db
            .collection('branches').doc(branchId)
            .collection('attendance').doc(today)
            .collection('records').doc(docId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'save_madrassa':
        final docId = op['docId']?.toString() ?? 'mad_${DateTime.now().microsecondsSinceEpoch}';
        final subType = op['subType']?.toString() ?? '';
        if (subType == RealtimeEvents.saveMadrassaDailyLog || subType == RealtimeEvents.saveMadrassaAttendance) {
          final logData = cleanData['data'] is Map
              ? Map<String, dynamic>.from(cleanData['data'])
              : (cleanData['logData'] is Map ? Map<String, dynamic>.from(cleanData['logData']) : cleanData);
          await _db
              .collection('branches').doc(branchId)
              .collection('madrassa_daily_logs').doc(docId)
              .set(logData, SetOptions(merge: true));
        } else if (subType == RealtimeEvents.saveMadrassaStudent || subType == RealtimeEvents.saveMadrassaAdmission) {
          final studentData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
          await _db
              .collection('branches').doc(branchId)
              .collection('madrassa_students').doc(docId)
              .set(studentData, SetOptions(merge: true));
        } else if (subType == RealtimeEvents.saveMadrassaFeePayment) {
          final feeData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
          await _db
              .collection('branches').doc(branchId)
              .collection('madrassa_fee_payments').doc(docId)
              .set(feeData, SetOptions(merge: true));
        } else {
          final coll = subType == RealtimeEvents.saveMadrassaFee ? 'fees' : 'records';
          await _db
              .collection('branches').doc(branchId)
              .collection('madrassa').doc(coll)
              .collection('items').doc(docId)
              .set(cleanData, SetOptions(merge: true));
        }
        break;

      case 'save_finance':
        final docId = op['docId']?.toString() ?? 'fin_${DateTime.now().microsecondsSinceEpoch}';
        final subType = op['subType']?.toString() ?? '';
        String coll = 'ledger';
        if (subType.contains('expense')) coll = 'expenses';
        else if (subType.contains('loan')) coll = 'loans';
        await _db
            .collection('branches').doc(branchId)
            .collection('finance').doc(coll)
            .collection('records').doc(docId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'delete_finance':
        final docId = op['docId']?.toString();
        if (docId != null) {
          final subType = op['subType']?.toString() ?? '';
          String coll = 'ledger';
          if (subType.contains('expense')) coll = 'expenses';
          else if (subType.contains('loan')) coll = 'loans';
          await _db
              .collection('branches').doc(branchId)
              .collection('finance').doc(coll)
              .collection('records').doc(docId)
              .delete();
        }
        break;

      case 'save_donation':
        final docId = op['docId']?.toString() ?? 'don_${DateTime.now().microsecondsSinceEpoch}';
        await _db
            .collection('branches').doc(branchId)
            .collection('donations').doc(docId)
            .set(cleanData, SetOptions(merge: true));
        await _db
            .collection('donations').doc(docId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'save_dasterkhwan':
        final subType = op['subType']?.toString() ?? '';
        if (subType == RealtimeEvents.saveOfficeBoyToken) {
          final isReverse = cleanData['action'] == 'reverse';
          final dateKey = cleanData['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);
          final dayDocRef = _db.collection('branches').doc(branchId).collection('dasterkhwaan').doc(dateKey);
          final tokensColRef = dayDocRef.collection('tokens');

          if (isReverse) {
            final tokenIds = List<String>.from((cleanData['tokenIds'] as List? ?? []).map((e) => e.toString()));
            final qty = (cleanData['quantity'] as num?)?.toInt() ?? tokenIds.length;
            final batch = _db.batch();
            for (final tid in tokenIds) {
              batch.delete(tokensColRef.doc(tid));
            }
            batch.set(dayDocRef, {
              'totalTokens': FieldValue.increment(-qty),
              'lastUpdated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            await batch.commit();
          } else {
            final tokensList = List<dynamic>.from(cleanData['tokens'] as List? ?? []);
            final qty = (cleanData['quantity'] as num?)?.toInt() ?? tokensList.length;
            final session = cleanData['session']?.toString() ?? 'lunch';
            final batch = _db.batch();
            for (final t in tokensList) {
              if (t is Map) {
                final tMap = Map<String, dynamic>.from(t);
                final tid = tMap['id']?.toString() ?? tokensColRef.doc().id;
                batch.set(tokensColRef.doc(tid), {
                  'number': tMap['number'] ?? 1,
                  'served': tMap['served'] == true,
                  'session': tMap['session'] ?? session,
                  'time': FieldValue.serverTimestamp(),
                  'issuedBy': tMap['issuedBy'] ?? '',
                  'localId': tid,
                }, SetOptions(merge: true));
              }
            }
            batch.set(dayDocRef, {
              'totalTokens': FieldValue.increment(qty),
              'session_${session}_total': FieldValue.increment(qty),
              'lastUpdated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            await batch.commit();
          }
        } else if (subType == RealtimeEvents.saveKitchenServeLog) {
          final dateKey = cleanData['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);
          final tokenId = cleanData['tokenId']?.toString();
          if (tokenId != null && tokenId.isNotEmpty) {
            await _db
                .collection('branches').doc(branchId)
                .collection('dasterkhwaan').doc(dateKey)
                .collection('tokens').doc(tokenId)
                .set({
                  'served': true,
                  'servedTime': FieldValue.serverTimestamp(),
                }, SetOptions(merge: true));
          }
        } else {
          final docId = op['docId']?.toString() ?? 'das_${DateTime.now().microsecondsSinceEpoch}';
          await _db
              .collection('branches').doc(branchId)
              .collection('dasterkhwaan').doc('entries')
              .collection('records').doc(docId)
              .set(cleanData, SetOptions(merge: true));
        }
        break;

      case 'save_supervisor':
        final docId = op['docId']?.toString() ?? 'sup_${DateTime.now().microsecondsSinceEpoch}';
        await _db
            .collection('branches').doc(branchId)
            .collection('edit_requests').doc(docId)
            .set(cleanData, SetOptions(merge: true));
        break;

      case 'save_employee':
        final localId = op['localId']?.toString() ?? cleanData['localId']?.toString() ?? cleanData['id']?.toString();
        final bId = op['branchId']?.toString() ?? cleanData['branchId']?.toString() ?? branchId;
        if (localId == null || localId.isEmpty) return;
        final fsData = Map<String, dynamic>.from(cleanData)..remove('syncStatus');
        await _db.collection('branches').doc(bId).collection('employees').doc(localId).set(fsData, SetOptions(merge: true));
        break;

      case 'delete_employee':
        final localId = op['localId']?.toString();
        final bId = op['branchId']?.toString() ?? branchId;
        if (localId == null || localId.isEmpty) return;
        await _db.collection('branches').doc(bId).collection('employees').doc(localId).delete();
        break;

      default:
        debugPrint('[SSM] Unknown op type: $type');
    }
  }

  // ── Downloads ──────────────────────────────────────────────────────────────

    Future<void> _downloadAllFromFirestore() async {
    if (_branchId == null || !_running) return;
    final conn = await Connectivity().checkConnectivity();
    if (conn.every((r) => r == ConnectivityResult.none)) return;

    // Today's tokens & dispensary records are small and time-critical —
    // ALWAYS refresh these, never gate behind the heavy-data cooldown below.
    // Gating this was the root cause of tokens "disappearing" after a LAN
    // disconnect: once connected, clients stop listening to Firestore
    // directly and rely entirely on this server's local cache for catch-up.
    // If that cache goes stale for up to 30 minutes, any token written to
    // Firestore during that window was invisible to every other device.
    await Future.wait([
      _downloadTodayTokens(),
      _downloadTodayDispensary(),
    ]);

    // ── 30-minute cooldown guard for the heavier, slower-changing data ────────
    final settings = Hive.box('app_settings');
    final ttlKey = 'ssm_last_download_$_branchId';
    final lastStr = settings.get(ttlKey) as String?;
    final last = lastStr != null ? DateTime.tryParse(lastStr) : null;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      debugPrint('[SSM] Heavy-data download cooldown active for $_branchId — skipping');
      return;
    }
    await settings.put(ttlKey, now.toIso8601String());

    await Future.wait([
      _downloadPatients(),
      _downloadInventory(),
      _downloadPrescriptions(),
      _downloadAttendance(),
      _downloadMadrassa(),
      _downloadFinance(),
      _downloadDonations(),
    ]);
  }

  /// Fetches today's serial documents for all three queue types and saves
  /// them to the local entries box.
  Future<void> _downloadTodayTokens() async {
    if (_branchId == null || !_running) return;
    try {
      final today      = _todayKey();
      final queueTypes = ['zakat', 'non-zakat', 'gmwf'];

      for (final queueType in queueTypes) {
        final snap = await _db
            .collection('branches')
            .doc(_branchId)
            .collection('serials')
            .doc(today)
            .collection(queueType)
            .get();

        for (final doc in snap.docs) {
          final d = doc.data();
          d['serial']    = doc.id;
          d['queueType'] = queueType;
          d['dateKey']   = today;
          d['branchId']  = _branchId;
          if (!CampSessionService.isSerialMatchingBranch(doc.id, _branchId)) continue;
          LocalStorageService.saveEntryLocal(_branchId!, doc.id, d);
        }
      }
      debugPrint('[SSM] Downloaded today tokens for $_branchId ($today)');
    } catch (e) {
      debugPrint('[SSM] _downloadTodayTokens error: $e');
    }
  }

  /// Fetches all patient documents for the branch and saves them locally.
  Future<void> _downloadPatients() async {
    if (_branchId == null || !_running) return;
    try {
      final snap = await _db
          .collection('branches')
          .doc(_branchId)
          .collection('patients')
          .get();

      final List<Map<String, dynamic>> patientsList = [];
      for (final doc in snap.docs) {
        final d = doc.data();
        d['patientId'] = doc.id;
        d['branchId']  = _branchId;
        patientsList.add(d);
        // Mark synced so backfill never re-uploads patients from Firestore
        await Hive.box('app_flags').put('patient_synced_${doc.id}', true);
      }
      await LocalStorageService.saveAllLocalPatients(patientsList);
      debugPrint('[SSM] Downloaded ${snap.docs.length} patients for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadPatients error: $e');
    }
  }

  /// Fetches all inventory documents for the branch and saves them locally.
  Future<void> _downloadInventory() async {
    if (_branchId == null || !_running) return;
    try {
      final snap = await _db
          .collection('branches')
          .doc(_branchId)
          .collection('inventory')
          .get();

      for (final doc in snap.docs) {
        final d = doc.data();
        d['medicineId'] = doc.id;
        d['branchId']   = _branchId;
        LocalStorageService.saveLocalInventoryItem(d);
      }
      debugPrint('[SSM] Downloaded ${snap.docs.length} inventory items for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadInventory error: $e');
    }
  }

  /// Fetches all CNIC-keyed prescription subcollections and saves them locally.
  Future<void> _downloadPrescriptions() async {
    if (_branchId == null || !_running) return;
    try {
      final cnicDocs = await _db
          .collection('branches')
          .doc(_branchId)
          .collection('prescriptions')
          .get();

      int total = 0;
      for (final cnicDoc in cnicDocs.docs) {
        final presSnap = await _db
            .collection('branches')
            .doc(_branchId)
            .collection('prescriptions')
            .doc(cnicDoc.id)
            .collection('prescriptions')
            .get();

        for (final presDoc in presSnap.docs) {
          final d = presDoc.data();
          d['id']          = presDoc.id;
          d['patientCnic'] = cnicDoc.id;
          final pSerial = (d['serial'] ?? presDoc.id).toString();
          if (!CampSessionService.isSerialMatchingBranch(pSerial, _branchId)) continue;
          d['branchId']    = _branchId;
          await LocalStorageService.saveLocalPrescription(d);
          total++;
        }
      }
      debugPrint('[SSM] Downloaded $total prescriptions for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadPrescriptions error: $e');
    }
  }

  /// Fetches today's dispensary records and saves them locally.
  Future<void> _downloadTodayDispensary() async {
    if (_branchId == null || !_running) return;
    try {
      final today = _todayKey();
      final snap  = await _db
          .collection('branches')
          .doc(_branchId)
          .collection('dispensary')
          .doc(today)
          .collection(today)
          .get();

      for (final doc in snap.docs) {
        final d = doc.data();
        d['serial']   = doc.id;
        d['dateKey']  = today;
        d['branchId'] = _branchId;
        LocalStorageService.saveLocalDispensaryRecord(d);
      }
      debugPrint('[SSM] Downloaded ${snap.docs.length} dispensary records for $_branchId ($today)');
    } catch (e) {
      debugPrint('[SSM] _downloadTodayDispensary error: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _todayKey() => DateFormat('ddMMyy').format(DateTime.now());

  String? _field(
    Map<String, dynamic> data,
    Map<String, dynamic> full,
    String field,
  ) =>
      data[field]?.toString() ??
      full[field]?.toString() ??
      full['_senderBranch']?.toString();

  String _cleanCnic(String raw) =>
      raw.replaceAll(RegExp(r'[-\s]'), '').toLowerCase();

  void _saveTokenExceptionRequest(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId  = _field(data, full, 'branchId') ?? _branchId!;
    final requestId = data['requestId']?.toString() ?? 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    
    final record = {
      ...data,
      'branchId': branchId,
      'status':   'pending',
      'requestedAt': DateTime.now().toIso8601String(),
      ...?user?.toAuditMap(),
    };

    _enqueue({
      'type':      'save_token_exception_request',
      'branchId':  branchId,
      'requestId': requestId,
      'data':      record,
    });
  }

  void _saveTokenExceptionApproval(
    Map<String, dynamic> data,
    Map<String, dynamic> full, {
    _UserContext? user,
  }) {
    final branchId  = _field(data, full, 'branchId') ?? _branchId!;
    final requestId = data['requestId']?.toString();
    final patientId = data['patientId']?.toString();
    if (requestId == null) return;

    final update = {
      'status':         'approved',
      'doctorReason':   data['reason'] ?? data['doctorReason'] ?? '',
      'approvedBy':     user?.username ?? 'Doctor',
      'approvedByName': user?.username ?? 'Doctor',
      'approvedAt':     DateTime.now().toIso8601String(),
      ...?user?.toAuditMap(),
    };

    // ── FIRESTORE FIX: Clear local restriction immediately on server device ──
    if (patientId != null) {
      LocalStorageService.clearMedicineRestriction(branchId, patientId).ignore();
    }

    _enqueue({
      'type':      'approve_token_exception',
      'branchId':  branchId,
      'requestId': requestId,
      'patientId': patientId, // CRITICAL: pass to SyncService
      'data':      update,
    });
  }

  void _handlePrescriptionRestriction(Map<String, dynamic> data, Map<String, dynamic> full) {
    final days = int.tryParse(data['daysOfMedicine']?.toString() ?? '1') ?? 1;
    if (days <= 1) return;

    final bId = _field(data, full, 'branchId') ?? _branchId;
    final pId = LocalStorageService.resolveIndividualPatientId(data);

    if (bId != null && pId.isNotEmpty) {
      LocalStorageService.saveMedicineRestriction(
        branchId: bId,
        patientId: pId,
        daysCovered: days,
      );
      debugPrint('[SSM] 💊 Multi-day restriction applied: $pId ($days days)');
    }
  }

  // ── Additional Module Download Methods ──────────────────────────────────────

  Future<void> _downloadAttendance() async {
    if (_branchId == null || !_running) return;
    try {
      final box = await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      final dateDocsSnap = await _db
          .collection('branches').doc(_branchId)
          .collection('employee_attendance')
          .limit(7)
          .get();

      int count = 0;
      for (final dateDoc in dateDocsSnap.docs) {
        final dStr = dateDoc.id;
        final recSnap = await dateDoc.reference.collection('records').get();
        for (final doc in recSnap.docs) {
          final employeeId = doc.id;
          final key = '${employeeId}_$dStr';
          box.put(key, LocalStorageService.sanitize(doc.data()));
          count++;
        }
      }
      debugPrint('[SSM] Downloaded $count attendance records for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadAttendance error: $e');
    }
  }

  Future<void> _downloadMadrassa() async {
    if (_branchId == null || !_running) return;
    try {
      final feesSnap = await _db
          .collection('branches').doc(_branchId)
          .collection('madrassa').doc('fees')
          .collection('items').get();

      final feesBox = await LocalStorageService.openBoxSafe('madrassa_fees');
      for (final doc in feesSnap.docs) {
        feesBox.put(doc.id, LocalStorageService.sanitize(doc.data()));
      }
      debugPrint('[SSM] Downloaded ${feesSnap.docs.length} madrassa fee records for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadMadrassa error: $e');
    }
  }

  Future<void> _downloadFinance() async {
    if (_branchId == null || !_running) return;
    try {
      for (final coll in ['expenses', 'loans', 'ledger']) {
        final snap = await _db
            .collection('branches').doc(_branchId)
            .collection('finance').doc(coll)
            .collection('records').get();

        String boxName = 'finance_entries';
        if (coll == 'expenses') boxName = 'finance_expenses';
        else if (coll == 'loans') boxName = 'finance_loans';

        final box = await LocalStorageService.openBoxSafe(boxName);
        for (final doc in snap.docs) {
          box.put(doc.id, LocalStorageService.sanitize(doc.data()));
        }
      }
      debugPrint('[SSM] Downloaded finance records for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadFinance error: $e');
    }
  }

  Future<void> _downloadDonations() async {
    if (_branchId == null || !_running) return;
    try {
      final snap = await _db
          .collection('branches').doc(_branchId)
          .collection('donations').doc('receipts')
          .collection('records').get();

      final box = await LocalStorageService.openBoxSafe('donations_box');
      for (final doc in snap.docs) {
        box.put(doc.id, LocalStorageService.sanitize(doc.data()));
      }
      debugPrint('[SSM] Downloaded ${snap.docs.length} donation records for $_branchId');
    } catch (e) {
      debugPrint('[SSM] _downloadDonations error: $e');
    }
  }
}
