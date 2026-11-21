// lib/services/stock/stock_ledger.dart
//
// The stock book on every PC (desks and LAN server alike).
//
// For each medicine batch in a pool it keeps:
//   base     – the last figure confirmed by the cloud (or by the LAN server, which got it
//              from the cloud),
//   rev      – the cloud revision of that figure (each cloud change adds 1),
//   baseOps  – ids of the movements already inside `base`.
// and, in a separate box, every movement this PC has seen.
//
//   quantity = base + Σ delta of the movements NOT inside base
//
// Because a movement is stored once by its opId, and the base says exactly which movements
// it already contains, the same change can never count twice and no change is lost — no
// matter whether it arrived over the LAN, from the cloud, from a replay or a catch-up, or in
// which order. Nothing ever overwrites a quantity with a total from another PC.
//
// Stored records (box LocalStorageService.stockBox, key "<pool>|<medicineId>"):
//   all medicine details (name, type, dose, expiryDate, code, …) plus
//   pool, branchId, campId, dispensaryId, id, medicineId,
//   base, rev, baseOps, quantityRaw (may be < 0) and quantity (never < 0, for display).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../local_storage_service.dart';
import 'stock_movement.dart';
import 'stock_pool.dart';

class StockLedger {
  StockLedger._();

  static const String movesBoxName = 'stock_moves_v1';

  /// Movements are kept this long, then forgotten (by then they are long inside the base).
  static const Duration keepMoves = Duration(days: 21);

  /// How many movement ids a cloud stock document remembers (see StockCloud).
  static const int baseOpsCap = 600;

  /// Called with movements recorded on THIS PC, so the sync layer can send them to the LAN
  /// server or queue them for the cloud. Set by StockSync; null in tests.
  static void Function(List<StockMovement> moves)? onLocalMoves;

  /// Called after any change, with the item keys that changed (LAN server rebroadcast etc.).
  static final StreamController<Set<String>> _changes = StreamController<Set<String>>.broadcast();
  static Stream<Set<String>> get changes => _changes.stream;

  // itemKey → opIds of movements for that item (built lazily from the moves box).
  static Map<String, Set<String>>? _index;

  static String itemKey(String pool, String medicineId) => '${pool.toLowerCase()}|${medicineId.trim()}';

  static bool isLedgerKey(dynamic key) => key is String && key.contains('|') && !key.startsWith('stock:');

  static Future<void> ensureOpen() async {
    if (!Hive.isBoxOpen(LocalStorageService.stockBox)) await Hive.openBox(LocalStorageService.stockBox);
    if (!Hive.isBoxOpen(movesBoxName)) await Hive.openBox(movesBoxName);
  }

  static bool get isOpen => Hive.isBoxOpen(LocalStorageService.stockBox) && Hive.isBoxOpen(movesBoxName);

  static Box get _items => Hive.box(LocalStorageService.stockBox);
  static Box get _moves => Hive.box(movesBoxName);

  /// Drops the in-memory index (tests, or after the boxes were reopened).
  static void resetCache() {
    _index = null;
    _dispCacheLen = -1;
  }

  // ── Wipe epoch & hard purge ──────────────────────────────────────────────────

  static String wipeFlagKey(String pool) => 'stock_wipe_epoch|${pool.trim().toLowerCase()}';

  /// Current wipe generation id for [pool], or null if this pool has never been wiped.
  static String? poolWipeId(String pool) {
    try {
      if (!Hive.isBoxOpen('app_flags')) return null;
      final v = Hive.box('app_flags').get(wipeFlagKey(pool));
      final s = v?.toString().trim() ?? '';
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Persists the wipe generation id for [pool] in `app_flags`.
  static Future<void> setPoolWipeId(String pool, String wipeId) async {
    final id = wipeId.trim();
    if (id.isEmpty) return;
    try {
      final flags = await LocalStorageService.ensureBoxOpen('app_flags');
      await flags.put(wipeFlagKey(pool), id);
    } catch (e) {
      debugPrint('[StockLedger] setPoolWipeId failed: $e');
    }
  }

  /// Hard-deletes EVERY local record, legacy key, movement, and quarantine entry for [poolKey]
  /// from Hive (nothing left behind as `deleted: true`). If [wipeId] is provided, records the
  /// new wipe epoch so pre-wipe messages from stale desks are rejected automatically.
  static Future<({int itemsRemoved, int movesRemoved})> purgePool(
    String poolKey, {
    String? wipeId,
  }) async {
    await ensureOpen();
    final p = poolKey.trim().toLowerCase();
    final parsedPool = StockPool.fromKey(p);

    // 1. Delete EVERY matching key from local_stock_items (ledger keys, pool-tagged maps,
    //    and legacy non-ledger keys belonging to this pool).
    final itemKeysToDelete = <dynamic>[];
    final prefix = '$p|';
    for (final k in _items.keys.toList()) {
      final kStr = k is String ? k.trim().toLowerCase() : '';
      if (kStr.startsWith(prefix)) {
        itemKeysToDelete.add(k);
        continue;
      }
      final v = _items.get(k);
      if (v is! Map) continue;
      final vPool = (v['pool'] ?? '').toString().trim().toLowerCase();
      if (vPool == p) {
        itemKeysToDelete.add(k);
        continue;
      }
      if (!isLedgerKey(k) && parsedPool != null) {
        final legacyPool = StockPool.ofLegacyRecord(v, branchFallback: parsedPool.branch);
        if (legacyPool != null && legacyPool.key == p) {
          itemKeysToDelete.add(k);
        }
      }
    }
    if (itemKeysToDelete.isNotEmpty) {
      await _items.deleteAll(itemKeysToDelete);
    }

    // 2. Delete EVERY movement for this pool from stock_moves_v1.
    final moveKeysToDelete = <dynamic>[];
    for (final k in _moves.keys.toList()) {
      final v = _moves.get(k);
      if (v is Map && (v['pool'] ?? '').toString().trim().toLowerCase() == p) {
        moveKeysToDelete.add(k);
      }
    }
    if (moveKeysToDelete.isNotEmpty) {
      await _moves.deleteAll(moveKeysToDelete);
    }

    // 3. Remove matching entries from stock_quarantine if open.
    try {
      if (Hive.isBoxOpen('stock_quarantine')) {
        final qBox = Hive.box('stock_quarantine');
        final qDrop = <dynamic>[];
        for (final k in qBox.keys.toList()) {
          final v = qBox.get(k);
          if (v is! Map) continue;
          final qp = parsedPool == null
              ? null
              : StockPool.ofLegacyRecord(v, branchFallback: parsedPool.branch);
          if (qp != null && qp.key == p) qDrop.add(k);
        }
        if (qDrop.isNotEmpty) await qBox.deleteAll(qDrop);
      }
    } catch (_) {}

    resetCache();
    if (wipeId != null && wipeId.trim().isNotEmpty) {
      await setPoolWipeId(p, wipeId.trim());
    }
    try {
      await LocalStorageService.setLastSyncedServerTimestamp('stock_v2_${p.replaceAll('/', '_')}', '');
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('app_flags')) {
        final flags = Hive.box('app_flags');
        final flagKeys = flags.keys.where((k) => k.toString().startsWith('stock_disp|$p|')).toList();
        if (flagKeys.isNotEmpty) await flags.deleteAll(flagKeys);
      }
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('stock_drift_log')) {
        final drift = Hive.box('stock_drift_log');
        final driftKeys = <dynamic>[];
        for (final k in drift.keys) {
          final v = drift.get(k);
          if ((v is Map && v['pool']?.toString() == p) || k.toString().startsWith('$p|')) {
            driftKeys.add(k);
          }
        }
        if (driftKeys.isNotEmpty) await drift.deleteAll(driftKeys);
      }
    } catch (_) {}

    return (itemsRemoved: itemKeysToDelete.length, movesRemoved: moveKeysToDelete.length);
  }

  /// Removes a single local batch record (e.g. when Firestore reports `DocumentChangeType.removed`),
  /// skipping only if this PC still holds an unuploaded positive restock for that batch.
  static Future<bool> removeItemLocally(String poolKey, String medicineId) async {
    if (!isOpen) return false;
    final key = itemKey(poolKey, medicineId);
    if (!_items.containsKey(key)) return false;
    final ids = _idx()[key];
    if (ids != null) {
      for (final id in ids) {
        final m = StockMovement.fromMap(_moves.get(id));
        if (m != null && !m.inCloud && m.delta > 0) return false;
      }
    }
    await _items.delete(key);
    return true;
  }

  /// Permanently deletes a single batch record and all its local ledger movements from Hive
  /// (used for Higher Authority permanent deletions and unbarcoded medicine cleanup).
  static Future<bool> hardDeleteItem(String poolKey, String medicineId) async {
    await ensureOpen();
    final p = poolKey.trim().toLowerCase();
    final id = medicineId.trim();
    if (p.isEmpty || id.isEmpty) return false;
    final key = itemKey(p, id);
    var removed = false;

    if (_items.containsKey(key)) {
      await _items.delete(key);
      removed = true;
    }
    // Also clean any matching legacy key for this exact pool/id if present.
    for (final alt in ['stock:$id', id]) {
      final v = _items.get(alt);
      if (v is Map) {
        final parsed = StockPool.fromKey(p);
        final lp = parsed == null ? null : StockPool.ofLegacyRecord(v, branchFallback: parsed.branch);
        if (lp != null && lp.key == p) {
          await _items.delete(alt);
          removed = true;
        }
      }
    }

    final moveIds = _idx().remove(key);
    if (moveIds != null && moveIds.isNotEmpty) {
      await _moves.deleteAll(moveIds.toList());
    } else {
      final drop = <dynamic>[];
      for (final k in _moves.keys.toList()) {
        final v = _moves.get(k);
        if (v is Map &&
            (v['pool'] ?? '').toString().trim().toLowerCase() == p &&
            (v['medicineId'] ?? '').toString().trim() == id) {
          drop.add(k);
        }
      }
      if (drop.isNotEmpty) await _moves.deleteAll(drop);
    }
    return removed;
  }

  /// Purges all pending stock/inventory entries for [pool] from cloud sync queues and LAN
  /// outboxes so old queued mutations cannot resurrect wiped medicines locally or in Firestore.
  static Future<int> purgeStockQueues(StockPool pool) async {
    const inventoryTypes = {
      'update_inventory',
      'add_inventory_stock',
      'delete_inventory',
      'delete_inventory_item',
      'stock_moves',
      'stock_snapshot',
      'stock_details',
      'inventory_stock_sync',
      'save_stock_item',
      'delete_stock_item',
      'medicine_registered',
      'register_medicine',
      'add_stock',
      'add_proforma_stock',
    };
    final targetColPrefix = 'branches/${pool.cloudBranch}/${pool.collection}/'.toLowerCase();
    var purged = 0;

    const queueBoxes = [
      LocalStorageService.syncBox,
      'server_sync_queue',
      'realtime_outbox',
      'realtime_failed_outbox',
    ];

    for (final boxName in queueBoxes) {
      try {
        if (!Hive.isBoxOpen(boxName)) continue;
        final box = Hive.box(boxName);
        final toDelete = <dynamic>[];
        for (final k in box.keys.toList()) {
          final v = box.get(k);
          if (v is! Map) continue;
          final type = (v['type'] ?? v['action'] ?? v['event_type'] ?? '').toString().trim().toLowerCase();
          final data = v['data'] is Map ? v['data'] as Map : const {};

          // Check relayed direct cloud writes targeting this pool's Firestore collection.
          if (type == 'relay_cloud_write') {
            final path = (data['path'] ?? v['path'] ?? '').toString().trim().toLowerCase();
            if (path.startsWith(targetColPrefix)) toDelete.add(k);
            continue;
          }
          if (!inventoryTypes.contains(type)) continue;

          // 1. Explicit pool key on envelope or data
          final explicitPool = (v['pool'] ?? data['pool'] ?? '').toString().trim().toLowerCase();
          if (explicitPool.isNotEmpty) {
            if (explicitPool == pool.key) toDelete.add(k);
            continue;
          }

          // 2. stock_moves payload with per-move pool keys
          if (type == 'stock_moves' && data['moves'] is List) {
            final moves = (data['moves'] as List).whereType<Map>().toList();
            if (moves.isNotEmpty &&
                moves.every((m) => (m['pool'] ?? '').toString().trim().toLowerCase() == pool.key)) {
              toDelete.add(k);
            }
            continue;
          }

          // 3. Legacy/sync_queue item: check branch & camp carefully so other camps stay untouched.
          final rawBranch = (v['branchId'] ?? v['branch'] ?? data['branchId'] ?? data['branch'] ?? '').toString();
          final normBranch = StockPool.normalizeBranch(rawBranch);
          if (normBranch.isNotEmpty && normBranch != pool.branch && normBranch != pool.cloudBranch) {
            continue;
          }
          if (!pool.hasCamp) {
            if (normBranch == pool.branch || normBranch == pool.cloudBranch) toDelete.add(k);
            continue;
          }
          final medId = (v['medicineId'] ?? v['inventoryId'] ?? v['id'] ?? data['medicineId'] ?? data['id'] ?? '').toString();
          final resolved = StockPool.ofLegacyRecord({
            'id': medId,
            'branchId': normBranch.isEmpty ? pool.branch : normBranch,
            'campId': v['campId'] ?? data['campId'] ?? v['dispensaryId'] ?? data['dispensaryId'],
            'dispensaryTag': v['dispensaryTag'] ?? data['dispensaryTag'],
          }, branchFallback: pool.branch);
          if (resolved != null && resolved.key == pool.key) {
            toDelete.add(k);
          }
        }
        if (toDelete.isNotEmpty) {
          await box.deleteAll(toDelete);
          purged += toDelete.length;
        }
      } catch (e) {
        debugPrint('[StockLedger] purgeStockQueues($boxName) note: $e');
      }
    }
    return purged;
  }

  static Map<String, Set<String>> _idx() {
    final cached = _index;
    if (cached != null) return cached;
    final out = <String, Set<String>>{};
    for (final v in _moves.values) {
      final m = StockMovement.fromMap(v);
      if (m == null) continue;
      out.putIfAbsent(m.itemKey, () => <String>{}).add(m.opId);
    }
    return _index = out;
  }

  // ── Reading ──────────────────────────────────────────────────────────────────

  static Map<String, dynamic>? item(String pool, String medicineId) {
    if (!isOpen) return null;
    final v = _items.get(itemKey(pool, medicineId));
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  /// All ledger records, optionally of one pool. Old-format records are ignored.
  static List<Map<String, dynamic>> items({String? pool, bool includeDeleted = false}) {
    if (!isOpen) return const [];
    final p = pool?.toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final k in _items.keys) {
      if (!isLedgerKey(k)) continue;
      final v = _items.get(k);
      if (v is! Map) continue;
      if (v['deleted'] == true && !includeDeleted) continue;
      if (p != null && (v['pool'] ?? '').toString() != p) continue;
      out.add(Map<String, dynamic>.from(v));
    }
    return out;
  }

  static double quantityOf(String pool, String medicineId) {
    final it = item(pool, medicineId);
    return it == null ? 0 : _num(it['quantity']);
  }

  static StockMovement? movement(String opId) => StockMovement.fromMap(_moves.get(opId));

  // Cache for [dispensedSerials]: rebuilt only when the moves box changed size.
  static int _dispCacheLen = -1;
  static Map<String, Set<String>> _dispCache = const {};

  /// Token serials (lower case, as written in the movement ref "<serial>|L<n>") that already
  /// have dispense movements in [pool]. The doctor's "reserved" figure drops a token as soon
  /// as its stock movement is here, even if the dispense status message is late or lost —
  /// otherwise the doctor saw the same units both taken off the shelf AND still held back.
  static Set<String> dispensedSerials(String pool) {
    if (!isOpen) return const <String>{};
    if (_dispCacheLen != _moves.length) {
      final out = <String, Set<String>>{};
      for (final v in _moves.values) {
        if (v is! Map || v['kind'] != StockMoveKind.dispense.name) continue;
        final ref = (v['ref'] ?? '').toString().trim().toLowerCase();
        if (ref.isEmpty) continue;
        final serial = ref.split('|').first.trim();
        if (serial.isEmpty) continue;
        out.putIfAbsent((v['pool'] ?? '').toString().toLowerCase(), () => <String>{}).add(serial);
      }
      _dispCache = out;
      _dispCacheLen = _moves.length;
    }
    return _dispCache[pool.toLowerCase()] ?? const <String>{};
  }

  static bool hasMovement(String opId) => isOpen && _moves.containsKey(opId);

  /// Movements of one item that are not inside its base yet.
  static List<StockMovement> openMovesOf(String pool, String medicineId) {
    final key = itemKey(pool, medicineId);
    final it = _items.get(key);
    return _openFor(key, it is Map ? it : null);
  }

  /// All movements not inside their item's base, optionally for one pool / branch.
  static List<StockMovement> openMoves({String? pool, String? branch}) {
    if (!isOpen) return const [];
    final out = <StockMovement>[];
    for (final e in _idx().entries) {
      final it = _items.get(e.key);
      final list = _openFor(e.key, it is Map ? it : null);
      for (final m in list) {
        if (pool != null && m.pool != pool) continue;
        if (branch != null && m.branch != branch) continue;
        out.add(m);
      }
    }
    return out;
  }

  /// Movements this PC still has to get into the cloud. A provisional figure (rev < 0, from
  /// the one-time repair) only hides movements from the display, never from the upload.
  static List<StockMovement> pendingUpload({String? branch}) {
    if (!isOpen) return const [];
    final out = <StockMovement>[];
    for (final e in _idx().entries) {
      final it = _items.get(e.key);
      final provisional = it is Map && _int(it['rev']) < 0;
      final list = provisional
          ? e.value.map((id) => StockMovement.fromMap(_moves.get(id))).whereType<StockMovement>().toList()
          : _openFor(e.key, it is Map ? it : null);
      for (final m in list) {
        if (m.inCloud) continue;
        if (branch != null && m.branch != branch) continue;
        out.add(m);
      }
    }
    return out;
  }

  /// Movements to offer the LAN server on (re)connect: everything not confirmed by a real
  /// (non-provisional) figure. The server ignores the ones it already has.
  static List<StockMovement> unconfirmed({String? branch}) {
    if (!isOpen) return const [];
    final out = <StockMovement>[];
    for (final e in _idx().entries) {
      final it = _items.get(e.key);
      final provisional = it is Map && _int(it['rev']) < 0;
      final list = provisional
          ? e.value.map((id) => StockMovement.fromMap(_moves.get(id))).whereType<StockMovement>().toList()
          : _openFor(e.key, it is Map ? it : null);
      for (final m in list) {
        if (branch != null && m.branch != branch) continue;
        out.add(m);
      }
    }
    return out;
  }

  static List<StockMovement> _openFor(String key, Map? it) {
    final ids = _idx()[key];
    if (ids == null || ids.isEmpty) return const [];
    final baseOps = _baseOpsOf(it);
    final rev = _int(it?['rev']);
    final out = <StockMovement>[];
    for (final id in ids) {
      if (baseOps.contains(id)) continue;
      final raw = _moves.get(id);
      final m = StockMovement.fromMap(raw);
      if (m == null) continue;
      // A movement the cloud applied at revision r is inside any base of revision >= r,
      // even when the base's id list no longer reaches back that far.
      final cloudRev = raw is Map ? _int(raw['cloudRev']) : 0;
      if (cloudRev > 0 && rev >= cloudRev) continue;
      out.add(m);
    }
    out.sort((a, b) {
      final c = a.at.compareTo(b.at);
      return c != 0 ? c : a.opId.compareTo(b.opId);
    });
    return out;
  }

  // ── Writing ──────────────────────────────────────────────────────────────────

  /// Records a movement made on THIS PC. Returns false if it was already known.
  static Future<bool> record(StockMovement m, {Map<String, dynamic>? itemDetails}) async {
    final applied = await _apply([m], details: itemDetails == null ? null : {m.itemKey: itemDetails});
    if (applied.isNotEmpty) {
      try {
        onLocalMoves?.call(applied);
      } catch (e) {
        debugPrint('[StockLedger] onLocalMoves failed: $e');
      }
    }
    return applied.isNotEmpty;
  }

  /// Records several movements made on this PC (one dispense = several lines).
  static Future<List<StockMovement>> recordAll(List<StockMovement> moves) async {
    final applied = await _apply(moves);
    if (applied.isNotEmpty) {
      try {
        onLocalMoves?.call(applied);
      } catch (e) {
        debugPrint('[StockLedger] onLocalMoves failed: $e');
      }
    }
    return applied;
  }

  /// Applies movements that came from another PC / the server. Already-known ones are
  /// skipped (but a known movement learns `inCloud` if the sender says so).
  static Future<List<StockMovement>> applyRemote(Iterable<StockMovement> moves) => _apply(moves.toList());

  static Future<List<StockMovement>> _apply(List<StockMovement> moves,
      {Map<String, Map<String, dynamic>>? details}) async {
    await ensureOpen();
    final idx = _idx();
    final applied = <StockMovement>[];
    final touched = <String>{};
    for (final m in moves) {
      final existing = _moves.get(m.opId);
      if (existing is Map) {
        if (m.inCloud && existing['inCloud'] != true) {
          await _moves.put(m.opId, {...Map<String, dynamic>.from(existing), 'inCloud': true});
        }
        continue;
      }
      await _moves.put(m.opId, m.toMap());
      idx.putIfAbsent(m.itemKey, () => <String>{}).add(m.opId);
      applied.add(m);
      touched.add(m.itemKey);
    }
    for (final key in touched) {
      final first = applied.firstWhere((m) => m.itemKey == key);
      await _ensureItem(first, details?[key]);
      await _recompute(key);
    }
    if (touched.isNotEmpty) _changes.add(touched);
    return applied;
  }

  /// Saves medicine details (name, type, dose, expiry, price, …) for one batch. Quantity
  /// fields in [details] are ignored: quantity only ever changes through movements.
  static Future<void> saveDetails(String pool, String medicineId, Map<String, dynamic> details) async {
    await ensureOpen();
    final key = itemKey(pool, medicineId);
    final cur = _items.get(key);
    final base = cur is Map ? Map<String, dynamic>.from(cur) : _newItem(pool, medicineId);
    final clean = Map<String, dynamic>.from(details)..removeWhere((k, _) => _ledgerFields.contains(k));
    base.addAll(clean);
    base.remove('deleted');
    _stampIdentity(base, pool, medicineId);
    await _items.put(key, base);
    await _recompute(key);
    _changes.add({key});
  }

  /// Takes a confirmed figure from the cloud or the LAN server. It replaces the base only if
  /// it is at least as new (rev) as the one held. Details in [details] are merged.
  /// Returns true if the shown quantity changed.
  static Future<bool> applyBase({
    required String pool,
    required String medicineId,
    required double base,
    required int rev,
    required List<String> baseOps,
    Map<String, dynamic>? details,
  }) async {
    await ensureOpen();
    final key = itemKey(pool, medicineId);
    final cur = _items.get(key);
    final it = cur is Map ? Map<String, dynamic>.from(cur) : _newItem(pool, medicineId);
    final before = _num(it['quantityRaw'] ?? it['quantity']);
    if (details != null) {
      final clean = Map<String, dynamic>.from(details)..removeWhere((k, _) => _ledgerFields.contains(k));
      it.addAll(clean);
    }
    _stampIdentity(it, pool, medicineId);
    final curRev = it.containsKey('rev') ? _int(it['rev']) : -1;
    final hasBase = it.containsKey('base');
    if (!hasBase || rev >= curRev) {
      it['base'] = math.max(0.0, base);
      it['rev'] = rev;
      it['baseOps'] = baseOps.length > baseOpsCap ? baseOps.sublist(baseOps.length - baseOpsCap) : baseOps;
      if (baseOps.length >= baseOpsCap) await _coverOlderThanList(key, it['baseOps'] as List<String>, rev);
    }
    await _items.put(key, it);
    final after = await _recompute(key);
    _changes.add({key});
    return (after - before).abs() > 1e-9;
  }

  /// Whether this PC uploads stock to the cloud (the LAN server, or a PC with no LAN link).
  /// Set by StockSync; a desk (false) never holds unsent movements for long, it forwards them.
  static bool Function()? thisPcUploads;

  /// A base whose id list is full (the cloud keeps the last [baseOpsCap]) no longer names its
  /// oldest movements. Only the uploading PC had `cloudRev` to recognise them, so on every
  /// other PC they were counted again on top of the base (a busy medicine past 600 moves
  /// showed too little stock, and prune never removed them). Movements older than the oldest
  /// one the list still names are inside the base. On the uploading PC only those the cloud
  /// confirmed (its own unsent ones are not in the cloud yet); on a desk, all of them — a desk
  /// passes its movements to the server at once, so none waits unsent while 600 newer ones
  /// reach the cloud.
  static Future<void> _coverOlderThanList(String key, List<String> listed, int rev) async {
    final ids = _idx()[key];
    if (ids == null || ids.isEmpty) return;
    final inList = listed.toSet();
    DateTime? oldestListed;
    for (final id in ids) {
      if (!inList.contains(id)) continue;
      final m = StockMovement.fromMap(_moves.get(id));
      if (m != null && (oldestListed == null || m.at.isBefore(oldestListed))) oldestListed = m.at;
    }
    if (oldestListed == null) return;
    final uploader = thisPcUploads?.call() ?? false;
    for (final id in ids) {
      if (inList.contains(id)) continue;
      final raw = _moves.get(id);
      if (raw is! Map || _int(raw['cloudRev']) > 0) continue;
      final m = StockMovement.fromMap(raw);
      if (m == null || !m.at.isBefore(oldestListed)) continue;
      final confirmed = raw['inCloud'] == true;
      if (confirmed || !uploader) {
        await _moves.put(id, {...Map<String, dynamic>.from(raw), 'cloudRev': rev});
      }
    }
  }

  /// Marks movements as being in the cloud. [cloudRev] is the revision at which the cloud
  /// applied them (from the upload transaction).
  static Future<void> markInCloud(Iterable<String> opIds, {int cloudRev = 0}) async {
    await ensureOpen();
    for (final id in opIds) {
      final v = _moves.get(id);
      if (v is! Map) continue;
      await _moves.put(id, {
        ...Map<String, dynamic>.from(v),
        'inCloud': true,
        if (cloudRev > 0) 'cloudRev': cloudRev,
      });
    }
  }

  /// Hides a batch (medicine removed). Its movements stay, so history and totals stay right
  /// if it is ever brought back.
  static bool _sanitizedNegativesOnce = false;

  /// One-time per session cleanup of any legacy negative balances in Hive.
  static Future<void> sanitizeNegativesOnce() async {
    if (_sanitizedNegativesOnce) return;
    _sanitizedNegativesOnce = true;
    await sanitizeNegatives();
  }

  /// Clamps any stored negative balances (`base`, `quantityRaw`, `quantity`)
  /// in `local_stock_items` back to `0.0` and notifies listeners.
  static Future<int> sanitizeNegatives() async {
    await ensureOpen();
    var healed = 0;
    final changed = <String>{};
    for (final k in _items.keys.toList()) {
      final raw = _items.get(k);
      if (raw is! Map) continue;
      final base = _num(raw['base']);
      final qRaw = _num(raw['quantityRaw']);
      final q = _num(raw['quantity']);
      if (base < 0 || qRaw < 0 || q < 0) {
        final ks = k.toString();
        if (base < 0) {
          final updated = Map<String, dynamic>.from(raw);
          updated['base'] = 0.0;
          await _items.put(ks, updated);
        }
        await _recompute(ks);
        changed.add(ks);
        healed++;
      }
    }
    if (changed.isNotEmpty) _changes.add(changed);
    return healed;
  }

  static Future<void> markDeleted(String pool, String medicineId) async {
    await ensureOpen();
    final key = itemKey(pool, medicineId);
    final cur = _items.get(key);
    if (cur is! Map) return;
    await _items.put(key, {
      ...Map<String, dynamic>.from(cur),
      'deleted': true,
      'base': 0.0,
      'quantityRaw': 0.0,
      'quantity': 0.0,
    });
    _changes.add({key});
  }

  /// Forgets movements older than [keepMoves] that are already inside their base.
  static Future<int> prune({DateTime? now}) async {
    if (!isOpen) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(keepMoves);
    final drop = <String>[];
    final idx = _idx();
    for (final e in idx.entries) {
      final it = _items.get(e.key);
      final open = _openFor(e.key, it is Map ? it : null).map((m) => m.opId).toSet();
      for (final id in e.value) {
        if (open.contains(id)) continue;
        final m = StockMovement.fromMap(_moves.get(id));
        if (m == null || m.at.isBefore(cutoff)) drop.add(id);
      }
    }
    if (drop.isEmpty) return 0;
    await _moves.deleteAll(drop);
    for (final s in idx.values) {
      s.removeAll(drop);
    }
    return drop.length;
  }

  // ── Snapshot / checksum (LAN catch-up and the weekly check) ─────────────────

  /// Everything another PC needs to reach this PC's figures for [pools] (null = all).
  static Map<String, dynamic> snapshot({Set<String>? pools}) {
    final items = <Map<String, dynamic>>[];
    final seenPools = <String>{if (pools != null) ...pools};
    for (final it in StockLedger.items(includeDeleted: true)) {
      final p = (it['pool'] ?? '').toString();
      if (pools != null && !pools.contains(p)) continue;
      if (p.isNotEmpty) seenPools.add(p);
      // Removed batches go too, as a marker only: a desk that was off when a batch was
      // deleted (or a pool wiped) kept showing it, and every check found a difference.
      if (it['deleted'] == true) {
        items.add({'pool': p, 'medicineId': it['medicineId'] ?? it['id'], 'deleted': true});
        continue;
      }
      items.add(it);
    }
    final moves = openMoves()
        .where((m) => pools == null || pools.contains(m.pool))
        .map((m) => m.toMap())
        .toList();
    final wipeEpochs = <String, String>{};
    for (final p in seenPools) {
      final wid = poolWipeId(p);
      if (wid != null && wid.isNotEmpty) wipeEpochs[p] = wid;
    }
    return {
      'items': items,
      'moves': moves,
      if (wipeEpochs.isNotEmpty) 'wipeEpochs': wipeEpochs,
    };
  }

  /// Applies a snapshot from the LAN server. Returns how many items changed.
  static Future<int> applySnapshot(Map snap) async {
    var changed = 0;
    // Apply any newer pool wipe epochs FIRST (chunk-safe: once recorded, later chunks match
    // poolWipeId and will not re-purge).
    final wipeEpochs = snap['wipeEpochs'];
    if (wipeEpochs is Map) {
      for (final e in wipeEpochs.entries) {
        final pool = e.key.toString().trim().toLowerCase();
        final wid = (e.value ?? '').toString().trim();
        if (pool.isEmpty || wid.isEmpty) continue;
        if (poolWipeId(pool) != wid) {
          final res = await purgePool(pool, wipeId: wid);
          changed += res.itemsRemoved;
        }
      }
    }
    final moves = <StockMovement>[];
    for (final raw in (snap['moves'] is List ? snap['moves'] as List : const [])) {
      final m = StockMovement.fromMap(raw);
      if (m != null) moves.add(m);
    }
    if (moves.isNotEmpty) changed += (await applyRemote(moves)).length;
    for (final raw in (snap['items'] is List ? snap['items'] as List : const [])) {
      if (raw is! Map) continue;
      final pool = (raw['pool'] ?? '').toString();
      final id = (raw['medicineId'] ?? raw['id'] ?? '').toString();
      if (pool.isEmpty || id.isEmpty) continue;
      final details = Map<String, dynamic>.from(raw);
      if (raw['deleted'] == true) {
        if (raw['hardDelete'] == true) {
          if (await hardDeleteItem(pool, id)) changed++;
        } else {
          await markDeleted(pool, id);
        }
        continue;
      }
      if (!raw.containsKey('base')) {
        await saveDetails(pool, id, details);
        continue;
      }
      if (await applyBase(
        pool: pool,
        medicineId: id,
        base: _num(raw['base']),
        rev: _int(raw['rev']),
        baseOps: _baseOpsOf(raw).toList(),
        details: details,
      )) {
        changed++;
      }
    }
    return changed;
  }

  /// Short fingerprint of a pool's figures. Two PCs with the same checksum show the same
  /// quantities for every medicine in that pool.
  static String checksum(String pool) {
    final rows = items(pool: pool)
        .map((it) => '${it['medicineId'] ?? it['id']}:${_num(it['quantityRaw'] ?? it['quantity']).toStringAsFixed(2)}')
        .toList()
      ..sort();
    return StockMovement.deterministicId('ck', [rows.length, ...rows]);
  }

  // ── Internals ────────────────────────────────────────────────────────────────

  static const Set<String> _ledgerFields = {
    'base', 'rev', 'baseOps', 'quantity', 'quantityRaw', 'stock', 'pool', '_quantityDelta', 'lastOps', 'deleted',
  };

  /// A record with no confirmed figure yet ('base' absent): the first base from the cloud,
  /// the LAN server or the repair is always taken.
  static Map<String, dynamic> _newItem(String pool, String medicineId) => {
        'quantity': 0.0,
        'quantityRaw': 0.0,
      };

  static void _stampIdentity(Map<String, dynamic> it, String pool, String medicineId) {
    final p = StockPool.fromKey(pool);
    it['pool'] = pool.toLowerCase();
    it['id'] = medicineId;
    it['medicineId'] = medicineId;
    if (p != null) {
      it['branchId'] = p.branch;
      if (p.camp != null) {
        it['campId'] = p.camp;
        it['dispensaryId'] = p.camp;
      } else {
        it.remove('campId');
        it.remove('dispensaryId');
        it.remove('dispensaryTag');
      }
    }
  }

  static Future<void> _ensureItem(StockMovement m, Map<String, dynamic>? details) async {
    final key = m.itemKey;
    final cur = _items.get(key);
    if (cur is Map && details == null && cur['deleted'] != true) return;
    // Never create a phantom Qty-0 / no-expiry ghost row from a negative dispense movement
    // arriving for a wiped or unknown batch (the movement stays in _moves, so if real details
    // arrive later _recompute still subtracts it). Similarly never touch a deleted batch on
    // a late negative movement.
    if (details == null && m.delta <= 0) {
      if (cur == null) return;
      if (cur is Map && cur['deleted'] == true) return;
    }
    final it = cur is Map ? Map<String, dynamic>.from(cur) : _newItem(m.pool, m.medicineId);
    if (details != null) {
      final clean = Map<String, dynamic>.from(details)..removeWhere((k, _) => _ledgerFields.contains(k));
      it.addAll(clean);
    }
    if ((it['name'] ?? '').toString().trim().isEmpty && m.name.isNotEmpty) it['name'] = m.name;
    // A restock brings a hidden batch back, never preserving a prior negative base.
    if (m.delta > 0) {
      it.remove('deleted');
      if (_num(it['base']) < 0) it['base'] = 0.0;
    }
    _stampIdentity(it, m.pool, m.medicineId);
    await _items.put(key, it);
  }

  static Future<double> _recompute(String key) async {
    final cur = _items.get(key);
    if (cur is! Map) return 0;
    final it = Map<String, dynamic>.from(cur);
    final rawBase = _num(it['base']);
    var q = math.max(0.0, rawBase);
    if (rawBase < 0) it['base'] = 0.0;
    for (final m in _openFor(key, it)) {
      q = math.max(0.0, q + m.delta);
    }
    q = double.parse(math.max(0.0, q).toStringAsFixed(4));
    it['quantityRaw'] = q;
    it['quantity'] = q;
    it['updatedAt'] = DateTime.now().toIso8601String();
    await _items.put(key, it);
    return q;
  }

  static Set<String> _baseOpsOf(Map? it) {
    final raw = it?['baseOps'];
    if (raw is! List) return const <String>{};
    return raw.map((e) => e.toString()).toSet();
  }

  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;
  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
}
