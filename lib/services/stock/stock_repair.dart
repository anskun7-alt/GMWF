// lib/services/stock/stock_repair.dart
//
// One-time stock repair, run once on every PC when the new stock book is installed.
//
// On this PC:
//   1. Old stock changes still waiting in the upload queue (update_inventory /
//      add_inventory_stock) become movements with stable ids, so they still reach the cloud —
//      once — through the new path.
//   2. Old stock records (saved twice per medicine, under "stock:<id>" and "<id>") are read,
//      merged per pool + medicine, and replaced by one ledger record each.
//      • no name → removed if its quantity is 0, otherwise put in quarantine (with quantity)
//      • a camp the branch does not have → same
//   3. The pool's figures are then taken from ONE source: the cloud (LAN server / standalone
//      PC) or the LAN server (desk). Until then the old figure is shown, marked as
//      provisional (rev -1), so nothing shows 0 in the meantime.
//
// In the cloud (first uploading PC per pool, once): documents with no name and quantity 0
// are deleted; documents with no name but stock are marked deleted + quarantined; negative
// figures are listed for a stock count. Old Karachi collections are only reported.
//
// Every step is logged; the summary goes to the audit log and the quarantine list.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../local_storage_service.dart';
import 'stock_cloud.dart';
import 'stock_ledger.dart';
import 'stock_movement.dart';
import 'stock_pool.dart';
import 'stock_reader.dart';
import 'stock_sync.dart';

class StockRepair {
  StockRepair._();

  static const String flagKey = 'stock_repair_v1';
  static const String quarantineBox = 'stock_quarantine';
  static bool _running = false;

  static bool get isDone {
    try {
      return Hive.isBoxOpen('app_flags') && Hive.box('app_flags').get(flagKey) != null;
    } catch (_) {
      return false;
    }
  }

  /// Runs the local repair once. Safe to call on every start. Never throws.
  static Future<Map<String, int>> runIfNeeded({String? branchId}) async {
    final stats = <String, int>{};
    if (_running) return stats;
    _running = true;
    try {
      final flags = await LocalStorageService.ensureBoxOpen('app_flags');
      if (flags.get(flagKey) != null) {
        // Local part done: finish the provisional figures when the cloud is reachable.
        await _settleProvisional(branchId);
        return stats;
      }
      await StockLedger.ensureOpen();
      await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      final queued = await convertQueuedChanges(branchFallback: branchId);
      stats['queuedConverted'] = queued.length;
      // The old figures on this PC already include these queued changes.
      final inside = <String, List<String>>{};
      for (final m in queued) {
        inside.putIfAbsent(m.itemKey, () => []).add(m.opId);
      }
      stats.addAll(await convertLegacyRecords(branchFallback: branchId, alreadyInside: inside));
      await flags.put(flagKey, DateTime.now().toIso8601String());
      await LocalStorageService.saveLocalInventoryLog({
        'action': 'stock_repair_v1',
        'details': stats,
        'timestamp': DateTime.now().toIso8601String(),
      });
      debugPrint('[StockRepair] local repair done: $stats');
      unawaited(_settleProvisional(branchId));
    } catch (e, st) {
      debugPrint('[StockRepair] failed (will retry next start): $e\n$st');
    } finally {
      _running = false;
    }
    return stats;
  }

  // ── 1. Queued old-format stock changes → movements ──────────────────────────

  static Future<List<StockMovement>> convertQueuedChanges({String? branchFallback}) async {
    final box = Hive.box(LocalStorageService.syncBox);
    final moves = <StockMovement>[];
    final remove = <dynamic>[];
    for (final k in box.keys.toList()) {
      final v = box.get(k);
      if (v is! Map) continue;
      final type = (v['type'] ?? '').toString();
      if (type != 'update_inventory' && type != 'add_inventory_stock') continue;
      final data = v['data'] is Map ? v['data'] as Map : const {};
      final medId = (v['medicineId'] ?? v['inventoryId'] ?? data['medicineId'] ?? data['id'] ?? '').toString().trim();
      double delta;
      if (type == 'add_inventory_stock') {
        final q = v['quantity'] ?? data['quantity'] ?? v['delta'];
        delta = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0;
      } else {
        final d = v['delta'] ?? data['delta'];
        delta = d is num ? d.toDouble() : double.tryParse(d?.toString() ?? '') ?? 0;
      }
      remove.add(k);
      if (medId.isEmpty || delta == 0) continue;
      final pool = StockPool.ofLegacyRecord({
        'id': medId,
        'branchId': v['branchId'] ?? data['branchId'],
        'campId': v['campId'] ?? data['campId'] ?? v['dispensaryId'] ?? data['dispensaryId'],
        'dispensaryTag': v['dispensaryTag'] ?? data['dispensaryTag'],
      }, branchFallback: branchFallback);
      if (pool == null) continue;
      moves.add(StockMovement(
        opId: StockMovement.deterministicId('legacyq', [k, v['createdAt'] ?? v['enqueuedAt'], medId, delta]),
        pool: pool.key,
        medicineId: medId,
        delta: delta,
        kind: delta > 0 ? StockMoveKind.restock : StockMoveKind.dispense,
        at: DateTime.tryParse((v['createdAt'] ?? '').toString()) ?? DateTime.now(),
        ref: (v['serial'] ?? data['serial'] ?? 'queued-before-upgrade').toString(),
        name: (data['medicineName'] ?? '').toString(),
      ));
    }
    // Recorded quietly (not re-sent over the LAN as new): uploaded by the normal upload.
    if (moves.isNotEmpty) await StockLedger.applyRemote(moves);
    if (remove.isNotEmpty) await box.deleteAll(remove);
    return moves;
  }

  // ── 2. Old records → ledger records ──────────────────────────────────────────

  static Future<Map<String, int>> convertLegacyRecords({
    String? branchFallback,
    Map<String, List<String>> alreadyInside = const {},
  }) async {
    final box = Hive.box(LocalStorageService.stockBox);
    final merged = <String, Map<String, dynamic>>{}; // pool|id → record
    final legacyKeys = <dynamic>[];
    var removedJunk = 0, quarantined = 0, duplicates = 0;

    for (final k in box.keys.toList()) {
      if (StockLedger.isLedgerKey(k)) continue;
      legacyKeys.add(k);
      final v = box.get(k);
      if (v is! Map) {
        removedJunk++;
        continue;
      }
      final item = Map<String, dynamic>.from(v);
      final id = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? '').toString().trim().isNotEmpty
          ? (item['id'] ?? item['medicineId'] ?? item['docId']).toString().trim()
          : k.toString().replaceFirst('stock:', '').trim();
      item['id'] = id;
      if (item['status'] == 'deleted' || item['deleted'] == true) {
        removedJunk++;
        continue;
      }
      // Fill a missing name from the id ("hajicamp--paracetamol--tablet--500-mg--2027-01-01").
      if (!StockReader.hasUsableName(item)) {
        final healed = LocalStorageService.healStockItemFromKeyOrId(id);
        if (healed != null) {
          item['name'] = healed['name'];
          if ((item['type'] ?? '').toString().trim().isEmpty) item['type'] = healed['type'];
          if ((item['dose'] ?? '').toString().trim().isEmpty) item['dose'] = healed['dose'];
          if ((item['expiryDate'] ?? '').toString().trim().isEmpty) item['expiryDate'] = healed['expiryDate'];
        }
      }
      final qty = StockReader.qty(item);
      final pool = StockPool.ofLegacyRecord(item, branchFallback: branchFallback);
      if (!StockReader.hasUsableName(item) || pool == null || id.isEmpty) {
        if (qty > 0) {
          await _quarantine(item, reason: pool == null ? 'unknown camp/branch' : 'no name', source: 'this PC');
          quarantined++;
        } else {
          removedJunk++;
        }
        continue;
      }
      final key = StockLedger.itemKey(pool.key, id);
      final prev = merged[key];
      if (prev == null) {
        merged[key] = {...item, '_pool': pool.key};
      } else {
        duplicates++;
        // Same record stored twice: keep the newer copy.
        final a = DateTime.tryParse((prev['updatedAt'] ?? prev['lastUpdated'] ?? '').toString());
        final b = DateTime.tryParse((item['updatedAt'] ?? item['lastUpdated'] ?? '').toString());
        if (a == null || (b != null && b.isAfter(a))) merged[key] = {...item, '_pool': pool.key};
      }
    }

    await box.deleteAll(legacyKeys);
    for (final rec in merged.values) {
      final pool = rec.remove('_pool') as String;
      final id = rec['id'].toString();
      // Provisional figure (rev -1): shown until the cloud or the LAN server gives the real one.
      await StockLedger.applyBase(
        pool: pool,
        medicineId: id,
        base: StockReader.qty(rec),
        rev: -1,
        baseOps: alreadyInside[StockLedger.itemKey(pool, id)] ?? const [],
        details: rec,
      );
    }
    return {
      'recordsKept': merged.length,
      'junkRemoved': removedJunk,
      'quarantined': quarantined,
      'duplicatesMerged': duplicates,
    };
  }

  // ── 3. Real figures from one source ──────────────────────────────────────────

  static Future<void> _settleProvisional(String? branchId) async {
    final branch = branchId ?? LocalStorageService.getActiveUserBranchId();
    if (branch.isEmpty) return;
    if (StockSync.isLanClient) {
      StockSync.requestSnapshot(branch); // the server's figures replace the provisional ones
      return;
    }
    for (final pool in StockPool.allFor(branch)) {
      final read = await StockCloud.download(pool, full: true);
      if (read == 0) continue; // offline (or empty): try again next start
      await cleanCloudPoolOnce(pool);
      // Batches the cloud never had (registered here, never uploaded): their figure goes up
      // once as a count. The id is the same on every PC, so the cloud takes it only once.
      final seeds = <StockMovement>[];
      for (final it in StockLedger.items(pool: pool.key)) {
        if ((it['rev'] as num? ?? 0) >= 0) continue;
        final id = (it['medicineId'] ?? it['id']).toString();
        final q = StockReader.qty(it);
        await StockLedger.applyBase(pool: pool.key, medicineId: id, base: 0, rev: 0, baseOps: const []);
        if (q > 0) {
          seeds.add(StockMovement(
            opId: StockMovement.deterministicId('seed', [pool.key, id]),
            pool: pool.key,
            medicineId: id,
            delta: q,
            kind: StockMoveKind.count,
            at: DateTime.now(),
            ref: 'repair: batch not in cloud',
            name: (it['name'] ?? '').toString(),
          ));
        }
      }
      if (seeds.isNotEmpty) await StockLedger.recordAll(seeds);
    }
  }

  // ── Cloud clean-up, once per pool ────────────────────────────────────────────

  static Future<void> cleanCloudPoolOnce(StockPool pool) async {
    try {
      final db = FirebaseFirestore.instance;
      final metaRef = db
          .collection('branches')
          .doc(pool.cloudBranch)
          .collection('inventory_meta')
          .doc('repair_v1_${pool.collection}');
      final meta = await metaRef.get().timeout(const Duration(seconds: 20));
      if (meta.exists) return;
      final snap = await db
          .collection('branches')
          .doc(pool.cloudBranch)
          .collection(pool.collection)
          .get()
          .timeout(const Duration(seconds: 60));
      var deleted = 0, marked = 0;
      final negatives = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        final d = doc.data();
        if (d['deleted'] == true) continue;
        final q = (d['quantity'] is num) ? (d['quantity'] as num).toDouble() : 0.0;
        if (!StockReader.hasUsableName(d)) {
          if (q == 0) {
            await doc.reference.delete();
            deleted++;
          } else {
            await doc.reference.set({'deleted': true, 'quarantined': true}, SetOptions(merge: true));
            await _quarantine({...d, 'id': doc.id}, reason: 'no name', source: 'cloud ${pool.collection}');
            await StockLedger.markDeleted(pool.key, doc.id);
            marked++;
          }
          continue;
        }
        if (q < 0) negatives.add({'medicineId': doc.id, 'name': d['name'], 'quantity': q});
      }
      final report = {
        'pool': pool.key,
        'collection': pool.collection,
        'documents': snap.docs.length,
        'deletedEmptyUnnamed': deleted,
        'quarantinedUnnamed': marked,
        'negative': negatives,
        'at': FieldValue.serverTimestamp(),
      };
      await metaRef.set(report);
      await LocalStorageService.saveLocalInventoryLog({
        'action': 'stock_repair_v1_cloud',
        'pool': pool.key,
        'details': {...report, 'at': DateTime.now().toIso8601String()},
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[StockRepair] cloud clean-up of ${pool.key} skipped: $e');
    }
  }

  // ── Quarantine ───────────────────────────────────────────────────────────────

  static Future<void> _quarantine(Map item, {required String reason, required String source}) async {
    final box = Hive.isBoxOpen(quarantineBox) ? Hive.box(quarantineBox) : await Hive.openBox(quarantineBox);
    final id = (item['id'] ?? item['medicineId'] ?? 'unknown').toString();
    await box.put('q_${source}_$id', {
      'medicineId': id,
      'name': item['name'] ?? '',
      'quantity': StockReader.qty(item),
      'branchId': item['branchId'],
      'campId': item['campId'] ?? item['dispensaryId'],
      'reason': reason,
      'source': source,
      'at': DateTime.now().toIso8601String(),
      'record': LocalStorageService.sanitize(Map<String, dynamic>.from(item)),
    });
  }

  static List<Map<String, dynamic>> quarantined() {
    if (!Hive.isBoxOpen(quarantineBox)) return const [];
    return Hive.box(quarantineBox).values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }
}
