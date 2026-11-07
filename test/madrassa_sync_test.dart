import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/pages/madrassa/utils/madrassa_local_storage.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    SyncService.suppressUploadsForTests = true;
    tempDir = await Directory.systemTemp.createTemp('gmwf_madrassa_sync_test_');
    Hive.init(tempDir.path);
    await MadrassaLocalStorage.ensureBoxesOpen();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Student enrollment normalizes branch, compacts duplicate media, and enqueues sync', () async {
    final fakePhoto = 'data:image/jpeg;base64,${'A' * 40000}';
    final studentId = await MadrassaLocalStorage.saveStudentLocalAndSync(
      branchId: 'grt', // alias for gujrat
      studentId: '',
      isNew: true,
      data: {
        'name': 'Muhammad Ahmed',
        'rollNumber': '101',
        'branchId': 'grt',
        'photoUrl': fakePhoto,
        'photoBase64': fakePhoto,
        'studentPhotoBase64': fakePhoto,
        'bFormUrl': fakePhoto,
        'bFormBase64': fakePhoto,
      },
    );

    expect(studentId, isNotEmpty);

    // Verify cached under canonical 'gujrat' branch
    final cached = MadrassaLocalStorage.getStudentCached('gujrat', studentId);
    expect(cached, isNotNull);
    expect(cached!['name'], equals('Muhammad Ahmed'));
    expect(cached['branchId'], equals('gujrat'));
    expect(cached['photoUrl'], equals(fakePhoto));
    // Duplicate alias fields removed by compactMediaForCloud
    expect(cached.containsKey('photoBase64'), isFalse);
    expect(cached.containsKey('studentPhotoBase64'), isFalse);
    expect(cached.containsKey('bFormBase64'), isFalse);

    // Verify sync queue entry exists
    final syncBox = Hive.box(LocalStorageService.syncBox);
    final queued = syncBox.values.whereType<Map>().where(
      (e) => e['type'] == 'save_madrassa_student' && e['studentId'] == studentId,
    );
    expect(queued, isNotEmpty);
    expect(queued.first['branchId'], equals('gujrat'));
  });

  test('Daily log & Parent reply preserve existing fields and enqueue sync', () async {
    final studentId = await MadrassaLocalStorage.saveStudentLocalAndSync(
      branchId: 'gujrat',
      studentId: 'std_1',
      data: {'name': 'Zaid', 'rollNumber': '1', 'currentLines': 10},
    );

    // 1. Teacher saves daily attendance & sabq
    await MadrassaLocalStorage.saveLogRecordLocal(
      branchId: 'grt', // alias normalized to gujrat
      dateKey: '2026-11-07',
      logData: {
        studentId: {
          'attendance': 'present',
          'sabakLines': 15,
          'currentLines': 25,
        },
      },
      editorName: 'Qari Sahab',
      editorRole: 'teacher',
    );

    // Verify student currentLines updated locally
    final updatedStudent = MadrassaLocalStorage.getStudentCached('gujrat', studentId);
    expect(updatedStudent?['currentLines'], equals(25));

    // 2. Parent submits reply on the same date
    await MadrassaLocalStorage.saveLogRecordLocal(
      branchId: 'gujrat',
      dateKey: '2026-11-07',
      logData: {
        studentId: {
          'parentReplied': true,
          'parentRepliedRequested': true,
          'parentReplyText': 'JazakAllah Khair',
          'parentReplyMessage': 'JazakAllah Khair',
        },
      },
      editorName: 'Parent/Guardian',
      editorRole: 'guardian',
    );

    // Verify teacher's attendance & sabakLines are preserved AND parent reply is merged
    final log = MadrassaLocalStorage.getLogCached('gujrat', '2026-11-07');
    expect(log, isNotNull);
    final studentLog = log![studentId] as Map;
    expect(studentLog['attendance'], equals('present'));
    expect(studentLog['sabakLines'], equals(15));
    expect(studentLog['parentReplied'], isTrue);
    expect(studentLog['parentReplyText'], equals('JazakAllah Khair'));

    // Verify sync queue has coalesced daily log with both teacher & parent fields
    final syncBox = Hive.box(LocalStorageService.syncBox);
    final logSyncItem = syncBox.values.whereType<Map>().firstWhere(
      (e) => e['type'] == 'save_madrassa_log' && e['dateKey'] == '2026-11-07',
    );
    expect(logSyncItem, isNotNull);
    final syncData = logSyncItem['data'] as Map;
    final syncStudentEntry = syncData[studentId] as Map;
    expect(syncStudentEntry['attendance'], equals('present'));
    expect(syncStudentEntry['parentReplied'], isTrue);
    expect(syncStudentEntry['parentReplyText'], equals('JazakAllah Khair'));
  });

  test('compactMediaForCloud is fast and does not block UI thread for normal photos', () {
    final sw = Stopwatch()..start();
    final normalPhoto = 'data:image/jpeg;base64,${'B' * 80000}';
    final compacted = MadrassaLocalStorage.compactMediaForCloud({
      'name': 'Fast Test',
      'photoBase64': normalPhoto,
      'studentPhotoBase64': normalPhoto,
      'bFormBase64': normalPhoto,
      'guardianCnicBase64': normalPhoto,
    });
    sw.stop();

    expect(compacted['photoUrl'], equals(normalPhoto));
    expect(compacted['bFormUrl'], equals(normalPhoto));
    expect(compacted['guardianCnicUrl'], equals(normalPhoto));
    expect(compacted.containsKey('photoBase64'), isFalse);
    expect(sw.elapsedMilliseconds, lessThan(50));
  });
}
