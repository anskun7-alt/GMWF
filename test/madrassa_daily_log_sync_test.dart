// Sabak / Sabqi / Manzil sync between PCs (2026-11-21).
//
// A PC with an unsent edit used to keep its WHOLE copy of a student's entry when
// another PC's copy arrived, so an older Sabqi/Manzil on that PC hid the newer one
// and was later uploaded over it. Now only the fields this PC actually changed
// stay local; everything else takes the incoming copy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/pages/madrassa/utils/madrassa_local_storage.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'gujrat__log__2026-11-21';
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('madrassa_log_sync_');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> localDay() => {
        'pendingSync': true,
        'syncStatus': 'pending',
        'S1': {
          'attendance': 'present',
          'sabkiPara': 0,
          'sabkiRatio': '-',
          'lastEditedAt': '2026-11-21T10:05:00Z',
        },
      };

  final remoteDay = {
    'S1': {
      'attendance': 'absent',
      'sabkiPara': 7,
      'sabkiRatio': '1/2',
      'manzilPara': 2,
      'manzilRatio': '1',
      'lastEditedAt': '2026-11-21T10:00:00Z',
    },
  };

  tearDown(() => MadrassaLocalStorage.setPendingFieldsForTest(key, null));

  test('only the unsent fields stay local; peer Sabqi/Manzil come through', () {
    MadrassaLocalStorage.setPendingFieldsForTest(key, {
      'S1': {'attendance'},
    });
    final merged = MadrassaLocalStorage.mergeRemoteLogForTest(localDay(), remoteDay, logKey: key);
    final s1 = merged['S1'] as Map;
    expect(s1['attendance'], 'present', reason: 'this PC changed attendance and has not sent it');
    expect(s1['sabkiPara'], 7);
    expect(s1['sabkiRatio'], '1/2');
    expect(s1['manzilPara'], 2);
    expect(s1['manzilRatio'], '1');
    expect(merged['pendingSync'], true, reason: 'the day is still unsent here');
  });

  test('without known unsent fields the older whole-entry rule still applies', () {
    final merged = MadrassaLocalStorage.mergeRemoteLogForTest(localDay(), remoteDay);
    final s1 = merged['S1'] as Map;
    expect(s1['attendance'], 'present');
    expect(s1['sabkiPara'], 0);
    expect(s1['manzilPara'], 2, reason: 'fields only the peer has are still added');
  });

  test('a synced day takes the incoming copy and forgets old unsent marks', () {
    MadrassaLocalStorage.setPendingFieldsForTest(key, {
      'S1': {'attendance'},
    });
    final synced = localDay()
      ..['pendingSync'] = false
      ..['syncStatus'] = 'synced';
    final merged = MadrassaLocalStorage.mergeRemoteLogForTest(synced, remoteDay, logKey: key);
    final s1 = merged['S1'] as Map;
    expect(s1['attendance'], 'absent');
    expect(s1['sabkiPara'], 7);
  });
}
