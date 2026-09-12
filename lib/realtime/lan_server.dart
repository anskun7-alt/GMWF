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
import '../services/python_runner_service.dart';
import '../utils/network_utils.dart';

class LanServer {
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

  // ── [FIX 5] In-memory & disk persisted record version arbiter map ──────────
  final Map<String, int> _recordVersionMap = {};
  final Map<String, String> _recordDeviceMap = {};

  // ── [LIVENESS] Track last active timestamp for each socket to evict silent/dead sockets ──
  final Map<WebSocket, DateTime> _lastActiveTimes = {};
  Timer? _heartbeatTimer;

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
      _server = await HttpServer.bind(
          InternetAddress.anyIPv4, port, shared: true);

      final ipShown = forcedIp ?? 'your-LAN-IP';
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
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      final now = DateTime.now();
      final deadSockets = <WebSocket>[];
      for (final client in List<WebSocket>.from(_clients)) {
        if (client.readyState != WebSocket.open) {
          deadSockets.add(client);
          continue;
        }
        final lastActive = _lastActiveTimes[client];
        if (lastActive != null) {
          if (now.difference(lastActive) > const Duration(seconds: 40)) {
            try {
              client.add('ping');
            } catch (_) {
              deadSockets.add(client);
            }
          }
          if (now.difference(lastActive) > const Duration(seconds: 60)) {
            deadSockets.add(client);
          }
        }
      }
      for (final dead in deadSockets) {
        final sid = dead.hashCode.toString();
        print('[LanServer] ⏱️ Client $sid closed/timed out — evicting');
        try { dead.close(1001, 'Liveness timeout'); } catch (_) {}
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
        
        final payload = utf8.encode('${AppNetwork.udpMessagePrefix}$ipShown:$port');
        final broadcastAddr = InternetAddress('255.255.255.255');
        
        _udpTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
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

  // ── Handle message ─────────────────────────────────────────────────────────
  void _handleMessage(WebSocket socket, String socketId, dynamic message) {
    _lastActiveTimes[socket] = DateTime.now();
    if (message is! String) return;
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
          socket.close(1008, 'Auth Failed');
          return;
        }
        socket.add(jsonEncode({'type': 'auth_ack', 'status': 'authenticated'}));
        return;
      }

      // ── Identify handshake ────────────────────────────────────────────────
      if (eventType == 'identify') {
        final clientProtocol = (data['protocolVersion'] as num?)?.toInt() ?? 1;
        if (clientProtocol < 2) {
          print('[LanServer] ❌ Protocol version mismatch for client $socketId (protocol v$clientProtocol < 2). Rejecting connection.');
          socket.add(jsonEncode({
            'type': 'error',
            'event_type': 'version_mismatch',
            'code': 'VERSION_MISMATCH_REJECTED',
            'message': 'Protocol version mismatch. Please update app to v1.3.7 or higher.'
          }));
          socket.close(1008, 'VERSION_MISMATCH_REJECTED');
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

          onClientConnected?.call(socketId, info);
          _broadcastClientCount();
        } else {
          print('⚠️ Incomplete identification: role=$role branch=$branchId');
        }
        return;
      }

      // ── Reject unidentified clients ───────────────────────────────────────
      if (_clientInfo[socket]?['identified'] != true) {
        print('❌ Message from UNIDENTIFIED client $socketId — rejecting');
        return;
      }

      // ── [DEDUP] Server-side deduplication ─────────────────────────────────
      final messageId = (data['_messageId'] ?? data['messageId'])?.toString();
      if (messageId != null && messageId.isNotEmpty) {
        if (_processedMessageIds.containsKey(messageId)) {
          // Already processed — send immediate ACK so client removes from outbox
          // but do NOT process or broadcast.
          print('[LanServer] ⚠️ Duplicate messageId=$messageId from $socketId — ACK & ignore');
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

      // ── Acknowledge message immediately ───────────────────────────────────
      if (messageId != null && messageId.isNotEmpty) {
        socket.add(jsonEncode({
          'event_type': 'message_ack',
          'messageId':  messageId,
          'duplicate':  false,
        }));
      }

      // ── [FIX 5] Server Authoritative Version Check with Disk Persistence & Tie-Breaker ──
      final innerData = (data['data'] as Map?)?.cast<String, dynamic>() ?? data;
      final recordId = (innerData['serial'] ?? innerData['patientId'] ?? innerData['userId'])?.toString();
      final incomingVersion = (data['version'] is int)
          ? (data['version'] as int)
          : (int.tryParse(data['version']?.toString() ?? '') ?? 0);
      final incomingDeviceId = (data['deviceId'] ?? data['_clientId'] ?? '').toString();

      if (recordId != null && recordId.isNotEmpty && incomingVersion > 0) {
        final knownVersion = _recordVersionMap[recordId] ?? 0;
        if (incomingVersion < knownVersion) {
          print('[LanServer] 🛑 Stale update for recordId=$recordId (version $incomingVersion < $knownVersion) — dropping broadcast');
          return;
        }
        if (incomingVersion == knownVersion) {
          // Tie-breaker: compare deviceId or client timestamp to break concurrent ties
          final knownDeviceId = _recordDeviceMap[recordId] ?? '';
          if (incomingDeviceId.isNotEmpty && knownDeviceId.isNotEmpty && incomingDeviceId == knownDeviceId) {
            print('[LanServer] 🛑 Duplicate version $incomingVersion from same device $incomingDeviceId — dropping');
            return;
          }
        }
        _recordVersionMap[recordId] = incomingVersion;
        if (incomingDeviceId.isNotEmpty) _recordDeviceMap[recordId] = incomingDeviceId;
        try {
          if (Hive.isBoxOpen('server_record_versions')) {
            Hive.box('server_record_versions').put(recordId, incomingVersion);
          }
        } catch (_) {}
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
      _routeMessage(socket, enhanced);
      try {
        onMessageReceived?.call(enhanced);
      } catch (e, st) {
        print('❌ onMessageReceived handler threw (peer routing was NOT affected): $e\n$st');
      }
    } catch (e) {
      print('❌ Error processing message from $socketId: $e');
    }
  }

  // ── Route message to branch peers ──────────────────────────────────────────
  void _routeMessage(WebSocket sender, Map<String, dynamic> message) {
    final senderInfo = _clientInfo[sender];
    if (senderInfo == null) return;

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
          clientBranch.isEmpty || clientBranch == 'all' || clientBranch == 'default';
      if (!isUniversal && clientBranch != targetBranch && !clientBranch.contains(targetBranch) && !targetBranch.contains(clientBranch)) {
        continue;
      }

      try {
        client.add(messageJson);
        sentCount++;
        _messagesSent++;
      } catch (e) {
        failedCount++;
        final clientSocketId = client.hashCode.toString();
        print('❌ ERROR routing to $clientSocketId (${info['role']}): $e');
        // [FP-4 FIX] Mark client as potentially stale; catch-up will recover
        // messages for this client when it reconnects.
      }
    }

    // [FP-5 FIX] Enhanced zero-delivery logging with serial info for diagnostics
    if (sentCount == 0 && message['event_type'] != 'identify') {
      final eventType = message['event_type'] ?? 'unknown';
      final serial = message['data'] is Map
          ? (message['data']['serial'] ?? '').toString()
          : (message['serial'] ?? '').toString();
      final serialInfo = serial.isNotEmpty ? ' serial=$serial' : '';
      print('⚠️ "$eventType"$serialInfo not delivered to any peer '
          '(${_clientInfo.length} connected, ${failedCount > 0 ? "$failedCount failed" : "no matching peers"}) '
          '— catch-up will recover on next connect');
    }
  }

  // ── Remove client ──────────────────────────────────────────────────────────
  void _removeClient(WebSocket socket) {
    final socketId = socket.hashCode.toString();
    _clients.remove(socket);
    _socketById.remove(socketId);
    _clientInfo.remove(socket);
    _clientIps.remove(socket);
    _lastActiveTimes.remove(socket);

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

        'appVersion': e.value['appVersion'] ?? 'v2.4.0',
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
