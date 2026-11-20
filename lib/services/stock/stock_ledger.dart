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
  static void resetCache() => _index = null;

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
  static List<Map<String, dynamic>> items({String? pool}) {
    if (!isOpen) return const [];
    final p = pool?.toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final k in _items.keys) {
      if (!isLedgerKey(k)) continue;
      final v = _items.get(k);
      if (v is! Map) continue;
      if (v['deleted'] == true) continue;
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
      it['base'] = base;
      it['rev'] = rev;
      it['baseOps'] = baseOps.length > baseOpsCap ? baseOps.sublist(baseOps.length - baseOpsCap) : baseOps;
    }
    await _items.put(key, it);
    final after = await _recompute(key);
    _changes.add({key});
    return (after - before).abs() > 1e-9;
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
  static Future<void> markDeleted(String pool, String medicineId) async {
    await ensureOpen();
    final key = itemKey(pool, medicineId);
    final cur = _items.get(key);
    if (cur is! Map) return;
    await _items.put(key, {...Map<String, dynamic>.from(cur), 'deleted': true});
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
    for (final it in StockLedger.items()) {
      if (pools != null && !pools.contains(it['pool'])) continue;
      items.add(it);
    }
    final moves = openMoves()
        .where((m) => pools == null || pools.contains(m.pool))
        .map((m) => m.toMap())
        .toList();
    return {'items': items, 'moves': moves};
  }

  /// Applies a snapshot from the LAN server. Returns how many items changed.
  static Future<int> applySnapshot(Map snap) async {
    var changed = 0;
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
        await markDeleted(pool, id);
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
    final it = cur is Map ? Map<String, dynamic>.from(cur) : _newItem(m.pool, m.medicineId);
    if (details != null) {
      final clean = Map<String, dynamic>.from(details)..removeWhere((k, _) => _ledgerFields.contains(k));
      it.addAll(clean);
    }
    if ((it['name'] ?? '').toString().trim().isEmpty && m.name.isNotEmpty) it['name'] = m.name;
    // A restock brings a hidden batch back.
    if (m.delta > 0) it.remove('deleted');
    _stampIdentity(it, m.pool, m.medicineId);
    await _items.put(key, it);
  }

  static Future<double> _recompute(String key) async {
    final cur = _items.get(key);
    if (cur is! Map) return 0;
    final it = Map<String, dynamic>.from(cur);
    var q = _num(it['base']);
    for (final m in _openFor(key, it)) {
      q += m.delta;
    }
    q = double.parse(q.toStringAsFixed(4));
    it['quantityRaw'] = q;
    it['quantity'] = math.max(0.0, q);
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
