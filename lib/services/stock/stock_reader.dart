// lib/services/stock/stock_reader.dart
//
// The ONLY way screens read stock. Doctor panel, prescription edit, templates, dispensar
// table, Update Stock, ledger and the dispense itself all call this, so they all count the
// same records the same way:
//   • strictly one pool (branch, or branch + camp) — no "fall back to the whole branch";
//   • batches of the same medicine (name/formula + form + strength) are ADDED together;
//   • FEFO: earliest expiry first, expired batches last;
//   • available = on shelf − reserved (today's saved prescriptions not yet dispensed).

import 'package:hive_flutter/hive_flutter.dart';

import '../../pages/dispensary/dispensar/patient_form_helper.dart';
import '../camp_session_service.dart';
import '../local_storage_service.dart';
import '../master_proforma_service.dart';
import 'stock_ledger.dart';
import 'stock_pool.dart';

/// Units a prescription line takes from the shelf. Used by the dispense AND by the doctor's
/// reservation, so what the doctor holds back is exactly what the dispensar will take.
class StockMath {
  StockMath._();

  static bool isSyrup(String? type, String? name) {
    final t = (type ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    return t.contains('syrup') || t.contains('syp') || t.contains('susp') || n.contains('syrup') || n.contains('syp');
  }

  static bool isInjectable(String? type, String? name) {
    final t = (type ?? '').toLowerCase().trim();
    if (t.contains('syringe') || t.contains('nebulization')) return true;
    return PatientFormHelper.isInjectablePrescription(t, name ?? '');
  }

  /// Units per day: syrups 1 bottle (whole course), injections the prescribed count, other
  /// medicines the sum of the timing slots ("1+0+1" = 2) or the stored per-day quantity.
  static int perDay(Map line) {
    final type = line['type']?.toString();
    final name = (line['name'] ?? line['formula'])?.toString();
    if (isSyrup(type, name)) return 1;
    final raw = line['quantity'] ?? line['qty'] ?? 1;
    final stored = raw is num ? raw.toInt() : (int.tryParse(raw.toString()) ?? 1);
    if (isInjectable(type, name)) return stored > 0 ? stored : 1;
    final timing = (line['timing'] ?? '').toString().trim();
    if (timing.isNotEmpty) {
      final t = PatientFormHelper.totalPerDay(timing);
      if (t > 0) return t;
    }
    return stored > 0 ? stored : 1;
  }

  /// Units for the whole prescription line.
  static double lineUnits(Map line, int days) {
    final type = line['type']?.toString();
    final name = (line['name'] ?? line['formula'])?.toString();
    if (isSyrup(type, name)) return 1;
    final p = perDay(line).toDouble();
    if (isInjectable(type, name)) return p;
    return p * (days < 1 ? 1 : days);
  }
}

/// One medicine as a screen shows it: all batches of it in the pool added together.
class StockGroup {
  final String key; // name|type|dose
  final String pool;
  final List<Map<String, dynamic>> batches; // FEFO order
  final double onShelf;
  final double reserved;

  StockGroup({
    required this.key,
    required this.pool,
    required this.batches,
    required this.onShelf,
    required this.reserved,
  });

  double get available => (onShelf - reserved) < 0 ? 0 : onShelf - reserved;
  bool get inStock => available > 0;
  List<String> get batchIds => [for (final b in batches) (b['medicineId'] ?? b['id']).toString()];

  /// First batch that still has stock (else the first batch): its id is what a
  /// prescription line links to.
  Map<String, dynamic> get primary =>
      batches.firstWhere((b) => StockReader.qty(b) > 0, orElse: () => batches.first);
}

class StockReader {
  StockReader._();

  static double qty(Map b) {
    final q = b['quantity'];
    return q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0;
  }

  static String _clean(Object? v) => MasterProformaService.cleanBrandToFormula((v ?? '').toString())
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _cleanDose(Object? v) => (v ?? '').toString().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static String _type(Map b) => (b['type'] ?? b['dosageForm'] ?? b['form'] ?? '').toString().toLowerCase().trim();

  /// Grouping key: the same medicine in the same form and strength.
  static String groupKey(Map b) {
    final isCustom = b['isCustomized'] == true || b['userEdited'] == true;
    final rawName = (b['name'] ?? b['formula'] ?? '').toString();
    final name = isCustom ? rawName.toLowerCase().trim() : _clean(rawName);
    return '$name|${_type(b)}|${_cleanDose(b['dose'] ?? b['dosage'])}';
  }

  static bool hasUsableName(Map b) {
    final n = (b['name'] ?? b['formula'] ?? '').toString().trim().toLowerCase();
    return n.isNotEmpty && n != 'null' && n != 'unknown';
  }

  /// Batches of one pool (named, not deleted).
  static List<Map<String, dynamic>> batches(StockPool pool) =>
      StockLedger.items(pool: pool.key).where(hasUsableName).toList();

  /// FEFO order: earliest expiry first, expired batches last, id as tie-breaker.
  static void sortFefo(List<Map<String, dynamic>> list, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    list.sort((a, b) {
      final ea = MasterProformaService.parseExpiryDate(a['expiryDate'] ?? a['expiry'], (a['id'] ?? a['medicineId'])?.toString());
      final eb = MasterProformaService.parseExpiryDate(b['expiryDate'] ?? b['expiry'], (b['id'] ?? b['medicineId'])?.toString());
      final xa = ea.isBefore(today), xb = eb.isBefore(today);
      if (xa != xb) return xa ? 1 : -1;
      final c = ea.compareTo(eb);
      if (c != 0) return c;
      return (a['id'] ?? '').toString().compareTo((b['id'] ?? '').toString());
    });
  }

  /// All medicines of a pool, batches added together, with reservations applied.
  /// [excludeSerial] leaves that token's own prescription out of "reserved" (the doctor
  /// writing it, or the dispensar dispensing it).
  static List<StockGroup> groups(StockPool pool, {String? excludeSerial, bool withReserved = true}) {
    final byKey = <String, List<Map<String, dynamic>>>{};
    for (final b in batches(pool)) {
      byKey.putIfAbsent(groupKey(b), () => []).add(b);
    }
    final reservedById = withReserved ? reservedByMedicine(pool, excludeSerial: excludeSerial) : const <String, double>{};
    final out = <StockGroup>[];
    for (final e in byKey.entries) {
      final list = e.value;
      sortFefo(list);
      var shelf = 0.0, res = 0.0;
      for (final b in list) {
        shelf += qty(b);
        res += reservedById[(b['medicineId'] ?? b['id']).toString()] ?? 0;
      }
      out.add(StockGroup(key: e.key, pool: pool.key, batches: list, onShelf: shelf, reserved: res));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  /// The group a prescription line belongs to: by batch id first, then by name/form/strength.
  static StockGroup? groupForLine(StockPool pool, Map line, {String? excludeSerial, List<StockGroup>? within}) {
    final all = within ?? groups(pool, excludeSerial: excludeSerial);
    final id = (line['inventoryId'] ?? line['medicineId'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      for (final g in all) {
        if (g.batchIds.contains(id)) return g;
      }
    }
    final key = groupKey({
      'name': line['formula'] ?? line['name'],
      'type': line['type'],
      'dose': line['dose'] ?? line['dosage'],
    });
    final key2 = groupKey({'name': line['name'], 'type': line['type'], 'dose': line['dose'] ?? line['dosage']});
    for (final g in all) {
      if (g.key == key || g.key == key2) return g;
    }
    return null;
  }

  /// Splits [units] over the group's batches, FEFO, never taking more than a batch holds.
  /// Returns batchId → units taken; the sum may be less than [units] when stock is short.
  static Map<String, double> planTake(StockGroup g, double units) {
    final out = <String, double>{};
    var left = units;
    for (final b in g.batches) {
      if (left <= 0) break;
      final have = qty(b);
      if (have <= 0) continue;
      final take = left <= have ? left : have;
      out[(b['medicineId'] ?? b['id']).toString()] = take;
      left -= take;
    }
    return out;
  }

  // ── Reservations ─────────────────────────────────────────────────────────────

  /// Units held back per batch id by today's saved, not yet dispensed prescriptions in this
  /// pool. A reservation ends when the token is dispensed, completed or cancelled, and at
  /// the end of the day.
  static Map<String, double> reservedByMedicine(StockPool pool, {String? excludeSerial}) {
    final out = <String, double>{};
    if (!Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) return out;
    final prescBox = Hive.box(LocalStorageService.prescriptionsBox);
    final entries = Hive.isBoxOpen(LocalStorageService.entriesBox) ? Hive.box(LocalStorageService.entriesBox) : null;
    final today = CampSessionService.resolveShiftAndDateKey(null, pool.branch).dateKey;
    final skip = _canonSerial(excludeSerial, pool.branch);

    final finished = <String>{};
    if (entries != null) {
      for (final v in entries.values) {
        if (v is! Map) continue;
        if (_isFinished(v)) {
          final s = _canonSerial((v['serial'] ?? v['id'])?.toString(), pool.branch);
          if (s.isNotEmpty) finished.add(s);
        }
      }
    }

    for (final raw in prescBox.values) {
      if (raw is! Map) continue;
      final serial = _canonSerial((raw['serial'] ?? raw['id'])?.toString(), pool.branch);
      if (serial.isEmpty || serial == skip) continue;
      if (_isFinished(raw) || finished.contains(serial)) continue;
      if (!_isToday(raw, serial, today)) continue;
      // Only prescriptions of this pool.
      final rp = StockPool.of(
        (raw['branchId'] ?? pool.branch).toString(),
        (raw['campId'] ?? raw['dispensaryId'])?.toString(),
        fallbackCamp: pool.camp,
      );
      if (rp == null || rp.key != pool.key) continue;
      final meds = raw['prescriptions'] ?? raw['medicines'];
      if (meds is! List) continue;
      final d = raw['daysOfMedicine'];
      final days = d is num ? d.toInt() : int.tryParse(d?.toString() ?? '1') ?? 1;
      for (final m in meds) {
        if (m is! Map) continue;
        if (m['isExternal'] == true || m['outOfStock'] == true) continue;
        final id = (m['inventoryId'] ?? m['medicineId'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        out[id] = (out[id] ?? 0) + StockMath.lineUnits(m, days);
      }
    }
    return out;
  }

  static bool _isFinished(Map v) {
    final d = (v['dispenseStatus'] ?? '').toString().toLowerCase().trim();
    final s = (v['status'] ?? '').toString().toLowerCase().trim();
    return d == 'dispensed' || d == 'cancelled' || s == 'completed' || s == 'cancelled' || s == 'dispensed' ||
        v['dispensedAt'] != null;
  }

  static bool _isToday(Map raw, String serial, String today) {
    final fromSerial = CampSessionService.getDateKeyFromSerial(serial);
    if (fromSerial.isNotEmpty) return fromSerial == today;
    final created = DateTime.tryParse((raw['createdAt'] ?? raw['timestamp'] ?? raw['date'] ?? '').toString());
    if (created == null) return false;
    final k = '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}';
    return k == today;
  }

  static String _canonSerial(String? s, String branch) {
    var v = (s ?? '').trim().toLowerCase();
    if (v.startsWith('$branch-')) v = v.substring(branch.length + 1);
    return v;
  }
}
