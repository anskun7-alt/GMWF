import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/utils/token_order.dart';

/// Patients must be seen in the order they got their token: server-numbered tokens by
/// number, offline-issued tokens (desk block 1001+) slotted in by issue time.
void main() {
  final t0 = DateTime(2026, 11, 5, 9).millisecondsSinceEpoch;
  int at(int minutes) => t0 + minutes * 60000;

  Map<String, dynamic> tok(int seq, int? minute, {String prefix = '051126M-SADD'}) => {
        'serial': '$prefix-${seq.toString().padLeft(3, '0')}',
        if (minute != null) 'issuedAtMs': at(minute),
      };

  List<String> order(List<Map<String, dynamic>> l, {bool newestFirst = false}) =>
      TokenOrder.sortFairly(l, newestFirst: newestFirst)
          .map((e) => e['serial'].toString().split('-').last)
          .toList();

  test('online tokens follow their number even if they arrived out of order', () {
    expect(order([tok(3, 3), tok(1, 1), tok(2, 2)]), ['001', '002', '003']);
  });

  test('online tokens keep number order even when desk clocks disagree', () {
    // Token 2 was issued on a desk whose clock is 10 minutes behind.
    expect(order([tok(1, 5), tok(2, -5), tok(3, 6)]), ['001', '002', '003']);
  });

  test('an offline token keeps its real place in line', () {
    // 1001 was issued offline at minute 2, between online 2 (minute 1) and 3 (minute 3).
    final list = [tok(1, 0), tok(2, 1), tok(3, 3), tok(4, 4), tok(1001, 2)];
    expect(order(list), ['001', '002', '1001', '003', '004']);
  });

  test('offline tokens from two desks interleave by time, not by block', () {
    final list = [tok(2001, 1), tok(1001, 2), tok(2002, 3), tok(1002, 4)];
    expect(order(list), ['2001', '1001', '2002', '1002']);
  });

  test('an offline token issued before any online token comes first', () {
    expect(order([tok(1, 10), tok(2, 11), tok(1001, 5)]), ['1001', '001', '002']);
  });

  test('offline token with no time goes after the others, nothing is dropped', () {
    final list = [tok(1, 0), tok(1001, null), tok(2, 1)];
    expect(order(list), ['001', '002', '1001']);
  });

  test('createdAt (ISO) is used when issuedAtMs is missing', () {
    final list = [
      {'serial': '051126M-SADD-001', 'createdAt': DateTime(2026, 11, 5, 9, 0).toIso8601String()},
      {'serial': '051126M-SADD-002', 'createdAt': DateTime(2026, 11, 5, 9, 10).toIso8601String()},
      {'serial': '051126M-SADD-1001', 'createdAt': DateTime(2026, 11, 5, 9, 5).toIso8601String()},
    ];
    expect(order(list), ['001', '1001', '002']);
  });

  test('newestFirst reverses the fair order', () {
    final list = [tok(1, 0), tok(2, 2), tok(1001, 1)];
    expect(order(list, newestFirst: true), ['002', '1001', '001']);
  });

  test('result is a new list; input is not reordered', () {
    final list = [tok(2, 2), tok(1, 1)];
    final sorted = TokenOrder.sortFairly(list);
    expect(list.first['serial'], '051126M-SADD-002');
    expect(sorted.first['serial'], '051126M-SADD-001');
  });
}
