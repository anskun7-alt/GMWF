import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/donations_local_storage.dart';
import 'package:gmwf/pages/madrassa/utils/madrassa_local_storage.dart';
import 'package:gmwf/services/finance_local_storage.dart';
import 'package:gmwf/services/finance_loans_storage.dart';
import 'package:gmwf/services/finance_expenses_storage.dart';
import 'package:gmwf/services/permission_service.dart';
import 'package:gmwf/services/quota_service.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:gmwf/services/serials_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/offline_auth_service.dart';

import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/services/auto_update_service.dart';
import 'package:gmwf/services/zkteco_network_service.dart';
import 'package:gmwf/realtime/connection_manager.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();
  bool _isUploading = false;
  String? _currentBranchId;
  List<String> _authorizedBranches = [];
  String? _currentUserRole;

  /// Ensures any branch string is strictly sanitized so 'all', 'global', or CNIC IDs are NEVER used as branch documents.
  String _cleanBranch(dynamic b, {String? fallback}) {
    return LocalStorageService.sanitizeBranchId(
      b?.toString(),
      fallback: fallback ?? _currentBranchId ?? 'karachi',
    );
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _dailyTokenTimer;
  Timer? _periodicSyncTimer;

  void start(String branchId, {List<String>? authorizedBranches}) {
    _currentBranchId = _cleanBranch(branchId);
    _authorizedBranches = (authorizedBranches ?? [])
        .map((b) => _cleanBranch(b))
        .where((b) => LocalStorageService.isValidBranchId(b))
        .toSet()
        .toList();

    NetworkHealthService().start();
    
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        triggerUpload();
      }
    });

    _setupDailyTokenRefresh(branchId);
    
    _periodicSyncTimer?.cancel();
    // 4-hour periodic sync for historical/report data delta syncing with overnight silence (22:00 - 06:00).
    // Live operational updates use LAN WebSockets and reactive local storage.
    _periodicSyncTimer = Timer.periodic(const Duration(hours: 4), (_) {
      final now = DateTime.now();
      if (now.hour >= 22 || now.hour < 6) {
        Logger().d("SyncService: Periodic sync skipped during overnight silence window (22:00 - 06:00)");
        return;
      }
      triggerUpload();
    });

    triggerUpload();
    Logger().d("SyncService started for branch: $branchId");
  }

  void updateAuthorizedBranches(List<String> branchIds) {
    _authorizedBranches = branchIds;
    Logger().d("SyncService: Updated authorized branches: $branchIds");
    triggerUpload();
  }

  Future<void> _enqueueMissingDonations(String branchId) async {
    try {
      final donationsBox = Hive.box(DonationsLocalStorage.donationsBox);
      final syncBox      = Hive.box(LocalStorageService.syncBox);
      
      final alreadyQueued = syncBox.values
          .where((v) => v['type'] == 'save_donation')
          .map((v) => v['localId']?.toString())
          .toSet();

      int queued = 0;
      for (final key in donationsBox.keys) {
        final keyStr = key.toString();
        final raw = donationsBox.get(key);
        if (raw == null || raw is! Map) continue;

        final data = Map<String, dynamic>.from(raw);
        if (data['syncStatus'] != 'pending') continue;

        final localId = data['localId']?.toString();
        if (localId == null || localId.isEmpty) continue;
        if (alreadyQueued.contains(localId)) continue;

        await LocalStorageService.enqueueSync({
          'type': 'save_donation',
          'branchId': branchId,
          'localId': localId,
          'hiveKey': keyStr,
          'data': data,
        });
        queued++;
      }
      
      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued pending donations for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingDonations error: $e');
    }
  }

  void _setupDailyTokenRefresh(String branchId) {
    final now          = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1, 0, 5);
    var duration       = nextMidnight.difference(now);
    if (duration.isNegative) duration += const Duration(days: 1);

    _dailyTokenTimer?.cancel();
    _dailyTokenTimer = Timer(duration, () async {
      await LocalStorageService.downloadTodayTokens(branchId);
      _setupDailyTokenRefresh(branchId);
    });
  }

  Future<void> triggerUpload({bool force = false}) async {
    if (_currentBranchId == null) return;

    bool isOnline = true;
    try {
      if (!NetworkHealthService().isStableOnline) {
        isOnline = false;
      } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        final connectivity = await Connectivity().checkConnectivity();
        isOnline = connectivity.any((r) => r != ConnectivityResult.none);
      }
    } catch (_) {
      isOnline = NetworkHealthService().isStableOnline;
    }

    if (isOnline && !_isUploading) {
      // Dual Sync Rule:
      // If local LAN server is running on this machine, ServerSyncManager handles the scheduled cloud sync passes.
      // If this is a client station connected to the LAN server, ServerSyncManager on the server handles the cloud sync passes.
      // BUT if the server is NOT connected at the time of sync (standalone/offsite), the client independently runs its sync pass!
      final bool isLocalServer = ZkTecoNetworkService.isServerRunningNotifier.value;
      final bool isServerConnected = ConnectionManager().isConnected;
      final bool hasLocalPending = Hive.isBoxOpen(LocalStorageService.syncBox) &&
          Hive.box(LocalStorageService.syncBox).isNotEmpty;

      if (!force && !isLocalServer && isServerConnected && !hasLocalPending) {
        Logger().d("SyncService: LAN server is connected and active. Scheduled sync deferred to ServerSyncManager on the server.");
        return;
      }
      if (_currentUserRole == null) {
        try {
          final userData = await OfflineAuthService.getCachedUserData();
          if (userData != null) {
            _currentUserRole = userData['role'] as String?;
          }
        } catch (_) {}
      }

      await _uploadPending();

      final remainingQueue = Hive.box(LocalStorageService.syncBox).length;
      if (remainingQueue == 0) {
        try {
          final branchesToSync = <String>{};
          final activeB = (_currentBranchId ?? '').toLowerCase().trim();
          if (activeB.isNotEmpty && activeB != 'all' && activeB != 'global') {
            branchesToSync.add(activeB);
          } else if (_authorizedBranches.isNotEmpty) {
            branchesToSync.addAll(_authorizedBranches);
          }

          final settings = Hive.box('app_settings');
          for (final bId in branchesToSync) {
            final lastRefreshStr = settings.get('last_refresh_$bId') as String?;
            final lastRefresh = lastRefreshStr != null ? DateTime.tryParse(lastRefreshStr) : null;
            final now = DateTime.now();
            // Cooldown raised to 2 hours to match historical periodic timer
            // and prevent redundant full/delta scans on rapid connectivity events.
            if (force) {
              await settings.put('last_refresh_$bId', now.toIso8601String());
              await _refreshDataForBranch(bId);
              await Future.delayed(const Duration(milliseconds: 50));
            } else {
              Logger().d("[SyncService] Automatic post-upload refresh skipped (zero-read architecture)");
            }
          }
        } catch (e) {
          Logger().d("Refresh after upload failed: $e");
        }
      }
    }
  }

  Future<void> _refreshDataForBranch(String branchId) async {
    try {
      await LocalStorageService.downloadTodayTokens(branchId);
      await LocalStorageService.downloadInventory(branchId);
      await LocalStorageService.refreshPrescriptions(branchId);
      await LocalStorageService.downloadMedicineRestrictions(branchId);
      // [FIX-4.1] Periodic attendance download (participates in FinanceLocalStorage internal TTL guard)
      await FinanceLocalStorage.downloadAttendance(branchId);

      final role = _currentUserRole;

      // Only download donations if the user has donations permission
      final hasDonationsPerm = role == null ||
          PermissionService().hasPermission(role, AppPermission.viewDonations) ||
          PermissionService().hasPermission(role, AppPermission.manageDonations);
      if (hasDonationsPerm) {
        await DonationsLocalStorage.downloadAllDonations(branchId);
        await DonationsLocalStorage.downloadDonors(branchId);
      }

      // Only download Madrassa data if the user has madrassa permissions
      final hasMadrassaPerm = role == null ||
          PermissionService().hasPermission(role, AppPermission.manageMadrassa) ||
          PermissionService().hasPermission(role, AppPermission.manageMadrassaAdmin);
      if (hasMadrassaPerm) {
        await MadrassaLocalStorage.downloadStudents(branchId);
        await MadrassaLocalStorage.downloadLogsForMonth(branchId, DateTime.now().year, DateTime.now().month);
        await MadrassaLocalStorage.downloadHolidays(branchId);
        await MadrassaLocalStorage.downloadFeePaymentsForMonth(branchId, DateTime.now().year, DateTime.now().month);
      }

      // Finance bulk downloads (heavy collectionGroup scans) are intentionally
      // excluded from the periodic sync cycle. Call triggerFinanceRefresh()
      // explicitly when the Finance page is opened.
    } catch (e) {
      Logger().d("[SyncService] Error refreshing branch $branchId: $e");
    }
  }

  /// Call this when the Finance module is opened by the user.
  /// Respects the same TTL guards as FinanceLocalStorage so it won't hammer
  /// Firestore if the page is opened multiple times within the cooldown window.
  Future<void> triggerFinanceRefresh({bool force = false}) async {
    final branchId = _currentBranchId;
    if (branchId == null) return;

    final role = _currentUserRole;
    final hasFinancePerm = role == null ||
        PermissionService().hasPermission(role, AppPermission.manageFinance);
    if (!hasFinancePerm) return;

    Logger().d('[SyncService] triggerFinanceRefresh for $branchId (force=$force)');
    try {
      await FinanceLocalStorage.downloadEmployees(branchId);
      await FinanceLocalStorage.downloadSalaryHistory(branchId, force: force);
      await FinanceLocalStorage.downloadAttendance(branchId, force: force);
      await FinanceLocalStorage.downloadSalaryLedger(branchId);
      await FinanceLocalStorage.downloadFinanceSettings(branchId);
      await FinanceLocalStorage.downloadTransfers(branchId, force: force);
      await FinanceLocalStorage.downloadAuditLogs(branchId, force: force);
      await FinanceLocalStorage.downloadFinanceHolidays(branchId);
      await FinanceLocalStorage.downloadLoans(branchId);
      await FinanceExpensesStorage.downloadExpenses(branchId, force: force);
    } catch (e) {
      Logger().d('[SyncService] triggerFinanceRefresh error: $e');
    }
  }

  Future<void> _uploadPending() async {
    if (_isUploading || _currentBranchId == null) return;
    _isUploading = true;

    try {
      final queueBox = Hive.box(LocalStorageService.syncBox);
      if (queueBox.isEmpty) return;

      // Minimum-Version Fleet Lock Check
      try {
        final versionDoc = await _db.collection('app_config').doc('version').get();
        if (versionDoc.exists) {
          final minVersion = versionDoc.data()?['min_supported_version']?.toString();
          if (minVersion != null && AutoUpdateService.compareVersions(AutoUpdateService.currentVersion, minVersion) < 0) {
            debugPrint('[SyncService] ⛔ App version (${AutoUpdateService.currentVersion}) is below minimum supported version ($minVersion). Sync halted.');
            return;
          }
        }
      } catch (e) {
        debugPrint('[SyncService] Version check warning: $e');
      }

      // Fast purge bloated duplicates before processing
      if (queueBox.length > 50) {
        await LocalStorageService.purgeBloatedSyncQueue();
      }

      final allKeys = queueBox.keys.toList();
      if (allKeys.isEmpty) return;

      // Process in batches of up to 100 to avoid locking the isolate
      final batchKeys = allKeys.take(100).toList();

      for (final key in batchKeys) {
        final raw = queueBox.get(key);
        if (raw == null || raw is! Map) {
          await queueBox.delete(key);
          continue;
        }

        final action   = Map<String, dynamic>.from(raw);
        final type     = action['type'] as String? ?? 'unknown';
        final attempts = (action['attempts'] as int?) ?? 0;

        // Exponential backoff check (Pillar 2-C)
        final nextRetryAtStr = action['nextRetryAt'] as String?;
        if (nextRetryAtStr != null) {
          final nextRetry = DateTime.tryParse(nextRetryAtStr);
          if (nextRetry != null && DateTime.now().isBefore(nextRetry)) {
            continue; // Skip key until backoff window expires
          }
        }

        // Bounded retry: Route to dead letter queue after 20 attempts (Pillar 2-C)
        if (attempts >= 20) {
          action['lastFailureLoggedAt'] = DateTime.now().toIso8601String();
          await _flagPersistentSyncFailure(key, action, type);
          await LocalStorageService.moveToDeadLetterQueue(
            LocalStorageService.syncBox,
            key,
            action,
            reason: action['lastError']?.toString() ?? 'Exceeded max retry attempts (20)',
          );
          continue;
        }

        try {
          final branchId = _cleanBranch(action['branchId']);

          if (action['collection'] != null) {
            final colPath = action['collection'].toString().trim();
            final docId = action['docId']?.toString().trim();
            final act = (action['action'] ?? 'set').toString().toLowerCase().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});

            if (colPath.isNotEmpty && docId != null && docId.isNotEmpty) {
              final DocumentReference<Map<String, dynamic>> docRef;
              if (colPath.contains('/')) {
                docRef = _db.doc('$colPath/$docId');
              } else {
                docRef = _db.collection('branches').doc(branchId).collection(colPath).doc(docId);
              }

              if (act == 'delete') {
                await docRef.delete();
              } else {
                final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
                await docRef.set(fsData, SetOptions(merge: true));
              }

              // Update local cache status for school records
              try {
                final bId = branchId.toLowerCase().trim();
                if (colPath.contains('school_students') && Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
                  final sBox = Hive.box(LocalStorageService.schoolStudentsBox);
                  final key = '${bId}__$docId';
                  final r = sBox.get(key);
                  if (r is Map) await sBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                } else if (colPath.contains('school_teachers') && Hive.isBoxOpen(LocalStorageService.schoolTeachersBox)) {
                  final tBox = Hive.box(LocalStorageService.schoolTeachersBox);
                  final key = '${bId}__$docId';
                  final r = tBox.get(key);
                  if (r is Map) await tBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                } else if (colPath.contains('school_books') && Hive.isBoxOpen(LocalStorageService.schoolBooksBox)) {
                  final bBox = Hive.box(LocalStorageService.schoolBooksBox);
                  final key = '${bId}__$docId';
                  final r = bBox.get(key);
                  if (r is Map) await bBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                } else if (colPath.contains('school_book_loans') && Hive.isBoxOpen(LocalStorageService.schoolBookLoansBox)) {
                  final lBox = Hive.box(LocalStorageService.schoolBookLoansBox);
                  final key = '${bId}__$docId';
                  final r = lBox.get(key);
                  if (r is Map) await lBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                } else if (colPath.contains('school_grades') && Hive.isBoxOpen('school_grades')) {
                  final gBox = Hive.box('school_grades');
                  final key = '${bId}__$docId';
                  final r = gBox.get(key);
                  if (r is Map) await gBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                } else if (colPath.contains('school_fees') && Hive.isBoxOpen('school_fees')) {
                  final fBox = Hive.box('school_fees');
                  final key = '${bId}__$docId';
                  final r = fBox.get(key);
                  if (r is Map) await fBox.put(key, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_patient') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final patientId = (action['patientId'] ?? data['patientId'])?.toString();
            final bId       = (action['branchId'] ?? data['branchId'] ?? branchId).toString();
            if (patientId == null || patientId.isEmpty) throw Exception('Missing patientId');

            if (data['dob'] is String) {
              try {
                data['dob'] = Timestamp.fromDate(DateTime.parse(data['dob'] as String));
              } catch (_) {}
            }
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus')..remove('hiveKey');
            await _db.collection('branches').doc(bId).collection('patients').doc(patientId).set(fsData, SetOptions(merge: true));
            await Hive.box('app_flags').put('patient_synced_$patientId', true);
          }
          else if (type == 'delete_patient') {
            final patientId = action['patientId']?.toString();
            final bId       = (action['branchId'] ?? branchId).toString();
            if (patientId != null && patientId.isNotEmpty) {
              await _db.collection('branches').doc(bId).collection('patients').doc(patientId).delete();
              await Hive.box('app_flags').delete('patient_synced_$patientId');
            }
          }
          else if (type == 'delete_prescription') {
            final bId = (action['branchId'] ?? branchId).toString();
            final pCnic = action['patientCnic']?.toString() ?? '';
            final serial = action['serial']?.toString() ?? '';
            final path = action['path']?.toString() ?? '';
            if (path.isNotEmpty) {
              try {
                await _db.doc(path).delete();
              } catch (_) {}
            }
            if (pCnic.isNotEmpty && serial.isNotEmpty) {
              try {
                await _db.collection('branches').doc(bId).collection('patients').doc(pCnic).collection('prescriptions').doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('branches').doc(bId).collection('prescriptions').doc(pCnic).collection('prescriptions').doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('prescriptions').doc(pCnic).collection('prescriptions').doc(serial).delete();
              } catch (_) {}
            }
          }
          else if (type == 'delete_dispensary') {
            final bId     = (action['branchId'] ?? branchId).toString();
            final dateKey = action['dateKey']?.toString() ?? '';
            final serial  = action['serial']?.toString() ?? '';
            final path    = action['path']?.toString() ?? '';
            if (path.isNotEmpty) {
              try {
                await _db.doc(path).delete();
              } catch (_) {}
            }
            if (bId.isNotEmpty && dateKey.isNotEmpty && serial.isNotEmpty) {
              try {
                await _db.collection('branches').doc(bId).collection('dispensary').doc(dateKey).collection(dateKey).doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('branches').doc(bId).collection('dispensary').doc(dateKey).collection('dispensed').doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('branches').doc(bId).collection('dispensary').doc(serial).delete();
              } catch (_) {}
            }
          }
          else if (type == 'save_entry') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final dateKey = (action['dateKey'] ?? action['datePart'] ?? data['dateKey'])?.toString();
            final serial  = (action['serial'] ?? data['serial'])?.toString();
            if (dateKey == null || serial == null) throw Exception('Missing dateKey/serial');
            final queueType = resolveQueueType((action['queueType'] ?? data['queueType'])?.toString(), branchId: branchId);

            if (data['isTempSerial'] == true || action['isTempSerial'] == true) {
              final dispTag = (data['dispensaryTag'] ?? CampSessionService.getDispensaryKeyword(data['dispensaryId'])).toString();
              final result = await issueAtomicSerialTransaction(
                branchId: branchId,
                dispensaryTag: dispTag,
                queueType: queueType,
                tokenData: data,
              );
              final canonicalSerial = result['serial'] as String;
              await LocalStorageService.remapTempSerialToCanonical(
                branchId,
                serial,
                canonicalSerial,
                result['entryData'] as Map<String, dynamic>,
              );
            } else {
              final upperSerial = serial.trim().toUpperCase();
              data['serial'] = upperSerial;

              // Terminal Status Protection: Never overwrite completed/dispensed with waiting
              try {
                if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                  final eBox = Hive.box(LocalStorageService.entriesBox);
                  final localE = eBox.get('$branchId-$upperSerial') ?? eBox.get('$branchId-$serial');
                  if (localE is Map) {
                    final lDisp = (localE['dispenseStatus'] ?? '').toString().toLowerCase();
                    final lStat = (localE['status'] ?? '').toString().toLowerCase();
                    if (lDisp == 'dispensed' || lStat == 'completed') {
                      data['status'] = 'completed';
                      if (lDisp == 'dispensed') {
                        data['dispenseStatus'] = 'dispensed';
                        if (localE['dispensedAt'] != null) data['dispensedAt'] = localE['dispensedAt'];
                      }
                      if (localE['prescription'] != null) data['prescription'] = localE['prescription'];
                      if (localE['doctorName'] != null) data['doctorName'] = localE['doctorName'];
                      if (localE['completedAt'] != null) data['completedAt'] = localE['completedAt'];
                    }
                  }
                }
              } catch (_) {}

              final campDocKey = CampSessionService.getCampDateDocId(
                branchId: branchId,
                dateKey: dateKey,
                campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
                dispensaryTag: data['dispensaryTag']?.toString(),
                serial: upperSerial,
              );
              await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(upperSerial).set(data, SetOptions(merge: true));
              if (serial != upperSerial) {
                try {
                  await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial.toLowerCase()).delete();
                } catch (_) {}
              }
            }
          }
          else if (type == 'save_prescription') {
            final rawSerial = action['serial'] as String?;
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            if (rawSerial == null) throw Exception('Missing serial');
            final serial = rawSerial.trim().toUpperCase();
            data['serial'] = serial;
            
            final queueType = resolveQueueType(action['queueType']?.toString() ?? Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial')?['queueType']?.toString(), branchId: branchId);
            final dateKey   = action['dateKey']?.toString() ?? Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial')?['dateKey']?.toString() ?? LocalStorageService.getTodayDateKey();
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString(),
              serial: serial,
            );

            final updateMap = <String, dynamic>{
              'status':         'completed',
              'completedAt':    data['completedAt'] ?? DateTime.now().toUtc().toIso8601String(),
              'dispenseStatus': data['dispenseStatus'] ?? 'pending',
            };

            // Terminal Status Protection: Preserve dispensed status if already dispensed locally
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final localE = Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial');
                if (localE is Map && (localE['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') {
                  updateMap['dispenseStatus'] = 'dispensed';
                  if (localE['dispensedAt'] != null) updateMap['dispensedAt'] = localE['dispensedAt'];
                }
              }
            } catch (_) {}

            for (final f in ['doctorName', 'doctorId', 'daysOfMedicine', 'extraCharge', 'vitals', 'prescription', 'medicines', 'diagnosis', 'complaints']) {
              if (data.containsKey(f) && data[f] != null) {
                updateMap[f] = data[f];
              }
            }

            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set(updateMap, SetOptions(merge: true));
            if (rawSerial != serial) {
              try {
                await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(rawSerial.toLowerCase()).delete();
              } catch (_) {}
            }
          }
          else if (type == 'update_serial_status') {
            final serial = action['serial'] as String?;
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            if (serial == null) throw Exception('Missing serial');
            final entryKey = '$branchId-$serial';
            final localEntry = Hive.box(LocalStorageService.entriesBox).get(entryKey);

            // Terminal Status Protection
            try {
              if (localEntry is Map) {
                final lDisp = (localEntry['dispenseStatus'] ?? '').toString().toLowerCase();
                final dDisp = (data['dispenseStatus'] ?? '').toString().toLowerCase();
                if (lDisp == 'dispensed' && dDisp != 'dispensed') {
                  data['dispenseStatus'] = 'dispensed';
                  data['status'] = 'completed';
                }
              }
            } catch (_) {}

            final queueType = resolveQueueType(action['queueType']?.toString() ?? localEntry?['queueType']?.toString(), branchId: branchId);
            final dateKey   = action['dateKey']?.toString() ?? localEntry?['dateKey']?.toString() ?? LocalStorageService.getTodayDateKey();
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString() ?? localEntry?['campId']?.toString() ?? localEntry?['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString() ?? localEntry?['dispensaryTag']?.toString(),
              serial: serial,
            );
            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set(data, SetOptions(merge: true));
          }
          else if (type == 'save_dispensary_record') {
            // [DEDUP] Dispensary collection write deprecated. All dispense data is
            // stored in the serial document via update_serial_status.
            debugPrint('[SyncService] save_dispensary_record skipped (redundant write removed)');
          }
          else if (type == 'save_dispensary_charge') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final serial  = (action['serial'] ?? data['serial'])?.toString();
            final dateKey = (action['dateKey'] ?? data['dateKey'])?.toString() ?? LocalStorageService.getTodayDateKey();
            if (serial == null || serial.isEmpty) throw Exception('Missing serial');
            final queueType = resolveQueueType((action['queueType'] ?? data['queueType'])?.toString(), branchId: branchId);
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString(),
              serial: serial,
            );
            await _db.collection('branches').doc(branchId).collection('dispensary_charges').doc(dateKey).collection('charges').doc(serial).set({...data, 'queueType': queueType}, SetOptions(merge: true));
            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set({'daysOfMedicine': (data['daysOfMedicine'] as num?)?.toInt() ?? 1}, SetOptions(merge: true));
          }
          else if (type == 'update_inventory') {
            final nestedData = action['data'] is Map
                ? Map<String, dynamic>.from(action['data'] as Map)
                : <String, dynamic>{};
            final medicineId = (action['medicineId'] ?? action['inventoryId'] ?? nestedData['medicineId'] ?? nestedData['inventoryId'] ?? nestedData['id'] ?? nestedData['docId'])?.toString().trim();
            final deltaValue = action['delta'] ?? nestedData['delta'];
            final delta = deltaValue is num
                ? deltaValue.toDouble()
                : double.tryParse(deltaValue?.toString() ?? '') ?? 0.0;
            if (medicineId != null && medicineId.isNotEmpty && delta != 0) {
              final serialHint = medicineId.startsWith('hajicamp--')
                  ? 'HAJI'
                  : (medicineId.startsWith('saddar--') ? 'SADDAR' : (action['serial'] ?? nestedData['serial'])?.toString());
              final invCol = CampSessionService.getCampInventoryPath(
                branchId: branchId,
                campId: (action['campId'] ?? nestedData['campId'] ?? nestedData['dispensaryId'])?.toString(),
                dispensaryTag: (action['dispensaryTag'] ?? nestedData['dispensaryTag'])?.toString(),
                serial: serialHint,
              );
              final docRef = _db.collection('branches').doc(branchId).collection(invCol).doc(medicineId);
              // Zero-read atomic update using FieldValue.increment
              await docRef.set({
                'quantity': FieldValue.increment(delta),
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
          else if (type == 'add_inventory_stock') {
            final nestedData = action['data'] is Map
                ? Map<String, dynamic>.from(action['data'] as Map)
                : <String, dynamic>{};
            final medicineId = (action['medicineId'] ?? action['inventoryId'] ?? nestedData['medicineId'] ?? nestedData['inventoryId'] ?? nestedData['id'] ?? nestedData['docId'])?.toString().trim();
            final qty = (action['quantity'] as num?)?.toInt() ?? 0;
            final txId = action['txId'] as String? ?? key;
            if (medicineId != null && medicineId.isNotEmpty && qty > 0) {
              final serialHint = medicineId.startsWith('hajicamp--')
                  ? 'HAJI'
                  : (medicineId.startsWith('saddar--') ? 'SADDAR' : (action['serial'] ?? nestedData['serial'])?.toString());
              final invCol = CampSessionService.getCampInventoryPath(
                branchId: branchId,
                campId: (action['campId'] ?? nestedData['campId'] ?? nestedData['dispensaryId'])?.toString(),
                dispensaryTag: (action['dispensaryTag'] ?? nestedData['dispensaryTag'])?.toString(),
                serial: serialHint,
              );
              final docRef = _db.collection('branches').doc(branchId).collection(invCol).doc(medicineId);
              // Zero-read atomic update using FieldValue.increment
              await docRef.set({
                'quantity': FieldValue.increment(qty),
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              // Add to audit log using txId as document ID to prevent duplicate log items on retry
              await _db
                  .collection('branches')
                  .doc(branchId)
                  .collection('inventory_log')
                  .doc(txId)
                  .set({
                'action': 'add_stock',
                'medicineId': medicineId,
                'medicineName': action['medicineName'] ?? '',
                'quantityAdded': qty,
                'performedBy': action['performedBy'] ?? '',
                'performedByName': action['performedByName'] ?? '',
                'timestamp': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
          else if (type == 'register_medicine' || type == 'add_stock' || type == 'add_proforma_stock') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final docId = data['id']?.toString() ?? data['docId']?.toString() ?? action['docId']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            final fsData = Map<String, dynamic>.from(data)..remove('id')..remove('syncStatus');
            final targetBranch = action['branchId']?.toString() ?? branchId;
            final invCol = CampSessionService.getCampInventoryPath(
              branchId: targetBranch,
              campId: data['dispensaryId']?.toString() ?? data['campId']?.toString(),
            );
            await _db.collection('branches').doc(targetBranch).collection(invCol).doc(docId).set(fsData, SetOptions(merge: true));

            final logData = action['logData'] != null ? Map<String, dynamic>.from(action['logData']) : null;
            if (logData != null) {
              await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
                ...logData,
                'timestamp': FieldValue.serverTimestamp(),
              });
            } else if (type == 'register_medicine') {
              await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
                'action': 'medicine_registered_directly',
                'medicineName': data['name'],
                'docId': docId,
                'quantityAdded': (data['quantity'] as num?)?.toInt() ?? 0,
                'timestamp': FieldValue.serverTimestamp(),
              });
            }
          }
          else if (type == 'save_inventory_log') {
            final logData = Map<String, dynamic>.from(action['data'] ?? action['logData'] ?? {});
            final targetBranch = action['branchId']?.toString() ?? branchId;
            await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
              ...logData,
              'timestamp': FieldValue.serverTimestamp(),
            });
          }
          else if (type == 'save_token_exception_request') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final requestId = action['requestId']?.toString() ?? action['docId']?.toString() ?? data['id']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            final bId = action['branchId']?.toString() ?? branchId;
            
            for (final f in ['requestedAt', 'reviewedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }
            
            await _db
                .collection('branches')
                .doc(bId)
                .collection('edit_requests')
                .doc(requestId)
                .set(data, SetOptions(merge: true));
          }
          else if (type == 'approve_token_exception') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final requestId = action['requestId']?.toString() ?? action['docId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            final patientId = action['patientId']?.toString() ?? data['patientId']?.toString();

            if (patientId != null && patientId.isNotEmpty) {
              await LocalStorageService.grantTokenException(
                bId,
                patientId,
                reason: data['doctorReason']?.toString() ?? 'Approved by Doctor',
                approvedBy: data['approvedBy']?.toString() ?? 'Doctor',
                requestId: requestId,
              );
            }

            if (requestId != null) {
              for (final f in ['requestedAt', 'reviewedAt', 'approvedAt']) {
                if (data[f] is String) {
                  try {
                    data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                  } catch (_) {}
                }
              }
              await _db
                  .collection('branches')
                  .doc(bId)
                  .collection('edit_requests')
                  .doc(requestId)
                  .update(data);
            }
          }
          else if (type == 'save_donation') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final hiveKey = action['hiveKey'] as String?;
            final stableId = (data['firestoreId'] as String?)?.isNotEmpty == true ? data['firestoreId'] as String : (action['localId']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4());
            final docRef = _db.collection('branches').doc(branchId).collection('donations').doc(stableId);

            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = data['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                if (hiveKey != null) await DonationsLocalStorage.mergeRemoteDonation(hiveKey, stableId, remoteDoc.data() ?? {});
                await queueBox.delete(key);
                continue;
              }
            }
            final fsData = Map<String, dynamic>.from(data)..remove('hiveKey')..remove('syncStatus')..remove('firestoreId');
            await docRef.set(fsData, SetOptions(merge: true));
            if (hiveKey != null) await DonationsLocalStorage.markDonationSynced(hiveKey, docRef.id);
          }
          else if (type == 'save_audit_log') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final logId     = data['id']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            final logBranch = action['branchId'] as String? ?? branchId;
            data['branchId'] ??= logBranch;
            final batch = _db.batch();
            batch.set(_db.collection('branches').doc(logBranch).collection('audit_logs').doc(logId), data, SetOptions(merge: true));
            batch.set(_db.collection('global_audit_logs').doc(logId), data, SetOptions(merge: true));
            await batch.commit();
          }
          else if (type == 'save_journal_entry') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final entryId = action['entryId'] as String?;
            final bId     = action['branchId'] as String? ?? branchId;
            if (entryId != null && data.isNotEmpty) {
              final batch = _db.batch();
              if (bId != 'all') {
                batch.set(_db.collection('branches').doc(bId).collection('journal_entries').doc(entryId), data, SetOptions(merge: true));
              }
              batch.set(_db.collection('global_journal_entries').doc(entryId), data, SetOptions(merge: true));
              await batch.commit();
            }
          }
          else if (type == 'save_org_bank_account') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final accountId = action['accountId'] as String?;
            if (accountId != null && data.isNotEmpty) {
              await _db.collection('global_org_bank_accounts').doc(accountId).set(data, SetOptions(merge: true));
            }
          }

          else if (type == 'save_donor') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final donorId = action['donorId'] as String?;
            if (donorId == null || data.isEmpty) throw Exception('Missing donorId');
            final docRef = _db.collection('donors').doc(donorId);
            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = data['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                await DonationsLocalStorage.mergeRemoteDonor(donorId, remoteDoc.data() ?? {});
                await queueBox.delete(key);
                continue;
              }
            }
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus')..remove('isEdited');
            await docRef.set(fsData, SetOptions(merge: true));
          }
          else if (type == 'save_donor_branch') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final donorId = action['donorId'] as String?;
            final bId     = (action['branchId'] as String?) ?? branchId;
            if (donorId == null || data.isEmpty) throw Exception('Missing donorId');
            final docRef = _db.collection('branches').doc(bId).collection('donors').doc(donorId);
            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = data['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                await DonationsLocalStorage.mergeRemoteDonor(donorId, remoteDoc.data() ?? {});
                await queueBox.delete(key);
                continue;
              }
            }
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus')..remove('isEdited');
            await docRef.set(fsData, SetOptions(merge: true));
          }
          else if (type == 'update_donation') {
            final firestoreId = action['firestoreId'] as String?;
            final fields      = Map<String, dynamic>.from(action['fields'] ?? {});
            if (firestoreId == null) throw Exception('Missing firestoreId');
            final docRef = _db.collection('branches').doc(branchId).collection('donations').doc(firestoreId);
            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = fields['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                final hiveKey = (action['hiveKey'] as String?) ?? DonationsLocalStorage.getBox().keys.firstWhere(
                  (k) => k.toString().endsWith(firestoreId),
                  orElse: () => '',
                ).toString();
                if (hiveKey.isNotEmpty) {
                  await DonationsLocalStorage.mergeRemoteDonation(hiveKey, firestoreId, remoteDoc.data() ?? {});
                }
                await queueBox.delete(key);
                continue;
              }
            }
            final fsFields = Map<String, dynamic>.from(fields)..remove('hiveKey')..remove('syncStatus')..remove('firestoreId');
            await docRef.update(fsFields);
          }
          else if (type == 'delete_donation') {
            final firestoreId = action['firestoreId'] as String?;
            if (firestoreId != null) await _db.collection('branches').doc(branchId).collection('donations').doc(firestoreId).delete();
          }
          else if (type == 'delete_donor') {
            final donorId = action['donorId'] as String?;
            if (donorId != null) await _db.collection('donors').doc(donorId).delete();
          }
          else if (type == 'delete_donor_branch') {
            final donorId = action['donorId'] as String?;
            final bId     = action['branchId'] as String?;
            if (donorId != null && bId != null) await _db.collection('branches').doc(bId).collection('donors').doc(donorId).delete();
          }
          else if (type == 'save_bank_slip') {
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            final slipId = action['slipId'] as String?;
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            final docRef = _db.collection('branches').doc(branchId).collection('bank_slips').doc(slipId);
            await docRef.set(fsData, SetOptions(merge: true));
            if (slipId != null) await DonationsLocalStorage.markBankSlipSynced(slipId, docRef.id);
          }
          else if (type == 'save_employee') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (FinanceLocalStorage.isPlaceholderEmployee(data)) {
              // Silently discard placeholder employee from syncing
              continue;
            }
            final localId = action['localId']?.toString() ?? data['localId']?.toString();
            final bId = _cleanBranch(action['branchId'] ?? data['branchId'] ?? branchId);
            if (localId == null || localId.isEmpty) throw Exception('Missing localId');

            for (final f in ['dob', 'cnicExpiry', 'joiningDate', 'exitDate']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('employees').doc(localId).set(fsData, SetOptions(merge: true));
            
            final box = Hive.box(LocalStorageService.employeesBox);
            final localRecord = box.get(localId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = localId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(localId, updated);
            }
          }
          else if (type == 'delete_employee') {
            final localId = action['localId']?.toString();
            final bId = _cleanBranch(action['branchId'] ?? branchId);
            if (localId == null || localId.isEmpty) throw Exception('Missing localId');

            await _db.collection('branches').doc(bId).collection('employees').doc(localId).delete();
          }
          else if (type == 'save_user') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final uid = action['uid']?.toString() ?? data['uid']?.toString();
            final bId = action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId;
            if (uid == null || uid.isEmpty) throw Exception('Missing uid');

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('users').doc(uid).set(fsData, SetOptions(merge: true));

            final role = (fsData['role'] as String? ?? 'staff').toLowerCase();
            const globalRoles = ['ceo', 'chairman', 'admin', 'hq manager'];
            if (!globalRoles.contains(role) && bId != 'all' && bId.isNotEmpty) {
              await _db.collection('branches').doc(bId).collection('users').doc(uid).set(fsData, SetOptions(merge: true));
            }
          }
          else if (type == 'delete_user') {
            final uid = action['uid']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            final email = action['email']?.toString().trim().toLowerCase() ?? '';
            final username = action['username']?.toString().trim().toLowerCase() ?? '';
            final identifiers = <String>{
              if (uid != null && uid.isNotEmpty) uid,
              if (email.isNotEmpty) email,
              if (username.isNotEmpty) username,
            };
            if (identifiers.isEmpty) throw Exception('Missing user identifiers');

            for (final identifier in identifiers) {
              await _db.collection('users').doc(identifier).delete();
              if (bId != 'all' && bId.isNotEmpty) {
                await _db.collection('branches').doc(bId).collection('users').doc(identifier).delete();
              }
            }
          }
          else if (type == 'save_salary_history') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final employeeId = action['employeeId']?.toString();
            final historyId = action['historyId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (employeeId == null || historyId == null) throw Exception('Missing keys');

            if (data['effectiveDate'] is String) {
              try {
                data['effectiveDate'] = Timestamp.fromDate(DateTime.parse(data['effectiveDate'] as String));
              } catch (_) {}
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('employees').doc(employeeId).collection('salary_history').doc(historyId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.salaryHistoryBox);
            final key = '${employeeId}_$historyId';
            final localRecord = box.get(key);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = historyId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(key, updated);
            }
          }
          else if (type == 'save_attendance_record' ||
              type == 'save_biometric_log' ||
              type == 'save_employee_attendance' ||
              type == 'save_attendance') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final dateStr = (action['date'] ??
                    action['dateKey'] ??
                    data['date'] ??
                    data['dateKey'] ??
                    DateFormat('yyyy-MM-dd').format(DateTime.now()))
                .toString();
            final employeeId = (action['employeeId'] ??
                    data['employeeId'] ??
                    data['empId'] ??
                    data['userId'])
                ?.toString();
            final bId = (action['branchId'] ?? data['branchId'] ?? branchId).toString();
            final logId = (action['localId'] ?? data['id'] ?? data['logId'] ?? key).toString();
            if (employeeId == null || employeeId.isEmpty) throw Exception('Missing employeeId');

            if (data['markedAt'] is String) {
              try {
                data['markedAt'] = Timestamp.fromDate(DateTime.parse(data['markedAt'] as String));
              } catch (_) {}
            }
            if (data['timestamp'] is String) {
              try {
                data['timestamp'] = Timestamp.fromDate(DateTime.parse(data['timestamp'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            fsData['lastSyncedAt'] = FieldValue.serverTimestamp();

            await _db.collection('branches').doc(bId).collection('employee_attendance').doc(dateStr).set({
              'date': dateStr,
              'branchId': bId,
              'lastUpdated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            await _db
                .collection('branches')
                .doc(bId)
                .collection('employee_attendance')
                .doc(dateStr)
                .collection('records')
                .doc(employeeId)
                .set(fsData, SetOptions(merge: true));

            if (type == 'save_biometric_log' || action['punchSequence'] != null) {
              await _db.collection('branches').doc(bId).collection('biometric_logs').doc(logId).set(fsData, SetOptions(merge: true));
            }

            final box = Hive.box(LocalStorageService.attendanceBox);
            final hKey = '${employeeId}_$dateStr';
            final localRecord = box.get(hKey);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = employeeId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(hKey, updated);
            }
          }
          else if (type == 'send_notification') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final notifId = (action['localId'] ?? data['id'] ?? const Uuid().v4()).toString();
            final bId = (action['branchId'] ?? data['branchId'] ?? branchId).toString();

            final fsData = Map<String, dynamic>.from(data);
            fsData['timestamp'] = FieldValue.serverTimestamp();

            await _db.collection('branches').doc(bId).collection('notifications').doc(notifId).set(fsData, SetOptions(merge: true));
          }
          else if (type == 'save_salary_ledger') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final recordId = action['recordId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (recordId == null) throw Exception('Missing recordId');

            for (final f in ['date', 'createdAt', 'voidedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            final employeeDocRef = _db.collection('branches').doc(bId).collection('employees').doc(data['employeeId'] as String);
            final ledgerDocRef = _db.collection('branches').doc(bId).collection('employee_salaries').doc(recordId);

            // GMWF v2 Conflict Check
            final remoteDoc = await ledgerDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                final remoteVoid = remoteData['isVoided'] == true;
                final localVoid = data['isVoided'] == true;
                if (remoteVoid != localVoid || (remoteVoid && localVoid && remoteData['voidReason'] != data['voidReason'])) {
                  await _handleSyncConflict(bId, recordId, 'salary_ledger', data, remoteData);
                  await queueBox.delete(key);
                  continue;
                }
              }
            }

            await _db.runTransaction((transaction) async {
              transaction.set(ledgerDocRef, fsData, SetOptions(merge: true));
              
              final ledgerType = data['type']?.toString();
              final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
              final amountMinor = (data['amountMinor'] as num?)?.toInt() ?? (amount * 100).round();
              final isVoided = data['isVoided'] == true;
              
              double delta = 0.0;
              int deltaMinor = 0;
              if (ledgerType == 'advance_payment') {
                delta = isVoided ? -amount : amount;
                deltaMinor = isVoided ? -amountMinor : amountMinor;
              } else if (ledgerType == 'payout') {
                final recovery = (data['advanceDeductions'] as num?)?.toDouble() ?? 0.0;
                final recoveryMinor = (data['advanceDeductionsMinor'] as num?)?.toInt() ?? (recovery * 100).round();
                delta = isVoided ? recovery : -recovery;
                deltaMinor = isVoided ? recoveryMinor : -recoveryMinor;
              }

              if (delta != 0) {
                transaction.update(employeeDocRef, {
                  'currentAdvanceBalance': FieldValue.increment(delta),
                  'currentAdvanceBalanceMinor': FieldValue.increment(deltaMinor),
                });
              }
            });

            final box = Hive.box(LocalStorageService.salaryLedgerBox);
            final localRecord = box.get(recordId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = recordId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(recordId, updated);
            }
          }
          else if (type == 'save_finance_settings') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = action['branchId']?.toString() ?? branchId;

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('settings').doc('workSchedule').set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeSettingsBox);
            final localRecord = box.get(bId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(bId, updated);
            }
          }
          else if (type == 'save_branch_transfer') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final transferId = action['transferId']?.toString();
            final employeeId = action['employeeId']?.toString();
            final fromBranch = action['fromBranchId']?.toString();
            final toBranch = action['toBranchId']?.toString();

            if (transferId == null || employeeId == null || fromBranch == null || toBranch == null) {
              throw Exception('Missing transfer arguments');
            }

            if (data['effectiveDate'] is String) {
              try {
                data['effectiveDate'] = Timestamp.fromDate(DateTime.parse(data['effectiveDate'] as String));
              } catch (_) {}
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');

            final fromEmpRef = _db.collection('branches').doc(fromBranch).collection('employees').doc(employeeId);
            final toEmpRef = _db.collection('branches').doc(toBranch).collection('employees').doc(employeeId);
            final transferRef = _db.collection('branches').doc(toBranch).collection('employees').doc(employeeId).collection('branch_transfers').doc(transferId);

            await _db.runTransaction((transaction) async {
              final snapshot = await transaction.get(fromEmpRef);
              if (snapshot.exists) {
                final empData = Map<String, dynamic>.from(snapshot.data() ?? {});
                empData['branchId'] = toBranch;
                
                transaction.set(toEmpRef, empData, SetOptions(merge: true));
                transaction.delete(fromEmpRef);
                transaction.set(transferRef, fsData, SetOptions(merge: true));
              }
            });

            final box = Hive.box(LocalStorageService.branchTransfersBox);
            final localRecord = box.get(transferId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = transferId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(transferId, updated);
            }
          }
          else if (type == 'save_employee') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final empId = (action['localId'] ?? data['localId'] ?? data['id'])?.toString().trim();
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'] ?? data['branchId'], fallback: 'karachi');
            if (empId == null || empId.isEmpty) throw Exception('Missing employeeId');

            for (final f in ['dob', 'cnicExpiry', 'joiningDate', 'exitDate', 'createdAt', 'updatedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('employees').doc(empId).set(fsData, SetOptions(merge: true));

            if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
              final box = Hive.box(LocalStorageService.employeesBox);
              final local = box.get(empId);
              if (local is Map) {
                await box.put(empId, Map<String, dynamic>.from(local)..['syncStatus'] = 'synced');
              }
            }
          }
          else if (type == 'delete_employee') {
            final empId = (action['localId'] ?? action['employeeId'])?.toString().trim();
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'], fallback: 'karachi');
            if (empId != null && empId.isNotEmpty) {
              final candidateBranches = <String>{bId, 'karachi', 'saddar', 'haji_camp', 'main'};
              for (final cand in candidateBranches) {
                try {
                  await _db.collection('branches').doc(cand).collection('employees').doc(empId).delete();
                } catch (_) {}
                try {
                  await _db.collection('branches').doc(cand).collection('biometric_credentials').doc(empId).delete();
                } catch (_) {}
              }
            }
          }
          else if (type == 'delete_biometric_device') {
            final deviceId = (action['deviceId'] ?? action['id'] ?? action['localId'])?.toString().trim();
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'], fallback: 'karachi');
            if (deviceId != null && deviceId.isNotEmpty) {
              final candidateBranches = <String>{bId, 'karachi', 'saddar', 'haji_camp', 'main'};
              for (final cand in candidateBranches) {
                try {
                  await _db.collection('branches').doc(cand).collection('biometric_devices').doc(deviceId).delete();
                } catch (_) {}
              }
              try {
                await _db.collection('biometric_devices').doc(deviceId).delete();
              } catch (_) {}
              try {
                final groupSnap = await _db.collectionGroup('biometric_devices').get();
                for (final doc in groupSnap.docs) {
                  final d = doc.data();
                  if (doc.id == deviceId || d['deviceId'] == deviceId) {
                    await doc.reference.delete();
                  }
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_biometric_device') {
            final deviceId = (action['deviceId'] ?? action['id'])?.toString().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'] ?? data['branchId'], fallback: 'karachi');
            if (deviceId != null && deviceId.isNotEmpty) {
              data['updatedAt'] = FieldValue.serverTimestamp();
              await _db.collection('branches').doc(bId).collection('biometric_devices').doc(deviceId).set(data, SetOptions(merge: true));
            }
          }
          else if (type == 'save_finance_holiday') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final holidayId = action['holidayId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (holidayId == null) throw Exception('Missing holidayId');

            if (data['date'] is String) {
              try {
                data['date'] = Timestamp.fromDate(DateTime.parse(data['date'] as String));
              } catch (_) {}
            }
            if (data['updatedAt'] is String) {
              try {
                data['updatedAt'] = Timestamp.fromDate(DateTime.parse(data['updatedAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('finance_holidays').doc(holidayId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeHolidaysBox);
            final key = '${bId.toLowerCase().trim()}__hol__$holidayId';
            final localRecord = box.get(key);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = holidayId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(key, updated);
            }
          }
          else if (type == 'delete_finance_holiday') {
            final holidayId = action['holidayId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (holidayId == null) throw Exception('Missing holidayId');

            await _db.collection('branches').doc(bId).collection('finance_holidays').doc(holidayId).delete();
          }
          else if (type == 'save_finance_loan') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final loanId = action['loanId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (loanId == null) throw Exception('Missing loanId');

            for (final f in ['dateIssued', 'closedAt', 'createdAt', 'updatedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            if (data['payments'] is List) {
              final paymentsList = List<dynamic>.from(data['payments'] as List);
              final convertedPayments = <Map<String, dynamic>>[];
              for (final p in paymentsList) {
                if (p is Map) {
                  final pMap = Map<String, dynamic>.from(p);
                  for (final f in ['date', 'createdAt', 'voidedAt']) {
                    if (pMap[f] is String) {
                      try {
                        pMap[f] = Timestamp.fromDate(DateTime.parse(pMap[f] as String));
                      } catch (_) {}
                    }
                  }
                  convertedPayments.add(pMap);
                }
              }
              data['payments'] = convertedPayments;
            }

            // GMWF v2 Conflict Check
            final loanDocRef = _db.collection('branches').doc(bId).collection('finance_loans').doc(loanId);
            final remoteDoc = await loanDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                final remotePayments = List<dynamic>.from(remoteData['payments'] as List? ?? []);
                final localPayments = List<dynamic>.from(data['payments'] as List? ?? []);
                
                bool hasConflict = false;
                for (final lp in localPayments) {
                  if (lp is Map) {
                    final rp = remotePayments.firstWhereOrNull((p) => p['id'] == lp['id']);
                    if (rp is Map && rp['isVoided'] == true && lp['isVoided'] == true && rp['voidReason'] != lp['voidReason']) {
                      hasConflict = true;
                      break;
                    }
                  }
                }
                
                if (hasConflict) {
                  await _handleSyncConflict(bId, loanId, 'loan', data, remoteData);
                  await queueBox.delete(key);
                  continue;
                }
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await loanDocRef.set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeLoansBox);
            final localRecord = box.get(loanId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = loanId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(loanId, updated);
            }
          }
          else if (type == 'save_audit_log') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final logId = data['id']?.toString() ?? action['localId']?.toString();
            final bId = action['branchId']?.toString() ?? data['branchContext']?.toString() ?? branchId;
            if (logId == null) throw Exception('Missing logId');

            for (final f in ['timestamp', 'updatedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            
            // Mirror to branch collection and global_audit_logs collection
            await _db.collection('branches').doc(bId).collection('audit_logs').doc(logId).set(fsData, SetOptions(merge: true));
            await _db.collection('global_audit_logs').doc(logId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.auditLogsBox);
            final localRecord = box.get(logId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = logId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(logId, updated);
            }
          }
          else if (type == 'save_dasterkhwan_tokens') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = action['branchId']?.toString() ?? branchId;
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokensList = List<dynamic>.from(data['tokens'] as List? ?? []);
            final qty = (data['quantity'] as num?)?.toInt() ?? tokensList.length;
            final session = data['session']?.toString() ?? 'lunch';

            final dayDocRef = _db
                .collection('branches')
                .doc(bId)
                .collection('dasterkhwaan')
                .doc(dateKey);

            final tokensColRef = dayDocRef.collection('tokens');

            final batch = _db.batch();
            for (final t in tokensList) {
              if (t is Map) {
                final tMap = Map<String, dynamic>.from(t);
                final tokenId = tMap['id']?.toString() ?? tokensColRef.doc().id;
                final fsToken = {
                  'number': tMap['number'] ?? 1,
                  'served': tMap['served'] == true,
                  'session': tMap['session'] ?? session,
                  'time': tMap['time'] != null
                      ? Timestamp.fromDate(DateTime.tryParse(tMap['time'].toString()) ?? DateTime.now())
                      : FieldValue.serverTimestamp(),
                  'issuedBy': tMap['issuedBy'] ?? '',
                  'localId': tokenId,
                };
                batch.set(tokensColRef.doc(tokenId), fsToken, SetOptions(merge: true));
              }
            }

            final dayUpdate = <String, dynamic>{
              'totalTokens': FieldValue.increment(qty),
              'session_${session}_total': FieldValue.increment(qty),
              'lastUpdated': FieldValue.serverTimestamp(),
            };
            batch.set(dayDocRef, dayUpdate, SetOptions(merge: true));
            await batch.commit();
          }
          else if (type == 'reverse_dasterkhwan_tokens') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = action['branchId']?.toString() ?? branchId;
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokenIds = List<String>.from((data['tokenIds'] as List? ?? []).map((e) => e.toString()));
            final qty = (data['quantity'] as num?)?.toInt() ?? tokenIds.length;
            final sessionCounts = Map<String, dynamic>.from(data['sessionCounts'] ?? {});

            final dayDocRef = _db
                .collection('branches')
                .doc(bId)
                .collection('dasterkhwaan')
                .doc(dateKey);

            final tokensColRef = dayDocRef.collection('tokens');
            final batch = _db.batch();

            for (final id in tokenIds) {
              batch.delete(tokensColRef.doc(id));
            }

            final dayUpdate = <String, dynamic>{
              'totalTokens': FieldValue.increment(-qty),
              'lastUpdated': FieldValue.serverTimestamp(),
            };
            sessionCounts.forEach((s, count) {
              final cnt = (count as num?)?.toInt() ?? 0;
              if (cnt > 0) {
                dayUpdate['session_${s}_total'] = FieldValue.increment(-cnt);
              }
            });

            batch.set(dayDocRef, dayUpdate, SetOptions(merge: true));
            await batch.commit();
          }
          else if (type == 'serve_dasterkhwan_token') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = action['branchId']?.toString() ?? branchId;
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokenId = data['tokenId']?.toString();
            final session = data['session']?.toString() ?? 'lunch';

            if (tokenId != null && tokenId.isNotEmpty) {
              final dayDocRef = _db
                  .collection('branches')
                  .doc(bId)
                  .collection('dasterkhwaan')
                  .doc(dateKey);

              final tokensColRef = dayDocRef.collection('tokens');

              final batch = _db.batch();
              batch.set(tokensColRef.doc(tokenId), {
                'served': true,
                'servedTime': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              batch.set(dayDocRef, {
                'servedTokens': FieldValue.increment(1),
                'session_${session}_served': FieldValue.increment(1),
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              await batch.commit();
            }
          }
          else if (type == 'save_madrassa_log') {
            final dateKey = action['dateKey'] as String?;
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (dateKey == null) throw Exception('Missing dateKey');
            await _db.collection('branches').doc(branchId).collection('madrassa_daily_logs').doc(dateKey).set(data, SetOptions(merge: true));
          }
          else if (type == 'save_madrassa_student' || type == 'save_madrassa_admission') {
            final studentId = action['studentId'] as String?;
            final bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (studentId == null || studentId.isEmpty) throw Exception('Missing studentId');
            if (data['joinDate'] is String) {
              final parsed = DateTime.tryParse(data['joinDate'] as String);
              if (parsed != null) data['joinDate'] = Timestamp.fromDate(parsed);
            }
            data['lastUpdatedAt'] = FieldValue.serverTimestamp();
            await _db.collection('branches').doc(bId).collection('madrassa_students').doc(studentId).set(data, SetOptions(merge: true));
          }
          else if (type == 'delete_madrassa_student' || type == 'offboard_madrassa_student') {
            final studentId = action['studentId'] as String?;
            final bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            final status = action['status']?.toString() ?? 'left';
            if (studentId == null || studentId.isEmpty) throw Exception('Missing studentId');
            await _db.collection('branches').doc(bId).collection('madrassa_students').doc(studentId).set({
              'status': status,
              'batch': status,
              'lastUpdatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          else if (type == 'update_madrassa_student') {
            final studentId = action['studentId'] as String?;
            final currentLines = action['currentLines'] as int?;
            if (studentId == null || currentLines == null) throw Exception('Missing studentId/currentLines');
            await _db.collection('branches').doc(branchId).collection('madrassa_students').doc(studentId).update({
              'currentLines': currentLines,
              'lastUpdatedAt': FieldValue.serverTimestamp(),
            });
          }
          else if (type == 'save_madrassa_fee_payment' || type == 'save_madrassa_fee') {
            final bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            final docId = action['id']?.toString() ?? '${action['year']}_${action['month']}_${action['studentId']}';
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            data['lastUpdatedAt'] = FieldValue.serverTimestamp();
            await _db.collection('branches').doc(bId).collection('madrassa_fee_payments').doc(docId).set(data, SetOptions(merge: true));
          }
          else if (type == 'save_user') {
            final uid = action['uid'] as String?;
            final bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (uid != null && uid.isNotEmpty) {
              await _db.collection('users').doc(uid).set(data, SetOptions(merge: true));
              if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
                await _db.collection('branches').doc(bId).collection('users').doc(uid).set(data, SetOptions(merge: true));
              }
            }
          }
          else if (type == 'delete_user') {
            final uid = action['uid'] as String?;
            final bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            if (uid != null && uid.isNotEmpty) {
              await _db.collection('users').doc(uid).delete();
              if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
                await _db.collection('branches').doc(bId).collection('users').doc(uid).delete();
              }
            }
          }
          else if (type == 'save_expense' || type == 'void_expense') {
            final expenseId = action['expenseId'] as String?;
            final bId = action['branchId']?.toString() ?? branchId;
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (expenseId == null) throw Exception('Missing expenseId');

            for (final f in ['date', 'createdAt', 'updatedAt', 'voidedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            // GMWF v2 Conflict Check
            final expDocRef = _db.collection('branches').doc(bId).collection('expenses').doc(expenseId);
            final remoteDoc = await expDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                if (remoteData['isVoided'] == true && data['isVoided'] == true && remoteData['voidReason'] != data['voidReason']) {
                  await _handleSyncConflict(bId, expenseId, 'expense', data, remoteData);
                  await queueBox.delete(key);
                  continue;
                }
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await expDocRef.set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.expensesBox);
            final localRecord = box.get(expenseId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(expenseId, updated);
            }
          }

          await queueBox.delete(key);
          if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(type)) {
            await _resolveInventorySyncFailure(key, branchId);
          }
        } catch (e, stackTrace) {
          if (QuotaService.isQuotaError(e)) {
            QuotaService.recordQuotaExceeded(error: e);
          }
          final nextAttempts = attempts + 1;
          action['attempts'] = nextAttempts;
          action['lastAttempt'] = DateTime.now().toIso8601String();
          action['lastError'] = e.toString();

          // Exponential backoff (1s, 2s, 4s, 8s, 16s ... capped at 5 mins) - Pillar 2-C
          final backoffSeconds = min(300, pow(2, min(nextAttempts, 8)).toInt());
          action['nextRetryAt'] = DateTime.now().add(Duration(seconds: backoffSeconds)).toIso8601String();

          if (nextAttempts >= 20) {
            await LocalStorageService.moveToDeadLetterQueue(
              LocalStorageService.syncBox,
              key,
              action,
              reason: e.toString(),
            );
          } else {
            await queueBox.put(key, action);
          }

          Logger().d("[SyncService] ❌ Upload failed for key: $key (type: $type, attempt: $nextAttempts, backoff: ${backoffSeconds}s). Error: $e");
          debugPrint(stackTrace.toString());
          if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(type)) {
            await _logInventorySyncFailure(key, action, type, e.toString());
          }
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (fatal) {
      Logger().d("FATAL sync: $fatal");
    } finally {
      _isUploading = false;
    }
  }



  Future<void> syncUnsyncedPatients(String branchId) async {
    await triggerUpload();
  }

  Future<void> syncTodayOnly(String branchId) async {
    final normBranchId = branchId.toLowerCase().trim();
    await LocalStorageService.downloadTodayTokens(normBranchId);
    await DonationsLocalStorage.downloadAllDonations(normBranchId);
  }

  Future<void> initialFullDownload(String branchId) async {
    final normBranchId = branchId.toLowerCase().trim();
    final settings = Hive.box('app_settings');
    final key      = 'initial_download_done_$normBranchId';
    if (settings.get(key, defaultValue: false)) {
      await syncTodayOnly(normBranchId);
      return;
    }
    try {
      if (!Hive.isBoxOpen(LocalStorageService.patientsBox) ||
          Hive.box(LocalStorageService.patientsBox).isEmpty) {
        final patientsSnap = await _db.collection('branches').doc(normBranchId).collection('patients').get();
        final List<Map<String, dynamic>> patientsList = [];
        for (final doc in patientsSnap.docs) {
          final d = doc.data();
          d['patientId'] = doc.id;
          d['branchId'] = normBranchId;
          patientsList.add(d);
        }
        await LocalStorageService.saveAllLocalPatients(patientsList);
      }

      await LocalStorageService.downloadTodayTokens(normBranchId);
      await LocalStorageService.downloadInventory(normBranchId);
      await DonationsLocalStorage.downloadAllDonations(normBranchId);
      await DonationsLocalStorage.downloadDonors(normBranchId);
      await FinanceLocalStorage.downloadAllFinanceData(normBranchId);
      await FinanceLoansStorage.migrateLegacyAdvancesToLoans(performedBy: 'System');
      await settings.put(key, true);
    } catch (e) {
      Logger().d('Initial download failed: $e');
    }
  }

  Future<void> forceFullRefresh(String branchId) async {
    final normBranchId = branchId.toLowerCase().trim();
    final settings = Hive.box('app_settings');
    final lastForceKey = 'last_force_full_refresh_$normBranchId';
    final lastForceStr = settings.get(lastForceKey) as String?;
    if (lastForceStr != null) {
      final lastForce = DateTime.tryParse(lastForceStr);
      if (lastForce != null && DateTime.now().difference(lastForce).inHours < 6) {
        Logger().d('SyncService: forceFullRefresh skipped — cooldown active (6h)');
        await syncTodayOnly(normBranchId);
        await triggerUpload();
        return;
      }
    }
    await settings.put(lastForceKey, DateTime.now().toIso8601String());
    await settings.delete('initial_download_done_$normBranchId');
    await initialFullDownload(normBranchId);
    await triggerUpload();
  }

  void dispose() {
    _connectivitySub?.cancel();
    _dailyTokenTimer?.cancel();
    _periodicSyncTimer?.cancel();
  }

  String resolveQueueType(String? raw, {String? branchId}) {
    if (raw == null) return 'zakat';
    final r = raw.toLowerCase().trim();
    if (r.contains('non') || r.contains('general')) {
      if (branchId != null) {
        final b = branchId.toLowerCase().trim();
        if (b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya')) {
          return 'zakat';
        }
      }
      return 'non-zakat';
    }
    if (r.contains('gmwf')) return 'gmwf';
    return 'zakat';
  }

  Future<void> _flagPersistentSyncFailure(String key, Map<String, dynamic> action, String type) async {
    try {
      final failuresBox = await Hive.openBox('sync_failures');
      final failureRecord = {
        'queueKey': key,
        'type': type,
        'action': action,
        'flaggedAt': DateTime.now().toIso8601String(),
        'attempts': action['attempts'],
      };
      await failuresBox.put(key, failureRecord);
      debugPrint('[SyncService] Flagged persistent sync failure: key=$key type=$type');
    } catch (e) {
      debugPrint('[SyncService] Error flagging sync failure: $e');
    }
  }

  Future<void> _logInventorySyncFailure(String queueKey, Map<String, dynamic> action, String type, String errorMsg) async {
    try {
      final bId = action['branchId'] as String? ?? _currentBranchId!;
      final medId = action['medicineId'] ?? action['inventoryId'] ?? (action['data'] as Map?)?['medicineId'] ?? '';
      final medName = action['medicineName'] ?? (action['data'] as Map?)?['name'] ?? 'Unknown Medicine';
      
      final docId = 'fail_${queueKey}';
      
      final failuresBox = await Hive.openBox('inventory_sync_failures');
      final record = {
        'queueKey': queueKey,
        'type': type,
        'medicineId': medId,
        'medicineName': medName,
        'error': errorMsg,
        'timestamp': DateTime.now().toIso8601String(),
        'actionData': action,
        'attempts': action['attempts'] ?? 0,
        'status': 'pending',
      };
      await failuresBox.put(docId, record);
      
      await _db
          .collection('branches')
          .doc(bId)
          .collection('inventory_sync_failures')
          .doc(docId)
          .set({
        ...record,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      
      debugPrint('[SyncService] Logged inventory sync failure for $medName: $errorMsg');
    } catch (err) {
      debugPrint('[SyncService] Error logging sync failure: $err');
    }
  }

  Future<void> _resolveInventorySyncFailure(String queueKey, String branchId) async {
    try {
      final docId = 'fail_${queueKey}';
      final failuresBox = await Hive.openBox('inventory_sync_failures');
      await failuresBox.delete(docId);
      
      await _db
          .collection('branches')
          .doc(branchId)
          .collection('inventory_sync_failures')
          .doc(docId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
      }).catchError((_) {});
    } catch (err) {
      debugPrint('[SyncService] Error resolving sync failure: $err');
    }
  }

  Future<void> _handleSyncConflict(
    String branchId,
    String entityId,
    String entityType,
    Map<String, dynamic> localData,
    Map<String, dynamic> remoteData,
  ) async {
    try {
      final settings = Hive.box(LocalStorageService.financeSettingsBox);
      final conflicts = List<Map<String, dynamic>>.from(
        (settings.get('sync_conflicts') as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      
      // Avoid duplicate conflicts
      final exists = conflicts.any((c) => c['entityId'] == entityId && c['entityType'] == entityType);
      if (!exists) {
        conflicts.add({
          'id': _uuid.v4(),
          'entityId': entityId,
          'entityType': entityType,
          'branchId': branchId,
          'local': localData,
          'remote': remoteData,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        });
        await settings.put('sync_conflicts', conflicts);
        await settings.flush();
      }

      await _db.collection('branches').doc(branchId).collection('sync_conflicts').doc(entityId).set({
        'entityId': entityId,
        'entityType': entityType,
        'local': localData,
        'remote': remoteData,
        'status': 'unresolved',
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('[SyncService] Conflict logged for $entityType: $entityId');
    } catch (e) {
      debugPrint('[SyncService] Error handling sync conflict: $e');
    }
  }
}