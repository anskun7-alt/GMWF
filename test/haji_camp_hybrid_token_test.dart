import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LanServer server;
  const testPort = 19890;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_haji_camp_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox('local_users');
    await Hive.openBox('local_patients');
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.dispensaryBox);
    await Hive.openBox(LocalStorageService.syncBox);
    await Hive.openBox('realtime_outbox');
    await Hive.openBox('realtime_outbox_failed');
    await Hive.openBox('server_record_versions');
    await Hive.openBox('realtime_dedup_ids');
    await Hive.openBox('realtime_entity_versions');

    server = LanServer(port: testPort);

    // Track tokens received on server
    server.onMessageReceived = (msg) async {
      final type = msg['event_type']?.toString();
      final data = msg['data'] is Map ? Map<String, dynamic>.from(msg['data'] as Map) : msg;
      final serial = (data['serial'] ?? msg['serial'])?.toString();
      final branchId = (data['branchId'] ?? msg['branchId'] ?? 'karachi').toString();
      if (type == RealtimeEvents.saveEntry && serial != null) {
        await LocalStorageService.saveEntryLocal(branchId, serial, data);
      }
    };

    await server.start('127.0.0.1');
  });

  tearDownAll(() async {
    await server.stop();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('HAJI CAMP HYBRID DESK (rec+dis): Token generation with complete nested vitals and child/guardian data', () async {
    final rm = RealtimeManager();
    bool disconnectedFired = false;
    rm.onDisconnected = () {
      disconnectedFired = true;
    };

    // 1. Connect as Haji Camp Hybrid Desk
    await rm.initialize(
      serverIp: '127.0.0.1',
      port: testPort,
      role: 'rec+dis',
      branchId: 'karachi',
      username: 'Kashif',
    );

    // Wait for identified handshake
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!rm.isServerIdentified && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    expect(rm.isConnected, isTrue, reason: 'Haji Camp desk must be connected');
    expect(rm.isServerIdentified, isTrue, reason: 'Haji Camp desk must be identified');
    expect(disconnectedFired, isFalse);

    // 2. Build the EXACT complex payload produced on the Haji Camp Hybrid Desk
    final now = DateTime.now();
    const dateKey = '021026';
    const queueType = 'zakat';
    const dispTag = 'HAJI';
    const campId = 'haji_camp';

    final complexVitals = <String, dynamic>{
      'bp': '120/80',
      'temp': '37.0',
      'tempUnit': 'C',
      'weight': '65',
      'sugar': '110',
      'age': 8,
      'gender': 'Female',
      'bloodGroup': 'B+',
      'receptionistVitals': {
        'bp': '120/80',
        'temp': '37.0',
        'weight': '65',
        'sugar': '110',
        'addedBy': 'Kashif',
        'addedById': 'kashif_uid',
        'addedAt': now.toIso8601String(),
      },
      'auditTrail': [
        {
          'role': 'rec+dis',
          'action': 'Added initial vitals at Haji Camp Desk',
          'by': 'Kashif',
          'byId': 'kashif_uid',
          'at': now.toIso8601String(),
          'bp': '120/80',
          'temp': '37.0',
          'weight': '65',
          'sugar': '110',
        }
      ],
    };

    // Issue 5 realistic tokens with full nested structures
    for (int seq = 1; seq <= 5; seq++) {
      final seqPadded = seq.toString().padLeft(3, '0');
      final serial = '$dateKey-$dispTag-$seqPadded';
      final entryUid = 'ENT-${now.microsecondsSinceEpoch}-$seq';

      final entryData = <String, dynamic>{
        'queueType': queueType,
        'dateKey': dateKey,
        'session': 'morning',
        'patientId': '421010000000$seq',
        'patientName': 'Haji Camp Patient $seq',
        'name': 'Haji Camp Patient $seq',
        'isAdult': seq.isEven,
        'age': seq * 7,
        'gender': seq.isEven ? 'Male' : 'Female',
        'isVitalsOnly': false,
        'vitalsOnly': false,
        'visitReason': 'General Consultation',
        'patientCnic': '42101-000000$seq-1',
        'guardianCnic': seq.isOdd ? '42101-9999999-1' : null,
        'guardianName': seq.isOdd ? 'Guardian of Patient $seq' : null,
        'createdAt': now.toIso8601String(),
        'status': 'waiting',
        'vitals': complexVitals,
        'branchId': 'karachi',
        'dispensaryTag': dispTag,
        'dispensaryId': campId,
        'campId': campId,
        'campName': 'Haji Camp Dispensary',
        'dispensaryName': 'Haji Camp Dispensary',
        'createdBy': 'kashif_uid',
        'createdByName': 'Kashif',
        'performedBy': 'Kashif',
        'entryUid': entryUid,
        'serial': serial,
        'pendingSync': true,
      };

      // STEP 1 — Save local Hive
      await LocalStorageService.saveEntryLocal('karachi', serial, entryData);

      // STEP 2 — Broadcast via RealtimeManager (The exact line that disconnected in 1.6.0)
      rm.sendMessage({
        ...RealtimeEvents.payload(
          type: RealtimeEvents.saveEntry,
          branchId: 'karachi',
          data: entryData,
        ),
        'entryUid': entryUid,
        'queueType': queueType,
        'dateKey': dateKey,
        'serial': serial,
      });

      // Verify connection did not drop during send
      expect(rm.isConnected, isTrue, reason: 'RealtimeManager MUST stay connected during token #$seq issuance');
      expect(disconnectedFired, isFalse, reason: 'Disconnected callback MUST NOT fire during token #$seq issuance');

      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Allow outbox / network loop to settle
    await Future.delayed(const Duration(seconds: 2));

    // Final assertions
    expect(rm.isConnected, isTrue, reason: 'RealtimeManager must remain solidly connected after all tokens');
    expect(disconnectedFired, isFalse, reason: 'No disconnect occurred');

    // Verify tokens were saved in Hive
    final savedToken = LocalStorageService.getLocalEntry('karachi', '$dateKey-$dispTag-001');
    expect(savedToken, isNotNull);
    expect(savedToken?['serial'], equals('$dateKey-$dispTag-001'));

    await rm.dispose();
  });
}
