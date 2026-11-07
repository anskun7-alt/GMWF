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
import 'dart:convert';
import 'dart:io' as io;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../config/constants.dart';
import '../services/camp_session_service.dart';
import '../services/local_storage_service.dart';
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
  ConnectionStatus get status {
    final rm = RealtimeManager();
    if (rm.isConnected && rm.isServerIdentified) {
      final rmIp = rm.serverIp;
      final rmPort = rm.port;
      return ConnectionStatus(
        state: LanConnectionState.connected,
        ip: rmIp ?? _current.ip,
        port: rmPort,
        message: 'Connected to ${rmIp ?? _current.ip}:$rmPort',
      );
    }
    return _current;
  }
  bool get isConnected => status.isConnected;

  String? _role;
  String? _branchId;
  String? _username;

  DateTime? _lastFirestoreProbeTime;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
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

    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (!_running || _disposed) return;
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) {
        // After a Wi-Fi drop the old socket is often still "connected" (half-open) with no
        // frames arriving; without this the desk kept writing into it until the 30 s pong
        // timeout. A link that answered pings in the last 15 s is left alone.
        final staleLink = isConnected && !RealtimeManager().isLinkAlive;
        if ((!isConnected || staleLink) && !_discovering) {
          debugPrint('[ConnectionManager] ⚡ OS network restored (stale link: $staleLink) — reconnectNow()');
          reconnectNow();
        }
      } else if (!kIsWeb && (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS)) {
        // Unreliable on desktop (see _tryConnectInner): ignore instead of showing "Disconnected".
        debugPrint('[ConnectionManager] OS reported no network on desktop; ignoring (unreliable signal)');
      } else {
        debugPrint('[ConnectionManager] ⚠️ OS reports network disconnected');
        _emit(const ConnectionStatus(
          state: LanConnectionState.disconnected,
          message: 'No WiFi or LAN detected.',
        ));
      }
    });

    RealtimeManager().onNeedRediscovery = () {
      if (!_running || _disposed) return;
      // Do NOT re-arm the timer on every disconnect callback: doing so cancelled
      // the pending rediscovery over and over so it never actually ran.
      if (_discovering) return;
      if (_reconnectTimer != null && _reconnectTimer!.isActive) return;
      debugPrint('[ConnectionManager] RealtimeManager requested rediscovery after failed retries');
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(milliseconds: 300), () {
        _reconnectTimer = null;
        _tryConnect();
      });
    };

    // RealtimeManager also retries the last server on its own. When that succeeds (even while
    // LanDiscovery is scanning in the background), immediately mark the link up and run
    // reconnect listeners so pending offline work is pushed to the server right away.
    RealtimeManager().onConnected = (ip, port) {
      if (!_running || _disposed || _inConnectTo) return; // _connectTo handles its own success
      _stopPassiveBeaconWatch();
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _saveServer(ip, port);
      _onLinkUp(ip, port);
    };

    debugPrint('[ConnectionManager] Starting: role=$_role branch=$_branchId'
        '${AppNetwork.useDedicatedServer ? " [dedicated: ${AppNetwork.dedicatedServerIp}]" : ""}');

    final activeIp = _current.ip ?? RealtimeManager().serverIp;
    if (isConnected && activeIp != null) {
      debugPrint('[ConnectionManager] Already connected to $activeIp:${_current.port ?? RealtimeManager().port} — updating identity without rediscovery');
      await RealtimeManager().initialize(
        role: _role!,
        branchId: _branchId!,
        serverIp: activeIp,
        port: _current.port ?? RealtimeManager().port,
        username: _username,
      );
      _emit(status);
      return;
    }

    await _tryConnect();
  }

  // ── Discovery + connect loop ───────────────────────────────────────────────
  bool _discovering = false;
  bool _inConnectTo = false;
  io.RawDatagramSocket? _passiveBeaconSocket;

  void _stopPassiveBeaconWatch() {
    try {
      _passiveBeaconSocket?.close();
    } catch (_) {}
    _passiveBeaconSocket = null;
  }

  /// Listens for the server's 5s UDP broadcast while sitting in [_scheduleReconnect] backoff.
  /// When the server is the last PC to open, desks wake up and connect within <1 second of
  /// the server starting instead of waiting out the backoff + subnet scan cycle.
  Future<void> _startPassiveBeaconWatch() async {
    if (kIsWeb || !_running || _disposed || _discovering || RealtimeManager().hasServerLink) return;
    if (_passiveBeaconSocket != null) return;
    try {
      final socket = await io.RawDatagramSocket.bind(
        io.InternetAddress.anyIPv4,
        AppNetwork.udpBroadcastPort,
        reuseAddress: true,
      );
      if (!_running || _disposed || _discovering || RealtimeManager().hasServerLink) {
        socket.close();
        return;
      }
      _passiveBeaconSocket = socket;
      socket.listen((event) {
        if (event != io.RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true).trim();
        if (!msg.startsWith(AppNetwork.udpMessagePrefix)) return;
        final payload = msg.substring(AppNetwork.udpMessagePrefix.length);
        final parts = payload.split(':');
        if (parts.length < 2) return;
        final ip = parts[0].trim();
        final port = int.tryParse(parts[1].trim()) ?? AppNetwork.websocketPort;
        final beaconBranch = parts.length >= 3
            ? LocalStorageService.sanitizeBranchId(parts[2], fallback: '')
            : '';
        final myBranch = LocalStorageService.sanitizeBranchId(_branchId, fallback: '');
        if (beaconBranch.isNotEmpty &&
            myBranch.isNotEmpty &&
            beaconBranch != myBranch &&
            !CampSessionService.areBranchesMatching(beaconBranch, myBranch)) {
          return;
        }
        if (ip.isEmpty) return;
        // Verify reachability so a stale IP from a DHCP renewal does not hijack our connection
        unawaited(LanDiscovery.isReachable(ip, port).then((reachable) {
          if (!reachable || !_running || _disposed || RealtimeManager().hasServerLink) return;
          debugPrint('[ConnectionManager] ⚡ Passive UDP beacon heard & verified from $ip:$port — connecting immediately');
          _stopPassiveBeaconWatch();
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _reconnectAttempts = 0;
          // Only adopt the announcing server as "ours" when we have none yet or it IS ours.
          // Saving every heard beacon let a second server on the LAN (an old PC still running
          // GMWF as server) take desks over one by one: reception on one server, doctor on the
          // other. _tryConnect tries the saved server first and switches only if it is gone.
          final saved = _getSavedServer();
          if (saved == null || saved.$1 == ip) _saveServer(ip, port);
          unawaited(_tryConnect());
        }));
      }, onError: (_) {
        _stopPassiveBeaconWatch();
      }, onDone: () {
        _passiveBeaconSocket = null;
      });
    } catch (_) {
      // Port 53280 may already be bound on the server machine itself; safe to ignore.
    }
  }

  Future<void> _tryConnect() async {
    if (!_running || _disposed) return;
    if (_discovering) return;
    _stopPassiveBeaconWatch();
    _discovering = true;
    try {
      await _tryConnectInner();
    } catch (e) {
      // An error here used to end the retry chain for good (nothing scheduled the next try).
      debugPrint('[ConnectionManager] Connect attempt failed: $e');
      _discovering = false;
      _scheduleReconnect();
    } finally {
      _discovering = false;
    }
  }

  Future<void> _tryConnectInner() async {
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
      }
      // In offline clinics, DHCP leases or static IPs stay the same. Never delete the saved server IP
      // automatically — doing so leaves the client with no known address if UDP broadcast is filtered by the router.
      debugPrint('[ConnectionManager] Saved server ${saved.$1} not responding on quick probe — retaining saved IP and continuing discovery');
    }

    final now = DateTime.now();
    final canProbeFirestore = _isFirebaseReady &&
        (_lastFirestoreProbeTime == null || now.difference(_lastFirestoreProbeTime!).inMinutes >= 15);
    Future<bool> probeFirestoreServer() async {
    if (canProbeFirestore) {
      _lastFirestoreProbeTime = now;
      final candidates = <String>[
        if (_branchId != null && _branchId!.isNotEmpty && _branchId != 'all' && _branchId != 'global') _branchId!,
      ];
      // Other branches' servers are only looked up when this PC's own branch is unknown
      // (e.g. HQ). A PC can only reach its own branch's LAN server, and reading every
      // known branch document every few minutes cost ~1,000 reads a day per searching PC.
      try {
        if (candidates.isEmpty && Hive.isBoxOpen('local_branches')) {
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
              if (ok) return true;
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
            if (ok) return true;
          }
        }
      } catch (_) {}
    }
    return false;
    }

    // Web has no LAN scan, so Firestore is the first resort there.
    if (kIsWeb && await probeFirestoreServer()) return;

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
    if (!kIsWeb) {
      // Bounded: if the plugin call hangs, _discovering stayed true and every retry path
      // returned early, so the desk never reconnected until the app was restarted.
      final connList = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 2), onTimeout: () => const <ConnectivityResult>[])
          .catchError((Object _) => const <ConnectivityResult>[]);
      // connectivity_plus often reports an empty list (or only "none") on Windows desktops that are
      // perfectly connected (virtual adapters, several NICs). Treating that as "no network" stopped
      // discovery before it started, so the client sat on "Disconnected" forever. On desktop we
      // never block on it: the scan below simply fails if the network really is down.
      final isDesktop = io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS;
      final hasNetwork = isDesktop ||
          connList.contains(ConnectivityResult.wifi) ||
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
      branchId: _branchId,
      onStatus: (s) => _emit(ConnectionStatus(
        state: LanConnectionState.searching,
        message: s,
      )),
    );

    if (found == null) {
      // LAN scan failed → last resort: server IP published in Firestore.
      if (await probeFirestoreServer()) return;

      // Final fallback before giving up: direct connect attempt to last-known saved server
      if (saved != null) {
        debugPrint('[ConnectionManager] Full discovery found nothing → retrying direct connect to saved server ${saved.$1}:${saved.$2}');
        final ok = await _connectTo(saved.$1, saved.$2);
        if (ok) return;
      }

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
    // Found a DIFFERENT server than the one this desk works with: only switch if the saved one
    // is really gone, not just slow to answer one probe (see _savedServerStillAlive).
    if (saved != null && found.ip != saved.$1 && await _savedServerStillAlive(saved)) {
      debugPrint('[ConnectionManager] ⚠️ Ignoring other server ${found.ip}: saved server ${saved.$1} is still up');
      final okSaved = await _connectTo(saved.$1, saved.$2);
      if (okSaved) return;
    }
    final ok = await _connectTo(found.ip, found.port);
    if (!ok) _scheduleReconnect();
  }

  // ── Connect to specific IP ─────────────────────────────────────────────────
  Future<bool> _connectTo(String ip, int port) async {
    if (!_running || _disposed) return false;
    _inConnectTo = true;

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

      final confirmed = await _waitForIdentified(timeoutSeconds: 15);

      if (!confirmed) {
        debugPrint('[ConnectionManager] No identified response from $ip');
        return false;
      }

      _saveServer(ip, port);
      // Desks never publish the server's address to Firestore: the server does that itself
      // when it starts (server.dart). This was one Firestore write per desk on every reconnect.

      _reconnectAttempts = 0;
      _onLinkUp(ip, port);
      return true;
    } catch (e) {
      debugPrint('[ConnectionManager] Connect failed: $e');
      _emit(ConnectionStatus(
        state: LanConnectionState.disconnected,
        message: 'Connection failed: $e',
      ));
      return false;
    } finally {
      _inConnectTo = false;
    }
  }

  /// The server accepted this PC: show it, re-run the reconnect listeners and watch the link.
  void _onLinkUp(String ip, int port) {
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
  }

  // ── Wait for 'identified' ──────────────────────────────────────────────────
  Future<bool> _waitForIdentified({required int timeoutSeconds}) async {
    if (RealtimeManager().isServerIdentified) return true;

    final completer = Completer<bool>();
    void identifiedListener() {
      if (RealtimeManager().isServerIdentified && !completer.isCompleted) {
        completer.complete(true);
      }
    }

    RealtimeManager().addIdentifiedListener(identifiedListener);

    late StreamSubscription sub;
    sub = RealtimeManager().messageStream.listen((event) {
      if ((event['event_type'] == 'identified' || RealtimeManager().isServerIdentified) && !completer.isCompleted) {
        completer.complete(true);
      }
    });

    Timer(Duration(seconds: timeoutSeconds), () {
      if (!completer.isCompleted) {
        // Only return true if actively identified and confirmed by server
        completer.complete(RealtimeManager().isServerIdentified);
      }
    });

    try {
      return await completer.future;
    } finally {
      RealtimeManager().removeIdentifiedListener(identifiedListener);
      sub.cancel();
    }
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
      if (!_running || _disposed || _discovering) return;

      final rm = RealtimeManager();
      // Case 1: RealtimeManager is disconnected and no reconnect is actively scheduled.
      // Case 2: RealtimeManager has failed reconnecting to the current IP 3+ times.
      //         The server may have rebooted with a new DHCP IP, so run full discovery.
      final bool needsRediscovery = !rm.isConnected && rm.reconnectAttempts >= 3;
      final bool isDeadSilent = !rm.isConnected && _reconnectTimer == null && !rm.isReconnecting;

      if (needsRediscovery || isDeadSilent) {
        debugPrint('[ConnectionManager] Heartbeat: ${needsRediscovery ? "reconnect attempts (${rm.reconnectAttempts}) exhausted" : "disconnect detected"}, scheduling server rediscovery...');
        _emit(const ConnectionStatus(
          state: LanConnectionState.disconnected,
          message: 'Connection lost — rediscovering server...',
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

    // Capped at 10 s: a clinic PC waiting a minute between attempts looked permanently
    // disconnected after a short server restart (each discovery round itself takes ~12 s).
    const delays = [2, 3, 5, 10];
    final delay =
        delays[_reconnectAttempts.clamp(0, delays.length - 1)];
    _reconnectAttempts++;

    if (_reconnectAttempts <= 5 || _reconnectAttempts % 5 == 0) {
      debugPrint('[ConnectionManager] Reconnect in ${delay}s (attempt $_reconnectAttempts)');
    }
    _startPassiveBeaconWatch();
    // Cleared when it fires: the heartbeat's "nothing scheduled" check relies on it.
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      _reconnectTimer = null;
      _tryConnect();
    });
  }

  // ── Manual retry ───────────────────────────────────────────────────────────
  Future<void> reconnectNow() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _reconnectAttempts = 0;
    // The Retry button must work even if something stopped the manager (stop() is meant
    // for logout only, but a stopped manager used to ignore every retry until next login).
    if (_role != null && _branchId != null) {
      _running = true;
      _disposed = false;
    }
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
  /// The saved server answers within ~10 s (3 probes, 2 s apart). A single 1.2 s probe failing
  /// (server busy for a moment, Wi-Fi blip) used to send the desk to whatever other server it
  /// found, splitting the desks between two servers.
  Future<bool> _savedServerStillAlive((String, int) saved) async {
    for (var i = 0; i < 3; i++) {
      if (!_running || _disposed) return false;
      if (await LanDiscovery.isReachable(saved.$1, saved.$2)) return true;
      if (i < 2) await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

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

  void clearSavedServer() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        box.delete(_savedIpKey);
        box.delete(_savedPortKey);
      }
    } catch (_) {}
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
    // Skip repeats: every listening desk screen rebuilds itself on each status event, and
    // reconnect cycles emitted the same status several times in a row.
    final prev = _current;
    if (prev.state == s.state && prev.ip == s.ip && prev.port == s.port && prev.message == s.message) return;
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
    _connSub?.cancel();
    _connSub = null;
    await RealtimeManager().dispose();
    _emit(const ConnectionStatus(
      state: LanConnectionState.disconnected,
      message: 'Disconnected',
    ));
  }
}
