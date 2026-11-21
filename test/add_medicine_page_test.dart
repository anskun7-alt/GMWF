// test/add_medicine_page_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/pages/dispensary/dispensar/add_medicine_page.dart';
import 'package:gmwf/services/add_medicine_mode_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_add_med_page_test');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox(LocalStorageService.syncBox);
    await Hive.openBox(LocalStorageService.auditLogsBox);
    await Hive.openBox(LocalStorageService.stockBox);
    await Hive.openBox(StockLedger.movesBoxName);
    await Hive.openBox(MasterProformaService.boxName);
    StockLedger.resetCache();

    await Hive.box('app_settings').put('user_data', {
      'uid': 'disp-test-1',
      'username': 'Tester Dispenser',
      'role': 'dispenser',
    });
    await MasterProformaService.seedDefaultProformaIfEmpty();
  });

  tearDown(() async {
    StockLedger.resetCache();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [GComfortColors.light],
      ),
      home: child,
    );
  }

  testWidgets('Guided flow: hidden list until typed, scanner Enter, quick-add, no-expiry note, stock & log write',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const AddMedicinePage(
      branchId: 'gujrat',
      isDispenser: true,
      isAdmin: false,
      isEmbedded: true,
    )));
    await tester.pumpAndSettle();

    // Opens in Guided mode by default; no 175-row table visible until user types or toggles full list.
    expect(find.text('Guided'), findsWidgets);
    expect(find.text('Express'), findsWidgets);
    expect(find.text('Step 1: Find the medicine'), findsOneWidget);
    expect(find.text('Select'), findsNothing);

    // Search for something non-existent: Dispenser must NOT see "Register new medicine".
    final searchField = find.byType(TextField).first;
    await tester.enterText(searchField, 'zzznonexistent999');
    await tester.pumpAndSettle();
    expect(find.text('No medicine found for "zzznonexistent999"'), findsOneWidget);
    expect(find.text('Register new medicine'), findsNothing);

    // Scan exact barcode '079' (Metronidazole / Flagyl 200 mg) and press Enter -> opens Step 2 immediately.
    await tester.enterText(searchField, '079');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // Now on Step 2: quantity starts blank, amber no-expiry note is visible, button disabled.
    expect(find.text('Quantity to add (optional)'), findsOneWidget);
    expect(find.text('No expiry date set. Expiry alerts will not work for this batch.'), findsOneWidget);
    expect(find.text('Enter quantity or expiry date'), findsOneWidget);

    // Tap +100 quick-add chip -> live calculation + "(no expiry)" button label.
    await tester.tap(find.text('+100'));
    await tester.pumpAndSettle();
    expect(find.text('Stock after adding: 0 + 100 = 100'), findsOneWidget);
    expect(find.text('Add 100 to Stock (no expiry)'), findsOneWidget);

    // Pick "1 year" expiry chip -> button label becomes "Add 100 to Stock".
    await tester.tap(find.text('1 year'));
    await tester.pumpAndSettle();
    expect(find.text('Add 100 to Stock'), findsOneWidget);

    // Clearing quantity while expiry is set -> button label becomes "Save Expiry Date".
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Save Expiry Date'), findsOneWidget);

    // Re-add +50 and submit to stock.
    await tester.tap(find.text('+50'));
    await tester.pumpAndSettle();
    expect(find.text('Add 50 to Stock'), findsOneWidget);

    await tester.tap(find.text('Add 50 to Stock'));
    await tester.pumpAndSettle();

    // Step 3 Done screen shows new stock count.
    expect(find.text('Added to Stock!'), findsOneWidget);
    expect(find.text('New stock: 50'), findsOneWidget);

    // Verify existing StockLedger + audit_logs + sync_box received the exact writes.
    final pool = StockPool.of('gujrat', null)!;
    final batches = StockReader.batches(pool);
    expect(batches.length, 1);
    expect(StockReader.qty(batches.first), 50.0);

    final logs = LocalStorageService.getLocalInventoryLogs(branchId: 'gujrat');
    expect(logs.length, 1);
    expect(logs.first['action'], 'add_from_proforma');
    expect(logs.first['quantityAdded'], 50);

    final syncBox = Hive.box(LocalStorageService.syncBox);
    expect(
      syncBox.values.where((v) => v is Map && v['type'] == 'save_inventory_log').length,
      1,
    );

    // Returning via "Add another medicine" displays "Added in this session (1)".
    await tester.tap(find.text('Add another medicine'));
    await tester.pumpAndSettle();
    expect(find.text('Added in this session (1)'), findsOneWidget);
  });

  testWidgets('Express flow: scanner adds & clears, preserves list across mode switch, full list toggle, admin register',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await Hive.box('app_settings').put('user_data', {
      'uid': 'admin-test-1',
      'username': 'HQ Admin',
      'role': 'hq manager',
    });

    await tester.pumpWidget(wrap(const AddMedicinePage(
      branchId: 'gujrat',
      isDispenser: false,
      isAdmin: true,
      isEmbedded: true,
    )));
    await tester.pumpAndSettle();

    // Admin sees "Register new medicine" on empty search.
    await tester.enterText(find.byType(TextField).first, 'zzznonexistent999');
    await tester.pumpAndSettle();
    expect(find.text('Register new medicine'), findsOneWidget);

    // Switch to Express via top segmented switch -> saves preferred mode immediately.
    await tester.tap(find.text('Express').first);
    await tester.pumpAndSettle();
    expect(AddMedicineModeService.getPreferredMode(), AddMedicineMode.express);
    expect(find.text('Your list (0)'), findsOneWidget);

    // Scan barcode '079' + Enter -> adds to "Your list (1)" and clears search box.
    final expressSearch = find.byType(TextField).first;
    await tester.enterText(expressSearch, '079');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Your list (1)'), findsOneWidget);
    expect((tester.widget<TextField>(expressSearch)).controller!.text, isEmpty);

    // Switch to Guided and back to Express -> picked item in Express is preserved!
    await tester.tap(find.text('Guided').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Express').first);
    await tester.pumpAndSettle();
    expect(find.text('Your list (1)'), findsOneWidget);

    // Toggle "Show full list" reveals type filter pills.
    await tester.tap(find.textContaining('Show full list'));
    await tester.pumpAndSettle();
    expect(find.text('Tablet'), findsWidgets);
    expect(find.text('Syrup'), findsWidgets);
    expect(find.text('Consumables'), findsWidgets);
  });
}
