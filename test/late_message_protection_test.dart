import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/realtime/realtime_router.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:hive/hive.dart';

/// Late, replayed or duplicated messages must never move data backwards or count stock twice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gmwf_late_msg_');
    Hive.init(dir.path);
    for (final b in [
      'app_settings',
      'app_flags',
      'dead_letter_queue',
      LocalStorageService.entriesBox,
      LocalStorageService.patientsBox,
      LocalStorageService.prescriptionsBox,
      LocalStorageService.syncBox,
      LocalStorageService.auditLogsBox,
    ]) {
      await Hive.openBox(b);
    }
  });

  tearDown(() async {
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  const branch = 'gujrat';
  const serial = '051126M-GUJ-007';

  Map<String, dynamic> entry(String status, {String? updatedAt, Map<String, dynamic>? extra}) => {
        'serial': serial,
        'branchId': branch,
        'dateKey': '051126',
        'session': 'morning',
        'patientId': 'p7',
        'patientName': 'Patient Seven',
        'status': status,
        if (updatedAt != null) 'updatedAt': updatedAt,
        ...?extra,
      };

  String? storedStatus() {
    final box = Hive.box(LocalStorageService.entriesBox);
    final v = box.get('$branch-$serial');
    return v is Map ? v['status']?.toString() : null;
  }

  group('token status only moves forward', () {
    test('a late "waiting" copy does not undo "in_consultation"', () async {
      await LocalStorageService.saveEntryLocal(branch, serial, entry('waiting', updatedAt: '2026-11-05T09:00:00'));
      await LocalStorageService.saveEntryLocal(
          branch, serial, entry('in_consultation', updatedAt: '2026-11-05T09:05:00'));
      // Replay of the original token (older)
      await LocalStorageService.saveEntryLocal(branch, serial, entry('waiting', updatedAt: '2026-11-05T09:00:00'));
      expect(storedStatus(), 'in_consultation');
    });

    test('a copy without any time does not undo progress either', () async {
      await LocalStorageService.saveEntryLocal(
          branch, serial, entry('in_consultation', updatedAt: '2026-11-05T09:05:00'));
      await LocalStorageService.saveEntryLocal(branch, serial, entry('waiting'));
      expect(storedStatus(), 'in_consultation');
    });

    test('a deliberate newer change back is allowed (doctor skips the patient)', () async {
      await LocalStorageService.saveEntryLocal(
          branch, serial, entry('in_consultation', updatedAt: '2026-11-05T09:05:00'));
      await LocalStorageService.saveEntryLocal(branch, serial, entry('skipped', updatedAt: '2026-11-05T09:06:00'));
      expect(storedStatus(), 'skipped');
    });

    test('completed is never reverted to waiting', () async {
      await LocalStorageService.saveEntryLocal(branch, serial, entry('completed', updatedAt: '2026-11-05T09:10:00'));
      await LocalStorageService.saveEntryLocal(branch, serial, entry('waiting', updatedAt: '2026-11-05T09:20:00'));
      expect(storedStatus(), 'completed');
    });

    test('a late cancellation does not cancel a dispensed patient', () async {
      await LocalStorageService.saveEntryLocal(branch, serial,
          entry('completed', updatedAt: '2026-11-05T09:10:00', extra: {'dispenseStatus': 'dispensed'}));
      await LocalStorageService.saveEntryLocal(branch, serial, entry('cancelled', updatedAt: '2026-11-05T09:20:00'));
      expect(storedStatus(), 'completed');
    });
  });

  group('stock operations apply once', () {
    test('an operation id is remembered (also across a reopen of the box)', () async {
      expect(await RealtimeRouter.stockOpAlreadyApplied('op-1'), isFalse);
      await RealtimeRouter.markStockOpApplied('op-1');
      expect(await RealtimeRouter.stockOpAlreadyApplied('op-1'), isTrue);
      await Hive.box('applied_stock_ops').close();
      expect(await RealtimeRouter.stockOpAlreadyApplied('op-1'), isTrue);
      expect(await RealtimeRouter.stockOpAlreadyApplied('op-2'), isFalse);
    });
  });

  group('prescriptions box keeps the newer prescription', () {
    Map<String, dynamic> rx(List<String> meds, String updatedAt) => {
          'serial': serial,
          'branchId': branch,
          'patientCnic': '3520112345671',
          'patientName': 'Patient Seven',
          'updatedAt': updatedAt,
          'completedAt': updatedAt,
          'prescriptions': [
            for (final m in meds) {'name': m, 'quantity': 1, 'timing': '1+0+1'}
          ],
        };

    List<String> storedMeds() {
      final v = Hive.box(LocalStorageService.prescriptionsBox).get('$branch-${serial.toUpperCase()}');
      final list = v is Map ? (v['prescriptions'] ?? v['medicines']) : null;
      return list is List ? list.map((m) => (m as Map)['name'].toString()).toList() : <String>[];
    }

    test('a late older copy does not replace the doctor\'s newer edit', () async {
      await LocalStorageService.saveLocalPrescription(rx(['Panadol'], '2026-11-05T09:00:00'));
      await LocalStorageService.saveLocalPrescription(rx(['Augmentin', 'Panadol'], '2026-11-05T09:10:00'));
      await LocalStorageService.saveLocalPrescription(rx(['Panadol'], '2026-11-05T09:00:00'));
      expect(storedMeds(), ['Augmentin', 'Panadol']);
    });

    test('a copy without medicines does not wipe one that has them', () async {
      await LocalStorageService.saveLocalPrescription(rx(['Panadol'], '2026-11-05T09:00:00'));
      await LocalStorageService.saveLocalPrescription(rx([], '2026-11-05T09:30:00'));
      expect(storedMeds(), ['Panadol']);
    });

    test('a newer edit is stored', () async {
      await LocalStorageService.saveLocalPrescription(rx(['Panadol'], '2026-11-05T09:00:00'));
      await LocalStorageService.saveLocalPrescription(rx(['Brufen'], '2026-11-05T09:10:00'));
      expect(storedMeds(), ['Brufen']);
    });
  });
}
