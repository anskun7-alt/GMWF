import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LanServer server;
  const testPort = 19888;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_token_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox('local_users');
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.dispensaryBox);
    await Hive.openBox(LocalStorageService.syncBox);
    await Hive.openBox('realtime_outbox');
    await Hive.openBox('realtime_outbox_failed');
    await Hive.openBox('server_record_versions');

    server = LanServer(port: testPort);

    // Attach realistic server onMessageReceived simulating SSM
    server.onMessageReceived = (msg) async {
      final data = msg['data'] is Map ? Map<String, dynamic>.from(msg['data'] as Map) : msg;
      final serial = (data['serial'] ?? msg['serial'])?.toString();
      final branchId = (data['branchId'] ?? msg['branchId'] ?? 'test_branch').toString();
      if (serial != null) {
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

  test('Simulate RealtimeManager sending save_entry over real WebSocket', () async {
    final rm = RealtimeManager();
    bool disconnected = false;
    rm.onDisconnected = () {
      disconnected = true;
    };

    await rm.initialize(
      serverIp: '127.0.0.1',
      port: testPort,
      role: 'receptionist',
      branchId: 'test_branch',
      username: 'receptionist_test',
    );

    // Wait until identified
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!rm.isServerIdentified && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(rm.isServerIdentified, isTrue);
    expect(rm.isConnected, isTrue);

    // Now issue 10 tokens in sequence like a receptionist clicking Issue Token
    for (int i = 1; i <= 10; i++) {
      final serial = '261002-TEST-00$i';
      final entryData = {
        'serial': serial,
        'patientName': 'Patient $i',
        'patientCnic': '42101-000000$i-1',
        'status': 'waiting',
        'branchId': 'test_branch',
        'queueType': 'zakat',
      };

      await LocalStorageService.saveEntryLocal('test_branch', serial, entryData);

      rm.sendMessage({
        ...RealtimeEvents.payload(
          type: RealtimeEvents.saveEntry,
          branchId: 'test_branch',
          data: entryData,
        ),
        'serial': serial,
        'dateKey': '261002',
        'queueType': 'zakat',
      });

      // Brief delay between tokens
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Wait 2 seconds to see if any disconnect occurred
    await Future.delayed(const Duration(seconds: 2));

    expect(disconnected, isFalse, reason: 'RealtimeManager must NEVER disconnect during token generation');
    expect(rm.isConnected, isTrue);

    await rm.dispose();
  });

  test('Multi-Peer Real Network Test: Receptionist issuing tokens while Doctor & Dispenser actively ACK', () async {
    final rmRec = RealtimeManager();
    bool recDisconnected = false;
    rmRec.onDisconnected = () {
      recDisconnected = true;
    };

    await rmRec.initialize(
      serverIp: '127.0.0.1',
      port: testPort,
      role: 'receptionist',
      branchId: 'test_branch',
      username: 'receptionist_desk',
    );

    // Connect Doctor desk over real TCP socket
    final doctorSocket = await WebSocket.connect('ws://127.0.0.1:$testPort');
    doctorSocket.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'test_branch',
      'username': 'dr_ahmed',
      '_clientId': 'doc_client_1',
      'protocolVersion': 2,
    }));

    // Connect Dispenser desk over real TCP socket
    final dispenserSocket = await WebSocket.connect('ws://127.0.0.1:$testPort');
    dispenserSocket.add(jsonEncode({
      'event_type': 'identify',
      'role': 'dispenser',
      'branchId': 'test_branch',
      'username': 'dispenser_main',
      '_clientId': 'disp_client_1',
      'protocolVersion': 2,
    }));

    // Listen on Doctor & Dispenser sockets and immediately reflect ack_serials like real clients do
    int doctorTokensReceived = 0;
    int dispenserTokensReceived = 0;

    doctorSocket.listen((msg) {
      try {
        final decoded = jsonDecode(msg as String);
        if (decoded['event_type'] == 'save_entry') {
          doctorTokensReceived++;
          final serial = decoded['serial'] ?? decoded['data']?['serial'];
          // Reflect immediate ACK
          doctorSocket.add(jsonEncode({
            'event_type': 'ack_serials',
            'serials': [serial],
            '_clientId': 'doc_client_1',
            '_timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        }
      } catch (_) {}
    });

    dispenserSocket.listen((msg) {
      try {
        final decoded = jsonDecode(msg as String);
        if (decoded['event_type'] == 'save_entry') {
          dispenserTokensReceived++;
          final serial = decoded['serial'] ?? decoded['data']?['serial'];
          // Reflect immediate ACK
          dispenserSocket.add(jsonEncode({
            'event_type': 'ack_serials',
            'serials': [serial],
            '_clientId': 'disp_client_1',
            '_timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        }
      } catch (_) {}
    });

    // Wait until receptionist is identified
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!rmRec.isServerIdentified && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(rmRec.isServerIdentified, isTrue);

    // Rapidly issue 25 tokens from Receptionist
    for (int i = 1; i <= 25; i++) {
      final serial = '261002-MULTI-0$i';
      final entryData = {
        'serial': serial,
        'patientName': 'Multi Patient $i',
        'patientCnic': '42101-999999$i-1',
        'status': 'waiting',
        'branchId': 'test_branch',
        'queueType': 'zakat',
      };

      await LocalStorageService.saveEntryLocal('test_branch', serial, entryData);

      rmRec.sendMessage({
        ...RealtimeEvents.payload(
          type: RealtimeEvents.saveEntry,
          branchId: 'test_branch',
          data: entryData,
        ),
        'serial': serial,
        'dateKey': '261002',
        'queueType': 'zakat',
      });

      await Future.delayed(const Duration(milliseconds: 20));
    }

    // Wait 3 seconds for peer messages & ACKs to propagate
    final waitEnd = DateTime.now().add(const Duration(seconds: 5));
    while ((doctorTokensReceived < 25 || dispenserTokensReceived < 25) && DateTime.now().isBefore(waitEnd)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    expect(recDisconnected, isFalse, reason: 'Receptionist must not disconnect during multi-peer token broadcast');
    expect(doctorSocket.readyState, equals(WebSocket.open), reason: 'Doctor socket must stay open');
    expect(dispenserSocket.readyState, equals(WebSocket.open), reason: 'Dispenser socket must stay open');
    expect(doctorTokensReceived, equals(25));
    expect(dispenserTokensReceived, equals(25));

    await rmRec.dispose();
    await doctorSocket.close();
    await dispenserSocket.close();
  });
}
