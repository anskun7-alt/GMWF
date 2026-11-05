// lib/realtime/lan_server.dart
//
// CHANGES IN THIS VERSION:
//   1. _handleMessage() now extracts 'username' from identify payload
//      and stores it in _clientInfo.
//   2. getConnectedClients() includes username in returned map.
//   3. onClientConnected callback info map includes username.
//   4. [DEDUP] Server-side _messageId deduplication with 24-hour TTL.
//      Duplicate messages receive an immediate ACK but are NOT processed
//      or broadcast again — eliminates double-processing on reconnect.
//   5. [DEDUP] _purgeOldMessageIds() runs every 10 minutes to keep memory bounded.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async';

import '../config/constants.dart';
import '../services/camp_session_service.dart';
import '../services/local_storage_service.dart';
import '../services/python_runner_service.dart';
import '../utils/network_utils.dart';
import '../services/auto_update_service.dart';

class LanServer {
  static bool _isRunning = false;
  static bool get isRunning => _isRunning;

  /// Real traffic counters (since process start) used by the server dashboard.
  /// "Out" counts every payload delivered to a device; "in" every message received from one.
  static int trafficMsgsIn = 0;
  static int trafficMsgsOut = 0;
  static int trafficBytesIn = 0;
  static int trafficBytesOut = 0;

  HttpServer? _server;

  final List<WebSocket>                      _clients    = [];
  final Map<String, WebSocket>               _socketById = {};
  final Map<WebSocket, Map<String, dynamic>> _clientInfo = {};
  final Map<WebSocket, String>               _clientIps  = {};

  final int port;
  final String? authToken;

  int _messagesReceived = 0;
  int _messagesSent     = 0;

  RawDatagramSocket? _udpSocket;
  Timer? _udpTimer;

  // ── [DEDUP] Processed message IDs with timestamps for 24-hour TTL ──────────
  // LinkedHashMap preserves insertion order so oldest entries can be purged fast.
  final LinkedHashMap<String, DateTime> _processedMessageIds =
      LinkedHashMap<String, DateTime>();
  static const _dedupTtl       = Duration(hours: 24);
  static const _dedupMaxSize   = 50000; // hard cap to prevent unbounded growth
  Timer? _dedupPurgeTimer;

  /// Messages being saved right now. A resend that arrives meanwhile is ignored without an
  /// ACK: if the save fails, the desk still holds the message and sends it again.
  final Set<String> _inFlightMessageIds = {};

  /// Messages already forwarded, with the desks (clientIds) each one reached. A resend or
  /// duplicate of one goes only to desks that have not had it: forwarding again to all of them
  /// would apply it twice on their screens, and never forwarding again left a token that was
  /// issued while the doctor's desk was reconnecting undelivered until the 5-minute catch-up
  /// (token 01 showing up after 02-04 had been prescribed and dispensed).
  final LinkedHashMap<String, ({Map<String, dynamic> message, Set<String> reached, DateTime at})> _routed =
      LinkedHashMap();
  static const int _maxRoutedTracked = 3000;

  /// Save failures per message id. A message that keeps failing is parked in
  /// [unsavedMessagesBox] and ACKed after [_maxSaveFailures], so it does not loop forever.
  final Map<String, int> _saveFailures = {};
  static const int _maxSaveFailures = 5;
  static const String unsavedMessagesBox = 'lan_unsaved_messages';

  /// Set by ServerSyncManager once its handler saves incoming messages (to Hive and the cloud
  /// queue). Until then data messages are not ACKed or processed: desks reconnect within
  /// seconds of a server restart, and messages ACKed before the handler existed were lost.
  bool persistenceReady = false;

  // ── [FIX 5] In-memory & disk persisted record version arbiter map ──────────
  final Map<String, int> _recordVersionMap = {};

  // ── Persistent event log (non-token events) ──────────────────────────────────
  // Tokens and stock have their own catch-ups. Everything else a desk can miss while it is
  // off or reconnecting — patient edits, deletes, restrictions lifted, requests approved,
  // users, attendance — used to reach it only through the 10-minute in-memory replay or the
  // 30-minute full resync. Each such event now gets a sequence number and is kept on disk for
  // 7 days; a desk reports the last number it applied when it connects and receives exactly
  // what it missed (also after a server restart). '_logEpoch' identifies this log, so a desk
  // that knew another (reinstalled) server's log starts over instead of skipping events.
  static const String eventLogBox = 'lan_event_log';
  static const Duration _eventLogKeep = Duration(days: 7);
  static const int _maxReplay = 3000;
  Box? _eventLog;
  int _eventSeq = 0;
  String _logEpoch = '';

  static bool isLoggedEventType(String? t) {
    if (t == null || t.isEmpty) return false;
    const tokenOrStock = {
      'save_entry', 'token_created', 'save_prescription', 'prescription_created',
      'dispense_completed', 'update_serial_status', 'save_stock_item', 'delete_stock_item',
      'medicine_registered', 'add_stock', 'add_proforma_stock', 'save_dispensary_charge',
      'save_dispensary_record',
    };
    if (tokenOrStock.contains(t) || t.startsWith('stress_')) return false;
    return t.startsWith('save_') || t.startsWith('delete_') || t.startsWith('request_') ||
        t.startsWith('token_exception') || t.startsWith('token_reversal') ||
        t.startsWith('approve_') || t.startsWith('reject_') || t.startsWith('migrate_') ||
        t.startsWith('restriction') || t.startsWith('workflow_') || t.startsWith('offboard_');
  }

  Future<void> _openEventLog() async {
    try {
      final box = await LocalStorageService.ensureBoxOpen(eventLogBox);
      _eventLog = box;
      var epoch = box.get('_epoch')?.toString() ?? '';
      if (epoch.isEmpty) {
        epoch = '${DateTime.now().microsecondsSinceEpoch}';
        await box.put('_epoch', epoch);
      }
      _logEpoch = epoch;
      final cutoff = DateTime.now().subtract(_eventLogKeep).millisecondsSinceEpoch;
      final old = <dynamic>[];
      var maxSeq = 0;
      for (final k in box.keys) {
        if (k is! int) continue;
        if (k > maxSeq) maxSeq = k;
        final v = box.get(k);
        if (v is Map && (v['at'] as num? ?? 0) < cutoff) old.add(k);
      }
      if (old.isNotEmpty) await box.deleteAll(old);
      _eventSeq = maxSeq;
    } catch (e) {
      print('[LanServer] Event log unavailable: $e');
    }
  }

  /// Records [enhanced] in the log and stamps it with its sequence number (before forwarding).
  void _logEvent(Map<String, dynamic> enhanced, String? eventType, String branch) {
    final box = _eventLog;
    if (box == null || !box.isOpen || !isLoggedEventType(eventType)) return;
    final seq = ++_eventSeq;
    enhanced['_logSeq'] = seq;
    enhanced['_logEpoch'] = _logEpoch;
    final copy = Map<String, dynamic>.from(enhanced)..remove('_socketId');
    try {
      box.put(seq, {
        'at': DateTime.now().millisecondsSinceEpoch,
        'branch': branch,
        'from': enhanced['_clientId']?.toString() ?? '',
        'msg': jsonEncode(copy),
      });
    } catch (_) {}
  }

  /// Sends a (re)connecting desk every logged event after [lastSeq] for its branch.
  Future<void> _replayEventLog(WebSocket socket, int lastSeq, String lastEpoch) async {
    final box = _eventLog;
    if (box == null || !box.isOpen) return;
    final info = _clientInfo[socket];
    if (info == null) return;
    final from = lastEpoch == _logEpoch ? lastSeq : 0;
    if (from >= _eventSeq) return;
    final myBranch = LocalStorageService.sanitizeBranchId((info['branchId'] ?? '').toString(), fallback: '');
    final me = (info['clientId'] ?? '').toString();
    final keys = box.keys.whereType<int>().where((k) => k > from).toList()..sort();
    final start = keys.length > _maxReplay ? keys.length - _maxReplay : 0;
    var sent = 0;
    for (var i = start; i < keys.length; i++) {
      if (socket.readyState != WebSocket.open) return;
      final v = box.get(keys[i]);
      if (v is! Map) continue;
      final b = LocalStorageService.sanitizeBranchId((v['branch'] ?? '').toString(), fallback: '');
      if (b.isNotEmpty && b != 'all' && myBranch.isNotEmpty && b != myBranch) continue;
      if (me.isNotEmpty && v['from'] == me) continue; // its own event
      try {
        final m = jsonDecode(v['msg'].toString());
        if (m is Map<String, dynamic>) {
          m['isCatchUp'] = true;
          m['_eventLogReplay'] = true;
          socket.add(jsonEncode(m));
          countTraffic('out event-log replay');
          sent++;
        }
      } catch (_) {}
      if (sent % 100 == 0) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Tell the desk where the log stands, so it can record it even if nothing was for it.
    try {
      socket.add(jsonEncode({'event_type': 'event_log_position', '_logSeq': _eventSeq, '_logEpoch': _logEpoch}));
    } catch (_) {}
    if (sent > 0) print('[LanServer] 📜 Replayed $sent missed event(s) to ${info['username']} (after #$from)');
  }

  /// Client -> server control messages that no other device needs (see _handleMessage).
  static const Set<String> _serverOnlyEventTypes = {
    'ack_serials', 'ack_stock_items', 'message_ack', 'request_catch_up', 'request_full_lan_sync',
  };

  // ── Token number issuer ───────────────────────────────────────────────────
  // Each desk used to number tokens from its own records (highest it had seen + 1). Two desks
  // issuing before they had received each other's token gave two patients the same number,
  // and their records then merged: the dispenser saw one patient's medicines for the other.
  // Desks now ask here first, so numbers are handed out one at a time for the whole LAN.

  /// Highest sequence issued per serial prefix ('301026M-HAJI').
  final Map<String, int> _lastIssuedSeq = {};

  /// This server's branch, added to the UDP beacon ("…I_AM:<ip>:<port>:<branch>"; older
  /// desks read only ip:port), so a desk never joins another branch's server on a shared LAN.
  String? branchId;
  /// requestId → number already given, so a desk's retry gets the same number (insertion
  /// ordered; oldest dropped past 2000).
  final Map<String, int> _reservedByRequest = {};

  /// socketId → today's tokens that desk has not confirmed (set by the server's catch-up pass
  /// every few seconds, sent back with each pong).
  final Map<String, int> _unconfirmedBySocket = {};
  void reportUnconfirmedTokens(String socketId, int count) {
    _unconfirmedBySocket[socketId] = count;
    if (_unconfirmedBySocket.length > 200) _unconfirmedBySocket.remove(_unconfirmedBySocket.keys.first);
  }

  static final RegExp _serialParts = RegExp(r'^(\d{6}[A-Z]?-[A-Z0-9_]+)-(\d{1,4})$');

  void _noteIssuedSerial(String? serial) {
    final m = _serialParts.firstMatch((serial ?? '').trim().toUpperCase());
    if (m == null) return;
    final prefix = m.group(1)!;
    final seq = int.parse(m.group(2)!);
    // A desk's offline-block number (1001+) is not part of the shared sequence; counting it
    // would make every desk jump to 1002, 1003 ... and into that desk's offline block.
    if (LocalStorageService.isOfflineBandSeq(seq)) return;
    if (seq > (_lastIssuedSeq[prefix] ?? 0)) _lastIssuedSeq[prefix] = seq;
  }

  /// Gives each desk PC its own offline token block (1..9), remembered on this server PC so a
  /// desk keeps its slot across restarts. When all 9 are taken, the slot of the desk not seen
  /// for the longest time is reused.
  int _deskSlotFor(String deviceKey) {
    if (deviceKey.isEmpty || !Hive.isBoxOpen('app_settings')) return 0;
    try {
      final box = Hive.box('app_settings');
      final raw = box.get('lan_offline_desk_slots');
      final slots = <String, Map<String, dynamic>>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          if (v is Map) slots[k.toString()] = Map<String, dynamic>.from(v);
        });
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      var mine = slots[deviceKey];
      if (mine == null) {
        final used = slots.values.map((v) => (v['slot'] as num?)?.toInt() ?? 0).toSet();
        int slot = 0;
        for (var s = 1; s <= LocalStorageService.maxOfflineDeskSlot; s++) {
          if (!used.contains(s)) { slot = s; break; }
        }
        if (slot == 0) {
          // All taken: take over the slot of the desk seen longest ago.
          final oldest = slots.entries.reduce((a, b) =>
              ((a.value['seen'] as num?) ?? 0) <= ((b.value['seen'] as num?) ?? 0) ? a : b);
          slot = (oldest.value['slot'] as num?)?.toInt() ?? 0;
          slots.remove(oldest.key);
        }
        mine = {'slot': slot};
      }
      final lastSeen = (mine['seen'] as num?)?.toInt() ?? 0;
      mine['seen'] = now;
      slots[deviceKey] = mine;
      // Write at most every 10 min per desk (a new desk is written at once).
      if (now - lastSeen > 600000) box.put('lan_offline_desk_slots', slots);
      return (mine['slot'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// First request for a prefix since this server started: also count the tokens already
  /// stored on this PC, so a restart never hands out a number again.
  void _seedIssuedSeq(String prefix) {
    if (_lastIssuedSeq.containsKey(prefix)) return;
    _lastIssuedSeq[prefix] = 0;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) return;
      for (final v in Hive.box(LocalStorageService.entriesBox).values) {
        if (v is Map) _noteIssuedSerial(v['serial']?.toString());
      }
    } catch (_) {}
  }

  void _reserveSerial(WebSocket socket, Map<String, dynamic> data) {
    final prefix = (data['prefix'] ?? '').toString().trim().toUpperCase();
    final requestId = data['requestId']?.toString();
    if (prefix.isEmpty || requestId == null || requestId.isEmpty) return;
    _seedIssuedSeq(prefix);
    // A desk re-sends the same request while it waits; answer it with the same number.
    final int seq;
    final repeated = _reservedByRequest[requestId];
    if (repeated != null) {
      seq = repeated;
    } else {
      var proposed = (data['proposed'] as num?)?.toInt() ?? 0;
      // An older desk build may propose an offset number (e.g. 501) or an offline-block one;
      // only a shared-sequence proposal may move the shared counter forward.
      if (LocalStorageService.isOfflineBandSeq(proposed)) proposed = 0;
      final last = _lastIssuedSeq[prefix] ?? 0;
      seq = proposed > last ? proposed : last + 1;
      _lastIssuedSeq[prefix] = seq;
      _reservedByRequest[requestId] = seq;
      if (_reservedByRequest.length > 2000) {
        _reservedByRequest.remove(_reservedByRequest.keys.first);
      }
    }
    final deskSlot = _deskSlotFor((data['deviceKey'] ?? '').toString());
    try {
      socket.add(jsonEncode({
        'event_type': 'serial_reserved',
        'requestId':  requestId,
        'prefix':     prefix,
        'seq':        seq,
        if (deskSlot > 0) 'deskSlot': deskSlot,
      }));
    } catch (_) {}
  }

  // ── Dispense approval: one counter per token ──────────────────────────────
  // Two counters clicking "Dispense" within a second both passed their own local check (each
  // PC reads its own copy) and both dispensed and deducted stock. Now the dispensing desk asks
  // this server first; the server is the single place that decides. A lock lasts until the
  // dispense_completed arrives (the token is then dispensed and every later request is refused)
  // or 90 s pass (the desk gave up or crashed).
  final Map<String, ({String holder, String holderName, DateTime at})> _dispenseLocks = {};
  static const Duration _dispenseLockTtl = Duration(seconds: 90);

  static String _dispenseKey(String serial) {
    var s = serial.trim().toUpperCase();
    final m = RegExp(r'(\d{6}[A-Z]?-[A-Z0-9_]+-\d{1,4})$').firstMatch(s);
    if (m != null) s = m.group(1)!;
    return s;
  }

  bool _isDispensedHere(String branch, String serial) {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) return false;
      final box = Hive.box(LocalStorageService.entriesBox);
      final b = branch.toLowerCase().trim();
      for (final k in ['$b-$serial', '${LocalStorageService.sanitizeBranchId(b)}-$serial', serial]) {
        final v = box.get(k);
        if (v is Map && (v['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') return true;
      }
    } catch (_) {}
    return false;
  }

  void _beginDispense(WebSocket socket, String socketId, Map<String, dynamic> data) {
    final requestId = data['requestId']?.toString();
    final serialRaw = (data['serial'] ?? '').toString();
    if (requestId == null || requestId.isEmpty || serialRaw.trim().isEmpty) return;
    final key = _dispenseKey(serialRaw);
    final branch = (data['branchId'] ?? _clientInfo[socket]?['branchId'] ?? '').toString();
    final me = (_clientInfo[socket]?['clientId'] ?? data['_clientId'] ?? socketId).toString();
    final myName = (_clientInfo[socket]?['username'] ?? '').toString();
    final now = DateTime.now();

    String result;
    String? holderName;
    if (_isDispensedHere(branch, key)) {
      result = 'already_dispensed';
    } else {
      final held = _dispenseLocks[key];
      if (held == null || held.holder == me || now.difference(held.at) > _dispenseLockTtl) {
        _dispenseLocks[key] = (holder: me, holderName: myName, at: now);
        result = 'granted';
      } else {
        result = 'held';
        holderName = held.holderName;
      }
    }
    if (_dispenseLocks.length > 500) {
      _dispenseLocks.removeWhere((_, v) => now.difference(v.at) > _dispenseLockTtl);
    }
    try {
      socket.add(jsonEncode({
        'event_type': 'dispense_lock',
        'requestId': requestId,
        'serial': key,
        'result': result,
        if (holderName != null && holderName.isNotEmpty) 'holder': holderName,
      }));
    } catch (_) {}
  }

  // ── [LIVENESS] Track last active timestamp for each socket to evict silent/dead sockets ──
  final Map<WebSocket, DateTime> _lastActiveTimes = {};
  Timer? _heartbeatTimer;

  // Staged messages received before client completed 'identify' handshake
  final Map<WebSocket, List<String>> _stagedPreHandshakeMessages = {};
  String? _serverIp;
  String? get serverIp => _serverIp;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  Function(String socketId, Map<String, dynamic> info)? onClientConnected;
  Function(String socketId)?                             onClientDisconnected;
  Function(Map<String, dynamic>)?                        onMessageReceived;

  LanServer({this.port = AppNetwork.websocketPort, this.authToken});

  int get clientCount      => _clientInfo.length;
  int get messagesReceived => _messagesReceived;
  int get messagesSent     => _messagesSent;

  // ── Start ──────────────────────────────────────────────────────────────────
  Future<void> start(String? forcedIp) async {
    try {
      await _openEventLog();
      _server = await HttpServer.bind(
          InternetAddress.anyIPv4, port, shared: true);
      _isRunning = true;

      final ipShown = forcedIp ?? 'your-LAN-IP';
      _serverIp = ipShown;
      print('╔════════════════════════════════════════════════════════════╗');
      print('║ LAN WebSocket Server STARTED                               ║');
      print('║ Listening: 0.0.0.0:$port  (share $ipShown:$port)          ║');
      print('╚════════════════════════════════════════════════════════════╝');

      _server!.listen((HttpRequest request) async {
        // Handle preflight requests for Chrome/Edge Private Network Access (PNA)
        if (request.method == 'OPTIONS') {
          request.response
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            ..headers.add('Access-Control-Allow-Headers', 'Origin, Content-Type, Accept')
            ..headers.add('Access-Control-Allow-Private-Network', 'true')
            ..statusCode = HttpStatus.noContent
            ..close();
          return;
        }

        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            final clientIp = request.connectionInfo?.remoteAddress.address ?? '';
            final socket = await WebSocketTransformer.upgrade(request);
            _addClient(socket, clientIp);
          } catch (e) {
            print('WebSocket upgrade failed: $e');
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..write('WebSocket upgrade failed')
              ..close();
          }
        } else {
          // Serve Flutter Web static files if build/web exists, or return health check
          final pathStr = request.uri.path == '/' ? '/index.html' : request.uri.path;
          final webDir  = Directory('build/web');
          final webFile = File('${webDir.path}$pathStr');

          if (await webDir.exists() && await webFile.exists()) {
            try {
              request.response.headers
                ..add('Access-Control-Allow-Origin', '*')
                ..add('Access-Control-Allow-Private-Network', 'true')
                ..contentType = _getContentType(pathStr);
              await webFile.openRead().pipe(request.response);
              return;
            } catch (_) {}
          }

          // HTTP endpoint: return connected client details
          if (request.uri.path == '/api/clients' || request.uri.path == '/clients') {
            request.response
              ..headers.add('Access-Control-Allow-Origin', '*')
              ..headers.add('Access-Control-Allow-Private-Network', 'true')
              ..headers.contentType = ContentType.json
              ..statusCode = HttpStatus.ok
              ..write(jsonEncode({
                'serverIp': ipShown,
                'port': port,
                'clientsCount': _clientInfo.length,
                'clients': getConnectedClients(),
                'timestamp': DateTime.now().toIso8601String(),
              }))
              ..close();
            return;
          }

          // HTTP health-check — LanDiscovery._verify() looks for 'GMWF'.
          request.response
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..headers.add('Access-Control-Allow-Private-Network', 'true')
            ..statusCode = HttpStatus.ok
            ..write('GMWF LAN Token Server — ws://$ipShown:$port')
            ..close();
        }
      });

      _startUdpBroadcast(ipShown);
      _startDedupPurgeTimer();
      _startHeartbeatChecker();

      if (!kIsWeb) {
        if (!PythonRunnerService.instance.isRunning) {
          unawaited(PythonRunnerService.instance.initAutoStart().catchError((e) {
            if (kDebugMode) print('[LanServer] Auto-start Python daemon warning: $e');
            return false;
          }));
        }
      }

    } catch (e) {
      print('╔════════════════════════════════════════════════════════════╗');
      print('║ FAILED TO START LAN SERVER on port $port                   ║');
      print('║ Error: $e');
      print('╚════════════════════════════════════════════════════════════╝');
      rethrow;
    }
  }

  // ── [LIVENESS] Evict dead sockets that have gone silent ─────────────────────
  void _startHeartbeatChecker() {
    _heartbeatTimer?.cancel();
    var lastTick = DateTime.now();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now();
      // A late tick means this server's UI thread was frozen: the desks' pings from that time
      // are still queued, so silence is not evidence of a dead desk. Evict on the next tick.
      final lateTick = now.difference(lastTick) > const Duration(seconds: 20);
      lastTick = now;
      final deadSockets = <WebSocket>[];
      for (final client in List<WebSocket>.from(_clients)) {
        if (client.readyState != WebSocket.open) {
          deadSockets.add(client);
          continue;
        }
        final lastActive = _lastActiveTimes[client];
        if (lastActive != null) {
          if (now.difference(lastActive) > const Duration(seconds: 15)) {
            try {
              client.add(jsonEncode({
                'type': 'ping',
                'event_type': 'ping',
                'serverEpoch': now.millisecondsSinceEpoch,
              }));
            } catch (_) {
              deadSockets.add(client);
            }
          }
          // Desks ping every 5 s. A socket silent for 35 s is dead (cable re-plugged, desk asleep,
          // Wi-Fi drop leave it half-open) and everything forwarded into it is lost until the
          // desk reconnects and catches up — so evict it sooner than the old 60 s. A frozen
          // server tick (lateTick) still never evicts anyone.
          if (!lateTick && now.difference(lastActive) > const Duration(seconds: 35)) {
            deadSockets.add(client);
          }
        }
      }
      for (final dead in deadSockets) {
        final sid = dead.hashCode.toString();
        print('[LanServer] ⏱️ Client $sid closed/timed out — evicting');
        // dart:io rejects 1001 ("close code must be 1000 or in the range 3000-4999", seen in
        // gmwf_crash.log), so the dead socket was never closed.
        try { dead.close(4000, 'Liveness timeout'); } catch (_) {}
        _removeClient(dead);
      }
    });
  }

  // ── UDP Broadcast ──────────────────────────────────────────────────────────
  void _startUdpBroadcast(String ipShown) {
    try {
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((socket) {
        socket.broadcastEnabled = true;
        _udpSocket = socket;
        
        final b = LocalStorageService.sanitizeBranchId(branchId, fallback: '');
        final payload = utf8.encode('${AppNetwork.udpMessagePrefix}$ipShown:$port${b.isNotEmpty ? ':$b' : ''}');
        final broadcastAddr = InternetAddress('255.255.255.255');
        
        // 5 s is plenty for discovery (was 2 s, plus a duplicate beacon from the server page).
        _udpTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
          try {
            _udpSocket?.send(payload, broadcastAddr, AppNetwork.udpBroadcastPort);
            final localSubnets = await getAllLanSubnets();
            for (final sub in localSubnets) {
              try {
                _udpSocket?.send(payload, InternetAddress('$sub.255'), AppNetwork.udpBroadcastPort);
              } catch (_) {}
            }
          } catch (e) {
            if (kDebugMode) print('[LanServer] UDP send error: $e');
          }
        });
        print('[LanServer] UDP Broadcaster started for $ipShown.');
      });
    } catch (e) {
      print('[LanServer] Failed to start UDP broadcast: $e');
    }
  }

  // ── [DEDUP] Purge processed-ID map every 10 minutes ───────────────────────
  void _startDedupPurgeTimer() {
    _dedupPurgeTimer?.cancel();
    _dedupPurgeTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _purgeOldMessageIds();
    });
  }

  void _purgeOldMessageIds() {
    final cutoff = DateTime.now().subtract(_dedupTtl);
    // Remove entries older than TTL (LinkedHashMap is insertion-ordered).
    _processedMessageIds.removeWhere((_, ts) => ts.isBefore(cutoff));

    // Hard cap — remove oldest entries first if still over size limit.
    if (_processedMessageIds.length > _dedupMaxSize) {
      final overflow = _processedMessageIds.length - _dedupMaxSize;
      final keysToRemove = _processedMessageIds.keys.take(overflow).toList();
      for (final k in keysToRemove) {
        _processedMessageIds.remove(k);
      }
    }
    print('[LanServer] Dedup purge: ${_processedMessageIds.length} IDs retained');
  }

  // ── Add client ─────────────────────────────────────────────────────────────
  void _addClient(WebSocket socket, [String ipAddress = '']) {
    final socketId = socket.hashCode.toString();
    _clients.add(socket);
    _socketById[socketId] = socket;
    _lastActiveTimes[socket] = DateTime.now();
    if (ipAddress.isNotEmpty) {
      _clientIps[socket] = ipAddress;
    }

    print('╔════════════════════════════════════════════════════════════╗');
    print('║ NEW CLIENT CONNECTED  Socket: $socketId IP: ${ipAddress.isEmpty ? 'Unknown' : ipAddress} '
        'Total: ${_clients.length}');
    print('╚════════════════════════════════════════════════════════════╝');

    // Ask the new client to identify itself.
    socket.add(jsonEncode({
      'event_type': 'identify_request',
      'timestamp':  DateTime.now().toIso8601String(),
      'message':    'Please identify your role and branch',
    }));

    socket.listen(
      (message) => _handleMessage(socket, socketId, message),
      onDone:  () => _removeClient(socket),
      onError: (_) => _removeClient(socket),
    );
  }

  // ── Stress-test support (used by StressTestEngine) ───────────────────────────
  /// Set by the engine while a test runs; receives every `stress_*` message from a device.
  void Function(String socketId, Map<String, dynamic> message)? onStressMessage;

  /// Identified, open client connections right now.
  List<Map<String, dynamic>> stressClientSnapshot() {
    final out = <Map<String, dynamic>>[];
    _clientInfo.forEach((ws, info) {
      if (info['identified'] != true || ws.readyState != WebSocket.open) return;
      out.add({
        'socketId': ws.hashCode.toString(),
        'role': info['role'],
        'username': info['username'],
        'clientId': info['clientId'],
        'ip': info['ipAddress'],
        'branchId': info['branchId'],
      });
    });
    return out;
  }

  // ── Handle message ─────────────────────────────────────────────────────────
  void _handleMessage(WebSocket socket, String socketId, dynamic message) {
    _lastActiveTimes[socket] = DateTime.now();
    if (message is! String) return;
    trafficMsgsIn++;
    trafficBytesIn += message.length;
    final trimmed = message.trim();

    // Ping / pong keep-alive.
    if (trimmed == 'ping' || trimmed == '{"type":"ping"}') {
      socket.add(jsonEncode({
        'type': 'pong',
        'event_type': 'pong',
        'serverEpoch': DateTime.now().millisecondsSinceEpoch,
      }));
      return;
    }
    if (trimmed == 'pong' || trimmed == '{"type":"pong"}') return;

    try {
      final data      = jsonDecode(message) as Map<String, dynamic>;
      final eventType = (data['event_type'] ?? data['type']) as String?;
      _messagesReceived++;

      // ── Ping / Pong keep-alive inside JSON payload ────────────────────────
      if (eventType == 'ping' || data['type'] == 'ping') {
        socket.add(jsonEncode({
          'type': 'pong',
          'event_type': 'pong',
          'serverEpoch': DateTime.now().millisecondsSinceEpoch,
          // Today's tokens this desk has not confirmed yet (see reportUnconfirmedTokens).
          if (_unconfirmedBySocket.containsKey(socketId))
            'unconfirmedTokens': _unconfirmedBySocket[socketId],
        }));
        return;
      }
      if (eventType == 'pong' || data['type'] == 'pong') return;

      // ── Auth handshake ───────────────────────────────────────────────────
      if (eventType == 'auth_handshake' || data['type'] == 'auth_handshake') {
        final clientToken = (data['authToken'] ?? data['token'])?.toString();
        if (authToken != null && authToken!.isNotEmpty && clientToken != authToken) {
          print('[LanServer] ❌ Auth handshake failed for client $socketId — invalid token');
          socket.add(jsonEncode({'type': 'error', 'message': 'Auth Failed: Invalid token'}));
          socket.close(4001, 'Auth Failed'); // dart:io allows 1000 or 3000-4999 only
          return;
        }
        socket.add(jsonEncode({'type': 'auth_ack', 'status': 'authenticated'}));
        return;
      }

      // Traffic breakdown (see takeTrafficSummary): which desk sends what, how often.
      final who = (_clientInfo[socket]?['username'] ?? data['_clientId'] ?? socketId).toString();
      countTraffic('in ${eventType ?? '?'} from $who');

      // ── Stress-test replies (probe / token / cleanup acks) ───────────────────
      // Handled by StressTestEngine only: never saved, routed to other devices, or queued.
      if (eventType != null && eventType.startsWith('stress_')) {
        onStressMessage?.call(socketId, data);
        return;
      }
      // A stress-test token sent back as a real event (a device still holding leftovers from
      // an interrupted test) is dropped: never saved, broadcast to other devices or queued.
      if (LocalStorageService.isStressTestMessage(data)) {
        return;
      }

      // ── Connected clients query ──────────────────────────────────────────
      if (eventType == 'get_connected_clients' || data['type'] == 'get_connected_clients') {
        socket.add(jsonEncode({
          'event_type': 'connected_clients_response',
          'serverIp': _serverIp ?? '',
          'port': port,
          'clientsCount': _clientInfo.length,
          'clients': getConnectedClients(),
          'timestamp': DateTime.now().toIso8601String(),
        }));
        return;
      }

      // ── Identify handshake ────────────────────────────────────────────────
      if (eventType == 'identify') {
        final clientProtocol = (data['protocolVersion'] as num?)?.toInt() ?? 1;
        if (clientProtocol < AutoUpdateService.minProtocolVersion) {
          print('[LanServer] ❌ Protocol version mismatch for client $socketId (protocol v$clientProtocol < ${AutoUpdateService.minProtocolVersion}). Rejecting connection.');
          socket.add(jsonEncode({
            'type': 'error',
            'event_type': 'version_mismatch',
            'code': 'VERSION_MISMATCH_REJECTED',
            'message': 'This PC runs an older GMWF version than the server '
                '(server ${AutoUpdateService.currentVersion}). Update GMWF on this PC to connect.',
          }));
          socket.close(4008, 'VERSION_MISMATCH_REJECTED'); // dart:io allows 1000 or 3000-4999 only
          return;
        }

        final role     = data['role']     as String?;
        final branchId = data['branchId'] as String?;
        final clientId = data['_clientId'] as String?;
        // Extract username sent by client; fall back to role label.
        final username = (data['username'] as String?)?.trim().isNotEmpty == true
            ? data['username'] as String
            : role ?? 'unknown';

        final socketIp = _clientIps[socket] ?? '';
        final payloadIp = (data['ipAddress'] ?? data['ip'] ?? data['deviceIp'] ?? '').toString().trim();
        final ipAddress = socketIp.isNotEmpty
            ? socketIp
            : (payloadIp.isNotEmpty ? payloadIp : '127.0.0.1');

        if (role != null && branchId != null) {
          final normRole = role.toLowerCase().trim();
          final normBranch = branchId.toLowerCase().trim();
          final platform = (data['platform'] as String?)?.trim().toLowerCase() ?? 'unknown';

          // DEDUPLICATION: Remove any stale socket ONLY if the exact same clientId is reconnecting
          final staleSockets = <WebSocket>[];
          _clientInfo.forEach((ws, oldInfo) {
            if (ws != socket) {
              final sameClient = clientId != null && clientId.isNotEmpty && oldInfo['clientId'] == clientId;
              if (sameClient) {
                staleSockets.add(ws);
              }
            }
          });

          for (final oldWs in staleSockets) {
            try { oldWs.close(); } catch (_) {}
            _clients.remove(oldWs);
            _socketById.remove(oldWs.hashCode.toString());
            _clientInfo.remove(oldWs);
            _clientIps.remove(oldWs);
            onClientDisconnected?.call(oldWs.hashCode.toString());
          }

          // Desks send identify again on the live socket whenever a screen starts the
          // connection. Treating that as a new client reset the server's per-socket "seen" set
          // and pushed the whole day again each time.
          final prevInfo = _clientInfo[socket];
          final reIdentify = prevInfo != null &&
              prevInfo['identified'] == true &&
              prevInfo['role'] == normRole &&
              prevInfo['branchId'] == normBranch;

          final info = {
            'role':        normRole,
            'branchId':    normBranch,
            'username':    username,
            'clientId':    clientId,
            'platform':    platform,
            'ipAddress':   ipAddress,
            'identified':  true,
            'connectedAt': DateTime.now().toIso8601String(),
          };
          _clientInfo[socket] = info;

          print('╔════════════════════════════════════════════════════════════╗');
          print('║ CLIENT IDENTIFIED  Socket: $socketId  IP: $ipAddress');
          print('║ Role: $role  Branch: $branchId  Username: $username');
          print('║ Total identified: ${_clientInfo.length}');
          print('╚════════════════════════════════════════════════════════════╝');

          // Confirm identification to client.
          socket.add(jsonEncode({
            'event_type':   'identified',
            'role':         role,
            'branchId':     branchId,
            'username':     username,
            'clientId':     clientId,
            'timestamp':    DateTime.now().toIso8601String(),
            'serverEpoch':  DateTime.now().millisecondsSinceEpoch,
          }));

          if (!reIdentify) onClientConnected?.call(socketId, info);
          _broadcastClientCount();
          if (!reIdentify) _forwardMissedTo(socket);
          // Every logged (non-token) event this desk missed since its last applied number.
          if (!reIdentify) {
            unawaited(_replayEventLog(
              socket,
              (data['lastEventSeq'] as num?)?.toInt() ?? 0,
              (data['lastEventEpoch'] ?? '').toString(),
            ));
          }

          // Safely drain any messages the client sent before identify was acknowledged
          final pending = _stagedPreHandshakeMessages.remove(socket);
          if (pending != null && pending.isNotEmpty) {
            print('[LanServer] 🚀 Draining ${pending.length} staged pre-handshake message(s) for client $socketId');
            for (final m in pending) {
              _handleMessage(socket, socketId, m);
            }
          }
        } else {
          print('⚠️ Incomplete identification: role=$role branch=$branchId');
        }
        return;
      }

      // ── Stage or reject unidentified clients ──────────────────────────────
      if (_clientInfo[socket]?['identified'] != true) {
        final staged = _stagedPreHandshakeMessages.putIfAbsent(socket, () => []);
        if (staged.length < 100) {
          staged.add(message);
          print('[LanServer] ⏳ Staged pre-handshake message for client $socketId (queue: ${staged.length})');
        } else {
          print('❌ Message from UNIDENTIFIED client $socketId dropped — staging buffer full');
        }
        return;
      }

      // ── Token numbers: one issuer for every desk ──────────────────────────
      if (eventType == 'reserve_serial') {
        _reserveSerial(socket, data);
        return;
      }
      if (eventType == 'begin_dispense') {
        _beginDispense(socket, socketId, data);
        return;
      }
      if (eventType == 'end_dispense') {
        final k = _dispenseKey((data['serial'] ?? '').toString());
        final me = (_clientInfo[socket]?['clientId'] ?? data['_clientId'] ?? socketId).toString();
        if (_dispenseLocks[k]?.holder == me) _dispenseLocks.remove(k);
        return;
      }
      // (dispense_completed does not release the lock: until this server has saved the dispense,
      // a released lock would let a second counter in; it simply expires.)
      if (eventType == 'save_entry' || eventType == 'token_created') {
        final inner = data['data'] is Map ? data['data'] as Map : data;
        _noteIssuedSerial((inner['serial'] ?? data['serial'])?.toString());
      }

      // ── [DEDUP] Server-side deduplication ─────────────────────────────────
      final messageId = (data['_messageId'] ?? data['messageId'])?.toString();
      if (messageId != null &&
          messageId.isNotEmpty &&
          !persistenceReady &&
          !_serverOnlyEventTypes.contains(eventType)) {
        // Not ACKed, so the desk keeps it in its outbox and resends it shortly.
        print('[LanServer] ⏳ Sync manager not ready — leaving $eventType ($messageId) with the desk');
        return;
      }
      if (messageId != null && messageId.isNotEmpty) {
        if (_inFlightMessageIds.contains(messageId)) return; // still being saved; no ACK yet
        if (_processedMessageIds.containsKey(messageId)) {
          // Already processed — send immediate ACK so client removes from outbox
          // but do NOT process or broadcast.
          print('[LanServer] ⚠️ Duplicate messageId=$messageId from $socketId — ACK & ignore');
          // Not processed again, but desks that missed the first forward (they were
          // reconnecting) get it now instead of at the next catch-up.
          final previous = _routed[messageId];
          if (previous != null && !_serverOnlyEventTypes.contains(eventType)) {
            previous.reached.addAll(_routeMessage(socket, previous.message, skip: previous.reached));
          }
          socket.add(jsonEncode({
            'event_type': 'message_ack',
            'messageId':  messageId,
            'duplicate':  true,
          }));
          return;
        }
        // Mark as processed with current timestamp.
        _processedMessageIds[messageId] = DateTime.now();
      }

      // The ACK is sent once the handler has saved the message (_deliverAndAck): the desk
      // deletes it from its outbox on the ACK, so an ACK before the save lost it whenever the
      // save failed.

      // ── [FIX 5] Server Authoritative Version Check with Disk Persistence & Tie-Breaker ──
      // 'version' is the sending PC's own clock. Comparing it across PCs dropped real updates
      // (already ACKed, so lost): a doctor PC whose clock ran behind the receptionist PC had
      // its prescription discarded as "older" than the token, and every PC sends the same
      // deviceId ('device_local'). Offline, Windows cannot correct the drift, so this is what
      // broke routing without internet. Versions are now only compared for the same event
      // type from the same client (a genuinely re-ordered or repeated send).
      final innerData = (data['data'] as Map?)?.cast<String, dynamic>() ?? data;
      final recordId = (innerData['serial'] ?? innerData['patientId'] ?? innerData['userId'])?.toString();
      final incomingVersion = (data['version'] is int)
          ? (data['version'] as int)
          : (int.tryParse(data['version']?.toString() ?? '') ?? 0);
      final senderClientId = (_clientInfo[socket]?['clientId'] ?? data['_clientId'] ?? socketId).toString();

      if (recordId != null && recordId.isNotEmpty && incomingVersion > 0) {
        final versionKey = '$recordId|${eventType ?? ''}|$senderClientId';
        final knownVersion = _recordVersionMap[versionKey] ?? 0;
        if (incomingVersion < knownVersion) {
          print('[LanServer] 🛑 Out-of-order update for $versionKey ($incomingVersion < $knownVersion) — dropping');
          if (messageId != null && messageId.isNotEmpty) _sendAck(socket, messageId); // superseded
          return;
        }
        _recordVersionMap[versionKey] = incomingVersion;
        if (_recordVersionMap.length > 20000) _recordVersionMap.clear(); // bounded; per-run ordering only
      }

            // ── Enrich and route ──────────────────────────────────────────────────
      final enhanced = Map<String, dynamic>.from(data);
      enhanced['_serverTimestamp']  = DateTime.now().toIso8601String();
      enhanced['_senderRole']       = _clientInfo[socket]!['role'];
      enhanced['_senderBranch']     = _clientInfo[socket]!['branchId'];
      enhanced['_senderUsername']   = _clientInfo[socket]!['username'];
      enhanced['_clientId']       ??= _clientInfo[socket]!['clientId'];
      // Attach socket ID so SSM can correctly credit the right connected user
      enhanced['_socketId']         = socketId;

      // [FIX-ROUTE-ISOLATION] Route to LAN peers FIRST and unconditionally.
      // Previously onMessageReceived?.call(enhanced) ran before _routeMessage()
      // inside the same try block — if the local handler (server dashboard's
      // onMessageReceived) threw for any reason (e.g. a Hive box not open on
      // this device), the whole _handleMessage call aborted and _routeMessage()
      // never executed. That meant NO connected peer received the broadcast,
      // even though the message was valid. Peer routing must never depend on
      // whether the server's own local bookkeeping succeeds.
      // Acknowledgements and catch-up requests are for the server only. Forwarding them made
      // every catch-up cost (PCs x tokens x PCs) frames: each client ACKs every token it is
      // sent, and each ACK went to every other client, keeping the LAN busy all the time.
      if (!_serverOnlyEventTypes.contains(eventType)) {
        final tracked = messageId != null && messageId.isNotEmpty;
        final previous = tracked ? _routed[messageId] : null;
        // First time this message is forwarded: give it its event-log number (non-token events).
        if (previous == null) {
          final logBranch = (enhanced['branchId'] ??
                  (enhanced['data'] is Map ? (enhanced['data'] as Map)['branchId'] : null) ??
                  _clientInfo[socket]?['branchId'] ??
                  '')
              .toString();
          _logEvent(enhanced, eventType, logBranch);
        }
        if (previous != null) {
          previous.reached.addAll(_routeMessage(socket, previous.message, skip: previous.reached));
        } else {
          final reached = _routeMessage(socket, enhanced);
          if (tracked) {
            _routed[messageId] = (message: enhanced, reached: reached, at: DateTime.now());
            if (_routed.length > _maxRoutedTracked) _routed.remove(_routed.keys.first);
          }
        }
      }
      unawaited(_deliverAndAck(socket, enhanced, messageId));
    } catch (e) {
      print('❌ Error processing message from $socketId: $e');
    }
  }

  /// Runs the server's handler (local save + cloud queue) and ACKs the message only after it
  /// finished. On failure the id is forgotten and no ACK is sent, so the desk resends it.
  Future<void> _deliverAndAck(WebSocket socket, Map<String, dynamic> message, String? messageId) async {
    final tracked = messageId != null && messageId.isNotEmpty;
    if (tracked) _inFlightMessageIds.add(messageId);
    try {
      await onMessageReceived?.call(message);
    } catch (e, st) {
      print('❌ onMessageReceived handler threw (peer routing was NOT affected): $e\n$st');
      if (tracked) {
        _inFlightMessageIds.remove(messageId);
        final failures = (_saveFailures[messageId] ?? 0) + 1;
        if (failures < _maxSaveFailures) {
          _saveFailures[messageId] = failures;
          _processedMessageIds.remove(messageId); // not ACKed: the desk resends it
          return;
        }
        // Keeps failing (bad data, broken box): park a copy for recovery and ACK it, so the
        // desk stops resending it every 30 s.
        _saveFailures.remove(messageId);
        await _parkUnsaved(message, e);
        _sendAck(socket, messageId);
      }
      return;
    }
    if (tracked) {
      _inFlightMessageIds.remove(messageId);
      _saveFailures.remove(messageId);
      _sendAck(socket, messageId);
    }
  }

  Future<void> _parkUnsaved(Map<String, dynamic> message, Object error) async {
    try {
      final box = Hive.isBoxOpen(unsavedMessagesBox)
          ? Hive.box(unsavedMessagesBox)
          : await Hive.openBox(unsavedMessagesBox);
      final id = (message['_messageId'] ?? message['messageId'] ?? DateTime.now().microsecondsSinceEpoch).toString();
      await box.put(id, {
        'message': jsonDecode(jsonEncode(message, toEncodable: (o) => o.toString())),
        'error': error.toString(),
        'parkedAt': DateTime.now().toIso8601String(),
      });
      print('⚠️ [LanServer] Message $id could not be saved after $_maxSaveFailures tries — parked in $unsavedMessagesBox');
    } catch (e) {
      print('❌ [LanServer] Could not park unsaved message: $e');
    }
  }

  void _sendAck(WebSocket socket, String messageId) {
    try {
      socket.add(jsonEncode({'event_type': 'message_ack', 'messageId': messageId, 'duplicate': false}));
    } catch (_) {
      // Socket closed meanwhile: the desk resends and gets the duplicate ACK then.
    }
  }

  // ── Route message to branch peers ──────────────────────────────────────────
  /// Sends a desk that just (re)connected the messages of the last 10 minutes it was not
  /// written: a token issued while the doctor's desk was reconnecting reached nobody and
  /// waited for the 5-minute catch-up (the catch-up on connect reads the server's own store,
  /// which may not have that token saved yet). Same branch only, oldest first.
  void _forwardMissedTo(WebSocket socket) {
    final info = _clientInfo[socket];
    if (info == null) return;
    final desk = _deskKey(socket);
    final clientBranch = (info['branchId'] as String?)?.toLowerCase().trim() ?? '';
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(minutes: 10));
    // Written to this desk shortly before it reconnected: maybe into a socket that was already
    // dead (Wi-Fi drop). Sent again as a catch-up copy, which the desk's router applies even
    // if it has seen the id, and its screens treat as a replay (no alert).
    final suspect = now.subtract(const Duration(minutes: 2));
    var sent = 0;
    for (final entry in _routed.entries) {
      final r = entry.value;
      if (r.at.isBefore(cutoff)) continue;
      final hadIt = r.reached.contains(desk);
      if (hadIt && r.at.isBefore(suspect)) continue;
      final m = hadIt ? {...r.message, 'isCatchUp': true} : r.message;
      if ((m['_clientId'] ?? '').toString() == info['clientId']?.toString()) continue; // its own
      final msgBranch = ((m['branchId'] ?? (m['data'] is Map ? m['data']['branchId'] : null) ?? m['_senderBranch'] ?? '')
              .toString())
          .toLowerCase()
          .trim();
      final sameBranch = msgBranch.isEmpty || clientBranch.isEmpty || msgBranch == 'all' || clientBranch == 'all' ||
          CampSessionService.areBranchesMatching(msgBranch, clientBranch);
      if (!sameBranch) continue;
      try {
        socket.add(jsonEncode(m));
        r.reached.add(desk);
        sent++;
      } catch (_) {
        break; // socket gone again
      }
    }
    if (sent > 0) print('[LanServer] 📬 Forwarded $sent message(s) desk $desk missed while away');
  }

  /// A desk's identity across reconnects (its clientId), else its socket.
  String _deskKey(WebSocket ws) => (_clientInfo[ws]?['clientId'] ?? ws.hashCode).toString();

  /// Forwards [message] to the identified desks of its branch except [sender] and the desks in
  /// [skip]. Returns the desks it was written to.
  // ── Traffic breakdown ───────────────────────────────────────────────────────
  // Counts per "direction type from/to desk" since the last summary, so a flood names its
  // source in the server log instead of only showing a total msg/min.
  final Map<String, int> _traffic = {};
  void countTraffic(String what, [int n = 1]) {
    _traffic[what] = (_traffic[what] ?? 0) + n;
    if (_traffic.length > 500) _traffic.remove(_traffic.keys.first);
  }

  /// The [top] busiest entries since the last call (then resets), e.g.
  /// "in save_entry from Kashif ×120 · out save_entry (catch-up) ×300".
  String? takeTrafficSummary({int top = 6}) {
    if (_traffic.isEmpty) return null;
    final total = _traffic.values.fold<int>(0, (a, b) => a + b);
    final sorted = _traffic.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    _traffic.clear();
    return '$total msgs: ' + sorted.take(top).map((e) => '${e.key} ×${e.value}').join(' · ');
  }

  Set<String> _routeMessage(WebSocket sender, Map<String, dynamic> message, {Set<String>? skip}) {
    final reached = <String>{};
    final senderInfo = _clientInfo[sender];
    if (senderInfo == null) return reached;
    countTraffic('fwd ${message['event_type'] ?? '?'}');

    final senderBranch = senderInfo['branchId'] as String;
    final messageBranch =
        (message['branchId'] as String?)?.toLowerCase().trim() ??
        (message['data'] is Map
            ? (message['data']['branchId'] as String?)?.toLowerCase().trim()
            : null) ??
        senderBranch;

    // [FP-3 FIX] Single, clear branch resolution — route to all peers in
    // the same branch as the message (or the sender if message has no branch).
    final targetBranch = messageBranch.isNotEmpty ? messageBranch : senderBranch;

    final messageJson = jsonEncode(message);
    int sentCount = 0;
    int failedCount = 0;

    for (final client in List<WebSocket>.from(_clients)) {
      if (client == sender) continue;
      if (client.readyState != WebSocket.open) continue;

      final info = _clientInfo[client];
      if (info == null || info['identified'] != true) continue;

      final clientBranch = (info['branchId'] as String?)?.toLowerCase().trim() ?? '';
      final isUniversal = targetBranch.isEmpty || targetBranch == 'all' || targetBranch == 'default' ||
          clientBranch.isEmpty || clientBranch == 'all' || clientBranch == 'default' ||
          CampSessionService.areBranchesMatching(targetBranch, clientBranch);
      if (!isUniversal) {
        continue;
      }
      final desk = _deskKey(client);
      if (skip != null && skip.contains(desk)) continue;

      try {
        client.add(messageJson);
        trafficMsgsOut++;
        trafficBytesOut += messageJson.length;
        sentCount++;
        _messagesSent++;
        reached.add(desk);
      } catch (e) {
        failedCount++;
        final clientSocketId = client.hashCode.toString();
        print('❌ ERROR routing to $clientSocketId (${info['role']}): $e');
        // [FP-4 FIX] Mark client as potentially stale; catch-up will recover
        // messages for this client when it reconnects.
      }
    }

    // [FP-5 FIX] Enhanced zero-delivery logging with serial info for diagnostics
    if (sentCount == 0 && skip == null && message['event_type'] != 'identify') {
      final eventType = message['event_type'] ?? 'unknown';
      final serial = message['data'] is Map
          ? (message['data']['serial'] ?? '').toString()
          : (message['serial'] ?? '').toString();
      final serialInfo = serial.isNotEmpty ? ' serial=$serial' : '';
      print('⚠️ "$eventType"$serialInfo not delivered to any peer '
          '(${_clientInfo.length} connected, ${failedCount > 0 ? "$failedCount failed" : "no matching peers"}) '
          '— catch-up will recover on next connect');
    }
    return reached;
  }

  // ── Remove client ──────────────────────────────────────────────────────────
  void _removeClient(WebSocket socket) {
    final socketId = socket.hashCode.toString();
    _clients.remove(socket);
    _socketById.remove(socketId);
    _clientInfo.remove(socket);
    _clientIps.remove(socket);
    _lastActiveTimes.remove(socket);
    _stagedPreHandshakeMessages.remove(socket);

    print('╔════════════════════════════════════════════════════════════╗');
    print('║ CLIENT DISCONNECTED: $socketId  Remaining: ${_clients.length}');
    print('╚════════════════════════════════════════════════════════════╝');

    onClientDisconnected?.call(socketId);
    _broadcastClientCount();
  }

  // ── Public send helpers ────────────────────────────────────────────────────

  /// Send to ONE specific client by socketId (used for catch-up push).
  bool sendToSocket(String socketId, String rawMessage) {
    final socket = _socketById[socketId];
    if (socket == null) {
      print('⚠️ sendToSocket: socket $socketId not found');
      return false;
    }
    if (socket.readyState != WebSocket.open) {
      print('⚠️ sendToSocket: socket $socketId not open');
      return false;
    }
    try {
      socket.add(rawMessage);
      trafficMsgsOut++;
      trafficBytesOut += rawMessage.length;
      _messagesSent++;
      return true;
    } catch (e) {
      print('❌ sendToSocket error for $socketId: $e');
      return false;
    }
  }

  /// Broadcast to ALL connected + identified clients.
  void broadcast(String rawMessage, {WebSocket? exclude}) {
    int forwarded = 0;
    for (final client in List<WebSocket>.from(_clients)) {
      if (client == exclude) continue;
      if (client.readyState != WebSocket.open) continue;
      try {
        client.add(rawMessage);
        trafficMsgsOut++;
        trafficBytesOut += rawMessage.length;
        forwarded++;
        _messagesSent++;
      } catch (_) {}
    }
    if (forwarded > 0) print('[LanServer] Broadcast → $forwarded client(s)');
  }

  /// Returns metadata (including username and IP address) for all identified clients.
  List<Map<String, dynamic>> getConnectedClients() {
    return _clientInfo.entries.map((e) {
      final socketId = e.key.hashCode.toString();
      return {
        'socketId':  socketId,
        'role':      e.value['role'],
        'branchId':  e.value['branchId'],
        'username':  e.value['username'],
        'clientId':  e.value['clientId'],
        'ipAddress': e.value['ipAddress'] ?? _clientIps[e.key] ?? '127.0.0.1',
        'deviceOs':  e.value['deviceOs'] ?? (kIsWeb ? 'Chrome Web' : 'Windows PC'),

        'appVersion': e.value['appVersion'] ?? 'v${AutoUpdateService.currentVersion}',
      };
    }).toList();
  }

  // ── Broadcast client count ─────────────────────────────────────────────────
  void _broadcastClientCount() {
    final countMsg = jsonEncode({
      'event_type': 'client_count_update',
      'count':      _clientInfo.length,
      'timestamp':  DateTime.now().toIso8601String(),
    });
    for (final client in _clients) {
      if (client.readyState == WebSocket.open &&
          _clientInfo.containsKey(client)) {
        try { client.add(countMsg); } catch (_) {}
      }
    }
  }

  Future<void> stop() async {
    print('[LanServer] Shutting down (${_clients.length} clients)...');
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastActiveTimes.clear();
    _udpTimer?.cancel();
    _udpTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    _dedupPurgeTimer?.cancel();
    _dedupPurgeTimer = null;
    _processedMessageIds.clear();
    
    for (final client in _clients) {
      try { client.close(); } catch (_) {}
    }
    _clients.clear();
    _socketById.clear();
    _clientInfo.clear();
    _clientIps.clear();
    try {
      await _server?.close(force: true);
    } catch (e) {
      print('[LanServer] Error closing server socket: $e');
    }
    _server = null;
    _isRunning = false;
    if (!kIsWeb && PythonRunnerService.instance.isRunning) {
      try {
        await PythonRunnerService.instance.stopProcess();
      } catch (_) {}
    }
    print('[LanServer] Fully stopped');
  }

  ContentType _getContentType(String path) {
    if (path.endsWith('.html')) return ContentType.html;
    if (path.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
    if (path.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
    if (path.endsWith('.png')) return ContentType('image', 'png');
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return ContentType('image', 'jpeg');
    if (path.endsWith('.svg')) return ContentType('image', 'svg+xml');
    if (path.endsWith('.json')) return ContentType.json;
    if (path.endsWith('.wasm')) return ContentType('application', 'wasm');
    return ContentType.binary;
  }
}
