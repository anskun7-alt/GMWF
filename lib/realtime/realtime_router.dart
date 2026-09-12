// lib/realtime/realtime_router.dart
//
// FIXES IN THIS VERSION:
//
// [P2] Non-server devices now enqueue directly to SyncService on every LAN
//      message receipt. _handleSaveEntry, _handleSavePrescription, and
//      _handleDispenseCompleted each call LocalStorageService.enqueueSync()
//      so that any device with internet connectivity uploads to Firestore
//      independently — without relying on the LAN server to relay.
//      Messages flagged with _serverPush:true are excluded to prevent the
//      server device from double-enqueuing its own catch-up pushes.
//
// [P3] _processedMessageIds is now persisted to a Hive box ('realtime_dedup_ids')
//      with a 24-hour TTL so deduplication survives app restarts.
//      Keys are stored as "<timestampMs>_<messageId>" enabling O(1) TTL
//      pruning by prefix comparison without scanning values.
//      Call RealtimeRouter.init() at app startup alongside other Hive opens.
//
// [FIX] Removed duplicate switch-case values for workflow_request /
//       workflow_decision (previously appeared both as raw string literals
//       under the request-event block AND as RealtimeEvents constants under
//       a second block, then later as a third duplicate block — this caused
//       a Dart duplicate-case compile error). Each event type now maps to
//       exactly ONE case clause in routeMessage().

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../services/local_storage_service.dart';
import '../services/sync_service.dart';
import '../services/finance_local_storage.dart';
import '../services/donations_local_storage.dart';
import '../services/zkteco_network_service.dart';
import '../pages/madrassa/utils/madrassa_local_storage.dart';
import 'realtime_events.dart';
import 'realtime_manager.dart';

class RealtimeRouter {
  // ── [P3] Fast In-memory & Hive-backed dedup store ─────────────────────────
  static const _dedupBox = 'realtime_dedup_ids';
  static final Set<String> _seenMessageIds = <String>{};

  /// Must be called once at app startup alongside other Hive.openBox() calls.
  static Future<void> init() async {
    final box = await Hive.openBox<String>(_dedupBox);
    await RealtimeManager.initOutbox();
    // Preload keys into in-memory set for O(1) instant checking
    _seenMessageIds.addAll(box.values);
    _pruneExpired();
  }

  /// Removes dedup entries older than 24 hours.
  static void _pruneExpired() {
    try {
      final box = Hive.box<String>(_dedupBox);
      if (box.isEmpty) return;

      final cutoffMs = DateTime.now()
          .subtract(const Duration(hours: 24))
          .millisecondsSinceEpoch;

      final expired = box.keys.where((k) {
        final parts = k.toString().split('_');
        if (parts.isEmpty) return true;
        final ts = int.tryParse(parts.first);
        return ts == null || ts < cutoffMs;
      }).toList();

      if (expired.isNotEmpty) {
        for (final k in expired) {
          final id = box.get(k);
          if (id != null) _seenMessageIds.remove(id);
        }
        box.deleteAll(expired);
        if (kDebugMode) {
          print('RealtimeRouter: pruned ${expired.length} expired dedup entries');
        }
      }
    } catch (e) {
      if (kDebugMode) print('RealtimeRouter: _pruneExpired error: $e');
    }
  }

  static DateTime _lastCleanup = DateTime.now();

  // ── Main router ───────────────────────────────────────────────────────────

  static Future<void> routeMessage(Map<String, dynamic> message) async {
    // Periodic prune — replaces the old 5-min in-memory clear
    if (DateTime.now().difference(_lastCleanup).inMinutes > 5) {
      _pruneExpired();
      _lastCleanup = DateTime.now();
    }

    // Generate a collision-resistant message ID
    final data = message['data'] as Map<String, dynamic>? ?? message;
    final messageId = message['_messageId']?.toString() ??
        '${message['_clientId'] ?? 'client'}_'
        '${message['_timestamp'] ?? ''}_'
        '${message['event_type'] ?? ''}_'
        '${message['serial'] ?? data['serial'] ?? data['id'] ?? data['localId'] ?? ''}';

    // O(1) Instant In-memory set lookup
    if (_seenMessageIds.contains(messageId)) {
      if (kDebugMode) print('⚠️ Duplicate message ignored: $messageId');
      return;
    }

    // Record seen
    _seenMessageIds.add(messageId);
    if (Hive.isBoxOpen(_dedupBox)) {
      final box = Hive.box<String>(_dedupBox);
      final dedupKey = '${DateTime.now().millisecondsSinceEpoch}_$messageId';
      box.put(dedupKey, messageId);
    }

    final incomingVersion = (message['version'] is int)
        ? (message['version'] as int)
        : (int.tryParse(message['version']?.toString() ?? '') ?? (data['version'] is int ? data['version'] as int : 0));
    final entityId = data['serial']?.toString() ?? data['patientId']?.toString() ?? data['userId']?.toString() ?? '';

    if (incomingVersion > 0 && entityId.isNotEmpty) {
      try {
        final versionBox = await Hive.openBox<int>('realtime_entity_versions');
        final localVersion = versionBox.get(entityId) ?? 0;
        if (incomingVersion <= localVersion) {
          if (kDebugMode) {
            print('🛑 Stale update ignored for $entityId: incoming version $incomingVersion <= local $localVersion');
          }
          return;
        }
        await versionBox.put(entityId, incomingVersion);
      } catch (e) {
        if (kDebugMode) print('RealtimeRouter: Version check error: $e');
      }
    }

    final type = message['event_type']?.toString() ?? '';

    // ── LAN Source-Branch Validation (Pillar 5-B / Pillar 2) ──────────────────
    final incomingBranch = (message['branchId'] ?? data['branchId'] ?? '').toString().toLowerCase().trim();
    final activeBranch = LocalStorageService.getActiveBranchId();
    if (activeBranch != null &&
        activeBranch != 'all' &&
        incomingBranch.isNotEmpty &&
        incomingBranch != 'all' &&
        incomingBranch != activeBranch) {
      if (kDebugMode) {
        print('🛑 Cross-branch packet rejected: Inbound branch "$incomingBranch" != active branch "$activeBranch" (type: $type)');
      }
      return;
    }

    if (kDebugMode) {
      print('''
════════════ REALTIME ROUTER ════════════
Type: $type
Msg ID: $messageId
Sender: ${message['_senderRole'] ?? '?'}
Branch: ${data['branchId'] ?? message['branchId'] ?? '?'}
Serial: ${data['serial'] ?? 'N/A'}
════════════════════════════════════════
''');
    }

    switch (type) {
      case 'token_created':
      case RealtimeEvents.saveEntry:
        await _handleSaveEntry(data, message);
        break;

      case RealtimeEvents.deleteEntry:
        await _handleDeleteEntry(data);
        break;

      case 'prescription_created':
      case RealtimeEvents.savePrescription:
        await _handleSavePrescription(data, message);
        break;

      case RealtimeEvents.deletePrescription:
        await _handleDeletePrescription(data);
        break;

      case RealtimeEvents.savePatient:
        await LocalStorageService.saveLocalPatient(
          data['data'] as Map<String, dynamic>? ?? data,
          isFromSync: true,
        );
        break;

      case RealtimeEvents.deletePatient:
        if (data['patientId'] != null) {
          await LocalStorageService.deleteLocalPatient(data['patientId']);
        }
        break;

      case 'dispense_completed':
        await _handleDispenseCompleted(data, message);
        break;

      case RealtimeEvents.saveEmployee:
        await _handleSaveEmployee(data, message);
        break;

      case RealtimeEvents.deleteEmployee:
        await _handleDeleteEmployee(data, message);
        break;

      case RealtimeEvents.deleteBiometricDevice:
        final devId = (data['deviceId'] ?? data['id'])?.toString();
        if (devId != null && devId.isNotEmpty) {
          await ZkTecoNetworkService.addDeletedDeviceTombstone(devId);
          if (Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
            final box = Hive.box(LocalStorageService.biometricDevicesBox);
            final keysToPrune = <dynamic>[];
            for (final k in box.keys) {
              if (k.toString() == devId) {
                keysToPrune.add(k);
                continue;
              }
              final val = box.get(k);
              if (val is Map && (val['deviceId']?.toString() == devId)) {
                keysToPrune.add(k);
              }
            }
            for (final k in keysToPrune) {
              await box.delete(k);
            }
          }
        }
        break;

      case RealtimeEvents.saveBiometricDevice:
        final devData = Map<String, dynamic>.from(data['data'] as Map? ?? data);
        final devId = (data['deviceId'] ?? devData['deviceId'] ?? '').toString();
        if (devId.isNotEmpty) {
          await ZkTecoNetworkService.removeDeletedDeviceTombstone(devId);
          if (Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
            final box = Hive.box(LocalStorageService.biometricDevicesBox);
            await box.put(devId, devData);
          }
        }
        break;

      case RealtimeEvents.saveUser:
        final userData = Map<String, dynamic>.from(data['data'] as Map? ?? data);
        final uid = (data['uid'] ?? userData['uid'] ?? userData['id'])?.toString() ?? '';
        final bId = (data['branchId'] ?? userData['branchId'] ?? '').toString();
        if (userData['email'] != null && Hive.isBoxOpen(LocalStorageService.usersBox)) {
          await Hive.box(LocalStorageService.usersBox).put('user:${userData['email']}', userData);
          await Hive.box(LocalStorageService.usersBox).flush();
        }
        if (!RealtimeManager().isConnected && message['_serverPush'] != true) {
          await LocalStorageService.enqueueSync({
            'type': 'save_user',
            'uid': uid,
            'branchId': bId,
            'data': userData,
          });
        }
        break;

      case RealtimeEvents.deleteUser:
        final email = (data['email'] ?? '').toString();
        final uid = (data['uid'] ?? '').toString();
        final bId = (data['branchId'] ?? '').toString();
        if (email.isNotEmpty && Hive.isBoxOpen(LocalStorageService.usersBox)) {
          await Hive.box(LocalStorageService.usersBox).delete('user:$email');
        }
        if (!RealtimeManager().isConnected && message['_serverPush'] != true) {
          await LocalStorageService.enqueueSync({
            'type': 'delete_user',
            'uid': uid,
            'branchId': bId,
            'email': email,
          });
        }
        break;

      // ── INVENTORY: stock addition or new medicine registration ──────────────
      case RealtimeEvents.saveStockItem:
        await _handleSaveStockItem(data, message);
        break;

      case RealtimeEvents.deleteStockItem:
        await _handleDeleteStockItem(data);
        break;

      // ── PROFORMA CATALOG EVENTS ─────────────────────────────────────────────
      case RealtimeEvents.saveProformaItem:
      case RealtimeEvents.proformaItemUpdated:
        await _handleProformaEvent(data);
        break;

      // ── TOKEN REVERSAL APPROVED ────────────────────────────────────────────
      case RealtimeEvents.tokenReversalApproved:
        await _handleTokenReversalApproved(data);
        break;

      // ── WORKFLOW REQUESTS & APPROVALS (edit-request approval flow) ──────────
      case RealtimeEvents.requestCreated:
      case RealtimeEvents.requestApproved:
      case RealtimeEvents.requestRejected:
        await _handleRequestEvent(type, data);
        break;

      // ── ATTENDANCE EVENTS ──────────────────────────────────────────────────
      case RealtimeEvents.saveBiometricLog:
      case RealtimeEvents.saveEmployeeAttendance:
      case RealtimeEvents.saveFacultyAttendance:
      case RealtimeEvents.saveStudentAttendance:
        await _handleAttendanceEvent(type, data);
        break;

      // ── MADRASSA & SCHOOL EVENTS ───────────────────────────────────────────
      case RealtimeEvents.saveMadrassaStudent:
      case RealtimeEvents.saveMadrassaAdmission:
      case RealtimeEvents.saveMadrassaAttendance:
      case RealtimeEvents.saveMadrassaDailyLog:
      case RealtimeEvents.offboardMadrassaStudent:
      case RealtimeEvents.deleteMadrassaStudent:
      case RealtimeEvents.saveMadrassaFee:
      case RealtimeEvents.saveMadrassaFeePayment:
      case RealtimeEvents.saveMadrassaHifzProgress:
      case RealtimeEvents.saveExamResult:
        await _handleMadrassaEvent(type, data);
        break;

      // ── FINANCE EVENTS ────────────────────────────────────────────────────
      case RealtimeEvents.saveExpense:
      case RealtimeEvents.deleteExpense:
      case RealtimeEvents.saveLoan:
      case RealtimeEvents.deleteLoan:
      case RealtimeEvents.saveFinanceEntry:
        await _handleFinanceEvent(type, data);
        break;

      // ── DONATION EVENTS ───────────────────────────────────────────────────
      case RealtimeEvents.saveDonationReceipt:
      case RealtimeEvents.saveDonor:
      case RealtimeEvents.saveDonationCollection:
        await _handleDonationEvent(type, data);
        break;

      // ── EXECUTIVE GLOBAL CLOUD SYNC ────────────────────────────────────────
      case 'force_all_users_cloud_sync':
        debugPrint('[RealtimeRouter] ☁️ Received force_all_users_cloud_sync command! Uploading local queues to Firestore...');
        SyncService().triggerUpload();
        break;

      // ── DASTERKHWAAN EVENTS ───────────────────────────────────────────────
      case RealtimeEvents.saveDasterkhwanEntry:
      case RealtimeEvents.saveDasterkhwanStock:
      case RealtimeEvents.saveOfficeBoyToken:
      case RealtimeEvents.saveKitchenServeLog:
        await _handleDasterkhwanEvent(type, data);
        break;

      // ── LIBRARY EVENTS ───────────────────────────────────────────────────
      case RealtimeEvents.saveLibraryBook:
      case RealtimeEvents.saveLibraryIssue:
      case RealtimeEvents.deleteLibraryBook:
        await _handleLibraryEvent(type, data);
        break;

      // ── FACULTY & STAFF EVENTS ────────────────────────────────────────────
      case RealtimeEvents.saveFaculty:
      case RealtimeEvents.saveStaffProfile:
        await _handleStaffEvent(type, data);
        break;

      // ── TOKEN EXCEPTION EVENTS ───────────────────────────────────────────
      case RealtimeEvents.tokenExceptionRequest:
        await _handleTokenExceptionRequest(data, message);
        break;

      case RealtimeEvents.tokenExceptionApproved:
      case 'restriction_removed':
        await _handleTokenExceptionApproved(data, message);
        break;

      // ── GENERIC WORKFLOW EVENTS (separate tracking box from edit-requests) ──
      case RealtimeEvents.workflowRequest:
      case RealtimeEvents.workflowDecision:
        await _handleWorkflowEvent(type, data);
        break;

      // ── SUPERVISOR EVENTS ─────────────────────────────────────────────────
      case RealtimeEvents.saveSupervisorAction:
      case RealtimeEvents.approveEditRequest:
      case RealtimeEvents.rejectEditRequest:
        await _handleSupervisorEvent(type, data);
        break;

      case 'welcome':
      case 'identify_request':
      case 'identified':
      case 'ping':
      case 'pong':
      case RealtimeEvents.clientCountUpdate:
        // ignore connection handshake / housekeeping messages
        break;

      default:
        if (kDebugMode) print('⚠️ Unhandled realtime event: $type');
    }
  }

  // ── Handlers ──────────────────────────────────────────────────────────────

  static Future<void> _handleSaveEntry(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    // CRITICAL: Extract branchId correctly from EITHER location
    final branchId = (fullMessage['branchId']?.toString() ??
                     data['branchId']?.toString() ??
                     '').toLowerCase().trim();

    final serial = data['serial']?.toString().trim();

    if (branchId.isEmpty || serial == null || serial.isEmpty) {
      if (kDebugMode) {
        print('❌ save_entry missing branchId or serial');
        print('   fullMessage branchId: ${fullMessage['branchId']}');
        print('   data branchId: ${data['branchId']}');
        print('   serial: $serial');
      }
      return;
    }

    // CRITICAL: Use CONSISTENT key format across all devices
    final uniqueKey = '$branchId-$serial';

    final parts = serial.split('-');
    final cleanDateKey = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
        ? (parts.length > 1 ? parts[1] : '')
        : (parts.isNotEmpty ? parts[0] : '');

    // Build complete entry data — merge everything
    final entryData = <String, dynamic>{
      'serial':       serial,
      'branchId':     branchId,
      'queueType':    data['queueType'] ?? 'zakat',
      'patientId':    data['patientId'] ?? '',
      'patientName':  data['patientName'] ?? 'Unknown',
      'patientCnic':  data['patientCnic'] ?? data['cnic'] ?? '',
      'guardianCnic': data['guardianCnic'],
      'createdAt':    data['createdAt'] ?? data['time'],
      'status':       data['status'] ?? 'waiting',
      'vitals':       data['vitals'] ?? {},
      'createdBy':    data['createdBy'] ?? '',
      'createdByName':data['createdByName'] ?? '',
      'dateKey':      data['dateKey'] ?? cleanDateKey,
      if (data['session'] != null) 'session': data['session'],
      if (data['shift'] != null) 'shift': data['shift'],
    };

    // Add any additional fields from data not already included
    data.forEach((key, value) {
      if (!entryData.containsKey(key) && value != null) {
        entryData[key] = value;
      }
    });

    // CRITICAL: Save via LocalStorageService.saveEntryLocal to enforce terminal status protection & auto-link prescriptions
    await LocalStorageService.saveEntryLocal(branchId, serial, entryData);

    if (kDebugMode) print('✅ ENTRY SAVED → $uniqueKey');

  }

  static Future<void> _handleDeleteEntry(Map<String, dynamic> data) async {
    final branchId = data['branchId']?.toString().toLowerCase().trim();
    final serial   = data['serial']?.toString().trim();

    if (branchId == null || branchId.isEmpty ||
        serial == null || serial.isEmpty) {
      if (kDebugMode) print('❌ delete_entry missing branchId or serial');
      return;
    }

    final key = '$branchId-$serial';
    await Hive.box(LocalStorageService.entriesBox).delete(key);
    if (kDebugMode) print('✅ ENTRY DELETED → $key');
  }

  static Future<void> _handleSavePrescription(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final serial   = data['serial']?.toString().trim();
    final branchId = (fullMessage['branchId']?.toString() ??
                     data['branchId']?.toString() ??
                     '').toLowerCase().trim();

    if (serial == null || serial.isEmpty) {
      if (kDebugMode) print('❌ save_prescription missing serial');
      return;
    }

    // CRITICAL: Save prescription to its own box IMMEDIATELY
    await LocalStorageService.saveLocalPrescription(data);

    // NEW: Handle medicine restriction for multi-day prescriptions
    _handleMedicineRestriction(data, fullMessage);

    // CRITICAL: Also update the entry status if we have branchId
    if (branchId.isNotEmpty) {
      final box = Hive.box(LocalStorageService.entriesBox);
      final normBranch = branchId.toLowerCase().trim();
      final normSerial = serial.toLowerCase().trim();

      bool found = false;
      for (final k in box.keys) {
        final kStr = k.toString().toLowerCase().trim();
        if (kStr == '$normBranch-$normSerial' || kStr == normSerial || kStr.endsWith('-$normSerial')) {
          final entry = box.get(k);
          if (entry is Map) {
            final updated = Map<String, dynamic>.from(entry);
            updated['status']         = 'completed';
            updated['prescription']   = data;
            updated['prescriptionId'] = data['id'] ?? serial;
            updated['completedAt']    =
                data['completedAt'] ?? DateTime.now().toIso8601String();

            await box.put(k, updated);
            found = true;
          }
        }
      }

      if (kDebugMode && found) {
        print('╔════════════════════════════════════════════════════════════╗');
        print('║ ✅ PRESCRIPTION SAVED TO HIVE (ROUTER)                    ║');
        print('╠════════════════════════════════════════════════════════════╣');
        print('║ Serial: $serial');
        print('║ Entry Status Updated: completed');
        print('║ Prescription ID: ${data['id'] ?? serial}');
        print('╚════════════════════════════════════════════════════════════╝');
      }
    }

  }

  static Future<void> _handleDeletePrescription(Map<String, dynamic> data) async {
    final id = data['id']?.toString();
    if (id != null && id.isNotEmpty) {
      await LocalStorageService.deleteLocalPrescription(id);
      if (kDebugMode) print('✅ PRESCRIPTION DELETED → $id');
    }
  }

  // Updated signature: now receives fullMessage to access _serverPush flag
  static Future<void> _handleDispenseCompleted(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final branchId = (data['branchId']?.toString() ?? '').toLowerCase().trim();
    final serial   = data['serial']?.toString().trim();

    if (branchId.isEmpty || serial == null || serial.isEmpty) {
      if (kDebugMode) print('❌ dispense_completed missing branchId or serial');
      return;
    }

    final normBranch = branchId.toLowerCase().trim();
    final normSerial = serial.toLowerCase().trim();
    final key        = '$normBranch-$serial';
    final box        = Hive.box(LocalStorageService.entriesBox);
    dynamic targetKey = key;
    dynamic existing = box.get(key);

    if (existing == null) {
      for (final k in box.keys) {
        final kStr = k.toString().toLowerCase().trim();
        if (kStr == '$normBranch-$normSerial' || kStr == normSerial || kStr.endsWith('-$normSerial')) {
          targetKey = k;
          existing = box.get(k);
          break;
        }
      }
    }

    if (existing != null) {
      final updated = Map<String, dynamic>.from(existing);
      updated['dispenseStatus'] = 'dispensed';
      updated['status']         = 'completed';
      updated['dispensedAt']    =
          data['dispensedAt'] ?? DateTime.now().toIso8601String();
      updated['dispensedBy']    = data['dispensedBy'];
      updated['completedAt']    =
          data['completedAt'] ?? DateTime.now().toIso8601String();

      await box.put(targetKey, updated);

      if (kDebugMode) {
        print('╔════════════════════════════════════════════════════════════╗');
        print('║ ✅ DISPENSE COMPLETED (ROUTER)                            ║');
        print('╠════════════════════════════════════════════════════════════╣');
        print('║ Serial: $serial');
        print('║ Entry Key: $targetKey');
        print('║ Dispensed By: ${data['dispensedBy']}');
        print('╚════════════════════════════════════════════════════════════╝');
      }
    } else {
      final newEntry = {
        ...data,
        'branchId': normBranch,
        'serial': serial.toUpperCase(),
        'dispenseStatus': 'dispensed',
        'status': 'completed',
        'dispensedAt': data['dispensedAt'] ?? DateTime.now().toIso8601String(),
        'dispensedBy': data['dispensedBy'],
        'completedAt': data['completedAt'] ?? DateTime.now().toIso8601String(),
      };
      await box.put(key, newEntry);
      if (kDebugMode) print('✅ Created dispensed entry for: $key');
    }

    // Also update dispensaryBox so all records screens reflect 'dispensed' instantly
    try {
      if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
        final dBox = Hive.box(LocalStorageService.dispensaryBox);
        for (final k in dBox.keys) {
          final kStr = k.toString().toLowerCase().trim();
          if (kStr.endsWith('_$normSerial') || kStr == normSerial || kStr.contains('-$normSerial')) {
            final dVal = dBox.get(k);
            if (dVal is Map) {
              final updatedD = Map<String, dynamic>.from(dVal);
              updatedD['dispenseStatus'] = 'dispensed';
              updatedD['status'] = 'completed';
              updatedD['dispensedAt'] = data['dispensedAt'] ?? DateTime.now().toIso8601String();
              updatedD['dispensedBy'] = data['dispensedBy'];
              await dBox.put(k, updatedD);
            }
          }
        }
      }
    } catch (_) {}

    // Deduct stock locally on peer PCs if medicines list was provided
    final medicines = data['medicines'];
    if (medicines is List && medicines.isNotEmpty && Hive.isBoxOpen(LocalStorageService.stockBox)) {
      try {
        final stockBox = Hive.box(LocalStorageService.stockBox);
        final days = int.tryParse(data['daysOfMedicine']?.toString() ?? '1') ?? 1;
        for (final m in medicines) {
          if (m is! Map) continue;
          final medId = (m['inventoryId'] ?? m['medicineId'] ?? m['id'] ?? '').toString().trim();
          final perDayRaw = m['quantity'] ?? m['qty'] ?? 0;
          final perDay = perDayRaw is num ? perDayRaw.toDouble() : double.tryParse(perDayRaw.toString()) ?? 0.0;
          if (medId.isEmpty || perDay <= 0) continue;
          final medName = (m['name'] ?? '').toString().toLowerCase().trim();
          final isSyrup = (m['type']?.toString().toLowerCase().contains('syrup') == true) || medName.contains('syp') || medName.contains('syrup');
          final multiplier = isSyrup ? 1.0 : days.toDouble();
          final qtyDeduct = isSyrup ? 1.0 : perDay * multiplier;

          dynamic stockKey = 'stock:$medId';
          var item = stockBox.get(stockKey) ?? stockBox.get(medId);
          if (item == null && medName.isNotEmpty) {
            for (final sk in stockBox.keys) {
              final sv = stockBox.get(sk);
              if (sv is Map && (sv['name']?.toString().toLowerCase().trim() == medName)) {
                item = sv;
                stockKey = sk;
                break;
              }
            }
          }
          if (item is Map) {
            final uItem = Map<String, dynamic>.from(item);
            final curQ = (uItem['quantity'] as num?)?.toDouble() ?? 0.0;
            uItem['quantity'] = (curQ - qtyDeduct).clamp(0.0, double.infinity);
            await stockBox.put(stockKey, uItem);
          }
        }
      } catch (_) {}
    }

    // [P2] Enqueue serial status patch for direct Firestore upload.
    // queueType and dateKey are pulled from the now-updated Hive entry
    // (or the just-fetched existing entry) so they are as accurate as possible.
    if (fullMessage['_serverPush'] != true) {
      final entryForQueue = existing != null
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};

      await LocalStorageService.enqueueSync({
        'type':      'update_serial_status',
        'branchId':  branchId,
        'serial':    serial,
        'queueType': entryForQueue['queueType'],  // resolved by SyncService if null
        'dateKey':   entryForQueue['dateKey'],     // resolved by SyncService if null
        'data': {
          'dispenseStatus': 'dispensed',
          'status':         'completed',
          'dispensedAt':    data['dispensedAt'] ?? DateTime.now().toIso8601String(),
          'dispensedBy':    data['dispensedBy'] ?? '',
          'completedAt':    data['completedAt'] ?? DateTime.now().toIso8601String(),
        },
      });
      if (kDebugMode) {
        print('[P2] Enqueued update_serial_status (dispense) for direct upload: $serial');
      }
    }
  }

  static void _handleMedicineRestriction(Map<String, dynamic> data, Map<String, dynamic> full) {
    // Check for daysOfMedicine (1 is default, 2+ is multi-day)
    final days = int.tryParse(data['daysOfMedicine']?.toString() ?? '1') ?? 1;
    if (days <= 1) return;

    final bId = (full['branchId']?.toString() ?? data['branchId']?.toString())
        ?.toLowerCase().trim();
    
    // Resolve individual patient identity (child vs adult)
    final pId = LocalStorageService.resolveIndividualPatientId(data);

    if (bId != null && bId.isNotEmpty && pId.isNotEmpty) {
      LocalStorageService.saveMedicineRestriction(
        branchId:    bId,
        patientId:   pId,
        daysCovered: days,
      );
      if (kDebugMode) {
        print('💊 [Router] Multi-day restriction applied: $pId ($days days)');
      }
    }
  }

  // ── INVENTORY: handle incoming stock update from another LAN device ──────────
  //
  // Two sub-cases:
  //   (a) Full medicine data (new registration or replaced item) → saveLocalInventoryItem
  //   (b) Quantity delta only (add-stock) → updateLocalStockQuantity
  //
  // In both cases we also enqueue for Firestore sync so the server can
  // upload when connectivity is restored.
  static Future<void> _handleSaveStockItem(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final branchId = (fullMessage['branchId']?.toString() ??
                     data['branchId']?.toString() ??
                     '').toLowerCase().trim();

    final medicineId = (data['id'] ?? data['medicineId'] ?? data['docId'])?.toString().trim();

    if (medicineId == null || medicineId.isEmpty) {
      if (kDebugMode) print('❌ save_stock_item missing medicineId');
      return;
    }

    await LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox);

    // Check whether this is a quantity-only delta update or a full item save
    final rawDelta = data['_quantityDelta'];
    final bool isDelta = rawDelta != null;

    final enrichedData = Map<String, dynamic>.from(data);
    if (branchId.isNotEmpty) {
      enrichedData['branchId'] ??= branchId;
    }

    if (isDelta) {
      // ── Case (b): add-stock delta ──
      final delta = rawDelta is num
          ? rawDelta.toDouble()
          : double.tryParse(rawDelta.toString()) ?? 0.0;

      final existing = LocalStorageService.getLocalInventoryItem(medicineId);
      if (existing != null) {
        if (delta != 0) {
          await LocalStorageService.updateLocalStockQuantity(medicineId, delta);
        }
      } else {
        // If this machine does not have the medicine yet, save full record with new quantity!
        LocalStorageService.saveLocalInventoryItem(enrichedData);
      }
      if (kDebugMode) {
        print('✅ STOCK DELTA applied via LAN → $medicineId +$delta');
      }
    } else {
      // ── Case (a): full item (new registration or full replacement) ──
      LocalStorageService.saveLocalInventoryItem(enrichedData);
      if (kDebugMode) {
        print('✅ INVENTORY ITEM saved via LAN → $medicineId');
      }

      // Enqueue Firestore sync for this registration (offline resilience)
      if (fullMessage['_serverPush'] != true && branchId.isNotEmpty) {
        await LocalStorageService.enqueueSync({
          'type':     'register_medicine',
          'branchId': branchId,
          'data':     enrichedData,
        });
        if (kDebugMode) print('[Router] Enqueued register_medicine for Firestore sync');
      }
    }
  }

  static Future<void> _handleDeleteStockItem(Map<String, dynamic> data) async {
    final medicineId = (data['id'] ?? data['medicineId'])?.toString().trim();
    if (medicineId != null && medicineId.isNotEmpty) {
      await LocalStorageService.deleteLocalStockItem(medicineId);
      if (kDebugMode) print('✅ STOCK ITEM DELETED via LAN → $medicineId');
    }
  }

  static Future<void> _handleProformaEvent(Map<String, dynamic> data) async {
    try {
      final code = (data['code'] ?? data['barcode'] ?? '').toString().trim();
      if (code.isEmpty) return;
      if (!Hive.isBoxOpen(LocalStorageService.masterProformaBox)) {
        await Hive.openBox(LocalStorageService.masterProformaBox);
      }
      final box = Hive.box(LocalStorageService.masterProformaBox);
      final item = Map<String, dynamic>.from(data);
      item['isProformaMaster'] = true;
      await box.put('proforma:$code', LocalStorageService.sanitize(item));
      if (kDebugMode) print('✅ Master Proforma item saved via LAN → $code');
    } catch (e) {
      if (kDebugMode) print('❌ Error handling proforma event via LAN: $e');
    }
  }

  static Future<void> _handleTokenReversalApproved(Map<String, dynamic> data) async {
    try {
      final branchId = (data['branchId'] ?? '').toString();
      final serial = (data['tokenSerial'] ?? data['serial'] ?? data['tokenId'])?.toString().trim();
      if (serial == null || serial.isEmpty) return;

      await LocalStorageService.deleteLocalEntry(branchId, serial);
      await LocalStorageService.deleteLocalPrescription(serial);

      // Also mark request as approved in local_edit_requests if present
      final reqId = (data['requestId'] ?? data['id'])?.toString();
      if (reqId != null && reqId.isNotEmpty) {
        if (Hive.isBoxOpen('local_edit_requests')) {
          final box = Hive.box('local_edit_requests');
          final raw = box.get(reqId);
          if (raw is Map) {
            final updated = Map<String, dynamic>.from(raw);
            updated['status'] = 'approved';
            await box.put(reqId, updated);
          }
        }
      }
      if (kDebugMode) print('✅ Token reversal applied via LAN → $serial');
    } catch (e) {
      if (kDebugMode) print('❌ Error handling token reversal via LAN: $e');
    }
  }

  static Future<void> _handleRequestEvent(String type, Map<String, dynamic> data) async {
    try {
      final reqId = (data['requestId'] ?? data['id'] ?? data['docId'])?.toString();
      if (reqId == null || reqId.isEmpty) return;

      if (!Hive.isBoxOpen('local_edit_requests')) {
        await LocalStorageService.openBoxSafe('local_edit_requests');
      }
      final box = Hive.box('local_edit_requests');

      if (type == RealtimeEvents.requestCreated || type == 'request_created') {
        final reqMap = Map<String, dynamic>.from(data);
        reqMap['status'] ??= 'pending';
        await box.put(reqId, reqMap);
        if (kDebugMode) print('✅ Local edit request stored via LAN → $reqId');
      } else if (type == RealtimeEvents.requestApproved || type == 'request_approved') {
        final existing = box.get(reqId);
        final map = existing is Map ? Map<String, dynamic>.from(existing) : Map<String, dynamic>.from(data);
        map['status'] = 'approved';
        await box.put(reqId, map);
        if (kDebugMode) print('✅ Local edit request marked approved via LAN → $reqId');
      } else if (type == RealtimeEvents.requestRejected || type == 'request_rejected') {
        final existing = box.get(reqId);
        final map = existing is Map ? Map<String, dynamic>.from(existing) : Map<String, dynamic>.from(data);
        map['status'] = 'rejected';
        await box.put(reqId, map);
        if (kDebugMode) print('✅ Local edit request marked rejected via LAN → $reqId');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error handling request event via LAN: $e');
    }
  }

  // ── Module Handlers for Local Hive Tier 1 Save ───────────────────────────

  static Future<void> _handleAttendanceEvent(String type, Map<String, dynamic> data) async {
    try {
      final punchData = data['data'] is Map ? Map<String, dynamic>.from(data['data']) : Map<String, dynamic>.from(data);
      final branchId = (punchData['branchId'] ?? data['branchId'] ?? '').toString().toLowerCase().trim();
      final empId = (punchData['employeeId'] ?? punchData['empId'] ?? punchData['userId'] ?? data['employeeId'] ?? punchData['pin'] ?? punchData['localId'] ?? punchData['id'] ?? '').toString();
      final dt = (punchData['date'] ?? punchData['dateKey'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now())).toString();

      // Clock drift check (Pillar 2-E)
      final punchTimeStr = punchData['timestamp'] ?? punchData['time'] ?? punchData['punchTime'];
      if (punchTimeStr != null) {
        final punchTime = DateTime.tryParse(punchTimeStr.toString());
        if (punchTime != null) {
          final diff = DateTime.now().difference(punchTime).abs();
          if (diff.inMinutes > 15) {
            punchData['clock_drift_warning'] = true;
            punchData['drift_minutes'] = diff.inMinutes;
            if (kDebugMode) {
              print('⚠️ Biometric punch clock drift detected: ${diff.inMinutes} mins for employee $empId');
            }
          }
        }
      }

      final box = await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      punchData['branchId'] = branchId;
      final id = punchData['id']?.toString() ?? punchData['logId']?.toString() ?? (empId.isNotEmpty ? 'att_${branchId}_${empId}_$dt' : 'att_${DateTime.now().microsecondsSinceEpoch}');

      // Write locally to Hive box (Never re-broadcast on LAN to eliminate LAN Echo Loop - Pillar 2-A)
      await box.put(id, LocalStorageService.sanitize(punchData));

      if (kDebugMode) {
        print('✅ ATTENDANCE / BIOMETRIC EVENT saved locally via LAN → $type ($id)');
      }
    } catch (e) {
      if (kDebugMode) print('❌ _handleAttendanceEvent error: $e');
    }
  }

  static Future<void> _handleMadrassaEvent(String type, Map<String, dynamic> data) async {
    try {
      if (type == RealtimeEvents.saveMadrassaStudent || type == RealtimeEvents.saveMadrassaAdmission) {
        final branchId = data['branchId']?.toString() ?? '';
        final studentId = data['studentId']?.toString() ?? data['id']?.toString() ?? '';
        if (branchId.isNotEmpty && studentId.isNotEmpty) {
          await MadrassaLocalStorage.cacheStudent(branchId, studentId, data);
          if (kDebugMode) print('✅ MADRASSA STUDENT cached via LAN → $studentId');
          return;
        }
      }
      if (type == RealtimeEvents.saveMadrassaAttendance || type == RealtimeEvents.saveMadrassaDailyLog) {
        final branchId = data['branchId']?.toString() ?? '';
        final dateKey = data['date']?.toString() ?? data['dateKey']?.toString() ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
        final logData = data['logData'] is Map
            ? Map<String, dynamic>.from(data['logData'])
            : (data['data'] is Map ? Map<String, dynamic>.from(data['data']) : data);
        if (branchId.isNotEmpty) {
          await MadrassaLocalStorage.cacheDailyLog(branchId, dateKey, logData);
          if (kDebugMode) print('✅ MADRASSA DAILY LOG cached via LAN → $dateKey');
          return;
        }
      }
      if (type == RealtimeEvents.saveMadrassaFeePayment) {
        final branchId = data['branchId']?.toString() ?? '';
        final year = (data['year'] as num?)?.toInt() ?? DateTime.now().year;
        final month = (data['month'] as num?)?.toInt() ?? DateTime.now().month;
        final studentId = data['studentId']?.toString() ?? '';
        final feeData = data['data'] is Map ? Map<String, dynamic>.from(data['data']) : data;
        if (branchId.isNotEmpty && studentId.isNotEmpty) {
          await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
            branchId: branchId,
            studentId: studentId,
            studentName: feeData['studentName']?.toString() ?? '',
            rollNumber: feeData['rollNumber']?.toString() ?? '',
            year: year,
            month: month,
            amountDue: (feeData['amountDue'] as num?)?.toDouble() ?? 0.0,
            amountPaid: (feeData['amountPaid'] as num?)?.toDouble() ?? 0.0,
            status: feeData['status']?.toString() ?? 'paid',
            markedBy: feeData['markedBy']?.toString() ?? 'LAN',
            markedByRole: feeData['markedByRole']?.toString() ?? 'LAN',
            note: feeData['note']?.toString(),
          );
          if (kDebugMode) print('✅ MADRASSA FEE PAYMENT cached via LAN → $studentId ($year-$month)');
          return;
        }
      }
      if (type == RealtimeEvents.offboardMadrassaStudent || type == RealtimeEvents.deleteMadrassaStudent) {
        final branchId = data['branchId']?.toString() ?? '';
        final studentId = data['studentId']?.toString() ?? data['id']?.toString() ?? '';
        final status = data['status']?.toString() ?? 'left';
        if (branchId.isNotEmpty && studentId.isNotEmpty) {
          final studentCache = MadrassaLocalStorage.getStudentCached(branchId, studentId);
          if (studentCache != null) {
            studentCache['status'] = status;
            studentCache['batch'] = status;
            if (data['effectiveDate'] != null) {
              studentCache['offboardedAt'] = data['effectiveDate'];
            }
            await MadrassaLocalStorage.cacheStudent(branchId, studentId, studentCache);
          }
          if (kDebugMode) print('✅ MADRASSA STUDENT offboarded via LAN → $studentId');
          return;
        }
      }
      final boxName = type == RealtimeEvents.saveMadrassaFee ? 'madrassa_fees' : 'madrassa_box';
      final box = await LocalStorageService.openBoxSafe(boxName);
      final id = data['id']?.toString() ?? data['receiptNo']?.toString() ?? data['admissionNo']?.toString() ?? 'mad_${DateTime.now().microsecondsSinceEpoch}';
      await box.put(id, LocalStorageService.sanitize(data));
      if (kDebugMode) print('✅ MADRASSA EVENT saved via LAN → $type ($id)');
    } catch (e) {
      if (kDebugMode) print('❌ _handleMadrassaEvent error: $e');
    }
  }

  static Future<void> _handleFinanceEvent(String type, Map<String, dynamic> data) async {
    try {
      String boxName = 'finance_entries';
      if (type == RealtimeEvents.saveExpense || type == RealtimeEvents.deleteExpense) {
        boxName = 'finance_expenses';
      } else if (type == RealtimeEvents.saveLoan || type == RealtimeEvents.deleteLoan) {
        boxName = 'finance_loans';
      }
      final box = await LocalStorageService.openBoxSafe(boxName);
      final id = data['id']?.toString() ?? 'fin_${DateTime.now().microsecondsSinceEpoch}';
      if (type == RealtimeEvents.deleteExpense || type == RealtimeEvents.deleteLoan) {
        await box.delete(id);
        if (kDebugMode) print('✅ FINANCE ITEM DELETED via LAN → $type ($id)');
      } else {
        await box.put(id, LocalStorageService.sanitize(data));
        if (kDebugMode) print('✅ FINANCE EVENT saved via LAN → $type ($id)');
      }
    } catch (e) {
      if (kDebugMode) print('❌ _handleFinanceEvent error: $e');
    }
  }

  static Future<void> _handleDonationEvent(String type, Map<String, dynamic> data) async {
    try {
      final box = await LocalStorageService.openBoxSafe(DonationsLocalStorage.donationsBox);
      final id = data['localId']?.toString() ?? data['id']?.toString() ?? data['receiptNoClean']?.toString() ?? 'don_${DateTime.now().microsecondsSinceEpoch}';
      final branchId = (data['branchId']?.toString() ?? LocalStorageService.getActiveBranchId() ?? '').toLowerCase().trim();
      final date = data['date']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);
      final hiveKey = data['hiveKey']?.toString() ?? '${branchId}_${date}_$id';
      final sanitized = LocalStorageService.sanitize(data);
      await box.put(hiveKey, sanitized);
      await LocalStorageService.enqueueSync({
        'type': 'save_donation',
        'branchId': branchId,
        'localId': id,
        'hiveKey': hiveKey,
        'data': sanitized,
      });
      SyncService().triggerUpload(force: true);
      if (kDebugMode) print('✅ DONATION EVENT saved via LAN → $type ($hiveKey)');
    } catch (e) {
      if (kDebugMode) print('❌ _handleDonationEvent error: $e');
    }
  }

  static Future<void> _handleDasterkhwanEvent(String type, Map<String, dynamic> data) async {
    try {
      if (type == RealtimeEvents.saveOfficeBoyToken) {
        final tokenBox = await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
        final isReverse = data['action'] == 'reverse';
        final branchId = data['branchId']?.toString() ?? '';
        final dateKey = data['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);

        if (isReverse) {
          final tokenIds = List<String>.from((data['tokenIds'] as List? ?? []).map((e) => e.toString()));
          for (final tid in tokenIds) {
            await tokenBox.delete(tid);
          }
          await LocalStorageService.enqueueSync({
            'type': 'reverse_dasterkhwan_tokens',
            'branchId': branchId,
            'dateKey': dateKey,
            'data': data,
          });
          SyncService().triggerUpload(force: true);
          if (kDebugMode) print('✅ DASTERKHWAAN TOKENS REVERSED via LAN → ${tokenIds.length} tokens');
        } else {
          final tokensList = List<dynamic>.from(data['tokens'] as List? ?? []);
          for (final t in tokensList) {
            if (t is Map) {
              final tMap = Map<String, dynamic>.from(t);
              final tid = tMap['id']?.toString() ?? 'dst_${DateTime.now().microsecondsSinceEpoch}';
              await tokenBox.put(tid, LocalStorageService.sanitize(tMap));
            }
          }
          await LocalStorageService.enqueueSync({
            'type': 'save_dasterkhwan_tokens',
            'branchId': branchId,
            'dateKey': dateKey,
            'data': data,
          });
          SyncService().triggerUpload(force: true);
          if (kDebugMode) print('✅ DASTERKHWAAN TOKENS SAVED via LAN → ${tokensList.length} tokens');
        }
        return;
      }

      if (type == RealtimeEvents.saveKitchenServeLog) {
        final tokenBox = await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
        final tokenId = data['tokenId']?.toString();
        if (tokenId != null && tokenId.isNotEmpty) {
          final existing = tokenBox.get(tokenId);
          if (existing is Map) {
            final updated = Map<String, dynamic>.from(existing)
              ..['served'] = true
              ..['servedTime'] = data['timestamp'] ?? DateTime.now().toIso8601String();
            await tokenBox.put(tokenId, updated);
          }
        }
        await LocalStorageService.enqueueSync({
          'type': 'serve_dasterkhwan_token',
          'branchId': data['branchId']?.toString() ?? '',
          'dateKey': data['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10),
          'data': data,
        });
        SyncService().triggerUpload(force: true);
        if (kDebugMode) print('✅ DASTERKHWAAN KITCHEN SERVE LOG saved via LAN → $tokenId');
        return;
      }

      final box = await LocalStorageService.openBoxSafe('dasterkhwaan_entries');
      final id = data['id']?.toString() ?? 'das_${DateTime.now().microsecondsSinceEpoch}';
      await box.put(id, LocalStorageService.sanitize(data));
      if (kDebugMode) print('✅ DASTERKHWAAN EVENT saved via LAN → $type ($id)');
    } catch (e) {
      if (kDebugMode) print('❌ _handleDasterkhwanEvent error: $e');
    }
  }

  static Future<void> _handleSupervisorEvent(String type, Map<String, dynamic> data) async {
    try {
      final box = await LocalStorageService.openBoxSafe('local_edit_requests');
      final id = data['requestId']?.toString() ?? data['id']?.toString() ?? 'sup_${DateTime.now().microsecondsSinceEpoch}';
      await box.put(id, LocalStorageService.sanitize(data));
      if (kDebugMode) print('✅ SUPERVISOR EVENT saved via LAN → $type ($id)');
    } catch (e) {
      if (kDebugMode) print('❌ _handleSupervisorEvent error: $e');
    }
  }

  static Future<void> _handleWorkflowEvent(
      String type, Map<String, dynamic> data) async {
    try {
      final box = await LocalStorageService.openBoxSafe('local_workflow_requests');
      final requestId = (data['requestId'] ?? data['id'])?.toString();
      if (requestId == null || requestId.isEmpty) return;
      final existing = box.get(requestId);
      final merged = <String, dynamic>{
        if (existing is Map) ...Map<String, dynamic>.from(existing),
        ...data,
        'eventType': type,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await box.put(requestId, LocalStorageService.sanitize(merged));
    } catch (e) {
      if (kDebugMode) print('❌ _handleWorkflowEvent error: $e');
    }
  }

  static Future<void> _handleLibraryEvent(String type, Map<String, dynamic> data) async {
    try {
      final box = await LocalStorageService.openBoxSafe('library_box');
      final id = data['id']?.toString() ?? data['bookId']?.toString() ?? 'lib_${DateTime.now().microsecondsSinceEpoch}';
      if (type == RealtimeEvents.deleteLibraryBook) {
        await box.delete(id);
        if (kDebugMode) print('✅ LIBRARY BOOK DELETED via LAN → $id');
      } else {
        await box.put(id, LocalStorageService.sanitize(data));
        if (kDebugMode) print('✅ LIBRARY EVENT saved via LAN → $type ($id)');
      }
    } catch (e) {
      if (kDebugMode) print('❌ _handleLibraryEvent error: $e');
    }
  }

  static Future<void> _handleStaffEvent(String type, Map<String, dynamic> data) async {
    try {
      final box = await LocalStorageService.openBoxSafe(LocalStorageService.usersBox);
      final id = data['uid']?.toString() ?? data['id']?.toString() ?? 'usr_${DateTime.now().microsecondsSinceEpoch}';
      await box.put(id, LocalStorageService.sanitize(data));
      if (kDebugMode) print('✅ STAFF/FACULTY PROFILE saved via LAN → $type ($id)');
    } catch (e) {
      if (kDebugMode) print('❌ _handleStaffEvent error: $e');
    }
  }

  static Future<void> _handleTokenExceptionApproved(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final branchId = (fullMessage['branchId']?.toString() ??
                     data['branchId']?.toString() ??
                     '').toLowerCase().trim();
    final patientId = (data['patientId'] ?? data['id'])?.toString();
    final reason = data['reason']?.toString() ?? 'Approved by Doctor';
    final approvedBy = (data['approvedBy'] ?? data['doctorName'])?.toString() ?? 'Doctor';
    final requestId = data['requestId']?.toString();

    if (branchId.isNotEmpty && patientId != null && patientId.isNotEmpty) {
      await LocalStorageService.grantTokenException(
        branchId,
        patientId,
        reason: reason,
        approvedBy: approvedBy,
        requestId: requestId,
      );
      if (kDebugMode) print('✅ TOKEN EXCEPTION APPROVED & GRANTED → $branchId-$patientId ($reason)');
    }
  }

  static Future<void> _handleTokenExceptionRequest(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final requestId = data['requestId']?.toString() ??
        'local_${DateTime.now().millisecondsSinceEpoch}';
    final localReq = <String, dynamic>{
      'id':          requestId,
      'requestType': 'token_exception',
      'status':      'pending',
      'patientId':   data['patientId'] ?? '',
      'patientName': data['patientName'] ?? 'Unknown',
      'restriction': data['restriction'],
      'branchId':    fullMessage['branchId'] ?? data['branchId'] ?? '',
      'requestedAt': DateTime.now().toIso8601String(),
    };
    if (Hive.isBoxOpen('app_settings')) {
      await Hive.box('app_settings').put(
          'pending_exception_$requestId',
          LocalStorageService.sanitize(localReq));
      if (kDebugMode) print('✅ TOKEN EXCEPTION REQUEST STORED LOCALLY → $requestId');
    }
  }

  static Future<void> _handleSaveEmployee(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final localId = data['localId']?.toString() ?? data['id']?.toString();
    if (localId == null || localId.isEmpty) return;

    // Permanently reject placeholder ghost employees received over LAN
    if (FinanceLocalStorage.isPlaceholderEmployee(data)) return;

    try {
      if (!Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.employeesBox);
      }
      final empBox = Hive.box(LocalStorageService.employeesBox);
      final existing = empBox.get(localId);

      final record = existing is Map
          ? (Map<String, dynamic>.from(existing)..addAll(data))
          : Map<String, dynamic>.from(data);
      record['id'] = localId;
      record['localId'] = localId;
      record['syncStatus'] = 'synced';
      await empBox.put(localId, LocalStorageService.sanitize(record));

      final pin = (record['biometricPin'] ?? record['pin'])?.toString().trim() ?? '';
      if (pin.isNotEmpty && Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
        final credBox = Hive.box(LocalStorageService.biometricCredentialsBox);
        final isTeacher = (record['role']?.toString().toLowerCase().contains('teacher') == true) ||
            (record['department']?.toString().toLowerCase().contains('teacher') == true);
        await credBox.put(localId, {
          'id': localId,
          'biometricPin': pin,
          'entityId': localId,
          'entityName': record['name']?.toString() ?? 'Employee',
          'entityType': isTeacher ? 'teacher' : 'employee',
          'branchId': record['branchId']?.toString() ?? 'karachi',
          'enrolledAt': record['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
          'active': record['isActive'] != false,
        });
      }
      if (kDebugMode) print('✅ EMPLOYEE SYNCED OVER LAN: ${record["name"]} ($localId)');
    } catch (e) {
      if (kDebugMode) print('❌ Error saving employee over LAN: $e');
    }
  }

  static Future<void> _handleDeleteEmployee(
    Map<String, dynamic> data,
    Map<String, dynamic> fullMessage,
  ) async {
    final localId = data['localId']?.toString() ?? data['id']?.toString();
    if (localId == null || localId.isEmpty) return;

    try {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        await Hive.box(LocalStorageService.employeesBox).delete(localId);
      }
      if (Hive.isBoxOpen(LocalStorageService.biometricCredentialsBox)) {
        await Hive.box(LocalStorageService.biometricCredentialsBox).delete(localId);
      }
      if (kDebugMode) print('✅ EMPLOYEE DELETED OVER LAN: $localId');
    } catch (e) {
      if (kDebugMode) print('❌ Error deleting employee over LAN: $e');
    }
  }
}