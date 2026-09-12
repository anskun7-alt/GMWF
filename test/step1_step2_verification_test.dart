import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/cloud_messaging_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_step1_2_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Pillar 1: Cloud Messaging & Notifications', () {
    test('Bilingual notification builders return English and Urdu content', () {
      final reportNotif = CloudMessagingService.buildDailyReportNotification('Ali');
      expect(reportNotif['title_en'], contains('Daily Report Available'));
      expect(reportNotif['title_ur'], contains('روزانہ رپورٹ'));
      expect(reportNotif['body_en'], contains('Ali'));
      expect(reportNotif['body_ur'], contains('Ali'));

      final feeNotif = CloudMessagingService.buildFeePaymentNotification('Fatima', 5000, 0);
      expect(feeNotif['title_en'], equals('Payment Received'));
      expect(feeNotif['title_ur'], equals('ادائیگی موصول ہو گئی'));
      expect(feeNotif['body_en'], contains('Rs. 5000'));
      expect(feeNotif['body_ur'], contains('5000'));

      final leaveNotif = CloudMessagingService.buildLeaveRequestNotification(
        studentName: 'Zayd',
        reason: 'Family event',
        startDate: '2026-09-10',
      );
      expect(leaveNotif['title_en'], contains('New Leave Request: Zayd'));
      expect(leaveNotif['title_ur'], contains('چھٹی کی نئی درخواست: Zayd'));
      expect(leaveNotif['body_en'], contains('Family event'));
      expect(leaveNotif['body_ur'], contains('Family event'));

      final replyNotif = CloudMessagingService.buildGuardianReplyNotification(
        studentName: 'Zayd',
        guardianName: 'Ahmad (Father)',
        replySnippet: 'Acknowledged and signed',
      );
      expect(replyNotif['title_en'], contains('Parent Replied: Zayd'));
      expect(replyNotif['title_ur'], contains('والدین کا جواب: Zayd'));
      expect(replyNotif['body_en'], contains('Acknowledged and signed'));
    });

    test('Idempotency guard prevents duplicate notification dispatches', () async {
      await Hive.openBox('app_settings');
      
      final firstSend = await CloudMessagingService.shouldSendNotification(
        flagKey: 'dues_cleared',
        entityId: 'student_123',
      );
      expect(firstSend, isTrue);

      final secondSend = await CloudMessagingService.shouldSendNotification(
        flagKey: 'dues_cleared',
        entityId: 'student_123',
      );
      expect(secondSend, isFalse);
    });
  });

  group('Pillar 2: Multi-Queue & Biometric Deduplication', () {
    test('Enqueueing multiple biometric punches for same employee same day retains all punches', () async {
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);

      // Punch 1 (Check-in at 09:00)
      await LocalStorageService.enqueueSync({
        'type': 'save_biometric_log',
        'branchId': 'karachi',
        'employeeId': 'emp_01',
        'date': '2026-09-06',
        'punchSequence': '1',
        'timestamp': '2026-09-06T09:00:00Z',
        'data': {'punchType': 'check_in'},
      });

      // Punch 2 (Break-out at 13:00)
      await LocalStorageService.enqueueSync({
        'type': 'save_biometric_log',
        'branchId': 'karachi',
        'employeeId': 'emp_01',
        'date': '2026-09-06',
        'punchSequence': '2',
        'timestamp': '2026-09-06T13:00:00Z',
        'data': {'punchType': 'break_out'},
      });

      // Punch 3 (Check-out at 18:00)
      await LocalStorageService.enqueueSync({
        'type': 'save_biometric_log',
        'branchId': 'karachi',
        'employeeId': 'emp_01',
        'date': '2026-09-06',
        'punchSequence': '3',
        'timestamp': '2026-09-06T18:00:00Z',
        'data': {'punchType': 'check_out'},
      });

      expect(syncBox.length, equals(3));
      expect(syncBox.containsKey('sync_att_karachi_emp_01_2026-09-06_1'), isTrue);
      expect(syncBox.containsKey('sync_att_karachi_emp_01_2026-09-06_2'), isTrue);
      expect(syncBox.containsKey('sync_att_karachi_emp_01_2026-09-06_3'), isTrue);
    });

    test('Dead letter queue safely moves failed queue entries', () async {
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);
      final deadLetterBox = await Hive.openBox(LocalStorageService.deadLetterQueueBox);

      final testKey = 'sync_att_karachi_emp_99_2026-09-06_1';
      final testItem = {
        'type': 'save_biometric_log',
        'branchId': 'karachi',
        'employeeId': 'emp_99',
        'attempts': 20,
      };

      await syncBox.put(testKey, testItem);
      expect(syncBox.containsKey(testKey), isTrue);

      await LocalStorageService.moveToDeadLetterQueue(
        LocalStorageService.syncBox,
        testKey,
        testItem,
        reason: 'Network Timeout (504)',
      );

      expect(syncBox.containsKey(testKey), isFalse);
      expect(deadLetterBox.containsKey(testKey), isTrue);
      final dlEntry = deadLetterBox.get(testKey);
      expect(dlEntry['deadLetterReason'], equals('Network Timeout (504)'));
      expect(dlEntry['sourceBox'], equals(LocalStorageService.syncBox));
    });

    test('purgeBloatedSyncQueue deduplicates duplicate actions and prunes corrupted entries', () async {
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);
      await syncBox.clear();

      // Add duplicate serial entries (older vs newer)
      await syncBox.put('legacy_1', {
        'type': 'save_entry',
        'branchId': 'karachi',
        'serial': '001',
        'dateKey': '060926',
        'data': {'patientName': 'Ali (Draft)'},
      });
      await syncBox.put('sync_serial_karachi_001', {
        'type': 'save_entry',
        'branchId': 'karachi',
        'serial': '001',
        'dateKey': '060926',
        'data': {'patientName': 'Ali (Final)'},
      });

      // Add corrupted / empty item
      await syncBox.put('corrupt_item', {'invalid': true});

      expect(syncBox.length, equals(3));

      final purged = await LocalStorageService.purgeBloatedSyncQueue();
      expect(purged, greaterThanOrEqualTo(2));
      expect(syncBox.length, equals(1));
      expect(syncBox.containsKey('sync_serial_karachi_001'), isTrue);
    });
  });
}
