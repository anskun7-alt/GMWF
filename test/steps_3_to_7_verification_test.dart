import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/branch_record_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Pillar 3 & Pillar 5 - Role-Based Box Sets & Canonical Keys', () {
    test('getBoxesForRoles resolves correct union of boxes for roles', () {
      final dispensaryBoxes = LocalStorageService.getBoxesForRoles(['dispensar', 'doctor']);
      expect(dispensaryBoxes.contains('app_settings'), isTrue);
      expect(dispensaryBoxes.contains('local_patients'), isTrue);
      expect(dispensaryBoxes.contains('local_stock_items'), isTrue);
      // Shouldn't load school or finance boxes for pure dispensary
      expect(dispensaryBoxes.contains('local_school_teachers'), isFalse);
      expect(dispensaryBoxes.contains('org_chart_of_accounts'), isFalse);

      final madrassaBoxes = LocalStorageService.getBoxesForRoles(['madrassa_teacher']);
      expect(madrassaBoxes.contains('local_madrassa_students'), isTrue);
      expect(madrassaBoxes.contains('local_madrassa_fees'), isTrue);
      expect(madrassaBoxes.contains('local_patients'), isFalse);

      final multiRoleBoxes = LocalStorageService.getBoxesForRoles(['dispensar', 'madrassa_teacher']);
      expect(multiRoleBoxes.contains('local_patients'), isTrue);
      expect(multiRoleBoxes.contains('local_madrassa_students'), isTrue);
      expect(multiRoleBoxes.contains('local_madrassa_fees'), isTrue);

      final adminBoxes = LocalStorageService.getBoxesForRoles(['admin']);
      expect(adminBoxes.contains('local_patients'), isTrue);
      expect(adminBoxes.contains('local_madrassa_students'), isTrue);
      expect(adminBoxes.contains('org_chart_of_accounts'), isTrue);
    });

    test('getBoxesForRoles resolves all doctor, clinic, and hybrid roles properly', () {
      final docBoxes = LocalStorageService.getBoxesForRoles(['doc']);
      expect(docBoxes.contains(LocalStorageService.prescriptionsBox), isTrue);
      expect(docBoxes.contains(LocalStorageService.patientsBox), isTrue);
      expect(docBoxes.contains(LocalStorageService.stockBox), isTrue);
      expect(docBoxes.contains(LocalStorageService.masterProformaBox), isTrue);

      final hybridBoxes = LocalStorageService.getBoxesForRoles(['doc+rec', 'clinic']);
      expect(hybridBoxes.contains(LocalStorageService.entriesBox), isTrue);
      expect(hybridBoxes.contains(LocalStorageService.prescriptionsBox), isTrue);
      expect(hybridBoxes.contains(LocalStorageService.medicineRestrictionsBox), isTrue);

      final invBoxes = LocalStorageService.getBoxesForRoles(['inventory']);
      expect(invBoxes.contains(LocalStorageService.stockBox), isTrue);
    });

    test('getCanonicalTokenKey and getCanonicalPatientKey return uniform format', () {
      final tokenKey = LocalStorageService.getCanonicalTokenKey('Gujrat_Main', 104);
      expect(tokenKey, equals('token_gujrat_main_104'));

      final patientKey = LocalStorageService.getCanonicalPatientKey('Karachi', 'PAT-9988', visitId: 'VIS-01');
      expect(patientKey, equals('local_patient_karachi_pat-9988_vis-01'));
    });

    test('Write locks correctly track active in-flight writes', () {
      const boxName = 'test_write_box';
      expect(LocalStorageService.hasActiveWriteLock(boxName), isFalse);

      LocalStorageService.acquireWriteLock(boxName);
      expect(LocalStorageService.hasActiveWriteLock(boxName), isTrue);

      LocalStorageService.acquireWriteLock(boxName);
      expect(LocalStorageService.hasActiveWriteLock(boxName), isTrue);

      LocalStorageService.releaseWriteLock(boxName);
      expect(LocalStorageService.hasActiveWriteLock(boxName), isTrue);

      LocalStorageService.releaseWriteLock(boxName);
      expect(LocalStorageService.hasActiveWriteLock(boxName), isFalse);
    });
  });

  group('Pillar 4 - LAN Health Hysteresis', () {
    test('isLanHealthyNotifier is initialized and reactive', () {
      expect(RealtimeManager.isLanHealthyNotifier.value, isFalse);
      
      bool notified = false;
      void listener() {
        notified = true;
      }

      RealtimeManager.isLanHealthyNotifier.addListener(listener);
      RealtimeManager.isLanHealthyNotifier.value = true;
      expect(notified, isTrue);
      expect(RealtimeManager().isLanHealthy, isTrue);

      RealtimeManager.isLanHealthyNotifier.value = false;
      expect(RealtimeManager().isLanHealthy, isFalse);
      RealtimeManager.isLanHealthyNotifier.removeListener(listener);
    });
  });

  group('Pillar 3 & 4 - BranchRecordService Peak & Zero-RAM Scan Verification', () {
    setUpAll(() async {
      final tempDir = await Directory.systemTemp.createTemp('hive_branch_peak_test_');
      Hive.init(tempDir.path);
      await Hive.openBox(LocalStorageService.branchCacheBox);
    });

    test('getBranchRecords operates without local_entries box being open', () {
      expect(Hive.isBoxOpen(LocalStorageService.entriesBox), isFalse);

      // Seed peak record in branch_data_cache directly
      final cacheBox = Hive.box(LocalStorageService.branchCacheBox);
      cacheBox.put('branch_peak_record_karachi|all', {
        'count': 120,
        'dateKey': '150126',
        'dateFormatted': '15-Jan-2026',
      });

      BranchRecordService.invalidateCache();
      final records = BranchRecordService.getBranchRecords('karachi', todayCount: 78);

      expect(records.peakRecord.count, equals(120));
      expect(records.todayTotal, equals(78));
      expect(records.isNewRecordToday, isFalse);
    });

    test('getBranchRecords updates peak when today count breaks all-time record', () {
      BranchRecordService.invalidateCache();
      final records = BranchRecordService.getBranchRecords('karachi', todayCount: 155);

      expect(records.peakRecord.count, equals(155));
      expect(records.todayTotal, equals(155));
      expect(records.isNewRecordToday, isTrue);

      // Verify persisted back to branch_data_cache
      final cacheBox = Hive.box(LocalStorageService.branchCacheBox);
      final raw = cacheBox.get('branch_peak_record_karachi|all');
      expect(raw, isNotNull);
      expect(raw['count'], equals(155));
    });
  });
}

