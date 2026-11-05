import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/dispensary/dispensar/patient_form_helper.dart';
import 'package:gmwf/services/camp_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('injectable prescriptions (syringe/needle auto-count)', () {
    bool inj(String type, String name) => PatientFormHelper.isInjectablePrescription(type, name);

    test('real injections and IV count', () {
      expect(inj('Injection', 'Ceftriaxone 1g'), isTrue);
      expect(inj('', 'Inj. Dexamethasone'), isTrue);
      expect(inj('', 'IV Paracetamol'), isTrue);
      expect(inj('drip', 'Ringer Lactate'), isTrue);
      expect(inj('', 'Normal saline I.V.'), isTrue);
    });

    test('oral medicines with "iv" inside the name do NOT count', () {
      expect(inj('Tablet', 'Multivitamin'), isFalse);
      expect(inj('', 'Ivermectin 6mg'), isFalse);
      expect(inj('', 'Rivotril 0.5mg'), isFalse);
      expect(inj('', 'Ativan 1mg'), isFalse);
      expect(inj('Syrup', 'Multivitamin syrup'), isFalse);
    });
  });

  group('syringe stock items', () {
    bool syr(String type, String name, [String cat = '']) =>
        PatientFormHelper.isSyringeStockItem(type, name, cat);

    test('syringes are recognised (incl. the app\'s own "syr." type)', () {
      expect(syr('syringe', 'Disposable Syringe 5cc'), isTrue);
      expect(syr('syr.', '3cc'), isTrue);
      expect(syr('', 'Disp. Syr 10ml'), isTrue);
      expect(syr('', 'Syr 5cc', 'Consumables'), isTrue);
    });

    test('syrups are never syringes', () {
      expect(syr('Syrup', 'Syr. Brufen 120ml'), isFalse);
      expect(syr('', 'Syr. Panadol 60ml'), isFalse);
      expect(syr('syp.', 'Calpol'), isFalse);
      expect(syr('Suspension', 'Augmentin 156mg'), isFalse);
    });
  });

  group('late-night carry-over (sessions past midnight)', () {
    final now = DateTime(2026, 11, 6, 0, 30); // 00:30 on 6 Nov
    Map<String, dynamic> tok(DateTime issued, {String date = '051126'}) => {
          'serial': '${date}E-GUJ-040',
          'issuedAtMs': issued.millisecondsSinceEpoch,
        };

    test('a token issued at 23:50 yesterday stays after midnight', () {
      expect(CampSessionService.isLateNightCarryOver(tok(DateTime(2026, 11, 5, 23, 50)), 'gujrat', now), isTrue);
    });

    test('an abandoned morning token from yesterday does not resurface', () {
      expect(CampSessionService.isLateNightCarryOver(tok(DateTime(2026, 11, 5, 9, 0)), 'gujrat', now), isFalse);
    });

    test('nothing is carried over after 06:00', () {
      expect(
          CampSessionService.isLateNightCarryOver(
              tok(DateTime(2026, 11, 5, 23, 50)), 'gujrat', DateTime(2026, 11, 6, 6, 5)),
          isFalse);
    });

    test('a token from two days ago is never carried over', () {
      expect(
          CampSessionService.isLateNightCarryOver(
              tok(DateTime(2026, 11, 5, 23, 50), date: '041126'), 'gujrat', now),
          isFalse);
    });
  });
}
