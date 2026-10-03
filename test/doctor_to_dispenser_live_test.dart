import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/realtime/realtime_router.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('doctor_dispenser_test_');
    Hive.init(tempDir.path);
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.medicineRestrictionsBox);
    await Hive.openBox('app_settings');
    await Hive.openBox('local_branches');
    await Hive.openBox('app_flags');
  });

  tearDownAll(() async {
    await Future.delayed(const Duration(milliseconds: 100));
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('Prescription from Doctor automatically inserts into Dispenser queue in entriesBox', () async {
    final entriesBox = Hive.box(LocalStorageService.entriesBox);

    final doctorPrescriptionPayload = {
      'event_type': RealtimeEvents.savePrescription,
      'branchId': 'karachi',
      'data': {
        'id': 'KHI-042',
        'serial': 'KHI-042',
        'branchId': 'karachi',
        'patientName': 'Muhammad Ali',
        'patientCnic': '42101-1234567-1',
        'doctorName': 'Dr. Tariq',
        'doctorId': 'doc_123',
        'daysOfMedicine': 3,
        'status': 'completed',
        'dispenseStatus': 'pending',
        'prescriptions': [
          {'name': 'Paracetamol 500mg', 'dosage': '1+1+1', 'days': 3, 'qty': 9}
        ],
        'completedAt': DateTime.now().toIso8601String(),
      }
    };

    // Route message through RealtimeRouter (as happens on Dispenser machine)
    await RealtimeRouter.routeMessage(doctorPrescriptionPayload);

    // Verify entries box has the completed entry under canonical key
    final entry = entriesBox.get('karachi-KHI-042') ?? entriesBox.get('karachi-khi-042');
    expect(entry, isNotNull);
    expect(entry['status'], equals('completed'));
    expect(entry['patientName'], equals('Muhammad Ali'));
    expect(entry['doctorName'], equals('Dr. Tariq'));
    expect(entry['prescription'], isNotNull);
  });

  test('CampSessionService allows Saddar branch to match Karachi camp tags', () {
    expect(CampSessionService.isSerialMatchingBranch('KHI-SADDAR-001', 'saddar'), isTrue);
    expect(CampSessionService.isSerialMatchingBranch('KHI-HAJI-005', 'karachi'), isTrue);
    expect(CampSessionService.isSerialMatchingBranch('021026-KAP-001', 'saddar'), isTrue);
    expect(CampSessionService.areBranchesMatching('saddar', 'karachi'), isTrue);
    expect(CampSessionService.areBranchesMatching('karachi', 'saddar'), isTrue);
  });

  test('Token routing: Receptionist save_entry routes cleanly into entriesBox and is retrievable by getLocalEntries', () async {
    final tokenPayload = {
      'event_type': 'token_created',
      'branchId': 'saddar',
      'data': {
        'serial': '101',
        'patientName': 'Zainab Bibi',
        'patientCnic': '42101-7654321-2',
        'queueType': 'zakat',
        'status': 'waiting',
      }
    };

    await RealtimeRouter.routeMessage(tokenPayload);

    final entries = LocalStorageService.getLocalEntries('saddar');
    final found = entries.any((e) => (e['serial'] ?? e['id']) == '101' && e['patientName'] == 'Zainab Bibi');
    expect(found, isTrue);
  });

  test('Fast startup: LocalStorageService.init completes without blocking delay', () async {
    final stopwatch = Stopwatch()..start();
    await LocalStorageService.init();
    stopwatch.stop();

    print('LocalStorageService.init() took: ${stopwatch.elapsedMilliseconds} ms');
    // Must complete synchronously in well under 1000ms
    expect(stopwatch.elapsedMilliseconds, lessThan(1000));
  });
}

