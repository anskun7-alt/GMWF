// lib/pages/dispensary/receptionist/token_tally.dart
//
// Token-fee totals for the Receptionist summary (and the Hybrid Pharmacy
// "Today's collection" strip): Zakat = PKR 20 x days, Non-Zakat = PKR 100 x days,
// GMWF = free. Karachi branches have no Non-Zakat; those count as Zakat.

class TokenTally {
  final int zakat;
  final int nonZakat;
  final int gmwf;
  final int zakatAmount;
  final int nonZakatAmount;

  const TokenTally({
    this.zakat = 0,
    this.nonZakat = 0,
    this.gmwf = 0,
    this.zakatAmount = 0,
    this.nonZakatAmount = 0,
  });

  int get total => zakat + nonZakat + gmwf;
  int get totalAmount => zakatAmount + nonZakatAmount;

  static const int zakatFee = 20;
  static const int nonZakatFee = 100;

  /// Days of medicine on a token (1–99), top level first, then the prescription.
  static int daysOfMedicine(Map<String, dynamic> entry) {
    final topLevel = entry['daysOfMedicine'];
    if (topLevel is num) return topLevel.toInt().clamp(1, 99);
    if (topLevel != null) {
      final parsedTop = int.tryParse(topLevel.toString());
      if (parsedTop != null) return parsedTop.clamp(1, 99);
    }
    final presc = entry['prescription'];
    if (presc is Map) {
      final nested = presc['daysOfMedicine'];
      if (nested is num) return nested.toInt().clamp(1, 99);
      if (nested != null) {
        final parsedNested = int.tryParse(nested.toString());
        if (parsedNested != null) return parsedNested.clamp(1, 99);
      }
    }
    return 1;
  }

  static TokenTally of(Iterable<Map<String, dynamic>> entries, {required bool isKarachi}) {
    var zakat = 0, nonZakat = 0, gmwf = 0, zakatAmount = 0, nonZakatAmount = 0;
    for (final e in entries) {
      var qt = (e['queueType'] as String?)?.toLowerCase().trim() ?? 'unknown';
      if (isKarachi && (qt == 'non-zakat' || qt.contains('non'))) {
        qt = 'zakat';
      }
      final days = daysOfMedicine(e);
      switch (qt) {
        case 'zakat':
          zakat++;
          zakatAmount += zakatFee * days;
          break;
        case 'non-zakat':
          nonZakat++;
          nonZakatAmount += nonZakatFee * days;
          break;
        case 'gmwf':
          gmwf++;
          break;
        default:
          zakat++;
          zakatAmount += zakatFee * days;
      }
    }
    return TokenTally(
      zakat: zakat,
      nonZakat: nonZakat,
      gmwf: gmwf,
      zakatAmount: zakatAmount,
      nonZakatAmount: nonZakatAmount,
    );
  }
}

/// Short collection summary to share (e.g. on WhatsApp):
///
///   GMWF Jalalpur Jattan – 12 Oct 2026 (Morning)
///   Patients: 14 | Amount: PKR 640
///   Zakat 8 (PKR 160) · Non-Zakat 4 (PKR 400) · GMWF 2
///   — temp
///
/// The breakdown line lists only the categories that have tokens and is left
/// out when there are none. [shift] is omitted when null/empty or 'all'.
String buildCollectionSummary({
  required TokenTally tally,
  required String place,
  required String date,
  String? shift,
  required String username,
}) {
  String fmt(int n) {
    final s = n.abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return n < 0 ? '-$b' : b.toString();
  }

  final s = shift?.trim() ?? '';
  final shiftPart = (s.isEmpty || s.toLowerCase() == 'all')
      ? ''
      : ' (${s[0].toUpperCase()}${s.substring(1).toLowerCase()})';
  final placePart = place.trim().isEmpty ? '' : ' ${place.trim()}';

  final lines = <String>[
    'GMWF$placePart – $date$shiftPart',
    'Patients: ${tally.total} | Amount: PKR ${fmt(tally.totalAmount)}',
  ];
  final parts = <String>[
    if (tally.zakat > 0) 'Zakat ${tally.zakat} (PKR ${fmt(tally.zakatAmount)})',
    if (tally.nonZakat > 0) 'Non-Zakat ${tally.nonZakat} (PKR ${fmt(tally.nonZakatAmount)})',
    if (tally.gmwf > 0) 'GMWF ${tally.gmwf}',
  ];
  if (parts.isNotEmpty) lines.add(parts.join(' · '));
  if (username.trim().isNotEmpty) lines.add('— ${username.trim()}');
  return lines.join('\n');
}
