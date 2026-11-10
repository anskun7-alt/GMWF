import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/services/sync_service.dart';

void main() {
  group('SyncService.foodTokenDeviceTag', () {
    test('uses the last 6 letters/digits of the device id', () {
      expect(SyncService.foodTokenDeviceTag('dev_3f2a9c1e-77b0-4d1a-9e2f-0a1b2c3d4e5f'), '3d4e5f');
    });

    test('two PCs get different tags, so the same token number gives different ids', () {
      final a = SyncService.foodTokenDeviceTag('dev_aaaa-1111');
      final b = SyncService.foodTokenDeviceTag('dev_bbbb-2222');
      expect(a, isNot(b));
      expect('dst_karachi_2026-11-10_12_$a', isNot('dst_karachi_2026-11-10_12_$b'));
    });

    test('is stable for the same PC', () {
      expect(SyncService.foodTokenDeviceTag('dev_ABC-123'), SyncService.foodTokenDeviceTag('dev_ABC-123'));
    });

    test('short or empty ids still give a usable tag', () {
      expect(SyncService.foodTokenDeviceTag('ab'), 'ab');
      expect(SyncService.foodTokenDeviceTag(''), 'pc');
      expect(SyncService.foodTokenDeviceTag('---'), 'pc');
    });
  });
}
