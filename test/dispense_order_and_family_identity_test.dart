import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/Pages/dispensary/dispensar/dispense_queue.dart';
import 'package:gmwf/Pages/dispensary/receptionist/patient_register.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SyncService.suppressUploadsForTests = true;
    await Hive.openBox(LocalStorageService.patientsBox, bytes: Uint8List(0));
    await Hive.openBox(LocalStorageService.entriesBox, bytes: Uint8List(0));
    await Hive.openBox(LocalStorageService.prescriptionsBox, bytes: Uint8List(0));
    await Hive.openBox(LocalStorageService.dispensaryBox, bytes: Uint8List(0));
    await Hive.openBox(LocalStorageService.syncBox, bytes: Uint8List(0));
    await Hive.openBox(LocalStorageService.auditLogsBox, bytes: Uint8List(0));
    await Hive.openBox('app_settings', bytes: Uint8List(0));
    await Hive.openBox('app_flags', bytes: Uint8List(0));
    LocalStorageService.invalidateLocalEntriesCache();
  });

  tearDown(() async {
    AppToast.clear();
    SyncService.suppressUploadsForTests = false;
    await Hive.close();
  });

  group('Problem 1: Dispense queue always selects smallest waiting token', () {
    test('prescriptionFitsToken matches dashed vs un-dashed adult patientId and child key variants', () {
      const serial = '211126M-HAJI-019';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final nowIso = DateTime.now().toIso8601String();

      final adultTokenDashed = {
        'serial': serial,
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'dateKey': '211126',
        'queueType': 'zakat',
        'patientId': '42301-0730163-2',
        'patientCnic': '42301-0730163-2',
        'patientName': 'Roshan',
        'issuedAtMs': nowMs,
      };
      final adultRxUndashed = {
        'serial': serial,
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'dateKey': '211126',
        'queueType': 'zakat',
        'patientId': '4230107301632',
        'patientCnic': '42301-0730163-2',
        'patientName': 'Roshan',
        'tokenIssuedAtMs': nowMs,
        'completedAt': nowIso,
      };
      expect(LocalStorageService.prescriptionFitsToken(adultRxUndashed, adultTokenDashed), isTrue);

      final childToken = {
        'serial': '211126M-HAJI-025',
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'dateKey': '211126',
        'queueType': 'zakat',
        'patientId': '42301-9415570-8_child_mhashim',
        'patientCnic': '42301-9415570-8',
        'guardianCnic': '42301-9415570-8',
        'patientName': 'M Hashim',
        'isAdult': false,
        'issuedAtMs': nowMs,
      };
      final childRxUnderscore = {
        'serial': '211126M-HAJI-025',
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'dateKey': '211126',
        'queueType': 'zakat',
        'patientId': '4230194155708_child_m_hashim',
        'patientCnic': '42301-9415570-8',
        'patientName': 'M Hashim',
        'tokenIssuedAtMs': nowMs,
        'completedAt': nowIso,
      };
      expect(LocalStorageService.prescriptionFitsToken(childRxUnderscore, childToken), isTrue);

      // Adult and child sharing a CNIC must still NEVER cross-match!
      final adultRxSameCnic = {
        'serial': '211126M-HAJI-025',
        'branchId': 'karachi',
        'dispensaryId': 'haji_camp',
        'dateKey': '211126',
        'queueType': 'zakat',
        'patientId': '4230194155708',
        'patientCnic': '42301-9415570-8',
        'patientName': 'Shezai',
        'tokenIssuedAtMs': nowMs,
        'completedAt': nowIso,
      };
      expect(LocalStorageService.prescriptionFitsToken(adultRxSameCnic, childToken), isFalse);
    });

    test('DispenseQueue includes adult tokens with dashed/un-dashed patientIds and pickNext selects smallest token (#019 not #025)', () async {
      final todayKey = CampSessionService.resolveShiftAndDateKey(null, 'karachi').dateKey;
      final eBox = Hive.box(LocalStorageService.entriesBox);
      final now = DateTime.now();

      Future<void> putPendingToken(int seq, String name, String entryPid, String rxPid, String cnic) async {
        final serial = '${todayKey}M-HAJI-${seq.toString().padLeft(3, '0')}';
        final issuedMs = now.subtract(Duration(minutes: 30 - seq)).millisecondsSinceEpoch;
        final completedIso = now.toIso8601String();
        await eBox.put('karachi-$serial', {
          'serial': serial,
          'id': serial,
          'branchId': 'karachi',
          'dispensaryId': 'haji_camp',
          'campId': 'haji_camp',
          'dispensaryTag': 'HAJI',
          'dateKey': todayKey,
          'session': 'morning',
          'queueType': 'zakat',
          'status': 'completed',
          'dispenseStatus': 'pending',
          'patientId': entryPid,
          'patientName': name,
          'name': name,
          'patientCnic': cnic,
          'cnic': cnic,
          'createdBy': 'rec1',
          'issuedAtMs': issuedMs,
          'createdAt': DateTime.fromMillisecondsSinceEpoch(issuedMs).toIso8601String(),
          'prescription': {
            'serial': serial,
            'branchId': 'karachi',
            'dispensaryId': 'haji_camp',
            'dateKey': todayKey,
            'queueType': 'zakat',
            'patientId': rxPid,
            'patientCnic': cnic,
            'patientName': name,
            'tokenIssuedAtMs': issuedMs,
            'completedAt': completedIso,
            'medicines': [
              {'name': 'Tab. 017', 'quantity': 2, 'timing': '1+0+1'},
            ],
          },
        });
      }

      // Adults #019..#024 have dashed entry patientId (from saveLocalPatient/dedup) and un-dashed rx patientId (from doctor)
      await putPendingToken(19, 'Roshan', '42301-0730163-2', '4230107301632', '42301-0730163-2');
      await putPendingToken(20, 'M Hassain', '42301-0238746-9', '4230102387469', '42301-0238746-9');
      await putPendingToken(24, 'Maryam', '42000-0365525-4', '4200003655254', '42000-0365525-4');
      // Child #025 has matching child patientId
      await putPendingToken(25, 'M Hashim', '42301-9415570-8_child_mhashim', '42301-9415570-8_child_mhashim', '42301-9415570-8');

      LocalStorageService.invalidateLocalEntriesCache();

      final queue = DispenseQueue.compute(
        branchId: 'karachi',
        sessionFilter: 'all',
        campFilter: 'haji_camp',
      );

      final pending = DispenseQueue.pendingInTokenOrder(queue);
      expect(pending.length, 4);
      expect(pending.map((e) => e['serial'].toString().split('-').last).toList(), ['019', '020', '024', '025']);

      // Unpinned pickNext (smallest-first) MUST select #019, never #025
      final next = DispenseQueue.pickNext(queue);
      expect(next?['serial'], '${todayKey}M-HAJI-019');
      expect(next?['patientName'], 'Roshan');
    });
  });

  group('Problems 2 & 3: Adult vs Child identity separation and self-healing', () {
    test('getPatientKey NEVER strips _child_ suffix into adult guardian CNIC key', () {
      expect(
        LocalStorageService.getPatientKey({
          'patientId': '42301-9415570-8_child_mhashim',
          'name': 'M Hashim',
          'guardianCnic': '42301-9415570-8',
          'isAdult': false,
        }),
        '42301-9415570-8_child_mhashim',
      );
      expect(
        LocalStorageService.getPatientKey({
          'patientId': '4230194155708_child_mhashim',
          'name': 'M Hashim',
          'guardianCnic': '42301-9415570-8',
          'isAdult': false,
        }),
        '42301-9415570-8_child_mhashim',
      );
      expect(
        LocalStorageService.getPatientKey({
          'patientId': '4230194155708',
          'name': 'Shezai',
          'cnic': '42301-9415570-8',
          'isAdult': true,
        }),
        '42301-9415570-8',
      );
      // Child mistakenly carrying guardian raw CNIC as patientId gets a child key, not adult key
      expect(
        LocalStorageService.getPatientKey({
          'patientId': '4230194155708',
          'name': 'M Hashim',
          'guardianCnic': '42301-9415570-8',
          'isAdult': false,
        }),
        '42301-9415570-8_child_mhashim',
      );
    });

    test('Saving adult and child under same CNIC + running deduplication preserves both separately with correct names', () async {
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Shezai',
        'cnic': '42301-9415570-8',
        'isAdult': true,
        'age': 38,
        'gender': 'Female',
      });

      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'M Hashim',
        'guardianCnic': '42301-9415570-8',
        'guardianName': 'Shezai',
        'cnic': null,
        'isAdult': false,
        'age': 15,
        'gender': 'Male',
      });

      await LocalStorageService.standardizeAndDeduplicateAllPatients(
        branchId: 'karachi',
        processRemote: false,
      );

      final results = LocalStorageService.searchPatientsByCnicOrGuardian(
        '42301-9415570-8',
        branchId: 'karachi',
      );

      expect(results.length, 2);

      final adult = results.firstWhere((p) => !LocalStorageService.isChildPatientRecord(p));
      final child = results.firstWhere((p) => LocalStorageService.isChildPatientRecord(p));

      expect(adult['patientId'], '42301-9415570-8');
      expect(LocalStorageService.resolveCanonicalPatientName(adult), 'Shezai');
      expect(adult['name'], 'Shezai');
      expect(adult['patientName'], 'Shezai');
      expect(adult['guardianCnic'], isNull);

      expect(child['patientId'], '42301-9415570-8_child_mhashim');
      expect(LocalStorageService.resolveCanonicalPatientName(child), 'M Hashim');
      expect(child['name'], 'M Hashim');
      expect(child['patientName'], 'M Hashim');
      expect(child['guardianName'], 'Shezai');
      expect(child['guardianCnic'], '42301-9415570-8');
      expect(child['cnic'], isNull);
    });

    test('Automatically repairs already-corrupted Shezai / M Hashim Hive records on search & dedup', () async {
      final pBox = Hive.box(LocalStorageService.patientsBox);

      // Simulate exact pre-existing corruption from the screenshots:
      // 1) Adult polluted by _healPatient with child's patientName and guardianCnic
      await pBox.put('42301-9415570-8', {
        'branchId': 'karachi',
        'patientId': '42301-9415570-8',
        'id': '42301-9415570-8',
        'name': 'Shezai',
        'patientName': 'M Hashim',
        'cnic': '42301-9415570-8',
        'guardianCnic': '42301-9415570-8',
        'isAdult': true,
      });

      // 2) Child whose `name` got polluted with guardian's name while `patientName` and `_child_` key have child's name
      await pBox.put('42301-9415570-8_child_mhashim', {
        'branchId': 'karachi',
        'patientId': '42301-9415570-8_child_mhashim',
        'id': '42301-9415570-8_child_mhashim',
        'name': 'Shezai',
        'patientName': 'M Hashim',
        'guardianName': 'Shezai',
        'cnic': '42301-9415570-8',
        'guardianCnic': '42301-9415570-8',
        'isAdult': false,
        'age': 15,
        'gender': 'Female',
      });

      final results = LocalStorageService.searchPatientsByCnicOrGuardian(
        '42301-9415570-8',
        branchId: 'karachi',
      );
      expect(results.length, 2);

      final adult = results.firstWhere((p) => !LocalStorageService.isChildPatientRecord(p));
      final child = results.firstWhere((p) => LocalStorageService.isChildPatientRecord(p));

      expect(LocalStorageService.resolveCanonicalPatientName(adult), 'Shezai');
      expect(adult['name'], 'Shezai');
      expect(adult['patientName'], 'Shezai');
      expect(adult['guardianCnic'], isNull);

      expect(LocalStorageService.resolveCanonicalPatientName(child), 'M Hashim');
      expect(child['name'], 'M Hashim');
      expect(child['patientName'], 'M Hashim');
      expect(child['guardianName'], 'Shezai');
      expect(child['cnic'], isNull);
      expect(child['guardianCnic'], '42301-9415570-8');
    });

    test('resolveCanonicalPatientName never falls back to guardianName for a child', () {
      final childNoName = {
        'patientId': '42301-9415570-8_child_mhashim',
        'guardianCnic': '42301-9415570-8',
        'guardianName': 'Shezai',
        'isAdult': false,
      };
      expect(LocalStorageService.resolveCanonicalPatientName(childNoName), 'mhashim');
      expect(LocalStorageService.resolveCanonicalPatientName(childNoName), isNot('Shezai'));
    });

    test('Self-guardian corrupted adult record (isAdult=false, cnic==guardianCnic, name==guardianName) heals back to Adult', () {
      final corruptedAdult = <String, dynamic>{
        'patientId': '42301-9415570-8',
        'name': 'Shezai',
        'patientName': 'M Hashim',
        'guardianName': 'Shezai',
        'cnic': '42301-9415570-8',
        'guardianCnic': '42301-9415570-8',
        'isAdult': false,
      };
      expect(LocalStorageService.isChildPatientRecord(corruptedAdult), isFalse);
      LocalStorageService.normalizePatientRecordIdentity(corruptedAdult);
      expect(corruptedAdult['isAdult'], isTrue);
      expect(corruptedAdult['name'], 'Shezai');
      expect(corruptedAdult['patientName'], 'Shezai');
      expect(corruptedAdult['guardianCnic'], isNull);
      expect(corruptedAdult['guardianName'], isNull);
    });
  });

  group('Rule: 1 adult per CNIC, multiple children on a CNIC', () {
    test('getLocalAdultByCnic returns null when only children exist, and returns the 1 adult once registered', () async {
      const cnic = '42301-9415570-8';

      // Register two children before any adult exists on this CNIC
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'M Hashim',
        'guardianCnic': cnic,
        'cnic': null,
        'isAdult': false,
        'age': 15,
        'gender': 'Male',
      });
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Zainab',
        'guardianCnic': cnic,
        'cnic': null,
        'isAdult': false,
        'age': 10,
        'gender': 'Female',
      });

      // No adult registered yet -> still allowed to register the 1 adult on this CNIC
      expect(LocalStorageService.getLocalAdultByCnic(cnic), isNull);

      // Register the 1 adult + a 3rd child
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Shezai',
        'cnic': cnic,
        'isAdult': true,
        'age': 38,
        'gender': 'Female',
      });
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Bilal',
        'guardianCnic': cnic,
        'guardianName': 'Shezai',
        'cnic': null,
        'isAdult': false,
        'age': 7,
        'gender': 'Male',
      });

      final adult = LocalStorageService.getLocalAdultByCnic(cnic);
      expect(adult, isNotNull);
      expect(adult!['patientId'], cnic);
      expect(LocalStorageService.resolveCanonicalPatientName(adult), 'Shezai');

      // All 4 family members (1 adult + 3 children) exist separately under the same CNIC
      final family = LocalStorageService.searchPatientsByCnicOrGuardian(cnic, branchId: 'karachi');
      expect(family.length, 4);
      final adults = family.where((p) => !LocalStorageService.isChildPatientRecord(p)).toList();
      final children = family.where((p) => LocalStorageService.isChildPatientRecord(p)).toList();
      expect(adults.length, 1);
      expect(children.length, 3);
      expect(
        children.map(LocalStorageService.resolveCanonicalPatientName).toSet(),
        {'M Hashim', 'Zainab', 'Bilal'},
      );
    });

    test('updatePatientWithCnicMigration keeps dashed adult key and migrates child guardian CNIC cleanly', () async {
      const oldCnic = '42301-1111111-1';
      const newCnic = '42301-2222222-2';

      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Tariq',
        'cnic': oldCnic,
        'isAdult': true,
        'age': 40,
        'gender': 'Male',
      });
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Amina',
        'guardianCnic': oldCnic,
        'guardianName': 'Tariq',
        'cnic': null,
        'isAdult': false,
        'age': 9,
        'gender': 'Female',
      });

      final migratedAdultKey = await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: oldCnic,
        oldCnic: oldCnic,
        updatedPatient: {
          'branchId': 'karachi',
          'name': 'Tariq',
          'cnic': newCnic,
          'isAdult': true,
        },
        isFromSync: true,
      );
      expect(migratedAdultKey, newCnic);
      expect(LocalStorageService.getLocalAdultByCnic(oldCnic), isNull);
      expect(LocalStorageService.getLocalAdultByCnic(newCnic)?['name'], 'Tariq');

      // Child on old CNIC was not deleted by adult migration, and migrates cleanly when edited
      final oldChildKey = '${oldCnic}_child_amina';
      expect(Hive.box(LocalStorageService.patientsBox).containsKey(oldChildKey), isTrue);

      final migratedChildKey = await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: oldChildKey,
        oldCnic: oldCnic,
        updatedPatient: {
          'branchId': 'karachi',
          'name': 'Amina',
          'guardianCnic': newCnic,
          'isAdult': false,
        },
        isFromSync: true,
      );
      expect(migratedChildKey, '${newCnic}_child_amina');
      final pBox = Hive.box(LocalStorageService.patientsBox);
      expect(pBox.containsKey(oldChildKey), isFalse);
      final migratedChild = Map<String, dynamic>.from(pBox.get(migratedChildKey) as Map);
      expect(migratedChild['isAdult'], isFalse);
      expect(migratedChild['guardianCnic'], newCnic);
      expect(migratedChild['cnic'], isNull);
    });

    testWidgets(
      'PatientRegisterPage enforces: child needs adult first, 1 adult per CNIC auto-switches to Child, multiple children allowed',
      timeout: const Timeout(Duration(seconds: 15)),
      (tester) async {
      const adultCnic = '42301-9415570-8';
      const freshCnic = '42301-5555555-5';
      await tester.runAsync(() async {
        await LocalStorageService.saveLocalPatient({
          'branchId': 'karachi',
          'name': 'Shezai',
          'cnic': adultCnic,
          'phone': '03001234567',
          'isAdult': true,
          'age': 38,
          'gender': 'Female',
        });
      });

      final registeredIds = <String>[];
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      Future<void> pumpUi() async {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 500));
      }

      Future<void> tapRegisterAndFlush() async {
        await tester.ensureVisible(find.text('Register Patient'));
        await tester.tap(find.text('Register Patient'));
        await tester.pump();
        for (int i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
          if (find.text('Register Patient').evaluate().isNotEmpty) break;
        }
        await tester.pump(const Duration(milliseconds: 500));
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientRegisterPage(
              branchId: 'karachi',
              receptionistId: 'rec1',
              onPatientRegistered: registeredIds.add,
            ),
          ),
        ),
      );
      await pumpUi();

      RadioListTile<bool> adultRadio() =>
          tester.widget<RadioListTile<bool>>(find.widgetWithText(RadioListTile<bool>, 'Adult'));
      RadioListTile<bool> childRadio() =>
          tester.widget<RadioListTile<bool>>(find.widgetWithText(RadioListTile<bool>, 'Child'));
      final cnicField = find.byType(TextFormField).at(0);
      final nameField = find.byType(TextFormField).at(2);
      final ageField = find.byType(TextFormField).at(3);
      final pBox = Hive.box(LocalStorageService.patientsBox);

      // 1. Starts in Adult mode
      expect(adultRadio().groupValue, isFalse);

      // 2. Selecting Child on a CNIC with NO registered adult shows inline warning & blocks registration
      await tester.tap(find.text('Child'));
      await tester.pump();
      await tester.enterText(cnicField, freshCnic);
      await pumpUi();
      expect(childRadio().groupValue, isTrue);
      expect(find.text('No adult registered on this CNIC'), findsOneWidget);

      await tester.enterText(nameField, 'Orphan Kid');
      await tester.enterText(ageField, '8');
      await tester.pump();
      await tapRegisterAndFlush();

      expect(pBox.containsKey('${freshCnic}_child_orphankid'), isFalse);
      expect(registeredIds, isEmpty);

      // Tapping "Register Adult" switches cleanly back to Adult mode
      await tester.tap(find.text('Register Adult'));
      await pumpUi();
      expect(adultRadio().groupValue, isFalse);
      expect(find.text('No adult registered on this CNIC'), findsNothing);

      // 3. Enter registered adult CNIC -> auto-selects Child & shows inline guardian notice
      await tester.enterText(cnicField, adultCnic);
      await pumpUi();

      expect(childRadio().groupValue, isTrue);
      expect(find.text('Registering a CHILD of Shezai'), findsOneWidget);

      // 4. Tapping Adult radio is blocked (stays in Child mode)
      await tester.tap(find.text('Adult'));
      await pumpUi();
      expect(childRadio().groupValue, isTrue);

      // 5. Directly replacing with a brand-new 13-digit CNIC reverts back to Adult mode
      await tester.enterText(cnicField, freshCnic);
      await pumpUi();
      expect(adultRadio().groupValue, isFalse);
      expect(find.text('Registering a CHILD of Shezai'), findsNothing);

      // 6. Re-enter adult CNIC + SAME adult name -> does NOT create a self-child duplicate
      await tester.enterText(cnicField, adultCnic);
      await pumpUi();
      expect(childRadio().groupValue, isTrue);

      await tester.enterText(nameField, 'Shezai');
      await tester.enterText(ageField, '38');
      await tester.pump();
      await tapRegisterAndFlush();

      expect(pBox.containsKey('${adultCnic}_child_shezai'), isFalse);
      expect(registeredIds, [adultCnic]);

      // 7. Register multiple children on the same adult CNIC -> both saved separately, adult intact
      for (final child in [('M Hashim', '15'), ('Zainab', '10')]) {
        await tester.enterText(cnicField, adultCnic);
        await pumpUi();
        expect(childRadio().groupValue, isTrue);

        await tester.enterText(nameField, child.$1);
        await tester.enterText(ageField, child.$2);
        await tester.pump();
        await tapRegisterAndFlush();
      }

      expect(pBox.containsKey(adultCnic), isTrue);
      expect(pBox.containsKey('${adultCnic}_child_mhashim'), isTrue);
      expect(pBox.containsKey('${adultCnic}_child_zainab'), isTrue);
      expect(
        LocalStorageService.resolveCanonicalPatientName(Map<String, dynamic>.from(pBox.get(adultCnic) as Map)),
        'Shezai',
      );
      expect(registeredIds, [
        adultCnic,
        '${adultCnic}_child_mhashim',
        '${adultCnic}_child_zainab',
      ]);

      // Unmount widget and flush any short debounce timers cleanly before tearDown.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('Item 4: Patient Edit Persistence (Name, Child Rename, DOB, Age, Blood Group across Hive, Tokens, Prescriptions, Merge & Cloud Pulls)', () {
    test('Editing adult & child patient updates name, DOB, age, and 2-char blood group permanently across patientsBox, entriesBox, prescriptionsBox, saveAllLocalPatients, and mergePatientMaps', () async {
      const cnic = '42301-9415570-8';
      const todayKey = '211126';
      const adultSerial = '${todayKey}M-HAJI-010';
      const childSerial = '${todayKey}M-HAJI-011';

      // 1. Register Adult & Child
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'Shezai',
        'cnic': cnic,
        'isAdult': true,
        'age': 38,
        'gender': 'Female',
        'bloodGroup': 'N/A',
      });
      await LocalStorageService.saveLocalPatient({
        'branchId': 'karachi',
        'name': 'M Hashim',
        'guardianCnic': cnic,
        'guardianName': 'Shezai',
        'cnic': null,
        'isAdult': false,
        'age': 15,
        'gender': 'Male',
        'bloodGroup': 'N/A',
      });

      final childPid = '${cnic}_child_mhashim';

      // 2. Issue today tokens and prescriptions for both Adult and Child
      await LocalStorageService.saveEntryLocal('karachi', adultSerial, {
        'serial': adultSerial,
        'id': adultSerial,
        'branchId': 'karachi',
        'dateKey': todayKey,
        'queueType': 'zakat',
        'status': 'completed',
        'dispenseStatus': 'pending',
        'patientId': cnic,
        'patientName': 'Shezai',
        'name': 'Shezai',
        'patientCnic': cnic,
        'cnic': cnic,
        'isAdult': true,
        'age': 38,
        'patientAge': 38,
        'gender': 'Female',
        'patientGender': 'Female',
        'bloodGroup': 'N/A',
        'vitals': {'age': 38, 'gender': 'Female', 'bloodGroup': 'N/A', 'bp': '120/80'},
        'prescription': {
          'serial': adultSerial,
          'branchId': 'karachi',
          'dateKey': todayKey,
          'patientId': cnic,
          'patientName': 'Shezai',
          'name': 'Shezai',
          'patientCnic': cnic,
          'age': 38,
          'gender': 'Female',
          'bloodGroup': 'N/A',
          'medicines': [
            {'name': 'Tab. 017', 'quantity': 2, 'timing': '1+0+1'},
          ],
        },
      });
      await LocalStorageService.saveLocalPrescription({
        'id': adultSerial,
        'serial': adultSerial,
        'branchId': 'karachi',
        'dateKey': todayKey,
        'patientId': cnic,
        'patientName': 'Shezai',
        'name': 'Shezai',
        'patientCnic': cnic,
        'age': 38,
        'patientAge': 38,
        'gender': 'Female',
        'patientGender': 'Female',
        'bloodGroup': 'N/A',
        'medicines': [
          {'name': 'Tab. 017', 'quantity': 2, 'timing': '1+0+1'},
        ],
      });

      await LocalStorageService.saveEntryLocal('karachi', childSerial, {
        'serial': childSerial,
        'id': childSerial,
        'branchId': 'karachi',
        'dateKey': todayKey,
        'queueType': 'zakat',
        'status': 'completed',
        'dispenseStatus': 'pending',
        'patientId': childPid,
        'patientName': 'M Hashim',
        'name': 'M Hashim',
        'patientCnic': cnic,
        'guardianCnic': cnic,
        'guardianName': 'Shezai',
        'isAdult': false,
        'age': 15,
        'patientAge': 15,
        'gender': 'Male',
        'patientGender': 'Male',
        'bloodGroup': 'N/A',
        'vitals': {'age': 15, 'gender': 'Male', 'bloodGroup': 'N/A'},
        'prescription': {
          'serial': childSerial,
          'branchId': 'karachi',
          'dateKey': todayKey,
          'patientId': childPid,
          'patientName': 'M Hashim',
          'name': 'M Hashim',
          'patientCnic': cnic,
          'guardianCnic': cnic,
          'isAdult': false,
          'age': 15,
          'gender': 'Male',
          'bloodGroup': 'N/A',
          'medicines': [
            {'name': 'Syp. 005', 'quantity': 1, 'timing': '1+0+1'},
          ],
        },
      });
      await LocalStorageService.saveLocalPrescription({
        'id': childSerial,
        'serial': childSerial,
        'branchId': 'karachi',
        'dateKey': todayKey,
        'patientId': childPid,
        'patientName': 'M Hashim',
        'name': 'M Hashim',
        'patientCnic': cnic,
        'guardianCnic': cnic,
        'isAdult': false,
        'age': 15,
        'patientAge': 15,
        'gender': 'Male',
        'patientGender': 'Male',
        'bloodGroup': 'N/A',
        'medicines': [
          {'name': 'Syp. 005', 'quantity': 1, 'timing': '1+0+1'},
        ],
      });

      // 3. Edit Adult: change name to shorter name 'Sana', DOB to '15-08-1985', Blood Group to 2-char 'A+'
      await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: cnic,
        oldCnic: cnic,
        updatedPatient: {
          'branchId': 'karachi',
          'name': 'Sana',
          'cnic': cnic,
          'dob': '15-08-1985',
          'bloodGroup': 'A+',
          'gender': 'Female',
          'isAdult': true,
        },
        isFromSync: true,
      );

      // 4. Edit Child: rename 'M Hashim' -> 'Ali Raza', DOB '10-05-2014', Blood Group 'O+'
      await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: childPid,
        oldCnic: cnic,
        updatedPatient: {
          'branchId': 'karachi',
          'name': 'Ali Raza',
          'guardianCnic': cnic,
          'dob': '10-05-2014',
          'bloodGroup': 'O+',
          'gender': 'Male',
          'isAdult': false,
        },
        isFromSync: true,
      );

      // Second edit on the already-renamed child (e.g. changing bloodGroup from 'O+' to 'B+')
      // must NOT lose `nameEditedAt` or revert child name back to 'M Hashim' from key `_child_mhashim`!
      await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: childPid,
        oldCnic: cnic,
        updatedPatient: {
          'branchId': 'karachi',
          'name': 'Ali Raza',
          'guardianCnic': cnic,
          'bloodGroup': 'B+',
          'isAdult': false,
        },
        isFromSync: true,
      );

      // 5. Verify patientsBox records
      final savedAdult = LocalStorageService.getLocalPatient(cnic)!;
      final expectedAdultAge = LocalStorageService.calculateAgeFromDob('1985-08-15');
      expect(LocalStorageService.resolveCanonicalPatientName(savedAdult), 'Sana');
      expect(savedAdult['name'], 'Sana');
      expect(savedAdult['patientName'], 'Sana');
      expect(savedAdult['fullName'], 'Sana');
      expect(savedAdult['bloodGroup'], 'A+');
      expect(LocalStorageService.tryParseDob(savedAdult['dob'])?.year, 1985);
      expect(savedAdult['age'], expectedAdultAge);

      final savedChild = LocalStorageService.getLocalPatient(childPid)!;
      final expectedChildAge = LocalStorageService.calculateAgeFromDob('2014-05-10');
      expect(LocalStorageService.resolveCanonicalPatientName(savedChild), 'Ali Raza');
      expect(savedChild['name'], 'Ali Raza');
      expect(savedChild['patientName'], 'Ali Raza');
      expect(savedChild['fullName'], 'Ali Raza');
      expect(savedChild['bloodGroup'], 'B+');
      expect(LocalStorageService.tryParseDob(savedChild['dob'])?.year, 2014);
      expect(savedChild['age'], expectedChildAge);

      // 6. Verify active entries in entriesBox AND prescriptionsBox were updated
      final adultEntry = LocalStorageService.getLocalEntry('karachi', adultSerial)!;
      expect(adultEntry['patientName'], 'Sana');
      expect(adultEntry['name'], 'Sana');
      expect(adultEntry['bloodGroup'], 'A+');
      expect(adultEntry['age'], expectedAdultAge);
      expect((adultEntry['vitals'] as Map)['bloodGroup'], 'A+');
      expect((adultEntry['vitals'] as Map)['age'], expectedAdultAge);
      expect((adultEntry['prescription'] as Map)['patientName'], 'Sana');
      expect((adultEntry['prescription'] as Map)['bloodGroup'], 'A+');

      final childEntry = LocalStorageService.getLocalEntry('karachi', childSerial)!;
      expect(childEntry['patientName'], 'Ali Raza');
      expect(childEntry['name'], 'Ali Raza');
      expect(childEntry['bloodGroup'], 'B+');
      expect(childEntry['age'], expectedChildAge);
      expect((childEntry['vitals'] as Map)['bloodGroup'], 'B+');
      expect((childEntry['vitals'] as Map)['age'], expectedChildAge);
      expect((childEntry['prescription'] as Map)['patientName'], 'Ali Raza');
      expect((childEntry['prescription'] as Map)['bloodGroup'], 'B+');

      final childRx = LocalStorageService.getLocalPrescription(childSerial, branchId: 'karachi')!;
      expect(childRx['patientName'], 'Ali Raza');
      expect(childRx['bloodGroup'], 'B+');
      expect(childRx['age'], expectedChildAge);

      // 7. Verify mergePatientMaps and saveAllLocalPatients (stale cloud pull with 'N/A' bloodGroup
      //    and longer old name 'Shezai') NEVER overwrite the edited name, DOB, or 2-char blood group!
      final merged = LocalStorageService.mergePatientMaps(savedAdult, {
        'patientId': cnic,
        'name': 'Shezai',
        'patientName': 'Shezai',
        'cnic': cnic,
        'bloodGroup': 'N/A',
        'isAdult': true,
      });
      expect(merged['name'], 'Sana');
      expect(merged['bloodGroup'], 'A+');

      await LocalStorageService.saveAllLocalPatients([
        {
          'patientId': cnic,
          'branchId': 'karachi',
          'name': 'Shezai',
          'cnic': cnic,
          'bloodGroup': 'N/A',
          'isAdult': true,
        },
        {
          'patientId': childPid,
          'branchId': 'karachi',
          'name': 'M Hashim',
          'guardianCnic': cnic,
          'bloodGroup': 'N/A',
          'isAdult': false,
        },
      ]);

      final afterCloudPullAdult = LocalStorageService.getLocalPatient(cnic)!;
      expect(LocalStorageService.resolveCanonicalPatientName(afterCloudPullAdult), 'Sana');
      expect(afterCloudPullAdult['bloodGroup'], 'A+');
      expect(afterCloudPullAdult['age'], expectedAdultAge);

      final afterCloudPullChild = LocalStorageService.getLocalPatient(childPid)!;
      expect(LocalStorageService.resolveCanonicalPatientName(afterCloudPullChild), 'Ali Raza');
      expect(afterCloudPullChild['bloodGroup'], 'B+');
      expect(afterCloudPullChild['age'], expectedChildAge);
    });
  });
}
