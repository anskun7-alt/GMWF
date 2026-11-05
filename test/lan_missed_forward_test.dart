import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:hive/hive.dart';

/// Token 01 issued while the doctor's desk is (re)connecting must reach the doctor as soon as
/// it connects, not at the next 5-minute catch-up (after 02-04 had been prescribed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const port = 19891;
  late LanServer server;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lan_missed_');
    Hive.init(dir.path);
    await Hive.openBox('realtime_outbox');
    server = LanServer(port: port)..persistenceReady = true;
    await server.start('127.0.0.1');
  });

  tearDownAll(() async {
    await server.stop();
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<(WebSocket, Stream<Map<String, dynamic>>)> connect(String role, String clientId) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port');
    final ctrl = StreamController<Map<String, dynamic>>.broadcast();
    ws.listen((d) {
      if (d is String) {
        final m = jsonDecode(d);
        if (m is Map<String, dynamic>) ctrl.add(m);
      }
    });
    final identified = ctrl.stream.firstWhere((m) => m['event_type'] == 'identified');
    ws.add(jsonEncode({
      'event_type': 'identify',
      'role': role,
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': clientId,
      'username': role,
    }));
    await identified.timeout(const Duration(seconds: 5));
    return (ws, ctrl.stream);
  }

  Map<String, dynamic> token(String id, String serial) => {
        'event_type': 'save_entry',
        '_messageId': id,
        '_clientId': 'rec-1',
        'branchId': 'karachi',
        'data': {'serial': serial, 'branchId': 'karachi', 'patientName': 'Patient $serial'},
      };

  test('a token sent while the doctor was away is forwarded the moment the doctor connects', () async {
    final (rec, recStream) = await connect('receptionist', 'rec-1');

    // Doctor not connected yet: token 01 reaches nobody.
    final ack = recStream.firstWhere((m) => m['event_type'] == 'message_ack' && m['messageId'] == 'tok-01');
    rec.add(jsonEncode(token('tok-01', '311026M-HAJI-001')));
    await ack.timeout(const Duration(seconds: 5));

    // The doctor connects: it must get 01 without waiting for a catch-up timer.
    final docWs = await WebSocket.connect('ws://127.0.0.1:$port');
    final docCtrl = StreamController<Map<String, dynamic>>.broadcast();
    docWs.listen((d) {
      if (d is String) docCtrl.add(jsonDecode(d) as Map<String, dynamic>);
    });
    final got01 = docCtrl.stream.firstWhere(
        (m) => m['event_type'] == 'save_entry' && (m['data'] as Map)['serial'] == '311026M-HAJI-001');
    docWs.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': 'doc-1',
      'username': 'doctor',
    }));
    final m = await got01.timeout(const Duration(seconds: 3));
    expect(m.containsKey('isCatchUp'), isFalse); // a first delivery, not a replay

    // Token 02 afterwards goes live as before.
    final got02 = docCtrl.stream.firstWhere(
        (m) => m['event_type'] == 'save_entry' && (m['data'] as Map)['serial'] == '311026M-HAJI-002');
    rec.add(jsonEncode(token('tok-02', '311026M-HAJI-002')));
    await got02.timeout(const Duration(seconds: 3));

    // Doctor drops (Wi-Fi) and comes back: what it was sent in the last 2 minutes is sent
    // again as a catch-up copy, in case it went into a dead socket.
    await docWs.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final (doc2, doc2Stream) = await (() async {
      final ws = await WebSocket.connect('ws://127.0.0.1:$port');
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      ws.listen((d) {
        if (d is String) ctrl.add(jsonDecode(d) as Map<String, dynamic>);
      });
      return (ws, ctrl.stream);
    })();
    final again02 = doc2Stream.firstWhere(
        (m) => m['event_type'] == 'save_entry' && (m['data'] as Map)['serial'] == '311026M-HAJI-002');
    doc2.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': 3,
      '_clientId': 'doc-1',
      'username': 'doctor',
    }));
    final copy = await again02.timeout(const Duration(seconds: 3));
    expect(copy['isCatchUp'], isTrue);

    await rec.close();
    await doc2.close();
  });
}
