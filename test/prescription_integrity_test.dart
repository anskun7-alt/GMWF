import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/Pages/dispensary/dispensar/patient_form_helper.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('prescription_integrity_test_');
    Hive.init(tempDir.path);
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.patientsBox);
    await Hive.openBox('app_settings');
    await Hive.openBox(LocalStorageService.stockBox);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Timing and daily quantity calculation', () {
    test('1-time timings strictly resolve to dailyQty = 1 (never 2)', () {
      final t1 = PatientFormHelper.resolveCanonicalTiming('1');
      expect(t1.timing, '1+0+0');
      expect(t1.dailyQty, 1);
      expect(PatientFormHelper.totalPerDay(t1.timing), 1);

      final t10 = PatientFormHelper.resolveCanonicalTiming('1+0');
      expect(t10.timing, '1+0+0');
      expect(t10.dailyQty, 1);

      final t100 = PatientFormHelper.resolveCanonicalTiming('1+0+0');
      expect(t100.timing, '1+0+0');
      expect(t100.dailyQty, 1);

      final t001 = PatientFormHelper.resolveCanonicalTiming('0+0+1');
      expect(t001.timing, '0+0+1');
      expect(t001.dailyQty, 1);

      final tSleepSingle = PatientFormHelper.resolveCanonicalTiming('1', mealTiming: 'Before Sleep');
      expect(tSleepSingle.timing, '0+0+1');
      expect(tSleepSingle.dailyQty, 1);

      final tSleepEmpty = PatientFormHelper.resolveCanonicalTiming('', mealTiming: 'Before Sleep');
      expect(tSleepEmpty.timing, '0+0+1');
      expect(tSleepEmpty.dailyQty, 1);
    });

    test('2-time timings strictly resolve to dailyQty = 2 (never 3)', () {
      final t11 = PatientFormHelper.resolveCanonicalTiming('1+1');
      expect(t11.timing, '1+1+0');
      expect(t11.dailyQty, 2);
      expect(PatientFormHelper.totalPerDay(t11.timing), 2);

      final t101 = PatientFormHelper.resolveCanonicalTiming('1+0+1');
      expect(t101.timing, '1+0+1');
      expect(t101.dailyQty, 2);

      final t110 = PatientFormHelper.resolveCanonicalTiming('1+1+0');
      expect(t110.timing, '1+1+0');
      expect(t110.dailyQty, 2);
    });

    test('3-time timings resolve to dailyQty = 3', () {
      final t111 = PatientFormHelper.resolveCanonicalTiming('1+1+1');
      expect(t111.timing, '1+1+1');
      expect(t111.dailyQty, 3);
      expect(PatientFormHelper.totalPerDay(t111.timing), 3);
    });
  });

  group('Strict injection classification', () {
    test('Oral and topical forms are never classified as injections', () {
      expect(
        PatientFormHelper.isInjectable({'name': 'Tab. Dicloran 50mg', 'type': 'Tablet'}),
        isFalse,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Multivitamin', 'type': 'Tablet'}),
        isFalse,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Ivermectin 6mg', 'type': 'Tablet'}),
        isFalse,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Infant Drops', 'type': 'Drops'}),
        isFalse,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Cap. Omeprazole 20mg', 'type': 'Capsule'}),
        isFalse,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Syp. Brufen', 'type': 'Syrup'}),
        isFalse,
      );
    });

    test('True injections, Powder for Injection, Injectable Suspension, and blank-type Normal Saline are classified as injectable', () {
      expect(
        PatientFormHelper.isInjectable({'name': 'Inj. Dicloran 75mg', 'type': 'Injection'}),
        isTrue,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Drip Normal Saline', 'type': 'Infusion'}),
        isTrue,
      );
      // Pre-deployment audit test: "Powder for Injection" and "Injectable Suspension"
      expect(
        PatientFormHelper.isInjectable({'name': 'Ceftriaxone 1g', 'type': 'Powder for Injection'}),
        isTrue,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Depo-Medrol 40mg', 'type': 'Injectable Suspension'}),
        isTrue,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Diclofenac Gel Injection', 'type': 'Injection Gel'}),
        isTrue,
      );
      // Blank type with infusion name like "Normal Saline" or "Ringer Lactate"
      expect(
        PatientFormHelper.isInjectable({'name': 'Normal Saline 500ml', 'type': ''}),
        isTrue,
      );
      expect(
        PatientFormHelper.isInjectable({'name': 'Ringer Lactate', 'type': ''}),
        isTrue,
      );
    });

    test('Ambiguous items with blank/unknown type are flagged as Unclassified instead of guessing', () {
      final unknownMed = {'name': 'Custom Compound Z', 'type': ''};
      expect(PatientFormHelper.isInjectable(unknownMed), isFalse);
      expect(PatientFormHelper.isUnclassifiedMedicine(unknownMed), isTrue);

      final knownTablet = {'name': 'Panadol', 'type': 'Tablet'};
      expect(PatientFormHelper.isUnclassifiedMedicine(knownTablet), isFalse);

      final knownInj = {'name': 'Ceftriaxone 1g', 'type': 'Powder for Injection'};
      expect(PatientFormHelper.isUnclassifiedMedicine(knownInj), isFalse);
    });
  });

  group('Doctor prescription edits, medicine/injection removal, and lookup accuracy', () {
    test('Doctor removing an injection or medicine replaces stored prescription in Hive', () async {
      const serial = '071126M-SKT-009';
      const branch = 'sialkot';
      const cnic = '3460312345671';
      final t0 = DateTime.now().toIso8601String();

      // Initial prescription with 2 tablets + 1 injection
      final initialPresc = <String, dynamic>{
        'id': serial,
        'serial': serial,
        'branchId': branch,
        'patientCnic': cnic,
        'cnic': cnic,
        'patientId': cnic,
        'patientName': 'Test Patient',
        'daysOfMedicine': 1,
        'completedAt': t0,
        'updatedAt': t0,
        'medicines': [
          {'name': 'Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
          {'name': 'Brufen', 'type': 'Tablet', 'timing': '1+1+1', 'quantity': 3},
          {'name': 'Inj. Dicloran', 'type': 'Injection', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
          {'name': 'Brufen', 'type': 'Tablet', 'timing': '1+1+1', 'quantity': 3},
          {'name': 'Inj. Dicloran', 'type': 'Injection', 'quantity': 1},
        ],
      };

      await LocalStorageService.saveLocalPrescription(initialPresc);

      // Doctor edits the prescription: removes Inj. Dicloran and Brufen, changes Panadol to 1-time (1+0+0)
      final t1 = DateTime.now().add(const Duration(milliseconds: 10)).toIso8601String();
      final editedPresc = <String, dynamic>{
        'id': serial,
        'serial': serial,
        'branchId': branch,
        'patientCnic': cnic,
        'cnic': cnic,
        'patientName': 'Test Patient',
        'daysOfMedicine': 1,
        'completedAt': t0,
        'updatedAt': t1,
        'medicines': [
          {'name': 'Panadol', 'type': 'Tablet', 'timing': '1+0+0', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Panadol', 'type': 'Tablet', 'timing': '1+0+0', 'quantity': 1},
        ],
      };

      // Verify mayReplacePrescription accepts the edit even when existing has patientId and edited lacks patientId (only has id=serial)
      expect(LocalStorageService.mayReplacePrescription(editedPresc, initialPresc), isTrue);

      await LocalStorageService.saveLocalPrescription(editedPresc);

      // Verify getLocalPrescription returns the edited prescription even when queried with patientId = cnic
      final fetched = LocalStorageService.getLocalPrescription(
        serial,
        cnic: cnic,
        patientName: 'Test Patient',
        patientId: cnic,
        branchId: branch,
      );
      expect(fetched, isNotNull);
      final meds = (fetched!['prescriptions'] ?? fetched['medicines']) as List;
      expect(meds.length, 1);
      expect(meds.first['name'], 'Panadol');
      expect(meds.first['timing'], '1+0+0');
      expect(meds.first['quantity'], 1);
      expect(meds.any((m) => PatientFormHelper.isInjectable(m as Map)), isFalse);
    });
  });

  group('Haji Camp (haji_camp vs karachi) & Receptionist vitals/name preservation', () {
    test('Doctor save under haji_camp never overwrites Receptionist vitals, name, age, gender, or CNIC saved under karachi', () async {
      const serial = '071126M-HAJI-005';
      const cnic = '4210112345671';
      final t0 = DateTime.now().toIso8601String();

      // 1. Receptionist creates token under 'karachi' (with dispensaryId: 'haji_camp')
      await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'campId': 'haji_camp',
        'dispensaryTag': 'HAJI',
        'patientName': 'Muhammad Tariq',
        'name': 'Muhammad Tariq',
        'patientCnic': cnic,
        'cnic': cnic,
        'age': '52',
        'patientAge': '52',
        'gender': 'Male',
        'patientGender': 'Male',
        'phone': '03001234567',
        'status': 'waiting',
        'createdAt': t0,
        'vitals': {
          'bp': '130/85',
          'temp': '98.6',
          'weight': '74',
          'sugar': '115',
          'receptionistVitals': {
            'bp': '130/85',
            'temp': '98.6',
            'weight': '74',
            'sugar': '115',
          },
        },
      });

      // 2. Doctor on 'haji_camp' desk looks up entry via getLocalEntry('haji_camp', serial)
      final foundForDoctor = LocalStorageService.getLocalEntry('haji_camp', serial);
      expect(foundForDoctor, isNotNull);
      expect(foundForDoctor!['patientName'], 'Muhammad Tariq');
      expect((foundForDoctor['vitals'] as Map)['bp'], '130/85');

      // 3. Even if Doctor saves prescription under 'haji_camp' with empty vitals {} and 'Unknown Patient'
      final t1 = DateTime.now().add(const Duration(seconds: 5)).toIso8601String();
      await LocalStorageService.saveLocalPrescription({
        'id': serial,
        'serial': serial,
        'branchId': 'haji_camp',
        'patientCnic': 'unknown_12345',
        'cnic': 'unknown_12345',
        'patientName': 'Unknown Patient',
        'name': 'Unknown Patient',
        'vitals': <String, dynamic>{},
        'daysOfMedicine': 2,
        'completedAt': t1,
        'updatedAt': t1,
        'doctorName': 'Dr. Farrukh',
        'medicines': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
        ],
        'prescriptions': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
        ],
      });

      // 4. Verify getLocalEntry and getLocalEntries preserve Receptionist's vitals, name, age, gender, and CNIC
      final afterRxEntry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(afterRxEntry, isNotNull);
      expect(afterRxEntry!['patientName'], 'Muhammad Tariq');
      expect(afterRxEntry['patientCnic'], cnic);
      expect(afterRxEntry['age'], '52');
      expect(afterRxEntry['gender'], 'Male');
      final entryVitals = afterRxEntry['vitals'] as Map;
      expect(entryVitals['bp'], '130/85');
      expect(entryVitals['temp'], '98.6');
      expect(entryVitals['weight'], '74');
      expect(entryVitals['sugar'], '115');

      // Also check getLocalEntries for both 'karachi' and 'haji_camp'
      for (final queryBranch in ['karachi', 'haji_camp']) {
        final entries = LocalStorageService.getLocalEntries(queryBranch);
        final match = entries.firstWhere(
          (e) => (e['serial'] ?? '').toString().toUpperCase() == serial,
          orElse: () => <String, dynamic>{},
        );
        expect(match.isNotEmpty, isTrue, reason: 'Should find $serial under $queryBranch');
        expect(match['patientName'], 'Muhammad Tariq');
        expect(match['patientCnic'], cnic);
        final v = match['vitals'] as Map;
        expect(v['bp'], '130/85');
        expect(v['temp'], '98.6');
        expect(v['weight'], '74');
        expect(v['sugar'], '115');
      }
    });

    test('Receptionist patientName and CNIC are strictly immutable even if Doctor sends synthetic unknown_<timestamp> CNIC or different name', () async {
      const serial = '071126M-HAJI-014';
      const realCnic = '4220198765431';
      final t0 = DateTime.now().toIso8601String();

      // 1. Receptionist issues token #014 for "shoukat Ali" with real CNIC
      final saved1 = await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'campId': 'haji_camp',
        'patientId': realCnic,
        'patientName': 'shoukat Ali',
        'name': 'shoukat Ali',
        'patientCnic': realCnic,
        'cnic': realCnic,
        'status': 'waiting',
        'session': 'morning',
        'createdAt': t0,
      });
      expect(saved1, isTrue);

      // 2. Doctor or LAN update arrives with synthetic 'unknown_1794037191871' CNIC (13-digit epoch!)
      // and a different/altered name. It must NOT trigger a false serial collision, and must NEVER
      // overwrite the Receptionist's patientName or CNIC!
      final saved2 = await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'campId': 'haji_camp',
        'patientId': 'unknown_1794037191871',
        'patientName': 'Wrong Doctor Name',
        'name': 'Wrong Doctor Name',
        'patientCnic': 'unknown_1794037191871',
        'cnic': '',
        'status': 'completed',
        'dispenseStatus': 'dispensed',
        'session': 'morning',
      });
      expect(saved2, isTrue, reason: 'Synthetic unknown_<timestamp> CNIC must never trigger a false serial collision');

      final entry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(entry, isNotNull);
      expect(entry!['patientName'], 'shoukat Ali');
      expect(entry['name'], 'shoukat Ali');
      expect(entry['patientCnic'], realCnic);
      expect(entry['cnic'], realCnic);
      expect(entry['hasCollision'], isNull);
    });

    test('Account assignments are respected without hardcoded username overrides', () async {
      final uBox = await Hive.openBox(LocalStorageService.usersBox);
      await uBox.put('shahmeer-uid', {
        'uid': 'shahmeer-uid',
        'username': 'shahmeer',
        'email': 'shahmeer@skt.com',
        'branchId': 'sialkot',
        'branchName': 'Sialkot',
        'role': 'rec+dis',
      });
      final settings = Hive.box('app_settings');
      await settings.put('user_data', {
        'uid': 'shahmeer-uid',
        'username': 'shahmeer',
        'email': 'shahmeer@skt.com',
        'branchId': 'sialkot',
        'branchName': 'Sialkot',
        'role': 'rec+dis',
      });
      await settings.put('selected_branch', 'sialkot');

      await LocalStorageService.repairAndSanitizeLocalAccounts(force: true);

      // Verify the account repair applies no username-based branch override over a legitimate Sialkot assignment
      final updatedUser = settings.get('user_data') as Map;
      expect(updatedUser['branchId'], 'sialkot');
      expect(settings.get('selected_branch'), 'sialkot');
    });

    test('Doctor PC clock 5 minutes behind still applies medicine edit/removal via monotonic revision counter', () async {
      const serial = '071126M-KHI-HAJI-Z-021';
      const branch = 'karachi';
      const cnic = '4210155555551';
      final tInitial = DateTime.utc(2026, 11, 7, 12, 0, 0).toIso8601String();
      // Doctor PC clock is 5 minutes BEHIND the initial timestamp!
      final tSlowClock = DateTime.utc(2026, 11, 7, 11, 55, 0).toIso8601String();

      final rxRev1 = <String, dynamic>{
        'id': serial,
        'serial': serial,
        'branchId': branch,
        'campId': 'haji_camp',
        'dateKey': '071126',
        'queueType': 'zakat',
        'patientCnic': cnic,
        'cnic': cnic,
        'patientId': cnic,
        'patientName': 'Imran Khan',
        'revision': 1,
        'completedAt': tInitial,
        'updatedAt': tInitial,
        'medicines': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
          {'name': 'Tab. Flagyl', 'type': 'Tablet', 'timing': '1+1+1', 'quantity': 3},
        ],
        'prescriptions': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
          {'name': 'Tab. Flagyl', 'type': 'Tablet', 'timing': '1+1+1', 'quantity': 3},
        ],
      };
      await LocalStorageService.saveLocalPrescription(rxRev1);

      // Doctor edits prescription (removes Flagyl) with clock 5 minutes behind, but revision = 2
      final rxRev2SlowClock = <String, dynamic>{
        'id': serial,
        'serial': serial,
        'branchId': branch,
        'campId': 'haji_camp',
        'dateKey': '071126',
        'queueType': 'zakat',
        'patientCnic': cnic,
        'cnic': cnic,
        'patientId': cnic,
        'patientName': 'Imran Khan',
        'revision': 2,
        'completedAt': tSlowClock,
        'updatedAt': tSlowClock,
        'medicines': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+0', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+0', 'quantity': 1},
        ],
      };

      expect(LocalStorageService.isOlderPrescription(rxRev2SlowClock, rxRev1), isFalse);
      expect(LocalStorageService.mayReplacePrescription(rxRev2SlowClock, rxRev1), isTrue);

      await LocalStorageService.saveLocalPrescription(rxRev2SlowClock);

      final fetched = LocalStorageService.getLocalPrescription(
        serial,
        branchId: branch,
        dateKey: '071126',
        cnic: cnic,
        patientName: 'Imran Khan',
      );
      expect(fetched, isNotNull);
      final meds = (fetched!['medicines'] ?? fetched['prescriptions']) as List;
      expect(meds.length, 1);
      expect(meds.first['name'], 'Tab. Panadol');
      expect(meds.first['timing'], '1+0+0');
      expect(fetched['revision'], 2);

      // Conversely, a replayed revision 1 with a FAST clock must be rejected over revision 2!
      expect(LocalStorageService.isOlderPrescription(rxRev1, rxRev2SlowClock), isTrue);
      expect(LocalStorageService.mayReplacePrescription(rxRev1, rxRev2SlowClock), isFalse);
    });

    test('Token #5 issued on two different days and for two family members on one CNIC never cross prescriptions', () async {
      const sharedCnic = '4210177777771';
      const branch = 'karachi';

      // 1. Token #5 ('005') on Day 1 ('071126') for Family Member 1 ("Ahmed Ali")
      await LocalStorageService.saveLocalPrescription({
        'id': '005',
        'serial': '005',
        'branchId': branch,
        'campId': 'haji_camp',
        'dateKey': '071126',
        'queueType': 'zakat',
        'patientCnic': sharedCnic,
        'cnic': sharedCnic,
        'patientId': '${sharedCnic}_child_ahmed',
        'patientName': 'Ahmed Ali',
        'revision': 1,
        'completedAt': '2026-11-07T10:00:00.000Z',
        'updatedAt': '2026-11-07T10:00:00.000Z',
        'medicines': [
          {'name': 'Syp. Amoxil', 'type': 'Syrup', 'timing': '1+0+1', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Syp. Amoxil', 'type': 'Syrup', 'timing': '1+0+1', 'quantity': 1},
        ],
      });

      // 2. Token #5 ('005') on Day 2 ('081126') for Family Member 2 ("Fatima Ali") on the SAME CNIC
      await LocalStorageService.saveLocalPrescription({
        'id': '005',
        'serial': '005',
        'branchId': branch,
        'campId': 'haji_camp',
        'dateKey': '081126',
        'queueType': 'zakat',
        'patientCnic': sharedCnic,
        'cnic': sharedCnic,
        'patientId': '${sharedCnic}_child_fatima',
        'patientName': 'Fatima Ali',
        'revision': 1,
        'completedAt': '2026-11-08T10:00:00.000Z',
        'updatedAt': '2026-11-08T10:00:00.000Z',
        'medicines': [
          {'name': 'Tab. Cetirizine', 'type': 'Tablet', 'timing': '0+0+1', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Tab. Cetirizine', 'type': 'Tablet', 'timing': '0+0+1', 'quantity': 1},
        ],
      });

      // 3. Even on the SAME day ('081126'), Family Member 1 ("Ahmed Ali") on Non-Zakat token #5 ('005')
      await LocalStorageService.saveLocalPrescription({
        'id': '005',
        'serial': '005',
        'branchId': branch,
        'campId': 'haji_camp',
        'dateKey': '081126',
        'queueType': 'non-zakat',
        'patientCnic': sharedCnic,
        'cnic': sharedCnic,
        'patientId': '${sharedCnic}_child_ahmed',
        'patientName': 'Ahmed Ali',
        'revision': 1,
        'completedAt': '2026-11-08T11:00:00.000Z',
        'updatedAt': '2026-11-08T11:00:00.000Z',
        'medicines': [
          {'name': 'Inj. Ceftriaxone', 'type': 'Powder for Injection', 'timing': '1+0+0', 'quantity': 1},
        ],
        'prescriptions': [
          {'name': 'Inj. Ceftriaxone', 'type': 'Powder for Injection', 'timing': '1+0+0', 'quantity': 1},
        ],
      });

      // Verify Day 1 Ahmed Ali's prescription is intact and did NOT cross with Day 2 or Fatima Ali
      final rxDay1Ahmed = LocalStorageService.getLocalPrescription(
        '005',
        branchId: branch,
        dateKey: '071126',
        queueType: 'zakat',
        cnic: sharedCnic,
        patientId: '${sharedCnic}_child_ahmed',
        patientName: 'Ahmed Ali',
      );
      expect(rxDay1Ahmed, isNotNull);
      expect((rxDay1Ahmed!['medicines'] as List).first['name'], 'Syp. Amoxil');

      // Verify Day 2 Fatima Ali's Zakat prescription is intact
      final rxDay2Fatima = LocalStorageService.getLocalPrescription(
        '005',
        branchId: branch,
        dateKey: '081126',
        queueType: 'zakat',
        cnic: sharedCnic,
        patientId: '${sharedCnic}_child_fatima',
        patientName: 'Fatima Ali',
      );
      expect(rxDay2Fatima, isNotNull);
      expect((rxDay2Fatima!['medicines'] as List).first['name'], 'Tab. Cetirizine');

      // Verify Day 2 Ahmed Ali's Non-Zakat prescription is intact
      final rxDay2AhmedNz = LocalStorageService.getLocalPrescription(
        '005',
        branchId: branch,
        dateKey: '081126',
        queueType: 'non-zakat',
        cnic: sharedCnic,
        patientId: '${sharedCnic}_child_ahmed',
        patientName: 'Ahmed Ali',
      );
      expect(rxDay2AhmedNz, isNotNull);
      expect((rxDay2AhmedNz!['medicines'] as List).first['name'], 'Inj. Ceftriaxone');
    });

    test('Explicit Receptionist/Supervisor name typo correction bumps identityRevision while Doctor edits remain blocked', () async {
      const serial = '071126M-KHI-HAJI-Z-033';
      const cnic = '4210188888881';

      // 1. Receptionist saves token with a typo: "Shoukat Alli"
      await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'campId': 'haji_camp',
        'patientId': cnic,
        'patientName': 'Shoukat Alli',
        'name': 'Shoukat Alli',
        'patientCnic': cnic,
        'cnic': cnic,
        'status': 'waiting',
      });

      // 2. Doctor save without allowIdentityOverride / identityRevision CANNOT change name
      await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'campId': 'haji_camp',
        'patientId': cnic,
        'patientName': 'Accidental Doctor Name',
        'name': 'Accidental Doctor Name',
        'patientCnic': cnic,
        'cnic': cnic,
        'status': 'completed',
      });
      var entry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(entry!['patientName'], 'Shoukat Alli');

      // 3. Receptionist/Supervisor corrects the typo via explicit override (`allowIdentityOverride: true`)
      await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'campId': 'haji_camp',
        'patientId': cnic,
        'patientName': 'Shoukat Ali',
        'name': 'Shoukat Ali',
        'patientCnic': cnic,
        'cnic': cnic,
        'allowIdentityOverride': true,
      });
      entry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(entry!['patientName'], 'Shoukat Ali');
      expect(entry['identityRevision'], 1);
      expect(entry['lanPushSig'], isNull);
    });

    test('Echo prevention lanPushSig is only stamped on server-originated data and cleared on local edits', () async {
      const serial = '071126M-KHI-HAJI-Z-044';
      const cnic = '4210199999991';

      // 1. Server sends token with lanPushSig stamped
      await LocalStorageService.saveEntryLocal('karachi', serial, {
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'patientName': 'Tariq Jameel',
        'patientCnic': cnic,
        'status': 'waiting',
        'lanPushSig': 'waiting|||false',
      });
      var entry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(entry!['lanPushSig'], isNotNull);

      // 2. Doctor saves prescription locally on this PC (no lanPushSig in payload)
      await LocalStorageService.saveLocalPrescription({
        'id': serial,
        'serial': serial,
        'branchId': 'karachi',
        'dateKey': '071126',
        'patientCnic': cnic,
        'patientName': 'Tariq Jameel',
        'revision': 1,
        'completedAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        'medicines': [
          {'name': 'Tab. Panadol', 'type': 'Tablet', 'timing': '1+0+1', 'quantity': 2},
        ],
      });

      // Local edit MUST clear lanPushSig so SyncService will push it when LAN reconnects!
      entry = LocalStorageService.getLocalEntry('karachi', serial);
      expect(entry!['lanPushSig'], isNull);
    });

    test('CNIC and Phone search strictly waits until all digits are written (never matches half-typed 17301-2)', () async {
      final pBox = Hive.box(LocalStorageService.patientsBox);
      await pBox.put('1730123389093', {
        'patientId': '1730123389093',
        'id': '1730123389093',
        'name': 'omar hayam',
        'patientName': 'omar hayam',
        'cnic': '17301-2338909-3',
        'patientCnic': '17301-2338909-3',
        'phone': '03009876543',
        'branchId': 'gujrat',
      });

      // Half-typed CNIC ("17301-2" or 10 digits "17301-23389") must return EMPTY list
      expect(LocalStorageService.searchPatientsByCnicOrGuardian('17301-2', branchId: 'gujrat'), isEmpty);
      expect(LocalStorageService.searchPatientsByCnicOrGuardian('17301-23389', branchId: 'gujrat'), isEmpty);
      expect(LocalStorageService.searchPatientsByCnicOrGuardian('17301-2338909', branchId: 'gujrat'), isEmpty);

      // Half-typed Phone ("0300987") must return EMPTY list
      expect(LocalStorageService.searchPatientsByCnicOrGuardian('0300987', branchId: 'gujrat'), isEmpty);

      // Complete 13-digit CNIC ("17301-2338909-3") matches immediately
      final fullCnicMatches = LocalStorageService.searchPatientsByCnicOrGuardian('17301-2338909-3', branchId: 'gujrat');
      expect(fullCnicMatches.length, 1);
      expect(fullCnicMatches.first['name'], 'omar hayam');

      // Complete 11-digit Phone ("03009876543") matches immediately
      final fullPhoneMatches = LocalStorageService.searchPatientsByCnicOrGuardian('03009876543', branchId: 'gujrat');
      expect(fullPhoneMatches.length, 1);
      expect(fullPhoneMatches.first['name'], 'omar hayam');
    });

    test('Future-proof dynamic camp matching works for newly created camps in any branch', () async {
      await Hive.openBox('local_branches');
      await CampSessionService.saveBranchCamps('lahore', [
        {'id': 'model_town_camp', 'name': 'Model Town Camp', 'status': 'active'},
        {'id': 'gulberg_camp', 'name': 'Gulberg Camp', 'status': 'active'},
      ]);

      expect(CampSessionService.areBranchesMatching('model_town_camp', 'lahore'), isTrue);
      expect(CampSessionService.areBranchesMatching('gulberg_camp', 'lahore'), isTrue);
      expect(
        CampSessionService.matchesCamp(
          selectedCamp: 'model_town_camp',
          campId: 'model_town_camp',
          serial: '071126M-MTC-001',
        ),
        isTrue,
      );
      expect(
        CampSessionService.matchesCamp(
          selectedCamp: 'saddar',
          campId: 'model_town_camp',
          serial: '071126M-MTC-001',
        ),
        isFalse,
      );
    });
  });
}
