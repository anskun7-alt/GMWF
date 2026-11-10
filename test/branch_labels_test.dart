import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/dispensary/receptionist/token_tally.dart';
import 'package:gmwf/utils/branch_labels.dart';

void main() {
  group('BranchLabels.isKarachiBranch', () {
    test('Karachi, its camps and khi ids are Karachi-related', () {
      for (final id in [
        'karachi', 'Karachi', ' KARACHI ', 'karachi_saddar', 'karachi_haji', 'karachi-2',
        'saddar', 'haji', 'haji_camp', 'hajicamp', 'kapaya', 'kapayya', 'khi', 'khi-saddar',
      ]) {
        expect(BranchLabels.isKarachiBranch(id), isTrue, reason: id);
      }
    });

    test('other branches and empty ids are not', () {
      for (final id in [null, '', 'all', 'gujrat', 'sialkot', 'rawalpindi', 'jalalpurjattan', 'lahore']) {
        expect(BranchLabels.isKarachiBranch(id), isFalse, reason: '$id');
      }
    });
  });

  group('labels', () {
    test('Karachi shows PKR amounts instead of Zakat', () {
      expect(BranchLabels.zakat('karachi'), '20 PKR');
      expect(BranchLabels.nonZakat('karachi_haji'), '100 PKR');
      expect(BranchLabels.text('Zakat Patients', 'saddar'), '20 PKR Patients');
      expect(BranchLabels.text('Non-Zakat Patients', 'karachi'), '100 PKR Patients');
      expect(BranchLabels.text('ZAKAT', 'karachi'), '20 PKR');
      expect(BranchLabels.text('NON-ZAKAT', 'karachi'), '100 PKR');
      expect(BranchLabels.text('non_zakat', 'karachi'), '100 PKR');
      expect(BranchLabels.text('Zakat: 3 | Non-Zakat: 0 | GMWF: 1', 'karachi'),
          '20 PKR: 3 | 100 PKR: 0 | GMWF: 1');
    });

    test('other branches keep Zakat', () {
      expect(BranchLabels.zakat('gujrat'), 'Zakat');
      expect(BranchLabels.nonZakat('sialkot'), 'Non-Zakat');
      expect(BranchLabels.text('Zakat Patients', 'gujrat'), 'Zakat Patients');
      expect(BranchLabels.zakat('all'), 'Zakat');
    });

    test('collection summary uses PKR labels for Karachi only', () {
      const tally = TokenTally(zakat: 2, zakatAmount: 40, gmwf: 1);
      final khi = buildCollectionSummary(
          tally: tally, place: 'Karachi', date: '1 Nov 2026', username: 'k', isKarachi: true);
      expect(khi, contains('20 PKR 2 (PKR 40)'));
      expect(khi.toLowerCase(), isNot(contains('zakat')));

      final other = buildCollectionSummary(tally: tally, place: 'Gujrat', date: '1 Nov 2026', username: 'g');
      expect(other, contains('Zakat 2 (PKR 40)'));
    });
  });
}
