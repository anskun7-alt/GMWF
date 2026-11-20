// lib/services/master_proforma_service.dart

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_ledger.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';

/// Service responsible for managing the Universal Master Proforma Medicine Catalog.
/// Strictly uses Generic Formulas only (no commercial brand names allowed).
/// Non-editable fields: code/barcode, name (formula), formula, type, dose.
/// Editable fields at branch level: quantity, price, expiry date.
class MasterProformaService {
  static const String boxName = LocalStorageService.masterProformaBox;

  /// Default Master Seed Catalog using generic medicine formulas ONLY.
  static final List<Map<String, dynamic>> _defaultProformaList = [
    {
      'barcode': '001',
      'rollNo': '001',
      'itemCode': 'MED-ATT-5',
      'code': 'MED-ATT-5',
      'name': 'Activated Attapulgite',
      'formula': 'Activated Attapulgite',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '002',
      'rollNo': '002',
      'itemCode': 'MED-ATT-50',
      'code': 'MED-ATT-50',
      'name': 'Activated Attapulgite',
      'formula': 'Activated Attapulgite',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '003',
      'rollNo': '003',
      'itemCode': 'MED-AMP-100',
      'code': 'MED-AMP-100',
      'name': 'Aminophylline',
      'formula': 'Aminophylline',
      'type': 'Tablet',
      'dose': '100 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '004',
      'rollNo': '004',
      'itemCode': 'MED-AML-5',
      'code': 'MED-AML-5',
      'name': 'Amlodipine Besylate',
      'formula': 'Amlodipine Besylate',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '005',
      'rollNo': '005',
      'itemCode': 'MED-AML-50',
      'code': 'MED-AML-50',
      'name': 'Amlodipine Besylate',
      'formula': 'Amlodipine Besylate',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '006',
      'rollNo': '006',
      'itemCode': 'MED-ANT-TRI-TAB',
      'code': 'MED-ANT-TRI-TAB',
      'name': 'Antacid (Trisil)',
      'formula': 'Antacid (Trisil)',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '007',
      'rollNo': '007',
      'itemCode': 'MED-ASP-75',
      'code': 'MED-ASP-75',
      'name': 'Aspirin',
      'formula': 'Aspirin',
      'type': 'Tablet',
      'dose': '75 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '008',
      'rollNo': '008',
      'itemCode': 'MED-ASP-300',
      'code': 'MED-ASP-300',
      'name': 'Aspirin (Disprin)',
      'formula': 'Aspirin (Disprin)',
      'type': 'Tablet',
      'dose': '300 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '009',
      'rollNo': '009',
      'itemCode': 'MED-ASP-50',
      'code': 'MED-ASP-50',
      'name': 'Aspirin (Disprin)',
      'formula': 'Aspirin (Disprin)',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '010',
      'rollNo': '010',
      'itemCode': 'MED-BIS-5',
      'code': 'MED-BIS-5',
      'name': 'Bisacodyl',
      'formula': 'Bisacodyl',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '011',
      'rollNo': '011',
      'itemCode': 'MED-BRC-100',
      'code': 'MED-BRC-100',
      'name': 'Broncophylline',
      'formula': 'Broncophylline',
      'type': 'Tablet',
      'dose': '100 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '012',
      'rollNo': '012',
      'itemCode': 'MED-CAL-TAB',
      'code': 'MED-CAL-TAB',
      'name': 'Calcium',
      'formula': 'Calcium',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '013',
      'rollNo': '013',
      'itemCode': 'MED-CAL-300',
      'code': 'MED-CAL-300',
      'name': 'Calcium Lactate',
      'formula': 'Calcium Lactate',
      'type': 'Tablet',
      'dose': '300 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '014',
      'rollNo': '014',
      'itemCode': 'MED-CAP-25-TAB',
      'code': 'MED-CAP-25-TAB',
      'name': 'Captopril (Capoten)',
      'formula': 'Captopril (Capoten)',
      'type': 'Tablet',
      'dose': '25 mg',
      'defaultPrice': 6.50,
      'isProformaMaster': true,
    },
    {
      'barcode': '015',
      'rollNo': '015',
      'itemCode': 'MED-CRV-20',
      'code': 'MED-CRV-20',
      'name': 'Carvedilol',
      'formula': 'Carvedilol',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 12.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '016',
      'rollNo': '016',
      'itemCode': 'MED-CET-5',
      'code': 'MED-CET-5',
      'name': 'Cetirizine',
      'formula': 'Cetirizine',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '017',
      'rollNo': '017',
      'itemCode': 'MED-CPM-4',
      'code': 'MED-CPM-4',
      'name': 'Chloropheniramine Maleate (CPM)',
      'formula': 'Chloropheniramine Maleate (CPM)',
      'type': 'Tablet',
      'dose': '4 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '018',
      'rollNo': '018',
      'itemCode': 'MED-CPM-40',
      'code': 'MED-CPM-40',
      'name': 'Chlorpheniramine Maleate (CPM)',
      'formula': 'Chlorpheniramine Maleate (CPM)',
      'type': 'Tablet',
      'dose': '40 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '019',
      'rollNo': '019',
      'itemCode': 'MED-CPM-5',
      'code': 'MED-CPM-5',
      'name': 'Chlorpheniramine Maleate (CPM)',
      'formula': 'Chlorpheniramine Maleate (CPM)',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '020',
      'rollNo': '020',
      'itemCode': 'MED-CIP-250-TAB',
      'code': 'MED-CIP-250-TAB',
      'name': 'Ciprofloxacin (Novidat)',
      'formula': 'Ciprofloxacin (Novidat)',
      'type': 'Tablet',
      'dose': '250 mg',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '021',
      'rollNo': '021',
      'itemCode': 'MED-CIP-500-TAB',
      'code': 'MED-CIP-500-TAB',
      'name': 'Ciprofloxacin (Novidat)',
      'formula': 'Ciprofloxacin (Novidat)',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '022',
      'rollNo': '022',
      'itemCode': 'MED-AUG-1G',
      'code': 'MED-AUG-1G',
      'name': 'Co-Amoxiclav (Augmentin)',
      'formula': 'Co-Amoxiclav (Augmentin)',
      'type': 'Tablet',
      'dose': '1 g',
      'defaultPrice': 50.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '023',
      'rollNo': '023',
      'itemCode': 'MED-AUG-625',
      'code': 'MED-AUG-625',
      'name': 'Co-Amoxiclav (Augmentin)',
      'formula': 'Co-Amoxiclav (Augmentin)',
      'type': 'Tablet',
      'dose': '625 mg',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '024',
      'rollNo': '024',
      'itemCode': 'MED-DEX-TAB',
      'code': 'MED-DEX-TAB',
      'name': 'Dexamethasone',
      'formula': 'Dexamethasone',
      'type': 'Tablet',
      'dose': '0.5 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '025',
      'rollNo': '025',
      'itemCode': 'MED-DZP-20',
      'code': 'MED-DZP-20',
      'name': 'Diazepam',
      'formula': 'Diazepam',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '026',
      'rollNo': '026',
      'itemCode': 'MED-DZP-5',
      'code': 'MED-DZP-5',
      'name': 'Diazepam',
      'formula': 'Diazepam',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '027',
      'rollNo': '027',
      'itemCode': 'MED-DIC-50',
      'code': 'MED-DIC-50',
      'name': 'Diclofenac Sodium',
      'formula': 'Diclofenac Sodium',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '028',
      'rollNo': '028',
      'itemCode': 'MED-DMH-50',
      'code': 'MED-DMH-50',
      'name': 'Dimenhydrinate (Gravinate)',
      'formula': 'Dimenhydrinate (Gravinate)',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '029',
      'rollNo': '029',
      'itemCode': 'MED-DRT-40',
      'code': 'MED-DRT-40',
      'name': 'Drotaverine (No-Spa)',
      'formula': 'Drotaverine (No-Spa)',
      'type': 'Tablet',
      'dose': '40 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '030',
      'rollNo': '030',
      'itemCode': 'MED-ENTX-650',
      'code': 'MED-ENTX-650',
      'name': 'Entox-P',
      'formula': 'Entox-P',
      'type': 'Tablet',
      'dose': '650 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '031',
      'rollNo': '031',
      'itemCode': 'MED-ESC-5',
      'code': 'MED-ESC-5',
      'name': 'Escitalopram',
      'formula': 'Escitalopram',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 14.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '032',
      'rollNo': '032',
      'itemCode': 'MED-FAM-40',
      'code': 'MED-FAM-40',
      'name': 'Famotidine',
      'formula': 'Famotidine',
      'type': 'Tablet',
      'dose': '40 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '033',
      'rollNo': '033',
      'itemCode': 'MED-FLC-100',
      'code': 'MED-FLC-100',
      'name': 'Fluconazole',
      'formula': 'Fluconazole',
      'type': 'Tablet',
      'dose': '100 mg',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '034',
      'rollNo': '034',
      'itemCode': 'MED-FOL-TAB',
      'code': 'MED-FOL-TAB',
      'name': 'Folic Acid',
      'formula': 'Folic Acid',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '035',
      'rollNo': '035',
      'itemCode': 'MED-HYC-50',
      'code': 'MED-HYC-50',
      'name': 'Hyo-C Plus',
      'formula': 'Hyo-C Plus',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '036',
      'rollNo': '036',
      'itemCode': 'MED-HYO-10',
      'code': 'MED-HYO-10',
      'name': 'Hyoscine Butylbromide (Buscopan)',
      'formula': 'Hyoscine Butylbromide (Buscopan)',
      'type': 'Tablet',
      'dose': '10 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '037',
      'rollNo': '037',
      'itemCode': 'MED-HYO-300',
      'code': 'MED-HYO-300',
      'name': 'Hyoscine Butylbromide (Buscopan)',
      'formula': 'Hyoscine Butylbromide (Buscopan)',
      'type': 'Tablet',
      'dose': '300 mg',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '038',
      'rollNo': '038',
      'itemCode': 'MED-IBU-200',
      'code': 'MED-IBU-200',
      'name': 'Ibuprofen (Brufen)',
      'formula': 'Ibuprofen (Brufen)',
      'type': 'Tablet',
      'dose': '200 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '039',
      'rollNo': '039',
      'itemCode': 'MED-IBU-250',
      'code': 'MED-IBU-250',
      'name': 'Ibuprofen (Brufen)',
      'formula': 'Ibuprofen (Brufen)',
      'type': 'Tablet',
      'dose': '250 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '040',
      'rollNo': '040',
      'itemCode': 'MED-IBU-400',
      'code': 'MED-IBU-400',
      'name': 'Ibuprofen (Brufen)',
      'formula': 'Ibuprofen (Brufen)',
      'type': 'Tablet',
      'dose': '400 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '041',
      'rollNo': '041',
      'itemCode': 'MED-LEV-250',
      'code': 'MED-LEV-250',
      'name': 'Levofloxacin',
      'formula': 'Levofloxacin',
      'type': 'Tablet',
      'dose': '250 mg',
      'defaultPrice': 18.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '042',
      'rollNo': '042',
      'itemCode': 'MED-LOP-TAB-2',
      'code': 'MED-LOP-TAB-2',
      'name': 'Loperamide',
      'formula': 'Loperamide',
      'type': 'Tablet',
      'dose': '2 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '043',
      'rollNo': '043',
      'itemCode': 'MED-MGT-TAB',
      'code': 'MED-MGT-TAB',
      'name': 'Magnesium Trisilicate',
      'formula': 'Magnesium Trisilicate',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '044',
      'rollNo': '044',
      'itemCode': 'MED-MCB-2',
      'code': 'MED-MCB-2',
      'name': 'Mecobalamin',
      'formula': 'Mecobalamin',
      'type': 'Tablet',
      'dose': '2 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '045',
      'rollNo': '045',
      'itemCode': 'MED-MCB-500',
      'code': 'MED-MCB-500',
      'name': 'Mecobalamin',
      'formula': 'Mecobalamin',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '046',
      'rollNo': '046',
      'itemCode': 'MED-MEF-1000',
      'code': 'MED-MEF-1000',
      'name': 'Mefenamic Acid',
      'formula': 'Mefenamic Acid',
      'type': 'Tablet',
      'dose': '1000 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '047',
      'rollNo': '047',
      'itemCode': 'MED-MEF-250',
      'code': 'MED-MEF-250',
      'name': 'Mefenamic Acid (Ponstan)',
      'formula': 'Mefenamic Acid (Ponstan)',
      'type': 'Tablet',
      'dose': '250 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '048',
      'rollNo': '048',
      'itemCode': 'MED-MEF-500',
      'code': 'MED-MEF-500',
      'name': 'Mefenamic Acid (Ponstan)',
      'formula': 'Mefenamic Acid (Ponstan)',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '049',
      'rollNo': '049',
      'itemCode': 'MED-METCL-TAB',
      'code': 'MED-METCL-TAB',
      'name': 'Metoclopramide (Metoclone)',
      'formula': 'Metoclopramide (Metoclone)',
      'type': 'Tablet',
      'dose': '10 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '050',
      'rollNo': '050',
      'itemCode': 'MED-MTC-20',
      'code': 'MED-MTC-20',
      'name': 'Metoclopramide (Metoclone)',
      'formula': 'Metoclopramide (Metoclone)',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '051',
      'rollNo': '051',
      'itemCode': 'MED-MTC-5',
      'code': 'MED-MTC-5',
      'name': 'Metoclopramide (Metoclone)',
      'formula': 'Metoclopramide (Metoclone)',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '052',
      'rollNo': '052',
      'itemCode': 'MED-FLG-100',
      'code': 'MED-FLG-100',
      'name': 'Metronidazole (Flagyl)',
      'formula': 'Metronidazole (Flagyl)',
      'type': 'Tablet',
      'dose': '100 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '053',
      'rollNo': '053',
      'itemCode': 'MED-FLG-400',
      'code': 'MED-FLG-400',
      'name': 'Metronidazole (Flagyl)',
      'formula': 'Metronidazole (Flagyl)',
      'type': 'Tablet',
      'dose': '400 mg',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '054',
      'rollNo': '054',
      'itemCode': 'MED-ENT-TAB',
      'code': 'MED-ENT-TAB',
      'name': 'Metronidazole (flagyl) + Diloxanide',
      'formula': 'Metronidazole (flagyl) + Diloxanide',
      'type': 'Tablet',
      'dose': '250 mg / 375 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '055',
      'rollNo': '055',
      'itemCode': 'MED-MET-DIL-TAB',
      'code': 'MED-MET-DIL-TAB',
      'name': 'Metronidazole + Diloxanide (Entamezole DS)',
      'formula': 'Metronidazole + Diloxanide (Entamezole DS)',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 12.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '056',
      'rollNo': '056',
      'itemCode': 'MED-MVIT-TAB',
      'code': 'MED-MVIT-TAB',
      'name': 'Multivitamin',
      'formula': 'Multivitamin',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '057',
      'rollNo': '057',
      'itemCode': 'MED-SRB-Z',
      'code': 'MED-SRB-Z',
      'name': 'Multivitamin + Zinc (Surbex-Z)',
      'formula': 'Multivitamin + Zinc (Surbex-Z)',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 12.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '058',
      'rollNo': '058',
      'itemCode': 'MED-NIM-100',
      'code': 'MED-NIM-100',
      'name': 'Nimesulide',
      'formula': 'Nimesulide',
      'type': 'Tablet',
      'dose': '100 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '059',
      'rollNo': '059',
      'itemCode': 'MED-OMP-TAB-40',
      'code': 'MED-OMP-TAB-40',
      'name': 'Omeprazole (Risek)',
      'formula': 'Omeprazole (Risek)',
      'type': 'Tablet',
      'dose': '40 mg',
      'defaultPrice': 20.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '060',
      'rollNo': '060',
      'itemCode': 'MED-ORPH-PARA-TAB',
      'code': 'MED-ORPH-PARA-TAB',
      'name': 'Orphenadrine Citrate + Paracetamol (Nubrul Forte)',
      'formula': 'Orphenadrine Citrate + Paracetamol (Nubrul Forte)',
      'type': 'Tablet',
      'dose': '35 mg / 450 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '061',
      'rollNo': '061',
      'itemCode': 'MED-PCF-650',
      'code': 'MED-PCF-650',
      'name': 'Paincure Forte',
      'formula': 'Paincure Forte',
      'type': 'Tablet',
      'dose': '650 mg',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '062',
      'rollNo': '062',
      'itemCode': 'MED-PARA-20',
      'code': 'MED-PARA-20',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '063',
      'rollNo': '063',
      'itemCode': 'MED-PARA-400',
      'code': 'MED-PARA-400',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Tablet',
      'dose': '400 mg',
      'defaultPrice': 2.50,
      'isProformaMaster': true,
    },
    {
      'barcode': '064',
      'rollNo': '064',
      'itemCode': 'MED-PARA-500',
      'code': 'MED-PARA-500',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 2.50,
      'isProformaMaster': true,
    },
    {
      'barcode': '065',
      'rollNo': '065',
      'itemCode': 'MED-PARA-CAF',
      'code': 'MED-PARA-CAF',
      'name': 'Paracetamol + Caffeine (Panadol Extra)',
      'formula': 'Paracetamol + Caffeine (Panadol Extra)',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 3.50,
      'isProformaMaster': true,
    },
    {
      'barcode': '066',
      'rollNo': '066',
      'itemCode': 'MED-PARA-CPM-DXM-TAB',
      'code': 'MED-PARA-CPM-DXM-TAB',
      'name': 'Paracetamol + Chlorpheniramine + Dextromethorphan (Panadol CF / T-Day)',
      'formula': 'Paracetamol + Chlorpheniramine + Dextromethorphan (Panadol CF / T-Day)',
      'type': 'Tablet',
      'dose': '500 mg / 2 mg / 15 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '067',
      'rollNo': '067',
      'itemCode': 'MED-PHE-20',
      'code': 'MED-PHE-20',
      'name': 'Pheniramine Maleate (Avil)',
      'formula': 'Pheniramine Maleate (Avil)',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 3.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '068',
      'rollNo': '068',
      'itemCode': 'MED-PGB-50',
      'code': 'MED-PGB-50',
      'name': 'Pregabalin',
      'formula': 'Pregabalin',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 18.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '069',
      'rollNo': '069',
      'itemCode': 'MED-PCP-5',
      'code': 'MED-PCP-5',
      'name': 'Prochlorperazine (Stemetil)',
      'formula': 'Prochlorperazine (Stemetil)',
      'type': 'Tablet',
      'dose': '5 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '070',
      'rollNo': '070',
      'itemCode': 'MED-PSE-CPM-DXM-TAB',
      'code': 'MED-PSE-CPM-DXM-TAB',
      'name': 'Pseudoephedrine + CPM + Dextromethorphan (Coldrex)',
      'formula': 'Pseudoephedrine + CPM + Dextromethorphan (Coldrex)',
      'type': 'Tablet',
      'dose': '30 mg / 2 mg / 10 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '071',
      'rollNo': '071',
      'itemCode': 'MED-SRP-20',
      'code': 'MED-SRP-20',
      'name': 'Serratiopeptidase (Danzen DS)',
      'formula': 'Serratiopeptidase (Danzen DS)',
      'type': 'Tablet',
      'dose': '20 mg',
      'defaultPrice': 12.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '072',
      'rollNo': '072',
      'itemCode': 'MED-SNV-50',
      'code': 'MED-SNV-50',
      'name': 'Sinova-M',
      'formula': 'Sinova-M',
      'type': 'Tablet',
      'dose': '50 mg',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '073',
      'rollNo': '073',
      'itemCode': 'MED-SDM-1G',
      'code': 'MED-SDM-1G',
      'name': 'Sodamint',
      'formula': 'Sodamint',
      'type': 'Tablet',
      'dose': '1 g',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '074',
      'rollNo': '074',
      'itemCode': 'MED-SDM-TAB',
      'code': 'MED-SDM-TAB',
      'name': 'Sodamint',
      'formula': 'Sodamint',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '075',
      'rollNo': '075',
      'itemCode': 'MED-SBC-300',
      'code': 'MED-SBC-300',
      'name': 'Sodium Bicarbonate',
      'formula': 'Sodium Bicarbonate',
      'type': 'Tablet',
      'dose': '300 mg',
      'defaultPrice': 2.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '076',
      'rollNo': '076',
      'itemCode': 'MED-VBC-TAB',
      'code': 'MED-VBC-TAB',
      'name': 'Vitamin B-complex (BC)',
      'formula': 'Vitamin B-complex (BC)',
      'type': 'Tablet',
      'dose': 'Standard',
      'defaultPrice': 4.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '077',
      'rollNo': '077',
      'itemCode': 'MED-VTC-TAB',
      'code': 'MED-VTC-TAB',
      'name': 'Vitamin C',
      'formula': 'Vitamin C',
      'type': 'Tablet',
      'dose': '500 mg',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '078',
      'rollNo': '078',
      'itemCode': 'MED-VTD3-1000',
      'code': 'MED-VTD3-1000',
      'name': 'Vitamin D3',
      'formula': 'Vitamin D3',
      'type': 'Tablet',
      'dose': '1000 IU',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '300',
      'rollNo': '300',
      'itemCode': 'MED-AMX-250',
      'code': 'MED-AMX-250',
      'name': 'Amoxicillin (Amoxil)',
      'formula': 'Amoxicillin (Amoxil)',
      'type': 'Capsule',
      'dose': '250 mg',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '301',
      'rollNo': '301',
      'itemCode': 'MED-AMX-500',
      'code': 'MED-AMX-500',
      'name': 'Amoxicillin (Amoxil)',
      'formula': 'Amoxicillin (Amoxil)',
      'type': 'Capsule',
      'dose': '500 mg',
      'defaultPrice': 18.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '302',
      'rollNo': '302',
      'itemCode': 'MED-CEF-400',
      'code': 'MED-CEF-400',
      'name': 'Cefixime (Cefspan)',
      'formula': 'Cefixime (Cefspan)',
      'type': 'Capsule',
      'dose': '400 mg',
      'defaultPrice': 45.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '303',
      'rollNo': '303',
      'itemCode': 'MED-CIP-250',
      'code': 'MED-CIP-250',
      'name': 'Ciprofloxacin (Novidat)',
      'formula': 'Ciprofloxacin (Novidat)',
      'type': 'Capsule',
      'dose': '250 mg',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '304',
      'rollNo': '304',
      'itemCode': 'MED-CIP-500',
      'code': 'MED-CIP-500',
      'name': 'Ciprofloxacin (Novidat)',
      'formula': 'Ciprofloxacin (Novidat)',
      'type': 'Capsule',
      'dose': '500 mg',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '305',
      'rollNo': '305',
      'itemCode': 'MED-DOX-100',
      'code': 'MED-DOX-100',
      'name': 'Doxycycline',
      'formula': 'Doxycycline',
      'type': 'Capsule',
      'dose': '100 mg',
      'defaultPrice': 12.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '306',
      'rollNo': '306',
      'itemCode': 'MED-IND-25',
      'code': 'MED-IND-25',
      'name': 'Indomethacin',
      'formula': 'Indomethacin',
      'type': 'Capsule',
      'dose': '25 mg',
      'defaultPrice': 7.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '307',
      'rollNo': '307',
      'itemCode': 'MED-LOP-2',
      'code': 'MED-LOP-2',
      'name': 'Loperamide',
      'formula': 'Loperamide',
      'type': 'Capsule',
      'dose': '2 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '308',
      'rollNo': '308',
      'itemCode': 'MED-OMP-20',
      'code': 'MED-OMP-20',
      'name': 'Omeprazole (Risek)',
      'formula': 'Omeprazole (Risek)',
      'type': 'Capsule',
      'dose': '20 mg',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '309',
      'rollNo': '309',
      'itemCode': 'MED-OMP-40',
      'code': 'MED-OMP-40',
      'name': 'Omeprazole (Risek)',
      'formula': 'Omeprazole (Risek)',
      'type': 'Capsule',
      'dose': '40 mg',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '310',
      'rollNo': '310',
      'itemCode': 'MED-OTC-250',
      'code': 'MED-OTC-250',
      'name': 'Oxytetracycline',
      'formula': 'Oxytetracycline',
      'type': 'Capsule',
      'dose': '250 mg',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '311',
      'rollNo': '311',
      'itemCode': 'MED-VAD-500',
      'code': 'MED-VAD-500',
      'name': 'Vitamin A + Vitamin D',
      'formula': 'Vitamin A + Vitamin D',
      'type': 'Capsule',
      'dose': '500 mg',
      'defaultPrice': 6.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '400',
      'rollNo': '400',
      'itemCode': 'MED-ALC-SYR',
      'code': 'MED-ALC-SYR',
      'name': 'Allergy Care',
      'formula': 'Allergy Care',
      'type': 'Syrup',
      'dose': '250 ml',
      'defaultPrice': 80.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '401',
      'rollNo': '401',
      'itemCode': 'MED-AMC-SYR',
      'code': 'MED-AMC-SYR',
      'name': 'Amonium Chloride (Cough Syrup)',
      'formula': 'Amonium Chloride (Cough Syrup)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 75.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '402',
      'rollNo': '402',
      'itemCode': 'MED-AMX-SYR',
      'code': 'MED-AMX-SYR',
      'name': 'Amoxicillin (Amoxil)',
      'formula': 'Amoxicillin (Amoxil)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 110.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '403',
      'rollNo': '403',
      'itemCode': 'MED-ANT-SYR',
      'code': 'MED-ANT-SYR',
      'name': 'Antacid (Trisil)',
      'formula': 'Antacid (Trisil)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 85.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '404',
      'rollNo': '404',
      'itemCode': 'MED-CRM-SYR',
      'code': 'MED-CRM-SYR',
      'name': 'Carminative Mixture (Colic Syrup)',
      'formula': 'Carminative Mixture (Colic Syrup)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '405',
      'rollNo': '405',
      'itemCode': 'MED-CEF-SYR',
      'code': 'MED-CEF-SYR',
      'name': 'Cefixime (Cefspan)',
      'formula': 'Cefixime (Cefspan)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 220.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '406',
      'rollNo': '406',
      'itemCode': 'MED-CPM-SYP',
      'code': 'MED-CPM-SYP',
      'name': 'Chloropheniramine Maleate (CPM)',
      'formula': 'Chloropheniramine Maleate (CPM)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '407',
      'rollNo': '407',
      'itemCode': 'MED-AUG-SYR',
      'code': 'MED-AUG-SYR',
      'name': 'Co-Amoxiclav (Augmentin)',
      'formula': 'Co-Amoxiclav (Augmentin)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 240.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '408',
      'rollNo': '408',
      'itemCode': 'MED-CTM-SYR',
      'code': 'MED-CTM-SYR',
      'name': 'Co-Trimoxazole',
      'formula': 'Co-Trimoxazole',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '409',
      'rollNo': '409',
      'itemCode': 'MED-DMH-SYR',
      'code': 'MED-DMH-SYR',
      'name': 'Dimenhydrinate (Gravinate)',
      'formula': 'Dimenhydrinate (Gravinate)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '410',
      'rollNo': '410',
      'itemCode': 'MED-FVC-SYR',
      'code': 'MED-FVC-SYR',
      'name': 'Fever Care',
      'formula': 'Fever Care',
      'type': 'Syrup',
      'dose': '250 ml',
      'defaultPrice': 75.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '411',
      'rollNo': '411',
      'itemCode': 'MED-FUR-SYR',
      'code': 'MED-FUR-SYR',
      'name': 'Furazolidone',
      'formula': 'Furazolidone',
      'type': 'Syrup',
      'dose': '250 ml',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '412',
      'rollNo': '412',
      'itemCode': 'MED-BRF-SYR',
      'code': 'MED-BRF-SYR',
      'name': 'Ibuprofen',
      'formula': 'Ibuprofen',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 120.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '413',
      'rollNo': '413',
      'itemCode': 'MED-INC-SYR',
      'code': 'MED-INC-SYR',
      'name': 'Insta Care',
      'formula': 'Insta Care',
      'type': 'Syrup',
      'dose': '250 ml',
      'defaultPrice': 75.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '414',
      'rollNo': '414',
      'itemCode': 'MED-MEF-SYR',
      'code': 'MED-MEF-SYR',
      'name': 'Mefenamic Acid (Ponstan)',
      'formula': 'Mefenamic Acid (Ponstan)',
      'type': 'Syrup',
      'dose': '50 mg / 5 ml',
      'defaultPrice': 95.00,
      'isProformaMaster': true,
    },
    {
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
    },
    {
      'barcode': '416',
      'rollNo': '416',
      'itemCode': 'MED-FLG-SYR',
      'code': 'MED-FLG-SYR',
      'name': 'Metronidazole (Flagyl)',
      'formula': 'Metronidazole (Flagyl)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '417',
      'rollNo': '417',
      'itemCode': 'MED-MET-DIL-SYR',
      'code': 'MED-MET-DIL-SYR',
      'name': 'Metronidazole + Diloxanide (Entamezole DS)',
      'formula': 'Metronidazole + Diloxanide (Entamezole DS)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 85.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '418',
      'rollNo': '418',
      'itemCode': 'MED-PARA-SYR',
      'code': 'MED-PARA-SYR',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 80.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '419',
      'rollNo': '419',
      'itemCode': 'MED-PARA-CPM-DXM-SYR',
      'code': 'MED-PARA-CPM-DXM-SYR',
      'name': 'Paracetamol + Chlorpheniramine + Dextromethorphan (Corex-D / T-Day)',
      'formula': 'Paracetamol + Chlorpheniramine + Dextromethorphan (Corex-D / T-Day)',
      'type': 'Syrup',
      'dose': '60 ml',
      'defaultPrice': 110.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '420',
      'rollNo': '420',
      'itemCode': 'MED-PSE-CPM-DXM-SYR',
      'code': 'MED-PSE-CPM-DXM-SYR',
      'name': 'Pseudoephedrine + CPM + Dextromethorphan (Coldrex)',
      'formula': 'Pseudoephedrine + CPM + Dextromethorphan (Coldrex)',
      'type': 'Syrup',
      'dose': '120 ml',
      'defaultPrice': 115.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '421',
      'rollNo': '421',
      'itemCode': 'MED-SIM-SYR',
      'code': 'MED-SIM-SYR',
      'name': 'Similone',
      'formula': 'Similone',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 70.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '422',
      'rollNo': '422',
      'itemCode': 'MED-SAC-SYR',
      'code': 'MED-SAC-SYR',
      'name': 'Sodium Acid Citrate',
      'formula': 'Sodium Acid Citrate',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 75.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '423',
      'rollNo': '423',
      'itemCode': 'MED-TLC-SYR',
      'code': 'MED-TLC-SYR',
      'name': 'Tralcare',
      'formula': 'Tralcare',
      'type': 'Syrup',
      'dose': '250 ml',
      'defaultPrice': 80.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '424',
      'rollNo': '424',
      'itemCode': 'MED-VBC-SYR',
      'code': 'MED-VBC-SYR',
      'name': 'Vitamin B-complex (BC)',
      'formula': 'Vitamin B-complex (BC)',
      'type': 'Syrup',
      'dose': '15 ml',
      'defaultPrice': 70.00,
      'isProformaMaster': true,
    },
    {
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
    },
    {
      'barcode': '501',
      'rollNo': '501',
      'itemCode': 'MED-BCM-INJ',
      'code': 'MED-BCM-INJ',
      'name': 'B-Complex (Neurobion)',
      'formula': 'B-Complex (Neurobion)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 35.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '502',
      'rollNo': '502',
      'itemCode': 'MED-CEF-1G',
      'code': 'MED-CEF-1G',
      'name': 'Ceftriaxone',
      'formula': 'Ceftriaxone',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 150.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '503',
      'rollNo': '503',
      'itemCode': 'MED-CEF-500M',
      'code': 'MED-CEF-500M',
      'name': 'Ceftriaxone',
      'formula': 'Ceftriaxone',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 110.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '504',
      'rollNo': '504',
      'itemCode': 'MED-DEX-INJ',
      'code': 'MED-DEX-INJ',
      'name': 'Dexamethasone',
      'formula': 'Dexamethasone',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 40.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '505',
      'rollNo': '505',
      'itemCode': 'MED-DIC-INJ',
      'code': 'MED-DIC-INJ',
      'name': 'Diclofenac Sodium',
      'formula': 'Diclofenac Sodium',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '506',
      'rollNo': '506',
      'itemCode': 'MED-DMH-INJ',
      'code': 'MED-DMH-INJ',
      'name': 'Dimenhydrinate (Gravinate)',
      'formula': 'Dimenhydrinate (Gravinate)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 35.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '507',
      'rollNo': '507',
      'itemCode': 'MED-DRT-INJ',
      'code': 'MED-DRT-INJ',
      'name': 'Drotaverine (No-Spa)',
      'formula': 'Drotaverine (No-Spa)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 45.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '508',
      'rollNo': '508',
      'itemCode': 'MED-FRS-INJ',
      'code': 'MED-FRS-INJ',
      'name': 'Furosemide',
      'formula': 'Furosemide',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 18.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '509',
      'rollNo': '509',
      'itemCode': 'MED-GEN-INJ',
      'code': 'MED-GEN-INJ',
      'name': 'Gentamicin Sulphate',
      'formula': 'Gentamicin Sulphate',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 20.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '510',
      'rollNo': '510',
      'itemCode': 'MED-HYD-INJ',
      'code': 'MED-HYD-INJ',
      'name': 'Hydrocortisone Sodium Succinate',
      'formula': 'Hydrocortisone',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '511',
      'rollNo': '511',
      'itemCode': 'MED-HYO-INJ',
      'code': 'MED-HYO-INJ',
      'name': 'Hyoscine Butylbromide (Buscopan)',
      'formula': 'Hyoscine Butylbromide (Buscopan)',
      'type': 'Injection',
      'dose': '20 mg',
      'defaultPrice': 40.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '512',
      'rollNo': '512',
      'itemCode': 'MED-LIN-INJ',
      'code': 'MED-LIN-INJ',
      'name': 'Lincomycin (Lincocin)',
      'formula': 'Lincomycin (Lincocin)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 45.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '513',
      'rollNo': '513',
      'itemCode': 'MED-MTC-INJ',
      'code': 'MED-MTC-INJ',
      'name': 'Metoclopramide',
      'formula': 'Metoclopramide',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '514',
      'rollNo': '514',
      'itemCode': 'MED-METCL-INJ',
      'code': 'MED-METCL-INJ',
      'name': 'Metoclopramide (Metoclone)',
      'formula': 'Metoclopramide (Metoclone)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '515',
      'rollNo': '515',
      'itemCode': 'MED-OND-INJ',
      'code': 'MED-OND-INJ',
      'name': 'Ondansetron',
      'formula': 'Ondansetron',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 55.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '516',
      'rollNo': '516',
      'itemCode': 'MED-PARA-INJ',
      'code': 'MED-PARA-INJ',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '517',
      'rollNo': '517',
      'itemCode': 'MED-PHE-INJ',
      'code': 'MED-PHE-INJ',
      'name': 'Pheniramine Maleate (Avil)',
      'formula': 'Pheniramine Maleate (Avil)',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '518',
      'rollNo': '518',
      'itemCode': 'MED-TRM-INJ',
      'code': 'MED-TRM-INJ',
      'name': 'Tramadol Hydrochloride',
      'formula': 'Tramadol',
      'type': 'Injection',
      'dose': '2 cc',
      'defaultPrice': 45.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '600',
      'rollNo': '600',
      'itemCode': 'MED-CIP-DRP',
      'code': 'MED-CIP-DRP',
      'name': 'Ciprofloxacin',
      'formula': 'Ciprofloxacin',
      'type': 'Infusion',
      'dose': '2 cc',
      'defaultPrice': 140.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '601',
      'rollNo': '601',
      'itemCode': 'MED-CIP-IV',
      'code': 'MED-CIP-IV',
      'name': 'Ciprofloxacin (Novidat)',
      'formula': 'Ciprofloxacin (Novidat)',
      'type': 'Infusion',
      'dose': '100 ml',
      'defaultPrice': 140.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '602',
      'rollNo': '602',
      'itemCode': 'MED-DS-1000',
      'code': 'MED-DS-1000',
      'name': 'DexoseSaline (D/S)',
      'formula': 'DexoseSaline (D/S)',
      'type': 'Infusion',
      'dose': '1000 ml',
      'defaultPrice': 130.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '603',
      'rollNo': '603',
      'itemCode': 'MED-DS-500',
      'code': 'MED-DS-500',
      'name': 'DexoseSaline (D/S)',
      'formula': 'DexoseSaline (D/S)',
      'type': 'Infusion',
      'dose': '500 ml',
      'defaultPrice': 115.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '604',
      'rollNo': '604',
      'itemCode': 'MED-FLG-INJ',
      'code': 'MED-FLG-INJ',
      'name': 'Metronidazole (Flagyl)',
      'formula': 'Metronidazole (Flagyl)',
      'type': 'Infusion',
      'dose': '100 ml',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '605',
      'rollNo': '605',
      'itemCode': 'MED-NS-100',
      'code': 'MED-NS-100',
      'name': 'Normal Saline (N/S)',
      'formula': 'Normal Saline (N/S)',
      'type': 'Infusion',
      'dose': '100 ml',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '606',
      'rollNo': '606',
      'itemCode': 'MED-NS-1000',
      'code': 'MED-NS-1000',
      'name': 'Normal Saline (N/S)',
      'formula': 'Normal Saline (N/S)',
      'type': 'Infusion',
      'dose': '1000 ml',
      'defaultPrice': 120.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '607',
      'rollNo': '607',
      'itemCode': 'MED-NS-500',
      'code': 'MED-NS-500',
      'name': 'Normal Saline (N/S)',
      'formula': 'Normal Saline (N/S)',
      'type': 'Infusion',
      'dose': '500 ml',
      'defaultPrice': 110.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '608',
      'rollNo': '608',
      'itemCode': 'MED-OMP-IV',
      'code': 'MED-OMP-IV',
      'name': 'Omeprazole (Risek)',
      'formula': 'Omeprazole (Risek)',
      'type': 'Infusion',
      'dose': '100 ml',
      'defaultPrice': 180.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '609',
      'rollNo': '609',
      'itemCode': 'MED-PARA-INJ-100',
      'code': 'MED-PARA-INJ-100',
      'name': 'Paracetamol (Panadol)',
      'formula': 'Paracetamol (Panadol)',
      'type': 'Infusion',
      'dose': '100 ml',
      'defaultPrice': 120.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '610',
      'rollNo': '610',
      'itemCode': 'MED-RL-1000',
      'code': 'MED-RL-1000',
      'name': 'Ringer Lactate (R/L)',
      'formula': 'Ringer Lactate (R/L)',
      'type': 'Infusion',
      'dose': '1000 ml',
      'defaultPrice': 135.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '611',
      'rollNo': '611',
      'itemCode': 'MED-RL-500',
      'code': 'MED-RL-500',
      'name': 'Ringer Lactate (R/L)',
      'formula': 'Ringer Lactate (R/L)',
      'type': 'Infusion',
      'dose': '500 ml',
      'defaultPrice': 130.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '700',
      'rollNo': '700',
      'itemCode': 'EQUIP-NEB-MSK',
      'code': 'EQUIP-NEB-MSK',
      'name': 'Aerosol / Nebulizer Mask',
      'formula': 'Aerosol Mask',
      'type': 'Nebulization',
      'dose': 'Adult/Pediatric',
      'defaultPrice': 120.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '701',
      'rollNo': '701',
      'itemCode': 'MED-ATR-NEB',
      'code': 'MED-ATR-NEB',
      'name': 'Ipratropium Bromide',
      'formula': 'Ipratropium Bromide',
      'type': 'Nebulization',
      'dose': '250 mcg',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '702',
      'rollNo': '702',
      'itemCode': 'MED-VNT-NEB',
      'code': 'MED-VNT-NEB',
      'name': 'Salbutamol Solution',
      'formula': 'Salbutamol',
      'type': 'Nebulization',
      'dose': '5 mg/ml',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '800',
      'rollNo': '800',
      'itemCode': 'EQUIP-SNP-STD',
      'code': 'EQUIP-SNP-STD',
      'name': 'Adhesive First Aid Bandage (Sunny Plast)',
      'formula': 'Adhesive First Aid Bandage (Sunny Plast)',
      'type': 'Dressing Item',
      'dose': 'Standard',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '801',
      'rollNo': '801',
      'itemCode': 'EQUIP-ALC-SWB',
      'code': 'EQUIP-ALC-SWB',
      'name': 'Alcohol Swab',
      'formula': 'Alcohol Swab',
      'type': 'Consumables',
      'dose': 'Standard',
      'defaultPrice': 5.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '802',
      'rollNo': '802',
      'itemCode': 'EQUIP-BTP-STD',
      'code': 'EQUIP-BTP-STD',
      'name': 'Bandage Tape Plaster',
      'formula': 'Bandage Tape Plaster',
      'type': 'Dressing Item',
      'dose': 'Standard',
      'defaultPrice': 40.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '803',
      'rollNo': '803',
      'itemCode': 'EQUIP-BND-STD',
      'code': 'EQUIP-BND-STD',
      'name': 'Bandages',
      'formula': 'Bandages',
      'type': 'Dressing Item',
      'dose': 'Standard',
      'defaultPrice': 30.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '804',
      'rollNo': '804',
      'itemCode': 'EQUIP-COT-ROL',
      'code': 'EQUIP-COT-ROL',
      'name': 'Cotton Roll',
      'formula': 'Cotton Roll',
      'type': 'Dressing Item',
      'dose': 'Standard',
      'defaultPrice': 90.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '805',
      'rollNo': '805',
      'itemCode': 'EQUIP-NDL-24',
      'code': 'EQUIP-NDL-24',
      'name': 'Needle 24"',
      'formula': 'Needle',
      'type': 'Consumables',
      'dose': '24"',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '806',
      'rollNo': '806',
      'itemCode': 'MED-PYO-OINT',
      'code': 'MED-PYO-OINT',
      'name': 'Povidone Iodine 10%',
      'formula': 'Povidone Iodine 10%',
      'type': 'Others',
      'dose': '20 g tube',
      'defaultPrice': 90.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '807',
      'rollNo': '807',
      'itemCode': 'EQUIP-PYD-SOL',
      'code': 'EQUIP-PYD-SOL',
      'name': 'Povidone Iodine Solution (Pyodine)',
      'formula': 'Povidone Iodine Solution (Pyodine)',
      'type': 'Dressing Item',
      'dose': 'Standard',
      'defaultPrice': 110.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '900',
      'rollNo': '900',
      'itemCode': 'EQUIP-NDL-DNT',
      'code': 'EQUIP-NDL-DNT',
      'name': 'Dental Needle 27"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '27"',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '901',
      'rollNo': '901',
      'itemCode': 'EQUIP-NDL-21IN',
      'code': 'EQUIP-NDL-21IN',
      'name': 'Disposable Needle 21"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '21"',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '902',
      'rollNo': '902',
      'itemCode': 'EQUIP-NDL-22IN',
      'code': 'EQUIP-NDL-22IN',
      'name': 'Disposable Needle 22"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '22"',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '903',
      'rollNo': '903',
      'itemCode': 'EQUIP-NDL-23IN',
      'code': 'EQUIP-NDL-23IN',
      'name': 'Disposable Needle 23"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '23"',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '904',
      'rollNo': '904',
      'itemCode': 'EQUIP-NDL-25IN',
      'code': 'EQUIP-NDL-25IN',
      'name': 'Disposable Needle 25"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '25"',
      'defaultPrice': 8.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '905',
      'rollNo': '905',
      'itemCode': 'EQUIP-NDL-INS',
      'code': 'EQUIP-NDL-INS',
      'name': 'Insulin Needle 30"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '30"',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '906',
      'rollNo': '906',
      'itemCode': 'EQUIP-DRIP-SET',
      'code': 'EQUIP-DRIP-SET',
      'name': 'IV Administration Set',
      'formula': 'IV Administration Set',
      'type': 'Drip Set',
      'dose': 'Standard',
      'defaultPrice': 45.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '907',
      'rollNo': '907',
      'itemCode': 'EQUIP-CAN-18IN',
      'code': 'EQUIP-CAN-18IN',
      'name': 'IV Cannula 18"',
      'formula': 'IV Cannula',
      'type': 'Cannula',
      'dose': '18"',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '908',
      'rollNo': '908',
      'itemCode': 'EQUIP-CAN-20IN',
      'code': 'EQUIP-CAN-20IN',
      'name': 'IV Cannula 20"',
      'formula': 'IV Cannula',
      'type': 'Cannula',
      'dose': '20"',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '909',
      'rollNo': '909',
      'itemCode': 'EQUIP-CAN-22IN',
      'code': 'EQUIP-CAN-22IN',
      'name': 'IV Cannula 22"',
      'formula': 'IV Cannula',
      'type': 'Cannula',
      'dose': '22"',
      'defaultPrice': 60.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '910',
      'rollNo': '910',
      'itemCode': 'EQUIP-CAN-24IN',
      'code': 'EQUIP-CAN-24IN',
      'name': 'IV Cannula 24"',
      'formula': 'IV Cannula',
      'type': 'Cannula',
      'dose': '24"',
      'defaultPrice': 65.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '911',
      'rollNo': '911',
      'itemCode': 'EQUIP-NDL-24IN',
      'code': 'EQUIP-NDL-24IN',
      'name': 'Needle 24"',
      'formula': 'Needle',
      'type': 'Cannula',
      'dose': '24"',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '996',
      'rollNo': '996',
      'itemCode': 'EQUIP-SYR-3CC',
      'code': 'EQUIP-SYR-3CC',
      'name': 'Disposable Syringe 3cc',
      'formula': 'Syringe',
      'type': 'Syringe',
      'dose': '3cc',
      'defaultPrice': 15.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '997',
      'rollNo': '997',
      'itemCode': 'EQUIP-SYR-5CC',
      'code': 'EQUIP-SYR-5CC',
      'name': 'Disposable Syringe 5cc',
      'formula': 'Syringe',
      'type': 'Syringe',
      'dose': '5cc',
      'defaultPrice': 18.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '998',
      'rollNo': '998',
      'itemCode': 'EQUIP-SYR-10CC',
      'code': 'EQUIP-SYR-10CC',
      'name': 'Disposable Syringe 10cc',
      'formula': 'Syringe',
      'type': 'Syringe',
      'dose': '10cc',
      'defaultPrice': 25.00,
      'isProformaMaster': true,
    },
    {
      'barcode': '999',
      'rollNo': '999',
      'itemCode': 'EQUIP-SYR-GEN',
      'code': 'EQUIP-SYR-GEN',
      'name': 'Disposable Syringe',
      'formula': 'Disposable Syringe',
      'type': 'Syringe',
      'dose': 'Standard',
      'defaultPrice': 10.00,
      'isProformaMaster': true,
    },
  ];

  /// Aligns a local stock item's name, formula, type, dose, code/itemCode, and
  /// 3-digit Proforma barcode (001–999) against the Master Proforma catalog
  /// whenever its current barcode is missing or not a valid 001–999 code
  /// (e.g. legacy 's3', 'T8', 'i2', or 'MED-...' values cached in Hive).
  ///
  /// Perf: the catalog's normalized fields are computed once (`_alignIndex`)
  /// and each distinct (code, name, type, dose) input is matched once
  /// (`_alignMemo`). This runs for every stock row on every stock read, so
  /// without the cache the Doctor screen did ~865 regex ops per row per reload.
  static final RegExp _reParens = RegExp(r'\(.*?\)');
  static final RegExp _reSeparators = RegExp(r'[-_+/]');
  static final RegExp _reSpaces = RegExp(r'\s+');
  static List<({Map<String, dynamic> d, String code, String itemCode, String name, String base, String type, String dose})>? _alignIndex;
  static final Map<String, Map<String, dynamic>?> _alignMemo = {};

  static String _alignBase(String s) =>
      s.replaceAll(_reParens, ' ').replaceAll(_reSeparators, ' ').replaceAll(_reSpaces, ' ').trim();

  static void alignStockItemWithProforma(Map<String, dynamic> item) {
    final memoKey = '${item['code'] ?? item['itemCode'] ?? ''}\u0001'
        '${item['formula'] ?? item['name'] ?? ''}\u0001'
        '${item['type'] ?? item['dosageForm'] ?? ''}\u0001${item['dose'] ?? ''}';
    final Map<String, dynamic>? match;
    if (_alignMemo.containsKey(memoKey)) {
      match = _alignMemo[memoKey];
    } else {
      match = _findProformaMatch(item);
      if (_alignMemo.length > 5000) _alignMemo.clear();
      _alignMemo[memoKey] = match;
    }

    if (match != null) {
      item['barcode'] = match['barcode'];
      item['rollNo'] = match['rollNo'];
      item['code'] = match['code'];
      item['itemCode'] = match['itemCode'];
      item['name'] = match['name'];
      item['formula'] = match['formula'];
      item['type'] = match['type'];
      item['dose'] = match['dose'];
    }
  }

  static Map<String, dynamic>? _findProformaMatch(Map<String, dynamic> item) {
    final index = _alignIndex ??= [
      for (final d in _defaultProformaList)
        (
          d: d,
          code: (d['code'] ?? '').toString().toLowerCase(),
          itemCode: (d['itemCode'] ?? '').toString().toLowerCase(),
          name: (d['name'] ?? '').toString().toLowerCase().trim(),
          base: _alignBase((d['name'] ?? '').toString().toLowerCase().trim()),
          type: (d['type'] ?? '').toString().toLowerCase().replaceAll(_reSpaces, ''),
          dose: (d['dose'] ?? '').toString().toLowerCase().replaceAll(_reSpaces, ''),
        ),
    ];
    final rawCode = (item['code'] ?? item['itemCode'] ?? '').toString().trim().toLowerCase();
    var rawName = cleanBrandToFormula((item['formula'] ?? item['name'] ?? '').toString()).toLowerCase().trim();
    rawName = rawName
        .replaceAll('aminophyline', 'aminophylline')
        .replaceAll('paracitamol', 'paracetamol')
        .replaceAll('hyocine', 'hyoscine')
        .replaceAll('famotadine', 'famotidine')
        .replaceAll('lopramide', 'loperamide')
        .replaceAll('vitamine', 'vitamin')
        .replaceAll('ciprofloxacine', 'ciprofloxacin')
        .replaceAll('metronidazol ', 'metronidazole ')
        .replaceAll('lincomycine', 'lincomycin')
        .replaceAll('levofloxacine', 'levofloxacin')
        .replaceAll('doxyline', 'doxycycline')
        .replaceAll('orphnadrin', 'orphenadrine')
        .replaceAll('citrte', 'citrate')
        .replaceAll('drotaverin-hci', 'drotaverine')
        .replaceAll('drotaverine-hci', 'drotaverine');
    if (rawName == 'metronidazol') rawName = 'metronidazole';
    final rawBase = _alignBase(rawName);
    final rawType = (item['type'] ?? item['dosageForm'] ?? '').toString().toLowerCase().replaceAll(_reSpaces, '');
    final rawDose = (item['dose'] ?? '').toString().toLowerCase().replaceAll(_reSpaces, '');

    if (rawCode.isNotEmpty) {
      for (final e in index) {
        if (e.code == rawCode || e.itemCode == rawCode) return e.d;
      }
    }

    if (rawName.isEmpty) return null;
    Map<String, dynamic>? typeMatch;
    for (final e in index) {
      final nameMatches = e.name == rawName ||
          e.base == rawBase ||
          (rawBase.isNotEmpty && e.base.isNotEmpty && (e.base.contains(rawBase) || rawBase.contains(e.base)));
      if (!nameMatches) continue;
      if (rawType.isNotEmpty && e.type != rawType) continue;
      if (rawDose.isNotEmpty && e.dose == rawDose) return e.d;
      typeMatch ??= e.d;
    }
    return typeMatch;
  }

  /// Initialize and seed Proforma Hive Box if empty or update to generic formulas
  static Future<void> seedDefaultProformaIfEmpty() async {
    try {
      final box = await Hive.openBox(boxName);
      // Re-seed master box with generic formulas
      debugPrint('[MasterProformaService] Seeding default generic formula catalog (${_defaultProformaList.length} items)...');
      await box.clear();
      for (final item in _defaultProformaList) {
        final key = 'proforma:${item['code']}';
        await box.put(key, item);
      }
    } catch (e) {
      debugPrint('[MasterProformaService] Error seeding proforma box: $e');
    }
  }

  /// Get all Master Proforma items from Hive cache (or default fallback)
  static List<Map<String, dynamic>> getAllProformaItems() {
    try {
      if (Hive.isBoxOpen(boxName)) {
        final box = Hive.box(boxName);
        final List<Map<String, dynamic>> result = [];
        final Set<String> existingCodes = {};
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is Map) {
            final map = Map<String, dynamic>.from(raw);
            
            final itemCode = (map['code'] as String? ?? '').trim();
            // Filter out duplicate/removed items
            if (itemCode == 'MED-VITC-500' || itemCode == 'MED-CAL-500' || itemCode == 'MED-METCL-CAP' || itemCode == 'MED-IBU-SYR' || itemCode == 'MED-SRP-10' || itemCode == 'MED-PARA-INJ-2ML' || itemCode == 'MED-ENT-TAB' || itemCode == 'MED-CPM-SYR') {
              box.delete(key);
              continue;
            }

            final isCustom = map['isCustomized'] == true ||
                             map['userEdited'] == true ||
                             (map['auditTrail'] is List && (map['auditTrail'] as List).isNotEmpty);

            if (!isCustom) {
              // Auto-sanitize all brand names to generic formulas ONLY for unedited seed items
              final cleanName = cleanBrandToFormula(map['name']?.toString() ?? '');
              final cleanFormula = cleanBrandToFormula(map['formula']?.toString() ?? '');
              if (cleanName.isNotEmpty) map['name'] = cleanName;
              if (cleanFormula.isNotEmpty) map['formula'] = cleanFormula;

              final formulaLower = (map['formula'] as String? ?? '').trim().toLowerCase();
              final nameLower = (map['name'] as String? ?? '').trim().toLowerCase();

              // Auto-sanitize Injection B-Complex (Neurobion)
              if (itemCode == 'MED-CYN-INJ' || itemCode == 'MED-BCM-INJ' || formulaLower.contains('neurobion') || nameLower.contains('neurobion')) {
                map['code'] = 'MED-BCM-INJ';
                map['name'] = 'B-Complex (Neurobion)';
                map['formula'] = 'B-Complex (Neurobion)';
                map['type'] = 'Injection';
                map['dose'] = '2 cc';
              }

              // Auto-sanitize Drip type to Infusion
              if (map['type'] == 'Drip') {
                map['type'] = 'Infusion';
              }

              // Auto-sanitize Paracetamol Infusion to Infusion 100 ml always
              if (formulaLower.contains('paracetamol') && (map['type'] == 'Injection' || map['type'] == 'Drip' || map['type'] == 'Infusion')) {
                map['type'] = 'Infusion';
                map['dose'] = '100 ml';
              }

              // Auto-sanitize Omeprazole Infusion
              if (itemCode == 'MED-OMP-IV') {
                map['type'] = 'Infusion';
                map['dose'] = '100 ml';
              }

              // Auto-sanitize Metronidazole (Flagyl) items
              if (itemCode == 'MED-FLG-INJ' || itemCode == 'MED-FLG-400' || itemCode == 'MED-FLG-SYR' || (formulaLower.contains('metronidazole') && !formulaLower.contains('diloxanide') && !formulaLower.contains('entam')) || (nameLower.contains('flagyl') && !nameLower.contains('entam'))) {
                map['name'] = 'Metronidazole (Flagyl)';
                map['formula'] = 'Metronidazole (Flagyl)';
                final rawType = (map['type'] as String? ?? '').trim().toLowerCase();
                if (itemCode == 'MED-FLG-INJ' || rawType == 'infusion' || rawType == 'drip' || rawType == 'injection') {
                  map['type'] = 'Infusion';
                  map['dose'] = '100 ml';
                } else if (itemCode == 'MED-FLG-400' || rawType == 'tablet') {
                  map['type'] = 'Tablet';
                  map['dose'] = '400 mg';
                } else if (itemCode == 'MED-FLG-SYR' || rawType == 'syrup') {
                  map['type'] = 'Syrup';
                  map['dose'] = '15 ml';
                }
              }

              // Auto-sanitize Metronidazole + Diloxanide
              if (itemCode == 'MED-MET-DIL-TAB' || itemCode == 'MED-MET-DIL-SYR' || (formulaLower.contains('metronidazole') && (formulaLower.contains('diloxanide') || formulaLower.contains('entam')))) {
                map['name'] = 'Metronidazole + Diloxanide (Entamezole DS)';
                map['formula'] = 'Metronidazole + Diloxanide (Entamezole DS)';
              }

              final type = (map['type'] as String? ?? '').trim().toLowerCase();
              
              // Rule: All syrups default to 15 ml if empty
              if (type == 'syrup' && (map['dose'] == null || (map['dose'] as String).isEmpty)) {
                map['dose'] = '15 ml';
              }

              // Rule: All injections default to 2 cc if empty
              if (type == 'injection' && (map['dose'] == null || (map['dose'] as String).isEmpty)) {
                map['dose'] = '2 cc';
              }

              // Auto-sanitize redundant category words from Injection/Infusion names
              if (type == 'injection' || type == 'infusion' || type == 'drip') {
                var name = (map['name'] as String? ?? '').trim();
                name = name.replaceAll(RegExp(r'\s+(Injection|Infusion|\/\s*Infusion|IV)$', caseSensitive: false), '').trim();
                if (name.isNotEmpty) {
                  map['name'] = name;
                }
              }
            }

            // Auto-align code with medicine type (e.g. fix -INJ on Tablet)
            final currentCode = (map['itemCode'] ?? map['code'] ?? '').toString().trim();
            final curType = (map['type'] ?? '').toString().trim();
            final adjustedCode = adjustBarcodeForType(currentCode, curType);
            if (adjustedCode != currentCode && adjustedCode.isNotEmpty) {
              map['code'] = adjustedCode;
              map['itemCode'] = adjustedCode;
              if (box.containsKey(key)) {
                box.put(key, LocalStorageService.sanitize(map));
              }
            }

            // Ensure itemCode is set to alphanumeric code
            final resolvedCode = (map['itemCode'] ?? map['code'] ?? adjustedCode).toString().trim();
            final rawBarcode = (map['barcode'] ?? '').toString().trim();
            final rawRoll = (map['rollNo'] ?? '').toString().trim();

            map['itemCode'] = (map['itemCode'] != null && map['itemCode'].toString().isNotEmpty)
                ? map['itemCode'].toString().trim()
                : resolvedCode;

            // If barcode is an old alphanumeric string like MED-... or EQUIP-..., move it to itemCode
            if (rawBarcode.startsWith('MED-') || rawBarcode.startsWith('EQUIP-')) {
              map['itemCode'] = rawBarcode;
              map['code'] = rawBarcode;
            }

            // Assign 3-digit numeric barcode (001-999) from _defaultProformaList match
            final defMatch = _defaultProformaList.firstWhere(
              (d) => d['code'] == resolvedCode || d['itemCode'] == resolvedCode || (d['name'] == map['name'] && d['type'] == map['type'] && d['dose'] == map['dose']),
              orElse: () => {},
            );
            if (defMatch.isNotEmpty && defMatch['barcode'] != null) {
              map['barcode'] = defMatch['barcode'];
              map['rollNo'] = defMatch['barcode'];
            } else {
              final normRoll = normalizeProformaBarcode(rawRoll);
              final normBar = normalizeProformaBarcode(rawBarcode);
              if (normRoll != null) {
                map['barcode'] = normRoll;
                map['rollNo'] = normRoll;
              } else if (normBar != null) {
                map['barcode'] = normBar;
                map['rollNo'] = normBar;
              } else if (rawBarcode.isNotEmpty &&
                  !rawBarcode.startsWith('MED-') &&
                  !rawBarcode.startsWith('EQUIP-') &&
                  (map['packBarcode'] == null || map['packBarcode'].toString().trim().isEmpty)) {
                // Preserve any existing external/commercial barcode in packBarcode so it never clashes with 001-999
                map['packBarcode'] = rawBarcode;
                map['barcode'] = '';
                map['rollNo'] = '';
              }
            }

            result.add(map);
            if (map['code'] != null) {
              existingCodes.add(map['code'].toString());
            }
          }
        }

        // Merge any missing default catalog items (e.g. Needles, Paracetamol Inj)
        for (final defItem in _defaultProformaList) {
          final code = defItem['code']?.toString();
          if (code != null && !existingCodes.contains(code)) {
            result.add(Map<String, dynamic>.from(defItem));
            box.put('proforma:$code', defItem);
          }
        }

        // Backfill unique 3-digit (001-999) barcodes for any items missing a valid one
        final Set<int> usedNumbers = {};
        for (final item in result) {
          final norm = normalizeProformaBarcode((item['barcode'] ?? item['rollNo'] ?? '').toString());
          if (norm != null) {
            usedNumbers.add(int.parse(norm));
          }
        }
        int nextFree = 1;
        for (final item in result) {
          final norm = normalizeProformaBarcode((item['barcode'] ?? '').toString());
          if (norm == null) {
            while (nextFree <= 999 && usedNumbers.contains(nextFree)) {
              nextFree++;
            }
            if (nextFree <= 999) {
              usedNumbers.add(nextFree);
              final newBarcode = nextFree.toString().padLeft(3, '0');
              item['barcode'] = newBarcode;
              item['rollNo'] = newBarcode;
              final k = 'proforma:${item['code']}';
              if (box.containsKey(k)) {
                box.put(k, LocalStorageService.sanitize(item));
              }
            }
          }
        }

        if (result.isNotEmpty) {
          result.sort((a, b) => (a['formula'] as String? ?? a['name'] as String? ?? '')
              .compareTo(b['formula'] as String? ?? b['name'] as String? ?? ''));
          return result;
        }
      }
    } catch (e) {
      debugPrint('[MasterProformaService] Error reading proforma items: $e');
    }

    // Fallback to default in-memory list
    return List<Map<String, dynamic>>.from(_defaultProformaList);
  }

  /// Returns all items from proforma master catalog
  static List<Map<String, dynamic>> getAllItems() => getAllProformaItems();

  /// Helper to check if a medicine formula + type is an exact match in Proforma catalog
  static Map<String, dynamic>? findExactMatch(String formulaOrName, String type) {
    final cleanInput = formulaOrName.trim().toLowerCase();
    final cleanType = type.trim().toLowerCase();

    final all = getAllProformaItems();
    for (final item in all) {
      final itemFormula = (item['formula'] as String? ?? '').trim().toLowerCase();
      final itemName = (item['name'] as String? ?? '').trim().toLowerCase();
      final itemType = (item['type'] as String? ?? '').trim().toLowerCase();
      if ((itemFormula == cleanInput || itemName == cleanInput) && itemType == cleanType) {
        return item;
      }
    }
    return null;
  }

  /// Returns true if [raw] is a valid 3-digit Proforma barcode between 001 and 999.
  static bool isValidProformaBarcode(String raw) => normalizeProformaBarcode(raw) != null;

  /// Normalizes a Proforma barcode to a 3-digit string ('001'..'999'), or null if out of range / invalid.
  static String? normalizeProformaBarcode(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final n = int.tryParse(trimmed);
    if (n == null || n < 1 || n > 999) return null;
    return n.toString().padLeft(3, '0');
  }

  /// Helper to check if a barcode/code, packBarcode, or roll number already exists in Proforma catalog
  static Map<String, dynamic>? findExactBarcodeMatch(String code) {
    final cleanCode = code.trim().toLowerCase();
    if (cleanCode.isEmpty) return null;

    final all = getAllProformaItems();
    final queryInt = int.tryParse(cleanCode);

    for (final item in all) {
      final itemBarcode = (item['barcode'] as String? ?? '').trim().toLowerCase();
      final itemCode = (item['code'] as String? ?? '').trim().toLowerCase();
      final itemPackBarcode = (item['packBarcode'] as String? ?? '').trim().toLowerCase();
      final itemRoll = (item['rollNo'] as String? ?? '').trim().toLowerCase();

      if (itemBarcode == cleanCode ||
          itemCode == cleanCode ||
          (itemPackBarcode.isNotEmpty && itemPackBarcode == cleanCode) ||
          itemRoll == cleanCode) {
        return item;
      }

      // Roll number numeric matching with leading-zero tolerance (e.g. '1' matches '001')
      if (queryInt != null && queryInt >= 1 && queryInt <= 999) {
        final rollInt = int.tryParse(itemRoll);
        final barInt = int.tryParse(itemBarcode);
        if ((rollInt != null && rollInt == queryInt) || (barInt != null && barInt == queryInt)) {
          return item;
        }
      }
    }
    return null;
  }

  /// Returns the next available 3-digit Proforma barcode ('001'..'999').
  static String getNextRollNumber() {
    final Set<int> used = {};
    int maxNum = 0;
    final all = getAllProformaItems();
    for (final item in all) {
      final rollStr = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim();
      final numVal = int.tryParse(rollStr);
      if (numVal != null && numVal >= 1 && numVal <= 999) {
        used.add(numVal);
        if (numVal > maxNum) maxNum = numVal;
      }
    }
    if (maxNum < 999) {
      return (maxNum + 1).toString().padLeft(3, '0');
    }
    for (int i = 1; i <= 999; i++) {
      if (!used.contains(i)) {
        return i.toString().padLeft(3, '0');
      }
    }
    return '999';
  }

  /// Helper to check if a Name + Dose + Type exact match exists in Proforma catalog
  static Map<String, dynamic>? findExactNameDoseTypeMatch(String name, String type, String dose) {
    final cleanN = name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final cleanT = type.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final cleanD = dose.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (cleanN.isEmpty) return null;

    final all = getAllProformaItems();
    for (final item in all) {
      final itemFormula = (item['formula'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final itemName = (item['name'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final itemType = (item['type'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final itemDose = (item['dose'] as String? ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

      final matchesName = (itemName == cleanN || itemFormula == cleanN);
      final matchesType = (itemType == cleanT);
      final matchesDose = cleanD.isEmpty || itemDose == cleanD || itemDose == 'standard';
      if (matchesName && matchesType && matchesDose) {
        return item;
      }
    }
    return null;
  }

  /// Checks whether a given user/role has permission to add Proforma catalog items (Register Medicine).
  /// Strictly allowed: Chairman, HQ Manager / Admin / Supervisor.
  /// Strictly blocked: Doctor, Dispenser, Hybrid, Receptionist.
  static bool canManageProformaCatalog({String? role, Map<String, dynamic>? userData}) {
    String r = (role ?? '').trim().toLowerCase();
    if (r.isEmpty && userData != null) {
      r = (userData['role'] ?? userData['userRole'] ?? '').toString().trim().toLowerCase();
    }
    if (r.isEmpty) {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            r = (uData['role'] ?? uData['userRole'] ?? '').toString().trim().toLowerCase();
          }
        }
      } catch (_) {}
    }

    // Explicitly reject Doctor, Dispenser, Hybrid, and Receptionist
    if (r.contains('doctor') || r.contains('dispens') || r.contains('hybrid') || r.contains('reception')) {
      return false;
    }

    // Allow Chairman, HQ Manager, Admin, Supervisor, President
    if (r.contains('chairman') ||
        r.contains('president') ||
        r.contains('hqmanager') ||
        r.contains('hq_manager') ||
        r.contains('hq manager') ||
        r.contains('manager') ||
        r.contains('admin') ||
        r.contains('supervisor')) {
      return true;
    }

    return false;
  }

  /// Checks whether a given user/role has permission to EDIT or DELETE Master Proforma catalog items.
  /// Strictly allowed: Chairman, HQ Manager, Admin.
  /// Strictly blocked: Doctor, Dispenser, Hybrid, Receptionist.
  static bool canEditOrDeleteProforma({String? role, Map<String, dynamic>? userData}) {
    return canManageProformaCatalog(role: role, userData: userData);
  }

  /// Deletes a proforma catalog item with mandatory audit log reason.
  static Future<bool> deleteProformaItem({
    required String code,
    required Map<String, dynamic> auditLog,
  }) async {
    try {
      if (!Hive.isBoxOpen(boxName)) {
        await Hive.openBox(boxName);
      }
      final box = Hive.box(boxName);
      dynamic existing = box.get('proforma:$code');

      final itemName = (existing is Map)
          ? (existing['name'] ?? existing['formula'] ?? code).toString()
          : code;

      // Delete from Hive proforma box
      await box.delete('proforma:$code');

      // Record audit log entry
      final fullAuditEntry = {
        ...auditLog,
        'action': 'delete_proforma_medicine',
        'medicineCode': code,
        'medicineName': itemName,
        'timestamp': DateTime.now().toIso8601String(),
      };
      await LocalStorageService.saveLocalInventoryLog(fullAuditEntry);

      return true;
    } catch (e) {
      debugPrint('[MasterProformaService] Error deleting proforma item: $e');
      return false;
    }
  }

  /// Adds a new proforma catalog item and records an audit log entry with mandatory reason.
  static Future<bool> saveProformaItem(
    Map<String, dynamic> item, {
    required Map<String, dynamic> auditLog,
  }) async {
    try {
      if (!Hive.isBoxOpen(boxName)) {
        await Hive.openBox(boxName);
      }
      final box = Hive.box(boxName);
      final rawCode = (item['code'] ?? item['barcode'] ?? '').toString().trim();
      final code = rawCode.isNotEmpty ? rawCode : 'MED-GEN-${DateTime.now().millisecondsSinceEpoch}';

      final cleanName = cleanBrandToFormula((item['name'] ?? item['formula'] ?? '').toString());
      final cleanFormula = cleanBrandToFormula((item['formula'] ?? item['name'] ?? '').toString());

      final sanitizedItem = Map<String, dynamic>.from(item);
      sanitizedItem['code'] = code;
      sanitizedItem['itemCode'] = (sanitizedItem['itemCode'] ?? code).toString().trim();

      // Enforce 3-digit Proforma barcode (001-999); move any external >3-digit barcode to packBarcode
      final rawBar = (sanitizedItem['barcode'] ?? sanitizedItem['rollNo'] ?? '').toString().trim();
      String? proformaBar = normalizeProformaBarcode(rawBar);
      if (proformaBar == null) {
        if (rawBar.isNotEmpty &&
            !rawBar.startsWith('MED-') &&
            !rawBar.startsWith('EQUIP-') &&
            (sanitizedItem['packBarcode'] == null || sanitizedItem['packBarcode'].toString().trim().isEmpty)) {
          sanitizedItem['packBarcode'] = rawBar;
        }
        proformaBar = getNextRollNumber();
      }
      sanitizedItem['barcode'] = proformaBar;
      sanitizedItem['rollNo'] = proformaBar;

      sanitizedItem['name'] = cleanName;
      sanitizedItem['formula'] = cleanFormula;
      sanitizedItem['isProformaMaster'] = true;
      sanitizedItem['updatedAt'] = DateTime.now().toIso8601String();

      // Maintain audit trail list on the item
      final existing = box.get('proforma:$code');
      final List<Map<String, dynamic>> auditTrail = [];
      if (existing is Map && existing['auditTrail'] is List) {
        auditTrail.addAll((existing['auditTrail'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
      }
      auditTrail.add(auditLog);
      sanitizedItem['auditTrail'] = auditTrail;

      await box.put('proforma:$code', LocalStorageService.sanitize(sanitizedItem));

            // Save to local inventory audit logs
      await LocalStorageService.saveLocalInventoryLog({
        ...auditLog,
        'action': auditLog['action'] ?? 'add_proforma_medicine',
        'medicineCode': code,
        'medicineName': cleanName,
        'medicineFormula': cleanFormula,
        'savedAt': DateTime.now().toIso8601String(),
      });

      try {
        RealtimeManager().sendMessage({
          'event_type': RealtimeEvents.saveProformaItem,
          'data': sanitizedItem,
          'auditLog': auditLog,
        });
      } catch (_) {}

      return true;
    } catch (e) {
      debugPrint('[MasterProformaService] Error saving proforma item: $e');
      return false;
    }
  }

  /// Edits an existing proforma medicine name/formula with mandatory reason and audit trail.
  static Future<bool> editProformaItemName({
    required String code,
    required String newName,
    required Map<String, dynamic> auditLog,
  }) async {
    return editProformaItem(
      code: code,
      newName: newName,
      newType: '',
      newDose: '',
      auditLog: auditLog,
    );
  }

  /// Edits an existing proforma item's name, type, and dose with mandatory audit trail.
  static Future<bool> editProformaItem({
    required String code,
    required String newName,
    required String newType,
    required String newDose,
    required Map<String, dynamic> auditLog,
  }) async {
    try {
      if (!Hive.isBoxOpen(boxName)) {
        await Hive.openBox(boxName);
      }
      final box = Hive.box(boxName);
      dynamic existing = box.get('proforma:$code') ?? box.get(code);
      String targetKey = 'proforma:$code';

      // Fallback search in Hive box by code or barcode or formula
      if (existing == null) {
        for (final k in box.keys) {
          final v = box.get(k);
          if (v is Map) {
            final c = (v['code'] ?? v['barcode'] ?? '').toString().trim();
            final f = (v['formula'] ?? v['name'] ?? '').toString().trim().toLowerCase();
            if ((code.isNotEmpty && c.toLowerCase() == code.toLowerCase()) ||
                (code.isNotEmpty && f == code.toLowerCase())) {
              existing = Map<String, dynamic>.from(v);
              targetKey = k.toString();
              break;
            }
          }
        }
      }

      // Fallback search in default seed list if not yet written to Hive
      if (existing == null) {
        for (final defItem in _defaultProformaList) {
          final c = (defItem['code'] ?? '').toString().trim();
          final f = (defItem['formula'] ?? defItem['name'] ?? '').toString().trim().toLowerCase();
          if ((code.isNotEmpty && c.toLowerCase() == code.toLowerCase()) ||
              (code.isNotEmpty && f == code.toLowerCase())) {
            existing = Map<String, dynamic>.from(defItem);
            break;
          }
        }
      }

      if (existing == null) {
        debugPrint('[MasterProformaService] Could not find proforma item for code: $code');
        return false;
      }

      final updated = Map<String, dynamic>.from(existing is Map ? existing : {});
      final oldName = (updated['name'] ?? updated['formula'] ?? '').toString();
      final oldType = (updated['type'] ?? 'Tablet').toString();
      final oldDose = (updated['dose'] ?? '').toString();

      // Respect the user's explicit edited values
      final cleanNewName = newName.trim().isNotEmpty ? newName.trim() : oldName;
      final effectiveType = newType.trim().isNotEmpty ? newType.trim() : oldType;
      final effectiveDose = newDose.trim().isNotEmpty ? newDose.trim() : oldDose;
      final adjustedCode = adjustBarcodeForType(code, effectiveType);

      updated['name'] = cleanNewName;
      updated['formula'] = cleanNewName;
      updated['type'] = effectiveType;
      updated['dose'] = effectiveDose;
      updated['code'] = adjustedCode;
      updated['barcode'] = adjustedCode;
      updated['isCustomized'] = true;
      updated['userEdited'] = true;
      updated['updatedAt'] = DateTime.now().toIso8601String();

      // Append to audit trail
      final List<Map<String, dynamic>> auditTrail = [];
      if (updated['auditTrail'] is List) {
        auditTrail.addAll((updated['auditTrail'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
      }
      final fullAuditEntry = {
        ...auditLog,
        'action': 'edit_proforma_medicine',
        'medicineCode': adjustedCode,
        'oldCode': code,
        'oldName': oldName,
        'newName': cleanNewName,
        'oldType': oldType,
        'newType': effectiveType,
        'oldDose': oldDose,
        'newDose': effectiveDose,
        'timestamp': DateTime.now().toIso8601String(),
      };
      auditTrail.add(fullAuditEntry);
      updated['auditTrail'] = auditTrail;

      // Save to Master Proforma Hive box
      await box.put(targetKey, LocalStorageService.sanitize(updated));
      if (targetKey != 'proforma:$adjustedCode' && adjustedCode.isNotEmpty) {
        await box.put('proforma:$adjustedCode', LocalStorageService.sanitize(updated));
      }
      if (adjustedCode != code && code.isNotEmpty) {
        await box.delete('proforma:$code');
      }

      // Update in-memory seed list so memory lookups never revert
      for (int i = 0; i < _defaultProformaList.length; i++) {
        final dCode = (_defaultProformaList[i]['code'] ?? '').toString().trim();
        final dForm = (_defaultProformaList[i]['formula'] ?? _defaultProformaList[i]['name'] ?? '').toString().trim().toLowerCase();
        if ((code.isNotEmpty && dCode.toLowerCase() == code.toLowerCase()) || dForm == oldName.toLowerCase()) {
          _defaultProformaList[i]['name'] = cleanNewName;
          _defaultProformaList[i]['formula'] = cleanNewName;
          _defaultProformaList[i]['type'] = effectiveType;
          _defaultProformaList[i]['dose'] = effectiveDose;
          _defaultProformaList[i]['code'] = adjustedCode;
          _defaultProformaList[i]['barcode'] = adjustedCode;
          _defaultProformaList[i]['isCustomized'] = true;
          _defaultProformaList[i]['userEdited'] = true;
          break;
        }
      }

      // Update any matching stock-book batch so inventory follows proforma edits. Details
      // only (name/formula/type/dose/code) through StockActions.saveDetails, which also sends
      // them to the LAN server and the cloud. Quantity is never touched here.
      try {
        for (final sMap in StockLedger.items()) {
          final sCode = (sMap['code'] ?? sMap['barcode'] ?? '').toString().trim();
          final sFormula = (sMap['formula'] ?? sMap['name'] ?? '').toString().trim().toLowerCase();
          if ((code.isNotEmpty && sCode.toLowerCase() == code.toLowerCase()) ||
              sFormula == oldName.toLowerCase() ||
              sFormula == cleanNewName.toLowerCase()) {
            final pool = StockPool.fromKey(sMap['pool']?.toString());
            final medId = (sMap['medicineId'] ?? sMap['id'] ?? '').toString();
            if (pool == null || medId.isEmpty) continue;
            await StockActions.saveDetails(pool, medId, {
              'name': cleanNewName,
              'formula': cleanNewName,
              'type': effectiveType,
              'dose': effectiveDose,
              'code': adjustedCode,
              'barcode': adjustedCode,
            });
          }
        }
      } catch (e) {
        debugPrint('[MasterProformaService] Error updating matching stock: $e');
      }

      // Broadcast updated proforma item and audit log over LAN
      try {
        RealtimeManager().sendMessage({
          'event_type': 'proforma_item_updated',
          'data': updated,
          'auditLog': fullAuditEntry,
        });
      } catch (_) {}

      // Save to local inventory audit logs
      await LocalStorageService.saveLocalInventoryLog(fullAuditEntry);

      // Enqueue sync for proforma item so server and Firestore get the update
      try {
        await LocalStorageService.enqueueSync({
          'type': 'edit_proforma_medicine',
          'data': updated,
          'auditLog': fullAuditEntry,
        });
      } catch (_) {}

      return true;
    } catch (e) {
      debugPrint('[MasterProformaService] Error editing proforma item: $e');
      return false;
    }
  }

  /// Ensures barcode/code matches the dosage form type.
  /// Replaces mismatching prefixes (e.g. INJ in a tablet or TAB in an injection).
  static String adjustBarcodeForType(String code, String type) {
    if (code.isEmpty || type.isEmpty) return code;
    final t = type.toLowerCase().trim();
    String newCode = code;

    if (t == 'tablet') {
      newCode = newCode.replaceAll('-INJ', '-TAB')
                       .replaceAll('_INJ', '_TAB')
                       .replaceAll('-SYR', '-TAB')
                       .replaceAll('_SYR', '_TAB')
                       .replaceAll('-CAP', '-TAB')
                       .replaceAll('_CAP', '_TAB')
                       .replaceAll('-INF', '-TAB')
                       .replaceAll('_INF', '_TAB');
    } else if (t == 'syrup') {
      newCode = newCode.replaceAll('-INJ', '-SYR')
                       .replaceAll('_INJ', '_SYR')
                       .replaceAll('-TAB', '-SYR')
                       .replaceAll('_TAB', '_SYR')
                       .replaceAll('-CAP', '-SYR')
                       .replaceAll('_CAP', '_SYR')
                       .replaceAll('-INF', '-SYR')
                       .replaceAll('_INF', '_SYR');
    } else if (t == 'injection') {
      newCode = newCode.replaceAll('-TAB', '-INJ')
                       .replaceAll('_TAB', '_INJ')
                       .replaceAll('-SYR', '-INJ')
                       .replaceAll('_SYR', '_INJ')
                       .replaceAll('-CAP', '-INJ')
                       .replaceAll('_CAP', '_INJ');
    } else if (t == 'infusion' || t == 'drip') {
      newCode = newCode.replaceAll('-TAB', '-INJ')
                       .replaceAll('_TAB', '_INJ')
                       .replaceAll('-SYR', '-INJ')
                       .replaceAll('_SYR', '_INJ');
    } else if (t == 'capsule') {
      newCode = newCode.replaceAll('-INJ', '-CAP')
                       .replaceAll('_INJ', '_CAP')
                       .replaceAll('-TAB', '-CAP')
                       .replaceAll('_TAB', '_CAP')
                       .replaceAll('-SYR', '-CAP')
                       .replaceAll('_SYR', '_CAP');
    }

    return newCode;
  }

  /// Returns all recorded audit logs for a proforma item.
  static List<Map<String, dynamic>> getAuditTrailForItem(String code) {
    try {
      if (Hive.isBoxOpen(boxName)) {
        final val = Hive.box(boxName).get('proforma:$code');
        if (val is Map && val['auditTrail'] is List) {
          return (val['auditTrail'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  /// Parses an expiry date string (supporting YYYY-MM, MM-YYYY, YYYY-MM-DD, DD-MM-YYYY, etc.)
  /// or extracts a date pattern from doc ID as fallback. Returns DateTime(3000) if null/empty/invalid.
  static DateTime parseExpiryDate(dynamic s, [String? id]) {
    if (s is DateTime) return s;
    String str = (s ?? '').toString().trim();
    if (str.isEmpty || str == 'null') {
      if (id != null && id.isNotEmpty) {
        final reg = RegExp(r'(\d{4}[-/.]\d{1,2}(?:[-/.]\d{1,2})?)');
        final match = reg.firstMatch(id);
        if (match != null) {
          str = match.group(1)!;
        }
      }
    }
    if (str.isEmpty || str == 'null') return DateTime(3000);
    try {
      final clean = str.replaceAll('/', '-').replaceAll('.', '-').trim();
      final p = clean.split('-');
      if (p.length == 2) {
        if (p[0].length == 4) {
          return DateTime(int.parse(p[0]), int.parse(p[1]), 15);
        } else {
          return DateTime(int.parse(p[1]), int.parse(p[0]), 15);
        }
      }
      if (p.length == 3) {
        if (p[0].length == 4) {
          return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
        } else {
          return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
        }
      }
      final parsed = DateTime.tryParse(str);
      if (parsed != null) return parsed;
    } catch (_) {}
    return DateTime(3000);
  }

  /// Converts any commercial brand name into its generic formula with brand name in brackets
  /// Converts any medicine name or brand into its standard canonical representation: Generic Formula (Popular Brand)
  // Pure string -> string; memoized because it runs several times per stock
  // row on every inventory reload in the Doctor panel.
  static final Map<String, String> _cleanBrandMemo = {};
  static final RegExp _reInnerParens = RegExp(r'\s*\([^()]*\)');

  static String cleanBrandToFormula(String input) {
    final cached = _cleanBrandMemo[input];
    if (cached != null) return cached;
    final result = _cleanBrandToFormulaUncached(input);
    if (_cleanBrandMemo.length > 5000) _cleanBrandMemo.clear();
    _cleanBrandMemo[input] = result;
    return result;
  }

  static String _cleanBrandToFormulaUncached(String input) {
    var text = input.trim();
    if (text.isEmpty) return text;

    // Iteratively unwrap and strip ALL outer and nested parentheses
    while (text.contains('(') && text.contains(')')) {
      final prev = text;
      text = text.replaceAll(_reInnerParens, '').trim();
      if (text == prev) break;
    }
    // Also remove any remaining unclosed or mismatched parens
    text = text.replaceAll('(', '').replaceAll(')', '').trim();

    final lower = text.toLowerCase().trim();

    // Direct canonical mapping based on base formula/brand keyword
    if (lower.contains('amoxicillin') && (lower.contains('clav') || lower.contains('augmentin') || lower.contains('amclav') || lower.contains('curam'))) {
      return 'Co-Amoxiclav (Augmentin)';
    }
    if (lower.contains('amoxicillin') || lower.contains('amoxil')) {
      return 'Amoxicillin (Amoxil)';
    }
    if (lower.contains('orphnadrin') || lower.contains('orphenadrine') || lower.contains('norgesic') || lower.contains('nubrul') || (lower.contains('paracetamol') && lower.contains('citr'))) {
      return 'Orphenadrine Citrate + Paracetamol (Nubrul Forte)';
    }
    if ((lower.contains('paracetamol') || lower.contains('panadol')) && (lower.contains('dextromethorphan') || lower.contains('dextromethor') || lower.contains('chlorpheramine') || lower.contains('chlorpheniramine') || lower.contains('cf') || lower.contains('t-day') || lower.contains('tday'))) {
      return 'Paracetamol + Chlorpheniramine + Dextromethorphan (Panadol CF / T-Day)';
    }
    if (lower.contains('coldrex') || (lower.contains('pseudoephedrine') && (lower.contains('dextromethorphan') || lower.contains('dextromethor') || lower.contains('chlorpheramine') || lower.contains('chlorpheniramine') || lower.contains('cpm')))) {
      return 'Pseudoephedrine + CPM + Dextromethorphan (Coldrex)';
    }
    if (lower.contains('paracetamol') || lower.contains('panadol') || lower.contains('calpol') || lower.contains('febrol') || lower.contains('disprol')) {
      if (lower.contains('caffeine') || lower.contains('extra')) {
        return 'Paracetamol + Caffeine (Panadol Extra)';
      }
      return 'Paracetamol (Panadol)';
    }
    if (lower.contains('metronidazole') || lower.contains('flagyl')) {
      if (lower.contains('diloxanide') || lower.contains('entamizole') || lower.contains('entamezole')) {
        return 'Metronidazole + Diloxanide (Entamezole DS)';
      }
      return 'Metronidazole (Flagyl)';
    }
    if (lower.contains('chlorpheniramine') || lower.contains('chloropheniramine') || lower.contains('cpm')) {
      return 'Chloropheniramine Maleate (CPM)';
    }
    if (lower.contains('pheniramine') || lower.contains('avil')) {
      return 'Pheniramine Maleate (Avil)';
    }
    if (lower.contains('aspirin') || lower.contains('disprin') || lower.contains('dispirin')) {
      return 'Aspirin (Disprin)';
    }
    if (lower.contains('loprin')) {
      return 'Aspirin (Loprin)';
    }
    if (lower.contains('ibuprofen') || lower.contains('brufen') || lower.contains('arofen')) {
      return 'Ibuprofen (Brufen)';
    }
    if (lower.contains('mefenamic') || lower.contains('ponstan')) {
      return 'Mefenamic Acid (Ponstan)';
    }
    if (lower.contains('diclofenac') || lower.contains('voltral') || lower.contains('voren') || lower.contains('dicloran')) {
      return 'Diclofenac Sodium (Voltral)';
    }
    if (lower.contains('hyoscine') || lower.contains('buscopan')) {
      return 'Hyoscine Butylbromide (Buscopan)';
    }
    if (lower.contains('dimenhydrinate') || lower.contains('gravinate')) {
      return 'Dimenhydrinate (Gravinate)';
    }
    if (lower.contains('drotaverine') || lower.contains('drotavorine') || lower.contains('no-spa') || lower.contains('nospa')) {
      return 'Drotaverine (No-Spa)';
    }
    if (lower.contains('prochlorperazine') || lower.contains('stemetil')) {
      return 'Prochlorperazine (Stemetil)';
    }
    if (lower.contains('serratiopeptidase') || lower.contains('danzen') || lower.contains('danzan')) {
      return 'Serratiopeptidase (Danzen DS)';
    }
    if (lower.contains('metoclopramide') || lower.contains('metoclone') || lower.contains('maxolon')) {
      return 'Metoclopramide (Maxolon / Metoclone)';
    }
    if (lower.contains('omeprazole') || lower.contains('risek') || lower.contains('losec')) {
      return 'Omeprazole (Risek)';
    }
    if (lower.contains('esomeprazole') || lower.contains('nexum') || lower.contains('esom')) {
      return 'Esomeprazole (Nexum)';
    }
    if (lower.contains('cefixime') || lower.contains('cefspan')) {
      return 'Cefixime (Cefspan)';
    }
    if (lower.contains('ciprofloxacin') || lower.contains('novidat') || lower.contains('ciprox')) {
      return 'Ciprofloxacin (Novidat)';
    }
    if (lower.contains('levofloxacin') || lower.contains('leflox')) {
      return 'Levofloxacin (Leflox)';
    }
    if (lower.contains('azithromycin') || lower.contains('zithromax') || lower.contains('azomax')) {
      return 'Azithromycin (Zithromax)';
    }
    if (lower.contains('clarithromycin') || lower.contains('klaricid')) {
      return 'Clarithromycin (Klaricid)';
    }
    if (lower.contains('ceftriaxone') || lower.contains('rocephin') || lower.contains('epoceph')) {
      return 'Ceftriaxone (Rocephin)';
    }
    if (lower.contains('cetirizine') || lower.contains('rigix') || lower.contains('zyrtec')) {
      return 'Cetirizine (Rigix)';
    }
    if (lower.contains('loratadine') || lower.contains('clarityn') || lower.contains('softin')) {
      return 'Loratadine (Softin)';
    }
    if (lower.contains('fexofenadine') || lower.contains('fexo') || lower.contains('telfast')) {
      return 'Fexofenadine (Fexo)';
    }
    if (lower.contains('salbutamol') || lower.contains('ventolin')) {
      return 'Salbutamol (Ventolin)';
    }
    if (lower.contains('nacl') || lower.contains('normal saline') || lower.contains('(ns)') || lower.contains('(n/s)')) {
      return 'Normal Saline (N/S)';
    }
    if (lower.contains('dexosaline') || lower.contains('dexosesaline') || (lower.contains('dextrose') && lower.contains('nacl')) || lower.contains('(ds)') || lower.contains('(d/s)')) {
      return 'DexoseSaline (D/S)';
    }
    if (lower.contains('ringer') || lower.contains('(rl)') || lower.contains('(r/l)')) {
      return 'Ringer Lactate (R/L)';
    }
    if (lower.contains('trisil')) {
      return 'Antacid (Trisil)';
    }
    if (lower.contains('captopril') || lower.contains('capoten')) {
      return 'Captopril (Capoten)';
    }
    if (lower.contains('mefenamic') || lower.contains('ponstan')) {
      return 'Mefenamic Acid (Ponstan)';
    }
    if (lower.contains('antacid') || lower.contains('mucaine') || lower.contains('digas') || lower.contains('simeco') || lower.contains('aluminium') || lower.contains('magnesium hydroxide')) {
      return 'Antacid (Trisil)';
    }
    if (lower.contains('ammonium chloride') || lower.contains('amonimum chloride') || lower.contains('hydryllin') || lower.contains('hydrin') || lower.contains('cough syrup')) {
      return 'Amonium Chloride (Cough Syrup)';
    }
    if (lower.contains('carminative') || lower.contains('gripe water') || lower.contains('grape water') || lower.contains('cholic') || lower.contains('colic')) {
      return 'Carminative Mixture (Colic Syrup)';
    }
    if (lower.contains('dexamethasone') || lower.contains('decadron')) {
      return 'Dexamethasone (Decadron)';
    }
    if (lower.contains('ondansetron') || lower.contains('onset')) {
      return 'Ondansetron (Onset)';
    }
    if (lower.contains('folic acid') || lower.contains('folvite')) {
      return 'Folic Acid';
    }
    if (lower.contains('sunny') || lower.contains('adhesive') || lower.contains('first aid bandage')) {
      return 'Adhesive First Aid Bandage (Sunny Plast)';
    }
    if (lower.contains('pyodine') || lower.contains('povidone')) {
      return 'Povidone Iodine Solution (Pyodine)';
    }
    if (lower.contains('surbex') || (lower.contains('multivitamin') && lower.contains('zinc'))) {
      return 'Multivitamin + Zinc (Surbex-Z)';
    }
    if (lower.contains('b-12') || lower.contains('b12') || lower.contains('cynocobalmin') || (lower.contains('cyanocobalamin') && (lower.contains('1cc') || lower.contains('1 cc')))) {
      return 'B-12 (Cynocobalmin)';
    }
    if (lower.contains('neurobion') || (lower.contains('cyanocobalamin') && !lower.contains('1cc')) || (lower.contains('b-complex') && (lower.contains('inj') || lower.contains('injection')))) {
      return 'B-Complex (Neurobion)';
    }
    if (lower.contains('polybion') || lower.contains('vitamin b complex') || lower.contains('vitamin b-complex') || lower.contains('(bc)') || lower.contains('becosules')) {
      return 'Vitamin B-complex (BC)';
    }
    if (lower.contains('ca-c') || lower.contains('cac-1000') || (lower.contains('calcium') && lower.contains('vitamin c'))) {
      return 'Calcium + Vitamin C + Vitamin D (Ca-C 1000)';
    }
    if (lower.contains('vitamin c') || lower.contains('cevicon') || lower.contains('cecon')) {
      return 'Vitamin C (Cevicon)';
    }
    if (lower.contains('vitamin d3') || lower.contains('indrop-d') || lower.contains('sunny d')) {
      return 'Vitamin D3 (Sunny D)';
    }
    if (lower.contains('doxycycline') || lower.contains('vibramycin')) {
      return 'Doxycycline (Vibramycin)';
    }
    if (lower.contains('oxytetracycline') || lower.contains('terramycin')) {
      return 'Oxytetracycline (Terramycin)';
    }
    if (lower.contains('indomethacin') || lower.contains('indocin')) {
      return 'Indomethacin (Indocin)';
    }
    if (lower.contains('lincomycin') || lower.contains('lincocin')) {
      return 'Lincomycin (Lincocin)';
    }
    if (lower.contains('ipratropium') || lower.contains('atrovent')) {
      return 'Ipratropium Bromide (Atrovent)';
    }
    if (lower.contains('nimesulide') || lower.contains('nise')) {
      return 'Nimesulide (Nise)';
    }

    return input.trim();
  }

  /// Sanitizes all saved stock items in Hive stockBox to generic formulas
  static Future<int> sanitizeAllSavedStockItems() async {
    int updatedCount = 0;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.stockBox)) {
        await Hive.openBox(LocalStorageService.stockBox);
      }
      final box = Hive.box(LocalStorageService.stockBox);
      for (final key in box.keys.toList()) {
        // Only stock-book records, and only their details (never the quantity fields).
        if (!StockLedger.isLedgerKey(key)) continue;
        final val = box.get(key);
        if (val is Map && val['deleted'] != true) {
          final rawName = val['name']?.toString() ?? '';
          final rawFormula = val['formula']?.toString() ?? '';

          final cleanName = cleanBrandToFormula(rawName);
          final cleanFormula = cleanBrandToFormula(rawFormula);

          if (cleanName != rawName || cleanFormula != rawFormula) {
            final pool = (val['pool'] ?? '').toString();
            final medId = (val['medicineId'] ?? val['id'] ?? '').toString();
            if (pool.isEmpty || medId.isEmpty) continue;
            await StockLedger.saveDetails(pool, medId, {'name': cleanName, 'formula': cleanFormula});
            updatedCount++;
          }
        }
      }
      if (updatedCount > 0) {
        debugPrint('[MasterProformaService] Sanitized $updatedCount items in stockBox to generic formulas.');
      }
    } catch (e) {
      debugPrint('[MasterProformaService] Error sanitizing saved stock items: $e');
    }
    return updatedCount;
  }
}