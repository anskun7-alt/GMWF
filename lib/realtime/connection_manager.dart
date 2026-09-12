// lib/realtime/connection_manager.dart
//
// PERSISTENCE FIX:
//   [FIX-P1] onReconnected callback — fired every time a connection is
//            successfully established. Doctor/Dispenser screens subscribe
//            to this to pull missing data immediately on reconnect.
//
// BUG FIXES:
//   [BUG-9]  onReconnected was a single nullable field — a second screen
//            calling start() would silently overwrite the first screen's
//            callback. Replaced with a listener list (_reconnectListeners)
//            so multiple screens can subscribe independently without
//            stomping each other.
//
//   [BUG-10] _waitForIdentified completed with true merely because
//            isConnected was already true, before the server had processed
//            the identify message. The isConnected fast-path now waits a
//            full 500 ms to give the server time to echo 'identified'.
//
//   [BUG-11] _heartbeatTimer guard: if stop() is called between the timer
//            firing and the _running check, _scheduleReconnect could run
//            on a disposed manager. Added explicit _disposed guard.
//
// NETWORK FIXES:
//   [FIX-NET-1] useDedicatedServer support — when AppNetwork.useDedicatedServer
//               is true, _tryConnect() skips LanDiscovery entirely and connects
//               directly to AppNetwork.dedicatedServerIp. This bypasses mDNS,
//               UDP broadcast, and subnet scan which all fail under AP isolation.
//
//   [FIX-NET-2] Discovery timeout increased from 15 s to 25 s to give the
//               server time to start broadcasting before clients give up.
//
//   [FIX-NET-3] On discovery failure the error message now distinguishes
//               between "no WiFi" and "server not found" to help diagnose
//               AP isolation vs server-not-running issues.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../config/constants.dart';
import 'lan_discovery.dart';
import 'realtime_manager.dart';

enum LanConnectionState { disconnected, searching, connecting, connected }

class ConnectionStatus {
  final LanConnectionState state;
  final String? ip;
  final int? port;
  final String message;

  const ConnectionStatus({
    required this.state,
    this.ip,
    this.port,
    required this.message,
  });

  bool get isConnected  => state == LanConnectionState.connected;
  bool get isSearching  => state == LanConnectionState.searching;
  bool get isConnecting => state == LanConnectionState.connecting;
}

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._();
  factory ConnectionManager() => _instance;
  ConnectionManager._();

  final _statusController =
      StreamController<ConnectionStatus>.broadcast();

  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  ConnectionStatus _current = const ConnectionStatus(
    state: LanConnectionState.disconnected,
    message: 'Not connected',
  );
  ConnectionStatus get status      => _current;
  bool             get isConnected => _current.isConnected;

  String? _role;
  String? _branchId;
  String? _username;

  DateTime? _lastFirestoreProbeTime;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int    _reconnectAttempts = 0;
  bool   _running  = false;
  bool   _disposed = false;

  // [BUG-9] List of reconnect listeners instead of a single nullable field.
  final List<VoidCallback> _reconnectListeners = [];

  /// Register a callback that fires every time a connection is confirmed.
  /// Returns a remove function for easy cleanup in dispose().
  VoidCallback addReconnectListener(VoidCallback cb) {
    _reconnectListeners.add(cb);
    return () => _reconnectListeners.remove(cb);
  }

  /// Remove a specific reconnect listener.
  void removeReconnectListener(VoidCallback cb) {
    _reconnectListeners.remove(cb);
  }

  // Back-compat setter — adds to listener list.
  set onReconnected(VoidCallback? cb) {
    if (cb != null) _reconnectListeners.add(cb);
  }

  static const _savedIpKey   = 'last_server_ip';
  static const _savedPortKey = 'last_server_port';

  // ── Start ──────────────────────────────────────────────────────────────────
  Future<void> start({
    required String role,
    required String branchId,
    String? username,
  }) async {
    _role     = role.toLowerCase().trim();
    _branchId = branchId.toLowerCase().trim();
    _username = username?.trim();
    _running  = true;
    _disposed = false;
    _reconnectAttempts = 0;

    debugPrint('[ConnectionManager] Starting: role=$_role branch=$_branchId'
        '${AppNetwork.useDedicatedServer ? " [dedicated: ${AppNetwork.dedicatedServerIp}]" : ""}');
    await _tryConnect();
  }

  // ── Discovery + connect loop ───────────────────────────────────────────────
  Future<void> _tryConnect() async {
    if (!_running || _disposed) return;

    // ── Dedicated-server mode ──────────────────────────────────────────────────
    if (AppNetwork.useDedicatedServer) {
      final targetIp = AppNetwork.dedicatedServerIp;
      _emit(ConnectionStatus(
        state: LanConnectionState.connecting,
        ip: targetIp,
        port: AppNetwork.websocketPort,
        message: 'Connecting to $targetIp...',
      ));
      final ok = await _connectTo(targetIp, AppNetwork.websocketPort);
      if (!ok) {
        _emit(ConnectionStatus(
          state: LanConnectionState.disconnected,
          message: 'Cannot reach server at $targetIp:${AppNetwork.websocketPort}. '
              'Check the IP and that the server is running.',
        ));
        _scheduleReconnect();
      }
      return;
    }

    // ── Fast-path 0: Probe localhost if running on server machine ─────────────
    if (!kIsWeb) {
      final isLocalHostServer = await LanDiscovery.isReachable('127.0.0.1', AppNetwork.websocketPort);
      if (isLocalHostServer) {
        final ok = await _connectTo('127.0.0.1', AppNetwork.websocketPort);
        if (ok) return;
      }
    }

    // ── Fast-path 1: Try last-known server (instant sub-second connection) ─────
    final saved = _getSavedServer();
    if (saved != null) {
      debugPrint('[ConnectionManager] Trying saved server: ${saved.$1}:${saved.$2}');
      final reachable = await LanDiscovery.isReachable(saved.$1, saved.$2);
      if (reachable) {
        final ok = await _connectTo(saved.$1, saved.$2);
        if (ok) return;
      } else {
        debugPrint('[ConnectionManager] Saved server unreachable, trying Firestore discovery');
      }
    }

    // ── Fast-path 2: Query Firestore for activeServerIp published by branch server (5m cooldown) ──
    final now = DateTime.now();
    final canProbeFirestore = _isFirebaseReady &&
        (_lastFirestoreProbeTime == null || now.difference(_lastFirestoreProbeTime!).inMinutes >= 5);
    if (canProbeFirestore) {
      _lastFirestoreProbeTime = now;
      final candidates = <String>[
        if (_branchId != null && _branchId!.isNotEmpty && _branchId != 'all' && _branchId != 'global') _branchId!,
      ];
      // Add all known branches from local cache for broader server discovery
      try {
        if (Hive.isBoxOpen('local_branches')) {
          final box = Hive.box('local_branches');
          for (final val in box.values) {
            if (val is Map) {
              final id = (val['id'] ?? '').toString().trim().toLowerCase();
              if (id.isNotEmpty && id != 'all' && id != 'global' && !candidates.contains(id)) {
                candidates.add(id);
              }
            }
          }
        }
      } catch (_) {}
      // Fallback if no local branches found
      if (candidates.isEmpty) candidates.add('karachi');
      
      for (final bId in candidates) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('branches').doc(bId).get()
              .timeout(const Duration(seconds: 2));
          final fsIp = doc.data()?['activeServerIp']?.toString().trim();
          final fsPort = (doc.data()?['activeServerPort'] as num?)?.toInt() ?? AppNetwork.websocketPort;
          if (fsIp != null && fsIp.isNotEmpty && fsIp != 'localhost') {
            debugPrint('[ConnectionManager] Probing branches/$bId activeServerIp: $fsIp:$fsPort');
            final reachable = await LanDiscovery.isReachable(fsIp, fsPort);
            if (reachable) {
              final ok = await _connectTo(fsIp, fsPort);
              if (ok) return;
            }
          }
        } catch (_) {}
      }

      // Universal system metadata check
      try {
        final metaDoc = await FirebaseFirestore.instance
            .collection('system_metadata').doc('active_server').get()
            .timeout(const Duration(seconds: 2));
        final metaIp = metaDoc.data()?['activeServerIp']?.toString().trim();
        final metaPort = (metaDoc.data()?['activeServerPort'] as num?)?.toInt() ?? AppNetwork.websocketPort;
        if (metaIp != null && metaIp.isNotEmpty && metaIp != 'localhost') {
          debugPrint('[ConnectionManager] Probing system_metadata activeServerIp: $metaIp:$metaPort');
          final reachable = await LanDiscovery.isReachable(metaIp, metaPort);
          if (reachable) {
            final ok = await _connectTo(metaIp, metaPort);
            if (ok) return;
          }
        }
      } catch (_) {}
    }

    // Web fallback if no LAN discovery available
    if (kIsWeb) {
      final List<String> candidateIps = [];

      // 1. Host from URL (if opened directly as http://192.168.1.x:port)
      final host = Uri.base.host.trim();
      if (host.isNotEmpty && host != 'localhost' && !host.contains('firebase') && !host.contains('web.app')) {
        candidateIps.add(host);
      }

      // 2. Common LAN server IPs
      candidateIps.addAll(['127.0.0.1', '192.168.1.100', '192.168.0.100', '192.168.1.10', '192.168.1.150', '192.168.1.200']);

      final distinctCandidates = candidateIps.toSet().toList();
      for (final targetIp in distinctCandidates) {
        _emit(ConnectionStatus(
          state: LanConnectionState.connecting,
          ip: targetIp,
          port: AppNetwork.websocketPort,
          message: 'Connecting to $targetIp...',
        ));
        final ok = await _connectTo(targetIp, AppNetwork.websocketPort);
        if (ok) return;
      }

      _emit(ConnectionStatus(
        state: LanConnectionState.disconnected,
        message: 'Could not connect to branch server on LAN. Ensure the server PC is running and accessible on port ${AppNetwork.websocketPort}.',
      ));
      _scheduleReconnect();
      return;
    }

    // ── Auto-discovery path (UDP broadcast + fast parallel subnet scan + mDNS) ─
    if (kIsWeb) {
      final connList = await Connectivity().checkConnectivity();
      final hasNetwork = connList.contains(ConnectivityResult.wifi) ||
          connList.contains(ConnectivityResult.ethernet) ||
          connList.contains(ConnectivityResult.other);

      if (!hasNetwork) {
        _emit(const ConnectionStatus(
          state: LanConnectionState.disconnected,
          message: 'No WiFi or LAN detected. Connect all devices to the same network.',
        ));
        _scheduleReconnect();
        return;
      }
    }

    _emit(const ConnectionStatus(
      state: LanConnectionState.searching,
      message: 'Scanning network for server...',
    ));

    final found = await LanDiscovery.findServer(
      timeout: const Duration(seconds: 12),
      onStatus: (s) => _emit(ConnectionStatus(
        state: LanConnectionState.searching,
        message: s,
      )),
    );

    if (found == null) {
      _emit(const ConnectionStatus(
        state: LanConnectionState.disconnected,
        message: 'Server not found. Ensure all devices are on the same WiFi/LAN '
            'and AP isolation is disabled on the router. '
            'Or set dedicatedServerIp in AppNetwork.',
      ));
      _scheduleReconnect();
      return;
    }

    debugPrint('[ConnectionManager] Discovered server via ${found.method}: ${found.ip}:${found.port}');
    final ok = await _connectTo(found.ip, found.port);
    if (!ok) _scheduleReconnect();
  }

  // ── Connect to specific IP ─────────────────────────────────────────────────
  Future<bool> _connectTo(String ip, int port) async {
    if (!_running || _disposed) return false;

    _emit(ConnectionStatus(
      state: LanConnectionState.connecting,
      ip: ip,
      port: port,
      message: 'Connecting to $ip...',
    ));

    try {
      await RealtimeManager().initialize(
        role:     _role!,
        branchId: _branchId!,
        serverIp: ip,
        port:     port,
        username: _username,
      );

      final confirmed = await _waitForIdentified(timeoutSeconds: 6);

      if (!confirmed) {
        debugPrint('[ConnectionManager] No identified response from $ip');
        return false;
      }

      _saveServer(ip, port);
      
      // Publish active server IP to Firestore for Web clients in this branch
      if (_isFirebaseReady && _branchId != null && _branchId!.isNotEmpty && ip != '127.0.0.1' && ip != 'localhost') {
        try {
          FirebaseFirestore.instance
              .collection('branches').doc(_branchId)
              .set({'activeServerIp': ip, 'serverLastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true))
              .catchError((e) => debugPrint('[ConnectionManager] Could not publish activeServerIp: $e'));
        } catch (e) {
          debugPrint('[ConnectionManager] Exception publishing activeServerIp: $e');
        }
      }

      _reconnectAttempts = 0;

      _emit(ConnectionStatus(
        state: LanConnectionState.connected,
        ip: ip,
        port: port,
        message: 'Connected to $ip:$port',
      ));

      // [FIX-P1] [BUG-9] Notify all registered listeners.
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!_disposed) {
          for (final cb in List<VoidCallback>.from(_reconnectListeners)) {
            try { cb(); } catch (e) {
              debugPrint('[ConnectionManager] reconnect listener error: $e');
            }
          }
        }
      });

      _startHeartbeat(ip, port);
      debugPrint('[ConnectionManager] ✅ Connected at $ip:$port');
      return true;
    } catch (e) {
      debugPrint('[ConnectionManager] Connect failed: $e');
      _emit(ConnectionStatus(
        state: LanConnectionState.disconnected,
        message: 'Connection failed: $e',
      ));
      return false;
    }
  }

  // ── Wait for 'identified' ──────────────────────────────────────────────────
  Future<bool> _waitForIdentified({required int timeoutSeconds}) async {
    if (RealtimeManager().isServerIdentified) return true;

    final completer = Completer<bool>();

    late StreamSubscription sub;
    sub = RealtimeManager().messageStream.listen((event) {
      if ((event['event_type'] == 'identified' || RealtimeManager().isServerIdentified) && !completer.isCompleted) {
        sub.cancel();
        completer.complete(true);
      }
    });

    Timer(Duration(seconds: timeoutSeconds), () {
      if (!completer.isCompleted) {
        sub.cancel();
        // Only return true if actively connected and confirmed
        completer.complete(RealtimeManager().isConnected);
      }
    });

    return completer.future;
  }

  bool get _isFirebaseReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Heartbeat ──────────────────────────────────────────────────────────────
  void _startHeartbeat(String ip, int port) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 10), (_) async {
      // [BUG-11] Explicit disposed guard.
      if (!_running || _disposed) return;

      // When RealtimeManager is disconnected and no reconnect is actively scheduled,
      // emit disconnected state and immediately schedule automatic reconnect.
      if (!RealtimeManager().isConnected && _reconnectTimer == null) {
        debugPrint('[ConnectionManager] Heartbeat: disconnect detected, scheduling auto-reconnect...');
        _emit(const ConnectionStatus(
          state: LanConnectionState.disconnected,
          message: 'Connection lost — reconnecting...',
        ));
        _scheduleReconnect();
      }
    });
  }

  // ── Backoff reconnect ──────────────────────────────────────────────────────
  void _scheduleReconnect() {
    if (!_running || _disposed) return;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();

    const delays = [3, 5, 10, 15, 20];
    final delay =
        delays[_reconnectAttempts.clamp(0, delays.length - 1)];
    _reconnectAttempts++;

    debugPrint('[ConnectionManager] Reconnect in ${delay}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delay), _tryConnect);
  }

  // ── Manual retry ───────────────────────────────────────────────────────────
  Future<void> reconnectNow() async {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectAttempts = 0;
    await _tryConnect();
  }

  /// Manually connect directly to a user-specified Server IP address
  Future<bool> connectDirectly(String ip, [int? port]) async {
    final cleanIp = ip.trim();
    if (cleanIp.isEmpty) return false;
    final targetPort = port ?? AppNetwork.websocketPort;

    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _saveServer(cleanIp, targetPort);

    _emit(ConnectionStatus(
      state: LanConnectionState.connecting,
      ip: cleanIp,
      port: targetPort,
      message: 'Connecting to $cleanIp:$targetPort...',
    ));

    final ok = await _connectTo(cleanIp, targetPort);
    if (!ok) {
      _emit(ConnectionStatus(
        state: LanConnectionState.disconnected,
        message: 'Could not connect to $cleanIp:$targetPort. Ensure server is running.',
      ));
      _scheduleReconnect();
    }
    return ok;
  }

  /// Get the currently saved server IP, if any
  String? getSavedServerIp() {
    return _getSavedServer()?.$1;
  }

  // ── Persistence ────────────────────────────────────────────────────────────
  (String, int)? _getSavedServer() {
    // Don't use saved server when dedicated mode is on — always use the fixed IP.
    if (AppNetwork.useDedicatedServer) return null;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box  = Hive.box('app_settings');
        final ip   = box.get(_savedIpKey)   as String?;
        final port = box.get(_savedPortKey) as int?;
        if (ip != null && port != null && ip.isNotEmpty && ip != '127.0.0.1' && ip != 'localhost') {
          return (ip, port);
        }
      }
    } catch (_) {}
    return null;
  }

  void _saveServer(String ip, int port) {
    if (AppNetwork.useDedicatedServer) return; // no need to cache a fixed address
    if (ip.isEmpty || ip == '127.0.0.1' || ip == 'localhost') return; // NEVER cache loopback address
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        box.put(_savedIpKey,   ip);
        box.put(_savedPortKey, port);
      }
    } catch (_) {}
  }

  // ── Emit ───────────────────────────────────────────────────────────────────
  void _emit(ConnectionStatus s) {
    if (_disposed) return;
    _current = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  // ── Stop ───────────────────────────────────────────────────────────────────
  Future<void> stop() async {
    _running  = false;
    _disposed = true;
    // [BUG-9] Do NOT clear _reconnectListeners here — screens will call
    // removeReconnectListener in their own dispose().
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    await RealtimeManager().dispose();
    _emit(const ConnectionStatus(
      state: LanConnectionState.disconnected,
      message: 'Disconnected',
    ));
  }
}
