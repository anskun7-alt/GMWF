// test/proforma_medicines_test.dart

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/services/master_proforma_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_proforma_test');
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

  group('Master Proforma Catalog & Medicine Formula Tests', () {
    test('Catalog contains 400mg Panadol, Orphenadrine Citrate + Paracetamol, and Paracetamol + CPM + Dextromethorphan', () {
      final all = MasterProformaService.getAllProformaItems();

      final para400 = all.firstWhere((e) => e['code'] == 'MED-PARA-400', orElse: () => {});
      expect(para400.isNotEmpty, isTrue);
      expect(para400['dose'], equals('400 mg'));
      expect(para400['name'], contains('Paracetamol'));

      final orph = all.firstWhere((e) => e['code'] == 'MED-ORPH-PARA-TAB', orElse: () => {});
      expect(orph.isNotEmpty, isTrue);
      expect(orph['formula'], equals('Orphenadrine Citrate + Paracetamol (Norgesic)'));

      final coldTab = all.firstWhere((e) => e['code'] == 'MED-PARA-CPM-DXM-TAB', orElse: () => {});
      expect(coldTab.isNotEmpty, isTrue);
      expect(coldTab['formula'], contains('Dextromethorphan'));

      final coldSyr = all.firstWhere((e) => e['code'] == 'MED-PARA-CPM-DXM-SYR', orElse: () => {});
      expect(coldSyr.isNotEmpty, isTrue);
      expect(coldSyr['type'], equals('Syrup'));
    });

    test('cleanBrandToFormula canonicalizes Orphenadrine and Panadol CF formulas correctly', () {
      expect(
        MasterProformaService.cleanBrandToFormula('Orphnadrin-Citre-Paracetamol'),
        equals('Orphenadrine Citrate + Paracetamol (Norgesic)'),
      );

      expect(
        MasterProformaService.cleanBrandToFormula('Paracetamol-Chlorpheramine-Dextromethorphan'),
        equals('Paracetamol + Chlorpheniramine + Dextromethorphan (Panadol CF / T-Day)'),
      );

      expect(
        MasterProformaService.cleanBrandToFormula('Panadol 400mg'),
        equals('Paracetamol (Panadol)'),
      );
    });

    test('Catalog contains 200 mg Metronidazole (Flagyl) Tablet and preserves all Flagyl tablet strengths after seeding', () async {
      await MasterProformaService.seedDefaultProformaIfEmpty();
      final all = MasterProformaService.getAllProformaItems();

      final flg100 = all.firstWhere((e) => e['code'] == 'MED-FLG-100', orElse: () => {});
      final flg200 = all.firstWhere((e) => e['code'] == 'MED-FLG-200', orElse: () => {});
      final flg400 = all.firstWhere((e) => e['code'] == 'MED-FLG-400', orElse: () => {});

      expect(flg100['dose'], equals('100 mg'));
      expect(flg100['barcode'], equals('052'));

      expect(flg200.isNotEmpty, isTrue);
      expect(flg200['barcode'], equals('079'));
      expect(flg200['rollNo'], equals('079'));
      expect(flg200['itemCode'], equals('MED-FLG-200'));
      expect(flg200['name'], equals('Metronidazole (Flagyl)'));
      expect(flg200['formula'], equals('Metronidazole (Flagyl)'));
      expect(flg200['type'], equals('Tablet'));
      expect(flg200['dose'], equals('200 mg'));

      expect(flg400['dose'], equals('400 mg'));
      expect(flg400['barcode'], equals('053'));

      expect(MasterProformaService.findExactBarcodeMatch('079')?['code'], equals('MED-FLG-200'));
      expect(MasterProformaService.findExactBarcodeMatch('MED-FLG-200')?['dose'], equals('200 mg'));
      expect(
        MasterProformaService.findExactNameDoseTypeMatch('Metronidazole (Flagyl)', 'Tablet', '200 mg')?['code'],
        equals('MED-FLG-200'),
      );

      final stockRow = <String, dynamic>{
        'name': 'Flagyl',
        'type': 'Tablet',
        'dose': '200mg',
      };
      MasterProformaService.alignStockItemWithProforma(stockRow);
      expect(stockRow['code'], equals('MED-FLG-200'));
      expect(stockRow['barcode'], equals('079'));
      expect(stockRow['dose'], equals('200 mg'));

      expect(all.where((e) => e['barcode'] == '079').length, equals(1));
      expect(all.where((e) => e['code'] == 'MED-FLG-200').length, equals(1));
    });
  });
}
