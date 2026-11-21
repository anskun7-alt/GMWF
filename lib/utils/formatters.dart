import 'package:flutter/services.dart';

String normalizeDobInput(String input) {
  final digits = input.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return '';
  if (digits.length <= 4) return digits;
  final limited = digits.substring(0, digits.length > 8 ? 8 : digits.length);
  final day = limited.substring(0, 2);
  final month = limited.substring(2, 4);
  final year = limited.substring(4);
  return '$day-$month-$year';
}

DateTime? parseDobDateTime(String? value) {
  if (value == null) return null;
  final text = value.trim();
  if (text.isEmpty || text == 'null' || text == 'NULL') return null;

  final iso = DateTime.tryParse(text);
  if (iso != null) return iso;

  final cleaned = text.replaceAll(RegExp(r'[^0-9]'), '');
  if (cleaned.length == 8) {
    final day = int.tryParse(cleaned.substring(0, 2));
    final month = int.tryParse(cleaned.substring(2, 4));
    final year = int.tryParse(cleaned.substring(4, 8));
    if (day != null && month != null && year != null) {
      try {
        return DateTime(year, month, day);
      } catch (_) {}
    }
  }

  final match = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(text);
  if (match != null) {
    try {
      final y = int.parse(match.group(3)!);
      final m = int.parse(match.group(2)!);
      final d = int.parse(match.group(1)!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return DateTime(y, m, d);
      }
    } catch (_) {}
  }

  final yyyyMatch = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(text);
  if (yyyyMatch != null) {
    try {
      final y = int.parse(yyyyMatch.group(1)!);
      final m = int.parse(yyyyMatch.group(2)!);
      final d = int.parse(yyyyMatch.group(3)!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return DateTime(y, m, d);
      }
    } catch (_) {}
  }

  return null;
}

/// Formats CNIC input as XXXXX-XXXXXXX-X (13 digits + 2 dashes = 15 chars max)
class CNICInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    // Limit to 13 digits max
    final limited = digits.length > 13 ? digits.substring(0, 13) : digits;
    final buffer = StringBuffer();

    for (int i = 0; i < limited.length; i++) {
      buffer.write(limited[i]);
      // Insert hyphen after 5th digit (index 4) and after 12th digit (index 11)
      if ((i == 4 || i == 11) && i != limited.length - 1) {
        buffer.write('-');
      }
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Limits phone input to max 11 digits (digits only)
class PhoneNumberInputFormatter extends TextInputFormatter {
  final int maxDigits;
  const PhoneNumberInputFormatter({this.maxDigits = 11});

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final limited = digits.length > maxDigits ? digits.substring(0, maxDigits) : digits;
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: limited.length),
    );
  }
}

class DateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    final buffer = StringBuffer();

    for (int i = 0; i < limited.length; i++) {
      buffer.write(limited[i]);
      if ((i == 3 || i == 5) && i != limited.length - 1) {
        buffer.write('-');
      }
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Formats Date of Birth input as dd-MM-yyyy (digits only, auto-inserting dashes and validating day 01-31 / month 01-12, matching PatientRegisterPage)
class DobInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var t = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (t.length > 8) t = t.substring(0, 8);

    final b = StringBuffer();

    if (t.isNotEmpty) {
      var day = t.substring(0, t.length.clamp(0, 2));
      if (day.length == 2) {
        final d = int.tryParse(day) ?? 0;
        if (d > 31 || d == 0) day = day[0];
      }
      b.write(day);
    }

    if (t.length > 2) {
      b.write('-');
      var month = t.substring(2, t.length.clamp(2, 4));
      if (month.length == 2) {
        final m = int.tryParse(month) ?? 0;
        if (m > 12 || m == 0) month = month[0];
      }
      b.write(month);
    }

    if (t.length > 4) {
      b.write('-');
      b.write(t.substring(4));
    }

    final formatted = b.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Resolves a user's display name prioritizing explicit full name or username.
String resolveUserDisplayName(Map<String, dynamic>? data, {String fallback = 'User'}) {
  if (data == null) return fallback;
  final name = (data['name'] ?? data['fullName'] ?? data['displayName'] ?? '').toString().trim();
  final username = (data['username'] ?? data['userName'] ?? '').toString().trim();
  final email = (data['email'] ?? '').toString().trim();
  bool isPlaceholder(String value) {
    final normalized = value.toLowerCase();
    return value.isEmpty ||
        normalized == '?' ||
        normalized == '-' ||
        normalized == 'null' ||
        normalized == 'none' ||
        normalized == 'n/a' ||
        normalized == 'user' ||
        normalized == 'unknown' ||
        normalized == 'unknown user' ||
        normalized == 'loading' ||
        normalized == 'loading...' ||
        normalized.startsWith('loading');
  }

  // A role or a stand-in written when nothing better was known ("Staff User", "Admin",
  // "Dispenser"...). The header showed these instead of the person's own name; they are used
  // only when the record has nothing else.
  bool isRoleLike(String value) => _roleLikeNames.contains(value.toLowerCase());

  if (!isPlaceholder(name) && !isRoleLike(name)) {
    return name;
  }

  if (!isPlaceholder(username) && !isRoleLike(username)) {
    return username;
  }

  if (email.contains('@')) {
    final parts = email.split('@').first;
    if (parts.isNotEmpty && !isRoleLike(parts)) {
      return parts[0].toUpperCase() + parts.substring(1);
    }
  }

  if (!isPlaceholder(name)) return name;
  if (!isPlaceholder(username)) return username;
  return fallback;
}

/// Whether [value] is not a person's own name: empty, a placeholder, or a role/stand-in such
/// as "Staff User" or "Admin" (see [resolveUserDisplayName]).
bool isStandInUserName(String? value) {
  final v = (value ?? '').trim().toLowerCase();
  return v.isEmpty || v == 'null' || v == 'user' || v == 'unknown' || v.startsWith('loading') ||
      _roleLikeNames.contains(v);
}

const _roleLikeNames = {
  'staff user', 'staff', 'admin', 'administrator', 'super admin', 'superadmin', 'global admin',
  'doctor', 'receptionist', 'dispenser', 'supervisor', 'manager', 'teacher', 'office boy',
  'cashier', 'accountant', 'hq', 'hq manager',
};
/// Dose timing as the doctor types it: digits only, '+' inserted automatically.
/// Three doses — Morning+Evening+Night: "101" → "1+0+1". Backspace over a '+' removes the dose before it.
class DoseTimingInputFormatter extends TextInputFormatter {
  final int maxDoses;
  const DoseTimingInputFormatter({this.maxDoses = 3});

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final oldDigits = oldValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    // Only a '+' was deleted: treat it as deleting the dose before it.
    if (newValue.text.length < oldValue.text.length && digits == oldDigits && digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }
    if (digits.length > maxDoses) {
      // The box was already full (e.g. the pre-filled "1+0+1"). Whatever was just typed or
      // pasted starts a new timing — never silently dropped, or the old timing gets saved.
      final inserted = _insertedText(oldValue.text, newValue.text).replaceAll(RegExp(r'[^0-9]'), '');
      if (inserted.isNotEmpty) digits = inserted;
      if (digits.length > maxDoses) digits = digits.substring(0, maxDoses);
    }
    final text = digits.split('').join('+');
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  /// The part of [newText] that is not in [oldText] (common prefix and suffix removed).
  static String _insertedText(String oldText, String newText) {
    var p = 0;
    while (p < oldText.length && p < newText.length && oldText[p] == newText[p]) {
      p++;
    }
    var s = 0;
    while (s < oldText.length - p && s < newText.length - p &&
        oldText[oldText.length - 1 - s] == newText[newText.length - 1 - s]) {
      s++;
    }
    return newText.substring(p, newText.length - s);
  }
}
