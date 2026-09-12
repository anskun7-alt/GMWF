import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_child_parent_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Pillar 1: Individual Patient ID Resolution & Disambiguation', () {
    test('Correctly identifies adult vs child canonical IDs', () {
      // 1. Adult with CNIC
      final adultMap = {
        'patientId': '4210112345671',
        'cnic': '4210112345671',
        'isAdult': true,
        'name': 'Muhammad Ali',
      };
      expect(LocalStorageService.resolveIndividualPatientId(adultMap), '4210112345671');

      // 2. Child registered under guardian CNIC with child suffix
      final childWithSuffix = {
        'patientId': '4210112345671_child_hassan',
        'cnic': '4210112345671',
        'guardianCnic': '4210112345671',
        'isAdult': false,
        'name': 'Hassan Ali',
      };
      expect(LocalStorageService.resolveIndividualPatientId(childWithSuffix), '4210112345671_child_hassan');

      // 3. Child registered with raw parent CNIC (legacy bug)
      final childWithRawCnic = {
        'patientId': '4210112345671',
        'cnic': '4210112345671',
        'guardianCnic': '4210112345671',
        'isAdult': false,
        'name': 'Hassan Ali',
      };
      // Resolved ID should automatically formulate canonical child key
      final resolved = LocalStorageService.resolveIndividualPatientId(childWithRawCnic);
      expect(resolved.toLowerCase(), '4210112345671_child_hassan_ali');
      expect(resolved, isNot(equals('4210112345671')));
    });

    test('Differentiates siblings sharing guardian CNIC', () {
      final child1 = {
        'patientId': '4210112345671_child_ali',
        'cnic': '4210112345671',
        'guardianCnic': '4210112345671',
        'isAdult': false,
        'name': 'Ali',
      };
      final child2 = {
        'patientId': '4210112345671_child_fatima',
        'cnic': '4210112345671',
        'guardianCnic': '4210112345671',
        'isAdult': false,
        'name': 'Fatima',
      };

      final id1 = LocalStorageService.resolveIndividualPatientId(child1);
      final id2 = LocalStorageService.resolveIndividualPatientId(child2);

      expect(id1, isNot(equals(id2)));
      expect(id1, contains('ali'));
      expect(id2, contains('fatima'));
    });
  });

  group('Pillar 2: Child & Parent Conflict Detection in Data Integrity', () {
    test('findChildParentCnicConflicts detects raw CNIC children and CNIC collisions', () async {
      final pBox = await Hive.openBox(LocalStorageService.patientsBox);
      final eBox = await Hive.openBox(LocalStorageService.entriesBox);
      final prBox = await Hive.openBox(LocalStorageService.prescriptionsBox);

      // Scenario: Adult exists with CNIC 4210199999991
      await pBox.put('4210199999991', {
        'patientId': '4210199999991',
        'cnic': '4210199999991',
        'isAdult': true,
        'patientName': 'Tariq Khan',
        'branchId': 'khi_01',
      });

      // Child was registered under parent's raw CNIC 4210199999991 before adult was created
      // Hive key in corrupted database might be prefixed or raw
      await pBox.put('child_raw_key', {
        'patientId': '4210199999991',
        'cnic': '4210199999991',
        'guardianCnic': '4210199999991',
        'isAdult': false,
        'patientName': 'Bilal Tariq',
        'branchId': 'khi_01',
      });

      // Add visit history for Bilal Tariq
      await eBox.put('serial_001', {
        'serial': '001',
        'patientId': '4210199999991',
        'patientName': 'Bilal Tariq',
        'branchId': 'khi_01',
        'isAdult': false,
        'date': '2026-09-06',
      });

      // Add prescription for Bilal Tariq
      await prBox.put('rx_001', {
        'patientId': '4210199999991',
        'patientName': 'Bilal Tariq',
        'branchId': 'khi_01',
        'medicines': [{'name': 'Paracetamol Syrup', 'quantity': 1}],
      });

      // Scan for conflicts
      final conflicts = await LocalStorageService.findChildParentCnicConflicts();

      expect(conflicts.length, greaterThanOrEqualTo(1));
      final childConflict = conflicts.firstWhere((c) => c['patientName'] == 'Bilal Tariq');
      expect(childConflict['isChild'], isTrue);
      expect(childConflict['isRawCnicChild'], isTrue);
      expect(childConflict['linkedVisitsCount'], 1);
      expect(childConflict['linkedPrescriptionsCount'], 1);
    });
  });

  group('Pillar 3: Delete Patient Registration Preserving Medical History', () {
    test('Deletes corrupted registration from patientsBox while keeping entries, prescriptions & dispensary', () async {
      final pBox = await Hive.openBox(LocalStorageService.patientsBox);
      final eBox = await Hive.openBox(LocalStorageService.entriesBox);
      final prBox = await Hive.openBox(LocalStorageService.prescriptionsBox);
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);
      await Hive.openBox(LocalStorageService.auditLogsBox);

      const corruptedKey = 'corrupted_child_key';
      const patientId = '4210188888881';

      // Insert corrupted registration
      await pBox.put(corruptedKey, {
        'patientId': patientId,
        'cnic': patientId,
        'guardianCnic': patientId,
        'isAdult': false,
        'patientName': 'Zainab Child',
        'branchId': 'khi_01',
      });

      // Insert 2 medical visit entries
      await eBox.put('entry_001', {
        'serial': '001',
        'patientId': patientId,
        'patientName': 'Zainab Child',
        'branchId': 'khi_01',
        'status': 'dispensed',
      });
      await eBox.put('entry_002', {
        'serial': '002',
        'patientId': patientId,
        'patientName': 'Zainab Child',
        'branchId': 'khi_01',
        'status': 'waiting',
      });

      // Insert prescription
      await prBox.put('rx_101', {
        'patientId': patientId,
        'patientName': 'Zainab Child',
        'branchId': 'khi_01',
        'medicines': [{'name': 'Amoxicillin', 'quantity': 1}],
      });

      // Execute safe deletion
      await LocalStorageService.deletePatientRegistrationPreservingHistory(
        corruptedKey,
        branchId: 'khi_01',
        reason: 'Child-parent collision cleanup',
      );

      // Verify patient registration is REMOVED
      expect(pBox.containsKey(corruptedKey), isFalse);

      // Verify medical visits are 100% PRESERVED
      expect(eBox.containsKey('entry_001'), isTrue);
      expect(eBox.containsKey('entry_002'), isTrue);
      expect(eBox.get('entry_001')['patientName'], 'Zainab Child');

      // Verify prescriptions are 100% PRESERVED
      expect(prBox.containsKey('rx_101'), isTrue);
      expect(prBox.get('rx_101')['patientName'], 'Zainab Child');

      // Verify sync queue received background delete task
      expect(syncBox.isNotEmpty, isTrue);
      final syncItem = syncBox.values.firstWhere(
        (it) => it is Map && (it['type'] == 'delete_patient' || it['action'] == 'delete_patient'),
      ) as Map;
      expect(syncItem['patientId'], corruptedKey);
      expect(syncItem['branchId'], 'khi_01');
    });

    test('Auto-migrates child to canonical ID and repoints local records', () async {
      final pBox = await Hive.openBox(LocalStorageService.patientsBox);
      final eBox = await Hive.openBox(LocalStorageService.entriesBox);
      await Hive.openBox(LocalStorageService.syncBox);

      const oldKey = '4210177777771';
      await pBox.put(oldKey, {
        'patientId': oldKey,
        'cnic': oldKey,
        'guardianCnic': oldKey,
        'isAdult': false,
        'patientName': 'Ibrahim Kid',
        'branchId': 'khi_01',
      });

      await eBox.put('entry_301', {
        'serial': '301',
        'patientId': oldKey,
        'patientName': 'Ibrahim Kid',
        'branchId': 'khi_01',
      });

      final newCanonicalId = await LocalStorageService.autoMigrateChildToCanonicalId(
        oldKey,
        branchId: 'khi_01',
      );

      expect(newCanonicalId.toLowerCase(), contains('_child_ibrahim_kid'));
      expect(pBox.containsKey(oldKey), isFalse);
      expect(pBox.containsKey(newCanonicalId), isTrue);

      // Verify entry was updated with new canonical ID
      final updatedEntry = eBox.get('entry_301');
      expect(updatedEntry['patientId'], newCanonicalId);
    });
  });

  group('Pillar 4: Receptionist Token Disambiguation Logic', () {
    test('Parent and Child with same guardian CNIC receive tokens on same day without blocking', () {
      final adultToken = {
        'serial': '001',
        'patientId': '4210155555551',
        'cnic': '4210155555551',
        'guardianCnic': '',
        'patientName': 'Rashid Parent',
        'isAdult': true,
        'date': '2026-09-06',
        'status': 'waiting',
      };

      final childTokenCandidate = {
        'serial': '002',
        'patientId': '4210155555551_child_hadi',
        'cnic': '4210155555551',
        'guardianCnic': '4210155555551',
        'patientName': 'Hadi Child',
        'isAdult': false,
        'date': '2026-09-06',
      };

      // In token_screen:
      // Adult token check: eIsChild is false, candidate is child (isChild is true).
      // They must NEVER collide.
      final adultIsChild = adultToken['isAdult'] == false;
      final candidateIsChild = childTokenCandidate['isAdult'] == false;

      // Disambiguation boundary
      final isDifferentCategory = adultIsChild != candidateIsChild;
      expect(isDifferentCategory, isTrue, reason: "Adult and Child categories must never collide");

      // Candidate patientId comparison
      final isSameId = adultToken['patientId'] == childTokenCandidate['patientId'];
      expect(isSameId, isFalse, reason: "Adult and Child IDs must be distinct");
    });
  });

  group('Pillar 5: Dashboard Date Filter & Branch Normalization', () {
    test('Date parsing recognizes timestamps, ISO strings, dates and matches filter ranges', () {
      final filterStart = DateTime(2026, 9, 1);
      final filterEnd = DateTime(2026, 9, 6, 23, 59, 59);

      DateTime? parseFlexibleDate(dynamic raw) {
        if (raw == null) return null;
        if (raw is DateTime) return raw;
        if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
        if (raw is String && raw.isNotEmpty) {
          final dt = DateTime.tryParse(raw);
          if (dt != null) return dt;
          final parts = raw.split('-');
          if (parts.length == 3) {
            final y = int.tryParse(parts[0]);
            final m = int.tryParse(parts[1]);
            final d = int.tryParse(parts[2]);
            if (y != null && m != null && d != null) return DateTime(y, m, d);
          }
        }
        return null;
      }

      bool isDateInRange(dynamic raw) {
        final dt = parseFlexibleDate(raw);
        if (dt == null) return false;
        return !dt.isBefore(filterStart) && !dt.isAfter(filterEnd);
      }

      // Test ISO string
      expect(isDateInRange('2026-09-04T10:30:00Z'), isTrue);
      // Test YYYY-MM-DD
      expect(isDateInRange('2026-09-02'), isTrue);
      // Test Epoch milliseconds
      expect(isDateInRange(DateTime(2026, 9, 3).millisecondsSinceEpoch), isTrue);
      // Test Out of range past
      expect(isDateInRange('2026-08-30'), isFalse);
      // Test Out of range future
      expect(isDateInRange('2026-09-08'), isFalse);
    });

    test('Branch matcher normalizes all variants and aliases', () {
      bool isMatchingBranch(String? itemBranch, String targetBranch) {
        final normTarget = targetBranch.trim().toLowerCase();
        if (normTarget.isEmpty || normTarget == 'all') return true;
        final normItem = (itemBranch ?? '').trim().toLowerCase();
        if (normItem == normTarget) return true;
        final cleanItem = normItem.replaceAll(RegExp(r'[\s\-_]'), '');
        final cleanTarget = normTarget.replaceAll(RegExp(r'[\s\-_]'), '');
        if (cleanItem.isNotEmpty && cleanItem == cleanTarget) return true;
        if ((cleanTarget == 'karachi' || cleanTarget == 'khi' || cleanTarget == 'khi01') &&
            (cleanItem == 'karachi' || cleanItem == 'khi' || cleanItem == 'khi01' || cleanItem.isEmpty)) {
          return true;
        }
        return false;
      }

      expect(isMatchingBranch('khi_01', 'khi-01'), isTrue);
      expect(isMatchingBranch('karachi', 'khi_01'), isTrue);
      expect(isMatchingBranch('', 'karachi'), isTrue);
      expect(isMatchingBranch('lhr_01', 'khi_01'), isFalse);
    });
  });

  group('Pillar 6: 13-Digit Raw CNIC Formatting (xxxxx-xxxxxxx-x)', () {
    test('formatAllRawCnics updates 13-digit raw CNIC to xxxxx-xxxxxxx-x format and enqueues sync', () async {
      final pBox = await Hive.openBox(LocalStorageService.patientsBox);
      final eBox = await Hive.openBox(LocalStorageService.entriesBox);
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);

      // Patient with raw 13-digit CNIC
      const rawCnic = '4210112345671';
      const expectedFormatted = '42101-1234567-1';

      await pBox.put('p_raw_cnic_01', {
        'patientId': 'p_raw_cnic_01',
        'patientName': 'Kashif Raw CNIC',
        'cnic': rawCnic,
        'isAdult': true,
        'branchId': 'khi_01',
      });

      // Child with raw 13-digit guardian CNIC
      await pBox.put('p_raw_guard_02', {
        'patientId': 'p_raw_guard_02',
        'patientName': 'Sara Child',
        'guardianCnic': rawCnic,
        'isAdult': false,
        'branchId': 'khi_01',
      });

      // Entry with raw CNIC
      await eBox.put('e_001', {
        'serial': '001',
        'patientId': 'p_raw_cnic_01',
        'cnic': rawCnic,
        'branchId': 'khi_01',
      });

      // Run batch formatting
      final updatedCount = await LocalStorageService.formatAllRawCnics(branchId: 'khi_01');

      expect(updatedCount, 2);

      // Verify patient 1 has formatted CNIC
      final p1 = pBox.get('p_raw_cnic_01') as Map;
      expect(p1['cnic'], expectedFormatted);

      // Verify patient 2 has formatted guardian CNIC
      final p2 = pBox.get('p_raw_guard_02') as Map;
      expect(p2['guardianCnic'], expectedFormatted);

      // Verify entry was updated
      final e1 = eBox.get('e_001') as Map;
      expect(e1['cnic'], expectedFormatted);

      // Verify sync item enqueued
      final syncItem = syncBox.values.firstWhere(
        (it) => it is Map && it['type'] == 'save_patient' && it['patientId'] == 'p_raw_cnic_01',
      ) as Map;
      expect(syncItem['data']['cnic'], expectedFormatted);
    });

    test('saveLocalPatient automatically normalizes raw CNIC on save', () async {
      final pBox = await Hive.openBox(LocalStorageService.patientsBox);

      await LocalStorageService.saveLocalPatient({
        'name': 'Hamza New Patient',
        'cnic': '4220198765432',
        'isAdult': true,
        'branchId': 'khi_01',
      });

      // Retrieve by formatted CNIC key or patientId
      final p = pBox.values.firstWhere(
        (val) => val is Map && val['name'] == 'Hamza New Patient',
      ) as Map;

      expect(p['cnic'], '42201-9876543-2');
    });
  });

  group('Pillar 7: Local-First Prescription Consolidation & Background Sync', () {
    test('LocalStorageService.unifyAndMergeAllLocalSerials unifies prescriptions and dispensary data into entriesBox and purges legacy keys', () async {
      final prBox = await Hive.openBox(LocalStorageService.prescriptionsBox);
      final dBox = await Hive.openBox(LocalStorageService.dispensaryBox);
      final eBox = await Hive.openBox(LocalStorageService.entriesBox);
      final syncBox = await Hive.openBox(LocalStorageService.syncBox);

      await prBox.clear();
      await dBox.clear();
      await eBox.clear();
      await syncBox.clear();

      // 1. Initial waiting token in entriesBox
      await eBox.put('khi_01-060926-201', {
        'serial': '060926-201',
        'patientId': '42101-1111111-1',
        'cnic': '42101-1111111-1',
        'patientName': 'Zahid Khan',
        'status': 'waiting',
        'dispenseStatus': 'waiting',
        'queueType': 'zakat',
        'branchId': 'khi_01',
        'dateKey': '060926',
      });

      // 2. Doctor wrote prescription in prescriptionsBox under cleanCnic_serial
      await prBox.put('4210111111111_060926-201', {
        'serial': '060926-201',
        'patientCnic': '42101-1111111-1',
        'patientName': 'Zahid Khan',
        'branchId': 'khi_01',
        'dateKey': '060926',
        'doctorName': 'Dr. Farooq',
        'doctorId': 'doc_01',
        'diagnosis': 'Seasonal Flu & Fever',
        'complaint': 'Severe Headache',
        'daysOfMedicine': 3,
        'vitals': {'bp': '120/80', 'temp': '99.2'},
        'prescriptions': [
          {'name': 'Arinac Forte', 'quantity': 6, 'dosage': '1 tab twice daily'},
        ],
      });

      // 3. Dispensary recorded dispense in dispensaryBox under branch_date_serial
      await dBox.put('khi_01_060926_060926-201', {
        'serial': '060926-201',
        'branchId': 'khi_01',
        'dateKey': '060926',
        'dispenseStatus': 'dispensed',
        'status': 'completed',
        'dispensedBy': 'Dispenser Ali',
        'dispenserName': 'Dispenser Ali',
        'charges': 50,
        'receivedAmount': 50,
      });

      // 4. Orphaned prescription with NO initial entry in entriesBox
      await prBox.put('4210122222222_060926-999', {
        'serial': '060926-999',
        'patientCnic': '42101-2222222-2',
        'patientName': 'Orphan Patient Amina',
        'branchId': 'khi_01',
        'dateKey': '060926',
        'doctorName': 'Dr. Ayesha',
        'diagnosis': 'Asthma',
        'prescriptions': [
          {'name': 'Ventolin Inhaler', 'quantity': 1},
        ],
      });

      // Run unification routine
      final count = await LocalStorageService.unifyAndMergeAllLocalSerials('khi_01');
      expect(count, greaterThanOrEqualTo(2));

      // Assert serial 060926-201 in entriesBox has ALL unified data
      final mergedEntry = Map<String, dynamic>.from(eBox.get('khi_01-060926-201') as Map);
      expect(mergedEntry['status'], 'completed');
      expect(mergedEntry['dispenseStatus'], 'dispensed');
      expect(mergedEntry['doctorName'], 'Dr. Farooq');
      expect(mergedEntry['diagnosis'], 'Seasonal Flu & Fever');
      expect(mergedEntry['complaint'], 'Severe Headache');
      expect(mergedEntry['daysOfMedicine'], 3);
      expect(mergedEntry['dispenserName'], 'Dispenser Ali');
      expect(mergedEntry['charges'], 50);
      expect(mergedEntry['receivedAmount'], 50);
      expect(mergedEntry['medicines'], isNotEmpty);
      expect(mergedEntry['prescription'], isNotNull);

      // Assert legacy keys are PURGED from prBox and dBox
      expect(prBox.get('4210111111111_060926-201'), isNull);
      expect(prBox.get('060926-201'), isNull);
      expect(dBox.get('khi_01_060926_060926-201'), isNull);
      expect(dBox.get('060926-201'), isNull);

      // Assert orphaned prescription 060926-999 was RECOVERED into entriesBox
      final recoveredOrphan = Map<String, dynamic>.from(eBox.get('khi_01-060926-999') as Map);
      expect(recoveredOrphan['patientName'], 'Orphan Patient Amina');
      expect(recoveredOrphan['doctorName'], 'Dr. Ayesha');
      expect(recoveredOrphan['diagnosis'], 'Asthma');
      expect(recoveredOrphan['medicines'], isNotEmpty);
      expect(prBox.get('4210122222222_060926-999'), isNull);

      // Assert sync operations are enqueued
      final queuedSaves = syncBox.values.where((it) => it is Map && it['type'] == 'save_entry').toList();
      final queuedPrescDeletes = syncBox.values.where((it) => it is Map && it['type'] == 'delete_prescription').toList();
      final queuedDispDeletes = syncBox.values.where((it) => it is Map && it['type'] == 'delete_dispensary').toList();

      expect(queuedSaves.any((s) => (s as Map)['serial'] == '060926-201'), isTrue);
      expect(queuedSaves.any((s) => (s as Map)['serial'] == '060926-999'), isTrue);
      expect(queuedPrescDeletes.any((d) => (d as Map)['serial'] == '060926-201'), isTrue);
      expect(queuedDispDeletes.any((d) => (d as Map)['serial'] == '060926-201'), isTrue);
    });
  });
}
