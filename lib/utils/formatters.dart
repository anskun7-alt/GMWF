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

  final match = RegExp(r'^(\d{2})[-/](\d{2})[-/](\d{4})$').firstMatch(text);
  if (match != null) {
    try {
      return DateTime(
        int.parse(match.group(3)!),
        int.parse(match.group(2)!),
        int.parse(match.group(1)!),
      );
    } catch (_) {}
  }

  final yyyyMatch = RegExp(r'^(\d{4})[-/](\d{2})[-/](\d{2})$').firstMatch(text);
  if (yyyyMatch != null) {
    try {
      return DateTime(
        int.parse(yyyyMatch.group(1)!),
        int.parse(yyyyMatch.group(2)!),
        int.parse(yyyyMatch.group(3)!),
      );
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

  if (!isPlaceholder(name)) {
    return name;
  }

  if (!isPlaceholder(username)) {
    return username;
  }

  if (email.contains('@')) {
    final parts = email.split('@').first;
    if (parts.isNotEmpty) {
      return parts[0].toUpperCase() + parts.substring(1);
    }
  }

  return !isPlaceholder(name) ? name : fallback;
}