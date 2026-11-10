import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Keeps cloud stock quantities at zero or above.
///
/// Stock deductions are uploaded as `FieldValue.increment(-n)` so that two counters
/// dispensing at once never lose each other's change. Firestore cannot cap an increment at
/// zero, so a deduction larger than what the cloud holds left the quantity negative.
///
/// [repair] runs after such a write: it reads the stock document inside a Firestore
/// transaction and, only if the quantity is below zero, sets it to 0. The transaction is
/// retried by Firestore if another device changes the same document in between, so a restock
/// or dispense landing at the same moment is never overwritten. Positive quantities are never
/// touched, and nothing is written when the quantity is already >= 0 (one read, no write).
class StockFloor {
  StockFloor._();

  static const Duration _timeout = Duration(seconds: 20);

  /// Documents with a repair already running, so one burst of deductions on the same
  /// medicine does not start several transactions for it. A request that arrives while one
  /// is running is remembered in [_again] and runs once more when the first finishes.
  static final Set<String> _inFlight = <String>{};
  static final Set<String> _again = <String>{};

  /// Sets the stock document at [docPath] to 0 if its quantity is negative. Never throws.
  static Future<void> repair(String docPath) async {
    if (docPath.isEmpty) return;
    if (!_inFlight.add(docPath)) {
      _again.add(docPath);
      return;
    }
    try {
      final ref = FirebaseFirestore.instance.doc(docPath);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final raw = snap.data()?['quantity'];
        final qty = raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
        if (qty == null || qty >= 0) return;
        tx.update(ref, {
          'quantity': 0,
          'negativeCorrectedFrom': qty,
          'negativeCorrectedAt': FieldValue.serverTimestamp(),
          'lastUpdated': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        debugPrint('[StockFloor] $docPath was $qty — set to 0');
      }).timeout(_timeout);
    } catch (e) {
      // Offline or quota: left as is; the next deduction or inventory download repairs it.
      debugPrint('[StockFloor] repair skipped for $docPath: $e');
    } finally {
      _inFlight.remove(docPath);
    }
    if (_again.remove(docPath)) await repair(docPath);
  }

  /// Repairs every document in [docPaths], one after another. Never throws.
  static Future<void> repairAll(Iterable<String> docPaths) async {
    for (final p in docPaths.toSet()) {
      await repair(p);
    }
  }

  /// Finds stock documents below zero in [collectionPath] and sets them to 0. Only negative
  /// documents are read, so on a healthy inventory this costs a single read. Never throws.
  static Future<int> repairCollection(String collectionPath) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(collectionPath)
          .where('quantity', isLessThan: 0)
          .get()
          .timeout(_timeout);
      for (final d in snap.docs) {
        await repair(d.reference.path);
      }
      return snap.docs.length;
    } catch (e) {
      debugPrint('[StockFloor] scan skipped for $collectionPath: $e');
      return 0;
    }
  }
}
