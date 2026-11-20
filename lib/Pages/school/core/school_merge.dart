// lib/pages/school/core/school_merge.dart
//
// Pure merge rules for School records arriving from the cloud. No Hive, no
// Firestore: everything here is unit-tested in test/school/school_merge_test.dart.
//
// Rules (School ERP plan §3.1):
//  * Last write wins on `lastModified`, for EVERY collection (before, only
//    students/teachers/books compared timestamps; loans, attendance, grades,
//    fees and homerooms were overwritten blindly, losing unsynced edits).
//  * A local record that is still waiting to upload is never replaced by a
//    remote copy that is not strictly newer.
//  * Day documents (attendance) merge per student entry, so two PCs marking
//    different students on the same day both keep their marks.

enum SchoolMergeWinner { remote, local }

class SchoolMergeResult {
  final Map<String, dynamic> record;
  final SchoolMergeWinner winner;

  /// True when the local copy had unsynced edits and the remote copy replaced
  /// them (worth an audit entry).
  final bool overwrotePendingLocal;

  const SchoolMergeResult(this.record, this.winner, {this.overwrotePendingLocal = false});
}

abstract final class SchoolMerge {
  static DateTime? parseTs(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  static DateTime? recordTs(Map<String, dynamic>? r) =>
      r == null ? null : (parseTs(r['lastModified']) ?? parseTs(r['updatedAt']) ?? parseTs(r['lastUpdated']));

  static DateTime? entryTs(Map<String, dynamic>? e) =>
      e == null ? null : (parseTs(e['lastModified']) ?? parseTs(e['updatedAt']) ?? parseTs(e['timestamp']));

  static bool isPending(Map<String, dynamic>? r) {
    if (r == null) return false;
    final s = (r['syncStatus'] ?? '').toString();
    return s == 'pending' || s == 'failed' || r['pendingSync'] == true;
  }

  static Map<String, dynamic> _markSynced(Map<String, dynamic> r, DateTime now) => {
        ...r,
        'syncStatus': 'synced',
        'lastSyncedAt': now.toIso8601String(),
        'pendingSync': false,
      };

  /// Whole-record merge (students, teachers, books, loans, grades, fees, …).
  static SchoolMergeResult mergeRecord(
    Map<String, dynamic>? local,
    Map<String, dynamic> remote, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (local == null) return SchoolMergeResult(_markSynced(remote, at), SchoolMergeWinner.remote);

    final lt = recordTs(local);
    final rt = recordTs(remote);
    final pending = isPending(local);

    final remoteNewer = rt != null && (lt == null || rt.isAfter(lt));
    if (remoteNewer) {
      return SchoolMergeResult(_markSynced(remote, at), SchoolMergeWinner.remote, overwrotePendingLocal: pending);
    }
    // Same stamp in the cloud = this exact write already uploaded.
    if (rt != null && lt != null && rt.isAtSameMomentAs(lt)) {
      return SchoolMergeResult(_markSynced(local, at), SchoolMergeWinner.local);
    }
    // Local is newer, equal, or remote has no timestamp: keep local. A pending
    // local record stays pending so its queued upload still reaches the cloud.
    return SchoolMergeResult(pending ? local : _markSynced(local, at), SchoolMergeWinner.local);
  }

  /// Day document merge: `{date, entries: {id: {...}}, ...}`. Each entry is
  /// decided on its own timestamp; document fields follow the newer document.
  static SchoolMergeResult mergeDayLog(
    Map<String, dynamic>? local,
    Map<String, dynamic> remote, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (local == null) return SchoolMergeResult(_markSynced(remote, at), SchoolMergeWinner.remote);

    final localEntries = _entries(local);
    final remoteEntries = _entries(remote);
    final merged = <String, dynamic>{};
    var localWonAny = false;

    for (final id in {...localEntries.keys, ...remoteEntries.keys}) {
      final l = localEntries[id];
      final r = remoteEntries[id];
      if (l == null) {
        merged[id] = r;
        continue;
      }
      if (r == null) {
        merged[id] = l;
        localWonAny = true;
        continue;
      }
      final lt = entryTs(l);
      final rt = entryTs(r);
      final remoteNewer = rt != null && (lt == null || rt.isAfter(lt));
      if (remoteNewer) {
        merged[id] = r;
      } else {
        merged[id] = l;
        if (!_sameEntry(l, r)) localWonAny = true;
      }
    }

    final docWinner = mergeRecord(local, remote, now: at);
    final base = Map<String, dynamic>.from(docWinner.record);
    base['entries'] = merged;

    final stillPending = isPending(local) && localWonAny;
    if (stillPending) {
      base['syncStatus'] = 'pending';
      base['pendingSync'] = true;
    } else {
      base['syncStatus'] = 'synced';
      base['pendingSync'] = false;
      base['lastSyncedAt'] = at.toIso8601String();
    }
    return SchoolMergeResult(
      base,
      localWonAny ? SchoolMergeWinner.local : SchoolMergeWinner.remote,
    );
  }

  /// Combines several copies of the same day stored under branch-alias keys
  /// (e.g. biometric punches saved under "grt", screen saves under "gujrat").
  static Map<String, dynamic>? combineDayLogs(Iterable<Map<String, dynamic>> copies) {
    Map<String, dynamic>? acc;
    for (final c in copies) {
      if (acc == null) {
        acc = Map<String, dynamic>.from(c);
        acc['entries'] = _entries(c);
        continue;
      }
      final keepPending = isPending(acc) || isPending(c);
      acc = mergeDayLog(acc, c).record;
      if (keepPending) {
        acc['syncStatus'] = 'pending';
      }
    }
    return acc;
  }

  static Map<String, Map<String, dynamic>> _entries(Map<String, dynamic> doc) {
    final raw = doc['entries'];
    if (raw is! Map) return {};
    final out = <String, Map<String, dynamic>>{};
    raw.forEach((k, v) {
      if (v is Map) out[k.toString()] = Map<String, dynamic>.from(v);
    });
    return out;
  }

  static bool _sameEntry(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k]?.toString() != b[k]?.toString()) return false;
    }
    return true;
  }
}
