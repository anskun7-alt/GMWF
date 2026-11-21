// lib/services/stock/expiry_service.dart
//
// Expiry management (Med Inventory › Expiry), 2026-11-21.
//
//   • Expiry is a month: "12-2026" means the medicine expires on 01-12-2026 (user rule), so a
//     batch is EXPIRED from the first day of its expiry month.
//   • Remove (write off) an expired batch: its remaining stock leaves through one once-only
//     `count` movement, then the batch is hidden everywhere (kept for history), and logged.
//   • Fix expiry (a wrongly typed date): details only, never quantity, logged.
//   • A dispenser cannot do either directly: it sends a request (`expiry_action`) over the
//     LAN. A Supervisor, a Doctor allowed to approve, a Branch Manager, the HQ Manager or the
//     Chairman approves or rejects it. Movement ids come from the request id, so approving
//     the same request on two PCs changes stock once.

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../../realtime/realtime_manager.dart';
import '../local_storage_service.dart';
import 'expiry_rules.dart';
import 'stock_actions.dart';
import 'stock_authority.dart';
import 'stock_ledger.dart';
import 'stock_log.dart';
import 'stock_pool.dart';
import 'stock_reader.dart';
import 'stock_sync.dart';

enum ExpiryStatus { expired, withinOneMonth, withinThreeMonths, later, noExpiry }

class ExpiryRow {
  final StockPool pool;
  final String medicineId;
  final String name;
  final String type;
  final String dose;
  final String barcode;
  final String expiryRaw;
  final DateTime? month;
  final double quantity;
  final ExpiryStatus status;

  /// Whole months from this month to the expiry month (0 = expires this month, < 0 = past).
  final int monthsLeft;

  const ExpiryRow({
    required this.pool,
    required this.medicineId,
    required this.name,
    required this.type,
    required this.dose,
    required this.barcode,
    required this.expiryRaw,
    required this.month,
    required this.quantity,
    required this.status,
    required this.monthsLeft,
  });

  String get key => '${pool.key}|$medicineId';
  String get expiryLabel => month == null ? (expiryRaw.isEmpty ? 'No expiry' : expiryRaw) : DateFormat('MMM yyyy').format(month!);
}

/// One action inside a request or a direct change.
class ExpiryAction {
  final StockPool pool;
  final String medicineId;
  final String action; // 'writeoff' | 'fix_expiry'
  final DateTime? newExpiry;
  final String name;
  final String type;
  final String dose;
  final String oldExpiry;
  final double quantity;

  const ExpiryAction({
    required this.pool,
    required this.medicineId,
    required this.action,
    this.newExpiry,
    this.name = '',
    this.type = '',
    this.dose = '',
    this.oldExpiry = '',
    this.quantity = 0,
  });

  factory ExpiryAction.fromRow(ExpiryRow r, String action, {DateTime? newExpiry}) => ExpiryAction(
        pool: r.pool,
        medicineId: r.medicineId,
        action: action,
        newExpiry: newExpiry,
        name: r.name,
        type: r.type,
        dose: r.dose,
        oldExpiry: r.expiryRaw,
        quantity: r.quantity,
      );

  Map<String, dynamic> toMap() => {
        'pool': pool.key,
        'medicineId': medicineId,
        'action': action,
        if (newExpiry != null) 'newExpiry': ExpiryService.storeMonth(newExpiry!),
        'name': name,
        'type': type,
        'dose': dose,
        'expiryDate': oldExpiry,
        'quantity': quantity,
      };

  static ExpiryAction? fromMap(Map m) {
    final pool = StockPool.fromKey(m['pool']?.toString());
    final id = (m['medicineId'] ?? '').toString();
    if (pool == null || id.isEmpty) return null;
    return ExpiryAction(
      pool: pool,
      medicineId: id,
      action: (m['action'] ?? '').toString(),
      newExpiry: parseExpiryMonth((m['newExpiry'] ?? '').toString()),
      name: (m['name'] ?? '').toString(),
      type: (m['type'] ?? '').toString(),
      dose: (m['dose'] ?? '').toString(),
      oldExpiry: (m['expiryDate'] ?? '').toString(),
      quantity: (m['quantity'] is num) ? (m['quantity'] as num).toDouble() : 0,
    );
  }
}

class ExpiryService {
  ExpiryService._();

  static const String requestType = 'expiry_action';
  static const String requestsBox = 'local_edit_requests';

  /// Stored form of an expiry month: day is always 01.
  static String storeMonth(DateTime m) => DateFormat('yyyy-MM-01').format(DateTime(m.year, m.month, 1));

  static int _monthIndex(DateTime d) => d.year * 12 + d.month;

  /// Expired from the first day of its expiry month. A batch with no readable expiry is not.
  static bool isExpired(Map batch, {DateTime? now}) => isBatchExpired(batch, now: now);

  static ExpiryStatus statusOf(DateTime? month, {DateTime? now}) {
    if (month == null) return ExpiryStatus.noExpiry;
    final n = now ?? DateTime.now();
    final left = _monthIndex(month) - _monthIndex(n);
    if (left <= 0) return ExpiryStatus.expired;
    if (left <= 1) return ExpiryStatus.withinOneMonth;
    if (left <= 3) return ExpiryStatus.withinThreeMonths;
    return ExpiryStatus.later;
  }

  /// Every batch with stock in [pools], expired first, then by expiry month.
  static List<ExpiryRow> rows(List<StockPool> pools, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final out = <ExpiryRow>[];
    for (final pool in pools) {
      for (final b in StockReader.batches(pool)) {
        final q = StockReader.qty(b);
        if (q <= 0) continue;
        final raw = (b['expiryDate'] ?? b['expiry'] ?? '').toString().trim();
        final m = parseExpiryMonth(raw);
        out.add(ExpiryRow(
          pool: pool,
          medicineId: (b['medicineId'] ?? b['id']).toString(),
          name: (b['name'] ?? b['formula'] ?? '').toString(),
          type: (b['type'] ?? '').toString(),
          dose: (b['dose'] ?? '').toString(),
          barcode: (b['barcode'] ?? b['rollNo'] ?? '').toString(),
          expiryRaw: raw,
          month: m,
          quantity: q,
          status: statusOf(m, now: n),
          monthsLeft: m == null ? 9999 : _monthIndex(m) - _monthIndex(n),
        ));
      }
    }
    out.sort((a, b) {
      final c = a.monthsLeft.compareTo(b.monthsLeft);
      if (c != 0) return c;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  // ── Who may do what ──────────────────────────────────────────────────────────

  static String get _role => LocalStorageService.getActiveUserRole().toLowerCase().trim();

  /// Supervisor, Branch Manager, HQ Manager, Chairman / executives, or a Doctor when the
  /// branch allows doctors to approve inventory requests.
  static bool canApprove({String? branchId}) {
    final r = _role;
    if (r.contains('dispens') && !r.contains('doc')) return false;
    if (r.contains('supervisor') || r.contains('incharge') || r.contains('branch manager') || r == 'bm' || r == 'manager') {
      return true;
    }
    if (StockAuthority.isHigherAuthorityRole(r)) return true;
    if (r.contains('doctor') || r.startsWith('doc')) {
      return LocalStorageService.isDoctorInventoryApprovalAllowed(branchId ?? '');
    }
    return false;
  }

  // ── Direct changes (non-dispenser users, and approved requests) ──────────────

  /// Writes the batch down to 0 (one once-only movement) and hides it everywhere.
  static Future<void> writeOff(
    StockPool pool,
    String medicineId, {
    required String reason,
    required String opKey,
    String? requestId,
    String? approvedBy,
  }) async {
    await StockLedger.ensureOpen();
    final it = StockLedger.item(pool.key, medicineId);
    final name = (it?['name'] ?? '').toString();
    final raw = it == null ? 0.0 : _num(it['quantityRaw'] ?? it['quantity']);
    if (raw > 0) {
      await StockActions.countDifference(pool, medicineId, -raw,
          name: name, reason: 'expired: $reason', opKey: opKey);
    }
    await StockActions.deleteBatch(pool, medicineId);
    await StockLog.record({
      'id': 'log_$opKey',
      'action': 'remove_medicine',
      'medicineName': name,
      'medicineType': (it?['type'] ?? '').toString(),
      'dose': (it?['dose'] ?? '').toString(),
      'medicineId': medicineId,
      'barcode': (it?['barcode'] ?? '').toString(),
      'expiryDate': (it?['expiryDate'] ?? '').toString(),
      'quantityBefore': raw,
      'quantityAfter': 0,
      'pool': pool.key,
      'branchId': pool.branch,
      'reason': reason,
      if (requestId != null) 'approvedRequestId': requestId,
      if (approvedBy != null) 'approvedByName': approvedBy,
    });
  }

  /// Corrects a wrongly typed expiry (details only).
  static Future<void> fixExpiry(
    StockPool pool,
    String medicineId,
    DateTime newMonth, {
    required String reason,
    required String opKey,
    String? requestId,
    String? approvedBy,
  }) async {
    await StockLedger.ensureOpen();
    final it = StockLedger.item(pool.key, medicineId);
    final before = (it?['expiryDate'] ?? '').toString();
    final after = storeMonth(newMonth);
    await StockActions.saveDetails(pool, medicineId, {'expiryDate': after});
    await StockLog.record({
      'id': 'log_$opKey',
      'action': 'expiry_edited',
      'medicineName': (it?['name'] ?? '').toString(),
      'medicineType': (it?['type'] ?? '').toString(),
      'dose': (it?['dose'] ?? '').toString(),
      'medicineId': medicineId,
      'expiryBefore': before,
      'expiryDate': after,
      'pool': pool.key,
      'branchId': pool.branch,
      'reason': reason,
      if (requestId != null) 'approvedRequestId': requestId,
      if (approvedBy != null) 'approvedByName': approvedBy,
    });
  }

  /// Applies [actions] now (a user who does not need approval).
  static Future<int> applyDirect(List<ExpiryAction> actions, {required String reason}) async {
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    var done = 0;
    for (final a in actions) {
      final opKey = 'exp_${stamp}_${a.pool.key.replaceAll('/', '_')}_${a.medicineId}';
      try {
        if (a.action == 'writeoff') {
          await writeOff(a.pool, a.medicineId, reason: reason, opKey: opKey);
          done++;
        } else if (a.action == 'fix_expiry' && a.newExpiry != null) {
          await fixExpiry(a.pool, a.medicineId, a.newExpiry!, reason: reason, opKey: opKey);
          done++;
        }
      } catch (e) {
        debugPrint('[Expiry] direct ${a.action} ${a.medicineId} failed: $e');
      }
    }
    return done;
  }

  // ── Requests (dispenser) ─────────────────────────────────────────────────────

  /// Sends a request for approval over the LAN (the server stores and uploads it).
  static Future<String> sendRequest({
    required String branchId,
    required List<ExpiryAction> actions,
    required String reason,
  }) async {
    final who = LocalStorageService.getActiveUsername();
    final user = LocalStorageService.getActiveUserData();
    final uid = (user['uid'] ?? user['id'] ?? 'dispenser').toString();
    final requestId = 'req_expiry_${uid}_${DateTime.now().millisecondsSinceEpoch}';
    final items = [for (final a in actions) a.toMap()];
    final first = actions.isEmpty ? null : actions.first;
    final reqMap = <String, dynamic>{
      'id': requestId,
      'requestId': requestId,
      'requestType': requestType,
      'requestedBy': uid,
      'requestedByName': who,
      'requesterName': who,
      'requestedAt': DateTime.now().toIso8601String(),
      'status': 'pending',
      'reason': reason,
      'branchId': branchId,
      'campId': first?.pool.camp ?? '',
      'items': items,
      'draftItems': items,
      'summary': _summary(actions),
    };
    await LocalStorageService.saveLocalEditRequest(reqMap);
    try {
      RealtimeManager().sendMessage({
        'event_type': 'request_created',
        'branchId': branchId,
        'data': reqMap,
      });
    } catch (_) {}
    if (StockSync.uploadsToCloud) {
      await LocalStorageService.enqueueSync({
        'type': 'save_inventory_edit_request',
        'branchId': branchId,
        'requestId': requestId,
        'data': reqMap,
      });
    }
    await StockLog.record({
      'id': 'log_$requestId',
      'action': 'expiry_requested',
      'requestId': requestId,
      'medicineName': _summary(actions),
      'reason': reason,
      'branchId': branchId,
      'pool': first?.pool.key ?? '',
      'performedByName': who,
    });
    return requestId;
  }

  static String _summary(List<ExpiryAction> actions) {
    final w = actions.where((a) => a.action == 'writeoff').length;
    final f = actions.where((a) => a.action == 'fix_expiry').length;
    final names = actions.map((a) => a.name).where((n) => n.isNotEmpty).take(3).join(', ');
    final more = actions.length > 3 ? ' +${actions.length - 3} more' : '';
    final parts = [if (w > 0) 'Remove $w', if (f > 0) 'Fix expiry of $f'];
    return '${parts.join(' · ')}: $names$more';
  }

  /// Pending expiry requests of this branch (newest first), from the LAN-synced store.
  static List<Map<String, dynamic>> pendingRequests({String? branchId}) {
    if (!Hive.isBoxOpen(requestsBox)) return const [];
    final b = StockPool.normalizeBranch(branchId);
    final out = <Map<String, dynamic>>[];
    for (final v in Hive.box(requestsBox).values) {
      if (v is! Map) continue;
      if ((v['requestType'] ?? '').toString() != requestType) continue;
      if ((v['status'] ?? 'pending').toString().toLowerCase() != 'pending') continue;
      if (b.isNotEmpty && b != 'all') {
        final rb = StockPool.normalizeBranch((v['branchId'] ?? '').toString());
        if (rb.isNotEmpty && rb != b) continue;
      }
      out.add(Map<String, dynamic>.from(v));
    }
    out.sort((x, y) => (y['requestedAt'] ?? '').toString().compareTo((x['requestedAt'] ?? '').toString()));
    return out;
  }

  /// Applies the stock changes of an approved request. Ids come from the request id, so a
  /// second approval (another PC, the Requests page) changes nothing more.
  static Future<void> applyRequestItems(Map request, {String? approvedBy}) async {
    final reqId = (request['requestId'] ?? request['id'] ?? '').toString();
    final rawItems = request['draftItems'] is List && (request['draftItems'] as List).isNotEmpty
        ? request['draftItems'] as List
        : (request['items'] is List ? request['items'] as List : const []);
    final reason = (request['reason'] ?? 'expired').toString();
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final a = ExpiryAction.fromMap(raw);
      if (a == null) continue;
      final opKey = 'exp_${reqId}_${a.pool.key.replaceAll('/', '_')}_${a.medicineId}';
      try {
        if (a.action == 'writeoff') {
          await writeOff(a.pool, a.medicineId,
              reason: reason, opKey: opKey, requestId: reqId, approvedBy: approvedBy);
        } else if (a.action == 'fix_expiry' && a.newExpiry != null) {
          await fixExpiry(a.pool, a.medicineId, a.newExpiry!,
              reason: reason, opKey: opKey, requestId: reqId, approvedBy: approvedBy);
        }
      } catch (e) {
        debugPrint('[Expiry] apply $reqId ${a.medicineId} failed: $e');
      }
    }
  }

  /// Approves (applies) or rejects a request. Returns null on success, or why it was not done.
  static Future<String?> decide(Map<String, dynamic> request, {required bool approve, String? note}) async {
    final reqId = (request['requestId'] ?? request['id'] ?? '').toString();
    if (reqId.isEmpty) return 'Request has no id.';
    if (!canApprove(branchId: request['branchId']?.toString())) {
      return 'You are not allowed to approve stock requests.';
    }
    final box = Hive.isBoxOpen(requestsBox) ? Hive.box(requestsBox) : await Hive.openBox(requestsBox);
    final current = box.get(reqId);
    final status = (current is Map ? current['status'] : request['status'])?.toString().toLowerCase() ?? 'pending';
    if (status != 'pending') return 'This request was already $status.';

    final reviewer = LocalStorageService.getActiveUsername();
    final user = LocalStorageService.getActiveUserData();
    final reviewerUid = (user['uid'] ?? user['id'] ?? '').toString();

    if (approve) await applyRequestItems(request, approvedBy: reviewer);

    final newStatus = approve ? 'approved' : 'rejected';
    final decided = <String, dynamic>{
      ...request,
      'status': newStatus,
      'reviewedAt': DateTime.now().toIso8601String(),
      'reviewedBy': reviewerUid,
      'reviewedByName': reviewer,
      if (!approve && note != null && note.isNotEmpty) 'rejectionReason': note,
    };
    await box.put(reqId, decided);

    final event = {
      'requestId': reqId,
      'id': reqId,
      'status': newStatus,
      'branchId': request['branchId'],
      'collection': 'edit_requests',
      'reviewedAt': decided['reviewedAt'],
      'reviewedBy': reviewerUid,
      'reviewedByName': reviewer,
      if (!approve && note != null && note.isNotEmpty) 'rejectionReason': note,
    };
    try {
      final payload = {
        'event_type': approve ? 'request_approved' : 'request_rejected',
        'branchId': request['branchId'],
        'data': event,
      };
      if (StockSync.isServer) {
        StockSync.serverBroadcast?.call({...payload, '_serverPush': true});
      } else {
        RealtimeManager().sendMessage(payload);
      }
    } catch (_) {}
    if (StockSync.uploadsToCloud) {
      await LocalStorageService.enqueueSync({
        'type': approve ? 'approve_request' : 'reject_request',
        'requestId': reqId,
        'id': reqId,
        'docId': reqId,
        'status': newStatus,
        'collection': 'edit_requests',
        'branchId': (request['branchId'] ?? '').toString(),
        'data': event,
      });
    }
    await StockLog.record({
      'id': 'log_decision_$reqId',
      'action': approve ? 'request_approved' : 'request_rejected',
      'requestId': reqId,
      'requestType': requestType,
      'medicineName': (request['summary'] ?? '').toString(),
      'requestedByName': (request['requestedByName'] ?? '').toString(),
      'reason': (request['reason'] ?? '').toString(),
      if (note != null && note.isNotEmpty) 'decisionReason': note,
      'branchId': (request['branchId'] ?? '').toString(),
    });
    return null;
  }

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;
}
