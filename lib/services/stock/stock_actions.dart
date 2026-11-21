// lib/services/stock/stock_actions.dart
//
// What screens call to CHANGE stock. Every change becomes a movement (StockLedger) that is
// applied here at once and sent on by StockSync. No screen writes the stock box directly.

import '../local_storage_service.dart';
import 'expiry_rules.dart';
import 'stock_ledger.dart';
import 'stock_log.dart';
import 'stock_movement.dart';
import 'stock_pool.dart';
import 'stock_reader.dart';
import 'stock_sync.dart';

class StockActions {
  StockActions._();

  static String get _who => LocalStorageService.getActiveUsername();

  /// Pool of a record read through StockReader / StockLedger.
  static StockPool? poolOf(Map item) => StockPool.fromKey(item['pool']?.toString());

  /// Adds [qty] units to a batch (restock, proforma receipt). Returns the movement, or null
  /// if [qty] is not positive. [opKey] makes it once-only (e.g. an approved request id).
  static Future<StockMovement?> restock(
    StockPool pool,
    String medicineId,
    double qty, {
    Map<String, dynamic>? details,
    String ref = '',
    String? opKey,
  }) async {
    if (qty <= 0 || medicineId.trim().isEmpty) return null;
    await StockLedger.sanitizeNegativesOnce();
    if (details != null) await StockSync.saveDetails(pool, medicineId, details);
    final m = StockMovement(
      opId: opKey == null
          ? StockMovement.newId('rst')
          : StockMovement.deterministicId('rst', [pool.key, medicineId, opKey]),
      pool: pool.key,
      medicineId: medicineId.trim(),
      delta: qty,
      kind: StockMoveKind.restock,
      at: DateTime.now(),
      by: _who,
      ref: ref,
      name: (details?['name'] ?? StockLedger.item(pool.key, medicineId)?['name'] ?? '').toString(),
    );
    await StockLedger.record(m);
    return m;
  }

  /// Sets a batch to a counted figure (stock count, or a quantity typed in an edit dialog).
  /// Recorded as the difference from what this PC shows now, so changes other PCs made in
  /// the meantime are kept. Returns null when nothing changes.
  static Future<StockMovement?> setCounted(
    StockPool pool,
    String medicineId,
    double counted, {
    String reason = 'stock count',
  }) async {
    if (counted < 0) counted = 0;
    await StockLedger.sanitizeNegativesOnce();
    final it = StockLedger.item(pool.key, medicineId);
    final shown = it == null ? 0.0 : StockReader.qty(it);
    final delta = double.parse((counted - shown).toStringAsFixed(4));
    if (delta == 0) return null;
    // Once-only per (figure shown, figure counted, day): the same count made on two PCs, or
    // the same request approved on two PCs, is one movement instead of two.
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final m = StockMovement(
      opId: StockMovement.deterministicId('cnt', [pool.key, medicineId.trim(), '$shown', '$counted', day, reason]),
      pool: pool.key,
      medicineId: medicineId.trim(),
      delta: delta,
      kind: StockMoveKind.count,
      at: DateTime.now(),
      by: _who,
      ref: reason,
      name: (it?['name'] ?? '').toString(),
    );
    await StockLedger.record(m);
    return m;
  }

  /// Records a counted correction of exactly [delta] (used when the record is below 0, where
  /// [setCounted] would start from the displayed 0 instead of the true figure).
  /// [opKey] makes it once-only (e.g. an approved request id): approving the same request on
  /// two PCs then moves stock once, not twice.
  static Future<StockMovement?> countDifference(StockPool pool, String medicineId, double delta,
      {String name = '', String reason = 'stock count', String? opKey}) async {
    if (delta == 0 || medicineId.trim().isEmpty) return null;
    await StockLedger.sanitizeNegativesOnce();
    final m = StockMovement(
      opId: opKey == null
          ? StockMovement.newId('cnt')
          : StockMovement.deterministicId('cnt', [pool.key, medicineId, opKey]),
      pool: pool.key,
      medicineId: medicineId.trim(),
      delta: double.parse(delta.toStringAsFixed(4)),
      kind: StockMoveKind.count,
      at: DateTime.now(),
      by: _who,
      ref: reason,
      name: name,
    );
    await StockLedger.record(m);
    return m;
  }

  /// A new batch (new medicine registration / proforma import) with its first stock.
  static Future<void> addBatch(
    StockPool pool,
    String medicineId,
    Map<String, dynamic> details, {
    double initialQty = 0,
    String ref = 'new batch',
    String? opKey,
  }) async {
    await StockSync.saveDetails(pool, medicineId, details);
    if (initialQty > 0) {
      await restock(pool, medicineId, initialQty, ref: ref, opKey: opKey ?? 'initial');
    }
  }

  /// Name, price, expiry, … — never quantity.
  static Future<void> saveDetails(StockPool pool, String medicineId, Map<String, dynamic> details) =>
      StockSync.saveDetails(pool, medicineId, details);

  /// Hides a batch everywhere (kept for history).
  static Future<void> deleteBatch(StockPool pool, String medicineId) => StockSync.deleteBatch(pool, medicineId);

  /// Takes stock for one dispensed token. [lines] are the prescription lines; [days] the
  /// course length. Ids are derived from the token, so dispensing the same token again
  /// (resend, crash, second click) can never take the stock twice.
  ///
  /// Never takes more than a batch holds. Returns the movements made and, per line index,
  /// the units that could not be taken (stock short).
  static Future<({List<StockMovement> moves, Map<int, double> short})> dispense({
    required StockPool pool,
    required String serial,
    String entryUid = '',
    required List<Map<String, dynamic>> lines,
    required int days,
  }) async {
    // Once per token on this PC: a second dispense of the same token (double click, resend,
    // restart) takes nothing, even if the batches changed in between.
    final claimKey = 'stock_disp|${pool.key}|${serial.trim().toLowerCase()}|${entryUid.trim().toLowerCase()}';
    final flags = await LocalStorageService.ensureBoxOpen('app_flags');
    if (flags.containsKey(claimKey)) {
      return (moves: const <StockMovement>[], short: const <int, double>{});
    }
    await flags.put(claimKey, DateTime.now().toIso8601String());
    await StockLedger.sanitizeNegativesOnce();

    final groups = StockReader.groups(pool, excludeSerial: serial);
    final moves = <StockMovement>[];
    final short = <int, double>{};
    // Units already taken in this call per batch (two lines of the same medicine).
    final takenHere = <String, double>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final units = line['_units'] is num ? (line['_units'] as num).toDouble() : StockMath.lineUnits(line, days);
      if (units <= 0) continue;
      final g = StockReader.groupForLine(pool, line, within: groups);
      if (g == null) {
        short[i] = units;
        continue;
      }
      var left = units;
      for (final b in g.batches) {
        if (left <= 0) break;
        if (isBatchExpired(b)) continue; // expired stock is never dispensed
        final id = (b['medicineId'] ?? b['id']).toString();
        final have = StockReader.qty(b) - (takenHere[id] ?? 0);
        if (have <= 0) continue;
        final take = left <= have ? left : have;
        takenHere[id] = (takenHere[id] ?? 0) + take;
        left -= take;
        moves.add(StockMovement(
          opId: StockMovement.deterministicId('disp', [pool.key, serial, entryUid, i, id]),
          pool: pool.key,
          medicineId: id,
          delta: -take,
          kind: StockMoveKind.dispense,
          at: DateTime.now(),
          by: _who,
          ref: '$serial|L$i',
          name: (b['name'] ?? line['name'] ?? '').toString(),
        ));
      }
      if (left > 1e-9) short[i] = left;
    }
    if (moves.isNotEmpty) {
      await StockLedger.recordAll(moves);
      // One log entry per token (LAN only, `cloud: false`: the movements themselves already
      // reach the cloud, so this does not cost Firebase writes per patient).
      final perMedicine = <String, double>{};
      for (final m in moves) {
        perMedicine[m.name] = (perMedicine[m.name] ?? 0) - m.delta;
      }
      await StockLog.record({
        'id': 'log_disp_${pool.key.replaceAll('/', '_')}_${serial.trim()}_${entryUid.trim()}',
        'action': 'dispensed',
        'serial': serial,
        'medicineName': perMedicine.keys.join(', '),
        'items': [
          for (final e in perMedicine.entries) {'name': e.key, 'quantity': e.value},
        ],
        'quantityRemoved': perMedicine.values.fold<double>(0, (a, b) => a + b),
        'pool': pool.key,
        'branchId': pool.branch,
        'cloud': false,
      });
    }
    return (moves: moves, short: short);
  }
}
