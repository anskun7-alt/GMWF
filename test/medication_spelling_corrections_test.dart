import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/Pages/dispensary/dispensar/patient_form_helper.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_med_spelling_test');
    Hive.init(tempDir.path);
    if (!Hive.isBoxOpen(MasterProformaService.boxName)) {
      await Hive.openBox(MasterProformaService.boxName);
    }
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Medication spelling corrections', () {
    test('Master Proforma catalog exposes all 6 corrected spellings with intact metadata', () async {
      await MasterProformaService.seedDefaultProformaIfEmpty();
      final all = MasterProformaService.getAllProformaItems();

      Map<String, dynamic> byCode(String code) =>
          all.firstWhere((e) => e['code'] == code, orElse: () => {});

      // 1. Ammonium Chloride (Cough Syrup)
      final amc = byCode('MED-AMC-SYR');
      expect(amc['barcode'], equals('401'));
      expect(amc['name'], equals('Ammonium Chloride (Cough Syrup)'));
      expect(amc['formula'], equals('Ammonium Chloride (Cough Syrup)'));
      expect(amc['type'], equals('Syrup'));
      expect(amc['dose'], equals('15 ml'));

      // 2. B-12 (Cyanocobalamin)
      final b12 = byCode('MED-B12-INJ');
      expect(b12['barcode'], equals('500'));
      expect(b12['name'], equals('B-12 (Cyanocobalamin)'));
      expect(b12['formula'], equals('B-12 (Cyanocobalamin)'));
      expect(b12['type'], equals('Injection'));
      expect(b12['dose'], equals('1 cc'));

      // 3. Promethazine HCL (Metoclon Syrup)
      final proSyr = byCode('MED-METCL-SYR');
      expect(proSyr['barcode'], equals('415'));
      expect(proSyr['name'], equals('Promethazine HCL (Metoclon Syrup)'));
      expect(proSyr['formula'], equals('Promethazine HCL (Metoclon Syrup)'));
      expect(proSyr['type'], equals('Syrup'));
      expect(proSyr['dose'], equals('15 ml'));

      // Tablet & Injection Metoclopramide entries remain Metoclopramide
      for (final code in ['MED-METCL-TAB', 'MED-MTC-20', 'MED-MTC-5', 'MED-MTC-INJ', 'MED-METCL-INJ']) {
        final item = byCode(code);
        expect(item['name'], equals('Metoclopramide (Maxolon / Metoclone)'), reason: 'code=$code');
      }

      // 4. Ringer's Lactate (R/L)
      final rl1000 = byCode('MED-RL-1000');
      expect(rl1000['barcode'], equals('610'));
      expect(rl1000['name'], equals("Ringer's Lactate (R/L)"));
      expect(rl1000['formula'], equals("Ringer's Lactate (R/L)"));
      expect(rl1000['type'], equals('Infusion'));
      expect(rl1000['dose'], equals('1000 ml'));

      final rl500 = byCode('MED-RL-500');
      expect(rl500['barcode'], equals('611'));
      expect(rl500['name'], equals("Ringer's Lactate (R/L)"));
      expect(rl500['formula'], equals("Ringer's Lactate (R/L)"));
      expect(rl500['type'], equals('Infusion'));
      expect(rl500['dose'], equals('500 ml'));

      // 5. Sodium Bicarbonate (Sodamint)
      for (final entry in [
        ('MED-SDM-1G', '073', '1 g'),
        ('MED-SDM-TAB', '074', 'Standard'),
        ('MED-SBC-300', '075', '300 mg'),
      ]) {
        final item = byCode(entry.$1);
        expect(item['barcode'], equals(entry.$2));
        expect(item['name'], equals('Sodium Bicarbonate (Sodamint)'));
        expect(item['formula'], equals('Sodium Bicarbonate (Sodamint)'));
        expect(item['type'], equals('Tablet'));
        expect(item['dose'], equals(entry.$3));
      }

      // 6. Vitamin B9 (Folic Acid)
      final fol = byCode('MED-FOL-TAB');
      expect(fol['barcode'], equals('034'));
      expect(fol['name'], equals('Vitamin B9 (Folic Acid)'));
      expect(fol['formula'], equals('Vitamin B9 (Folic Acid)'));
      expect(fol['type'], equals('Tablet'));
      expect(fol['dose'], equals('5 mg'));
    });

    test('cleanBrandToFormula normalizes legacy and current spellings accurately without unintended changes', () {
      // 1. Ammonium Chloride (Cough Syrup)
      expect(
        MasterProformaService.cleanBrandToFormula('Amonium Chloride (Cough Syrup)'),
        equals('Ammonium Chloride (Cough Syrup)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Ammonium Chloride (Cough Syrup)'),
        equals('Ammonium Chloride (Cough Syrup)'),
      );

      // 2. B-12 (Cyanocobalamin)
      expect(
        MasterProformaService.cleanBrandToFormula('B-12 (Cynocobalmin)'),
        equals('B-12 (Cyanocobalamin)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('B-12 (Cyanocobalamin)'),
        equals('B-12 (Cyanocobalamin)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Cynocobalmin'),
        equals('B-12 (Cyanocobalamin)'),
      );

      // 3. Promethazine HCL (Metoclon Syrup) vs untouched Metoclopramide
      expect(
        MasterProformaService.cleanBrandToFormula('Promethazine HCL (Metoclon Syrup)'),
        equals('Promethazine HCL (Metoclon Syrup)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Metoclon Syrup'),
        equals('Promethazine HCL (Metoclon Syrup)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Metoclopramide (Maxolon / Metoclone)'),
        equals('Metoclopramide (Maxolon / Metoclone)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Metoclopramide (Metoclone)'),
        equals('Metoclopramide (Maxolon / Metoclone)'),
      );

      // 4. Ringer's Lactate (R/L)
      expect(
        MasterProformaService.cleanBrandToFormula('Ringer Lactate (R/L)'),
        equals("Ringer's Lactate (R/L)"),
      );
      expect(
        MasterProformaService.cleanBrandToFormula("Ringer's Lactate (R/L)"),
        equals("Ringer's Lactate (R/L)"),
      );

      // 5. Sodium Bicarbonate (Sodamint) — without touching unrelated sodium salts
      expect(
        MasterProformaService.cleanBrandToFormula('Sodamint'),
        equals('Sodium Bicarbonate (Sodamint)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Sodium Bicarbonate'),
        equals('Sodium Bicarbonate (Sodamint)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Sodium Bicarbonate (Sodamint)'),
        equals('Sodium Bicarbonate (Sodamint)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Sodium Acid Citrate'),
        equals('Sodium Acid Citrate'),
      );

      // 6. Vitamin B9 (Folic Acid) — without touching other B vitamins
      expect(
        MasterProformaService.cleanBrandToFormula('Folic Acid'),
        equals('Vitamin B9 (Folic Acid)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Vitamin B9 (Folic Acid)'),
        equals('Vitamin B9 (Folic Acid)'),
      );
      expect(
        MasterProformaService.cleanBrandToFormula('Vitamin B-complex (BC)'),
        equals('Vitamin B-complex (BC)'),
      );
    });

    test('Cached pre-update Hive proforma entries and stock alignment resolve to corrected names', () async {
      final box = Hive.box(MasterProformaService.boxName);
      await box.put('proforma:MED-METCL-SYR', {
        'barcode': '415',
        'rollNo': '415',
        'itemCode': 'MED-METCL-SYR',
        'code': 'MED-METCL-SYR',
        'name': 'Metoclopramide (Metoclone)',
        'formula': 'Metoclopramide (Metoclone)',
        'type': 'Syrup',
        'dose': '15 ml',
        'defaultPrice': 70.00,
        'isProformaMaster': true,
      });
      await box.put('proforma:MED-B12-INJ', {
        'barcode': '500',
        'rollNo': '500',
        'itemCode': 'MED-B12-INJ',
        'code': 'MED-B12-INJ',
        'name': 'B-12 (Cynocobalmin)',
        'formula': 'B-12 (Cynocobalmin)',
        'type': 'Injection',
        'dose': '1 cc',
        'defaultPrice': 40.00,
        'isProformaMaster': true,
      });

      final all = MasterProformaService.getAllProformaItems();
      final syr = all.firstWhere((e) => e['code'] == 'MED-METCL-SYR');
      expect(syr['name'], equals('Promethazine HCL (Metoclon Syrup)'));
      expect(syr['formula'], equals('Promethazine HCL (Metoclon Syrup)'));

      final b12 = all.firstWhere((e) => e['code'] == 'MED-B12-INJ');
      expect(b12['name'], equals('B-12 (Cyanocobalamin)'));

      // Stock alignment maps legacy records to corrected names
      final legacyStock = <Map<String, dynamic>>[
        {'name': 'Amonium Chloride (Cough Syrup)', 'type': 'Syrup', 'dose': '15 ml'},
        {'name': 'B-12 (Cynocobalmin)', 'type': 'Injection', 'dose': '1 cc'},
        {'code': 'MED-METCL-SYR', 'name': 'Metoclopramide (Metoclone)', 'type': 'Syrup', 'dose': '15 ml'},
        {'name': 'Ringer Lactate (R/L)', 'type': 'Infusion', 'dose': '1000 ml'},
        {'name': 'Sodamint', 'type': 'Tablet', 'dose': '1 g'},
        {'name': 'Sodium Bicarbonate', 'type': 'Tablet', 'dose': '300 mg'},
        {'name': 'Folic Acid', 'type': 'Tablet', 'dose': '5 mg'},
      ];

      for (final item in legacyStock) {
        MasterProformaService.alignStockItemWithProforma(item);
      }

      expect(legacyStock[0]['name'], equals('Ammonium Chloride (Cough Syrup)'));
      expect(legacyStock[1]['name'], equals('B-12 (Cyanocobalamin)'));
      expect(legacyStock[2]['name'], equals('Promethazine HCL (Metoclon Syrup)'));
      expect(legacyStock[3]['name'], equals("Ringer's Lactate (R/L)"));
      expect(legacyStock[4]['name'], equals('Sodium Bicarbonate (Sodamint)'));
      expect(legacyStock[4]['barcode'], equals('073'));
      expect(legacyStock[5]['name'], equals('Sodium Bicarbonate (Sodamint)'));
      expect(legacyStock[5]['barcode'], equals('075'));
      expect(legacyStock[6]['name'], equals('Vitamin B9 (Folic Acid)'));
      expect(legacyStock[6]['barcode'], equals('034'));

      // Infusion/injectable detection still recognizes Ringer's Lactate (R/L)
      expect(PatientFormHelper.isInjectable({'name': "Ringer's Lactate (R/L)", 'type': ''}), isTrue);
      expect(PatientFormHelper.isInjectable({'name': "Ringer's Lactate (R/L)", 'type': 'Infusion'}), isTrue);
      expect(PatientFormHelper.isInjectable({'name': 'Promethazine HCL (Metoclon Syrup)', 'type': 'Syrup'}), isFalse);
    });
  });
}
