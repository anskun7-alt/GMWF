// lib/services/stock/stock_log.dart
//
// Inventory activity log (who changed which medicine, when, by how much, why).
//
//   • Every entry has an id. It is saved on this PC first (Hive `local_audit_logs`,
//     key `inv_log_<id>`), so it shows at once, offline too.
//   • It is sent over the LAN as `inventory_log`. The LAN server forwards every message to
//     the other desks, so every PC of the branch ends up with the same log.
//   • Who uploads to the cloud: the LAN server, or a PC with no LAN link (same rule as
//     stock, StockSync.uploadsToCloud). The cloud document id is the entry id, so a retry or
//     a second uploader never creates a duplicate.
//   • Entries with `cloud: false` (e.g. one per dispensed token) stay on the LAN only, to
//     save Firebase quota; the stock movements themselves still reach the cloud.

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../realtime/realtime_manager.dart';
import '../local_storage_service.dart';
import 'stock_sync.dart';

class StockLog {
  StockLog._();

  static const String evLog = 'inventory_log';

  static final Random _rand = Random();

  static String newId() {
    final ms = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final salt = List.generate(5, (_) => _rand.nextInt(36).toRadixString(36)).join();
    return 'log_${ms}_$salt';
  }

  /// Saves [entry] on this PC, sends it to the LAN, and (on an uploader PC) queues it for
  /// the cloud. Never throws.
  static Future<void> record(Map<String, dynamic> entry) async {
    try {
      _stamp(entry);
      await LocalStorageService.saveLocalInventoryLog(entry);
      await share(entry);
    } catch (e) {
      debugPrint('[StockLog] record failed: $e');
    }
  }

  /// Sends an entry that is ALREADY saved locally to the LAN and the cloud.
  static Future<void> share(Map<String, dynamic> entry) async {
    try {
      _stamp(entry);
      final clean = _clean(entry);
      final branch = (clean['branchId'] ?? LocalStorageService.getActiveUserBranchId()).toString();
      final payload = <String, dynamic>{
        'event_type': evLog,
        '_messageId': 'invlog_${clean['id']}',
        'branchId': branch,
        'data': clean,
      };
      if (StockSync.isServer) {
        StockSync.serverBroadcast?.call({...payload, '_serverPush': true});
      } else if (RealtimeManager().hasServerLink) {
        RealtimeManager().sendMessage(payload);
      }
      if (StockSync.uploadsToCloud) await _queueCloud(clean, branch);
    } catch (e) {
      debugPrint('[StockLog] share failed: $e');
    }
  }

  /// An `inventory_log` message from another PC: keep it locally (same id = same row), and
  /// on the LAN server queue it for the cloud.
  static Future<void> handleIncoming(Map<String, dynamic> message) async {
    try {
      final raw = message['data'];
      if (raw is! Map) return;
      final entry = Map<String, dynamic>.from(raw);
      if ((entry['id'] ?? '').toString().isEmpty) return;
      await LocalStorageService.saveLocalInventoryLog(entry);
      if (StockSync.isServer) {
        final branch = (entry['branchId'] ?? message['branchId'] ?? '').toString();
        await _queueCloud(entry, branch);
      }
    } catch (e) {
      debugPrint('[StockLog] incoming failed: $e');
    }
  }

  static Future<void> _queueCloud(Map<String, dynamic> entry, String branch) async {
    if (entry['cloud'] == false || branch.isEmpty) return;
    await LocalStorageService.enqueueSync({
      'type': 'save_inventory_log',
      'branchId': branch,
      'docId': entry['id'],
      'id': entry['id'],
      'data': entry,
    });
  }

  static void _stamp(Map<String, dynamic> entry) {
    entry['id'] = (entry['id'] ?? entry['docId'] ?? '').toString().isEmpty
        ? newId()
        : (entry['id'] ?? entry['docId']).toString();
    entry['createdAt'] ??= DateTime.now().toIso8601String();
    entry['performedByName'] ??= LocalStorageService.getActiveUsername();
    entry['branchId'] ??= LocalStorageService.getActiveUserBranchId();
  }

  /// Only plain values travel (no Firestore Timestamp / FieldValue objects).
  static Map<String, dynamic> _clean(Map<String, dynamic> entry) {
    Object? fix(Object? v) {
      if (v == null || v is num || v is bool || v is String) return v;
      if (v is DateTime) return v.toIso8601String();
      if (v is Map) return {for (final e in v.entries) e.key.toString(): fix(e.value)};
      if (v is Iterable) return v.map(fix).toList();
      try {
        final d = (v as dynamic).toDate();
        if (d is DateTime) return d.toIso8601String();
      } catch (_) {}
      return v.toString();
    }

    return {for (final e in entry.entries) e.key: fix(e.value)};
  }
}
