import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GIcons;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/Pages/dispensary/dispensar/inventory.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/realtime/realtime_router.dart';
import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_movement.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_sync.dart';
import 'package:gmwf/services/stock/stock_wipe_service.dart';
import 'package:gmwf/widgets/nexus_server_dashboard/nexus_more_views.dart';

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('gmwf_stock_wipe_test_');
    Hive.init(tmpDir.path);
    await Hive.openBox(LocalStorageService.stockBox);
    await Hive.openBox(StockLedger.movesBoxName);
    await Hive.openBox('app_flags');
    await Hive.openBox(LocalStorageService.syncBox);
    await Hive.openBox('server_sync_queue');
    await Hive.openBox('realtime_outbox');
    await Hive.openBox('realtime_failed_outbox');
    await Hive.openBox(LocalStorageService.syncMetaBox);
    await Hive.openBox('stock_quarantine');
    await Hive.openBox<String>('realtime_dedup_ids');
    await Hive.openBox<int>('realtime_entity_versions');
    await Hive.openBox('app_settings');
    await Hive.openBox(LocalStorageService.branchesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.entriesBox);
  });

  tearDown(() async {
    for (final name in [
      LocalStorageService.stockBox,
      StockLedger.movesBoxName,
      'app_flags',
      LocalStorageService.syncBox,
      'server_sync_queue',
      'realtime_outbox',
      'realtime_failed_outbox',
      LocalStorageService.syncMetaBox,
      'stock_quarantine',
      'app_settings',
      LocalStorageService.branchesBox,
    ]) {
      if (Hive.isBoxOpen(name)) await Hive.box(name).clear();
    }
    if (Hive.isBoxOpen('realtime_dedup_ids')) {
      await Hive.box<String>('realtime_dedup_ids').clear();
    }
    if (Hive.isBoxOpen('realtime_entity_versions')) {
      await Hive.box<int>('realtime_entity_versions').clear();
    }
    StockLedger.resetCache();
    StockSync.serverBroadcast = null;
    StockSync.serverSendTo = null;
  });

  tearDownAll(() async {
    if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
      DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox)).dispose();
    }
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      if (tmpDir.existsSync()) {
        await tmpDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('purgePool hard-deletes ledger items, legacy keys, moves, and quarantine for target pool only', () async {
    final saddar = StockPool.fromKey('karachi/saddar')!;
    final haji = StockPool.fromKey('karachi/haji_camp')!;

    // Seed normal ledger records + movements in both camps
    await StockLedger.saveDetails(saddar.key, 'saddar--med-1', {
      'name': 'Carminative Mixture (Colic Syrup)',
      'type': 'Syrup',
      'dose': '15 ml',
      'expiryDate': '2027-09-24',
    });
    await StockLedger.record(StockMovement(
      opId: 'op_saddar_1',
      pool: saddar.key,
      medicineId: 'saddar--med-1',
      delta: 50,
      kind: StockMoveKind.restock,
      at: DateTime.now(),
      name: 'Carminative Mixture (Colic Syrup)',
    ));
    await StockLedger.saveDetails(haji.key, 'hajicamp--med-1', {
      'name': 'Paracetamol',
      'type': 'Tablet',
      'dose': '500 mg',
      'expiryDate': '2027-09-03',
    });
    await StockLedger.record(StockMovement(
      opId: 'op_haji_1',
      pool: haji.key,
      medicineId: 'hajicamp--med-1',
      delta: 100,
      kind: StockMoveKind.restock,
      at: DateTime.now(),
      name: 'Paracetamol',
    ));

    // Also inject a legacy stock: key and a malformed key whose medicineId mismatches
    final stockBox = Hive.box(LocalStorageService.stockBox);
    await stockBox.put('stock:saddar--legacy-1', {
      'id': 'saddar--legacy-1',
      'branchId': 'karachi',
      'campId': 'saddar',
      'name': 'Omeprazole (Risek)',
      'quantity': 10,
    });
    await stockBox.put('karachi/saddar|odd_key_with_mismatch', {
      'id': 'different_id',
      'pool': 'karachi/saddar',
      'name': 'Ghost Med',
    });

    final res = await StockLedger.purgePool(saddar.key, wipeId: 'w_test_1');

    expect(res.itemsRemoved, 3);
    expect(res.movesRemoved, 1);
    expect(StockLedger.items(pool: saddar.key, includeDeleted: true), isEmpty);
    expect(stockBox.containsKey('stock:saddar--legacy-1'), isFalse);
    expect(stockBox.containsKey('karachi/saddar|odd_key_with_mismatch'), isFalse);
    expect(StockLedger.poolWipeId(saddar.key), 'w_test_1');

    // Haji Camp stays 100% untouched
    expect(StockLedger.items(pool: haji.key).length, 1);
    expect(StockLedger.quantityOf(haji.key, 'hajicamp--med-1'), 100);
    expect(StockLedger.poolWipeId(haji.key), isNull);
  });

  test('purgeStockQueues removes all stock/inventory queue types for target pool only', () async {
    final saddar = StockPool.fromKey('karachi/saddar')!;
    final syncBox = Hive.box(LocalStorageService.syncBox);
    final outbox = Hive.box('realtime_outbox');

    await syncBox.put('k1', {
      'type': 'register_medicine',
      'branchId': 'karachi',
      'campId': 'saddar',
      'medicineId': 'saddar--brufen',
      'data': {'name': 'Ibuprofen', 'campId': 'saddar'},
    });
    await syncBox.put('k2', {
      'type': 'relay_cloud_write',
      'branchId': 'karachi',
      'data': {'path': 'branches/karachi/inventory_saddar/saddar--brufen'},
    });
    await syncBox.put('k3', {
      'type': 'register_medicine',
      'branchId': 'karachi',
      'campId': 'haji_camp',
      'medicineId': 'hajicamp--panadol',
      'data': {'name': 'Panadol', 'campId': 'haji_camp'},
    });
    await syncBox.put('k4', {
      'type': 'save_patient',
      'branchId': 'karachi',
      'data': {'name': 'Ali'},
    });
    await outbox.put('o1', {
      'event_type': 'stock_moves',
      'branchId': 'karachi',
      'data': {
        'moves': [
          {'opId': 'm1', 'pool': 'karachi/saddar', 'medicineId': 'saddar--med-1', 'delta': -1},
        ],
      },
    });
    await outbox.put('o2', {
      'event_type': 'stock_details',
      'branchId': 'karachi',
      'data': {'pool': 'karachi/haji_camp', 'medicineId': 'hajicamp--panadol'},
    });

    final purged = await StockLedger.purgeStockQueues(saddar);

    expect(purged, 3);
    expect(syncBox.containsKey('k1'), isFalse);
    expect(syncBox.containsKey('k2'), isFalse);
    expect(syncBox.containsKey('k3'), isTrue); // Haji Camp kept
    expect(syncBox.containsKey('k4'), isTrue); // Non-inventory kept
    expect(outbox.containsKey('o1'), isFalse);
    expect(outbox.containsKey('o2'), isTrue); // Haji Camp kept
  });

  test('negative dispense movement for wiped/missing batch never creates phantom Qty-0 no-expiry row', () async {
    const poolKey = 'karachi/saddar';

    await StockLedger.applyRemote([
      StockMovement(
        opId: 'disp_ghost_1',
        pool: poolKey,
        medicineId: 'saddar--carminative',
        delta: -1,
        kind: StockMoveKind.dispense,
        at: DateTime.now(),
        name: 'Carminative Mixture (Colic Syrup)',
      ),
    ]);

    // No phantom row created in local_stock_items!
    expect(StockLedger.items(pool: poolKey), isEmpty);
    expect(StockLedger.item(poolKey, 'saddar--carminative'), isNull);
    // Movement is still retained in stock_moves_v1 so real stock details arriving later deduct properly
    expect(StockLedger.hasMovement('disp_ghost_1'), isTrue);

    await StockLedger.applyBase(
      pool: poolKey,
      medicineId: 'saddar--carminative',
      base: 10,
      rev: 1,
      baseOps: const [],
      details: {'name': 'Carminative Mixture (Colic Syrup)', 'expiryDate': '2027-09-24'},
    );
    expect(StockLedger.quantityOf(poolKey, 'saddar--carminative'), 9);
  });

  test('repeated stock_wipe broadcasts via RealtimeRouter are never dropped as duplicates', () async {
    final saddar = StockPool.fromKey('karachi/saddar')!;

    // First wipe
    await StockLedger.saveDetails(saddar.key, 'med1', {'name': 'Med 1'});
    final msg1 = StockSync.buildWipePayload(saddar, 'w_first', DateTime.now().millisecondsSinceEpoch);
    await RealtimeRouter.routeMessage(msg1);
    expect(StockLedger.items(pool: saddar.key), isEmpty);
    expect(StockLedger.poolWipeId(saddar.key), 'w_first');

    // Re-add a medicine, then issue a SECOND wipe within seconds (used to be dropped as duplicate!)
    await StockLedger.saveDetails(saddar.key, 'med2', {'name': 'Med 2'});
    expect(StockLedger.items(pool: saddar.key).length, 1);

    final msg2 = StockSync.buildWipePayload(saddar, 'w_second', DateTime.now().millisecondsSinceEpoch);
    expect(msg2['_messageId'], isNot(equals(msg1['_messageId'])));
    expect(msg2['_serverPush'], isTrue);
    await RealtimeRouter.routeMessage(msg2);
    expect(StockLedger.items(pool: saddar.key), isEmpty);
    expect(StockLedger.poolWipeId(saddar.key), 'w_second');
  });

  test('stale pre-wipe moves and details are rejected by wipe epoch guard', () async {
    const poolKey = 'karachi/saddar';
    await StockLedger.purgePool(poolKey, wipeId: 'w_after');

    // Incoming pre-wipe stock_moves (no wipeId or old wipeId) must be dropped!
    await StockSync.handle(StockSync.evMoves, {
      'event_type': StockSync.evMoves,
      'branchId': 'karachi',
      'data': {
        'moves': [
          StockMovement(
            opId: 'stale_restock_1',
            pool: poolKey,
            medicineId: 'saddar--risek',
            delta: 50,
            kind: StockMoveKind.restock,
            at: DateTime.now(),
            name: 'Omeprazole (Risek)',
          ).toMap(),
        ],
        'wipeEpochs': {poolKey: ''},
      },
    });
    expect(StockLedger.items(pool: poolKey), isEmpty);

    // Incoming pre-wipe stock_details must also be dropped!
    await StockSync.handle(StockSync.evDetails, {
      'event_type': StockSync.evDetails,
      'branchId': 'karachi',
      'data': {
        'pool': poolKey,
        'medicineId': 'saddar--risek',
        'details': {'name': 'Omeprazole (Risek)'},
        'wipeId': 'w_old',
      },
    });
    expect(StockLedger.items(pool: poolKey), isEmpty);

    // Post-wipe move with matching wipeId succeeds!
    await StockSync.handle(StockSync.evDetails, {
      'event_type': StockSync.evDetails,
      'branchId': 'karachi',
      'data': {
        'pool': poolKey,
        'medicineId': 'saddar--fresh',
        'details': {'name': 'Fresh Med', 'expiryDate': '2028-01-01'},
        'wipeId': 'w_after',
      },
    });
    expect(StockLedger.items(pool: poolKey).length, 1);
  });

  test('applySnapshot purges stale items when remote wipeEpochs advances, even with 0 items', () async {
    const poolKey = 'karachi/saddar';
    await StockLedger.saveDetails(poolKey, 'med_a', {'name': 'Med A'});
    await StockLedger.saveDetails(poolKey, 'med_b', {'name': 'Med B'});
    expect(StockLedger.items(pool: poolKey).length, 2);

    // Server sends empty snapshot carrying its new wipe epoch
    await StockLedger.applySnapshot({
      'items': const [],
      'moves': const [],
      'wipeEpochs': {poolKey: 'w_new_epoch'},
    });

    expect(StockLedger.items(pool: poolKey), isEmpty);
    expect(StockLedger.poolWipeId(poolKey), 'w_new_epoch');

    // Second chunk with same wipe epoch must NOT wipe items added by chunk 1
    await StockLedger.applySnapshot({
      'items': [
        {'pool': poolKey, 'medicineId': 'med_new', 'name': 'New Med', 'base': 20, 'rev': 1, 'baseOps': const []},
      ],
      'moves': const [],
      'wipeEpochs': {poolKey: 'w_new_epoch'},
    });
    expect(StockLedger.items(pool: poolKey).length, 1);
    expect(StockLedger.quantityOf(poolKey, 'med_new'), 20);
  });

  test('applyRemoteWipe clears local stock, movements, and pending queues together', () async {
    const poolKey = 'karachi/saddar';
    await StockLedger.saveDetails(poolKey, 'med_x', {'name': 'Med X'});
    await Hive.box(LocalStorageService.syncBox).put('q_saddar', {
      'type': 'update_inventory',
      'branchId': 'karachi',
      'campId': 'saddar',
      'medicineId': 'saddar--med-x',
    });

    final res = await StockWipeService.applyRemoteWipe(poolKey, wipeId: 'w_remote_1');
    expect(res.itemsRemoved, 1);
    expect(res.queuePurged, 1);
    expect(StockLedger.items(pool: poolKey), isEmpty);
    expect(Hive.box(LocalStorageService.syncBox).containsKey('q_saddar'), isFalse);
    expect(StockLedger.poolWipeId(poolKey), 'w_remote_1');
  });

  testWidgets('Inventory Wipe panel uses single password field unlocked by admin123', (tester) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NexusSettingsView(
            branchId: 'karachi',
            multiServerControl: SizedBox.shrink(),
            biometricDeviceManager: SizedBox.shrink(),
            pythonTerminal: SizedBox.shrink(),
            dataVaultViewer: SizedBox.shrink(),
          ),
        ),
      ),
    );

    // Switch to Inventory Wipe sub-tab
    await tester.tap(find.text('Inventory Wipe'));
    await tester.pumpAndSettle();

    // Only ONE password field — Confirm Password must NOT exist
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('Confirm Password'), findsNothing);
    expect(find.text('Password'), findsOneWidget);

    // Wrong password shows error
    await tester.enterText(find.byType(TextFormField), 'wrongpass');
    await tester.tap(find.text('Verify & Unlock Wipe'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect password.'), findsOneWidget);
    expect(find.text('🗑  WIPE ALL INVENTORY DETAILS'), findsNothing);

    // Correct password 'admin123' unlocks wipe immediately
    await tester.enterText(find.byType(TextFormField), 'admin123');
    await tester.tap(find.text('Verify & Unlock Wipe'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect password.'), findsNothing);
    expect(find.text('🗑  WIPE ALL INVENTORY DETAILS'), findsOneWidget);
  });

  testWidgets('Doctor InventoryPage exposes Refresh action in empty state, AppBar, and toolbar', (tester) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.runAsync(() async {
      // Prime CampSessionService in real async so it never triggers an unawaited Hive.put
      // on app_settings inside FakeAsync during widget build.
      CampSessionService.getActiveCamp('karachi');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    // 1. Empty state shows Refresh Inventory button + AppBar refresh icon
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light().copyWith(extensions: const [GComfortColors.light]),
        home: const InventoryPage(
          branchId: 'karachi',
          isDoctor: true,
          isSupervisor: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Refresh Inventory'), findsOneWidget);
    expect(find.byTooltip('Refresh inventory'), findsOneWidget);

    // 2. Populated state shows Refresh button right beside PDF in toolbar
    await tester.runAsync(() async {
      final activePool = StockPool.current('karachi') ?? StockPool.fromKey('karachi/saddar')!;
      await StockLedger.saveDetails(activePool.key, 'med-1', {
        'name': 'Paracetamol',
        'type': 'Tablet',
        'dose': '500 mg',
        'expiryDate': '2027-09-03',
      });
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Refresh'), findsOneWidget);
    expect(find.byTooltip('Fetch latest inventory from server / cloud'), findsOneWidget);
    expect(find.byTooltip('Refresh inventory'), findsOneWidget);

    // Lower-level user (Doctor) must NEVER see Higher Authority Controls or executive bars
    expect(find.text('Higher Authority Controls'), findsNothing);
    expect(find.text('Hidden from lower-level users'), findsNothing);
    expect(find.text('Camp:'), findsNothing);
    expect(find.text('Remove by Barcodes'), findsNothing);
    expect(find.text('Remove Unbarcoded Meds'), findsNothing);
    expect(find.text('Wipe Selected Pool'), findsNothing);

    // Dispose InventoryPage cleanly so its timers/subscriptions cancel before tearDown
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('resolveOfficialBarcodeForStockItem validates official GMWF barcodes and flags unbarcoded/non-proforma items', () {
    final official = MasterProformaService.getOfficialBarcodes();
    expect(official, isNotEmpty);

    // All 7 Saddar target barcodes exist in the official GMWF Master Proforma
    for (final code in const ['012', '040', '046', '053', '059', '063', '071']) {
      expect(official.contains(code), isTrue, reason: 'Expected $code in official proforma');
      expect(
        MasterProformaService.resolveOfficialBarcodeForStockItem(
          {'name': 'Proforma Med', 'barcode': code, 'isCustomized': true},
          officialBarcodes: official,
        ),
        code,
      );
    }

    // Blank / missing barcode, EAN barcode, and non-proforma code must return null
    expect(
      MasterProformaService.resolveOfficialBarcodeForStockItem(
        {'name': '', 'barcode': ''},
        officialBarcodes: official,
      ),
      isNull,
    );
    expect(
      MasterProformaService.resolveOfficialBarcodeForStockItem(
        {'name': 'Custom Mystery Tablet', 'barcode': '', 'type': 'Tablet', 'dose': '10 mg'},
        officialBarcodes: official,
      ),
      isNull,
    );
    expect(
      MasterProformaService.resolveOfficialBarcodeForStockItem(
        {'name': 'External Pack Med', 'barcode': '8964000123456', 'isCustomized': true},
        officialBarcodes: official,
      ),
      isNull,
    );
    final unusedCode = List.generate(999, (i) => (i + 1).toString().padLeft(3, '0'))
        .firstWhere((c) => !official.contains(c));
    expect(
      MasterProformaService.resolveOfficialBarcodeForStockItem(
        {'name': 'Unofficial Code Med', 'barcode': unusedCode, 'isCustomized': true},
        officialBarcodes: official,
      ),
      isNull,
    );
  });

  test('scanUnbarcodedMedicines finds only unbarcoded/non-proforma items across all branches & camps', () async {
    final saddar = StockPool.fromKey('karachi/saddar')!;
    final haji = StockPool.fromKey('karachi/haji_camp')!;
    final gujrat = StockPool.fromKey('gujrat')!;

    // Valid official-barcode items (must NOT be flagged)
    await StockLedger.saveDetails(saddar.key, 'saddar--valid-002', {
      'name': 'Activated Attapulgite',
      'barcode': '002',
      'type': 'Tablet',
      'dose': '50 mg',
    });
    await StockLedger.saveDetails(haji.key, 'haji--valid-063', {
      'name': 'Paracetamol (Panadol)',
      'barcode': '063',
      'type': 'Tablet',
      'dose': '500 mg',
    });

    // Unbarcoded / non-proforma items across all 3 pools (MUST be flagged)
    await StockLedger.saveDetails(saddar.key, 'saddar--blank', {
      'name': '',
      'barcode': '',
      'type': '',
      'dose': '',
    });
    await StockLedger.saveDetails(haji.key, 'haji--unbarcoded', {
      'name': 'Bcomplex 2cc Custom',
      'barcode': '',
      'type': 'Injection',
      'isCustomized': true,
    });
    await StockLedger.saveDetails(gujrat.key, 'gujrat--ean', {
      'name': 'External Syrup',
      'barcode': '8961100998877',
      'type': 'Syrup',
      'isCustomized': true,
    });

    final scan = await StockWipeService.scanUnbarcodedMedicines(
      pools: [saddar, haji, gujrat],
      includeCloud: false,
    );

    expect(scan.totalScanned, 5);
    expect(scan.matches.map((m) => '${m.pool.key}|${m.medicineId}').toSet(), {
      'karachi/saddar|saddar--blank',
      'karachi/haji_camp|haji--unbarcoded',
      'gujrat|gujrat--ean',
    });
  });

  test('hardDeleteItem and StockSync hardDelete remove only targeted Saddar batches', () async {
    final saddar = StockPool.fromKey('karachi/saddar')!;
    final haji = StockPool.fromKey('karachi/haji_camp')!;

    await StockLedger.saveDetails(saddar.key, 'saddar--012', {'name': 'Calcium', 'barcode': '012'});
    await StockLedger.record(StockMovement(
      opId: 'm_012',
      pool: saddar.key,
      medicineId: 'saddar--012',
      delta: 20,
      kind: StockMoveKind.restock,
      at: DateTime.now(),
    ));
    await StockLedger.saveDetails(saddar.key, 'saddar--040', {'name': 'Ibuprofen (Brufen)', 'barcode': '040'});
    await StockLedger.saveDetails(saddar.key, 'saddar--002', {'name': 'Activated Attapulgite', 'barcode': '002'});
    await StockLedger.saveDetails(haji.key, 'haji--012', {'name': 'Calcium', 'barcode': '012'});

    // Direct local hard delete for 012 in Saddar
    expect(await StockLedger.hardDeleteItem(saddar.key, 'saddar--012'), isTrue);
    expect(StockLedger.item(saddar.key, 'saddar--012'), isNull);
    expect(StockLedger.hasMovement('m_012'), isFalse);

    // LAN hardDelete event for 040 in Saddar
    await StockSync.handle(StockSync.evDetails, {
      'event_type': StockSync.evDetails,
      'branchId': 'karachi',
      'data': {
        'pool': saddar.key,
        'medicineId': 'saddar--040',
        'deleted': true,
        'hardDelete': true,
      },
    });
    expect(StockLedger.item(saddar.key, 'saddar--040'), isNull);

    // Other Saddar meds and Haji Camp 012 stay completely untouched
    expect(StockLedger.item(saddar.key, 'saddar--002'), isNotNull);
    expect(StockLedger.item(haji.key, 'haji--012'), isNotNull);
  });

  testWidgets('HQ Manager InventoryPage uses top-bar branch strictly, shows Camp switcher for multi-camp branch, renames Proforma Sheet to Add Medicines, and matches Saddar barcodes', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.runAsync(() async {
      final box = Hive.box('app_settings');
      await box.put('user_data', {'role': 'hq manager', 'username': 'zaheer'});
      CampSessionService.getActiveCamp('karachi');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await StockLedger.saveDetails('karachi/saddar', 'saddar--012', {
        'name': 'Calcium',
        'barcode': '012',
        'type': 'Tablet',
        'dose': '500 mg',
        'expiryDate': '2027-09-03',
      });
      await StockLedger.saveDetails('karachi/saddar', 'saddar--040', {
        'name': 'Ibuprofen (Brufen)',
        'barcode': '040',
        'type': 'Tablet',
        'dose': '400 mg',
        'expiryDate': '2027-09-24',
      });
      await StockLedger.saveDetails('karachi/saddar', 'saddar--unbar', {
        'name': 'Mystery Junk Med',
        'barcode': '',
        'type': 'Tablet',
        'isCustomized': true,
      });
      await StockLedger.saveDetails('karachi/haji_camp', 'haji--063', {
        'name': 'Paracetamol (Panadol)',
        'barcode': '063',
        'type': 'Tablet',
        'dose': '500 mg',
        'expiryDate': '2027-09-03',
      });
      await StockLedger.saveDetails('jalalpurjattan', 'jpj--007', {
        'name': 'Aspirin',
        'barcode': '007',
        'type': 'Tablet',
        'dose': '75 mg',
        'expiryDate': '2027-10-01',
      });
    });

    // 1. When top-bar branch is 'karachi': shows ONLY Karachi items + Camp bar (NO duplicate branch picker)
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light().copyWith(extensions: const [GComfortColors.light]),
        home: const InventoryPage(branchId: 'karachi'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Branch & Camp:'), findsNothing);
    expect(find.text('Camp:'), findsOneWidget);
    expect(find.text('Higher Authority Controls'), findsOneWidget);
    expect(find.text('Hidden from lower-level users'), findsOneWidget);
    expect(find.text('Remove by Barcodes'), findsOneWidget);
    expect(find.text('Remove Unbarcoded Meds'), findsOneWidget);
    expect(find.text('Select & Delete'), findsOneWidget);
    expect(find.text('Wipe Selected Pool'), findsOneWidget);
    expect(find.text('No Barcode (1)'), findsOneWidget);
    // Proforma Sheet renamed to Add Medicines everywhere (sidebar + toolbar button)
    expect(find.text('Proforma Sheet'), findsNothing);
    expect(find.text('Add Medicines'), findsWidgets);
    // Must show Karachi meds cleanly without duplicate "(Calcium)" suffix, and NOT Jalal Pur Jattan's Aspirin
    expect(find.textContaining('Calcium', findRichText: true), findsWidgets);
    expect(find.textContaining('(Calcium)', findRichText: true), findsNothing);
    expect(find.textContaining('Aspirin', findRichText: true), findsNothing);
    // Reimagined row delete button uses GIcons.delete (NOT old Icons.delete_forever_rounded)
    expect(find.byTooltip('Remove medicine from inventory'), findsWidgets);
    expect(find.byIcon(GIcons.delete), findsWidgets);
    expect(find.byIcon(Icons.delete_forever_rounded), findsNothing);

    // Switch camp to Saddar Dispensary — scopes view to Saddar only
    final saddarChip = find.textContaining('Saddar').first;
    await tester.tap(saddarChip);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('Saddar Dispensary)'), findsWidgets);

    // Open Remove by Barcodes dialog and paste user's exact Name + Barcode list
    await tester.tap(find.text('Remove by Barcodes'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('Remove Medicines by Barcodes'), findsOneWidget);

    final dialogField = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(
      dialogField,
      'Calcium 012\nBrofen 040\nPostan 046\nFlagyl 053\nRisek 059\nPanadol 063\nDenzan DS 071',
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Only Saddar's 012 and 040 match (Haji Camp's 063 is NOT touched!)
    expect(find.textContaining('Matched 2 medicine row(s)'), findsOneWidget);
    expect(find.text('Remove (2)'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 450));

    // 2. When top-bar branch switches to 'jalalpurjattan': ONLY Jalal Pur Jattan data is shown, no redundant Camp bar
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light().copyWith(extensions: const [GComfortColors.light]),
        home: const InventoryPage(branchId: 'jalalpurjattan'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Camp:'), findsNothing);
    expect(find.text('Branch & Camp:'), findsNothing);
    expect(find.text('Higher Authority Controls'), findsOneWidget);
    expect(find.text('Add Medicines'), findsWidgets);
    expect(find.textContaining('Aspirin', findRichText: true), findsWidgets);
    expect(find.textContaining('Calcium', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
