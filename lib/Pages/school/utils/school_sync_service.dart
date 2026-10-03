// lib/pages/school/utils/school_sync_service.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import 'school_local_storage.dart';

enum SchoolSyncState {
  synced,
  syncing,
  offlinePending,
  failed,
}

class SchoolSyncStatus {
  final SchoolSyncState state;
  final int pendingCount;
  final int failedCount;
  final bool isOnline;
  final String? lastSyncedTime;

  const SchoolSyncStatus({
    required this.state,
    required this.pendingCount,
    required this.failedCount,
    required this.isOnline,
    this.lastSyncedTime,
  });
}

class SchoolSyncService {
  static final SchoolSyncService _instance = SchoolSyncService._internal();
  factory SchoolSyncService() => _instance;
  SchoolSyncService._internal();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<BoxEvent>? _syncBoxSub;
  final StreamController<SchoolSyncStatus> _statusController =
      StreamController<SchoolSyncStatus>.broadcast();

  bool _isOnline = true;
  bool _isSyncing = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;

  Stream<SchoolSyncStatus> get statusStream => _statusController.stream;
  Timer? _statusDebounceTimer;
  int _cachedFailedCount = 0;
  DateTime? _lastFailedScanTime;

  void init() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      _isOnline = results.any((r) => r != ConnectivityResult.none);
      _scheduleUpdateStatus();
      if (_isOnline) {
        syncNow();
      }
    });

    final syncBox = Hive.isBoxOpen(LocalStorageService.syncBox)
        ? Hive.box(LocalStorageService.syncBox)
        : null;

    if (syncBox != null) {
      _syncBoxSub?.cancel();
      _syncBoxSub = syncBox.watch().listen((_) => _scheduleUpdateStatus());
    }

    _updateStatus();
  }

  void _scheduleUpdateStatus() {
    _statusDebounceTimer?.cancel();
    _statusDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _updateStatus();
    });
  }

  void dispose() {
    _statusDebounceTimer?.cancel();
    _connectivitySub?.cancel();
    _syncBoxSub?.cancel();
  }

  int getPendingSchoolQueueCount() {
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return 0;
    final box = Hive.box(LocalStorageService.syncBox);
    int count = 0;
    for (final v in box.values) {
      if (v is Map) {
        final collection = (v['collection'] ?? '').toString();
        final type = (v['type'] ?? v['action'] ?? '').toString();
        if (collection.contains('school_') || type.contains('school_')) {
          count++;
        }
      }
    }
    return count;
  }

  int getFailedSchoolRecordsCount(String branchId) {
    int failed = 0;

    void checkList(List<Map<String, dynamic>> items) {
      for (final item in items) {
        if ((item['syncStatus'] ?? '') == 'failed') {
          failed++;
        }
      }
    }

    checkList(SchoolLocalStorage.getAllStudentsCached(branchId));
    checkList(SchoolLocalStorage.getAllTeachersCached(branchId));
    checkList(SchoolLocalStorage.getAllBooksCached(branchId));
    checkList(SchoolLocalStorage.getAllBookLoansCached(branchId));

    return failed;
  }

  void _updateStatus() {
    final pending = getPendingSchoolQueueCount();
    final now = DateTime.now();
    if (_lastFailedScanTime == null || now.difference(_lastFailedScanTime!).inSeconds >= 15) {
      _cachedFailedCount = getFailedSchoolRecordsCount('all');
      _lastFailedScanTime = now;
    }
    final failed = _cachedFailedCount;

    SchoolSyncState state;
    if (_isSyncing) {
      state = SchoolSyncState.syncing;
    } else if (failed > 0) {
      state = SchoolSyncState.failed;
    } else if (!_isOnline || pending > 0) {
      state = SchoolSyncState.offlinePending;
    } else {
      state = SchoolSyncState.synced;
    }

    final ts = SchoolLocalStorage.getLastSchoolSyncTimestamp();

    _statusController.add(SchoolSyncStatus(
      state: state,
      pendingCount: pending,
      failedCount: failed,
      isOnline: _isOnline,
      lastSyncedTime: ts,
    ));
  }

  /// Trigger manual sync (Push pending queue & Pull remote records)
  Future<void> syncNow({String branchId = 'all'}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    _updateStatus();

    try {
      // 1. Trigger global SyncService upload
      SyncService().triggerUpload();

      // Resolve real branch ID dynamically if 'all' was passed
      String targetBranch = branchId.trim().toLowerCase();
      if (targetBranch == 'all' || targetBranch == 'global' || targetBranch.isEmpty) {
        try {
          final uData = LocalStorageService.getActiveUserData();
          final b = (uData['branchId'] ?? '').toString().trim().toLowerCase();
          if (b.isNotEmpty && b != 'all' && b != 'global') {
            targetBranch = b;
          } else {
            final assigned = LocalStorageService.getActiveUserBranchId().toLowerCase().trim();
            if (assigned.isNotEmpty && assigned != 'all' && assigned != 'global') {
              targetBranch = assigned;
            }
          }
        } catch (_) {}
      }

      final branchesToSync = <String>{};
      if (targetBranch != 'all' && targetBranch != 'global' && targetBranch.isNotEmpty) {
        branchesToSync.add(targetBranch);
      } else {
        // Always include default branch 'gujrat' for school data
        branchesToSync.add('gujrat');
        if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
          final bBox = Hive.box(LocalStorageService.branchesBox);
          for (final k in bBox.keys) {
            final val = bBox.get(k);
            if (val is Map) {
              final bId = (val['id'] ?? k.toString().replaceFirst('branch:', '')).toString().trim().toLowerCase();
              if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
                branchesToSync.add(bId);
              }
            }
          }
        }
      }

      // 2. Fetch and merge latest remote school records for branch(es)
      for (final b in branchesToSync) {
        await fetchRemoteSchoolData(b);
      }

      // 3. Mark last synced timestamp
      await SchoolLocalStorage.setLastSchoolSyncTimestamp(
        DateTime.now().toIso8601String(),
      );

      _retryCount = 0;
    } catch (e) {
      debugPrint('[SchoolSyncService] Sync failed: $e');
      _retryCount++;
      
      await SchoolLocalStorage.logAudit(
        branchId: branchId,
        action: 'SYNC_FAILURE',
        user: 'System Sync',
        details: 'School sync failed (Attempt $_retryCount/$_maxRetries): $e',
      );

      if (_retryCount < _maxRetries && _isOnline) {
        final backoffSec = (1 << _retryCount).clamp(2, 30);
        Timer(Duration(seconds: backoffSec), () => syncNow(branchId: branchId));
      }
    } finally {
      _isSyncing = false;
      _updateStatus();
    }
  }

  /// Pull remote school collections from Firestore using delta sync & resolve conflicts
  Future<void> fetchRemoteSchoolData(String branchId, {bool force = false}) async {
    if (branchId == 'all' || branchId == 'global' || branchId.isEmpty) return;
    await SchoolLocalStorage.ensureBoxesOpen();
    final firestore = FirebaseFirestore.instance;
    final collections = [
      'school_students',
      'school_teachers',
      'school_books',
      'school_book_loans',
      'school_attendance',
      'school_teacher_attendance',
      'school_grades',
      'school_fees',
      'school_homerooms',
      'school_audit_logs',
    ];

    for (final col in collections) {
      try {
        final syncKey = '${col}_$branchId';
        final lastSyncedTs = force ? null : LocalStorageService.getLastSyncedServerTimestamp(syncKey);
        String? maxServerTs = lastSyncedTs;

        DocumentSnapshot? lastDoc;
        bool hasMore = true;

        while (hasMore) {
          Query<Map<String, dynamic>> query = firestore
              .collection('branches')
              .doc(branchId)
              .collection(col);

          query = query.limit(500);
          if (lastDoc != null) {
            query = query.startAfterDocument(lastDoc);
          }

          final snap = await query.get();

          for (final doc in snap.docs) {
            final remote = doc.data();
            Map<String, dynamic>? local;

            if (col == 'school_students') {
              local = SchoolLocalStorage.getStudentCached(branchId, doc.id);
            } else if (col == 'school_teachers') {
              local = SchoolLocalStorage.getTeacherCached(branchId, doc.id);
            } else if (col == 'school_books') {
              local = SchoolLocalStorage.getBookCached(branchId, doc.id);
            }

            final docTs = remote['updatedAt']?.toString() ?? remote['lastModified']?.toString();
            if (docTs != null) {
              if (maxServerTs == null || docTs.compareTo(maxServerTs) > 0) {
                maxServerTs = docTs;
              }
            }

            await _resolveAndSaveRecord(
              branchId: branchId,
              recordId: doc.id,
              remoteData: remote,
              localData: local,
              saveLocal: (data) async {
                if (col == 'school_students') {
                  await SchoolLocalStorage.cacheStudent(branchId, doc.id, data);
                } else if (col == 'school_teachers') {
                  await SchoolLocalStorage.cacheTeacher(branchId, doc.id, data);
                } else if (col == 'school_books') {
                  await SchoolLocalStorage.cacheBook(branchId, doc.id, data);
                } else if (col == 'school_book_loans') {
                  await SchoolLocalStorage.cacheBookLoan(branchId, doc.id, data);
                } else if (col == 'school_attendance') {
                  await SchoolLocalStorage.cacheLog(branchId, doc.id, data);
                } else if (col == 'school_teacher_attendance') {
                  await SchoolLocalStorage.cacheTeacherAttendanceLog(branchId, doc.id, data);
                } else if (col == 'school_grades') {
                  final box = Hive.box(SchoolLocalStorage.gradesBox);
                  await box.put('${branchId.toLowerCase()}__${doc.id}', data);
                } else if (col == 'school_fees') {
                  final box = Hive.box(SchoolLocalStorage.feesBox);
                  await box.put('${branchId.toLowerCase()}__${doc.id}', data);
                } else if (col == 'school_homerooms') {
                  final box = Hive.box(SchoolLocalStorage.homeroomBox);
                  await box.put('${branchId.toLowerCase()}__${doc.id}', data);
                } else if (col == 'school_audit_logs') {
                  final box = Hive.box(LocalStorageService.schoolAuditLogsBox);
                  await box.put('${branchId.toLowerCase()}__${doc.id}', data);
                }
              },
              recordType: col,
            );
          }

          if (snap.docs.length < 500) {
            hasMore = false;
          } else {
            lastDoc = snap.docs.last;
          }
        }

        if (maxServerTs != null) {
          await LocalStorageService.setLastSyncedServerTimestamp(syncKey, maxServerTs);
        }
      } catch (e) {
        debugPrint('[SchoolSyncService] Remote fetch error for $col: $e');
      }
    }
  }

  /// Conflict Resolution (Last-Write-Wins based on lastModified)
  Future<void> _resolveAndSaveRecord({
    required String branchId,
    required String recordId,
    required Map<String, dynamic> remoteData,
    required Map<String, dynamic>? localData,
    required Future<void> Function(Map<String, dynamic> data) saveLocal,
    required String recordType,
  }) async {
    if (localData == null) {
      // New record from cloud
      remoteData['syncStatus'] = 'synced';
      remoteData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await saveLocal(remoteData);
      return;
    }

    final localModifiedStr = localData['lastModified']?.toString();
    final remoteModifiedStr = remoteData['lastModified']?.toString();

    final localModified = DateTime.tryParse(localModifiedStr ?? '') ?? DateTime(2000);
    final remoteModified = DateTime.tryParse(remoteModifiedStr ?? '') ?? DateTime(2000);

    if (remoteModified.isAfter(localModified)) {
      // Remote write wins -> notify audit log if local had unsynced changes
      if (localData['syncStatus'] == 'pending') {
        await SchoolLocalStorage.logAudit(
          branchId: branchId,
          action: 'SYNC_CONFLICT_WARNING',
          user: 'System Conflict Resolver',
          details: 'Remote overwrite applied for $recordType ID $recordId (Remote: $remoteModifiedStr vs Local: $localModifiedStr)',
        );
      }

      remoteData['syncStatus'] = 'synced';
      remoteData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await saveLocal(remoteData);
    } else {
      // Local write is newer or equal
      if (localData['syncStatus'] != 'synced') {
        localData['syncStatus'] = 'synced';
        localData['lastSyncedAt'] = DateTime.now().toIso8601String();
        await saveLocal(localData);
      }
    }
  }
}
