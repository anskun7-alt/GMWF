// lib/pages/school/core/urdu_phonetic.dart
//
// Urdu phonetic keyboard for School users, InPage / CRULP style: the English
// key that sounds like the letter types it (a → ا, b → ب, s → س, Shift+s → ص).
//
// It works with the normal Windows/Android keyboard: while Urdu mode is on, the
// letters typed into the focused text field are converted as they are typed.
// Pasted text, numbers, phone/CNIC/number fields and passwords are left alone.

import 'package:flutter/widgets.dart';

abstract final class UrduPhonetic {
  /// Lower-case keys.
  static const Map<String, String> lower = {
    'a': 'ا', 'b': 'ب', 'c': 'چ', 'd': 'د', 'e': 'ع', 'f': 'ف', 'g': 'گ',
    'h': 'ھ', 'i': 'ی', 'j': 'ج', 'k': 'ک', 'l': 'ل', 'm': 'م', 'n': 'ن',
    'o': 'ہ', 'p': 'پ', 'q': 'ق', 'r': 'ر', 's': 'س', 't': 'ت', 'u': 'ء',
    'v': 'ط', 'w': 'و', 'x': 'ش', 'y': 'ے', 'z': 'ز',
  };

  /// Shift + key. Keys not listed fall back to the lower-case letter.
  static const Map<String, String> upper = {
    'A': 'آ', 'C': 'ث', 'D': 'ڈ', 'E': 'ٰ', 'G': 'غ', 'H': 'ح', 'I': 'ِ',
    'J': 'ض', 'K': 'خ', 'N': 'ں', 'O': 'ۃ', 'P': 'ُ', 'R': 'ڑ', 'S': 'ص',
    'T': 'ٹ', 'U': 'ئ', 'V': 'ظ', 'W': 'ؤ', 'X': 'ژ', 'Y': 'َ', 'Z': 'ذ',
  };

  /// Urdu punctuation.
  static const Map<String, String> punctuation = {',': '،', '?': '؟', '.': '۔', ';': '؛'};

  static String? mapChar(String ch) =>
      upper[ch] ?? lower[ch] ?? lower[ch.toLowerCase()] ?? punctuation[ch];

  /// Converts every mappable character in [latin]; everything else is kept.
  static String transliterate(String latin) {
    final b = StringBuffer();
    for (final ch in latin.characters) {
      b.write(mapChar(ch) ?? ch);
    }
    return b.toString();
  }

  static bool hasMappable(String s) => s.characters.any((ch) => mapChar(ch) != null);

  /// Fields where Urdu letters make no sense.
  static bool skipField(EditableText w) {
    if (w.obscureText || w.readOnly) return true;
    // Compare by index so numberWithOptions(...) counts as a number field too.
    final i = w.keyboardType.index;
    return {
      TextInputType.number.index,
      TextInputType.phone.index,
      TextInputType.emailAddress.index,
      TextInputType.url.index,
      TextInputType.datetime.index,
      TextInputType.visiblePassword.index,
    }.contains(i);
  }

  /// The text that should replace [oldValue] → [newValue] while Urdu mode is on,
  /// or null to leave the edit as it is. Only short insertions (typing, not
  /// paste) are converted, and never while an IME is composing.
  static TextEditingValue? convertEdit(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) return null;
    final o = oldValue.text;
    final n = newValue.text;
    var p = 0;
    final maxP = o.length < n.length ? o.length : n.length;
    while (p < maxP && o.codeUnitAt(p) == n.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < o.length - p && s < n.length - p && o.codeUnitAt(o.length - 1 - s) == n.codeUnitAt(n.length - 1 - s)) {
      s++;
    }
    final inserted = n.substring(p, n.length - s);
    if (inserted.isEmpty || inserted.length > 3 || !hasMappable(inserted)) return null;
    final converted = transliterate(inserted);
    if (converted == inserted) return null;
    final text = n.substring(0, p) + converted + n.substring(n.length - s);
    final shift = converted.length - inserted.length;
    int fix(int offset) => offset < p ? offset : (offset + shift).clamp(0, text.length);
    final sel = newValue.selection;
    return TextEditingValue(
      text: text,
      selection: sel.isValid ? TextSelection(baseOffset: fix(sel.baseOffset), extentOffset: fix(sel.extentOffset)) : TextSelection.collapsed(offset: text.length),
    );
  }
}
