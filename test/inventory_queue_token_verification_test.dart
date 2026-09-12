import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Token Queue Rollover & Dispensed Token Invariants', () {
    final todayKey = LocalStorageService.getTodayDateKey();
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final yesterdayDateKey = DateFormat('ddMMyy').format(DateTime.now().subtract(const Duration(days: 1)));
    final yesterdayIso = DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1)));

    // Replicate the invariant algorithm from patient_queue.dart and patient_list.dart
    bool testIsEffectivelyToday(Map<String, dynamic> e) {
      final status = (e['status'] ?? '').toString().toLowerCase().trim();
      final dispenseStatus = (e['dispenseStatus'] ?? '').toString().toLowerCase().trim();
      final isTerminal = status == 'completed' ||
          status == 'dispensed' ||
          status == 'cancelled' ||
          status == 'expired' ||
          status == 'reversed' ||
          status == 'deleted' ||
          dispenseStatus == 'dispensed';

      final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();
      final serialDk = CampSessionService.getDateKeyFromSerial(serial);
      final dk = (e['dateKey'] ?? '').toString().trim();
      final rawTime = e['createdAt'] ?? e['timestamp'] ?? e['date'] ?? e['time'] ?? e['dispensedAt'];

      // 1. Exact match with today's dateKey or ISO date string
      bool isTodayExact = false;
      if (dk == todayKey || (serialDk.isNotEmpty && serialDk == todayKey)) {
        isTodayExact = true;
      } else if (rawTime != null) {
        final rawStr = rawTime.toString();
        if (rawStr.startsWith(todayIso)) {
          isTodayExact = true;
        } else {
          final dt = DateTime.tryParse(rawStr);
          if (dt != null) {
            final dtKey = CampSessionService.resolveShiftAndDateKey(dt, 'main').dateKey;
            if (dtKey == todayKey) isTodayExact = true;
          }
        }
      } else if (dk.isEmpty && serialDk.isEmpty) {
        isTodayExact = true;
      }

      if (isTodayExact) return true;

      // 2. Shift/Rollover Tolerance: Only if non-terminal (waiting), accept previous day within 24h
      if (!isTerminal) {
        if (dk == yesterdayDateKey || (serialDk.isNotEmpty && serialDk == yesterdayDateKey)) {
          return true;
        }
        if (rawTime != null) {
          final rawStr = rawTime.toString();
          if (rawStr.startsWith(yesterdayIso)) {
            return true;
          }
          final dt = DateTime.tryParse(rawStr);
          if (dt != null && DateTime.now().difference(dt).inHours < 24) {
            return true;
          }
        }
      }

      return false;
    }

    test('Today dispensed token is strictly kept and does NOT disappear', () {
      final todayDispensedToken = {
        'serial': '005',
        'dateKey': todayKey,
        'createdAt': DateTime.now().toIso8601String(),
        'dispensedAt': DateTime.now().toIso8601String(),
        'status': 'completed',
        'dispenseStatus': 'dispensed',
        'patientName': 'Muhammad Ali',
      };

      expect(testIsEffectivelyToday(todayDispensedToken), isTrue);
    });

    test('Yesterday completed or dispensed token is REJECTED and does NOT leak into today', () {
      final yesterdayDispensedToken = {
        'serial': '012',
        'dateKey': yesterdayDateKey,
        'createdAt': '${yesterdayIso}T12:00:00.000',
        'status': 'completed',
        'dispenseStatus': 'dispensed',
        'patientName': 'Old Dispensed Patient',
      };

      expect(testIsEffectivelyToday(yesterdayDispensedToken), isFalse);
    });

    test('Yesterday waiting token within 24h rolls over safely for doctor continuation', () {
      final yesterdayWaitingToken = {
        'serial': '099',
        'dateKey': yesterdayDateKey,
        'createdAt': DateTime.now().subtract(const Duration(hours: 10)).toIso8601String(),
        'status': 'waiting',
        'dispenseStatus': 'pending',
        'patientName': 'Night Shift Unseen Patient',
      };

      expect(testIsEffectivelyToday(yesterdayWaitingToken), isTrue);
    });

    test('Token older than 24h is rejected regardless of status', () {
      final staleToken = {
        'serial': '001',
        'dateKey': '010125',
        'createdAt': DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
        'status': 'waiting',
        'dispenseStatus': 'pending',
      };

      expect(testIsEffectivelyToday(staleToken), isFalse);
    });
  });
}
