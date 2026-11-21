// lib/services/stock/expiry_rules.dart
//
// One rule for every place an expiry date is typed: it must be AFTER the current month
// (user decision 2026-11-21: a medicine expiring this month is not accepted).

/// Parses the expiry formats used in the app: MM-YYYY, MM/YYYY, DD-MM-YYYY, DD/MM/YYYY,
/// YYYY-MM, YYYY-MM-DD (and ISO with time). Returns the first day of the expiry month,
/// or null when the text is not a date.
DateTime? parseExpiryMonth(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final parts = s.split(RegExp(r'[-/.\sT]')).where((p) => p.isNotEmpty).toList();
  int? y;
  int? m;
  if (parts.length >= 2 && parts[0].length == 4) {
    // YYYY-MM or YYYY-MM-DD
    y = int.tryParse(parts[0]);
    m = int.tryParse(parts[1]);
  } else if (parts.length == 2) {
    // MM-YYYY
    m = int.tryParse(parts[0]);
    y = int.tryParse(parts[1]);
  } else if (parts.length >= 3) {
    // DD-MM-YYYY
    m = int.tryParse(parts[1]);
    y = int.tryParse(parts[2]);
  }
  if (y == null || m == null || m < 1 || m > 12) return null;
  if (y < 100) y += 2000;
  if (y < 2000 || y > 2100) return null;
  return DateTime(y, m);
}

/// True when [expiryMonth] is after the current month.
bool isExpiryAcceptable(DateTime expiryMonth, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final firstAllowed = DateTime(n.year, n.month + 1);
  return !DateTime(expiryMonth.year, expiryMonth.month).isBefore(firstAllowed);
}

/// A batch is expired from the FIRST day of its expiry month ("12-2026" = 01-12-2026).
/// A batch without a readable expiry is not treated as expired.
bool isBatchExpired(Map batch, {DateTime? now}) {
  final m = parseExpiryMonth((batch['expiryDate'] ?? batch['expiry'] ?? '').toString());
  if (m == null) return false;
  final n = now ?? DateTime.now();
  return m.year * 12 + m.month <= n.year * 12 + n.month;
}

/// Validator text for an expiry field, or null when it is fine.
String? expiryInputError(String raw, {bool allowEmpty = false, DateTime? now}) {
  if (raw.trim().isEmpty) return allowEmpty ? null : 'Enter the expiry date';
  final d = parseExpiryMonth(raw);
  if (d == null) return 'Use MM-YYYY, e.g. 08-2027';
  if (!isExpiryAcceptable(d, now: now)) return 'Expiry must be after this month';
  return null;
}
