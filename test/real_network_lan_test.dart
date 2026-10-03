import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/services/local_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LanServer server;
  const testPort = 19876;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_lan_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox('local_users');
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.dispensaryBox);
    await Hive.openBox('realtime_outbox');

    // Start REAL LanServer on real TCP network port 19876
    server = LanServer(port: testPort);
    await server.start('127.0.0.1');
  });

  tearDownAll(() async {
    await server.stop();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('LIVE NETWORK TEST: Real TCP sockets between Server, Receptionist, and Doctor', () async {
    // 1. Connect Client 1 (Receptionist) over live TCP socket
    final clientRec = await WebSocket.connect('ws://127.0.0.1:$testPort');
    final recBroadcastController = StreamController<Map<String, dynamic>>.broadcast();

    clientRec.listen((data) {
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) {
            recBroadcastController.add(decoded);
          }
        } catch (_) {}
      }
    });

    // 2. Connect Client 2 (Doctor Desk) over live TCP socket
    final clientDoc = await WebSocket.connect('ws://127.0.0.1:$testPort');
    final docBroadcastController = StreamController<Map<String, dynamic>>.broadcast();

    clientDoc.listen((data) {
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) {
            docBroadcastController.add(decoded);
          }
        } catch (_) {}
      }
    });

    // 3. Receptionist Handshake
    clientRec.add(jsonEncode({
      'event_type': 'identify',
      'role': 'receptionist',
      'branchId': 'main_test',
      'protocolVersion': 2,
      '_clientId': 'client_rec_uuid_1',
      'username': 'receptionist_pc',
    }));

    // Wait for receptionist identified confirmation
    final recIdentified = await recBroadcastController.stream
        .firstWhere((msg) => msg['event_type'] == 'identified')
        .timeout(const Duration(seconds: 5));
    expect(recIdentified['event_type'], equals('identified'));
    expect(recIdentified['role'], equals('receptionist'));

    // 4. Doctor Desk Handshake
    clientDoc.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'main_test',
      'protocolVersion': 2,
      '_clientId': 'client_doc_uuid_1',
      'username': 'doctor_pc',
    }));

    // Wait for doctor identified confirmation
    final docIdentified = await docBroadcastController.stream
        .firstWhere((msg) => msg['event_type'] == 'identified')
        .timeout(const Duration(seconds: 5));
    expect(docIdentified['event_type'], equals('identified'));
    expect(docIdentified['role'], equals('doctor'));

    // Check server tracks both clients over the live network
    expect(server.clientCount, equals(2));

    // 5. Receptionist creates a Token over the live network wire
    const testMsgId = 'live_net_token_token_42';
    clientRec.add(jsonEncode({
      'event_type': 'save_entry',
      '_messageId': testMsgId,
      'branchId': 'main_test',
      'serial': '42',
      'patientName': 'Ahmad Bilal',
      'phone': '03001234567',
      'timestamp': DateTime.now().toIso8601String(),
    }));

    // 6. Verify Receptionist receives ACK over the real TCP network socket
    final ack = await recBroadcastController.stream
        .firstWhere((msg) => msg['event_type'] == 'message_ack' && msg['messageId'] == testMsgId)
        .timeout(const Duration(seconds: 5));
    expect(ack['messageId'], equals(testMsgId));

    // 7. Verify Doctor receives the routed token over the live TCP network wire
    final docReceived = await docBroadcastController.stream
        .firstWhere((msg) => msg['event_type'] == 'save_entry' && msg['serial'] == '42')
        .timeout(const Duration(seconds: 5));
    expect(docReceived['patientName'], equals('Ahmad Bilal'));

    // 8. High-Frequency Live Network Stress: 50 rapid tokens over the live wire
    final receivedAcks = <String>{};
    final sub = recBroadcastController.stream.listen((msg) {
      if (msg['event_type'] == 'message_ack') {
        receivedAcks.add(msg['messageId'].toString());
      }
    });

    const burstCount = 50;
    for (int i = 1; i <= burstCount; i++) {
      clientRec.add(jsonEncode({
        'event_type': 'save_entry',
        '_messageId': 'burst_net_$i',
        'branchId': 'main_test',
        'serial': '$i',
        'patientName': 'Burst Patient $i',
      }));
    }

    // Wait until all 50 ACKs arrive back over the live network
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (receivedAcks.length < burstCount && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    expect(receivedAcks.length, equals(burstCount),
        reason: 'All 50 tokens must receive an ACK over the real TCP connection');

    // Both sockets must still be wide open and connected
    expect(clientRec.readyState, equals(WebSocket.open));
    expect(clientDoc.readyState, equals(WebSocket.open));

    await sub.cancel();
    await recBroadcastController.close();
    await docBroadcastController.close();
    await clientRec.close();
    await clientDoc.close();
  });
}
