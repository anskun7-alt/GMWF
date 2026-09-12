// lib/realtime/lan_discovery.dart
// Automatic server discovery: mDNS → UDP broadcast → parallel subnet scan.
// No manual IP needed. Usually finds server in under 3 seconds.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../config/constants.dart';
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
  }) async {
    onStatus?.call('Searching for server...');
    debugPrint('LanDiscovery: Starting multi-strategy discovery');

    final completer = Completer<DiscoveredServer?>();

    _tryUdp(completer, onStatus);
    _tryScan(completer, onStatus);
    _tryMdns(completer, onStatus);

    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    return completer.future;
  }

  static Future<void> _tryMdns(Completer<DiscoveredServer?> c, void Function(String)? s) async {
    try {
      final d = BonsoirDiscovery(type: '_gmwftoken._tcp');
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
      });
      Future.delayed(const Duration(seconds: 8), () {
        try { d.stop(); } catch (_) {}
      });
    } catch (e) {
      debugPrint('mDNS error: $e');
    }
  }

  static Future<void> _tryUdp(Completer<DiscoveredServer?> c, void Function(String)? s) async {
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppNetwork.udpBroadcastPort,
        reuseAddress: true,
        reusePort: true,
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
              if (ip.isNotEmpty) {
                debugPrint('UDP found: $ip:$port');
                s?.call('Found server at $ip');
                try { sock.close(); } catch (_) {}
                c.complete(DiscoveredServer(ip: ip, port: port, method: 'udp'));
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

      for (final subnet in allSubnets) {
        if (c.isCompleted) return;
        s?.call('Scanning $subnet.*...');

        // Priority 1: High probability server static IPs (.1, .15, .9, .100, .2, .10, .50, .200, .254)
        final priorityOctets = [1, 15, 9, 100, 2, 10, 50, 200, 254, 3, 4, 5, 20, 25, 30, 40, 55, 60, 70, 80, 90];
        await Future.wait(priorityOctets.map((oct) => _probe('$subnet.$oct', port, c)));
        if (c.isCompleted) return;

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
      final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
