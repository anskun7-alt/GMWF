import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  group('LocalStorageService.isAttendanceUploaded', () {
    test('a day with a new punch is not uploaded', () {
      expect(LocalStorageService.isAttendanceUploaded({
        'synced': false, 'syncStatus': 'pending', 'pendingSync': true,
      }), isFalse);
    });

    test('a record uploaded by this PC is uploaded', () {
      expect(LocalStorageService.isAttendanceUploaded({
        'synced': true, 'syncStatus': 'synced', 'pendingSync': false, 'lastSyncedAt': '2026-11-10T08:00:00Z',
      }), isTrue);
    });

    test('a record downloaded from the cloud (no synced / lastSyncedAt) is uploaded', () {
      // These used to look "unsynced" and were queued again on every sweep (the flood).
      expect(LocalStorageService.isAttendanceUploaded({'syncStatus': 'synced'}), isTrue);
    });

    test('a record the LAN server marked (pendingSync left true) is uploaded', () {
      expect(LocalStorageService.isAttendanceUploaded({
        'synced': true, 'syncStatus': 'synced', 'pendingSync': true,
      }), isTrue);
    });

    test('a record with no sync fields at all is not uploaded', () {
      expect(LocalStorageService.isAttendanceUploaded({'punches': []}), isFalse);
    });

    test('synced:false wins over a stale synced status', () {
      expect(LocalStorageService.isAttendanceUploaded({'synced': false, 'syncStatus': 'synced'}), isFalse);
    });
  });
}
