// lib/pages/school/utils/school_sync_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import '../core/school_branch_id.dart';
import '../core/school_merge.dart';
import '../core/school_store.dart';
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
      final normalizedBranches = branchesToSync
          .map(SchoolBranchId.normalize)
          .where((b) => b != SchoolBranchId.all)
          .toSet();
      for (final b in normalizedBranches) {
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

  /// Pulls every School collection of [branchId] and merges it into Hive with
  /// [SchoolMerge]: last write wins on `lastModified` for every collection,
  /// pending local edits are never replaced by an older or equal cloud copy,
  /// and attendance day documents merge per student.
  ///
  /// Still a full collection scan: a `lastModified > x` delta query would
  /// silently skip records written by a PC whose clock runs behind.
  Future<void> fetchRemoteSchoolData(String branchId, {bool force = false}) async {
    final branch = SchoolBranchId.normalize(branchId);
    if (branch == SchoolBranchId.all) return;
    await SchoolLocalStorage.ensureBoxesOpen();
    final firestore = FirebaseFirestore.instance;

    for (final col in SchoolCollection.all) {
      try {
        DocumentSnapshot? lastDoc;
        var hasMore = true;
        while (hasMore) {
          Query<Map<String, dynamic>> query =
              firestore.collection('branches').doc(branch).collection(col.name).limit(500);
          if (lastDoc != null) query = query.startAfterDocument(lastDoc);
          final snap = await query.get();

          for (final doc in snap.docs) {
            final remote = SchoolStore.sanitize(doc.data());
            final local = SchoolStore.get(col, branch, doc.id);
            final result = col.isDayLog
                ? SchoolMerge.mergeDayLog(local, remote)
                : SchoolMerge.mergeRecord(local, remote);

            if (result.overwrotePendingLocal && col != SchoolCollection.auditLogs) {
              await SchoolLocalStorage.logAudit(
                branchId: branch,
                action: 'SYNC_CONFLICT_WARNING',
                user: 'System Conflict Resolver',
                details: 'A newer cloud copy replaced unsynced local changes for ${col.name}/${doc.id} '
                    '(cloud ${remote['lastModified']} vs local ${local?['lastModified']})',
              );
            }
            if (local == null || jsonEncode(local) != jsonEncode(result.record)) {
              await SchoolStore.putFromCloud(col, branch, doc.id, result.record);
            }
          }

          if (snap.docs.length < 500) {
            hasMore = false;
          } else {
            lastDoc = snap.docs.last;
          }
        }
      } catch (e) {
        debugPrint('[SchoolSyncService] Remote fetch error for ${col.name}: $e');
      }
    }
  }
}
