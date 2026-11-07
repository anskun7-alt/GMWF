// lib/realtime/lan_discovery.dart
// Automatic server discovery: mDNS → UDP broadcast → parallel subnet scan.
// No manual IP needed. Usually finds server in under 3 seconds.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../config/constants.dart';
import '../services/camp_session_service.dart';
import '../services/local_storage_service.dart';
import '../utils/network_utils.dart';

class DiscoveredServer {
  final String ip;
  final int port;
  final String method;
  const DiscoveredServer({required this.ip, required this.port, required this.method});
  @override
  String toString() => '$ip:$port (via $method)';
}

class LanDiscovery {
  static Future<DiscoveredServer?> findServer({
    Duration timeout = const Duration(seconds: 12),
    void Function(String)? onStatus,
    String? branchId,
  }) async {
    onStatus?.call('Searching for server...');
    debugPrint('LanDiscovery: Starting multi-strategy discovery');

    final completer = Completer<DiscoveredServer?>();

    _tryUdp(completer, onStatus, branchId: branchId);
    _tryScan(completer, onStatus);
    _tryMdns(completer, onStatus);

    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    return completer.future;
  }

  /// Set once the mDNS plugin turns out to be missing (Windows builds): later discovery rounds
  /// skip it instead of failing again every few seconds while a desk looks for the server.
  static bool _mdnsUnavailable = false;

  static Future<void> _tryMdns(Completer<DiscoveredServer?> c, void Function(String)? s) async {
    if (_mdnsUnavailable) return;
    try {
      final d = BonsoirDiscovery(type: '_gmwftoken._tcp');
      // bonsoir 6 requires initialize() before start(); without it every discovery round
      // failed with an 'isReady' assertion (the repeated "mDNS error" in the terminal).
      await d.initialize();
      await d.start();
      d.eventStream?.listen((e) {
        if (c.isCompleted) return;
        if (e is BonsoirDiscoveryServiceResolvedEvent) {
          final ip = e.service.host;
          final port = e.service.port;
          if (ip != null && ip.isNotEmpty) {
            debugPrint('mDNS found: $ip:$port');
            s?.call('Found server at $ip');
            c.complete(DiscoveredServer(ip: ip, port: port, method: 'mdns'));
            try { d.stop(); } catch (_) {}
          }
        }
      }, onError: (Object e) {
        // No mDNS plugin on this platform (MissingPluginException on Windows): UDP and the
        // subnet scan still find the server. Unhandled, this filled gmwf_crash.log.
        debugPrint('mDNS unavailable: $e');
        if (e is MissingPluginException) _mdnsUnavailable = true;
      }, cancelOnError: true);
      Future.delayed(const Duration(seconds: 8), () {
        try { d.stop(); } catch (_) {}
      });
    } catch (e) {
      debugPrint('mDNS error: $e');
      if (e is MissingPluginException) _mdnsUnavailable = true;
    }
  }

  static Future<void> _tryUdp(Completer<DiscoveredServer?> c, void Function(String)? s,
      {String? branchId}) async {
    final myBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: '');
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppNetwork.udpBroadcastPort,
        reuseAddress: true,
        // reusePort is unsupported on Windows and makes bind() throw.
        reusePort: !(Platform.isWindows),
      );
      sock.listen((ev) {
        if (c.isCompleted) { try { sock.close(); } catch (_) {} return; }
        if (ev == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null) {
            final msg = utf8.decode(dg.data);
            if (msg.startsWith(AppNetwork.udpMessagePrefix)) {
              final payload = msg.substring(AppNetwork.udpMessagePrefix.length).trim();
              final parts = payload.split(':');
              final ip = parts[0];
              final port = parts.length > 1 ? (int.tryParse(parts[1]) ?? AppNetwork.websocketPort) : AppNetwork.websocketPort;
              // Another branch's server on the same network: not ours, keep listening. (A
              // beacon without a branch — older server — is accepted as before.)
              final serverBranch = parts.length > 2 ? LocalStorageService.sanitizeBranchId(parts[2], fallback: '') : '';
              if (myBranch.isNotEmpty &&
                  serverBranch.isNotEmpty &&
                  !CampSessionService.areBranchesMatching(myBranch, serverBranch)) {
                debugPrint('UDP: ignoring $ip:$port (branch $serverBranch does not match desk $myBranch)');
                return;
              }
              if (ip.isNotEmpty) {
                // Verify reachability so an outdated IP broadcast after DHCP renewal is not accepted
                unawaited(isReachable(ip, port).then((reachable) {
                  if (reachable && !c.isCompleted) {
                    debugPrint('UDP found & verified: $ip:$port');
                    s?.call('Found server at $ip');
                    try { sock.close(); } catch (_) {}
                    c.complete(DiscoveredServer(ip: ip, port: port, method: 'udp'));
                  }
                }));
              }
            }
          }
        }
      });
      Future.delayed(const Duration(seconds: 10), () { try { sock.close(); } catch (_) {} });
    } catch (e) {
      debugPrint('UDP error: $e');
    }
  }

  static int _scanRound = 0;

  static Future<void> _tryScan(Completer<DiscoveredServer?> c, void Function(String)? s) async {
    try {
      if (c.isCompleted) return;

      final port = AppNetwork.websocketPort;

      // 1. Probe localhost (127.0.0.1) immediately
      await _probe('127.0.0.1', port, c);
      if (c.isCompleted) return;

      // 2. Probe all local IPs directly
      final localIps = await getAllLanIps();
      for (final ip in localIps) {
        await _probe(ip, port, c);
        if (c.isCompleted) return;
      }

      // 3. Collect all subnets to scan: detected LAN subnets + standard subnets
      final detectedSubnets = await getAllLanSubnets();
      final standardSubnets = [
        '192.168.1',
        '192.168.0',
        '192.168.10',
        '192.168.18',
        '192.168.100',
        '10.0.0',
        '172.20.10',
      ];

      final allSubnets = <String>{...detectedSubnets, ...standardSubnets}.toList();

      // The standard subnets are usually not this PC's network: probing all 254 addresses
      // of each (about 1,800 connection attempts per search) loaded the PC and the network
      // every time a client looked for the server. Each round checks their likely server
      // addresses; every 5th round (or when this PC's own subnet is unknown) scans them fully.
      _scanRound++;
      final fullScanStandard = detectedSubnets.isEmpty || _scanRound % 5 == 1;

      for (final subnet in allSubnets) {
        if (c.isCompleted) return;
        s?.call('Scanning $subnet.*...');

        // Priority 1: High probability server static IPs (.1, .15, .9, .100, .2, .10, .50, .200, .254)
        final priorityOctets = [1, 15, 9, 100, 2, 10, 50, 200, 254, 3, 4, 5, 20, 25, 30, 40, 55, 60, 70, 80, 90];
        await Future.wait(priorityOctets.map((oct) => _probe('$subnet.$oct', port, c)));
        if (c.isCompleted) return;
        if (!detectedSubnets.contains(subnet) && !fullScanStandard) continue;

        // Priority 2: Remaining IPs in fast chunks of 40
        final remaining = <int>[];
        for (int i = 1; i <= 254; i++) {
          if (!priorityOctets.contains(i)) remaining.add(i);
        }

        const batchSize = 40;
        for (int i = 0; i < remaining.length && !c.isCompleted; i += batchSize) {
          final chunk = remaining.sublist(i, (i + batchSize).clamp(0, remaining.length));
          await Future.wait(chunk.map((oct) => _probe('$subnet.$oct', port, c)));
        }
      }
    } catch (e) {
      debugPrint('Scan error: $e');
    }
  }

  static Future<void> _probe(String host, int port, Completer<DiscoveredServer?> c) async {
    if (c.isCompleted) return;
    try {
      final sock = await Socket.connect(host, port, timeout: const Duration(milliseconds: 350));
      sock.destroy();
      if (!c.isCompleted) {
        debugPrint('Scan found open port: $host:$port');
        c.complete(DiscoveredServer(ip: host, port: port, method: 'scan'));
      }
    } on SocketException {
      // unreachable
    } catch (_) {}
  }

  static Future<bool> isReachable(String ip, int port) async {
    if (kIsWeb) return true;
    try {
      final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 1200));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
