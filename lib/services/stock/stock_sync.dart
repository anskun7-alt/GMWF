// lib/services/stock/stock_sync.dart
//
// Moves stock movements between PCs. Same behaviour on desks and on the LAN server:
//
//   • A movement made on a PC is applied there at once (StockLedger.record) and sent as a
//     `stock_moves` LAN message. The LAN server forwards every message to the other desks
//     and applies it itself. Every receiver applies it once (by opId).
//   • Who uploads to the cloud: the LAN server, or a PC that is not linked to a LAN server
//     (alone, or offline from the LAN). A desk linked to the LAN server never writes stock to
//     the cloud — the server does. If a movement reaches the cloud twice anyway (a desk that
//     went offline uploaded it, then sent it to the server), the cloud counts it once.
//   • A PC that uploads also follows its pools in the cloud (one listener per pool, reads only
//     changed documents) and, on the LAN server, passes new confirmed figures to the desks
//     as `stock_snapshot`.
//   • On (re)connect a desk sends its unconfirmed movements to the server and gets a full
//     snapshot back; weekly it sends checksums and gets a snapshot for any pool that differs.
//
// Messages from older app versions (save_stock_item with _quantityDelta, dispense_completed
// with deductedBatches) are still understood and turned into movements with stable ids.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../realtime/lan_host_manager.dart';
import '../../realtime/lan_server.dart';
import '../../realtime/realtime_manager.dart';
import '../local_storage_service.dart';
import 'stock_cloud.dart';
import 'stock_ledger.dart';
import 'stock_movement.dart';
import 'stock_pool.dart';

class StockSync {
  StockSync._();

  static const String evMoves = 'stock_moves';
  static const String evSnapshot = 'stock_snapshot';
  static const String evDetails = 'stock_details';
  static const String evChecksum = 'stock_checksum';
  static const String evDriftReport = 'stock_drift_report';
  static const String evWipe = 'stock_wipe';

  /// How long movements wait before a cloud upload (several dispenses → one write each).
  /// A PC with no LAN server uploads sooner, so other cloud-only PCs see the change soon.
  static const Duration uploadDelayServer = Duration(minutes: 10);
  static const Duration uploadDelayStandalone = Duration(seconds: 90);

  /// Set by the LAN server page: sends a payload to every connected desk.
  static void Function(Map<String, dynamic> payload)? serverBroadcast;

  /// Set by the LAN server page: sends a payload to one desk.
  static bool Function(String socketId, Map<String, dynamic> payload)? serverSendTo;

  static bool _started = false;
  static Timer? _uploadTimer;
  static Timer? _hourly;
  static Timer? _weekly;
  static Timer? _baseFlush;
  static final Set<String> _baseChanged = <String>{};
  static final Map<String, StreamSubscription> _listeners = {};
  static final Map<String, StreamSubscription> _wipeListeners = {};
  static final Set<String> _wipingPools = <String>{};
  static StreamSubscription? _ledgerSub;

  /// Builds a deduplication-safe `stock_wipe` LAN message. Uses `_serverPush: true` and a
  /// unique `_messageId` so clients never drop repeated wipes as duplicates in RealtimeRouter.
  static Map<String, dynamic> buildWipePayload(
    StockPool pool,
    String wipeId,
    int wipedAtMs, {
    String? targetClientId,
  }) {
    final nonce = '${wipeId.isNotEmpty ? wipeId : 'wipe'}_${DateTime.now().microsecondsSinceEpoch}';
    return {
      'event_type': evWipe,
      '_messageId': 'stock_wipe_${pool.key}_$nonce',
      '_serverPush': true,
      '_timestamp': wipedAtMs,
      'branchId': pool.branch,
      if (targetClientId != null && targetClientId.isNotEmpty) '_targetClientId': targetClientId,
      'data': {
        'pool': pool.key,
        'cloudBranch': pool.cloudBranch,
        'collection': pool.collection,
        'wipeId': wipeId,
        'wipedAtMs': wipedAtMs,
        'timestamp': DateTime.fromMillisecondsSinceEpoch(wipedAtMs, isUtc: true).toIso8601String(),
      },
    };
  }

  /// Drops any queued debounced base broadcasts for [poolKey].
  static void clearPendingBaseBroadcasts(String poolKey) {
    final prefix = '${poolKey.trim().toLowerCase()}|';
    _baseChanged.removeWhere((k) => k.toLowerCase().startsWith(prefix));
    if (_baseChanged.isEmpty) _baseFlush?.cancel();
  }

  /// Pauses cloud listeners, timers, and incoming stock traffic for [pool] while a master
  /// wipe is executing so nothing races with or resurrects wiped records.
  static Future<void> suspendForWipe(StockPool pool) async {
    _wipingPools.add(pool.key);
    _uploadTimer?.cancel();
    clearPendingBaseBroadcasts(pool.key);
    await _listeners.remove(pool.key)?.cancel();
    await _wipeListeners.remove(pool.key)?.cancel();
    // Wait briefly if a cloud upload transaction is already mid-flight.
    for (var i = 0; i < 25 && StockCloud.isUploading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Re-enables stock sync and cloud listeners for [pool] after a master wipe finishes.
  static void resumeAfterWipe(StockPool pool) {
    _wipingPools.remove(pool.key);
    if (_started) _followCloud(pool.branch);
  }

  /// This PC is a desk linked to a LAN server (the server does the cloud work).
  static bool get isLanClient =>
      !LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink;

  static bool get isServer => LanServer.isRunning || LanHostManager.isHostRunning;

  static bool get uploadsToCloud => !isLanClient;

  /// Starts stock syncing (idempotent). Call after Hive and Firebase are ready.
  static Future<void> start({String? branchId}) async {
    await StockLedger.ensureOpen();
    unawaited(StockLedger.sanitizeNegativesOnce());
    StockLedger.onLocalMoves = _onLocalMoves;
    StockLedger.thisPcUploads = () => uploadsToCloud;
    if (_started) {
      if (branchId != null) _followCloud(branchId);
      return;
    }
    _started = true;
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => unawaited(_hourlyTick()));
    _weekly = Timer.periodic(const Duration(hours: 6), (_) => unawaited(weeklyCheckIfDue()));
    _ledgerSub = StockLedger.changes.listen(_onLedgerChanged);
    if (branchId != null) _followCloud(branchId);
    // Movements left from the last run go out soon.
    _scheduleUpload(const Duration(minutes: 2));
  }

  static void stop() {
    _uploadTimer?.cancel();
    _hourly?.cancel();
    _weekly?.cancel();
    _baseFlush?.cancel();
    _ledgerSub?.cancel();
    for (final s in _listeners.values) {
      s.cancel();
    }
    _listeners.clear();
    for (final s in _wipeListeners.values) {
      s.cancel();
    }
    _wipeListeners.clear();
    _wipingPools.clear();
    _started = false;
  }

  // ── Local movements ──────────────────────────────────────────────────────────

  static void _onLocalMoves(List<StockMovement> moves) {
    if (moves.isEmpty) return;
    sendMoves(moves);
    if (uploadsToCloud) _scheduleUpload(isServer ? uploadDelayServer : uploadDelayStandalone);
  }

  /// Sends movements over the LAN (queued in the outbox while the link is down).
  static void sendMoves(List<StockMovement> moves) {
    if (moves.isEmpty) return;
    try {
      // Chunks keep each LAN frame small.
      for (var i = 0; i < moves.length; i += 50) {
        final part = moves.sublist(i, i + 50 > moves.length ? moves.length : i + 50);
        final wipeEpochs = <String, String>{};
        for (final m in part) {
          wipeEpochs[m.pool] = StockLedger.poolWipeId(m.pool) ?? '';
        }
        RealtimeManager().sendMessage({
          'event_type': evMoves,
          'branchId': part.first.branch,
          'data': {
            'moves': part.map((m) => m.toMap()).toList(),
            'wipeEpochs': wipeEpochs,
          },
        });
      }
    } catch (e) {
      debugPrint('[StockSync] sendMoves failed: $e');
    }
  }

  static void _scheduleUpload(Duration after) {
    if (_uploadTimer?.isActive == true) return;
    _uploadTimer = Timer(after, () => unawaited(uploadNow()));
  }

  /// Uploads pending movements now (only on a PC that uploads). Never throws.
  static Future<int> uploadNow() async {
    if (!uploadsToCloud) return 0;
    try {
      return await StockCloud.uploadPending();
    } catch (e) {
      debugPrint('[StockSync] upload failed: $e');
      return 0;
    }
  }

  static Future<void> _hourlyTick() async {
    await uploadNow();
    await StockLedger.prune();
    // Once-per-token dispense markers (StockActions.dispense) are not needed after 30 days.
    try {
      final flags = await LocalStorageService.ensureBoxOpen('app_flags');
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      final old = <dynamic>[];
      for (final k in flags.keys) {
        if (k is! String || !k.startsWith('stock_disp|')) continue;
        final at = DateTime.tryParse((flags.get(k) ?? '').toString());
        if (at == null || at.isBefore(cutoff)) old.add(k);
      }
      if (old.isNotEmpty) await flags.deleteAll(old);
    } catch (_) {}
  }

  // ── Incoming LAN messages (desks AND server) ─────────────────────────────────

  /// Handles a stock LAN message. Returns true if [eventType] was a stock event.
  static Future<bool> handle(String eventType, Map<String, dynamic> message) async {
    final data = message['data'] is Map ? Map<String, dynamic>.from(message['data'] as Map) : message;
    final socketId = (message['_socketId'] ?? '').toString();
    final senderClientId = (message['_clientId'] ?? data['clientId'] ?? '').toString();
    switch (eventType) {
      case evMoves:
        final moves = _movesFrom(data['moves']);
        if (moves.isEmpty) return true;
        final rawEpochs = data['wipeEpochs'] is Map ? data['wipeEpochs'] as Map : const {};
        final allowed = <StockMovement>[];
        final stalePools = <String>{};
        var needDeskSync = false;
        for (final m in moves) {
          if (_wipingPools.contains(m.pool)) continue;
          final myWipe = StockLedger.poolWipeId(m.pool);
          final incomingWipe = (rawEpochs[m.pool] ?? data['wipeId'] ?? '').toString().trim();
          if (myWipe != null && incomingWipe != myWipe) {
            stalePools.add(m.pool);
            continue;
          }
          if (!isServer && incomingWipe.isNotEmpty && incomingWipe != (myWipe ?? '')) {
            needDeskSync = true;
            continue;
          }
          allowed.add(m);
        }
        if (stalePools.isNotEmpty && isServer && socketId.isNotEmpty && serverSendTo != null) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          for (final pk in stalePools) {
            final p = StockPool.fromKey(pk);
            final wid = StockLedger.poolWipeId(pk);
            if (p != null && wid != null) {
              serverSendTo!(socketId, buildWipePayload(p, wid, nowMs, targetClientId: senderClientId));
            }
          }
        }
        if (needDeskSync) {
          final b = (message['branchId'] ?? moves.first.branch).toString();
          if (b.isNotEmpty) sendChecksums(b, reason: 'wipe_sync');
        }
        if (allowed.isEmpty) return true;
        final applied = await StockLedger.applyRemote(allowed);
        if (isServer && applied.any((m) => !m.inCloud)) _scheduleUpload(uploadDelayServer);
        return true;
      case evSnapshot:
        if (isServer) return true; // the server's own figures come from the cloud
        final target = (message['_targetClientId'] ?? '').toString();
        if (target.isNotEmpty && target != (RealtimeManager().clientId ?? '')) return true;
        await StockLedger.applySnapshot(data);
        return true;
      case evDetails:
        final pool = (data['pool'] ?? '').toString().trim().toLowerCase();
        final id = (data['medicineId'] ?? '').toString();
        if (pool.isEmpty || id.isEmpty || _wipingPools.contains(pool)) return true;
        final myWipe = StockLedger.poolWipeId(pool);
        final incomingWipe = (data['wipeId'] ?? '').toString().trim();
        if (myWipe != null && incomingWipe != myWipe) {
          if (isServer && socketId.isNotEmpty && serverSendTo != null) {
            final p = StockPool.fromKey(pool);
            if (p != null) {
              serverSendTo!(
                socketId,
                buildWipePayload(p, myWipe, DateTime.now().millisecondsSinceEpoch, targetClientId: senderClientId),
              );
            }
          }
          return true;
        }
        if (!isServer && incomingWipe.isNotEmpty && incomingWipe != (myWipe ?? '')) {
          final b = (message['branchId'] ?? pool.split('/').first).toString();
          if (b.isNotEmpty) sendChecksums(b, reason: 'wipe_sync');
          return true;
        }
        if (data['deleted'] == true) {
          if (data['hardDelete'] == true) {
            await StockLedger.hardDeleteItem(pool, id);
          } else {
            await StockLedger.markDeleted(pool, id);
            if (isServer) {
              final p = StockPool.fromKey(pool);
              if (p != null) unawaited(StockCloud.markDeleted(p, id));
            }
          }
        } else {
          final details = data['details'] is Map ? Map<String, dynamic>.from(data['details'] as Map) : <String, dynamic>{};
          await StockLedger.saveDetails(pool, id, details);
          if (isServer) {
            final p = StockPool.fromKey(pool);
            if (p != null) unawaited(StockCloud.saveDetails(p, id, details));
          }
        }
        return true;
      case evChecksum:
        if (!isServer) return true;
        await _answerChecksum(message, data);
        return true;
      case evDriftReport:
        if (!isServer) await StockDriftLog.storeFromServer(data);
        return true;
    }
    return false;
  }

  /// Applies movements that arrived from another PC; the LAN server also queues them for
  /// the cloud.
  static Future<List<StockMovement>> applyIncoming(List<StockMovement> moves) async {
    final filtered = moves.where((m) => !_wipingPools.contains(m.pool)).toList();
    if (filtered.isEmpty) return const [];
    final applied = await StockLedger.applyRemote(filtered);
    if (isServer && applied.any((m) => !m.inCloud)) _scheduleUpload(uploadDelayServer);
    return applied;
  }

  /// Movements carried by a `dispense_completed` message. New versions send `stockMoves`;
  /// older ones only `deductedBatches` (converted with ids derived from the token).
  static List<StockMovement> movesOfDispense(Map data, Map fullMessage) {
    final moves = _movesFrom(data['stockMoves'] ?? fullMessage['stockMoves']);
    if (moves.isNotEmpty) return moves;
    final batches = data['deductedBatches'];
    if (batches is! List || batches.isEmpty) return const [];
    final serial = (data['serial'] ?? fullMessage['serial'] ?? '').toString().trim();
    if (serial.isEmpty) return const [];
    final uid = (data['entryUid'] ?? fullMessage['entryUid'] ?? '').toString();
    final out = <StockMovement>[];
    for (var i = 0; i < batches.length; i++) {
      final b = batches[i];
      if (b is! Map) continue;
      final id = (b['medicineId'] ?? b['inventoryId'] ?? b['id'] ?? '').toString().trim();
      final d = b['delta'];
      final delta = d is num ? d.toDouble() : double.tryParse(d?.toString() ?? '') ?? 0;
      if (id.isEmpty || delta == 0) continue;
      final pool = StockPool.ofLegacyRecord({
        'id': id,
        'branchId': data['branchId'] ?? fullMessage['branchId'],
        'campId': b['campId'] ?? data['campId'] ?? data['dispensaryId'],
        'dispensaryTag': data['dispensaryTag'],
      });
      if (pool == null) continue;
      out.add(StockMovement(
        opId: StockMovement.deterministicId('ldisp', [pool.key, serial, uid, id]),
        pool: pool.key,
        medicineId: id,
        delta: delta,
        kind: StockMoveKind.dispense,
        at: DateTime.tryParse((data['dispensedAt'] ?? '').toString()) ?? DateTime.now(),
        by: (data['dispensedBy'] ?? '').toString(),
        ref: serial,
        name: (b['name'] ?? '').toString(),
      ));
    }
    return out;
  }

  /// An old-version `save_stock_item` / `add_stock` LAN message: a restock delta becomes a
  /// movement (id from its operation id, so a resend counts once); a full item only updates
  /// details — its quantity is never taken as a figure.
  static Future<void> handleLegacyStockItem(Map<String, dynamic> data, Map<String, dynamic> fullMessage) async {
    final item = data['data'] is Map ? Map<String, dynamic>.from(data['data'] as Map) : Map<String, dynamic>.from(data);
    final id = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? '').toString().trim();
    if (id.isEmpty) return;
    final pool = StockPool.ofLegacyRecord({...item, 'branchId': item['branchId'] ?? fullMessage['branchId']});
    if (pool == null || _wipingPools.contains(pool.key)) return;
    final isReplay = fullMessage['isCatchUp'] == true || fullMessage['_isReplay'] == true || fullMessage['_serverPush'] == true;
    // Never let a legacy replay resurrect items in a pool that has been master-wiped.
    if (isReplay && StockLedger.poolWipeId(pool.key) != null) return;
    final rawDelta = data['_quantityDelta'] ?? item['_quantityDelta'];
    final details = Map<String, dynamic>.from(item)..remove('_quantityDelta');
    final local = StockLedger.item(pool.key, id);
    // A catch-up copy of a batch removed here (or a copy that says it is deleted) must not
    // bring it back: saveDetails clears the deleted mark.
    if (isReplay && (local?['deleted'] == true || item['deleted'] == true || item['status'] == 'deleted')) {
      return;
    }
    if (local == null || details.containsKey('name')) {
      await StockLedger.saveDetails(pool.key, id, details);
    }
    if (rawDelta == null || isReplay) return;
    final delta = rawDelta is num ? rawDelta.toDouble() : double.tryParse(rawDelta.toString()) ?? 0;
    final op = (data['_opId'] ?? item['_opId'] ?? fullMessage['_messageId'] ?? '').toString();
    if (delta == 0 || op.isEmpty) return;
    final applied = await StockLedger.applyRemote([
      StockMovement(
        opId: StockMovement.deterministicId('lrst', [pool.key, id, op]),
        pool: pool.key,
        medicineId: id,
        delta: delta,
        kind: delta > 0 ? StockMoveKind.restock : StockMoveKind.adjust,
        at: DateTime.now(),
        ref: 'older app version',
        name: (item['name'] ?? '').toString(),
      ),
    ]);
    if (isServer && applied.isNotEmpty) _scheduleUpload(uploadDelayServer);
  }

  static List<StockMovement> _movesFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map(StockMovement.fromMap).whereType<StockMovement>().toList();
  }

  // ── Details / delete (no quantity) ──────────────────────────────────────────

  /// Saves medicine details for a batch on this PC, the LAN and the cloud. Never changes
  /// the quantity.
  static Future<void> saveDetails(StockPool pool, String medicineId, Map<String, dynamic> details) async {
    await StockLedger.saveDetails(pool.key, medicineId, details);
    final clean = Map<String, dynamic>.from(details)
      ..removeWhere((k, v) => v is Timestamp || v is FieldValue);
    try {
      RealtimeManager().sendMessage({
        'event_type': evDetails,
        'branchId': pool.branch,
        'data': {
          'pool': pool.key,
          'medicineId': medicineId,
          'details': clean,
          'wipeId': StockLedger.poolWipeId(pool.key) ?? '',
        },
      });
    } catch (_) {}
    if (uploadsToCloud) unawaited(StockCloud.saveDetails(pool, medicineId, clean));
  }

  static Future<void> deleteBatch(StockPool pool, String medicineId) async {
    await StockLedger.markDeleted(pool.key, medicineId);
    try {
      RealtimeManager().sendMessage({
        'event_type': evDetails,
        'branchId': pool.branch,
        'data': {
          'pool': pool.key,
          'medicineId': medicineId,
          'deleted': true,
          'wipeId': StockLedger.poolWipeId(pool.key) ?? '',
        },
      });
    } catch (_) {}
    if (uploadsToCloud) unawaited(StockCloud.markDeleted(pool, medicineId));
  }

  // ── Cloud following (uploader PCs) ───────────────────────────────────────────

  static void _followCloud(String branchId) {
    if (!uploadsToCloud) return;
    for (final pool in StockPool.allFor(branchId)) {
      if (_wipingPools.contains(pool.key)) continue;
      if (!_listeners.containsKey(pool.key)) {
        try {
          final last = LocalStorageService.getLastSyncedServerTimestamp('stock_v2_${pool.key.replaceAll('/', '_')}');
          final since = last == null ? null : DateTime.tryParse(last);
          Query<Map<String, dynamic>> q = FirebaseFirestore.instance
              .collection('branches')
              .doc(pool.cloudBranch)
              .collection(pool.collection);
          if (since != null) q = q.where('updatedAt', isGreaterThan: Timestamp.fromDate(since));
          _listeners[pool.key] = q.snapshots().listen((snap) async {
            // Never let stale local Firestore SDK cache resurrect REST-deleted docs.
            if (snap.metadata.isFromCache || _wipingPools.contains(pool.key)) return;
            for (final ch in snap.docChanges) {
              if (ch.type == DocumentChangeType.removed) {
                final removed = await StockLedger.removeItemLocally(pool.key, ch.doc.id);
                if (removed && isServer && serverBroadcast != null) {
                  serverBroadcast!({
                    'event_type': evDetails,
                    '_messageId': 'hard_del_${pool.key}_${ch.doc.id}_${DateTime.now().microsecondsSinceEpoch}',
                    '_serverPush': true,
                    'branchId': pool.branch,
                    'data': {
                      'pool': pool.key,
                      'medicineId': ch.doc.id,
                      'deleted': true,
                      'hardDelete': true,
                      'wipeId': StockLedger.poolWipeId(pool.key) ?? '',
                    },
                  });
                }
                continue;
              }
              final d = ch.doc.data();
              if (d == null) continue;
              await StockCloud.applyCloudDoc(pool, ch.doc.id, d);
            }
          }, onError: (Object e) {
            debugPrint('[StockSync] cloud listener ${pool.key} stopped: $e');
            _listeners.remove(pool.key);
          });
        } catch (e) {
          debugPrint('[StockSync] cannot follow ${pool.key}: $e');
        }
      }

      // Also watch the pool's cloud wipe marker (1 tiny doc; notifies Web & standalone desks
      // immediately whenever the server executes a master wipe).
      if (!_wipeListeners.containsKey(pool.key)) {
        try {
          _wipeListeners[pool.key] = StockCloud.wipeMetaRef(pool).snapshots().listen((snap) async {
            if (snap.metadata.isFromCache || !snap.exists || _wipingPools.contains(pool.key)) return;
            final wid = (snap.data()?['wipeId'] ?? '').toString().trim();
            if (wid.isEmpty || StockLedger.poolWipeId(pool.key) == wid) return;
            await StockLedger.purgePool(pool.key, wipeId: wid);
            await StockLedger.purgeStockQueues(pool);
            clearPendingBaseBroadcasts(pool.key);
            await LocalStorageService.setLastSyncedServerTimestamp(
                'stock_v2_${pool.key.replaceAll('/', '_')}', DateTime.now().toUtc().toIso8601String());
            debugPrint('[StockSync] Applied live cloud wipe marker $wid for ${pool.key}');
          }, onError: (Object e) {
            debugPrint('[StockSync] wipe listener ${pool.key} stopped: $e');
            _wipeListeners.remove(pool.key);
          });
        } catch (e) {
          debugPrint('[StockSync] cannot follow wipe marker for ${pool.key}: $e');
        }
      }
    }
  }

  /// Reads a pool from the cloud now (screens' "refresh"). Desks on the LAN ask the server.
  static Future<void> refresh(String branchId, {bool full = false}) async {
    if (isLanClient) {
      requestSnapshot(branchId);
      return;
    }
    for (final pool in StockPool.allFor(branchId)) {
      await StockCloud.download(pool, full: full);
    }
  }

  // ── Server → desks: new confirmed figures ────────────────────────────────────

  static void _onLedgerChanged(Set<String> keys) {
    if (!isServer || serverBroadcast == null) return;
    _baseChanged.addAll(keys);
    if (_baseFlush?.isActive == true) return;
    _baseFlush = Timer(const Duration(seconds: 3), _flushBases);
  }

  static void _flushBases() {
    final keys = Set<String>.from(_baseChanged);
    _baseChanged.clear();
    if (keys.isEmpty || serverBroadcast == null) return;
    final items = <Map<String, dynamic>>[];
    for (final k in keys) {
      final i = k.indexOf('|');
      if (i < 0) continue;
      final poolKey = k.substring(0, i).toLowerCase();
      if (_wipingPools.contains(poolKey)) continue;
      final it = StockLedger.item(poolKey, k.substring(i + 1));
      if (it != null) items.add(it);
    }
    if (items.isEmpty) return;
    final byBranch = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      byBranch.putIfAbsent((it['branchId'] ?? '').toString(), () => []).add(it);
    }
    for (final e in byBranch.entries) {
      final wipeEpochs = <String, String>{};
      for (final it in e.value) {
        final p = (it['pool'] ?? '').toString();
        final wid = p.isEmpty ? null : StockLedger.poolWipeId(p);
        if (wid != null) wipeEpochs[p] = wid;
      }
      for (var i = 0; i < e.value.length; i += 100) {
        serverBroadcast!({
          'event_type': evSnapshot,
          'branchId': e.key,
          '_serverPush': true,
          'data': {
            'items': e.value.sublist(i, i + 100 > e.value.length ? e.value.length : i + 100),
            'moves': const [],
            if (wipeEpochs.isNotEmpty) 'wipeEpochs': wipeEpochs,
          },
        });
      }
    }
  }

  /// Full catch-up for one desk (server side), sent in chunks.
  static int pushSnapshotTo(String socketId, String branchId, {String? targetClientId, Set<String>? pools}) {
    final send = serverSendTo;
    if (send == null) return 0;
    final b = StockPool.normalizeBranch(branchId);
    final poolKeys = pools ?? StockPool.allFor(b).map((p) => p.key).toSet();
    final snap = StockLedger.snapshot(pools: poolKeys);
    final items = (snap['items'] as List).cast<Map<String, dynamic>>();
    final moves = (snap['moves'] as List);
    final wipeEpochs = snap['wipeEpochs'] is Map ? Map<String, dynamic>.from(snap['wipeEpochs'] as Map) : const <String, dynamic>{};
    var sent = 0;
    // Movements first, then the figures.
    for (var i = 0; i < moves.length || i == 0; i += 200) {
      if (moves.isEmpty) break;
      if (send(socketId, {
        'event_type': evSnapshot,
        'branchId': b,
        '_serverPush': true,
        if (targetClientId != null) '_targetClientId': targetClientId,
        'data': {
          'items': const [],
          'moves': moves.sublist(i, i + 200 > moves.length ? moves.length : i + 200),
          if (wipeEpochs.isNotEmpty) 'wipeEpochs': wipeEpochs,
        },
      })) {
        sent++;
      }
    }
    for (var i = 0; i < items.length; i += 100) {
      if (send(socketId, {
        'event_type': evSnapshot,
        'branchId': b,
        '_serverPush': true,
        if (targetClientId != null) '_targetClientId': targetClientId,
        'data': {
          'items': items.sublist(i, i + 100 > items.length ? items.length : i + 100),
          'moves': const [],
          if (wipeEpochs.isNotEmpty) 'wipeEpochs': wipeEpochs,
        },
      })) {
        sent++;
      }
    }
    // Even if a wiped pool now has 0 items and 0 moves, still deliver its wipeEpochs so the
    // desk clears any stale records it held from before the wipe.
    if (moves.isEmpty && items.isEmpty && wipeEpochs.isNotEmpty) {
      if (send(socketId, {
        'event_type': evSnapshot,
        'branchId': b,
        '_serverPush': true,
        if (targetClientId != null) '_targetClientId': targetClientId,
        'data': {'items': const [], 'moves': const [], 'wipeEpochs': wipeEpochs},
      })) {
        sent++;
      }
    }
    return sent;
  }

  // ── Desk: (re)connect and checksums ──────────────────────────────────────────

  /// Called by a desk when its LAN link comes up: sends its movements the server may not
  /// have and asks for a snapshot through the checksum exchange.
  static void onLinkUp(String branchId) {
    if (!isLanClient) return;
    final mine = StockLedger.unconfirmed(branch: StockPool.normalizeBranch(branchId));
    if (mine.isNotEmpty) sendMoves(mine);
    sendChecksums(branchId, reason: 'connect');
  }

  static void requestSnapshot(String branchId) => sendChecksums(branchId, reason: 'refresh', forceAll: true);

  static void sendChecksums(String branchId, {String reason = 'weekly', bool forceAll = false}) {
    final pools = StockPool.allFor(branchId);
    if (pools.isEmpty) return;
    final sums = <String, dynamic>{};
    final details = <String, dynamic>{};
    final wipeEpochs = <String, String>{};
    for (final p in pools) {
      sums[p.key] = forceAll ? 'force' : StockLedger.checksum(p.key);
      wipeEpochs[p.key] = StockLedger.poolWipeId(p.key) ?? '';
      // Per-medicine figures let the server say exactly what differed.
      details[p.key] = {
        for (final it in StockLedger.items(pool: p.key))
          (it['medicineId'] ?? it['id']).toString(): (it['quantityRaw'] ?? it['quantity'] ?? 0),
      };
    }
    try {
      RealtimeManager().sendMessage({
        'event_type': evChecksum,
        'branchId': StockPool.normalizeBranch(branchId),
        'data': {
          'pools': sums,
          'figures': details,
          'wipeEpochs': wipeEpochs,
          'reason': reason,
          'clientId': RealtimeManager().clientId,
          'device': RealtimeManager().username ?? '',
        },
      });
    } catch (_) {}
  }

  static Future<void> _answerChecksum(Map<String, dynamic> message, Map<String, dynamic> data) async {
    final socketId = (message['_socketId'] ?? '').toString();
    final branch = (message['branchId'] ?? data['branchId'] ?? '').toString();
    final pools = data['pools'] is Map ? Map<String, dynamic>.from(data['pools'] as Map) : const <String, dynamic>{};
    final figures = data['figures'] is Map ? Map<String, dynamic>.from(data['figures'] as Map) : const <String, dynamic>{};
    final deskWipes = data['wipeEpochs'] is Map ? Map<String, dynamic>.from(data['wipeEpochs'] as Map) : const <String, dynamic>{};
    final differing = <String>{};
    final needsWipe = <String, String>{};
    for (final e in pools.entries) {
      final serverWipe = StockLedger.poolWipeId(e.key);
      final deskWipe = (deskWipes[e.key] ?? '').toString().trim();
      final deskFigs = figures[e.key] is Map ? (figures[e.key] as Map) : const {};
      final serverItemsEmpty = StockLedger.items(pool: e.key).isEmpty;
      if (serverWipe != null && deskWipe != serverWipe) {
        needsWipe[e.key] = serverWipe;
        differing.add(e.key);
      } else if (serverItemsEmpty && deskFigs.isNotEmpty) {
        needsWipe[e.key] = serverWipe ?? '';
        differing.add(e.key);
      } else if (e.value == 'force' || e.value != StockLedger.checksum(e.key)) {
        differing.add(e.key);
      }
    }
    final reason = (data['reason'] ?? '').toString();
    final device = (data['device'] ?? message['_senderUsername'] ?? data['clientId'] ?? '').toString();
    // A weekly or manual check that found nothing is reported too ("all matched").
    if ((reason == 'weekly' || reason == 'manual') && differing.isEmpty) {
      for (final pool in pools.keys) {
        await StockDriftLog.recordAllMatched(pool: pool, device: device, reason: reason);
      }
    }
    if (differing.isEmpty) return;
    // Record what differed (shown in the weekly report) before sending the fix.
    if (reason != 'refresh' && reason != 'wipe_sync') {
      for (final pool in differing) {
        final theirs = figures[pool] is Map ? Map<String, dynamic>.from(figures[pool] as Map) : const <String, dynamic>{};
        await StockDriftLog.recordDeskDiff(pool: pool, device: device, deskFigures: theirs, reason: reason);
      }
    }
    if (socketId.isNotEmpty) {
      final targetCid = data['clientId']?.toString();
      if (needsWipe.isNotEmpty && serverSendTo != null) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final entry in needsWipe.entries) {
          final p = StockPool.fromKey(entry.key);
          if (p != null) {
            serverSendTo!(socketId, buildWipePayload(p, entry.value, nowMs, targetClientId: targetCid));
          }
        }
      }
      // For differing pools that were NOT full-wiped, explicitly hard-delete any medicine ID
      // the desk still holds that no longer exists on the server (e.g. removed by HQ Manager).
      if (serverSendTo != null) {
        final extraDeletes = <Map<String, dynamic>>[];
        for (final poolKey in differing) {
          if (needsWipe.containsKey(poolKey)) continue;
          final deskFigs = figures[poolKey] is Map ? (figures[poolKey] as Map) : const {};
          if (deskFigs.isEmpty) continue;
          final serverIds = {
            for (final it in StockLedger.items(pool: poolKey))
              (it['medicineId'] ?? it['id'] ?? '').toString(),
          };
          for (final rawId in deskFigs.keys) {
            final id = rawId.toString().trim();
            if (id.isNotEmpty && !serverIds.contains(id)) {
              extraDeletes.add({'pool': poolKey, 'medicineId': id, 'deleted': true, 'hardDelete': true});
            }
          }
        }
        if (extraDeletes.isNotEmpty) {
          serverSendTo!(socketId, {
            'event_type': evSnapshot,
            'branchId': StockPool.normalizeBranch(branch),
            '_serverPush': true,
            if (targetCid != null && targetCid.isNotEmpty) '_targetClientId': targetCid,
            'data': {'items': extraDeletes, 'moves': const []},
          });
        }
      }
      pushSnapshotTo(socketId, branch, targetClientId: targetCid, pools: differing);
    }
  }

  // ── Weekly check ─────────────────────────────────────────────────────────────

  static const String _weeklyFlag = 'stock_weekly_check_at';

  /// When this PC last ran (or asked for) the stock check.
  static DateTime? get lastCheckAt {
    try {
      if (!Hive.isBoxOpen('app_flags')) return null;
      return DateTime.tryParse((Hive.box('app_flags').get(_weeklyFlag) ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  /// "Check now" from the report screen. A desk asks the LAN server (which compares, fixes
  /// the desk and sends back the report entry); the server / a standalone PC compares with
  /// the cloud itself.
  static Future<void> runCheckNow() async {
    final branch = LocalStorageService.getActiveUserBranchId();
    if (branch.isEmpty) return;
    if (isLanClient) {
      sendChecksums(branch, reason: 'manual');
      try {
        final flags = await LocalStorageService.ensureBoxOpen('app_flags');
        await flags.put(_weeklyFlag, DateTime.now().toIso8601String());
      } catch (_) {}
      return;
    }
    await weeklyCheckIfDue(force: true);
  }

  /// Runs the weekly check when a week has passed since the last one.
  /// Desk: sends checksums (the server fixes and logs any difference).
  /// Server / standalone: compares its figures with the cloud and logs differences.
  static Future<void> weeklyCheckIfDue({bool force = false}) async {
    try {
      final flags = await LocalStorageService.ensureBoxOpen('app_flags');
      final last = DateTime.tryParse((flags.get(_weeklyFlag) ?? '').toString());
      if (!force && last != null && DateTime.now().difference(last) < const Duration(days: 7)) return;
      final branch = LocalStorageService.getActiveUserBranchId();
      if (branch.isEmpty) return;
      if (isLanClient) {
        sendChecksums(branch, reason: 'weekly');
      } else {
        await uploadNow(); // queued movements first, so they are not reported as drift
        for (final pool in StockPool.allFor(branch)) {
          final diff = await StockCloud.driftReport(pool);
          await StockDriftLog.recordCloudDiff(pool: pool.key, diff: diff);
        }
      }
      await flags.put(_weeklyFlag, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('[StockSync] weekly check failed: $e');
    }
  }
}

/// The weekly report: what differed, where, and by how much.
/// Stored on the PC that found it (box `stock_drift_log`), newest first, last 200 entries.
class StockDriftLog {
  StockDriftLog._();

  static const String boxName = 'stock_drift_log';

  static Future<Box> _box() async => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : Hive.openBox(boxName);

  /// A desk's figures differed from the server's. Each differing medicine is listed with
  /// both figures and the difference; the desk is corrected right after.
  static Future<void> recordDeskDiff({
    required String pool,
    required String device,
    required Map<String, dynamic> deskFigures,
    required String reason,
  }) async {
    final rows = <Map<String, dynamic>>[];
    final serverItems = {for (final it in StockLedger.items(pool: pool)) (it['medicineId'] ?? it['id']).toString(): it};
    final ids = {...serverItems.keys, ...deskFigures.keys};
    for (final id in ids) {
      final s = serverItems[id];
      final sv = (s?['quantityRaw'] ?? s?['quantity'] ?? 0) as num;
      final dvRaw = deskFigures[id];
      final dv = dvRaw is num ? dvRaw : num.tryParse(dvRaw?.toString() ?? '') ?? 0;
      if ((sv - dv).abs() < 1e-6) continue;
      rows.add({
        'medicineId': id,
        'name': s?['name'] ?? '',
        'server': sv,
        'device': dv,
        'difference': dv - sv,
      });
    }
    if (rows.isEmpty) return;
    await _add({
      'kind': 'desk',
      'pool': pool,
      'device': device,
      'reason': reason,
      'rows': rows,
      'action': 'Desk corrected to the server figures',
    });
  }

  /// The server's confirmed figures differed from the cloud at the same revision (should
  /// never happen; nothing is changed automatically — an admin decides).
  /// Negative figures are listed too: they need a physical count.
  static Future<void> recordCloudDiff({required String pool, required Map<String, (double, double)> diff}) async {
    final rows = <Map<String, dynamic>>[
      for (final e in diff.entries)
        {
          'medicineId': e.key,
          'name': StockLedger.item(pool, e.key)?['name'] ?? '',
          'server': e.value.$1,
          'cloud': e.value.$2,
          'difference': e.value.$1 - e.value.$2,
        },
    ];
    final negatives = <Map<String, dynamic>>[
      for (final it in StockLedger.items(pool: pool))
        if (((it['quantityRaw'] ?? 0) as num) < 0)
          {'medicineId': it['medicineId'], 'name': it['name'] ?? '', 'figure': it['quantityRaw']},
    ];
    await _add({
      'kind': 'cloud',
      'pool': pool,
      'rows': rows,
      'negatives': negatives,
      'action': rows.isEmpty && negatives.isEmpty
          ? 'No differences'
          : 'Needs review (not changed automatically)${negatives.isEmpty ? '' : '; negative figures need a stock count'}',
    });
  }

  /// A check that found every figure equal.
  static Future<void> recordAllMatched({required String pool, required String device, required String reason}) =>
      _add({
        'kind': 'desk',
        'pool': pool,
        'device': device,
        'reason': reason,
        'rows': const <Map<String, dynamic>>[],
        'action': 'All figures matched',
      });

  /// A report entry made on the LAN server, received by a desk (stored, not re-sent).
  static Future<void> storeFromServer(Map entry) async {
    final key = (entry['key'] ?? '').toString();
    if (key.isEmpty) return;
    try {
      final box = await _box();
      await box.put(key, Map<String, dynamic>.from(entry));
    } catch (_) {}
  }

  static Future<void> _add(Map<String, dynamic> entry) async {
    try {
      final box = await _box();
      final key = 'drift_${DateTime.now().microsecondsSinceEpoch}';
      final stored = {...entry, 'key': key, 'at': DateTime.now().toIso8601String()};
      await box.put(key, stored);
      // Every desk keeps a copy, so the report shows the same on every PC.
      if (StockSync.isServer) {
        StockSync.serverBroadcast?.call({
          'event_type': StockSync.evDriftReport,
          'branchId': (entry['pool'] ?? '').toString().split('/').first,
          '_serverPush': true,
          'data': stored,
        });
      }
      if (box.length > 200) {
        final keys = box.keys.toList()..sort((a, b) => a.toString().compareTo(b.toString()));
        await box.deleteAll(keys.take(box.length - 200));
      }
      await LocalStorageService.saveLocalInventoryLog({
        'action': 'stock_check',
        'pool': entry['pool'],
        'details': entry,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[StockDriftLog] save failed: $e');
    }
  }

  /// Report entries, newest first.
  static List<Map<String, dynamic>> entries() {
    if (!Hive.isBoxOpen(boxName)) return const [];
    final box = Hive.box(boxName);
    final list = box.values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    list.sort((a, b) => (b['at'] ?? '').toString().compareTo((a['at'] ?? '').toString()));
    return list;
  }
}
