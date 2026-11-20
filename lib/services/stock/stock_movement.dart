// lib/services/stock/stock_movement.dart
//
// One stock change. Stock is never sent around as a total any more: every dispense,
// restock, correction or count is a movement with its own id (opId), created once on the
// PC where it happened. Every PC, the LAN server and the cloud apply a movement at most
// once (by opId), in any order, through any route (LAN, cloud, replay, catch-up).

import 'dart:math';

enum StockMoveKind { dispense, restock, adjust, count, returned }

class StockMovement {
  final String opId;
  final String pool; // StockPool.key
  final String medicineId;
  final double delta;
  final StockMoveKind kind;
  final DateTime at;
  final String by;
  final String device;

  /// What caused it, e.g. token serial + line ("171126-GUJ-012|L2").
  final String ref;

  /// Medicine name at the time (audit / reports only).
  final String name;

  /// True once the cloud has this movement (it went up from this PC or from the server).
  final bool inCloud;

  const StockMovement({
    required this.opId,
    required this.pool,
    required this.medicineId,
    required this.delta,
    required this.kind,
    required this.at,
    this.by = '',
    this.device = '',
    this.ref = '',
    this.name = '',
    this.inCloud = false,
  });

  String get itemKey => '$pool|$medicineId';

  String get branch {
    final i = pool.indexOf('/');
    return i < 0 ? pool : pool.substring(0, i);
  }

  StockMovement copyWith({bool? inCloud}) => StockMovement(
        opId: opId,
        pool: pool,
        medicineId: medicineId,
        delta: delta,
        kind: kind,
        at: at,
        by: by,
        device: device,
        ref: ref,
        name: name,
        inCloud: inCloud ?? this.inCloud,
      );

  Map<String, dynamic> toMap() => {
        'opId': opId,
        'pool': pool,
        'medicineId': medicineId,
        'delta': delta,
        'kind': kind.name,
        'at': at.toIso8601String(),
        'by': by,
        'device': device,
        'ref': ref,
        'name': name,
        'inCloud': inCloud,
      };

  static StockMovement? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final opId = (raw['opId'] ?? '').toString().trim();
    final pool = (raw['pool'] ?? '').toString().trim().toLowerCase();
    final med = (raw['medicineId'] ?? '').toString().trim();
    final d = raw['delta'];
    final delta = d is num ? d.toDouble() : double.tryParse(d?.toString() ?? '');
    if (opId.isEmpty || pool.isEmpty || med.isEmpty || delta == null || delta.isNaN || delta.isInfinite) {
      return null;
    }
    return StockMovement(
      opId: opId,
      pool: pool,
      medicineId: med,
      delta: delta,
      kind: StockMoveKind.values.firstWhere((k) => k.name == raw['kind'], orElse: () => StockMoveKind.adjust),
      at: DateTime.tryParse((raw['at'] ?? '').toString()) ?? DateTime.now(),
      by: (raw['by'] ?? '').toString(),
      device: (raw['device'] ?? '').toString(),
      ref: (raw['ref'] ?? '').toString(),
      name: (raw['name'] ?? '').toString(),
      inCloud: raw['inCloud'] == true,
    );
  }

  static final Random _rand = Random.secure();

  /// A new random op id. Use [deterministicId] when the same real-world event could be
  /// recorded twice (a dispense line re-sent after a crash must get the same id).
  static String newId(String prefix) {
    final r = List.generate(6, (_) => _rand.nextInt(36).toRadixString(36)).join();
    return '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$r';
  }

  /// Same inputs → same id, on every PC.
  static String deterministicId(String prefix, List<Object?> parts) {
    final s = parts.map((p) => (p ?? '').toString().trim().toLowerCase()).join('|');
    // Two independent 31-bit hashes (~62 bits together). All intermediate values stay below
    // 2^53, so the result is identical on Windows/Android and on the web (JS numbers).
    const m = 2147483647;
    var h1 = 5381, h2 = 7919;
    for (final c in s.codeUnits) {
      h1 = (h1 * 33 + c) % m;
      h2 = (h2 * 131 + c) % m;
    }
    return '$prefix-${h1.toRadixString(36)}${h2.toRadixString(36)}';
  }
}
