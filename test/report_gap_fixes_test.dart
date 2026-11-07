import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/dispensary/dispensar/patient_form_helper.dart';
import 'package:gmwf/services/local_storage_service.dart';

/// Gaps found when checking the fixes report against the code (2026-11-07).
void main() {
  group('timing: a bare number is times per day', () {
    test('2 -> 1+0+1, 3 -> 1+1+1, 1 -> 1+0+0', () {
      expect(PatientFormHelper.resolveCanonicalTiming('2').timing, '1+0+1');
      expect(PatientFormHelper.resolveCanonicalTiming('2').dailyQty, 2);
      expect(PatientFormHelper.resolveCanonicalTiming('3').timing, '1+1+1');
      expect(PatientFormHelper.resolveCanonicalTiming('1').timing, '1+0+0');
      expect(
          PatientFormHelper.resolveCanonicalTiming('1', mealTiming: 'Before Sleep').timing, '0+0+1');
    });

    test('empty timing is once a day, never twice', () {
      final r = PatientFormHelper.resolveCanonicalTiming('');
      expect(r.timing, '1+0+0');
      expect(r.dailyQty, 1);
    });

    test('explicit slots are kept as typed', () {
      expect(PatientFormHelper.resolveCanonicalTiming('2+0+0').timing, '2+0+0');
      expect(PatientFormHelper.resolveCanonicalTiming('1+1').timing, '1+1+0');
      expect(PatientFormHelper.resolveCanonicalTiming('1+1').dailyQty, 2);
    });
  });

  group('revision numbers arriving as text', () {
    test('intOf reads numbers and numeric strings', () {
      expect(LocalStorageService.intOf(2), 2);
      expect(LocalStorageService.intOf('3'), 3);
      expect(LocalStorageService.intOf('2.0'), 2);
      expect(LocalStorageService.intOf(null), 0);
      expect(LocalStorageService.intOf('x'), 0);
    });

    test('a string revision no longer throws and still wins', () {
      final ex = {
        'serial': '071126M-HAJI-Z-005', 'patientId': 'p1', 'patientName': 'Ali',
        'revision': 1, 'medicines': [{'name': 'Panadol'}],
      };
      final inc = {...ex, 'revision': '2', 'medicines': [{'name': 'Brufen'}]};
      expect(LocalStorageService.mayReplacePrescription(inc, ex), isTrue);
    });
  });

  group('receptionist rename vs doctor save', () {
    final renamed = {
      'serial': '071126M-HAJI-Z-007', 'patientId': 'p7', 'patientName': 'Muhammad Ali',
      'identityRevision': 1, 'revision': 1, 'medicines': [{'name': 'Panadol'}],
    };

    test('doctor copy with the old name (same patientId) is accepted', () {
      final doctor = {
        'serial': '071126M-HAJI-Z-007', 'patientId': 'p7', 'patientName': 'Mohd Ali',
        'revision': 2, 'medicines': [{'name': 'Brufen'}],
      };
      expect(LocalStorageService.mayReplacePrescription(doctor, renamed), isTrue);
    });

    test('a different family member on the same CNIC is still rejected', () {
      final mother = {
        'serial': '071126M-HAJI-Z-007', 'patientId': 'p7', 'patientName': 'Ayesha',
        'patientCnic': '1111111111111', 'revision': 1, 'medicines': [{'name': 'Panadol'}],
      };
      final child = {
        'serial': '071126M-HAJI-Z-007', 'patientId': 'p8', 'patientName': 'Bilal',
        'patientCnic': '1111111111111', 'revision': 2, 'medicines': [{'name': 'Syrup'}],
      };
      expect(LocalStorageService.mayReplacePrescription(child, mother), isFalse);
    });
  });
}
