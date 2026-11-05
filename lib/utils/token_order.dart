import '../services/local_storage_service.dart';
import '../services/serials_service.dart';

/// Fair queue order: patients are seen in the order they got their token.
///
/// - Online tokens (1..999) are numbered by the LAN server in arrival order, so their number
///   IS the arrival order. They are kept in number order, whatever their desk clocks say.
/// - Offline tokens (desk block N*1000+k, issued while the server was unreachable) are placed
///   among them by their issue time. Sorting by number alone put every offline patient
///   behind all later online patients (1001 after 60), and block 2 behind block 1.
///
/// This is a merge, not a comparator, so the order is always consistent: online tokens in
/// number order, offline tokens in time order, offline ones slotted in by time.
class TokenOrder {
  TokenOrder._();

  static int seqOf(Map<String, dynamic> e) =>
      parseSequenceFromSerial((e['serial'] ?? e['id'] ?? '').toString());

  static bool isOffline(Map<String, dynamic> e) {
    final seq = seqOf(e);
    return LocalStorageService.isOfflineBandSeq(seq) && seq < 999999;
  }

  /// Issue time in epoch ms (server-corrected `issuedAtMs` when present), or null.
  static int? issueTimeMs(Map<String, dynamic> e) {
    final v = e['issuedAtMs'];
    if (v is num && v > 0) return v.toInt();
    return _toMs(e['createdAt']) ?? _toMs(e['timestamp']);
  }

  static int? _toMs(Object? v) {
    if (v == null) return null;
    if (v is num) return v > 1e12 ? v.toInt() : (v * 1000).toInt();
    if (v is DateTime) return v.millisecondsSinceEpoch;
    if (v is Map) {
      final s = v['seconds'] ?? v['_seconds'];
      if (s is num) return (s * 1000).toInt();
      return null;
    }
    try {
      // Firestore Timestamp and similar objects expose millisecondsSinceEpoch / toDate().
      final dynamic d = v;
      final ms = d.millisecondsSinceEpoch;
      if (ms is int) return ms;
    } catch (_) {}
    return DateTime.tryParse(v.toString())?.millisecondsSinceEpoch;
  }

  /// Returns [list] in fair order (a new list). [newestFirst] reverses it.
  static List<Map<String, dynamic>> sortFairly(
    Iterable<Map<String, dynamic>> list, {
    bool newestFirst = false,
  }) {
    final online = <Map<String, dynamic>>[];
    final offline = <Map<String, dynamic>>[];
    for (final e in list) {
      (isOffline(e) ? offline : online).add(e);
    }

    online.sort((a, b) {
      final c = seqOf(a).compareTo(seqOf(b));
      if (c != 0) return c;
      return (issueTimeMs(a) ?? 0).compareTo(issueTimeMs(b) ?? 0);
    });
    // Offline tokens without a known time go last among themselves.
    offline.sort((a, b) {
      final ta = issueTimeMs(a) ?? (1 << 62);
      final tb = issueTimeMs(b) ?? (1 << 62);
      final c = ta.compareTo(tb);
      return c != 0 ? c : seqOf(a).compareTo(seqOf(b));
    });

    final List<Map<String, dynamic>> merged;
    if (offline.isEmpty) {
      merged = online;
    } else if (online.isEmpty) {
      merged = offline;
    } else {
      // Online issue times made non-decreasing along number order (desk clocks can differ),
      // so each offline token is inserted at one well-defined place.
      final onlineTimes = <int>[];
      var running = 0;
      for (final e in online) {
        final t = issueTimeMs(e);
        if (t != null && t > running) running = t;
        onlineTimes.add(running);
      }
      merged = <Map<String, dynamic>>[];
      var i = 0, j = 0;
      while (i < online.length && j < offline.length) {
        final offT = issueTimeMs(offline[j]) ?? (1 << 62);
        if (offT < onlineTimes[i]) {
          merged.add(offline[j++]);
        } else {
          merged.add(online[i++]);
        }
      }
      while (i < online.length) {
        merged.add(online[i++]);
      }
      while (j < offline.length) {
        merged.add(offline[j++]);
      }
    }
    return newestFirst ? merged.reversed.toList() : merged;
  }
}
