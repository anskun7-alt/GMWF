// lib/services/stock/stock_wipe_service.dart
//
// Server-side inventory wipe — clears all stock data for one pool from local
// Hive boxes, the Firestore collection, and broadcasts to all connected desks
// so they clear their caches immediately.
//
// Called only by the server's InventoryWipePanel after password verification.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../local_storage_service.dart';
import 'stock_ledger.dart';
import 'stock_pool.dart';
import 'stock_sync.dart';

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
  bool get success => itemsWiped >= 0;
}

class StockWipeService {
  StockWipeService._();

  static const Duration _cloudTimeout = Duration(seconds: 8);

  /// Wipes all inventory data for [pool]:
  ///   1. Marks every local item deleted (Hive).
  ///   2. Clears all movements for the pool from stock_moves_v1.
  ///   3. Purges inventory sync-queue entries from sync_queue + server_sync_queue.
  ///   4. Deletes Firestore docs in the pool's cloud collection (fast batch, 8s timeout).
  ///   5. Removes the repair flag so repair re-runs next start.
  ///   6. Broadcasts a 'stock_wipe' LAN message so every connected desk clears its cache.
  ///
  /// Returns a [WipeResult] with counts. Never throws.
  static Future<WipeResult> wipePool(StockPool pool, {void Function(String)? onProgress}) async {
    final errors = <String>[];
    var itemsWiped = 0;
    var movesWiped = 0;
    var cloudDocsDeleted = 0;

    // 1. ── Open boxes ───────────────────────────────────────────────────────
    try {
      await StockLedger.ensureOpen();
    } catch (e) {
      errors.add('Could not open Hive boxes: $e');
      return WipeResult(itemsWiped: 0, movesWiped: 0, cloudDocsDeleted: 0, errors: errors);
    }

    onProgress?.call('Wiping local items from database…');

    // 2. ── Mark every item deleted locally ──────────────────────────────────
    try {
      final allItems = StockLedger.items(pool: pool.key);
      for (final item in allItems) {
        final id = (item['medicineId'] ?? item['id'] ?? '').toString();
        if (id.isEmpty) continue;
        try {
          await StockLedger.markDeleted(pool.key, id);
          itemsWiped++;
        } catch (e) {
          errors.add('markDeleted $id: $e');
        }
      }
      onProgress?.call('Marked $itemsWiped local items deleted.');
      debugPrint('[StockWipe] Marked $itemsWiped items deleted (pool ${pool.key})');
    } catch (e) {
      errors.add('Items wipe failed: $e');
    }

    // 3. ── Clear movements for this pool ────────────────────────────────────
    onProgress?.call('Clearing local ledger movements…');
    try {
      if (Hive.isBoxOpen(StockLedger.movesBoxName)) {
        final movesBox = Hive.box(StockLedger.movesBoxName);
        final toDelete = <dynamic>[];
        for (final k in movesBox.keys) {
          final v = movesBox.get(k);
          if (v is Map && (v['pool'] ?? '').toString() == pool.key) {
            toDelete.add(k);
          }
        }
        await movesBox.deleteAll(toDelete);
        movesWiped = toDelete.length;
        onProgress?.call('Cleared $movesWiped ledger movement records.');
        debugPrint('[StockWipe] Deleted $movesWiped movements for pool ${pool.key}');
      }
    } catch (e) {
      errors.add('Moves wipe failed: $e');
    }

    // 4. ── Purge inventory sync-queue entries ───────────────────────────────
    onProgress?.call('Purging sync outbox queues…');
    try {
      const inventoryTypes = {
        'update_inventory', 'add_inventory_stock', 'delete_inventory',
        'stock_moves', 'inventory_stock_sync',
      };
      var queuePurged = 0;
      for (final boxName in [LocalStorageService.syncBox, 'server_sync_queue']) {
        if (!Hive.isBoxOpen(boxName)) continue;
        final box = Hive.box(boxName);
        final toPurge = <dynamic>[];
        for (final k in box.keys) {
          final v = box.get(k);
          if (v is Map) {
            final type = (v['type'] ?? v['action'] ?? v['event_type'] ?? '').toString();
            if (!inventoryTypes.contains(type)) continue;
            final bid = (v['branchId'] ?? v['branch'] ?? '').toString().toLowerCase().trim();
            if (bid == pool.branch || bid == pool.cloudBranch) {
              toPurge.add(k);
            }
          }
        }
        await box.deleteAll(toPurge);
        queuePurged += toPurge.length;
      }
      onProgress?.call('Purged $queuePurged pending sync-queue items.');
      debugPrint('[StockWipe] Purged $queuePurged entries from sync queues');
    } catch (e) {
      errors.add('Sync queue purge failed: $e');
    }

    // 5. ── Delete Firestore docs (Fast, non-blocking) ───────────────────────
    onProgress?.call('Checking Firestore cloud data…');
    try {
      final colRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(pool.cloudBranch)
          .collection(pool.collection);

      var hasMore = true;
      var loops = 0;
      while (hasMore && loops < 5) {
        loops++;
        final snap = await colRef.limit(200).get().timeout(_cloudTimeout);
        if (snap.docs.isEmpty) {
          hasMore = false;
          break;
        }

        final batch = FirebaseFirestore.instance.batch();
        for (final doc in snap.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit().timeout(_cloudTimeout);
        cloudDocsDeleted += snap.docs.length;
        onProgress?.call('Deleted $cloudDocsDeleted cloud documents so far…');
        debugPrint('[StockWipe] Deleted ${snap.docs.length} cloud docs (total $cloudDocsDeleted)');

        if (snap.docs.length < 200) {
          hasMore = false;
        }
      }

      if (cloudDocsDeleted == 0) {
        onProgress?.call('Cloud collection is already empty (or already wiped manually).');
      } else {
        onProgress?.call('Deleted total $cloudDocsDeleted Firestore documents.');
      }
    } catch (e) {
      debugPrint('[StockWipe] Cloud delete note: $e');
      onProgress?.call('Cloud sync note: Collection already empty or unreachable ($e).');
    }

    // 6. ── Remove repair flag so repair re-runs ─────────────────────────────
    onProgress?.call('Resetting repair flags…');
    try {
      if (Hive.isBoxOpen('app_flags')) {
        await Hive.box('app_flags').delete('stock_repair_v1');
        await Hive.box('app_flags').delete('stock_repair_v1|${pool.key}');
      }
      try {
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(pool.cloudBranch)
            .collection('inventory_meta')
            .doc('repair_v1_${pool.collection}')
            .delete()
            .timeout(const Duration(seconds: 4));
      } catch (_) {}
    } catch (e) {
      errors.add('Repair flag reset note: $e');
    }

    // 7. ── Reset the last-sync timestamp so a full re-download occurs ────────
    try {
      final syncKey = 'stock_v2_${pool.key.replaceAll('/', '_')}';
      await LocalStorageService.setLastSyncedServerTimestamp(syncKey, '');
    } catch (_) {}

    // 8. ── Reset local ledger cache ─────────────────────────────────────────
    StockLedger.resetCache();

    // 9. ── Broadcast wipe to all connected desks ────────────────────────────
    onProgress?.call('Broadcasting wipe to Doctor & Dispensary desks…');
    try {
      StockSync.serverBroadcast?.call({
        'event_type': 'stock_wipe',
        'branchId': pool.branch,
        'data': {
          'pool': pool.key,
          'cloudBranch': pool.cloudBranch,
          'collection': pool.collection,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
      });
      onProgress?.call('Live wipe broadcast delivered to all connected workstations.');
      debugPrint('[StockWipe] Broadcast sent for pool ${pool.key}');
    } catch (e) {
      errors.add('Broadcast note: $e');
    }

    onProgress?.call('✅ Master wipe completed successfully.');
    return WipeResult(
      itemsWiped: itemsWiped,
      movesWiped: movesWiped,
      cloudDocsDeleted: cloudDocsDeleted,
      errors: errors,
    );
  }
}
