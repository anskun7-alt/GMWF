// lib/realtime/realtime_manager.dart
//
// PERSISTENCE FIXES:
//   [FIX-P1] Hive-backed outbox — every sent message is written to Hive FIRST.
//            On successful WS send, removed from outbox.
//            On reconnect, unACK'd messages are flushed automatically.
//            Outbox items expire after 24 hours (only today's data matters).
//
//   [FIX-P2] _flushOutbox() called after every reconnect + identified echo,
//            ensuring no message is lost across connection drops.
//
//   [FIX-P3] ACK sending — after processing each incoming server-push,
//            client sends back 'ack_serials' so server's seen-set stays current.
//
// BUG FIXES:
//   [BUG-1]  Outbox double-write: _sendPendingMessages re-sent messages through
//            sendMessage(), which re-wrote them to the outbox. Fixed by flushing
//            pending messages directly to the channel, bypassing the outbox write.
//
//   [BUG-2]  Flush race: _sendPendingMessages and _flushOutbox were triggered in
//            sequence after 'identified', causing duplicates. _flushOutbox is now
//            only scheduled if _pendingMessages was empty.
//
//   [BUG-3]  ACK re-queue race: serials were cleared before the try block, so a
//            send failure silently lost them. Now cleared only on success.
//
//   [BUG-4]  Double fallback: _schedulePendingFallback could fire _flushOutbox a
//            second time if 'identified' already triggered it. Now guarded with a
//            _flushedOnConnect flag.
//
// NEW — THIS REVISION:
//   [IMM-ACK] Immediate ACK on receipt of save_entry/token_created/save_prescription/
//             prescription_created events (in addition to the 5-second batch timer).
//             Closes the reconnect-before-ACK window responsible for duplicate
//             server-side processing.
//
//   [FAIL-BOX] Client-side failed outbox ('realtime_failed_outbox').
//              Messages that fail to send 3× during _flushOutbox are moved here
//              instead of being silently dropped. Includes tokens and prescriptions.
//              On every new connection, _retryFailedOutbox() moves them back to
//              the main outbox for another round of attempts.
//
// RECONNECT FIX [FIX-RC]:
//   Removed the _reconnectAttempts < 5 cap from _handleDisconnect().
//   Previously RealtimeManager gave up after 5 self-reconnect attempts
//   (2+4+8+16+32 = 62 s), leaving ConnectionManager's heartbeat as the
//   only rescue path — which then re-ran full 25-second LAN discovery
//   even though the server IP was already cached.
//
//   Now RealtimeManager retries indefinitely with a stable 5-second
//   interval after the initial back-off sequence, matching
//   ConnectionManager's own retry strategy. ConnectionManager's heartbeat
//   remains a safety net but is no longer the primary recovery path.

import 'package:gmwf/utils/ui_stall_monitor.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, ValueNotifier, VoidCallback, debugPrint;
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../services/auto_update_service.dart';
import '../services/camp_session_service.dart';
import '../services/serials_service.dart';
import 'realtime_events.dart';
import 'realtime_router.dart';
import '../services/local_storage_service.dart';

class RealtimeManager {
  static final RealtimeManager _instance = RealtimeManager._internal();
  factory RealtimeManager() => _instance;
  RealtimeManager._internal();

  // ── State ─────────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;

  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _isConnected      = false;
  bool _gotFirstFrame    = false; // true once the server has actually sent us a frame on this socket
  bool _serverIdentified = false;
  bool _flushedOnConnect = false; // [BUG-4] guard against double outbox flush
  bool _outboxFlushing = false; // one _flushOutbox pass at a time
  bool _outboxFlushAgain = false; // a flush was asked for during a pass: run one right after
  DateTime? _lastPingTick; // to spot ping ticks delayed by a frozen UI thread
  Future<void> _routeChain = Future<void>.value(); // incoming messages are routed one at a time
  bool _stressPurgeDone = false; // the stress-test sweep scans every entry: once per app run

  // ── LAN Health State (3-up / 2-down Hysteresis) ───────────────────────────
  static final ValueNotifier<bool> isLanHealthyNotifier = ValueNotifier<bool>(false);

  /// Today's tokens the server has but this desk has not confirmed yet (from each pong;
  /// -1 = unknown, e.g. older server build). 0 means this desk's queue is complete.
  static final ValueNotifier<int> unconfirmedTokensNotifier = ValueNotifier<int>(-1);

  /// Set when the server refused this PC because its app version is too old.
  static final ValueNotifier<String?> versionRejectedNotifier = ValueNotifier<String?>(null);
  DateTime? _unconfirmedAt;

  /// True when this desk may be missing tokens: no server link, or the server reported
  /// unconfirmed tokens recently. Used to hold "next patient" for a moment.
  bool get isBehindServer {
    if (!hasServerLink) return true;
    final n = unconfirmedTokensNotifier.value;
    if (n <= 0) return false;
    final at = _unconfirmedAt;
    return at != null && DateTime.now().difference(at).inSeconds < 15;
  }

  /// Number of messages written on this desk that the server has not acknowledged yet.
  int get unsentCount {
    try {
      if (Hive.isBoxOpen(_outboxBox)) return Hive.box(_outboxBox).length;
    } catch (_) {}
    return _pendingMessages.length;
  }
  int _consecutivePingSuccesses = 0;
  int _consecutivePingFailures  = 0;

  String? _role;
  String? _branchId;
  String? _username;
  String? _serverIp;
  int     _port      = 53281;
  String? _clientId;

  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _ackFlushTimer;
  Timer? _outboxSweepTimer;

  // [FIX-RC] No longer capped — tracks attempts only for back-off schedule.
  int _reconnectAttempts = 0;

  DateTime? _lastPong;

  // [BUG-1] In-memory pending queue — only holds messages that could not be
  // sent because the channel was not ready. Already in the outbox.
  final List<Map<String, dynamic>> _pendingMessages = [];

  static const _outboxBox       = 'realtime_outbox';
  static const _failedOutboxBox = 'realtime_failed_outbox'; // [FAIL-BOX]

  // Max consecutive send failures in _flushOutbox before moving to failed box.
  static const _maxOutboxRetries = 3;
  /// Sends without a server ACK before a message is set aside in the failed outbox.
  static const _maxUnackedSends = 20;
  /// Critical (token/prescription/dispense) sends after which re-sends slow down.
  static const _criticalSlowAfterSends = 30;
  static const _criticalSlowResendEvery = Duration(seconds: 30);
  /// When each outbox key was last written to the socket (memory only).
  final Map<dynamic, DateTime> _outboxLastSendAt = {};

  // [BUG-3] Track serials to ACK — only cleared after a successful send.
  final Set<String> _pendingAckSerials = {};

  // ── Event types that trigger immediate ACK ─────────────────────────────────
  static const _immAckEvents = {
    'save_entry',
    'token_created',
    'save_prescription',
    'prescription_created',
    'dispense_completed',
    'save_patient',
    'migrate_patient_key',
    'save_stock_item',
    'delete_stock_item',
    'token_reversal_approved',
    'save_proforma_item',
    'proforma_item_updated',
    'request_created',
    'request_approved',
    'request_rejected',
    'token_exception_request',
    'token_exception_approved',
    'restriction_removed',
    'update_serial_status',
  };

  // ── Back-off schedule (seconds). After the last value, stays at 5 s. ──────
  static const _backoffDelays = [2, 3, 5, 5, 5];

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  bool    get isConnected          => _isConnected;
  bool    get isServerIdentified   => _serverIdentified;

  /// True only while the link is demonstrably alive: socket open, server handshake done, and a
  /// frame (pong or data) received in the last 15 s. Use this for status displays instead of
  /// cached connection-manager snapshots, which can stay "connected" after the server is gone.
  bool get isLinkAlive =>
      _isConnected && _serverIdentified && _lastPong != null && DateTime.now().difference(_lastPong!).inSeconds < 45;

  /// True once the server has accepted this PC on the current socket. [isConnected] alone
  /// turns true as soon as a connection attempt starts (and stays true for a while on a
  /// socket that died silently), so it must not decide whether local data is handed to the
  /// server instead of being uploaded by this PC.
  bool get hasServerLink => _isConnected && _serverIdentified;
  bool    get isLanHealthy         => isLanHealthyNotifier.value;
  bool    get isReconnecting       => _reconnectTimer != null && _reconnectTimer!.isActive;
  int     get reconnectAttempts    => _reconnectAttempts;
  String? get role                 => _role;
  String? get branchId             => _branchId;
  String? get username             => _username;
  String? get clientId             => _clientId;

  /// True when a messageStream event is the local echo of something THIS desk sent
  /// (e.g. a token issued from the Receptionist tab of a Hybrid Desk). Use it to skip
  /// "new token"/"prescription" popups about the user's own actions.
  bool isOwnEvent(Map<String, dynamic>? event) {
    if (event == null || _clientId == null || _clientId!.isEmpty) return false;
    final decoded = event['decoded'];
    final sender = event['_clientId'] ?? (decoded is Map ? decoded['_clientId'] : null);
    return sender != null && sender.toString() == _clientId;
  }
  String? get serverIp             => _serverIp;
  int     get port                 => _port;
  DateTime get effectiveNow => DateTime.now().add(Duration(milliseconds: _serverClockSkewMs));
  int _serverClockSkewMs = 0;

  VoidCallback? onNeedRediscovery;
  VoidCallback? onDisconnected;
  void Function(String ip, int port)? onConnected;

  final List<VoidCallback> _identifiedListeners = [];
  void addIdentifiedListener(VoidCallback cb) => _identifiedListeners.add(cb);
  void removeIdentifiedListener(VoidCallback cb) => _identifiedListeners.remove(cb);

  void _recordHealthSuccess() {
    _consecutivePingSuccesses++;
    _consecutivePingFailures = 0;
    if (_consecutivePingSuccesses >= 3 && !isLanHealthyNotifier.value) {
      isLanHealthyNotifier.value = true;
      if (kDebugMode) {
        print('[RealtimeManager] 🟢 LAN is HEALTHY (3 pings confirmed). Dispensary screens will silence live Firestore streams.');
      }
    }
  }

  void _recordHealthFailure() {
    _consecutivePingFailures++;
    _consecutivePingSuccesses = 0;
    if (_consecutivePingFailures >= 2 && isLanHealthyNotifier.value) {
      isLanHealthyNotifier.value = false;
      if (kDebugMode) {
        print('[RealtimeManager] 🔴 LAN is UNHEALTHY (2 consecutive drops). Falling back to Firestore cloud streams.');
      }
    }
  }

  static Future<void> initOutbox() async {
    await LocalStorageService.openBoxSafe(_outboxMetaBox);
    // An oversized queue is being rebuilt in a background isolate (startup); it opens when
    // that is done, without holding up the rest of start-up.
    final underRepair = LocalStorageService.isBoxUnderRepair(_outboxBox) ||
        LocalStorageService.isBoxUnderRepair(_failedOutboxBox);
    if (underRepair) {
      unawaited(() async {
        try {
          await LocalStorageService.openBoxSafe(_outboxBox);
          await LocalStorageService.openBoxSafe(_failedOutboxBox);
          await RealtimeManager()._writeDeferredOutbox();
        } catch (e) {
          debugPrint('[RealtimeManager] Opening repaired outbox failed: $e');
        }
      }());
      return;
    }
    await LocalStorageService.openBoxSafe(_outboxBox);
    await LocalStorageService.openBoxSafe(_failedOutboxBox); // [FAIL-BOX]
  }

  // ── Outbox send/retry counters ────────────────────────────────────────────
  // Kept in their own small box. They used to be written into the outbox item itself, which
  // re-put the whole payload (patient, prescription, ...) on every flush: every 30 s for every
  // queued item, the main reason realtime_outbox.hive reached 1.5 GB on a Karachi PC.
  static const _outboxMetaBox = 'realtime_outbox_meta';
  final Map<String, int> _outboxCountersMem = {};

  int _outboxCounter(String kind, dynamic key, Object? legacy) {
    final k = '$kind|$key';
    final mem = _outboxCountersMem[k];
    if (mem != null) return mem;
    try {
      if (Hive.isBoxOpen(_outboxMetaBox)) {
        final v = Hive.box(_outboxMetaBox).get(k);
        if (v is int) return v;
      }
    } catch (_) {}
    return legacy is int ? legacy : 0;
  }

  void _setOutboxCounter(String kind, dynamic key, int value) {
    final k = '$kind|$key';
    _outboxCountersMem[k] = value;
    try {
      if (Hive.isBoxOpen(_outboxMetaBox)) Hive.box(_outboxMetaBox).put(k, value);
    } catch (_) {}
  }

  void _clearOutboxCounters(dynamic key) {
    if (key == null) return;
    _outboxLastSendAt.remove(key);
    for (final kind in const ['s', 'r']) {
      final k = '$kind|$key';
      _outboxCountersMem.remove(k);
      try {
        if (Hive.isBoxOpen(_outboxMetaBox)) Hive.box(_outboxMetaBox).delete(k);
      } catch (_) {}
    }
  }

  // ── Writes made while the outbox is being repaired ────────────────────────
  final Map<String, Map<String, dynamic>> _deferredOutbox = {};

  Future<void> _writeDeferredOutbox() async {
    if (_deferredOutbox.isEmpty || !Hive.isBoxOpen(_outboxBox)) return;
    final pending = Map<String, Map<String, dynamic>>.from(_deferredOutbox);
    _deferredOutbox.clear();
    await Hive.box(_outboxBox).putAll(pending);
  }

  /// Rebuilds an oversized outbox file (runs in a background isolate, before the app opens the
  /// box). Keeps the newest queued copy of each record, flattens nested prescriptions, drops
  /// stale non-critical items (same rules as [_flushOutbox]) and leaves tokens, prescriptions,
  /// dispenses, patients, donations and employees in place however old. On any error the
  /// original file is left untouched. Returns before/after counts and sizes.
  static Future<Map<String, int>> rebuildQueueFile(String dir, String name) async {
    Hive.init(dir);
    if (!Hive.isAdapterRegistered(100)) Hive.registerAdapter(_RepairTimestampAdapter());
    final file = File('$dir${Platform.pathSeparator}$name.hive');
    final tmpName = '${name}_rebuild';
    final tmpFile = File('$dir${Platform.pathSeparator}$tmpName.hive');
    final beforeBytes = file.lengthSync();
    if (tmpFile.existsSync()) tmpFile.deleteSync(); // left over from an interrupted run

    final src = await Hive.openBox(name);
    final out = await Hive.openBox(tmpName);
    final beforeCount = src.length;
    var kept = 0;
    try {
      final now = DateTime.now();
      final today = '${now.day.toString().padLeft(2, '0')}${now.month.toString().padLeft(2, '0')}'
          '${(now.year % 100).toString().padLeft(2, '0')}';
      final cutoff = now.subtract(const Duration(hours: 12));
      final isCloudSyncQueue = name == LocalStorageService.syncBox;

      final latest = <String, ({dynamic key, String ts})>{};
      for (final key in src.keys) {
        final raw = src.get(key);
        if (raw is! Map) continue;
        final lk = _logicalKey(raw);
        if (lk == null) continue;
        final ts = (raw['enqueuedAt'] ?? raw['_outboxTimestamp'] ?? raw['createdAt'] ?? '').toString();
        final cur = latest[lk];
        if (cur == null || ts.compareTo(cur.ts) >= 0) latest[lk] = (key: key, ts: ts);
      }

      final batch = <dynamic, dynamic>{};
      for (final key in src.keys) {
        final raw = src.get(key);
        if (raw is! Map) continue;
        final lk = _logicalKey(raw);
        if (lk != null && latest[lk]?.key != key) continue; // an older copy of the same record
        final item = Map<String, dynamic>.from(raw.map((k, v) => MapEntry(k.toString(), v)));
        if (!isCloudSyncQueue && !_isCriticalOutboxItem(item)) {
          final dk = (item['dateKey'] ?? (item['data'] is Map ? item['data']['dateKey'] : null))?.toString().trim();
          final ts = DateTime.tryParse((item['_outboxTimestamp'] ?? item['createdAt'] ?? item['_failedAt'] ?? '').toString());
          final stale = (dk != null && dk.isNotEmpty && dk != today) ||
              (ts != null && (ts.isBefore(cutoff) || ts.day != now.day));
          if (stale) continue;
        }
        LocalStorageService.flattenEmbeddedPrescription(item);
        if (item['data'] is Map) {
          final data = Map<String, dynamic>.from((item['data'] as Map).map((k, v) => MapEntry(k.toString(), v)));
          LocalStorageService.flattenEmbeddedPrescription(data);
          item['data'] = data;
        }
        item.remove('_outboxSends');
        item.remove('_outboxRetryCount');
        batch[key] = item;
        kept++;
        if (batch.length >= 200) {
          await out.putAll(batch);
          batch.clear();
        }
      }
      if (batch.isNotEmpty) await out.putAll(batch);
      await out.flush();
    } catch (e) {
      await src.close();
      await out.deleteFromDisk();
      rethrow;
    }
    await src.close();
    await out.close();
    file.deleteSync();
    tmpFile.renameSync(file.path);
    for (final lock in [File('$dir${Platform.pathSeparator}$tmpName.lock')]) {
      if (lock.existsSync()) lock.deleteSync();
    }
    return {
      'beforeCount': beforeCount,
      'afterCount': kept,
      'beforeBytes': beforeBytes,
      'afterBytes': file.lengthSync(),
    };
  }

  /// Manually force-flushes the Hive outbox and requests catch-up from LAN server.
  /// Used by UI Sync buttons to force any stuck token or prescription to the next user.
  Future<void> forceFlushAndCatchUp() async {
    try {
      _retryFailedOutbox(force: true);
      _sendPendingMessages();
      await _flushOutbox();
      if (_isConnected && _serverIdentified) {
        sendMessage({
          'event_type': 'request_catch_up',
          'branchId': _branchId,
          'forceAll': true,
        });
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] forceFlushAndCatchUp error: $e');
    }
  }

  // ── Coalesced catch-up request ─────────────────────────────────────────────
  // Doctor, Dispenser and Receptionist screens (and the auto request sent on
  // server identification) may all ask for catch-up within the same second —
  // e.g. in the hybrid dispensary view. Sending N requests makes the server
  // push the whole day N times, which is exactly the kind of burst that made
  // 1.6.0 drop the socket. Collapse them into one request per window.
  DateTime? _lastCatchUpRequestAt;
  static const Duration _catchUpCoalesceWindow = Duration(seconds: 3);

  /// Returns true if a request was actually sent.
  bool requestCatchUp({String? branchId, bool force = false, String? reason}) {
    if (!_isConnected || !_serverIdentified) return false;
    final now = DateTime.now();
    if (!force &&
        _lastCatchUpRequestAt != null &&
        now.difference(_lastCatchUpRequestAt!) < _catchUpCoalesceWindow) {
      return false;
    }
    _lastCatchUpRequestAt = now;
    sendMessage({
      'event_type': 'request_catch_up',
      'branchId': branchId ?? _branchId,
      if (force) 'force': true,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
    return true;
  }

  // ── Initialize ─────────────────────────────────────────────────────────────
  Future<void> initialize({
    required String role,
    required String branchId,
    required String serverIp,
    int    port     = 53281,
    String? username,
  }) async {
    final normRole = role.trim().toLowerCase();
    final normBranch = branchId.trim().toLowerCase();
    final normIp = serverIp.trim();

    // A socket that was accepted but has had no frame for >45 s (pings go every 10 s) is
    // half-open after a Wi-Fi drop: reusing it kept the desk "connected" to nothing.
    final staleLink = _serverIdentified && _lastPong != null && DateTime.now().difference(_lastPong!).inSeconds > 45;
    if (_isConnected && !staleLink && _serverIp == normIp && _branchId == normBranch) {
      _role = normRole;
      if (username != null && username.trim().isNotEmpty) {
        _username = username.trim();
      }
      // Reuse existing live connection smoothly: send updated identify without tearing down the socket!
      try {
        final identifyMsg = {
          'event_type':      'identify',
          'role':            _role,
          'branchId':        _branchId,
          'username':        _username ?? _role,
          'platform':        kIsWeb ? 'web' : 'native',
          'protocolVersion': AutoUpdateService.protocolVersion,
          'appVersion':      AutoUpdateService.currentVersion,
          '_clientId':       _clientId,
          'lastEventSeq':    _lastLogSeq,
          'lastEventEpoch':  _lastLogEpoch,
          '_timestamp':      DateTime.now().millisecondsSinceEpoch,
        };
        _channel?.sink.add(jsonEncode(identifyMsg));
      } catch (_) {}
      return;
    }

    await dispose();

    _role     = normRole;
    _branchId = normBranch;
    _serverIp = normIp;
    _port     = port;
    _username = username?.trim();
    _serverIdentified = false;
    _flushedOnConnect = false;

    if (_clientId == null || _clientId!.isEmpty) {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          _clientId = Hive.box('app_settings').get('permanent_client_id') as String?;
        }
      } catch (_) {}
      if (_clientId == null || _clientId!.isEmpty) {
        _clientId = 'client_${const Uuid().v4()}';
        try {
          if (Hive.isBoxOpen('app_settings')) {
            Hive.box('app_settings').put('permanent_client_id', _clientId);
          }
        } catch (_) {}
      }
    }

    if (kDebugMode) {
      print('[RealtimeManager] Initializing: role=$_role branch=$_branchId username=$_username');
    }

    await _connectClient();
  }

  // ── Update username on the fly (called after async name fetch) ─────────────
  // [FIX-USERNAME] Screens call this once their async name load completes so
  // the next message they send carries the real display name, not just the role.
  void updateUsername(String username) {
    final trimmed = username.trim();
    if (trimmed.isEmpty) return;
    _username = trimmed;
    if (kDebugMode) {
      print('[RealtimeManager] Username updated → $_username');
    }
  }

  // ── WebSocket connect ──────────────────────────────────────────────────────
  int _connectGen = 0;

  /// Closes the current socket without waiting (closing a SYN_SENT socket can block ~20 s).
  /// Code 1000: dart:io rejects 1001 (goingAway) with "close code must be 1000 or in the range
  /// 3000-4999" (gmwf_crash.log), so the old half-open socket was never closed at all.
  void _closeChannelQuietly() {
    final channel = _channel;
    if (channel == null) return;
    try {
      unawaited(channel.sink
          .close(ws_status.normalClosure)
          .timeout(const Duration(seconds: 1), onTimeout: () {})
          .catchError((Object _) {}));
    } catch (_) {}
  }

  Future<void> _connectClient() async {
    if (_serverIp == null || _serverIp!.isEmpty) return;

    final wsUrl = 'ws://$_serverIp:$_port';
    debugPrint('[RealtimeManager] Connecting → $wsUrl');

    _serverIdentified = false;
    _gotFirstFrame    = false;
    _flushedOnConnect = false;

    // Make sure any previous half-open channel/subscription is released
    // without awaiting (closing a SYN_SENT socket can block for ~20s).
    try { _channelSub?.cancel(); } catch (_) {}
    _channelSub = null;
    _closeChannelQuietly();

    final gen = ++_connectGen;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Handshake watchdog: if the server never identifies us (stale IP, wrong
      // device on that IP, firewall dropping SYN) give up quickly so the
      // reconnect/rediscovery logic can run instead of sitting in SYN_SENT.
      final armedAt = DateTime.now();
      void watchdog() {
        if (gen != _connectGen) return;
        if (_serverIdentified) return;
        // Fired late because the UI thread was frozen: the server's reply may be queued
        // behind this timer. Look again shortly instead of dropping the attempt.
        if (DateTime.now().difference(armedAt).inSeconds > 15 &&
            DateTime.now().difference(armedAt).inSeconds < 60) {
          Timer(const Duration(seconds: 4), () {
            if (gen != _connectGen || _serverIdentified) return;
            debugPrint('[RealtimeManager] ⏱️ Handshake watchdog: still no identify from $wsUrl → reconnect');
            _handleDisconnect();
          });
          return;
        }
        debugPrint('[RealtimeManager] ⏱️ Handshake watchdog: no identify from $wsUrl in 15s → reconnect');
        _handleDisconnect();
      }
      Timer(const Duration(seconds: 15), watchdog);

      if (kIsWeb) {
        try {
          await _channel!.ready.timeout(const Duration(seconds: 4));
        } catch (e) {
          if (kDebugMode) print('[RealtimeManager] Web WebSocket connection error/timeout: $e');
          _handleDisconnect();
          return;
        }
      }

      // Attach listener FIRST before sending identify payload so no responses are lost
      _channelSub = _channel!.stream.listen(
        _onMessage,
        onError: (err) {
          debugPrint('[RealtimeManager] 🔴 Socket error: $err');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('[RealtimeManager] 🔴 Socket onDone: closeCode=${_channel?.closeCode} closeReason=${_channel?.closeReason}');
          _handleDisconnect();
        },
      );

      final identifyMsg = {
        'event_type':      'identify',
        'role':            _role,
        'branchId':        _branchId,
        'username':        _username ?? _role,
        'platform':        kIsWeb ? 'web' : 'native',
        'protocolVersion': AutoUpdateService.protocolVersion,
        'appVersion':      AutoUpdateService.currentVersion,
        '_clientId':       _clientId,
        'lastEventSeq':    _lastLogSeq,
        'lastEventEpoch':  _lastLogEpoch,
        '_timestamp':      DateTime.now().millisecondsSinceEpoch,
      };
      _channel!.sink.add(jsonEncode(identifyMsg));

      _isConnected = true;
      _lastPong = DateTime.now();
      // NOTE: _reconnectAttempts is intentionally NOT reset here. It is reset
      // once the server confirms identification, otherwise a dead IP would
      // keep the counter at 0 forever and rediscovery would never trigger.
      _startPingTimer();
      _startAckFlushTimer();
      _schedulePendingFallback();

      // [FAIL-BOX] On new connection, move failed messages back to main outbox.
      _retryFailedOutbox(force: true);

    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] Connect failed: $e');
      _handleDisconnect();
    }
  }

  // ── Incoming message ───────────────────────────────────────────────────────

  // ══ Stress-test support (server-initiated, see StressTestEngine) ══════════════
  // Replies are written straight to the socket (no outbox, no retry) so measured timings are
  // real. Test tokens are written to the local entries box only: they never enter the sync
  // queue, the serial counter or Firestore, and are removed again by `stress_cleanup` (and by
  // the safety purge that runs on every connect).

  void _sendRaw(Map<String, dynamic> m) {
    try {
      _channel?.sink.add(jsonEncode({...m, '_clientId': _clientId}));
    } catch (_) {}
  }

  bool _handleStressMessage(Map<String, dynamic> m) {
    final type = (m['event_type'] ?? m['type'] ?? '').toString();
    if (!type.startsWith('stress_')) return false;
    switch (type) {
      case 'stress_probe':
        _sendRaw({
          'event_type': 'stress_probe_ack',
          'testId': m['testId'],
          'seq': m['seq'],
        });
        return true;
      case 'stress_token':
        try {
          final serial = (m['serial'] ?? '').toString();
          final data = Map<String, dynamic>.from((m['data'] as Map?) ?? {});
          if (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            final branch = (data['branchId'] ?? _branchId ?? '').toString().toLowerCase();
            final box = Hive.box(LocalStorageService.entriesBox);
            data['isStressTest'] = true;
            data['serial'] = serial;
            data['id'] = serial;
            box.put('$branch-${serial.toLowerCase()}', data);
          }
        } catch (_) {}
        _sendRaw({'event_type': 'stress_token_ack', 'testId': m['testId'], 'i': m['i']});
        return true;
      case 'stress_request':
        _sendRaw({'event_type': 'stress_request_ack', 'testId': m['testId'], 'i': m['i']});
        return true;
      case 'stress_cleanup':
        final res = purgeStressTestEntries();
        _sendRaw({
          'event_type': 'stress_cleanup_ack',
          'testId': m['testId'],
          'removed': res.$1,
          'remaining': res.$2,
        });
        return true;
    }
    return true; // unknown stress_* frame: ignore, never route as real data
  }

  /// Deletes every stress-test token from this device. Returns (removed, remainingAfter).
  (int, int) purgeStressTestEntries() {
    var removed = 0;
    var remaining = 0;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) return (0, 0);
      final box = Hive.box(LocalStorageService.entriesBox);
      final doomed = <dynamic>[];
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map && (v['isStressTest'] == true || (v['serial'] ?? '').toString().startsWith('STRESS-'))) {
          doomed.add(k);
        }
      }
      for (final k in doomed) {
        box.delete(k);
        removed++;
      }
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map && v['isStressTest'] == true) remaining++;
      }
    } catch (e) {
      debugPrint('[RealtimeManager] purgeStressTestEntries error: $e');
    }
    return (removed, remaining);
  }

  void _onMessage(dynamic raw) {
    if (raw == null) return;
    _gotFirstFrame = true;
    _lastPong = DateTime.now();
    _recordHealthSuccess();
    final msg = raw.toString();

    // Immediate ping response
    if (msg == 'ping' || msg == '{"type":"ping"}' || msg == '{"event_type":"ping"}') {
      try {
        _channel?.sink.add(jsonEncode({
          'type': 'pong',
          'event_type': 'pong',
          '_clientId': _clientId,
          '_timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
      } catch (_) {}
      return;
    }

    if (msg == 'pong' || msg == '{"type":"pong"}' || msg == '{"event_type":"pong"}') {
      return;
    }

    try {
      final decoded = jsonDecode(msg) as Map<String, dynamic>;

      if (decoded['event_type'] == 'ping' || decoded['type'] == 'ping') {
        try {
          _channel?.sink.add(jsonEncode({
            'type': 'pong',
            'event_type': 'pong',
            '_clientId': _clientId,
            '_timestamp': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (_) {}
        return;
      }

      if (decoded['event_type'] == 'version_mismatch') {
        versionRejectedNotifier.value =
            decoded['message']?.toString() ?? 'Update GMWF on this PC to connect to the server.';
        return;
      }

      if (decoded['event_type'] == 'pong' || decoded['type'] == 'pong') {
        final n = decoded['unconfirmedTokens'];
        if (n is num) {
          unconfirmedTokensNotifier.value = n.toInt();
          _unconfirmedAt = DateTime.now();
        }
        return;
      }

      if (_handleStressMessage(decoded)) return;
      // A stress-test token relayed as a real event (older server build) is never shown or saved.
      if (LocalStorageService.isStressTestMessage(decoded)) return;

      if (decoded['event_type'] == 'identified') {
        final srvBranch = (decoded['serverBranch'] ?? decoded['branchId'])?.toString().trim();
        if (srvBranch != null && srvBranch.isNotEmpty && srvBranch != 'all' && srvBranch != 'default') {
          final normSrv = LocalStorageService.sanitizeBranchId(srvBranch);
          final myBranch = _branchId?.toLowerCase().trim() ?? '';
          // Only adopt the server's spelling of OUR branch (e.g. haji_camp -> karachi). A server
          // logged in under an account from another branch (a Karachi camp server whose user
          // record said "sialkot") used to switch every desk to that branch, after which the
          // desks dropped all live Karachi tokens as "another branch".
          final sameFamily = myBranch.isEmpty ||
              myBranch == 'all' ||
              CampSessionService.areBranchesMatching(normSrv, myBranch);
          if (!sameFamily) {
            debugPrint('[RealtimeManager] ⚠️ Server reports branch "$normSrv" but this desk is "$myBranch" — '
                'keeping "$myBranch" (set the server location on the server PC)');
          }
          if (sameFamily && normSrv.isNotEmpty && myBranch != normSrv) {
            if (kDebugMode) {
              print('[RealtimeManager] 🔄 Server identified branch mismatch: adopting $normSrv (was: $_branchId)');
            }
            _branchId = normSrv;
            try {
              if (Hive.isBoxOpen('app_settings')) {
                final settingsBox = Hive.box('app_settings');
                settingsBox.put('selected_branch', normSrv);
                settingsBox.put('current_branch', normSrv);
              }
            } catch (_) {}
          }
        }
        if (!_serverIdentified) {
          _onServerIdentified();
        }
      }

      if (decoded['event_type'] == 'event_log_position') {
        // Sent after the server replayed what this desk missed: all of it up to here is done
        // (events for other branches or sent by this desk are not replayed but count as seen).
        final pos = decoded['_logSeq'], ep = decoded['_logEpoch'];
        _routeChain.whenComplete(() => _noteLogPosition(pos, ep, jumpTo: true));
        return;
      }

      if (decoded['event_type'] == 'dispense_lock') {
        final waiting = _dispenseLockRequests.remove(decoded['requestId']?.toString());
        if (waiting != null && !waiting.isCompleted) {
          waiting.complete({
            'result': decoded['result']?.toString() ?? 'granted',
            if (decoded['holder'] != null) 'holder': decoded['holder'].toString(),
          });
        }
        return;
      }

      if (decoded['event_type'] == 'serial_reserved') {
        final waiting = _serialRequests.remove(decoded['requestId']?.toString());
        final seq = (decoded['seq'] as num?)?.toInt();
        // The server's offline token block for this PC (used when the server is unreachable).
        final deskSlot = (decoded['deskSlot'] as num?)?.toInt();
        if (deskSlot != null) LocalStorageService.setOfflineDeskSlot(deskSlot).ignore();
        if (waiting != null && !waiting.isCompleted && seq != null) waiting.complete(seq);
        return;
      }

      // [IMM-ACK] Handle ACK from server (server confirmed our message).
      if (decoded['event_type'] == 'message_ack') {
        final ackedId = decoded['messageId']?.toString();
        if (ackedId != null && ackedId.isNotEmpty) {
          _removeFromOutboxByMessageId(ackedId);
          final waiter = _ackWaiters.remove(ackedId);
          if (waiter != null && !waiter.isCompleted) waiter.complete(true);
        }
        return;
      }

      // [GAP-RECOVERY] Server detected a sequence gap (e.g. Token #2 or #5 arrived while earlier tokens were missing)
      // and asked this desk to immediately push all missing prior serials in exact numerical order.
      if (decoded['event_type'] == 'request_missing_serial' || decoded['event_type'] == 'request_missing_serials') {
        final missingList = <String>[];
        if (decoded['serials'] is List) {
          missingList.addAll((decoded['serials'] as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty));
        }
        final singleSerial = decoded['serial']?.toString().trim();
        if (singleSerial != null && singleSerial.isNotEmpty && !missingList.contains(singleSerial)) {
          missingList.add(singleSerial);
        }
        final reqBranch = (decoded['branchId'] ?? _branchId ?? '').toString().trim().toLowerCase();
        if (missingList.isNotEmpty && reqBranch.isNotEmpty) {
          // Sort in ascending numerical order so tokens 1, 2, 3... are re-transmitted in exact order
          missingList.sort((a, b) {
            final seqA = parseSequenceFromSerial(a);
            final seqB = parseSequenceFromSerial(b);
            return seqA.compareTo(seqB);
          });
          for (final missingSerial in missingList) {
            final localEntry = LocalStorageService.getLocalEntry(reqBranch, missingSerial);
            if (localEntry != null && localEntry.isNotEmpty) {
              sendMessage({
                'event_type': 'save_entry',
                'branchId': reqBranch,
                'serial': missingSerial,
                'dateKey': localEntry['dateKey'] ?? LocalStorageService.getTodayDateKey(),
                'queueType': localEntry['queueType'] ?? 'zakat',
                'data': localEntry,
              });
            }
          }
          unawaited(_flushOutbox());
        }
        return;
      }

      _routeIncoming(decoded);
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] Decode error: $e');
    }
  }

  // ── Outbox de-duplication ────────────────────────────────────────────────────
  // The same token / patient / prescription used to be queued again every time it was re-sent
  // (startup backfill, reconnects, repeated saves) under a NEW message id. Thousands of
  // duplicates piled up while offline; on reconnect they were all flushed at once and every
  // server ACK then scanned the whole outbox (O(n²)), freezing the UI thread ("Not Responding").
  final Map<String, String> _outboxLogical = {};

  /// Identity of the business record a message carries, e.g. "save_entry|091026-SADD-074".
  static String? _logicalKey(Map<dynamic, dynamic> m) {
    final type = (m['event_type'] ?? m['type'])?.toString() ?? '';
    if (type.isEmpty) return null;
    final data = m['data'] is Map ? m['data'] as Map : const {};
    // A stock change "+N" is an operation, not a record state: two restocks of the same
    // medicine must both be sent. Keeping only the newest one lost the earlier restock.
    if (data['_quantityDelta'] != null || m['_quantityDelta'] != null) return null;
    final id = (m['serial'] ?? data['serial'] ?? data['id'] ?? data['patientId'] ?? m['entityId'] ?? data['localId'] ?? '')
        .toString()
        .trim();
    return id.isEmpty ? null : '$type|$id';
  }

  /// Checks whether a business record (e.g. "save_entry|031126M-SADD-001") is currently pending in outbox or in-memory queue.
  bool isRecordPendingOrUnacked(String logicalKey) {
    if (_outboxLogical.containsKey(logicalKey)) {
      final boxKey = _outboxLogical[logicalKey];
      if (boxKey != null && Hive.isBoxOpen(_outboxBox) && Hive.box(_outboxBox).containsKey(boxKey)) {
        return true;
      }
    }
    if (_pendingMessages.any((m) => _logicalKey(m) == logicalKey)) return true;
    return false;
  }

  /// Triggers an immediate outbox flush so all queued messages are sent in order.
  Future<void> flushOutboxNow() => _flushOutbox();

  // ── Remove outbox entry by messageId (called on server ACK) ──────────────
  void _removeFromOutboxByMessageId(String messageId) {
    _deferredOutbox.remove(messageId);
    _clearOutboxCounters(messageId);
    try {
      final box = Hive.box(_outboxBox);
      // The outbox key IS the message id (see sendMessage), so this is O(1). The old code scanned
      // and decoded every entry for every ACK, which froze the app when thousands were queued.
      if (box.containsKey(messageId)) {
        box.delete(messageId);
        return;
      }
      // Entries written without a message id use generated keys: scan to match entry's messageId.
      for (final key in box.keys.toList()) {
        final entry = box.get(key);
        if (entry is Map) {
          final entryMsgId = (entry['_messageId'] ?? entry['messageId'])?.toString();
          if (entryMsgId == messageId) {
            box.delete(key);
            return;
          }
        }
      }
      // Also check failed outbox in case it was already moved there.
      if (Hive.isBoxOpen(_failedOutboxBox)) {
        final failedBox = Hive.box(_failedOutboxBox);
        for (final key in failedBox.keys.toList()) {
          final entry = failedBox.get(key);
          if (entry is Map) {
            final entryMsgId = (entry['_messageId'] ?? entry['messageId'])?.toString();
            if (entryMsgId == messageId) {
              failedBox.delete(key);
              if (kDebugMode) {
                print('[RealtimeManager] ACK: removed failed-outbox entry for msgId=$messageId');
              }
              return;
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] _removeFromOutboxByMessageId error: $e');
    }
  }

  void handleIncomingForTest(Map<String, dynamic> data) {
    if (data['event_type'] == 'message_ack') {
      final ackedId = data['messageId']?.toString();
      if (ackedId != null && ackedId.isNotEmpty) {
        _removeFromOutboxByMessageId(ackedId);
      }
    } else {
      _routeIncoming(data);
    }
  }

  /// Everything that follows the server accepting this PC. Used for the real 'identified'
  /// frame and for the fallback below, so both leave the link in the same state (the fallback
  /// used to set the flag only, skipping the outbox sweep and catch-up, and the real frame
  /// arriving later was then ignored).
  void _onServerIdentified() {
    versionRejectedNotifier.value = null; // accepted by this server
    _serverIdentified = true;
    for (final cb in List<VoidCallback>.from(_identifiedListeners)) {
      try { cb(); } catch (_) {}
    }
    // Safety net: remove any stress-test tokens left by a test this device missed. Once per
    // run: both sweeps scan the whole entries box on the UI thread, and on flapping Wi-Fi this
    // ran on every reconnect.
    if (!_stressPurgeDone) {
      _stressPurgeDone = true;
      purgeStressTestEntries();
      LocalStorageService.purgeStressTestLeftovers().ignore();
    }
    _reconnectAttempts = 0;
    if (kDebugMode) {
      print('[RealtimeManager] Identified — flushing ${_pendingMessages.length} pending');
    }

    // [BUG-1] Flush in-memory pending directly (bypasses outbox write).
    // [BUG-2] Only schedule outbox flush if nothing was in the pending queue.
    final hadPending = _pendingMessages.isNotEmpty;
    _sendPendingMessages();

    _flushedOnConnect = true;
    // Flush outbox immediately without delay so offline tokens reach the server right away
    unawaited(_flushOutbox());

    // Start periodic outbox sweep to catch stuck messages
    _startOutboxSweepTimer();

    // Request today's local records immediately. This fills a doctor or
    // dispensary queue that missed a live broadcast without waiting for
    // the periodic server catch-up timer. A fresh identification always
    // sends (window reset); screens mounting right after are coalesced.
    _lastCatchUpRequestAt = null;
    requestCatchUp();

    final ip = _serverIp;
    if (ip != null) {
      try {
        onConnected?.call(ip, _port);
      } catch (e) {
        if (kDebugMode) print('[RealtimeManager] onConnected error: $e');
      }
    }
  }

  // ── Fallback flush ─────────────────────────────────────────────────────────
  // Older server builds never send 'identified'; once the server has answered at all and
  // messages are waiting, treat the link as accepted.
  void _schedulePendingFallback() {
    final gen = _connectGen;
    Future.delayed(const Duration(seconds: 3), () {
      if (gen != _connectGen) return; // a newer connection attempt owns the link now
      if (!_serverIdentified && _isConnected && _gotFirstFrame && _pendingMessages.isNotEmpty) {
        _onServerIdentified();
      }
    });
  }

  // ── Ping / pong ────────────────────────────────────────────────────────────
  void _startPingTimer() {
    _pingTimer?.cancel();
    _lastPingTick = DateTime.now();
    // Ping every 5 s (was 10 s), dead after 20 s without a pong (was 30 s): a desk whose cable
    // was re-plugged or that woke from sleep reconnects and catches up in ~20-25 s instead of
    // ~40 s. Not lower yet: the server still handles messages on its UI thread, and a too-short
    // limit made every desk drop at once when the server was busy for a moment (see below).
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isConnected || _channel == null) return;
      final now = DateTime.now();
      // This tick came late: the UI thread was frozen (Haji Camp logs: 12–64 s while the
      // receptionist list rebuilt or boxes opened). The server's pongs from that time are still
      // queued behind this timer, so "no pong" would drop a healthy link and start a
      // reconnect plus a full catch-up, which froze the desk again. Judge it on the next tick.
      final lateTick = now.difference(_lastPingTick ?? now).inSeconds > 12;
      _lastPingTick = now;
      // No pong for 45 s → treat the socket as dead. (Increased from 20s to prevent
      // disconnects during Wi-Fi jitter or heavy background SQLite/Hive writes).
      if (!lateTick && _lastPong != null && now.difference(_lastPong!).inSeconds > 45) {
        debugPrint('[RealtimeManager] ⚠️ Pong timeout (>45s) → tearing down half-dead socket');
        _recordHealthFailure();
        _handleDisconnect();
        return;
      }
      try {
        _channel!.sink.add(jsonEncode({
          'type': 'ping',
          'event_type': 'ping',
          '_clientId': _clientId,
          '_timestamp': now.millisecondsSinceEpoch,
        }));
      } catch (e) {
        if (kDebugMode) print('[RealtimeManager] ⚠️ Ping send exception: $e');
        _recordHealthFailure();
        _handleDisconnect();
      }
    });
  }

  // [FIX-P3] Periodic ACK flush every 1 second (fast confirmation to LAN server).
  void _startAckFlushTimer() {
    _ackFlushTimer?.cancel();
    _ackFlushTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isConnected || !_serverIdentified) return;
      _sendPendingAcks();
    });
  }

  // [FIX-SWEEP] Periodic outbox sweep every 5 seconds — catches tokens/prescriptions
  // stuck in Hive outbox that were written but never delivered (silent WS drops,
  // buffering issues, or send appeared to succeed but server never ACK'd).
  // Also retries the failed outbox periodically instead of only on reconnect.
  DateTime? _lastRediscoveryNudge;
  bool _disposedSweep = false;

  void _startOutboxSweepTimer() {
    _disposedSweep = false;
    _outboxSweepTimer?.cancel();
    _outboxSweepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposedSweep) return;
      // Unsent items on a desk with no link: nudge the ConnectionManager to look for the
      // server. Only when fully disconnected (never during a handshake, which this would
      // interrupt) and at most every 20 s (a full rediscovery scans the subnet).
      if (!_isConnected) {
        try {
          final now = DateTime.now();
          if (Hive.isBoxOpen(_outboxBox) &&
              Hive.box(_outboxBox).isNotEmpty &&
              (_lastRediscoveryNudge == null ||
                  now.difference(_lastRediscoveryNudge!) >= const Duration(seconds: 20))) {
            _lastRediscoveryNudge = now;
            onNeedRediscovery?.call();
          }
        } catch (_) {}
        return;
      }
      if (!_serverIdentified) return;
      try {
        final box = Hive.box(_outboxBox);
        if (box.isNotEmpty) {
          if (kDebugMode) {
            print('[RealtimeManager] 🔄 Outbox sweep: ${box.length} stuck item(s)');
          }
          _flushOutbox();
        }
      } catch (_) {}
      // Also retry failed outbox every sweep
      _retryFailedOutbox();
    });
  }

  // [FIX-P3] [BUG-3] Serials are only cleared after a successful channel write.
  void _sendPendingAcks() {
    if (_pendingAckSerials.isEmpty) return;
    final serials = List<String>.from(_pendingAckSerials);

    try {
      final ackMsg = {
        'event_type': 'ack_serials',
        'serials':    serials,
        '_clientId':  _clientId,
        '_timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      _channel?.sink.add(jsonEncode(ackMsg));
      // Only clear on success
      _pendingAckSerials.removeAll(serials);
      if (kDebugMode) print('[RealtimeManager] ACK sent: ${serials.length} serials');
    } catch (e) {
      // Serials remain in _pendingAckSerials for the next timer tick
      if (kDebugMode) print('[RealtimeManager] ACK send failed, will retry: $e');
    }
  }

  // ── Disconnect / reconnect ─────────────────────────────────────────────────
  // [FIX-RC] No attempt cap — retries indefinitely.
  // Back-off: 2, 4, 8, 16, 32 s, then holds at 5 s intervals.
  // This prevents the >60-second dead window that occurred when the old cap
  // of 5 was hit and ConnectionManager had to re-run full LAN discovery.
  void _handleDisconnect() {
    _connectGen++; // invalidate any pending handshake watchdog for the old socket
    _gotFirstFrame = false;
    _recordHealthFailure();
    _isConnected      = false;
    _serverIdentified = false;
    _flushedOnConnect = false;
    _pingTimer?.cancel();
    _ackFlushTimer?.cancel();
    // Keep outbox sweep timer running so unsent queued items proactively prompt rediscovery
    _startOutboxSweepTimer();
    _channelSub?.cancel();
    _closeChannelQuietly();
    _channelSub = null;

    // Compute next delay; after exhausting the back-off table, hold at 5 s.
    final delaySeconds = _reconnectAttempts < _backoffDelays.length
        ? _backoffDelays[_reconnectAttempts]
        : 5;
    _reconnectAttempts++;

    if (kDebugMode) {
      print('[RealtimeManager] Disconnected. Reconnecting in ${delaySeconds}s '
          '(attempt $_reconnectAttempts)');
    }

    // If we've failed to reconnect to this specific server IP twice,
    // notify ConnectionManager to run full LAN discovery (UDP/subnet/Firestore probe)
    // in case the server IP changed or machine restarted with a new DHCP address.
    if (_reconnectAttempts >= 2 && onNeedRediscovery != null) {
      if (kDebugMode) {
        print('[RealtimeManager] Reconnect attempts reached $_reconnectAttempts → notifying ConnectionManager to trigger rediscovery');
      }
      try {
        onNeedRediscovery!();
      } catch (e) {
        if (kDebugMode) print('[RealtimeManager] onNeedRediscovery error: $e');
      }
    }

    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(Duration(seconds: delaySeconds), _connectClient);
  }

  void reconnectNow() {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    if (!_isConnected) {
      _connectClient();
    }
  }

  // ── [FIX 6] Durable Outbox helpers for Users, Sessions, and Credentials ─────
  void sendUserRecord(Map<String, dynamic> userData, {bool isDelete = false}) {
    final payload = RealtimeEvents.payload(
      type: isDelete ? RealtimeEvents.deleteUser : RealtimeEvents.saveUser,
      data: userData,
      branchId: userData['branchId']?.toString(),
    );
    sendMessage(payload);
  }

  void sendSessionEvent(Map<String, dynamic> sessionData) {
    final payload = RealtimeEvents.payload(
      type: 'session_event',
      data: sessionData,
      branchId: sessionData['branchId']?.toString(),
    );
    sendMessage(payload);
  }

  void sendCredentialSync(Map<String, dynamic> credData) {
    final payload = RealtimeEvents.payload(
      type: 'credential_sync',
      data: credData,
      branchId: credData['branchId']?.toString(),
    );
    sendMessage(payload);
  }

  /// Sends a live-only notice to the other desks: straight to the socket, never through the
  /// outbox, so it is not replayed after a reconnect. False when there is no server link.
  bool sendLive(Map<String, dynamic> payload) {
    if (!hasServerLink || _channel == null) return false;
    _sendRaw(payload);
    return true;
  }

  // ── Token numbers ──────────────────────────────────────────────────────────
  final Map<String, Completer<int>> _serialRequests = {};

  /// Asks the LAN server for the next token number after [prefix] ('301026M-HAJI'), at least
  /// [proposed] (this desk's own count). The server issues numbers one at a time for every
  /// desk, so two desks can no longer give out the same token. Null when there is no server
  /// link or no answer in [timeout] (older server build): the caller uses its own count.
  /// Sent straight to the socket, never through the outbox: a request replayed later would
  /// only use up a number.
  ///
  /// A slow server is not an absent one: it used to give up after 1.5 s, so whenever the
  /// server PC was busy the desk numbered the token itself (an offline-block or out-of-order
  /// number while the server was actually there). Now the same request is re-sent every
  /// [attempt] for up to [timeout] while the link is up; the server answers a repeated
  /// requestId with the same number, so a retry never uses up a second one.
  Future<int?> reserveSerial(String prefix, int proposed,
      {Duration timeout = const Duration(seconds: 6),
      Duration attempt = const Duration(seconds: 2)}) async {
    if (!hasServerLink || _channel == null) return null;
    final requestId = const Uuid().v4();
    final waiting = Completer<int>();
    _serialRequests[requestId] = waiting;
    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (!hasServerLink || _channel == null) return null; // link really went down
        _sendRaw({
          'event_type': 'reserve_serial',
          'requestId':  requestId,
          'prefix':     prefix,
          'proposed':   proposed,
          'deviceKey':  LocalStorageService.deskDeviceKey,
        });
        final left = deadline.difference(DateTime.now());
        final wait = left < attempt ? left : attempt;
        if (wait <= Duration.zero) break;
        try {
          return await waiting.future.timeout(wait);
        } on TimeoutException {
          // re-send the same request
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      _serialRequests.remove(requestId);
    }
  }

  final Map<String, Completer<bool>> _ackWaiters = {};

  // ── Event-log position (see LanServer event log) ──────────────────────────
  // The last log number applied IN ORDER; events applied out of order wait in [_logAhead]
  // until the gap closes. Sent with identify, so the server replays exactly what is missing.
  int _lastLogSeqValue = 0;
  String _lastLogEpochValue = '';
  bool _logLoaded = false;
  final Set<int> _logAhead = {};

  // Loaded on first use (app_settings may not be open yet when this singleton is created).
  void _ensureLogLoaded() {
    if (_logLoaded || !Hive.isBoxOpen('app_settings')) return;
    _logLoaded = true;
    _lastLogSeqValue = _readLogSeq();
    _lastLogEpochValue = _readLogEpoch();
  }

  int get _lastLogSeq {
    _ensureLogLoaded();
    return _lastLogSeqValue;
  }

  set _lastLogSeq(int v) => _lastLogSeqValue = v;

  String get _lastLogEpoch {
    _ensureLogLoaded();
    return _lastLogEpochValue;
  }

  set _lastLogEpoch(String v) => _lastLogEpochValue = v;

  static int _readLogSeq() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final v = Hive.box('app_settings').get('lan_event_log_seq');
        if (v is num) return v.toInt();
      }
    } catch (_) {}
    return 0;
  }

  static String _readLogEpoch() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        return Hive.box('app_settings').get('lan_event_log_epoch')?.toString() ?? '';
      }
    } catch (_) {}
    return '';
  }

  void _noteLogPosition(Object? seqRaw, Object? epochRaw, {bool jumpTo = false}) {
    final seq = seqRaw is num ? seqRaw.toInt() : int.tryParse(seqRaw?.toString() ?? '');
    final epoch = epochRaw?.toString() ?? '';
    if (seq == null || epoch.isEmpty) return;
    if (epoch != _lastLogEpoch) {
      // A different server log (reinstalled server): start counting from it.
      _lastLogEpoch = epoch;
      _lastLogSeq = 0;
      _logAhead.clear();
    }
    if (jumpTo) {
      // The server's position after a replay: everything up to it was sent to this desk.
      if (seq > _lastLogSeq) _lastLogSeq = seq;
      _logAhead.removeWhere((s) => s <= _lastLogSeq);
    } else if (seq == _lastLogSeq + 1) {
      _lastLogSeq = seq;
      while (_logAhead.remove(_lastLogSeq + 1)) {
        _lastLogSeq++;
      }
    } else if (seq > _lastLogSeq + 1) {
      _logAhead.add(seq);
      if (_logAhead.length > 1000) _logAhead.remove(_logAhead.reduce((a, b) => a < b ? a : b));
    }
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        box.put('lan_event_log_seq', _lastLogSeq);
        if (box.get('lan_event_log_epoch') != _lastLogEpoch) box.put('lan_event_log_epoch', _lastLogEpoch);
      }
    } catch (_) {}
  }
  final Map<String, Completer<Map<String, String>>> _dispenseLockRequests = {};

  /// Asks the LAN server for permission to dispense [serial] (one counter per token).
  /// Returns {'result': 'granted' | 'held' | 'already_dispensed', 'holder': name?}, or null
  /// when there is no server link or no answer (older server build) — the caller then relies
  /// on its local check.
  Future<Map<String, String>?> requestDispenseLock(String serial, String branchId,
      {Duration timeout = const Duration(seconds: 4)}) async {
    if (!hasServerLink || _channel == null) return null;
    final requestId = const Uuid().v4();
    final waiting = Completer<Map<String, String>>();
    _dispenseLockRequests[requestId] = waiting;
    _sendRaw({
      'event_type': 'begin_dispense',
      'requestId': requestId,
      'serial': serial,
      'branchId': branchId,
      '_clientId': _clientId,
    });
    try {
      return await waiting.future.timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      _dispenseLockRequests.remove(requestId);
    }
  }

  /// Gives the dispense permission back (the dispenser cancelled).
  void releaseDispenseLock(String serial) {
    if (!hasServerLink || _channel == null) return;
    _sendRaw({'event_type': 'end_dispense', 'serial': serial, '_clientId': _clientId});
  }

  /// Waits until the server has acknowledged (saved and forwarded) the message [messageId]
  /// returned by [sendMessage]. True once acknowledged, false on timeout or without an id.
  /// The message stays in the outbox either way and is re-sent until acknowledged.
  Future<bool> waitForServerAck(String? messageId,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (messageId == null || messageId.isEmpty) return false;
    // Acknowledged already (the outbox entry is removed on ACK)?
    try {
      if (Hive.isBoxOpen(_outboxBox) &&
          !Hive.box(_outboxBox).containsKey(messageId) &&
          !_deferredOutbox.containsKey(messageId) &&
          !_pendingMessages.any((m) => m['_messageId'] == messageId)) {
        return true;
      }
    } catch (_) {}
    final c = _ackWaiters.putIfAbsent(messageId, () => Completer<bool>());
    try {
      return await c.future.timeout(timeout);
    } catch (_) {
      return false;
    } finally {
      if (_ackWaiters[messageId] == c) _ackWaiters.remove(messageId);
    }
  }

  /// [sendMessage] that returns the message id, for [waitForServerAck].
  String sendMessageTracked(Map<String, dynamic> payload) {
    final p = Map<String, dynamic>.from(payload);
    final existing = p['_messageId']?.toString() ?? '';
    final id = existing.isNotEmpty ? existing : _generateMessageId();
    p['_messageId'] = id;
    sendMessage(p);
    return id;
  }

  // ── Send ───────────────────────────────────────────────────────────────────
  void sendMessage(Map<String, dynamic> payload) {
    final normalized = _normalizeMessage(payload);

    final isPing = normalized['event_type'] == 'ping' ||
                   normalized['type'] == 'ping';
    final isAck  = normalized['event_type'] == 'ack_serials';
    final isHandshake = normalized['event_type'] == 'identify' ||
                        normalized['event_type'] == 'identified';
    final isCatchUpRequest = normalized['event_type'] == 'request_catch_up';
    final isUnknown = normalized['event_type'] == 'unknown' && normalized['type'] == null;

    if (isUnknown) {
      if (kDebugMode) print('[RealtimeManager] ⚠️ Suppressing message with missing/unknown event_type');
      return;
    }

    if (!isPing && !isAck && !isHandshake && !isCatchUpRequest) {
      try {
        _messageController.add(normalized);
      } catch (_) {}
    }

    // [FIX-P1] Write to Hive outbox FIRST (skip ping/ack/handshake).
    String? outboxKey;
    if (!isPing && !isAck && !isHandshake && !isCatchUpRequest) {
      try {
        final mId = normalized['_messageId']?.toString();
        outboxKey = (mId != null && mId.isNotEmpty) ? mId : 'outbox_${DateTime.now().microsecondsSinceEpoch}';
        final outboxEntry = Map<String, dynamic>.from(normalized);
        outboxEntry['_outboxKey']        = outboxKey;
        outboxEntry['_outboxTimestamp']  = DateTime.now().toIso8601String();
        outboxEntry['_outboxRetryCount'] = 0; // [FAIL-BOX]
        if (Hive.isBoxOpen(_outboxBox)) {
          // Same business record queued again? Replace the older copy instead of piling up.
          final logical = _logicalKey(normalized);
          if (logical != null) {
            final old = _outboxLogical[logical];
            if (old != null && old != outboxKey) {
              try {
                Hive.box(_outboxBox).delete(old);
              } catch (_) {}
            }
            _outboxLogical[logical] = outboxKey;
            _pendingMessages.removeWhere((m) => _logicalKey(m) == logical);
          }
          Hive.box(_outboxBox).put(outboxKey, outboxEntry);
        } else if (LocalStorageService.isBoxUnderRepair(_outboxBox)) {
          // Written once the repaired outbox opens (see initOutbox).
          _deferredOutbox[outboxKey] = outboxEntry;
        }
      } catch (e) {
        if (kDebugMode) print('[RealtimeManager] Outbox write failed: $e');
        outboxKey = null;
      }
    }

    if (!_isConnected || _channel == null || !_serverIdentified) {
      if (kDebugMode && !isPing) {
        print('[RealtimeManager] Queuing (${!_isConnected ? "not connected" : "not identified"}): ${normalized['event_type']}');
      }
      if (!isPing && !isAck && !isHandshake && !isCatchUpRequest) {
        _pendingMessages.add(normalized);
      }
      return;
    }

    // Safely encode JSON first — serialization issues MUST NEVER drop the network socket!
    final String encoded;
    try {
      encoded = jsonEncode(normalized);
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] ⚠️ JSON encode error for ${normalized['event_type']}: $e');
      return;
    }

    // [UNBREAKABLE SEQUENCE] If sending Token N (e.g. 002 or 005), make sure any prior tokens
    // 1..(N-1) for this session/camp prefix that are still pending or un-ACKed are flushed FIRST
    // so Token 1..(N-1) hit the TCP socket before Token N!
    if (normalized['event_type'] == 'save_entry') {
      final ser = (normalized['serial'] ?? (normalized['data'] is Map ? normalized['data']['serial'] : null))?.toString().trim() ?? '';
      final lastDash = ser.lastIndexOf('-');
      if (lastDash > 0) {
        final prefix = ser.substring(0, lastDash);
        final seqStr = ser.substring(lastDash + 1);
        final seq = int.tryParse(seqStr);
        if (seq != null && seq > 1 && seq <= 999) {
          const padWidth = 3;
          bool hasPriorPending = false;
          final from = (seq - 20) > 1 ? seq - 20 : 1;
          for (int i = from; i < seq; i++) {
            final priorSerial = '$prefix-${i.toString().padLeft(padWidth, '0')}';
            if (isRecordPendingOrUnacked('save_entry|$priorSerial')) {
              hasPriorPending = true;
              break;
            }
          }
          if (hasPriorPending) {
            unawaited(_flushOutbox());
          }
        }
      }
    }

    try {
      _channel!.sink.add(encoded);
      if (kDebugMode) print('[RealtimeManager] → ${normalized['event_type']} (msgId=${normalized['_messageId']})');
      // Fast 2.5s un-ACKed check for critical dispensary messages: if a LAN micro-drop
      // swallowed this frame without throwing on sink.add, re-flush in 2.5s instead of waiting!
      if (outboxKey != null && _isCriticalOutboxItem(normalized)) {
        final trackedKey = outboxKey;
        Timer(const Duration(milliseconds: 2500), () {
          if (!_isConnected || !_serverIdentified) return;
          try {
            if (Hive.isBoxOpen(_outboxBox) && Hive.box(_outboxBox).containsKey(trackedKey)) {
              _flushOutbox();
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] Socket transmission exception: $e → queuing to pending and reconnecting');
      _pendingMessages.add(normalized);
      _handleDisconnect();
    }
  }

  // ── [BUG-1] Send pending directly to channel (no outbox re-write) ──────────
  void _sendPendingMessages() {
    if (_pendingMessages.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(_pendingMessages);
    _pendingMessages.clear();

    for (final msg in pending) {
      final isPing = msg['event_type'] == 'ping' || msg['type'] == 'ping';
      if (isPing) continue;

      try {
        _channel!.sink.add(jsonEncode(msg));
        if (kDebugMode) print('[RealtimeManager] pending→ ${msg['event_type']} (msgId=${msg['_messageId']})');
      } catch (e) {
        if (kDebugMode) print('[RealtimeManager] Pending send failed: $e');
        // Message is still in outbox; will be recovered on next reconnect.
      }
    }
  }

  // ── [FIX-P2] Flush Hive outbox on reconnect ────────────────────────────────
  Future<void> _flushOutbox() async {
    if (!_isConnected || !_serverIdentified || _channel == null) return;
    // Started from identify, the 30 s sweep, its own 2 s follow-up and forceFlushAndCatchUp;
    // overlapping passes sent every item twice and pushed items to the failed box early.
    if (_outboxFlushing) {
      // Not dropped: this pass works on the keys it read at its start, so an item queued since
      // (the token sent into a dead socket just before a reconnect) would wait for the 30 s sweep.
      _outboxFlushAgain = true;
      return;
    }
    _outboxFlushing = true;

    try {
      if (!Hive.isBoxOpen(_outboxBox)) return;
      final box = Hive.box(_outboxBox);
      if (box.isEmpty) return;

      final todayDateKey = CampSessionService.resolveShiftAndDateKey().dateKey;
      final cutoff   = DateTime.now().subtract(const Duration(hours: 12));
      final toDelete = <dynamic>[];

      if (kDebugMode) print('[RealtimeManager] Flushing outbox: ${box.length} items');

      // Pre-pass: for each business record keep only its NEWEST queued copy; older duplicates
      // (left over from earlier versions or sessions) are dropped without being sent.
      final latestByLogical = <String, ({dynamic key, String ts})>{};
      final queuedAt = <dynamic, String>{};
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        final ts = (raw['_outboxTimestamp'] ?? raw['createdAt'] ?? '').toString();
        queuedAt[key] = ts;
        final lk = _logicalKey(raw);
        if (lk == null) continue;
        final cur = latestByLogical[lk];
        if (cur == null || ts.compareTo(cur.ts) >= 0) latestByLogical[lk] = (key: key, ts: ts);
      }

      var sentThisPass = 0;
      const maxPerPass = 250; // never push thousands of frames at once; the rest follows shortly

      // Oldest and strictly in-order first:
      // 1. Tokens sharing the same session/camp prefix are sorted strictly by token sequence (001 before 002 before 005).
      // 2. Lifecycle ordering: token creation before prescription before dispense.
      // 3. Fallback: queued timestamp.
      final orderedKeys = box.keys.toList()
        ..sort((a, b) {
          final rawA = box.get(a);
          final rawB = box.get(b);
          if (rawA is Map && rawB is Map) {
            final typeA = (rawA['event_type'] ?? rawA['type'])?.toString() ?? '';
            final typeB = (rawB['event_type'] ?? rawB['type'])?.toString() ?? '';
            final serA = (rawA['serial'] ?? (rawA['data'] is Map ? rawA['data']['serial'] : null) ?? '').toString().trim().toUpperCase();
            final serB = (rawB['serial'] ?? (rawB['data'] is Map ? rawB['data']['serial'] : null) ?? '').toString().trim().toUpperCase();

            // Strict sequence sort for token creation
            if (typeA == 'save_entry' && typeB == 'save_entry' && serA.isNotEmpty && serB.isNotEmpty) {
              final lastDashA = serA.lastIndexOf('-');
              final lastDashB = serB.lastIndexOf('-');
              if (lastDashA > 0 && lastDashB > 0) {
                final prefixA = serA.substring(0, lastDashA);
                final prefixB = serB.substring(0, lastDashB);
                if (prefixA == prefixB) {
                  final seqA = int.tryParse(serA.substring(lastDashA + 1)) ?? 0;
                  final seqB = int.tryParse(serB.substring(lastDashB + 1)) ?? 0;
                  if (seqA != seqB) return seqA.compareTo(seqB);
                }
              }
            }

            // Lifecycle sort for the same serial: token -> prescription -> dispense
            if (serA.isNotEmpty && serA == serB) {
              int priority(String t) {
                if (t == 'save_entry' || t == 'token_created') return 1;
                if (t == 'save_prescription' || t == 'prescription_created') return 2;
                if (t == 'dispense_completed') return 3;
                return 4;
              }
              final pA = priority(typeA);
              final pB = priority(typeB);
              if (pA != pB) return pA.compareTo(pB);
            }
          }
          return (queuedAt[a] ?? '').compareTo(queuedAt[b] ?? '');
        });

      for (final key in orderedKeys) {
        final raw = box.get(key);
        if (raw is! Map) { toDelete.add(key); continue; }

        final lk = _logicalKey(raw);
        if (lk != null && latestByLogical[lk]?.key != key) {
          toDelete.add(key); // superseded by a newer copy of the same record
          continue;
        }
        if (sentThisPass >= maxPerPass) {
          Future.delayed(const Duration(seconds: 2), _flushOutbox);
          break;
        }

        final item = Map<String, dynamic>.from(raw);

        // Expire non-critical items from previous days or older than 12 hours.
        // Critical business entities (tokens, prescriptions, dispenses, patients, donations) MUST NOT be discarded.
        final isCriticalEvent = _isCriticalOutboxItem(item);

        final itemDateKey = (item['dateKey'] ?? item['data']?['dateKey'])?.toString().trim();
        final tsStr    = (item['_outboxTimestamp'] ?? item['createdAt'])?.toString();
        final itemTime = tsStr != null ? DateTime.tryParse(tsStr) : null;

        final isStale = !isCriticalEvent && (
            (itemDateKey != null && itemDateKey.isNotEmpty && itemDateKey != todayDateKey) ||
            (itemTime != null && (itemTime.isBefore(cutoff) || itemTime.day != DateTime.now().day))
        );

        if (isStale) {
          if (kDebugMode) print('[RealtimeManager] 🗑️ Discarding stale/yesterday outbox item: key=$key dateKey=$itemDateKey');
          toDelete.add(key);
          continue;
        }

        // A critical item the server has not ACKed after many sends stays here (it used to be
        // parked in the failed box, retried only every 5 min or on logout/restart — why tokens
        // "needed a trigger"). From then on it is re-sent at most every 30 s, not every sweep.
        if (_isCriticalOutboxItem(item) &&
            _outboxCounter('s', key, item['_outboxSends']) >= _criticalSlowAfterSends) {
          final last = _outboxLastSendAt[key];
          if (last != null && DateTime.now().difference(last) < _criticalSlowResendEvery) {
            continue;
          }
        }

        final msg = Map<String, dynamic>.from(item);
        msg.remove('_outboxKey');
        msg.remove('_outboxTimestamp');
        final retryCount = _outboxCounter('r', key, msg.remove('_outboxRetryCount'));
        msg.remove('_outboxSends');
        // Not marked _resent/_isReplay: the server forwards a resend only when it never handled
        // the first copy (duplicates are ACKed and dropped there), so for the other desks it is
        // a first delivery. The replay flags made them skip the stock deduction and alerts.
        msg['_outboxResend'] = true;
        msg['_timestamp'] = DateTime.now().millisecondsSinceEpoch;

        if (kDebugMode) {
        }

        try {
          _channel!.sink.add(jsonEncode(msg));
          sentThisPass++;
          // sink.add does not fail on a socket that died silently, so a sent message is not
          // a delivered one. Messages with an id stay until the server's message_ack removes
          // them (_removeFromOutboxByMessageId); deleting them here lost whatever was flushed
          // into a dead link during a LAN blip. A message the server never acknowledges is
          // set aside after many tries so it does not resend forever.
          final hasAckId = (msg['_messageId'] ?? '').toString().isNotEmpty;
          if (!hasAckId) {
            toDelete.add(key);
          } else {
            final sends = _outboxCounter('s', key, item['_outboxSends']) + 1;
            // Tokens, prescriptions, dispenses and the like are never set aside: the failed
            // box was retried only every 5 minutes, so such a message reached the other desks
            // many minutes late. They keep being re-sent with every sweep until the server
            // ACKs them (the server parks a message that keeps failing and ACKs it, so this
            // ends). Only non-critical messages are set aside.
            if (sends >= _maxUnackedSends && !_isCriticalOutboxItem(item)) {
              _moveToFailedOutbox(key, item, reason: 'no server acknowledgement after $sends sends');
              toDelete.add(key);
            } else {
              // Critical items are never parked: after [_criticalSlowAfterSends] sends they are
              // throttled to one send per [_criticalSlowResendEvery] (see the check above).
              _setOutboxCounter('s', key, sends);
              _outboxLastSendAt[key] = DateTime.now();
              if (_outboxLastSendAt.length > 5000) _outboxLastSendAt.remove(_outboxLastSendAt.keys.first);
            }
          }
          await Future.delayed(const Duration(milliseconds: 20));
        } catch (e) {
          if (kDebugMode) print('[RealtimeManager] Outbox resend failed: $e');

          // [FAIL-BOX] Track consecutive failures; move to failed box after max.
          final newRetryCount = retryCount + 1;
          // The channel broke: a critical message stays in the outbox and goes out with the
          // first flush after the reconnect (not the 5-minute failed-box retry).
          if (newRetryCount >= _maxOutboxRetries && !_isCriticalOutboxItem(item)) {
            _moveToFailedOutbox(key, item, reason: e.toString());
            toDelete.add(key);
          } else if (newRetryCount >= 30) {
            _moveToFailedOutbox(key, item, reason: 'critical item consecutive send failures ($newRetryCount): $e');
            toDelete.add(key);
          } else {
            // Update retry count and stop flushing (channel is down).
            _setOutboxCounter('r', key, newRetryCount);
          }
          break; // Channel is broken; stop the loop.
        }
      }

      for (final k in toDelete) {
        try { box.delete(k); } catch (_) {}
        _clearOutboxCounters(k);
      }
      // Hive only appends; after a big clean-up the dead records stay in the file until compacted.
      if (toDelete.length >= 100) unawaited(box.compact().catchError((Object _) {}));

      if (kDebugMode) {
        print('[RealtimeManager] Outbox flush done. Cleared: ${toDelete.length}, remaining: ${box.length}');
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] _flushOutbox error: $e');
    } finally {
      _outboxFlushing = false;
      if (_outboxFlushAgain) {
        _outboxFlushAgain = false;
        Future.delayed(const Duration(milliseconds: 300), _flushOutbox);
      }
    }
  }

  /// Business records (tokens, prescriptions, dispenses, patients, donations, ...) that are
  /// never discarded as stale, however old: they must reach the server.
  static bool _isCriticalOutboxItem(Map item) {
    final eventType = (item['event_type'] ?? item['type'])?.toString() ?? '';
    return eventType == RealtimeEvents.saveEntry ||
        eventType == RealtimeEvents.savePrescription ||
        eventType == RealtimeEvents.dispenseCompleted ||
        eventType == RealtimeEvents.savePatient ||
        eventType == 'migrate_patient_key' ||
        eventType == 'save_donation' ||
        eventType == RealtimeEvents.saveEmployee ||
        eventType == 'save_dispensary_charge' ||
        eventType == 'save_dispensary_record' ||
        eventType == 'update_serial_status' ||
        eventType == 'token_created' ||
        eventType == 'prescription_created' ||
        eventType == 'save_stock_item' ||
        eventType == 'delete_stock_item' ||
        eventType == 'token_reversal_approved' ||
        eventType == 'request_created' ||
        eventType == 'request_approved' ||
        eventType == 'request_rejected' ||
        eventType == 'token_exception_request' ||
        eventType == 'token_exception_approved' ||
        eventType == 'restriction_removed' ||
        // Deletes too: dropping one after 12 h or at day change left the record alive on
        // the other desks.
        eventType == RealtimeEvents.deleteEntry ||
        eventType == RealtimeEvents.deletePrescription ||
        eventType == RealtimeEvents.deletePatient;
  }

  // ── [FAIL-BOX] Move an entry to the failed outbox ─────────────────────────
  void _moveToFailedOutbox(dynamic originalKey, Map<String, dynamic> item, {String? reason}) {
    try {
      if (!Hive.isBoxOpen(_failedOutboxBox)) return;
      final failedBox = Hive.box(_failedOutboxBox);
      // Keyed by the message id: an item that fails again overwrites its earlier copy instead of
      // adding another full one (every move used to append a new record to the file).
      final msgId = (item['_messageId'] ?? '').toString();
      final failedKey = msgId.isNotEmpty ? 'failed_$msgId' : 'failed_${DateTime.now().microsecondsSinceEpoch}';
      final failedEntry = Map<String, dynamic>.from(item);
      failedEntry.remove('_outboxSends');
      failedEntry.remove('_outboxRetryCount');
      _clearOutboxCounters(originalKey);
      failedEntry['_failedAt']     = DateTime.now().toIso8601String();
      failedEntry['_failReason']   = reason?.substring(0, reason.length.clamp(0, 300));
      failedEntry['_originalKey']  = originalKey?.toString();
      failedBox.put(failedKey, failedEntry);

      if (kDebugMode) {
        print('[RealtimeManager] ⚠️ Moved to failed outbox: ${item['event_type']} '
            'msgId=${item['_messageId']} key=$failedKey');
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] _moveToFailedOutbox error: $e');
    }
  }

  // ── [FAIL-BOX] Retry failed outbox on new connection ──────────────────────
  // The 30 s sweep retries at most every 5 minutes: each retry moves every failed item (full
  // payload) into the outbox and back after 20 more sends, which rewrote both files nonstop on
  // a desk whose server never ACKed. A new connection or a manual sync retries at once.
  DateTime? _lastFailedRetryAt;

  void _retryFailedOutbox({bool force = false}) {
    final now = DateTime.now();
    if (!force && _lastFailedRetryAt != null && now.difference(_lastFailedRetryAt!) < const Duration(minutes: 5)) {
      return;
    }
    _lastFailedRetryAt = now;
    try {
      if (!Hive.isBoxOpen(_failedOutboxBox) || !Hive.isBoxOpen(_outboxBox)) return;
      final failedBox = Hive.box(_failedOutboxBox);
      if (failedBox.isEmpty) return;

      final box     = Hive.box(_outboxBox);
      final todayDateKey = CampSessionService.resolveShiftAndDateKey().dateKey;
      final cutoff  = DateTime.now().subtract(const Duration(hours: 12));
      int moved = 0;

      for (final key in failedBox.keys.toList()) {
        final raw = failedBox.get(key);
        if (raw is! Map) { failedBox.delete(key); continue; }

        final item = Map<String, dynamic>.from(raw);

        // Expire entries older than 12 h or from previous date
        final itemDateKey = (item['dateKey'] ?? item['data']?['dateKey'])?.toString().trim();
        final tsStr = (item['_outboxTimestamp'] ?? item['_failedAt'])?.toString();
        final ts    = tsStr != null ? DateTime.tryParse(tsStr) : null;
        // Same exemption as _flushOutbox: a prescription or token that failed in the evening
        // was deleted here on the next connect.
        final isStale = !_isCriticalOutboxItem(item) &&
            ((itemDateKey != null && itemDateKey.isNotEmpty && itemDateKey != todayDateKey) ||
                (ts != null && (ts.isBefore(cutoff) || ts.day != DateTime.now().day)));

        if (isStale) {
          failedBox.delete(key);
          continue;
        }

        // Reset failure metadata and move back to main outbox.
        item.remove('_failedAt');
        item.remove('_failReason');
        item.remove('_originalKey');
        item.remove('_outboxRetryCount');
        item.remove('_outboxSends');
        item['_outboxTimestamp']  = item['_outboxTimestamp'] ?? DateTime.now().toIso8601String();
        // Keyed by its message id again, so the server's ACK finds and removes it (a generated
        // key was missed by the ACK lookup, and the item bounced between the boxes forever).
        final msgId = (item['_messageId'] ?? '').toString();
        final newKey = msgId.isNotEmpty ? msgId : 'outbox_retry_${DateTime.now().microsecondsSinceEpoch}';
        item['_outboxKey'] = newKey;
        _clearOutboxCounters(newKey);
        box.put(newKey, item);
        failedBox.delete(key);
        moved++;
      }

      if (moved > 0 && kDebugMode) {
        print('[RealtimeManager] ♻️ Moved $moved failed entries back to outbox for retry');
      }
    } catch (e) {
      if (kDebugMode) print('[RealtimeManager] _retryFailedOutbox error: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  /// Drops older prescription copies nested inside an embedded prescription (both in the
  /// message and in its data), in and out: they grew every token by a level per round trip.
  static void _flattenNestedPrescriptions(Map<String, dynamic> message) {
    try {
      LocalStorageService.flattenEmbeddedPrescription(message);
      final data = message['data'];
      if (data is Map) LocalStorageService.flattenEmbeddedPrescription(data);
    } catch (_) {}
  }

  Map<String, dynamic> _normalizeMessage(Map<String, dynamic> original) {
    final copy = Map<String, dynamic>.from(original);

    copy['_clientId']     ??= _clientId;
    copy['_senderRole']   ??= _role;
    copy['_senderBranch'] ??= _branchId;
    copy['_username']     ??= _username ?? _role;
    copy['event_type']    ??= copy['type'] ?? 'activity';

    copy['_timestamp']      = DateTime.now().millisecondsSinceEpoch;
    copy['_messageId']    ??= _generateMessageId();

    if (_branchId != null && !copy.containsKey('branchId')) {
      copy['branchId'] = _branchId;
    }

    if (copy['data'] is Map) {
      final data = Map<String, dynamic>.from(copy['data'] as Map);
      if (data.containsKey('branchId') && (copy['branchId'] == null || copy['branchId'].toString().isEmpty)) {
        copy['branchId'] = data['branchId'];
      }
      if (copy['branchId'] != null) {
        data['branchId'] ??= copy['branchId'];
      }
      copy['data'] = data;
    }
    // After copying 'data': flattening must not change the caller's (often a Hive record's) map.
    _flattenNestedPrescriptions(copy);

    return Map<String, dynamic>.from(_sanitizeForRealtime(copy) as Map);
  }

  static dynamic _sanitizeForRealtime(dynamic value, [int depth = 0]) {
    if (value == null) return null;
    if (depth > 10) return value.toString();
    if (value is String || value is num || value is bool) return value;
    if (value is DateTime) return value.toIso8601String();
    final typeName = value.runtimeType.toString();
    if (typeName.contains('Timestamp')) {
      try {
        final dt = (value as dynamic).toDate();
        if (dt is DateTime) return dt.toIso8601String();
      } catch (_) {}
      return DateTime.now().toIso8601String();
    }
    if (typeName.contains('FieldValue')) {
      return DateTime.now().toIso8601String();
    }
    if (value is Map) {
      final res = <String, dynamic>{};
      value.forEach((k, v) {
        res[k.toString()] = _sanitizeForRealtime(v, depth + 1);
      });
      return res;
    }
    if (value is Iterable) {
      return value.map((e) => _sanitizeForRealtime(e, depth + 1)).toList();
    }
    return value.toString();
  }

  String _generateMessageId() => const Uuid().v4();

  // ── Route incoming ─────────────────────────────────────────────────────────
  void _routeIncoming(Map<String, dynamic> decoded) {
    final type     = decoded['event_type'] as String?;
    final data     = decoded['data'] as Map<String, dynamic>? ?? decoded;
    final senderId = decoded['_clientId']?.toString() ?? '';

    if (senderId.isNotEmpty && senderId == _clientId) {
      if (kDebugMode) print('[RealtimeManager] Ignoring own echo: $type');
      return;
    }

    _flattenNestedPrescriptions(decoded);

    final msgBranch = (decoded['branchId'] ?? decoded['_senderBranch'])
        ?.toString().toLowerCase().trim();
    final myBranch = _branchId?.toLowerCase().trim();

    final isPushedFromServer = decoded['_serverPush'] == true ||
        decoded['isCatchUp'] == true ||
        decoded['_catchUp'] == true;

    final isUniversalBranch = isPushedFromServer ||
        msgBranch == null ||
        msgBranch.isEmpty ||
        msgBranch == 'all' ||
        msgBranch == 'default' ||
        myBranch == null ||
        myBranch.isEmpty ||
        myBranch == 'all' ||
        myBranch == 'default' ||
        CampSessionService.areBranchesMatching(msgBranch, myBranch);

    if (!isUniversalBranch) {
      return;
    }

    UiStallMonitor.mark("lan in: ${decoded['event_type'] ?? '?'}");
    // One message at a time, in arrival order. Unserialized, a catch-up burst ran the entry,
    // prescription and dispense handlers of one token concurrently and their read-modify-write
    // of the same record interleaved at each await.
    // Bounded per message: a handler stuck on a Hive open or an offline Firestore call would
    // otherwise hold every later LAN message behind it. It keeps running; it is just not ACKed.
    final routed = _routeChain
        .then((_) => RealtimeRouter.routeMessage(decoded).timeout(const Duration(seconds: 20)))
        .then<bool>((_) => true)
        .catchError((Object e, StackTrace st) {
      if (kDebugMode) print('[RealtimeManager] RealtimeRouter error: $e\n$st');
      return false;
    });
    _routeChain = routed;

    // Event-log position: advanced only once the event was applied.
    final logSeq = decoded['_logSeq'];
    if (logSeq != null) {
      final logEpoch = decoded['_logEpoch'];
      unawaited(routed.then((ok) {
        if (ok) _noteLogPosition(logSeq, logEpoch);
      }));
    }

    if (type == 'save_stock_item') {
      final isCatchUp = decoded['isCatchUp'] == true || decoded['_isReplay'] == true;
      if (!isCatchUp) {
        final medicineId = (data['id'] ?? data['medicineId'] ?? data['docId'])?.toString().trim() ?? '';
        final version = (data['updatedAt'] ?? data['lastUpdated'] ?? data['createdAt'] ?? '').toString();
        if (medicineId.isNotEmpty) {
          try {
            final ackMsg = {
              'event_type': 'ack_stock_items',
              'items':      [{'medicineId': medicineId, 'version': version}],
              '_clientId':  _clientId,
              '_timestamp': DateTime.now().millisecondsSinceEpoch,
              '_immediate': true,
            };
            _channel?.sink.add(jsonEncode(ackMsg));
            if (kDebugMode) print('[RealtimeManager] ⚡ Immediate stock ACK: $medicineId v=$version');
          } catch (_) {}
        }
      }
    } else if (type != null && _immAckEvents.contains(type)) {
      final serial = data['serial']?.toString().trim() ?? '';
      if (serial.isNotEmpty) {
        // Sent once the router has applied it (not on receipt: a dropped or failed message
        // was still reported as delivered), without waiting for the 5-second batch.
        unawaited(routed.then((ok) {
          if (!ok) return;
          try {
            final ackMsg = {
              'event_type': 'ack_serials',
              'serials':    [serial],
              '_clientId':  _clientId,
              '_timestamp': DateTime.now().millisecondsSinceEpoch,
              '_immediate': true,
            };
            _channel?.sink.add(jsonEncode(ackMsg));
            if (kDebugMode) print('[RealtimeManager] ⚡ ACK: $serial ($type)');
          } catch (_) {
            // Fallback: add to batch queue.
            _pendingAckSerials.add(serial);
          }
        }));
      }
    }

    // [FIX-P3] Also queue ACK via batch timer for server-pushed entries (safety net).
    final isServerPush = decoded['_serverPush'] == true;
    if (isServerPush && (type == 'save_entry' || type == 'token_created')) {
      final serial = data['serial']?.toString().trim() ?? '';
      if (serial.isNotEmpty) {
        // Only once applied: the server counts an ACKed serial as delivered.
        unawaited(routed.then((ok) {
          if (ok) _pendingAckSerials.add(serial);
        }));
      }
    }

    _messageController.add({
      'event_type': type,
      'data':       data,
      'decoded':    decoded,
      // The screens read the sender and the catch-up flags at the top level of the event
      // (event['_clientId'], event['_serverPush'], ...). They only existed under 'decoded', so
      // own echoes and catch-up copies looked like fresh edits: popups on every catch-up, and a
      // replayed old prescription replaced the doctor's on-screen medicines.
      for (final k in const ['_clientId', '_serverPush', 'isCatchUp', '_isReplay', '_resent', '_outboxResend'])
        if (decoded[k] != null) k: decoded[k],
    });
  }

  // ── Dispose ────────────────────────────────────────────────────────────────
  Future<void> dispose() async {
    _connectGen++; // invalidate any pending handshake watchdog
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _ackFlushTimer?.cancel();
    // Logout / re-initialize: stop the sweep (it restarted itself here and kept asking for
    // rediscovery after the user had left the screen). initialize() starts it again.
    _disposedSweep = true;
    _outboxSweepTimer?.cancel();
    _outboxSweepTimer = null;
    _channelSub?.cancel();
    try {
      // Never block on closing: a half-open (SYN_SENT) socket can hang ~20s.
      await _channel?.sink.close(ws_status.normalClosure).timeout(const Duration(seconds: 1), onTimeout: () {});
    } catch (_) {}

    _channel          = null;
    _channelSub       = null;
    _isConnected      = false;
    _serverIdentified = false;
    _flushedOnConnect = false;
    _reconnectAttempts = 0;
    _pendingMessages.clear();
    _lastPong         = null;
    _pendingAckSerials.clear();

    if (kDebugMode) print('[RealtimeManager] Disposed');
  }
}

/// Reads Firestore Timestamps (typeId 100, as registered in main.dart) inside the outbox
/// repair isolate, which has its own Hive registry.
class _RepairTimestampAdapter extends TypeAdapter<Timestamp> {
  @override
  final int typeId = 100;

  @override
  Timestamp read(BinaryReader reader) {
    final seconds = reader.readInt();
    final nanoseconds = reader.readInt();
    return Timestamp(seconds, nanoseconds);
  }

  @override
  void write(BinaryWriter writer, Timestamp obj) {
    writer.writeInt(obj.seconds);
    writer.writeInt(obj.nanoseconds);
  }
}
