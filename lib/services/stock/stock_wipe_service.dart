// lib/services/stock/stock_wipe_service.dart
//
// Server-side inventory wipe — completely purges all stock data for one pool
// from local Hive boxes, pending sync/LAN queues, and Firestore Cloud (via
// CloudDb REST/server-sourced deletes), writes a cloud wipe marker for Web &
// standalone clients, and broadcasts a deduplication-safe 'stock_wipe' signal
// with a wipe generation ID to every connected desk.
//
// Called by the server's InventoryWipePanel after password verification.

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../realtime/realtime_manager.dart';
import '../camp_session_service.dart';
import '../cloud/cloud_db.dart';
import '../firebase_session_guard.dart';
import '../local_storage_service.dart';
import '../master_proforma_service.dart';
import 'stock_actions.dart';
import 'stock_authority.dart';
import 'stock_cloud.dart';
import 'stock_ledger.dart';
import 'stock_log.dart';
import 'stock_pool.dart';
import 'stock_sync.dart';

class UnbarcodedMedicineMatch {
  final StockPool pool;
  final String medicineId;
  final String name;
  final String rawBarcode;
  final String type;
  final String dose;
  final double quantity;
  final String expiryDate;
  final bool inLocal;
  final bool inCloud;

  const UnbarcodedMedicineMatch({
    required this.pool,
    required this.medicineId,
    required this.name,
    required this.rawBarcode,
    required this.type,
    required this.dose,
    required this.quantity,
    required this.expiryDate,
    required this.inLocal,
    required this.inCloud,
  });

  String get poolLabel {
    final branchName = LocalStorageService.getBranchName(pool.branch);
    if (pool.camp == null) return branchName;
    final campName = CampSessionService.getCampLabel(pool.camp!, pool.branch);
    return '$branchName — $campName';
  }
}

class BatchDeleteResult {
  final int localRemoved;
  final int cloudDeleted;
  final List<String> errors;

  const BatchDeleteResult({
    required this.localRemoved,
    required this.cloudDeleted,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
}

class WipeResult {
  final int itemsWiped;
  final int movesWiped;
  final int cloudDocsDeleted;
  final List<String> errors;

  const WipeResult({
    required this.itemsWiped,
    required this.movesWiped,
    required this.cloudDocsDeleted,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
  bool get success => !hasErrors;
}

class StockWipeService {
  StockWipeService._();

  static final Random _rand = Random.secure();

  static String _newWipeId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final salt = List.generate(6, (_) => _rand.nextInt(36).toRadixString(36)).join();
    return 'w_${now.toRadixString(36)}_$salt';
  }

  /// Applies a server-issued `stock_wipe` on a desk / Web / standalone PC.
  /// Hard-deletes all local items (including legacy keys), movements, quarantine entries,
  /// and pending inventory sync/outbox queue entries for [poolKey], and records [wipeId].
  static Future<({int itemsRemoved, int movesRemoved, int queuePurged})> applyRemoteWipe(
    String poolKey, {
    String? wipeId,
  }) async {
    final cleanPool = poolKey.trim().toLowerCase();
    if (cleanPool.isEmpty) {
      return (itemsRemoved: 0, movesRemoved: 0, queuePurged: 0);
    }
    final purged = await StockLedger.purgePool(cleanPool, wipeId: wipeId);
    StockSync.clearPendingBaseBroadcasts(cleanPool);
    var queuePurged = 0;
    final parsed = StockPool.fromKey(cleanPool);
    if (parsed != null) {
      queuePurged = await StockLedger.purgeStockQueues(parsed);
    }
    return (
      itemsRemoved: purged.itemsRemoved,
      movesRemoved: purged.movesRemoved,
      queuePurged: queuePurged,
    );
  }

  /// Wipes ALL inventory data for [pool]:
  ///   1. Suspends StockSync listeners/uploads for [pool] to prevent races.
  ///   2. Hard-deletes every local item (including legacy keys) & movement in Hive and
  ///      records a fresh pool wipe epoch ID.
  ///   3. Purges every pending stock/inventory entry from sync_queue, server_sync_queue,
  ///      realtime_outbox, and realtime_failed_outbox.
  ///   4. Broadcasts a deduplication-safe 'stock_wipe' LAN message to all connected desks.
  ///   5. Authenticates with Firebase and deletes EVERY document in Firestore
  ///      `branches/{cloudBranch}/{pool.collection}` via CloudDb (REST on Windows,
  ///      server-sourced SDK on web/mobile), verified until empty.
  ///   6. Writes the cloud wipe marker `branches/{cloudBranch}/inventory_meta/wipe_{collection}`
  ///      so Web & offline desks clear automatically too.
  ///   7. Re-broadcasts 'stock_wipe' and resumes StockSync cleanly.
  ///
  /// Returns a [WipeResult] with counts and any real errors. Never throws.
  static Future<WipeResult> wipePool(
    StockPool pool, {
    void Function(String)? onProgress,
  }) async {
    final errors = <String>[];
    var itemsWiped = 0;
    var movesWiped = 0;
    var cloudDocsDeleted = 0;

    try {
      StockAuthority.requireManage('Wiping inventory');
    } catch (e) {
      return WipeResult(itemsWiped: 0, movesWiped: 0, cloudDocsDeleted: 0, errors: ['$e']);
    }

    final wipeId = _newWipeId();
    final wipedAtMs = DateTime.now().millisecondsSinceEpoch;

    // 1. ── Open boxes & pause StockSync for this pool ────────────────────────
    try {
      await StockLedger.ensureOpen();
    } catch (e) {
      errors.add('Could not open Hive boxes: $e');
      return WipeResult(itemsWiped: 0, movesWiped: 0, cloudDocsDeleted: 0, errors: errors);
    }

    onProgress?.call('Pausing stock sync listeners & uploads for ${pool.key}…');
    try {
      await StockSync.suspendForWipe(pool);
    } catch (e) {
      errors.add('Suspend sync note: $e');
    }

    try {
      // 2. ── Hard-delete every local item & movement in Hive ─────────────────
      onProgress?.call('Hard-deleting all local items and movements for ${pool.key}…');
      try {
        final purged = await StockLedger.purgePool(pool.key, wipeId: wipeId);
        itemsWiped = purged.itemsRemoved;
        movesWiped = purged.movesRemoved;
        onProgress?.call('Deleted $itemsWiped local medicine record(s) and $movesWiped ledger movement(s).');
        debugPrint('[StockWipe] Purged $itemsWiped items & $movesWiped moves (pool ${pool.key}, wipeId=$wipeId)');
      } catch (e) {
        errors.add('Local database wipe failed: $e');
        onProgress?.call('❌ Local database wipe failed: $e');
      }

      // 3. ── Purge all inventory sync-queue & LAN outbox entries ─────────────
      onProgress?.call('Purging pending sync & LAN outbox queues…');
      try {
        final queuePurged = await StockLedger.purgeStockQueues(pool);
        onProgress?.call('Purged $queuePurged pending stock queue / outbox item(s).');
        debugPrint('[StockWipe] Purged $queuePurged queued stock entries for pool ${pool.key}');
      } catch (e) {
        errors.add('Sync queue purge failed: $e');
        onProgress?.call('⚠️ Sync queue purge note: $e');
      }

      // 4. ── Immediately broadcast wipe to all connected LAN desks ───────────
      onProgress?.call('Broadcasting instant wipe signal to connected Doctor, Dispensary & Hybrid desks…');
      _broadcastWipe(pool, wipeId, wipedAtMs, onProgress: onProgress, errors: errors);

      // 5. ── Delete ALL Firestore documents via CloudDb (REST on Windows) ────
      onProgress?.call('Authenticating & deleting Firestore cloud collection (${pool.cloudBranch}/${pool.collection})…');
      var cloudOk = false;
      try {
        await FirebaseSessionGuard.ensureSession(reason: 'cloud_db_auth')
            .timeout(const Duration(seconds: 12), onTimeout: () => false);

        final collectionsToWipe = <String>[
          'branches/${pool.cloudBranch}/${pool.collection}',
          // Also clear legacy Haji Camp alias collection if wiping Haji Camp
          if (pool.collection == 'inventory_haji')
            'branches/${pool.cloudBranch}/inventory_haji_camp',
        ];

        for (final colPath in collectionsToWipe) {
          final deleted = await CloudDb.instance.deleteCollection(
            colPath,
            batchSize: 400,
            onProgress: (soFar, roundTotal) {
              onProgress?.call('Deleted $soFar Firestore document(s) from $colPath…');
            },
          );
          cloudDocsDeleted += deleted;
          debugPrint('[StockWipe] Deleted $deleted cloud docs from $colPath');
        }

        // Write cloud wipe marker so Chrome Web / standalone / offline PCs wipe immediately
        // when they receive the marker or sync next, and remove stale repair meta doc.
        await CloudDb.runWith(const CloudWriteContext(force: true), () async {
          await CloudDb.instance.doc(StockCloud.wipeMetaPath(pool)).set({
            'pool': pool.key,
            'branch': pool.branch,
            'cloudBranch': pool.cloudBranch,
            'collection': pool.collection,
            'wipeId': wipeId,
            'wipedAtMs': wipedAtMs,
            'wipedAt': FieldValue.serverTimestamp(),
            'wipedBy': LocalStorageService.getActiveUsername(),
          });
          try {
            await CloudDb.instance
                .doc('branches/${pool.cloudBranch}/inventory_meta/repair_v1_${pool.collection}')
                .delete();
          } catch (_) {}
        });

        cloudOk = true;
        if (cloudDocsDeleted == 0) {
          onProgress?.call('Firestore cloud collection confirmed empty (0 documents) & wipe marker written.');
        } else {
          onProgress?.call('✅ Permanently deleted $cloudDocsDeleted Firestore cloud document(s) & updated wipe marker.');
        }
      } catch (e) {
        final msg = 'Firestore cloud delete failed: $e';
        errors.add(msg);
        debugPrint('[StockWipe] ❌ $msg');
        onProgress?.call('❌ $msg');
      }

      // 6. ── Update sync cursor so _followCloud watches only post-wipe changes ─
      try {
        final syncKey = 'stock_v2_${pool.key.replaceAll('/', '_')}';
        await LocalStorageService.setLastSyncedServerTimestamp(
          syncKey,
          cloudOk ? DateTime.now().toUtc().toIso8601String() : '',
        );
      } catch (_) {}

      // 7. ── Second broadcast after cloud purge for any desk that reconnected ─
      _broadcastWipe(pool, wipeId, wipedAtMs);

      if (errors.isEmpty) {
        onProgress?.call('✅ Master wipe completed successfully (Local + Firestore Cloud + All Desks).');
      } else {
        onProgress?.call('⚠️ Wipe finished with ${errors.length} error(s). Review the details below.');
      }
    } finally {
      StockSync.resumeAfterWipe(pool);
    }

    await StockLog.record({
      'id': 'log_$wipeId',
      'action': 'inventory_wiped',
      'medicineName': 'Whole inventory',
      'pool': pool.key,
      'branchId': pool.branch,
      'camp': pool.camp ?? '',
      'itemsRemoved': itemsWiped,
      'cloudDocsDeleted': cloudDocsDeleted,
      'errors': errors.length,
      'performedByName': LocalStorageService.getActiveUsername(),
    });

    return WipeResult(
      itemsWiped: itemsWiped,
      movesWiped: movesWiped,
      cloudDocsDeleted: cloudDocsDeleted,
      errors: errors,
    );
  }

  /// Returns every known stock pool across all branches and camps (local Hive + Firestore
  /// branches collection when reachable) for executive/global cleanup operations.
  static Future<List<StockPool>> allBranchPools({bool includeCloudBranches = true}) async {
    final branchIds = <String>{};
    for (final b in LocalStorageService.getLocalBranchesList()) {
      final norm = StockPool.normalizeBranch(b['id']?.toString());
      if (norm.isNotEmpty && norm != 'all' && norm != 'global') branchIds.add(norm);
    }
    if (StockLedger.isOpen) {
      for (final it in StockLedger.items()) {
        final norm = StockPool.normalizeBranch(it['branchId']?.toString());
        if (norm.isNotEmpty && norm != 'all' && norm != 'global') branchIds.add(norm);
      }
    }
    if (includeCloudBranches) {
      try {
        await FirebaseSessionGuard.ensureSession(reason: 'cloud_db_auth')
            .timeout(const Duration(seconds: 6), onTimeout: () => false);
        final snap = await FirebaseFirestore.instance
            .collection('branches')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        for (final doc in snap.docs) {
          final norm = StockPool.normalizeBranch(doc.id);
          if (norm.isNotEmpty && norm != 'all' && norm != 'global') branchIds.add(norm);
        }
      } catch (_) {}
    }
    if (branchIds.isEmpty) {
      branchIds.addAll(const ['karachi', 'gujrat', 'sialkot', 'rawalpindi']);
    }

    final byKey = <String, StockPool>{};
    for (final b in branchIds) {
      for (final p in StockPool.allFor(b)) {
        byKey[p.key] = p;
      }
    }
    final list = byKey.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// Scans [pools] (local Hive + Firestore server when [includeCloud] is true) and returns
  /// every medicine batch that has NO barcode or does NOT match an official 3-digit GMWF
  /// Master Proforma barcode.
  static Future<({List<UnbarcodedMedicineMatch> matches, int totalScanned, List<String> errors})>
      scanUnbarcodedMedicines({
    required List<StockPool> pools,
    bool includeCloud = true,
    void Function(String)? onProgress,
  }) async {
    await StockLedger.ensureOpen();
    final officialBarcodes = MasterProformaService.getOfficialBarcodes();
    final matches = <UnbarcodedMedicineMatch>[];
    final errors = <String>[];
    var totalScanned = 0;

    if (includeCloud) {
      try {
        await FirebaseSessionGuard.ensureSession(reason: 'cloud_db_auth')
            .timeout(const Duration(seconds: 8), onTimeout: () => false);
      } catch (_) {}
    }

    for (final pool in pools) {
      onProgress?.call('Scanning ${pool.key}…');
      final byId = <String, ({Map<String, dynamic> data, bool inLocal, bool inCloud})>{};

      for (final it in StockLedger.items(pool: pool.key)) {
        final id = (it['medicineId'] ?? it['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        byId[id] = (data: Map<String, dynamic>.from(it), inLocal: true, inCloud: false);
      }

      if (includeCloud) {
        final cols = <String>[
          pool.collection,
          if (pool.collection == 'inventory_haji') 'inventory_haji_camp',
        ];
        for (final col in cols) {
          try {
            final snap = await FirebaseFirestore.instance
                .collection('branches')
                .doc(pool.cloudBranch)
                .collection(col)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 20));
            for (final doc in snap.docs) {
              final d = doc.data();
              if (d['deleted'] == true) continue;
              final id = doc.id.trim();
              if (id.isEmpty) continue;
              final prev = byId[id];
              byId[id] = (
                data: prev != null ? {...d, ...prev.data} : Map<String, dynamic>.from(d),
                inLocal: prev?.inLocal ?? false,
                inCloud: true,
              );
            }
          } catch (e) {
            errors.add('Cloud scan ${pool.cloudBranch}/$col: $e');
          }
        }
      }

      for (final entry in byId.entries) {
        totalScanned++;
        final data = entry.value.data;
        final official = MasterProformaService.resolveOfficialBarcodeForStockItem(
          data,
          officialBarcodes: officialBarcodes,
        );
        if (official != null) continue;

        final rawBar = (data['barcode'] ?? data['rollNo'] ?? '').toString().trim();
        final q = data['quantity'];
        final qty = q is num ? q.toDouble() : (double.tryParse(q?.toString() ?? '') ?? 0.0);
        matches.add(UnbarcodedMedicineMatch(
          pool: pool,
          medicineId: entry.key,
          name: (data['name'] ?? data['formula'] ?? '').toString().trim(),
          rawBarcode: rawBar,
          type: (data['type'] ?? data['dosageForm'] ?? '').toString().trim(),
          dose: (data['dose'] ?? data['dosage'] ?? '').toString().trim(),
          quantity: qty < 0 ? 0 : qty,
          expiryDate: (data['expiryDate'] ?? data['expiry'] ?? '').toString().trim(),
          inLocal: entry.value.inLocal,
          inCloud: entry.value.inCloud,
        ));
      }
    }

    matches.sort((a, b) {
      final pCmp = a.pool.key.compareTo(b.pool.key);
      if (pCmp != 0) return pCmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return (matches: matches, totalScanned: totalScanned, errors: errors);
  }

  /// Removes medicine batches WITHOUT erasing their history (rules: nothing is deleted,
  /// quantity only changes through movements):
  ///   1. the remaining stock is written off with one once-only `count` movement
  ///      (id derived from [removalId], so a retry or a second PC never doubles it);
  ///   2. the batch is marked deleted on this PC, the LAN and the cloud (a tombstone
  ///      `deleted: true` that offline PCs also pick up, so it cannot come back);
  ///   3. one inventory log entry per batch records who, when, the quantity and [reason].
  ///
  /// Only Chairman / HQ Manager / the LAN server may call it (checked here, not just in the UI).
  static Future<BatchDeleteResult> removeBatches(
    Map<StockPool, List<String>> batchesByPool, {
    required String reason,
    void Function(String)? onProgress,
  }) async {
    final errors = <String>[];
    try {
      StockAuthority.requireManage('Removing medicines');
    } catch (e) {
      return BatchDeleteResult(localRemoved: 0, cloudDeleted: 0, errors: ['$e']);
    }
    final cleanReason = reason.trim().isEmpty ? 'removed' : reason.trim();
    await StockLedger.ensureOpen();
    var removed = 0;
    final removalId = 'rm_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final who = LocalStorageService.getActiveUsername();

    for (final entry in batchesByPool.entries) {
      final pool = entry.key;
      final ids = entry.value.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
      if (ids.isEmpty) continue;
      onProgress?.call('Removing ${ids.length} item(s) from ${pool.key}…');

      for (final id in ids) {
        try {
          final it = StockLedger.item(pool.key, id);
          final name = (it?['name'] ?? '').toString();
          final raw = it == null ? 0.0 : _num(it['quantityRaw'] ?? it['quantity']);
          if (raw > 0) {
            await StockActions.countDifference(
              pool,
              id,
              -raw,
              name: name,
              reason: 'removed: $cleanReason',
              opKey: '${removalId}_$id',
            );
          }
          await StockActions.deleteBatch(pool, id);
          removed++;
          await StockLog.record({
            'id': '${removalId}_${pool.key.replaceAll('/', '_')}_$id',
            'action': 'remove_medicine',
            'medicineId': id,
            'medicineName': name,
            'barcode': (it?['barcode'] ?? '').toString(),
            'expiryDate': (it?['expiryDate'] ?? '').toString(),
            'quantityBefore': raw,
            'quantityAfter': 0,
            'pool': pool.key,
            'branchId': pool.branch,
            'camp': pool.camp ?? '',
            'reason': cleanReason,
            'performedBy': who,
            'createdAt': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          errors.add('Remove ${pool.key}|$id: $e');
        }
      }
    }
    StockLedger.resetCache();
    // Cloud tombstones are written by StockActions.deleteBatch on uploader PCs; on a LAN
    // desk the server applies and uploads them, so nothing is force-written to the cloud here.
    return BatchDeleteResult(localRemoved: removed, cloudDeleted: 0, errors: errors);
  }

  static double _num(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

  static void _broadcastWipe(
    StockPool pool,
    String wipeId,
    int wipedAtMs, {
    void Function(String)? onProgress,
    List<String>? errors,
  }) {
    try {
      final payload = StockSync.buildWipePayload(pool, wipeId, wipedAtMs);
      final broadcast = StockSync.serverBroadcast;
      if (broadcast != null) {
        broadcast(payload);
        onProgress?.call('Live wipe broadcast delivered to all connected LAN workstations.');
        debugPrint('[StockWipe] Broadcast sent for pool ${pool.key} (wipeId=$wipeId)');
      } else if (RealtimeManager().hasServerLink) {
        RealtimeManager().sendMessage(payload);
        onProgress?.call('Wipe signal sent over LAN link.');
      } else {
        onProgress?.call('Note: No local LAN server broadcast channel active (Web/remote desks will wipe via Firestore marker).');
      }
    } catch (e) {
      errors?.add('LAN broadcast error: $e');
      onProgress?.call('⚠️ LAN broadcast note: $e');
    }
  }
}
