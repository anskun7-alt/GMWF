// test/add_medicine_mode_service_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/services/add_medicine_mode_service.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_add_med_mode_test');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox(LocalStorageService.syncBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('defaults to Guided and shows first-run prompt for new user', () {
    expect(AddMedicineModeService.getPreferredMode('user_a'), AddMedicineMode.guided);
    expect(AddMedicineModeService.shouldShowFirstRunPrompt('user_a'), isTrue);
  });

  test('switching mode saves per-user in Hive and enqueues sync only when changed', () async {
    await AddMedicineModeService.setPreferredMode(
      AddMedicineMode.express,
      explicitUserKey: 'user_a',
      explicitUid: 'uid-a',
      branchId: 'karachi',
    );

    expect(AddMedicineModeService.getPreferredMode('user_a'), AddMedicineMode.express);
    expect(AddMedicineModeService.shouldShowFirstRunPrompt('user_a'), isFalse);
    // Isolated per user: user_b still defaults to Guided.
    expect(AddMedicineModeService.getPreferredMode('user_b'), AddMedicineMode.guided);

    final syncBox = Hive.box(LocalStorageService.syncBox);
    expect(syncBox.length, 1);
    final queued = Map<String, dynamic>.from(syncBox.values.first as Map);
    expect(queued['type'], 'save_user_preference');
    expect(queued['uid'], 'uid-a');
    expect((queued['data'] as Map)['addMedicineMode'], 'express');

    // Setting the same mode again must NOT enqueue a duplicate write.
    await AddMedicineModeService.setPreferredMode(
      AddMedicineMode.express,
      explicitUserKey: 'user_a',
      explicitUid: 'uid-a',
      branchId: 'karachi',
    );
    expect(syncBox.length, 1);
  });

  test('dismissing first-run prompt keeps Guided and hides prompt', () async {
    await AddMedicineModeService.dismissFirstRunPrompt(explicitUserKey: 'user_c');
    expect(AddMedicineModeService.getPreferredMode('user_c'), AddMedicineMode.guided);
    expect(AddMedicineModeService.shouldShowFirstRunPrompt('user_c'), isFalse);
    expect(Hive.box(LocalStorageService.syncBox).isEmpty, isTrue);
  });

  test('picks up synced addMedicineMode from cached user_data without Firestore reads', () async {
    await Hive.box('app_settings').put('user_data', {
      'uid': 'uid-synced',
      'addMedicineMode': 'express',
    });
    expect(AddMedicineModeService.getPreferredMode(), AddMedicineMode.express);
    expect(AddMedicineModeService.shouldShowFirstRunPrompt(), isFalse);
  });
}
