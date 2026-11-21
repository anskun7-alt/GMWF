import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_cloud.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_movement.dart';
import 'package:gmwf/services/stock/stock_pool.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late StockPool lahore;
  late StockPool khiHaji;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_stock_neg_wipe_test');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox(LocalStorageService.syncBox);
    await Hive.openBox(LocalStorageService.auditLogsBox);
    await Hive.openBox(LocalStorageService.stockBox);
    await Hive.openBox(StockLedger.movesBoxName);
    await Hive.openBox('stock_quarantine');
    await Hive.openBox('stock_drift_log');
    StockLedger.resetCache();

    await Hive.box('app_settings').put('user_data', {
      'uid': 'disp-neg-1',
      'username': 'Tester Dispenser',
      'role': 'dispenser',
    });

    lahore = StockPool.of('lahore', null)!;
    khiHaji = StockPool.of('karachi', 'haji_camp')!;
  });

  tearDown(() async {
    StockLedger.resetCache();
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Negative stock elimination and pool wipe cleanliness', () {
    test('sanitizeNegatives resets stored negative base/quantityRaw to 0 and restock starts from 0', () async {
      final box = Hive.box(LocalStorageService.stockBox);
      final key = StockLedger.itemKey(lahore.key, 'med_neg_1');
      await box.put(key, {
        'id': 'med_neg_1',
        'medicineId': 'med_neg_1',
        'pool': lahore.key,
        'branchId': 'lahore',
        'name': 'Paracetamol 500mg',
        'base': -200.0,
        'quantityRaw': -200.0,
        'quantity': 0.0,
        'rev': 3,
      });

      final healed = await StockLedger.sanitizeNegatives();
      expect(healed, 1);

      final afterHeal = StockLedger.item(lahore.key, 'med_neg_1')!;
      expect((afterHeal['base'] as num).toDouble(), 0.0);
      expect((afterHeal['quantityRaw'] as num).toDouble(), 0.0);
      expect((afterHeal['quantity'] as num).toDouble(), 0.0);

      await StockActions.restock(lahore, 'med_neg_1', 50, ref: 'proforma');
      final afterRestock = StockLedger.item(lahore.key, 'med_neg_1')!;
      expect((afterRestock['quantity'] as num).toDouble(), 50.0);
      expect((afterRestock['quantityRaw'] as num).toDouble(), 50.0);
    });

    test('adding +1 via Proforma restock onto an existing -200 batch results in 1 (never 0)', () async {
      final box = Hive.box(LocalStorageService.stockBox);
      final key = StockLedger.itemKey(lahore.key, 'med_neg_2');
      await box.put(key, {
        'id': 'med_neg_2',
        'medicineId': 'med_neg_2',
        'pool': lahore.key,
        'branchId': 'lahore',
        'name': 'Amoxicillin',
        'base': -200.0,
        'quantityRaw': -200.0,
        'quantity': 0.0,
        'rev': 1,
      });

      // Adding 1 without calling sanitizeNegatives manually first
      await StockActions.restock(lahore, 'med_neg_2', 1.0, ref: 'proforma_test');
      final item = StockLedger.item(lahore.key, 'med_neg_2')!;
      expect((item['quantity'] as num).toDouble(), 1.0);
      expect((item['quantityRaw'] as num).toDouble(), 1.0);
    });

    test('large negative movement clamps running quantity at 0 and later restock adds onto 0', () async {
      await StockActions.restock(lahore, 'med_floor', 5.0, ref: 'init');
      await Future.delayed(const Duration(milliseconds: 5));

      await StockActions.countDifference(lahore, 'med_floor', -100.0, reason: 'test over-deduct');
      final afterDeduct = StockLedger.item(lahore.key, 'med_floor')!;
      expect((afterDeduct['quantity'] as num).toDouble(), 0.0);
      expect((afterDeduct['quantityRaw'] as num).toDouble(), 0.0);

      await Future.delayed(const Duration(milliseconds: 5));
      await StockActions.restock(lahore, 'med_floor', 12.0, ref: 'proforma');
      final afterRestock = StockLedger.item(lahore.key, 'med_floor')!;
      expect((afterRestock['quantity'] as num).toDouble(), 12.0);
      expect((afterRestock['quantityRaw'] as num).toDouble(), 12.0);
    });

    test('StockCloud.mergeIntoDoc and applyCloudDoc never produce or import negative quantities', () async {
      final t1 = DateTime.utc(2026, 11, 21, 10, 0, 0);
      final t2 = DateTime.utc(2026, 11, 21, 10, 5, 0);

      final healedDoc = StockCloud.mergeIntoDoc(
        {'quantity': -200.0, 'rev': 4, 'lastOps': ['old_op']},
        [
          StockMovement(
            opId: 'rst_heal_1',
            pool: lahore.key,
            medicineId: 'med_cloud',
            delta: 50.0,
            kind: StockMoveKind.restock,
            at: t1,
            by: 'tester',
          ),
        ],
      )!;
      expect(healedDoc['quantity'], 50.0);
      expect(healedDoc['rev'], 5);

      final clampedDispenseDoc = StockCloud.mergeIntoDoc(
        {'quantity': 5.0, 'rev': 1, 'lastOps': <String>[]},
        [
          StockMovement(
            opId: 'disp_1',
            pool: lahore.key,
            medicineId: 'med_cloud',
            delta: -20.0,
            kind: StockMoveKind.count,
            at: t1,
            by: 'tester',
          ),
          StockMovement(
            opId: 'rst_2',
            pool: lahore.key,
            medicineId: 'med_cloud',
            delta: 7.0,
            kind: StockMoveKind.restock,
            at: t2,
            by: 'tester',
          ),
        ],
      )!;
      // max(0, 5 - 20) == 0, then 0 + 7 == 7
      expect(clampedDispenseDoc['quantity'], 7.0);

      await StockCloud.applyCloudDoc(
        lahore,
        'med_cloud_neg',
        {'quantity': -200.0, 'rev': 9, 'lastOps': ['op_prev'], 'name': 'CloudNeg'},
      );
      final imported = StockLedger.item(lahore.key, 'med_cloud_neg')!;
      expect((imported['base'] as num).toDouble(), 0.0);
      expect((imported['quantityRaw'] as num).toDouble(), 0.0);
      expect((imported['quantity'] as num).toDouble(), 0.0);
    });

    test('markDeleted zeroes balance and re-adding via restock restores clean positive stock', () async {
      final box = Hive.box(LocalStorageService.stockBox);
      final key = StockLedger.itemKey(lahore.key, 'med_del_neg');
      await box.put(key, {
        'id': 'med_del_neg',
        'medicineId': 'med_del_neg',
        'pool': lahore.key,
        'name': 'OldDeletedNeg',
        'base': -50.0,
        'quantityRaw': -50.0,
        'quantity': 0.0,
      });

      await StockLedger.markDeleted(lahore.key, 'med_del_neg');
      final deleted = StockLedger.item(lahore.key, 'med_del_neg')!;
      expect(deleted['deleted'], isTrue);
      expect((deleted['base'] as num).toDouble(), 0.0);

      await StockActions.restock(lahore, 'med_del_neg', 25.0, ref: 'proforma_readd');
      final restored = StockLedger.item(lahore.key, 'med_del_neg')!;
      expect(restored.containsKey('deleted'), isFalse);
      expect((restored['quantity'] as num).toDouble(), 25.0);
    });

    test('purgePool clears quantities, moves, dispense flags, and drift logs for target pool only', () async {
      await StockActions.restock(lahore, 'med_a', 30.0, ref: 'init');
      await StockActions.restock(khiHaji, 'med_b', 40.0, ref: 'init');

      final flags = Hive.box('app_flags');
      await flags.put('stock_disp|${lahore.key}|001|uid1', '2026-11-21T10:00:00');
      await flags.put('stock_disp|${khiHaji.key}|002|uid2', '2026-11-21T10:00:00');

      final drift = Hive.box('stock_drift_log');
      await drift.put('d1', {'pool': lahore.key, 'medicineId': 'med_a'});
      await drift.put('d2', {'pool': khiHaji.key, 'medicineId': 'med_b'});

      final res = await StockLedger.purgePool(lahore.key, wipeId: 'wipe-lahore-1');
      expect(res.itemsRemoved, greaterThanOrEqualTo(1));
      expect(res.movesRemoved, greaterThanOrEqualTo(1));

      expect(StockLedger.item(lahore.key, 'med_a'), isNull);
      expect(flags.containsKey('stock_disp|${lahore.key}|001|uid1'), isFalse);
      expect(drift.containsKey('d1'), isFalse);

      // Other pool remains completely untouched
      expect((StockLedger.item(khiHaji.key, 'med_b')!['quantity'] as num).toDouble(), 40.0);
      expect(flags.containsKey('stock_disp|${khiHaji.key}|002|uid2'), isTrue);
      expect(drift.containsKey('d2'), isTrue);

      // Re-adding med_a after wipe starts clean at 15.0
      await StockActions.restock(lahore, 'med_a', 15.0, ref: 'post_wipe');
      expect((StockLedger.item(lahore.key, 'med_a')!['quantity'] as num).toDouble(), 15.0);
    });

    test('LAN server logs stock_wipe and patient_edit_approved for offline reconnect replay', () {
      expect(LanServer.isLoggedEventType('stock_wipe'), isTrue);
      expect(LanServer.isLoggedEventType('patient_edit_approved'), isTrue);
      expect(LanServer.isLoggedEventType('request_created'), isTrue);
      expect(LanServer.isLoggedEventType('request_approved'), isTrue);
      expect(LanServer.isLoggedEventType('restock_acknowledged'), isTrue);
    });
  });
}
