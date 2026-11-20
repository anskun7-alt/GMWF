// lib/services/stock/stock_cloud.dart
//
// Cloud side of the stock book.
//
// Upload: movements are grouped per medicine batch and applied in ONE Firestore transaction
// per batch. The stock document remembers the ids of the last [StockLedger.baseOpsCap]
// movements it contains (`lastOps`) and a revision counter (`rev`). The transaction skips
// every movement already in `lastOps`, so a movement sent twice — by the desk and again by
// the LAN server, after a lost acknowledgement, from a replay — still counts once.
//
// Download: reads only the pool's own collection and hands each document to the ledger
// as a confirmed base (quantity + rev + lastOps). The ledger adds the movements the cloud
// does not have yet. No timestamps are compared and nothing is floored.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../local_storage_service.dart';
import 'stock_ledger.dart';
import 'stock_movement.dart';
import 'stock_pool.dart';

class StockCloud {
  StockCloud._();

  static const Duration _timeout = Duration(seconds: 30);
  static bool _uploading = false;

  static DocumentReference<Map<String, dynamic>> docRef(StockPool pool, String medicineId) =>
      FirebaseFirestore.instance
          .collection('branches')
          .doc(pool.cloudBranch)
          .collection(pool.collection)
          .doc(medicineId);

  /// The pure part of the upload transaction: given the cloud document as it is and the
  /// movements to add, returns the fields to write (null = nothing new).
  @visibleForTesting
  static Map<String, dynamic>? mergeIntoDoc(Map<String, dynamic>? current, List<StockMovement> moves,
      {Map<String, dynamic>? details}) {
    final cur = current ?? const <String, dynamic>{};
    final lastOps = (cur['lastOps'] is List ? (cur['lastOps'] as List) : const []).map((e) => e.toString()).toList();
    final known = lastOps.toSet();
    final fresh = <StockMovement>[];
    for (final m in moves) {
      if (known.add(m.opId)) fresh.add(m);
    }
    if (fresh.isEmpty) return null;
    final q = cur['quantity'];
    final base = q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
    final inc = fresh.fold<double>(0, (s, m) => s + m.delta);
    final r = cur['rev'];
    final rev = (r is num ? r.toInt() : int.tryParse(r?.toString() ?? '') ?? 0) + 1;
    final ops = [...lastOps, ...fresh.map((m) => m.opId)];
    final capped = ops.length > StockLedger.baseOpsCap ? ops.sublist(ops.length - StockLedger.baseOpsCap) : ops;
    final out = <String, dynamic>{
      'quantity': double.parse((base + inc).toStringAsFixed(4)),
      'rev': rev,
      'lastOps': capped,
      '_applied': fresh.map((m) => m.opId).toList(), // stripped before writing
    };
    if (current == null && details != null) {
      final d = Map<String, dynamic>.from(details)
        ..removeWhere((k, _) => const {
              'base', 'rev', 'baseOps', 'quantity', 'quantityRaw', 'stock', 'lastOps', 'updatedAt', 'lastUpdated', 'deleted',
            }.contains(k));
      out.addAll(d);
    }
    return out;
  }

  /// Uploads this PC's pending movements (all, or of one branch). Never throws.
  /// Returns how many movements are now in the cloud.
  static Future<int> uploadPending({String? branch}) async {
    if (_uploading) return 0;
    _uploading = true;
    var done = 0;
    try {
      final pending = StockLedger.pendingUpload(branch: branch);
      final byItem = <String, List<StockMovement>>{};
      for (final m in pending) {
        byItem.putIfAbsent(m.itemKey, () => []).add(m);
      }
      for (final group in byItem.values) {
        final first = group.first;
        final pool = StockPool.fromKey(first.pool);
        if (pool == null) continue;
        final details = StockLedger.item(first.pool, first.medicineId);
        try {
          final res = await _applyGroup(pool, first.medicineId, group, details);
          done += group.length;
          await StockLedger.markInCloud(group.map((m) => m.opId), cloudRev: res.rev);
          await StockLedger.applyBase(
            pool: pool.key,
            medicineId: first.medicineId,
            base: res.quantity,
            rev: res.rev,
            baseOps: res.lastOps,
          );
        } catch (e) {
          debugPrint('[StockCloud] upload ${first.itemKey} failed (will retry): $e');
        }
      }
    } finally {
      _uploading = false;
    }
    return done;
  }

  static Future<({double quantity, int rev, List<String> lastOps})> _applyGroup(
      StockPool pool, String medicineId, List<StockMovement> moves, Map<String, dynamic>? details) async {
    final ref = docRef(pool, medicineId);
    return FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final cur = snap.exists ? snap.data() : null;
      final merged = mergeIntoDoc(cur, moves, details: details);
      if (merged == null) {
        final q = cur?['quantity'];
        return (
          quantity: q is num ? q.toDouble() : 0.0,
          rev: (cur?['rev'] as num?)?.toInt() ?? 0,
          lastOps: ((cur?['lastOps'] as List?) ?? const []).map((e) => e.toString()).toList(),
        );
      }
      merged.remove('_applied');
      final write = <String, dynamic>{
        ...merged,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastUpdated': FieldValue.serverTimestamp(),
      };
      tx.set(ref, write, SetOptions(merge: true));
      return (
        quantity: (merged['quantity'] as num).toDouble(),
        rev: merged['rev'] as int,
        lastOps: (merged['lastOps'] as List).map((e) => e.toString()).toList(),
      );
    }).timeout(_timeout);
  }

  /// Writes medicine details (never quantity) for a batch, e.g. a new medicine or a name
  /// change. Never throws; returns false if it could not be written now.
  static Future<bool> saveDetails(StockPool pool, String medicineId, Map<String, dynamic> details) async {
    try {
      final d = Map<String, dynamic>.from(details)
        ..removeWhere((k, _) => const {
              'base', 'rev', 'baseOps', 'quantity', 'quantityRaw', 'stock', 'lastOps', '_quantityDelta', 'updatedAt',
              'lastUpdated',
            }.contains(k));
      d['updatedAt'] = FieldValue.serverTimestamp();
      await docRef(pool, medicineId).set(d, SetOptions(merge: true)).timeout(_timeout);
      return true;
    } catch (e) {
      debugPrint('[StockCloud] saveDetails $medicineId failed: $e');
      return false;
    }
  }

  /// Marks a batch deleted in the cloud (kept for history; screens hide it).
  static Future<bool> markDeleted(StockPool pool, String medicineId) async {
    try {
      await docRef(pool, medicineId)
          .set({'deleted': true, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true))
          .timeout(_timeout);
      return true;
    } catch (e) {
      debugPrint('[StockCloud] markDeleted $medicineId failed: $e');
      return false;
    }
  }

  static String _syncKey(StockPool p) => 'stock_v2_${p.key.replaceAll('/', '_')}';

  /// Reads the pool's collection (only what changed since the last read, unless [full]) and
  /// gives every document to the ledger. Never throws. Returns the number of documents read.
  static Future<int> download(StockPool pool, {bool full = false}) async {
    try {
      Query<Map<String, dynamic>> q =
          FirebaseFirestore.instance.collection('branches').doc(pool.cloudBranch).collection(pool.collection);
      final last = full ? null : LocalStorageService.getLastSyncedServerTimestamp(_syncKey(pool));
      final since = last == null ? null : DateTime.tryParse(last);
      if (since != null) q = q.where('updatedAt', isGreaterThan: Timestamp.fromDate(since));
      final snap = await q.get().timeout(const Duration(seconds: 45));
      Timestamp? maxTs;
      for (final doc in snap.docs) {
        await applyCloudDoc(pool, doc.id, doc.data());
        final ts = doc.data()['updatedAt'];
        if (ts is Timestamp && (maxTs == null || ts.compareTo(maxTs) > 0)) maxTs = ts;
      }
      if (maxTs != null) {
        await LocalStorageService.setLastSyncedServerTimestamp(
            _syncKey(pool), maxTs.toDate().toUtc().toIso8601String());
      }
      return snap.docs.length;
    } catch (e) {
      debugPrint('[StockCloud] download ${pool.key} failed: $e');
      return 0;
    }
  }

  /// One cloud stock document → ledger.
  static Future<void> applyCloudDoc(StockPool pool, String id, Map<String, dynamic> data) async {
    if (data['deleted'] == true) {
      await StockLedger.markDeleted(pool.key, id);
      return;
    }
    final details = Map<String, dynamic>.from(data)
      ..removeWhere((k, v) => v is Timestamp || v is FieldValue);
    final q = data['quantity'];
    await StockLedger.applyBase(
      pool: pool.key,
      medicineId: id,
      base: q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0,
      rev: (data['rev'] as num?)?.toInt() ?? 0,
      baseOps: ((data['lastOps'] as List?) ?? const []).map((e) => e.toString()).toList(),
      details: details,
    );
  }

  /// Weekly server check: compares this PC's confirmed figures with the cloud for [pool].
  /// Returns medicineId → (local base, cloud quantity) for every batch that differs although
  /// both are at the same revision (that should never happen; it is logged for admins).
  static Future<Map<String, (double, double)>> driftReport(StockPool pool) async {
    final out = <String, (double, double)>{};
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(pool.cloudBranch)
          .collection(pool.collection)
          .get()
          .timeout(const Duration(seconds: 60));
      for (final doc in snap.docs) {
        final d = doc.data();
        if (d['deleted'] == true) continue;
        final local = StockLedger.item(pool.key, doc.id);
        final cloudQ = (d['quantity'] as num?)?.toDouble() ?? 0.0;
        final cloudRev = (d['rev'] as num?)?.toInt() ?? 0;
        if (local == null) {
          if (cloudQ != 0) out[doc.id] = (0.0, cloudQ);
          continue;
        }
        final localRev = (local['rev'] as num?)?.toInt() ?? 0;
        final localBase = (local['base'] as num?)?.toDouble() ?? 0.0;
        if (localRev == cloudRev && (localBase - cloudQ).abs() > 1e-6) out[doc.id] = (localBase, cloudQ);
        if (localRev < cloudRev) {
          // Simply behind: take the newer figure (this is normal catching up, not drift).
          await applyCloudDoc(pool, doc.id, d);
        }
      }
    } catch (e) {
      debugPrint('[StockCloud] driftReport ${pool.key} failed: $e');
    }
    return out;
  }

  /// Small helper for tests and diagnostics.
  static bool get hasMovesBox => Hive.isBoxOpen(StockLedger.movesBoxName);
}
