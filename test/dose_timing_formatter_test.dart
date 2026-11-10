import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/utils/formatters.dart';

TextEditingValue _v(String t) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));

void main() {
  const f = DoseTimingInputFormatter();
  String type(String typed) {
    var cur = _v('');
    for (final ch in typed.split('')) {
      cur = f.formatEditUpdate(cur, _v(cur.text + ch));
    }
    return cur.text;
  }

  test('digits get + automatically', () {
    expect(type('1'), '1');
    expect(type('10'), '1+0');
    expect(type('101'), '1+0+1');
    expect(type('111'), '1+1+1');
  });
  test('typing into a full box starts a new timing (max 3 doses)', () {
    expect(type('1019'), '9');
    expect(type('101100'), '1+0+0');
  });
  // The dialog opens pre-filled with 1+0+1. Typing over it must not keep 1+0+1.
  String typeOver(String start, String typed, {bool atStart = false}) {
    var cur = _v(start);
    for (final ch in typed.split('')) {
      cur = f.formatEditUpdate(cur, _v(atStart ? ch + cur.text : cur.text + ch));
    }
    return cur.text;
  }
  test('typing over the pre-filled 1+0+1 replaces it', () {
    expect(typeOver('1+0+1', '100'), '1+0+0');
    expect(typeOver('1+0+1', '001'), '0+0+1');
    expect(typeOver('1+0+1', '010'), '0+1+0');
    expect(typeOver('1+0+1', '1'), '1'); // saved as 1+0+0 by resolveCanonicalTiming
    expect(typeOver('1+0+1', '1', atStart: true), '1');
  });
  test('pasting a timing into a full box replaces it', () {
    expect(f.formatEditUpdate(_v('1+0+1'), _v('1+0+11+0+0')).text, '1+0+0');
  });
  test('typed + is ignored (no doubles)', () {
    expect(type('1+0+1'), '1+0+1');
  });
  test('backspace over + removes the dose before it', () {
    expect(f.formatEditUpdate(_v('1+0+1'), _v('1+0+')).text, '1+0');
    expect(f.formatEditUpdate(_v('1+0'), _v('1+')).text, '1');
  });
}
