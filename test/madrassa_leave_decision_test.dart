import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/pages/madrassa/models/madrassa_config.dart';
import 'package:gmwf/pages/madrassa/models/madrassa_fee_logic.dart';
import 'package:gmwf/pages/madrassa/utils/madrassa_local_storage.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    SyncService.suppressUploadsForTests = true;
    MadrassaLocalStorage.resetHealedForTests();
    tempDir = await Directory.systemTemp.createTemp('gmwf_madrassa_leave_test_');
    Hive.init(tempDir.path);
    await MadrassaLocalStorage.ensureBoxesOpen();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Madrassa leave merge protection (approve & deny)', () {
    test('Teacher APPROVE is never undone by a late pending copy from cloud/LAN', () {
      final local = {
        'syncStatus': 'synced',
        'pendingSync': false,
        'std_1': {
          'attendance': 'leave',
          'leaveStatus': 'approved',
          'isParentRequested': false,
          'leaveReason': 'Family wedding',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          'leaveDecidedBy': 'Qari Sahab',
          'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
          'uniform': 'leave',
          'isLate': false,
          'timing': 'on_time',
          'arrivalTime': null,
          'lastEditedAt': '2026-11-20T05:00:00.000Z',
        },
      };
      final stalePendingRemote = {
        'std_1': {
          'attendance': 'leave_requested',
          'leaveStatus': 'pending',
          'isParentRequested': true,
          'leaveReason': 'Family wedding',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'parentReplied': true,
          'parentReplyText': 'Thank you',
          'lastEditedAt': '2026-11-20T05:10:00.000Z',
        },
      };

      final healed = <String>[];
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        local,
        stalePendingRemote,
        healedStudents: healed,
      );
      final s1 = merged['std_1'] as Map;

      expect(s1['attendance'], equals('leave'));
      expect(s1['leaveStatus'], equals('approved'));
      expect(s1['isParentRequested'], isFalse);
      expect(s1['uniform'], equals('leave'));
      // Non-leave remote fields are still merged cleanly
      expect(s1['parentReplied'], isTrue);
      expect(s1['parentReplyText'], equals('Thank you'));
      // Marked for cloud healing
      expect(healed, contains('std_1'));
    });

    test('Teacher DENY is never undone by a late pending copy from cloud/LAN', () {
      final local = {
        'syncStatus': 'synced',
        'pendingSync': false,
        'std_1': {
          'attendance': 'absent',
          'leaveStatus': 'denied',
          'isParentRequested': false,
          'leaveReason': 'Not feeling like coming',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          'leaveDecidedBy': 'Qari Sahab',
          'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
          'uniform': false,
          'isLate': false,
          'timing': 'on_time',
          'arrivalTime': null,
          'lastEditedAt': '2026-11-20T05:00:00.000Z',
        },
      };
      final stalePendingRemote = {
        'std_1': {
          'attendance': 'leave_requested',
          'leaveStatus': 'pending',
          'isParentRequested': true,
          'leaveReason': 'Not feeling like coming',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'lastEditedAt': '2026-11-20T05:15:00.000Z',
        },
      };

      final healed = <String>[];
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        local,
        stalePendingRemote,
        healedStudents: healed,
      );
      final s1 = merged['std_1'] as Map;

      expect(s1['attendance'], equals('absent'));
      expect(s1['leaveStatus'], equals('denied'));
      expect(s1['isParentRequested'], isFalse);
      expect(s1['uniform'], isFalse);
      expect(healed, contains('std_1'));
    });

    test('Denied leave followed by teacher marking PRESENT survives late pending copy and keeps sabakLines', () {
      final local = {
        'syncStatus': 'synced',
        'pendingSync': false,
        'std_1': {
          'attendance': 'present',
          'leaveStatus': 'denied',
          'isParentRequested': false,
          'leaveReason': 'Sick',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
          'sabakLines': 12,
          'uniform': true,
          'lastEditedAt': '2026-11-20T05:30:00.000Z',
        },
      };
      final stalePendingRemote = {
        'std_1': {
          'attendance': 'leave_requested',
          'leaveStatus': 'pending',
          'isParentRequested': true,
          'leaveReason': 'Sick',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
        },
      };

      final healed = <String>[];
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        local,
        stalePendingRemote,
        healedStudents: healed,
      );
      final s1 = merged['std_1'] as Map;

      expect(s1['attendance'], equals('present'));
      expect(s1['leaveStatus'], equals('denied'));
      expect(s1['sabakLines'], equals(12));
      expect(s1['uniform'], isTrue);
      expect(healed, contains('std_1'));
    });

    test('Cancelled leave (teacher marked PRESENT directly) survives late pending copy', () {
      final local = {
        'syncStatus': 'synced',
        'pendingSync': false,
        'std_1': {
          'attendance': 'present',
          'leaveStatus': 'cancelled',
          'isParentRequested': false,
          'leaveReason': 'Doctor visit',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
        },
      };
      final stalePendingRemote = {
        'std_1': {
          'attendance': 'leave_requested',
          'leaveStatus': 'pending',
          'isParentRequested': true,
          'leaveReason': 'Doctor visit',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
        },
      };

      final healed = <String>[];
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        local,
        stalePendingRemote,
        healedStudents: healed,
      );
      final s1 = merged['std_1'] as Map;

      expect(s1['attendance'], equals('present'));
      expect(s1['leaveStatus'], equals('cancelled'));
      expect(s1['isParentRequested'], isFalse);
      expect(healed, contains('std_1'));
    });

    test('Clock skew immunity: guardian phone 2 hours ahead of teacher PC still preserves BOTH approve and deny', () {
      for (final approve in [true, false]) {
        final local = {
          'syncStatus': 'synced',
          'pendingSync': false,
          'std_1': {
            'attendance': approve ? 'leave' : 'absent',
            'leaveStatus': approve ? 'approved' : 'denied',
            'isParentRequested': false,
            'leaveReason': 'Travel',
            // Guardian clock was 07:00 UTC, teacher clock was 05:00 UTC!
            'leaveRequestedAt': '2026-11-20T07:00:00.000Z',
            'leaveDecidedFor': '2026-11-20T07:00:00.000Z',
            'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          },
        };
        final remote = {
          'std_1': {
            'attendance': 'leave_requested',
            'leaveStatus': 'pending',
            'isParentRequested': true,
            'leaveReason': 'Travel',
            'leaveRequestedAt': '2026-11-20T07:00:00.000Z',
          },
        };

        final healed = <String>[];
        final merged = MadrassaLocalStorage.mergeRemoteLogForTest(local, remote, healedStudents: healed);
        final s1 = merged['std_1'] as Map;

        expect(s1['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(s1['leaveStatus'], equals(approve ? 'approved' : 'denied'));
        expect(healed, contains('std_1'));
      }
    });

    test('Legacy guardian APK without leaveRequestedAt (late serverTimestamp) still preserves approve and deny', () {
      for (final approve in [true, false]) {
        final local = {
          'syncStatus': 'synced',
          'pendingSync': false,
          'std_1': {
            'attendance': approve ? 'leave' : 'absent',
            'leaveStatus': approve ? 'approved' : 'denied',
            'isParentRequested': false,
            'leaveReason': 'High fever',
            'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
          },
        };
        // Late Firestore flush from older guardian app assigns serverTimestamp AFTER decision
        final remote = {
          'std_1': {
            'attendance': 'leave_requested',
            'leaveStatus': 'pending',
            'isParentRequested': true,
            'leaveReason': 'High fever',
            'timestamp': '2026-11-20T06:30:00.000Z',
          },
        };

        final merged = MadrassaLocalStorage.mergeRemoteLogForTest(local, remote);
        final s1 = merged['std_1'] as Map;

        expect(s1['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(s1['leaveStatus'], equals(approve ? 'approved' : 'denied'));
      }
    });

    test('Brand-new guardian leave request submitted AFTER an earlier denial IS accepted', () {
      final local = {
        'syncStatus': 'synced',
        'pendingSync': false,
        'std_1': {
          'attendance': 'absent',
          'leaveStatus': 'denied',
          'isParentRequested': false,
          'leaveReason': 'Tired',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
          'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
          'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
        },
      };
      final newRequestRemote = {
        'std_1': {
          'attendance': 'leave_requested',
          'leaveStatus': 'pending',
          'isParentRequested': true,
          'leaveReason': 'Hospital emergency',
          'leaveRequestedAt': '2026-11-20T06:00:00.000Z',
          'leaveDecidedAt': null,
          'leaveDecidedFor': null,
        },
      };

      final healed = <String>[];
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        local,
        newRequestRemote,
        healedStudents: healed,
      );
      final s1 = merged['std_1'] as Map;

      expect(s1['attendance'], equals('leave_requested'));
      expect(s1['leaveStatus'], equals('pending'));
      expect(s1['leaveReason'], equals('Hospital emergency'));
      expect(healed, isEmpty);
    });

    test('Symmetric: Guardian phone with localPending adopts teacher APPROVE and DENY while keeping unsent reply', () {
      for (final approve in [true, false]) {
        final guardianLocal = {
          'syncStatus': 'pending',
          'pendingSync': true,
          'std_1': {
            'attendance': 'leave_requested',
            'leaveStatus': 'pending',
            'isParentRequested': true,
            'leaveReason': 'Sick',
            'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
            'parentReplied': true,
            'parentReplyText': 'Will attend tomorrow',
            // Guardian replied AFTER teacher decided, so guardian lastEditedAt is newer!
            'lastEditedAt': '2026-11-20T05:30:00.000Z',
          },
        };
        final teacherCloud = {
          'std_1': {
            'attendance': approve ? 'leave' : 'absent',
            'leaveStatus': approve ? 'approved' : 'denied',
            'isParentRequested': false,
            'leaveReason': 'Sick',
            'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
            'leaveDecidedFor': '2026-11-20T04:00:00.000Z',
            'leaveDecidedAt': '2026-11-20T05:00:00.000Z',
            'uniform': approve ? 'leave' : false,
            'lastEditedAt': '2026-11-20T05:00:00.000Z',
          },
        };

        final healed = <String>[];
        final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
          guardianLocal,
          teacherCloud,
          healedStudents: healed,
        );
        final s1 = merged['std_1'] as Map;

        // Teacher's decision wins!
        expect(s1['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(s1['leaveStatus'], equals(approve ? 'approved' : 'denied'));
        expect(s1['isParentRequested'], isFalse);
        // Guardian's unsent reply is preserved!
        expect(s1['parentReplied'], isTrue);
        expect(s1['parentReplyText'], equals('Will attend tomorrow'));
        // No bogus heal triggered
        expect(healed, isEmpty);
      }
    });

    test('Partial LAN delta (e.g. parent reply) does not wipe local attendance or sabakLines', () async {
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: 'gujrat',
        dateKey: '2026-11-20',
        logData: {
          'std_1': {
            'attendance': 'present',
            'sabakLines': 18,
            'uniform': true,
          },
        },
        editorName: 'Qari Sahab',
        editorRole: 'teacher',
      );

      // Simulate receiving a field-level LAN delta from guardian's reply
      await MadrassaLocalStorage.cacheDailyLog('gujrat', '2026-11-20', {
        'std_1': {
          'parentReplied': true,
          'parentReplyText': 'JazakAllah',
          'lastEditedBy': 'Parent/Guardian',
          'lastEditedAt': DateTime.now().toUtc().add(const Duration(seconds: 5)).toIso8601String(),
        },
      });

      final log = MadrassaLocalStorage.getLogCached('gujrat', '2026-11-20');
      final s1 = log!['std_1'] as Map;
      expect(s1['attendance'], equals('present'));
      expect(s1['sabakLines'], equals(18));
      expect(s1['uniform'], isTrue);
      expect(s1['parentReplied'], isTrue);
      expect(s1['parentReplyText'], equals('JazakAllah'));
    });

    test('lastSyncedAt absorbs clock-ahead peer edits so backfill does not re-upload downloaded logs', () {
      final futureEdit = DateTime.now().toUtc().add(const Duration(hours: 2)).toIso8601String();
      final merged = MadrassaLocalStorage.mergeRemoteLogForTest(
        null,
        {
          'std_1': {
            'attendance': 'present',
            'lastEditedAt': futureEdit,
          },
        },
      );
      final lastSynced = DateTime.parse(merged['lastSyncedAt'] as String).toUtc();
      final editDt = DateTime.parse(futureEdit).toUtc();
      expect(lastSynced.isBefore(editDt), isFalse);
      expect(merged['pendingSync'], isFalse);
      expect(merged['syncStatus'], equals('synced'));
    });
  });

  group('End-to-end saveLogRecordLocal, syncBox deltas & healing', () {
    test('Guardian reply on stale local pending cache sends ONLY reply fields, never stale leave_requested', () async {
      // Guardian's phone has an already-synced copy of an earlier pending leave request
      await MadrassaLocalStorage.cacheDailyLog('gujrat', '2026-11-20', {
        'std_1': {
          'attendance': 'leave_requested',
          'isParentRequested': true,
          'leaveStatus': 'pending',
          'leaveReason': 'Sick',
          'leaveRequestedAt': '2026-11-20T04:00:00.000Z',
        },
      });

      // Guardian now submits ONLY a reply before downloading the teacher's approval/denial
      await MadrassaLocalStorage.saveLogRecordLocal(
        branchId: 'gujrat',
        dateKey: '2026-11-20',
        logData: {
          'std_1': {
            'parentReplied': true,
            'parentReplyText': 'Assalam o Alaikum',
          },
        },
        editorName: 'Parent/Guardian',
        editorRole: 'guardian',
      );

      final syncBox = Hive.box(LocalStorageService.syncBox);
      final queued = syncBox.values.whereType<Map>().firstWhere(
        (e) => e['type'] == 'save_madrassa_log' && e['dateKey'] == '2026-11-20',
      );
      final qStudent = (queued['data'] as Map)['std_1'] as Map;

      expect(qStudent['parentReplied'], isTrue);
      expect(qStudent['parentReplyText'], equals('Assalam o Alaikum'));
      // Crucial: stale cached leave fields must NOT be in the outgoing delta!
      expect(qStudent.containsKey('attendance'), isFalse);
      expect(qStudent.containsKey('leaveStatus'), isFalse);
      expect(qStudent.containsKey('isParentRequested'), isFalse);
    });

    test('saveLogRecordLocal auto-stamps leaveDecidedAt, leaveDecidedBy, and leaveDecidedFor for approve & deny', () async {
      for (final approve in [true, false]) {
        final dateKey = approve ? '2026-11-20' : '2026-11-21';
        final reqAt = '2026-11-20T04:00:00.000Z';

        // Existing pending request in local cache
        await MadrassaLocalStorage.cacheDailyLog('gujrat', dateKey, {
          'std_1': {
            'attendance': 'leave_requested',
            'isParentRequested': true,
            'leaveStatus': 'pending',
            'leaveReason': 'Sick',
            'leaveRequestedAt': reqAt,
          },
        });

        // Teacher approves or denies (even without manually setting leaveDecidedAt/For)
        await MadrassaLocalStorage.saveLogRecordLocal(
          branchId: 'gujrat',
          dateKey: dateKey,
          logData: {
            'std_1': {
              'attendance': approve ? 'leave' : 'absent',
              'leaveStatus': approve ? 'approved' : 'denied',
              'isParentRequested': false,
            },
          },
          editorName: 'Qari Bilal',
          editorRole: 'teacher',
        );

        final saved = MadrassaLocalStorage.getLogCached('gujrat', dateKey)!['std_1'] as Map;
        expect(saved['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(saved['leaveStatus'], equals(approve ? 'approved' : 'denied'));
        expect(saved['leaveDecidedAt'], isNotNull);
        expect(saved['leaveDecidedBy'], equals('Qari Bilal'));
        expect(saved['leaveDecidedFor'], equals(reqAt));
      }
    });

    test('cacheDailyLog heals cloud when stale pending arrives after teacher APPROVE or DENY', () async {
      for (final approve in [true, false]) {
        final dateKey = approve ? '2026-11-22' : '2026-11-23';
        final reqAt = '2026-11-22T04:00:00.000Z';

        // 1. Guardian request arrives on teacher PC
        await MadrassaLocalStorage.cacheDailyLog('gujrat', dateKey, {
          'std_1': {
            'attendance': 'leave_requested',
            'isParentRequested': true,
            'leaveStatus': 'pending',
            'leaveReason': 'Fever',
            'leaveRequestedAt': reqAt,
          },
        });

        // 2. Teacher decides (Approve or Deny)
        await MadrassaLocalStorage.saveLogRecordLocal(
          branchId: 'gujrat',
          dateKey: dateKey,
          logData: {
            'std_1': {
              'attendance': approve ? 'leave' : 'absent',
              'leaveStatus': approve ? 'approved' : 'denied',
              'isParentRequested': false,
              'uniform': approve ? 'leave' : false,
            },
          },
          editorName: 'Qari Bilal',
          editorRole: 'teacher',
        );

        // Simulate upload succeeded & syncBox drained
        final syncBox = Hive.box(LocalStorageService.syncBox);
        await syncBox.clear();
        final logsBox = Hive.box(MadrassaLocalStorage.logsBox);
        final localKey = 'gujrat__log__$dateKey';
        final syncedCopy = Map<String, dynamic>.from(logsBox.get(localKey) as Map)
          ..['syncStatus'] = 'synced'
          ..['pendingSync'] = false
          ..['synced'] = true;
        await logsBox.put(localKey, syncedCopy);

        // 3. Stale guardian pending copy arrives from Firestore/LAN
        await MadrassaLocalStorage.cacheDailyLog('gujrat', dateKey, {
          'std_1': {
            'attendance': 'leave_requested',
            'isParentRequested': true,
            'leaveStatus': 'pending',
            'leaveReason': 'Fever',
            'leaveRequestedAt': reqAt,
          },
        });

        // Let the scheduled async heal finish
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Local Hive MUST still have the teacher's decision
        final after = MadrassaLocalStorage.getLogCached('gujrat', dateKey)!['std_1'] as Map;
        expect(after['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(after['leaveStatus'], equals(approve ? 'approved' : 'denied'));
        expect(after['isParentRequested'], isFalse);

        // And syncBox MUST have a healing re-upload with the teacher's decision!
        final healItems = syncBox.values.whereType<Map>().where(
          (e) => e['type'] == 'save_madrassa_log' && e['dateKey'] == dateKey,
        );
        expect(healItems, isNotEmpty);
        final healStudent = (healItems.first['data'] as Map)['std_1'] as Map;
        expect(healStudent['attendance'], equals(approve ? 'leave' : 'absent'));
        expect(healStudent['leaveStatus'], equals(approve ? 'approved' : 'denied'));
      }
    });
  });

  group('Fee calculation for approved vs denied vs pending leave', () {
    test('Approved leave gets attendance & uniform deduction; pending and denied do not', () {
      final config = MadrassaConfig(
        id: 'current',
        year: 2026,
        month: 11,
        baseFee: 3000,
        attendanceMaxDeduction: 1000,
        uniformMaxDeduction: 500,
        messageTotalDeduction: 500,
        ptmDeduction: 1000,
        enableFees: true,
      );
      final studentData = {'joinDate': '2026-11-01'};
      final workingDays = MadrassaFeeLogic.getWorkingDaysCount(2026, 11);

      final approvedFee = MadrassaFeeLogic.calculateStudentFee(
        studentId: 'std_1',
        studentData: studentData,
        logs: [
          {
            'std_1': {
              'attendance': 'leave',
              'leaveStatus': 'approved',
              'uniform': 'leave',
            },
          },
        ],
        config: config,
        totalWorkingDays: workingDays,
      );

      final pendingFee = MadrassaFeeLogic.calculateStudentFee(
        studentId: 'std_1',
        studentData: studentData,
        logs: [
          {
            'std_1': {
              'attendance': 'leave_requested',
              'leaveStatus': 'pending',
            },
          },
        ],
        config: config,
        totalWorkingDays: workingDays,
      );

      final deniedFee = MadrassaFeeLogic.calculateStudentFee(
        studentId: 'std_1',
        studentData: studentData,
        logs: [
          {
            'std_1': {
              'attendance': 'absent',
              'leaveStatus': 'denied',
              'uniform': false,
            },
          },
        ],
        config: config,
        totalWorkingDays: workingDays,
      );

      expect(approvedFee['leave'], equals(1));
      expect(approvedFee['attSavings'], greaterThan(0));
      expect(approvedFee['uniSavings'], greaterThan(0));

      expect(pendingFee['leave'], equals(0));
      expect(pendingFee['attSavings'], equals(0));
      expect(pendingFee['uniSavings'], equals(0));

      expect(deniedFee['leave'], equals(0));
      expect(deniedFee['attSavings'], equals(0));
      expect(deniedFee['uniSavings'], equals(0));
    });
  });
}
