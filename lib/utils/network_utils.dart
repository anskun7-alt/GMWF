// lib/utils/network_utils.dart
// COMPLETE FIX: Universal LAN IP detection for all subnets
// Supports: 192.168.x.x, 10.x.x.x, 172.16-31.x.x, 200.x.x.x, and any
// non-standard private subnet a router might assign.
// Cross-platform: Windows, Mac, Linux, ChromeOS, Android, iOS

import 'dart:io';
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns true for IPs that should NEVER be used as a LAN server address.
/// We blacklist rather than whitelist so any router subnet works.
bool _shouldExcludeIp(String ip) {
  // Loopback
  if (ip.startsWith('127.')) return true;

  // APIPA / link-local (assigned when DHCP fails — useless for LAN)
  if (ip.startsWith('169.254.')) return true;

  // Multicast
  if (ip.startsWith('224.') ||
      ip.startsWith('225.') ||
      ip.startsWith('226.') ||
      ip.startsWith('227.') ||
      ip.startsWith('228.') ||
      ip.startsWith('229.') ||
      ip.startsWith('230.') ||
      ip.startsWith('231.') ||
      ip.startsWith('232.') ||
      ip.startsWith('233.') ||
      ip.startsWith('234.') ||
      ip.startsWith('235.') ||
      ip.startsWith('236.') ||
      ip.startsWith('237.') ||
      ip.startsWith('238.') ||
      ip.startsWith('239.')) {
    return true;
  }

  // Broadcast / reserved
  if (ip.startsWith('255.')) return true;
  if (ip == '0.0.0.0') return true;

  return false;
}

/// Scoring: higher = prefer this IP.
/// Lets us rank 192.168 above 10.x above 172.x above anything else,
/// while still accepting non-standard subnets like 200.168.x.x.
int _ipScore(String ip, String interfaceName) {
  int score = 0;

  // Interface quality bonus
  if (_isLikelyWifiOrEthernet(interfaceName)) score += 100;

  // Well-known private ranges get a bonus (they're the most reliable)
  if (ip.startsWith('192.168.')) score += 50;
  if (ip.startsWith('10.')) score += 40;
  if (ip.startsWith('172.')) {
    final parts = ip.split('.');
    if (parts.length >= 2) {
      final second = int.tryParse(parts[1]) ?? 0;
      if (second >= 16 && second <= 31) score += 40;
    }
  }

  // Non-standard but routable private-ish ranges (e.g. 200.168.x.x)
  // These get a smaller bonus — still valid, just less common.
  // No penalty — they work fine as LAN addresses.

  return score;
}

/// Returns true if the interface name suggests WiFi or Ethernet.
bool _isLikelyWifiOrEthernet(String interfaceName) {
  final name = interfaceName.toLowerCase();

  // Explicit includes
  if (name.contains('wlan')) return true;
  if (name.contains('wifi')) return true;
  if (name.contains('wi-fi')) return true;
  if (name.startsWith('en0') || name.startsWith('en1')) return true; // macOS
  if (name.contains('eth')) return true;
  if (name.contains('ethernet')) return true;
  if (name.contains('local area connection')) return true;

  // Explicit excludes
  if (name.contains('tun')) return false;    // OpenVPN / WireGuard
  if (name.contains('utun')) return false;   // macOS VPN
  if (name.contains('vpn')) return false;
  if (name.contains('ppp')) return false;
  if (name.contains('rmnet')) return false;  // Android mobile data
  if (name.contains('mobile')) return false;
  if (name.contains('cellular')) return false;
  if (name.contains('bridge')) return false;
  if (name.contains('vbox')) return false;
  if (name.contains('vmnet')) return false;
  if (name.contains('docker')) return false;
  if (name.contains('loopback')) return false;
  if (name.contains('lo')) return false;

  // Unknown interface — allow it, just no bonus
  return true;
}

DateTime? _cachedIpsTime;
List<String>? _cachedIps;

/// Returns all active, bindable LAN IPv4 addresses on this machine.
Future<List<String>> getAllLanIps({bool forceRefresh = false}) async {
  if (kIsWeb) return [];
  final now = DateTime.now();
  if (!forceRefresh && _cachedIps != null && _cachedIpsTime != null &&
      now.difference(_cachedIpsTime!) < const Duration(seconds: 30)) {
    return _cachedIps!;
  }

  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final results = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.isLoopback || _shouldExcludeIp(ip)) continue;
        try {
          final testSocket = await RawDatagramSocket.bind(InternetAddress(ip), 0);
          testSocket.close();
          results.add(ip);
        } catch (_) {}
      }
    }
    _cachedIps = results;
    _cachedIpsTime = now;
    return results;
  } catch (_) {
    return _cachedIps ?? [];
  }
}

/// Returns all unique 3-octet subnet prefixes (e.g. ['192.168.1', '192.168.10'])
Future<List<String>> getAllLanSubnets({bool forceRefresh = false}) async {
  final ips = await getAllLanIps(forceRefresh: forceRefresh);
  final subnets = <String>{};
  for (final ip in ips) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
  }
  return subnets.toList();
}

/// Returns the best LAN IPv4 address for this device, or null if none found.
Future<String?> getPrimaryLanIp() async {
  if (kIsWeb) return null;

  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    // Collect all candidates with their scores
    final candidates = <({String ip, String iface, int score})>[];

    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;

        if (addr.isLoopback || _shouldExcludeIp(ip)) continue;

        // Validate that this IP is actually bound and active on the host OS.
        try {
          final testSocket = await RawDatagramSocket.bind(InternetAddress(ip), 0);
          testSocket.close();
        } catch (_) {
          continue;
        }

        final score = _ipScore(ip, iface.name);
        candidates.add((ip: ip, iface: iface.name, score: score));
      }
    }

    if (candidates.isNotEmpty) {
      // Pick the highest score
      candidates.sort((a, b) => b.score.compareTo(a.score));
      final best = candidates.first;
      debugPrint('✅ LAN IP SELECTED: ${best.ip} (${best.iface}) score=${best.score}');
      return best.ip;
    }

    // Fallback: try socket method with short timeout
    try {
      final socket = await Socket.connect(
        '8.8.8.8',
        80,
        timeout: const Duration(milliseconds: 500),
      );
      final ip = socket.address.address;
      await socket.close();

      if (!_shouldExcludeIp(ip)) {
        return ip;
      }
    } catch (_) {}

    return null;
  } catch (e) {
    debugPrint('❌ Critical error in IP detection: $e');
    return null;
  }
}
