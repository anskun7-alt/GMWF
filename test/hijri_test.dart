import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/madrassa/utils/islamic_calendar_helper.dart';

void main() {
  test('Pakistan Islamic Calendar calculation check', () {
    final d = DateTime(2026, 9, 4);
    final h = IslamicCalendarHelper.fromGregorian(d);
    print('Pakistan Hijri on 2026-09-04: ${h.day} ${h.monthName()} ${h.year} AH');
    print('Urdu formatted: ${h.format(isUrdu: true)}');

    expect(h.year, 1448);
    expect(h.month, 3);
    expect(h.monthName(), 'Rabi al-Awwal');
    expect(h.monthName(isUrdu: true), 'ربیع الاول');
    expect(h.day, 21);
  });
}
