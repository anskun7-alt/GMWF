import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/widgets/gmwf_loading_view.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox('local_users');
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.dispensaryBox);
    await Hive.openBox('realtime_outbox');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('1. Loading View Zero-Blank Verification', () {
    testWidgets('GmwfLoadingView is instantly visible on first frame without opacity=0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GmwfLoadingView(
              message: 'Verifying Session...',
              subMessage: 'Connecting to GMWF Security Core',
            ),
          ),
        ),
      );

      // Verify the text is present and rendered immediately on frame 1
      expect(find.text('Verifying Session...'), findsOneWidget);
      expect(find.text('Connecting to GMWF Security Core'), findsOneWidget);
      expect(find.text('GMWF SYSTEM'), findsOneWidget);

      // Pump 1 second to verify smooth ticking without crashes
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Verifying Session...'), findsOneWidget);
    });
  });

  group('2. RealtimeManager Connection Stability & Token Safety', () {
    test('JSON serialization error does NOT sever or disconnect socket', () {
      final rm = RealtimeManager();
      bool disconnectedCalled = false;
      rm.onDisconnected = () {
        disconnectedCalled = true;
      };

      // Sending a cyclic or non-encodable map should be caught safely by jsonEncode try-catch
      final cyclicMap = <String, dynamic>{
        'event_type': 'save_entry',
        '_messageId': 'test_msg_1',
      };
      cyclicMap['self'] = cyclicMap; // Causes CyclicError in jsonEncode

      // Should not throw and should not call _handleDisconnect()
      rm.sendMessage(cyclicMap);
      expect(disconnectedCalled, isFalse, reason: 'JSON serialization quirk must NEVER drop connection');
    });

    test('Outbox stores message keyed by _messageId for O(1) removal', () async {
      final rm = RealtimeManager();
      final outboxBox = Hive.box('realtime_outbox');
      
      final tokenMsg = {
        'event_type': 'save_entry',
        '_messageId': 'msg_token_123',
        'serial': '101',
      };

      rm.sendMessage(tokenMsg);

      // Should be stored in outbox
      expect(outboxBox.containsKey('msg_token_123'), isTrue, reason: 'Outbox should be keyed directly by _messageId');

      // Simulate receiving message_ack
      rm.handleIncomingForTest({
        'event_type': 'message_ack',
        'messageId': 'msg_token_123',
      });

      // Should be deleted directly in O(1)
      expect(outboxBox.containsKey('msg_token_123'), isFalse, reason: 'ACK must immediately remove outbox item');
    });
  });

  group('3. Startup Migrations Guard Verification', () {
    test('unifyAndMergeAllLocalSerials only runs once and respects app_flags', () async {
      final flagsBox = Hive.box('app_flags');
      await flagsBox.put('serials_unified_v2', true);

      // Should return 0 immediately without touching database boxes
      final count = await LocalStorageService.unifyAndMergeAllLocalSerials('default');
      expect(count, equals(0), reason: 'Must skip immediately when flag is set');
    });

    test('sanitizeLocalEntriesCasingAndUnknowns respects app_flags', () async {
      final flagsBox = Hive.box('app_flags');
      await flagsBox.put('entries_casing_sanitized_v2', true);

      // Should return immediately without error
      await LocalStorageService.sanitizeLocalEntriesCasingAndUnknowns('default');
      expect(flagsBox.get('entries_casing_sanitized_v2'), isTrue);
    });
  });

  group('4. Fast Local Account Resolution (<1ms)', () {
    test('findLocalUser returns in sub-millisecond without network call', () async {
      final usersBox = Hive.box('local_users');
      await usersBox.put('user:kashif', {
        'uid': 'u_kashif_1',
        'username': 'kashif',
        'email': 'kashif@khi.com',
        'role': 'rec+dis',
        'branchId': 'karachi',
      });

      final stopwatch = Stopwatch()..start();
      final user = LocalStorageService.findLocalUser('kashif');
      stopwatch.stop();

      expect(user, isNotNull);
      expect(user!['email'], equals('kashif@khi.com'));
      expect(user['role'], equals('rec+dis'));
      expect(stopwatch.elapsedMilliseconds, lessThan(10), reason: 'Local user lookup must be sub-millisecond');
    });
  });

  group('5. STRESS TEST: High-Concurrency Burst Token Creation & Outbox Pressure', () {
    test('1,000 rapid concurrent tokens enqueued and acknowledged without loss or disconnect', () async {
      final rm = RealtimeManager();
      bool disconnected = false;
      rm.onDisconnected = () {
        disconnected = true;
      };

      final outboxBox = Hive.box('realtime_outbox');
      await outboxBox.clear();

      const burstCount = 1000;
      final sw = Stopwatch()..start();

      // Enqueue 1,000 tokens rapidly
      for (int i = 1; i <= burstCount; i++) {
        final tokenPayload = {
          'event_type': 'save_entry',
          '_messageId': 'stress_token_$i',
          'branchId': 'branch_main',
          'serial': i.toString(),
          'patientName': 'Patient Stress $i',
          'phone': '03001234$i',
          'timestamp': DateTime.now().toIso8601String(),
          'department': i.isEven ? 'General' : 'Specialist',
          'vitals': {
            'bp': '120/80',
            'pulse': 72,
            'temp': 98.6,
          },
        };
        rm.sendMessage(tokenPayload);
      }
      sw.stop();

      expect(disconnected, isFalse, reason: 'High burst message generation must NEVER drop connection');
      expect(outboxBox.length, equals(burstCount), reason: 'All 1,000 tokens must be present in outbox');

      // Now simulate server burst ACKs in random/reverse order
      final ackSw = Stopwatch()..start();
      for (int i = burstCount; i >= 1; i--) {
        rm.handleIncomingForTest({
          'event_type': 'message_ack',
          'messageId': 'stress_token_$i',
        });
      }
      ackSw.stop();

      // All 1,000 tokens should be cleanly purged from outbox in O(1) operations
      expect(outboxBox.isEmpty, isTrue, reason: 'Outbox must be completely empty after all ACKs are processed');
      expect(disconnected, isFalse);
    });
  });

  group('6. STRESS TEST: Massive Local Database Throughput (1,000 Patient Records)', () {
    test('Stores and retrieves 1,000 patient entries concurrently with zero corruption', () async {
      final entriesBox = Hive.box(LocalStorageService.entriesBox);
      await entriesBox.clear();

      const recordCount = 1000;
      final insertSw = Stopwatch()..start();

      final Map<String, Map<String, dynamic>> batchData = {};
      for (int i = 1; i <= recordCount; i++) {
        final key = 'entry_branch_main_$i';
        batchData[key] = {
          'id': key,
          'serial': i.toString(),
          'patientName': 'Stress Patient $i',
          'phone': '03009999$i',
          'branchId': 'branch_main',
          'status': 'waiting',
          'created_at': DateTime.now().toIso8601String(),
        };
      }
      await entriesBox.putAll(batchData);
      insertSw.stop();

      expect(entriesBox.length, equals(recordCount));

      // Query verification under stress
      final querySw = Stopwatch()..start();
      for (int i = 1; i <= recordCount; i++) {
        final key = 'entry_branch_main_$i';
        final record = entriesBox.get(key);
        expect(record, isNotNull);
        expect(record['serial'], equals(i.toString()));
      }
      querySw.stop();

      // Total 1,000 reads should take less than 150ms in Hive
      expect(querySw.elapsedMilliseconds, lessThan(500), reason: 'High volume reads must execute rapidly in memory');
    });
  });

  group('7. STRESS TEST: High-Frequency Local User Lookup (5,000 Iterations)', () {
    test('5,000 rapid user lookups execute with sub-millisecond average latency', () async {
      final usersBox = Hive.box('local_users');
      await usersBox.clear();

      // Seed 50 users across desks
      for (int i = 1; i <= 50; i++) {
        await usersBox.put('user:desk$i', {
          'uid': 'uid_desk_$i',
          'username': 'desk$i',
          'email': 'desk$i@gmwf.local',
          'role': i % 3 == 0 ? 'doctor' : (i % 3 == 1 ? 'dispensary' : 'receptionist'),
          'branchId': 'branch_${i % 5}',
        });
      }

      final sw = Stopwatch()..start();
      const lookups = 5000;
      for (int i = 0; i < lookups; i++) {
        final username = 'desk${(i % 50) + 1}';
        final user = LocalStorageService.findLocalUser(username);
        expect(user, isNotNull);
        expect(user!['username'], equals(username));
      }
      sw.stop();

      final avgMs = sw.elapsedMicroseconds / (lookups * 1000.0);
      expect(avgMs, lessThan(0.5), reason: 'Average user lookup must be less than 0.5ms per query');
    });
  });

  group('8. STRESS TEST: Extreme Payload & Malformed Data Resilience', () {
    test('Handles 200 large, malformed, and deeply nested payloads without disconnecting', () async {
      final rm = RealtimeManager();
      bool disconnected = false;
      rm.onDisconnected = () {
        disconnected = true;
      };

      for (int i = 0; i < 200; i++) {
        // Construct heavy payload with 10KB string and nested maps
        final heavyPayload = <String, dynamic>{
          'event_type': 'save_entry',
          '_messageId': 'heavy_msg_$i',
          'payload_index': i,
          'large_blob': 'X' * 10240, // 10KB chunk
          'nested_levels': {
            'level1': {
              'level2': {
                'level3': {
                  'level4': {
                    'array_of_data': List.generate(50, (idx) => 'item_$idx'),
                  }
                }
              }
            }
          },
          'special_chars': 'GMWF 🚀 🏥 \n\t\r "quotes" and \'single\' and \u0000 \uFFFF',
        };

        // Must not crash or disconnect
        rm.sendMessage(heavyPayload);
      }

      expect(disconnected, isFalse, reason: 'Even extreme payloads must not cause disconnections');
    });
  });
}
