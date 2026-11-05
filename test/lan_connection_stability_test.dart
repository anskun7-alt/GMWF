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
  const testPort = 54321;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('gmwf_conn_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('app_settings');
    await Hive.openBox('app_flags');
    await Hive.openBox('local_users');
    await Hive.openBox(LocalStorageService.entriesBox);
    await Hive.openBox(LocalStorageService.prescriptionsBox);
    await Hive.openBox(LocalStorageService.dispensaryBox);
    await Hive.openBox(LocalStorageService.stockBox);
    await Hive.openBox('realtime_outbox');

    server = LanServer(port: testPort)
      ..persistenceReady = true; // no ServerSyncManager in these tests
    await server.start('127.0.0.1');
  });

  tearDownAll(() async {
    await server.stop();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('VIRTUAL AUDIT: Stress test with 300 stock catch-up frames and verify ping/pong survivability', () async {
    // Connect dispenser
    final dispenser = await WebSocket.connect('ws://127.0.0.1:$testPort');
    final dispenserMsgs = StreamController<Map<String, dynamic>>.broadcast();

    dispenser.listen((data) {
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) {
            dispenserMsgs.add(decoded);
          }
        } catch (_) {}
      }
    });

    // Identify
    dispenser.add(jsonEncode({
      'event_type': 'identify',
      'role': 'dispenser',
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': 'dispenser_test_client',
      'username': 'dispenser_unit_1',
    }));

    final identified = await dispenserMsgs.stream
        .firstWhere((m) => m['event_type'] == 'identified')
        .timeout(const Duration(seconds: 5));
    expect(identified['event_type'], equals('identified'));

    // Server simulates pushing 300 stock items
    final socketId = server.getConnectedClients().first['socketId'].toString();
    int pushed = 0;
    for (int i = 0; i < 300; i++) {
      final item = {
        'id': 'med_panadol_$i',
        'name': 'Panadol 500mg Batch $i',
        'quantity': 100 + i,
        'branchId': 'karachi',
      };
      server.sendToSocket(socketId, jsonEncode({
        'event_type': 'save_stock_item',
        'branchId': 'karachi',
        'data': item,
        '_serverPush': true,
        'isCatchUp': true,
        '_isReplay': true,
      }));
      pushed++;
    }

    expect(pushed, equals(300));

    // Send a ping while stream is receiving frames
    dispenser.add(jsonEncode({
      'event_type': 'ping',
      'type': 'ping',
      '_timestamp': DateTime.now().millisecondsSinceEpoch,
    }));

    final pongReceived = await dispenserMsgs.stream
        .firstWhere((m) => m['event_type'] == 'pong' || m['type'] == 'pong')
        .timeout(const Duration(seconds: 5));

    expect(pongReceived['event_type'] == 'pong' || pongReceived['type'] == 'pong', isTrue);
    expect(dispenser.readyState, equals(WebSocket.open));

    await dispenser.close();
  });

  test('VIRTUAL AUDIT: Test disconnect recovery and immediate reconnection', () async {
    // 1. Initial connection
    var client = await WebSocket.connect('ws://127.0.0.1:$testPort');
    final msgs = StreamController<Map<String, dynamic>>.broadcast();
    client.listen((d) {
      if (d is String) {
        try {
          msgs.add(jsonDecode(d));
        } catch (_) {}
      }
    });

    client.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': 'doctor_recon_test',
    }));

    var ident = await msgs.stream.firstWhere((m) => m['event_type'] == 'identified').timeout(const Duration(seconds: 5));
    expect(ident['role'], equals('doctor'));

    // 2. Abrupt disconnect (simulating router drop)
    await client.close();
    await Future.delayed(const Duration(milliseconds: 100));

    // 3. Reconnect
    client = await WebSocket.connect('ws://127.0.0.1:$testPort');
    final msgs2 = StreamController<Map<String, dynamic>>.broadcast();
    client.listen((d) {
      if (d is String) {
        try {
          msgs2.add(jsonDecode(d));
        } catch (_) {}
      }
    });

    client.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': 'doctor_recon_test',
    }));

    ident = await msgs2.stream.firstWhere((m) => m['event_type'] == 'identified').timeout(const Duration(seconds: 5));
    expect(ident['role'], equals('doctor'));
    expect(client.readyState, equals(WebSocket.open));

    await client.close();
  });
}
