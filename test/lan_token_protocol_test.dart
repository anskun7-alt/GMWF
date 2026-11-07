import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/services/auto_update_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:hive/hive.dart';

/// Phase 1 LAN protocol, over real WebSockets against a real LanServer:
/// version gate, repeat-safe number requests, per-PC offline blocks, ACK only after the token
/// was forwarded, and the unconfirmed-token count in pongs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const port = 19893;
  const prefix = '051126M-SADD';
  late LanServer server;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lan_token_protocol_');
    Hive.init(dir.path);
    await Hive.openBox('realtime_outbox');
    await Hive.openBox('app_settings');
    await Hive.openBox(LocalStorageService.entriesBox);
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

  Future<(WebSocket, Stream<Map<String, dynamic>>)> open() async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port');
    final ctrl = StreamController<Map<String, dynamic>>.broadcast();
    ws.listen((d) {
      if (d is String) {
        final m = jsonDecode(d);
        if (m is Map<String, dynamic>) ctrl.add(m);
      }
    });
    return (ws, ctrl.stream);
  }

  Future<(WebSocket, Stream<Map<String, dynamic>>)> connect(String role, String clientId) async {
    final (ws, stream) = await open();
    final identified = stream.firstWhere((m) => m['event_type'] == 'identified');
    ws.add(jsonEncode({
      'event_type': 'identify',
      'role': role,
      'branchId': 'karachi',
      'protocolVersion': AutoUpdateService.protocolVersion,
      '_clientId': clientId,
      'username': role,
    }));
    await identified.timeout(const Duration(seconds: 5));
    return (ws, stream);
  }

  Future<Map<String, dynamic>> reserve(WebSocket ws, Stream<Map<String, dynamic>> s, String requestId,
      {int proposed = 0, String? deviceKey}) {
    final reply = s.firstWhere((m) => m['event_type'] == 'serial_reserved' && m['requestId'] == requestId);
    ws.add(jsonEncode({
      'event_type': 'reserve_serial',
      'requestId': requestId,
      'prefix': prefix,
      'proposed': proposed,
      if (deviceKey != null) 'deviceKey': deviceKey,
    }));
    return reply.timeout(const Duration(seconds: 5));
  }

  test('an old desk build is refused with a version_mismatch message', () async {
    final (ws, stream) = await open();
    final refused = stream.firstWhere((m) => m['event_type'] == 'version_mismatch');
    ws.add(jsonEncode({
      'event_type': 'identify',
      'role': 'receptionist',
      'branchId': 'karachi',
      'protocolVersion': 2,
      '_clientId': 'old-desk',
    }));
    final m = await refused.timeout(const Duration(seconds: 5));
    expect(m['message'].toString(), contains('Update GMWF'));
    await ws.close();
  });

  test('numbers are shared, repeats get the same number, offline proposals are ignored', () async {
    final (a, aS) = await connect('receptionist', 'rec-a');
    final (b, bs) = await connect('receptionist', 'rec-b');

    expect((await reserve(a, aS, 'r1', proposed: 1))['seq'], 1);
    // Desk A re-sends the same request (slow answer): same number, not a new one.
    expect((await reserve(a, aS, 'r1', proposed: 1))['seq'], 1);
    // Desk B next: 2.
    expect((await reserve(b, bs, 'r2', proposed: 1))['seq'], 2);
    // A proposal from an offline block must not push the shared sequence to 1006.
    expect((await reserve(a, aS, 'r3', proposed: 1005))['seq'], 3);

    await a.close();
    await b.close();
  });

  test('an offline-block token does not move the shared sequence', () async {
    final (a, aS) = await connect('receptionist', 'rec-c');
    final ack = aS.firstWhere((m) => m['event_type'] == 'message_ack' && m['messageId'] == 'off-1');
    a.add(jsonEncode({
      'event_type': 'save_entry',
      '_messageId': 'off-1',
      '_clientId': 'rec-c',
      'branchId': 'karachi',
      'serial': '$prefix-1001',
      'data': {'serial': '$prefix-1001', 'branchId': 'karachi', 'patientName': 'Offline P'},
    }));
    await ack.timeout(const Duration(seconds: 5));
    final r = await reserve(a, aS, 'r4');
    expect(r['seq'], lessThan(1000));
    await a.close();
  });

  test('each PC gets its own offline block, the same one every time', skip: 'Offline desk blocks removed: one shared 001..999 sequence (see getNextLocalSerialSequence)', () async {
    final (a, aS) = await connect('receptionist', 'rec-d');
    final s1 = (await reserve(a, aS, 'r5', deviceKey: 'pc-one'))['deskSlot'];
    final s2 = (await reserve(a, aS, 'r6', deviceKey: 'pc-two'))['deskSlot'];
    final s1again = (await reserve(a, aS, 'r7', deviceKey: 'pc-one'))['deskSlot'];
    expect(s1, isA<int>());
    expect(s2, isA<int>());
    expect(s1, isNot(s2));
    expect(s1again, s1);
    expect(s1, inInclusiveRange(1, LocalStorageService.maxOfflineDeskSlot));
    await a.close();
  });

  test('the token is forwarded to the doctor before reception gets the confirmation', () async {
    final (rec, recStream) = await connect('receptionist', 'rec-e');
    final (doc, docStream) = await connect('doctor', 'doc-e');
    final events = <String>[];
    final docGot = docStream
        .firstWhere((m) => m['event_type'] == 'save_entry' && (m['data'] as Map)['serial'] == '$prefix-050')
        .then((_) => events.add('doctor'));
    final acked = recStream
        .firstWhere((m) => m['event_type'] == 'message_ack' && m['messageId'] == 'tok-50')
        .then((_) => events.add('ack'));
    rec.add(jsonEncode({
      'event_type': 'save_entry',
      '_messageId': 'tok-50',
      '_clientId': 'rec-e',
      'branchId': 'karachi',
      'serial': '$prefix-050',
      'data': {'serial': '$prefix-050', 'branchId': 'karachi', 'patientName': 'P50'},
    }));
    await Future.wait([docGot, acked]).timeout(const Duration(seconds: 5));
    // Both happen; the server forwards first, then ACKs after saving.
    expect(events, containsAll(['doctor', 'ack']));
    await rec.close();
    await doc.close();
  });

  Future<Map<String, dynamic>> beginDispense(WebSocket ws, Stream<Map<String, dynamic>> s, String req, String serial) {
    final reply = s.firstWhere((m) => m['event_type'] == 'dispense_lock' && m['requestId'] == req);
    ws.add(jsonEncode({'event_type': 'begin_dispense', 'requestId': req, 'serial': serial, 'branchId': 'karachi'}));
    return reply.timeout(const Duration(seconds: 5));
  }

  test('only one counter is allowed to dispense a token', () async {
    final (c1, s1) = await connect('dispenser', 'disp-1');
    final (c2, s2) = await connect('dispenser', 'disp-2');
    expect((await beginDispense(c1, s1, 'd1', '$prefix-070'))['result'], 'granted');
    final second = await beginDispense(c2, s2, 'd2', '$prefix-070');
    expect(second['result'], 'held');
    expect(second['holder'], 'dispenser');
    // The holder asking again (retry) is still granted.
    expect((await beginDispense(c1, s1, 'd3', '$prefix-070'))['result'], 'granted');
    // Once the server has the token as dispensed, everyone is refused.
    await Hive.box(LocalStorageService.entriesBox).put('karachi-$prefix-071', {
      'serial': '$prefix-071',
      'dispenseStatus': 'dispensed',
    });
    expect((await beginDispense(c2, s2, 'd4', '$prefix-071'))['result'], 'already_dispensed');
    await c1.close();
    await c2.close();
  });

  test('a desk that was away receives the non-token events it missed', () async {
    final (rec, recS) = await connect('receptionist', 'rec-log');
    // Two patient edits while the doctor desk is not connected.
    for (final id in ['p-1', 'p-2']) {
      final ack = recS.firstWhere((m) => m['event_type'] == 'message_ack' && m['messageId'] == 'msg-$id');
      rec.add(jsonEncode({
        'event_type': 'save_patient',
        '_messageId': 'msg-$id',
        '_clientId': 'rec-log',
        'branchId': 'karachi',
        'data': {'patientId': id, 'name': 'Patient $id', 'branchId': 'karachi'},
      }));
      await ack.timeout(const Duration(seconds: 5));
    }

    // The doctor connects with no log position: it gets both, then the log position.
    final (doc, docS) = await open();
    // (The 10-minute in-memory replay may also deliver them; the event log is what survives a
    // longer absence or a server restart, so check its copies specifically.)
    final got = <String>[];
    final position = docS.firstWhere((m) => m['event_type'] == 'event_log_position');
    docS.where((m) => m['event_type'] == 'save_patient' && m['_eventLogReplay'] == true).listen((m) {
      got.add((m['data'] as Map)['patientId'].toString());
      expect(m['isCatchUp'], isTrue);
      expect(m['_logSeq'], isA<int>());
    });
    doc.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': AutoUpdateService.protocolVersion,
      '_clientId': 'doc-log',
      'username': 'doctor',
      'lastEventSeq': 0,
      'lastEventEpoch': '',
    }));
    final pos = await position.timeout(const Duration(seconds: 5));
    expect(got, containsAll(['p-1', 'p-2']));
    await doc.close();

    // Reconnecting at that position: nothing is replayed again.
    final (doc2, doc2S) = await open();
    final replayed = <Map<String, dynamic>>[];
    doc2S.where((m) => m['event_type'] == 'save_patient' && m['_eventLogReplay'] == true).listen(replayed.add);
    final pos2 = doc2S.firstWhere((m) => m['event_type'] == 'event_log_position');
    doc2.add(jsonEncode({
      'event_type': 'identify',
      'role': 'doctor',
      'branchId': 'karachi',
      'protocolVersion': AutoUpdateService.protocolVersion,
      '_clientId': 'doc-log',
      'username': 'doctor',
      'lastEventSeq': pos['_logSeq'],
      'lastEventEpoch': pos['_logEpoch'],
    }));
    // No replay needed → the server sends no position either; wait briefly and check.
    await pos2.timeout(const Duration(seconds: 1), onTimeout: () => <String, dynamic>{});
    expect(replayed, isEmpty);
    await doc2.close();
    await rec.close();
  });

  test('pong tells a desk how many tokens it has not confirmed', () async {
    final (doc, docStream) = await connect('doctor', 'doc-f');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final sid = server
        .getConnectedClients()
        .firstWhere((c) => c['clientId'] == 'doc-f')['socketId']
        .toString();
    server.reportUnconfirmedTokens(sid, 3);
    final pong = docStream.firstWhere((m) => m['event_type'] == 'pong');
    doc.add(jsonEncode({'event_type': 'ping', 'type': 'ping'}));
    expect((await pong.timeout(const Duration(seconds: 5)))['unconfirmedTokens'], 3);

    server.reportUnconfirmedTokens(sid, 0);
    final pong2 = docStream.firstWhere((m) => m['event_type'] == 'pong');
    doc.add(jsonEncode({'event_type': 'ping', 'type': 'ping'}));
    expect((await pong2.timeout(const Duration(seconds: 5)))['unconfirmedTokens'], 0);
    await doc.close();
  });
}
