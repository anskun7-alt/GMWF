// lib/pages/dispensary/dispensar/dispense_queue.dart
//
// The dispenser's queue rules in one place: which of today's entries are in the
// dispense queue, how they are ordered (pending → on hold → dispensed, smallest
// token first), and which patient to load next. Used by the Dispenser's
// PatientList and by the Hybrid Pharmacy tab so the two never disagree.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/utils/token_order.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/serials_service.dart';

class DispenseQueue {
  DispenseQueue._();

  static bool isOnHold(Map<String, dynamic> e) {
    final ds = (e['dispenseStatus'] ?? '').toString().toLowerCase();
    return ds == 'on_hold' || ds == 'hold';
  }

  static bool isDispensed(Map<String, dynamic> e) {
    return (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
  }

  /// Whether the entry belongs to today's shift date. A token shows only on the date in its
  /// serial: with the old 24-hour carry-over, yesterday's tokens sat in today's list and a
  /// search for a slip's number could open yesterday's token and its medicines.
  static bool isEffectivelyToday(
    Map<String, dynamic> e,
    String currentTodayKey,
    String todayIso,
    String branchId,
  ) {
    if (CampSessionService.isTokenOnDate(e, currentTodayKey, branchId)) {
      return true;
    }
    // A session running past midnight: tokens issued in the last hours of yesterday stay on
    // (prescribed ones to dispense, and recently dispensed ones for reference). The old rule
    // brought back ALL of yesterday's unfinished tokens every night until 06:00, including
    // abandoned morning tokens.
    return CampSessionService.isLateNightCarryOver(e, branchId);
  }

  static Map<String, dynamic> _userData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final data = box.get('user_data') ?? box.get('currentUser');
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      }
    } catch (_) {}
    return {};
  }

  /// The dispense queue for [branchId], ordered pending → on hold → dispensed
  /// (each by token number). [filter] is 'all', 'pending' or 'dispensed';
  /// [sessionFilter] is 'all', 'auto' or a shift name; [campFilter] is the
  /// selected camp ('all' for none).
  static List<Map<String, dynamic>> compute({
    required String branchId,
    String sessionFilter = 'all',
    String campFilter = 'all',
    String searchQuery = '',
    bool newestFirst = false,
    String filter = 'all',
  }) {
    final effectiveBranch = (RealtimeManager().isConnected &&
            RealtimeManager().branchId != null &&
            RealtimeManager().branchId!.trim().isNotEmpty &&
            RealtimeManager().branchId!.toLowerCase().trim() != 'all')
        ? RealtimeManager().branchId!.toLowerCase().trim()
        : branchId.toLowerCase().trim();

    final queryBranch = effectiveBranch.isNotEmpty ? effectiveBranch : branchId;
    final todayKey = CampSessionService.resolveShiftAndDateKey(null, queryBranch).dateKey;
    final hasMultiCamps = CampSessionService.hasCampsForBranch(queryBranch);
    final userData = _userData();
    final allowedSessions = CampSessionService.getAllowedSessions(queryBranch, userData: userData);
    final scheduledCamps = CampSessionService.getMatchingScheduledCamps(userData);
    final effectiveCamp = hasMultiCamps
        ? ((campFilter.isNotEmpty && campFilter != 'all')
            ? campFilter
            : (scheduledCamps.isNotEmpty
                ? scheduledCamps.first
                : CampSessionService.getActiveCamp(queryBranch)))
        : null;

    final Set<String> branchesToQuery = {
      if (branchId.trim().isNotEmpty && branchId.toLowerCase().trim() != 'all') branchId.toLowerCase().trim(),
      if (effectiveBranch.trim().isNotEmpty && effectiveBranch != 'all') effectiveBranch,
    };
    if (branchesToQuery.isEmpty) branchesToQuery.add('all');

    final List<Map<String, dynamic>> allList = [];
    final seenIds = <String>{};
    for (final b in branchesToQuery) {
      for (final e in LocalStorageService.getLocalEntries(b)) {
        final id = (e['serial'] ?? e['id'] ?? '').toString();
        if (id.isEmpty || seenIds.add(id)) {
          allList.add(e);
        }
      }
    }
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // getLocalEntries hands out the shared index maps (read by the doctor/reception screens and
    // the server's catch-up). Names/CNICs filled in here — including the "Token #…" placeholder —
    // used to be written into those shared maps, so the placeholder leaked to every screen and
    // was even pushed to other desks. They are kept on the side and applied to this screen's
    // own copies below.
    final overrides = Map<Map, Map<String, dynamic>>.identity();
    Map<String, dynamic> ov(Map e) => overrides.putIfAbsent(e, () => <String, dynamic>{});

    var all = allList.where((e) {
      final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();

      final matchesBranch = branchesToQuery.any((b) => CampSessionService.isSerialMatchingBranch(serial, b)) ||
          CampSessionService.isSerialMatchingBranch(serial, branchId) ||
          CampSessionService.isSerialMatchingBranch(serial, queryBranch);

      if (!matchesBranch) {
        return false;
      }

      final isToday = isEffectivelyToday(e, todayKey, todayIso, queryBranch) ||
          (queryBranch != branchId && isEffectivelyToday(e, todayKey, todayIso, branchId));
      if (!isToday) return false;

      final presc = (e['prescription'] is Map && (e['prescription'] as Map).isNotEmpty)
          ? (e['prescription'] as Map)
          : (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.prescriptionsBox)
              ? (() {
                  final pBox = Hive.box(LocalStorageService.prescriptionsBox);
                  final raw = pBox.get(serial) ?? pBox.get(serial.toLowerCase()) ?? pBox.get(serial.toUpperCase());
                  return raw is Map ? raw : null;
                })()
              : null);
      final status = (e['status'] ?? '').toString().toLowerCase();
      final isDisp = (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' || status == 'dispensed';
      final hasPresc = presc != null && (
        (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
        (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
        (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
      );

      var name = LocalStorageService.resolveFirstValidPatientName([
        e['patientName'],
        e['name'],
        e['fullName'],
      ]).toLowerCase();
      var cnic = LocalStorageService.resolveFirstValidCnic([
        e['patientCnic'],
        e['cnic'],
        e['guardianCnic'],
      ]);

      // Fall back to prescription details if entry name OR cnic is missing/synthetic
      if ((name.isEmpty || cnic.isEmpty) && presc != null) {
        if (name.isEmpty) {
          final prName = LocalStorageService.resolveFirstValidPatientName([
            presc['patientName'],
            presc['name'],
            presc['fullName'],
          ]);
          if (prName.isNotEmpty) {
            name = prName.toLowerCase();
            ov(e)['patientName'] = prName;
            ov(e)['name'] = prName;
          }
        }
        if (cnic.isEmpty) {
          final prCnic = LocalStorageService.resolveFirstValidCnic([
            presc['patientCnic'],
            presc['cnic'],
            presc['guardianCnic'],
          ]);
          if (prCnic.isNotEmpty) {
            cnic = prCnic;
            ov(e)['cnic'] = prCnic;
            ov(e)['patientCnic'] = prCnic;
          }
        }
      }

      if (name.isEmpty || cnic.isEmpty) {
        if (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          final box = Hive.box(LocalStorageService.entriesBox);
          final raw = box.get('$branchId-$serial') ?? box.get('$queryBranch-$serial') ?? box.get(serial) ?? box.get(serial.toUpperCase());
          if (raw is Map) {
            final rName = LocalStorageService.resolveFirstValidPatientName([
              raw['patientName'],
              raw['name'],
              raw['fullName'],
            ]);
            final rCnic = LocalStorageService.resolveFirstValidCnic([
              raw['patientCnic'],
              raw['cnic'],
              raw['guardianCnic'],
            ]);
            if (name.isEmpty && rName.isNotEmpty) {
              name = rName.toLowerCase();
              ov(e)['patientName'] = rName;
              ov(e)['name'] = rName;
            }
            if (cnic.isEmpty && rCnic.isNotEmpty) {
              cnic = rCnic;
              ov(e)['cnic'] = rCnic;
              ov(e)['patientCnic'] = rCnic;
            }
          }
        }
        if (cnic.isEmpty) {
          final pId = (e['patientId'] ?? e['id'] ?? '').toString().trim();
          if (pId.isNotEmpty && !pId.toLowerCase().startsWith('unknown')) {
            final lp = LocalStorageService.getLocalPatient(pId);
            final lpCnic = LocalStorageService.resolveFirstValidCnic([
              lp?['cnic'],
              lp?['patientCnic'],
              lp?['guardianCnic'],
              pId.contains('_child_') ? pId.split('_child_').first : pId,
            ]);
            if (lpCnic.isNotEmpty) {
              cnic = lpCnic;
              ov(e)['cnic'] = lpCnic;
              ov(e)['patientCnic'] = lpCnic;
            }
          }
        }
        if (name.isEmpty && cnic.isEmpty) {
          // If token has prescription or completed status, NEVER hide it from dispenser!
          if (hasPresc || status == 'completed' || status == 'dispensed' || isDisp) {
            name = 'token #$serial';
            ov(e)['patientName'] = 'Token #$serial';
          } else {
            return false;
          }
        }
      }

      // Camp matching in multi-camp branches
      if (hasMultiCamps && effectiveCamp != null && effectiveCamp.isNotEmpty && effectiveCamp != 'all') {
        final matches = CampSessionService.matchesCamp(
          selectedCamp: effectiveCamp,
          dispensaryId: e['dispensaryId']?.toString(),
          campId: e['campId']?.toString(),
          dispensaryTag: e['dispensaryTag']?.toString(),
          serial: serial,
        );
        if (!matches) return false;
      }

      return (status == 'completed' || status == 'dispensed' || status == 'prescribed' || isDisp || hasPresc);
    }).toList();

    // Deduplicate by normalized serial (stripping branch prefix so 'branch-001' and '001' never appear as two patients)
    final Map<String, Map<String, dynamic>> uniqueBySerial = {};
    for (final shared in all) {
      final o = overrides[shared];
      final Map<String, dynamic> e = o == null ? shared : {...shared, ...o};
      String s = (e['serial'] ?? e['id'] ?? '').toString().trim().toUpperCase();
      final branchPrefix = '${branchId.trim().toUpperCase()}-';
      if (s.startsWith(branchPrefix)) {
        s = s.substring(branchPrefix.length);
      }
      if (s.isEmpty) continue;
      if (!uniqueBySerial.containsKey(s)) {
        uniqueBySerial[s] = Map<String, dynamic>.from(e);
      } else {
        final target = uniqueBySerial[s]!;
        e.forEach((k, v) {
          if (v != null && v != '' && v != 'unknown') {
            final old = target[k];
            if (old == null || old == '' || old == 'unknown') {
              target[k] = v;
            }
          }
        });

        // Always prioritize newer prescription data from doctor
        final inRx = e['prescription'];
        final exRx = target['prescription'];
        if (inRx is Map && inRx.isNotEmpty) {
          if (exRx is! Map || exRx.isEmpty) {
            target['prescription'] = LocalStorageService.prescriptionForEmbedding(inRx);
          } else {
            final inTime = DateTime.tryParse(inRx['updatedAt']?.toString() ?? inRx['completedAt']?.toString() ?? e['completedAt']?.toString() ?? '')?.millisecondsSinceEpoch ?? 0;
            final exTime = DateTime.tryParse(exRx['updatedAt']?.toString() ?? exRx['completedAt']?.toString() ?? target['completedAt']?.toString() ?? '')?.millisecondsSinceEpoch ?? 0;
            if (inTime >= exTime) {
              target['prescription'] = LocalStorageService.prescriptionForEmbedding(inRx);
            }
          }
        }

        final inCompleted = e['status'] == 'completed' || e['status'] == 'dispensed';
        final exCompleted = target['status'] == 'completed' || target['status'] == 'dispensed';
        if (inCompleted && !exCompleted) {
          target['status'] = e['status'];
          if (e['completedAt'] != null) target['completedAt'] = e['completedAt'];
          if (e['doctorName'] != null) target['doctorName'] = e['doctorName'];
          if (e['doctorId'] != null) target['doctorId'] = e['doctorId'];
        }

        final eDisp = (e['dispenseStatus'] ?? e['status'] ?? '').toString().toLowerCase();
        final tDisp = (target['dispenseStatus'] ?? target['status'] ?? '').toString().toLowerCase();
        if (eDisp == 'dispensed' || tDisp == 'dispensed') {
          target['dispenseStatus'] = 'dispensed';
          target['status'] = 'completed';
        }
      }
    }
    all = uniqueBySerial.values.toList();

    final currentRealShift = CampSessionService.getCurrentSession(null, branchId);
    final targetShift = sessionFilter == 'auto' ? currentRealShift : sessionFilter;

    // Strictly isolate to the active session
    if (targetShift != 'all') {
      all = all.where((entry) {
        String resolved = (entry['session'] ?? entry['shift'] ?? entry['campSession'] ?? entry['slot'] ?? '').toString().toLowerCase().trim();

        // Only infer session from createdAt if explicit session is missing/unknown
        if (resolved.isEmpty || resolved == 'unknown' || resolved == 'all' || resolved == 'auto') {
          final rawTime = entry['createdAt'] ?? entry['time'] ?? entry['timestamp'] ?? entry['date'];
          if (rawTime != null) {
            DateTime? dt;
            if (rawTime is Timestamp) {
              dt = rawTime.toDate().toLocal();
            } else if (rawTime is DateTime) {
              dt = rawTime.toLocal();
            } else {
              dt = DateTime.tryParse(rawTime.toString())?.toLocal();
            }
            if (dt != null) {
              final hasNight = allowedSessions.contains('night');
              if (dt.hour >= 6 && dt.hour < 14) {
                resolved = 'morning';
              } else if (dt.hour >= 14 && (dt.hour < 22 || !hasNight)) {
                resolved = 'evening';
              } else if (hasNight && (dt.hour >= 22 || dt.hour < 6)) {
                resolved = 'night';
              } else {
                resolved = CampSessionService.getCurrentSession(dt, branchId);
              }
            }
          }
        }

        if (sessionFilter == 'auto') {
          return true;
        }

        if (resolved.isNotEmpty) {
          return resolved == targetShift;
        }
        return true;
      }).toList();
    }

    // Search query filter
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      all = all.where((e) {
        final s = (e['serial'] ?? e['id'] ?? '').toString().toLowerCase();
        final n = (e['patientName'] ?? e['name'] ?? '').toString().toLowerCase();
        final c = (e['patientCnic'] ?? e['cnic'] ?? e['guardianCnic'] ?? '').toString().toLowerCase();
        final phone = (e['phone'] ?? '').toString().toLowerCase();
        return s.contains(q) || n.contains(q) || c.contains(q) || phone.contains(q);
      }).toList();
    }

    final pending   = <Map<String, dynamic>>[];
    final onHold    = <Map<String, dynamic>>[];
    final dispensed = <Map<String, dynamic>>[];

    for (final e in all) {
      String ds = (e['dispenseStatus'] ?? '').toString().toLowerCase();
      final st = (e['status'] ?? '').toString().toLowerCase();

      if (ds != 'dispensed' && st != 'dispensed') {
        final s = (e['serial'] ?? e['id'] ?? '').toString().trim();
        final dKey = (e['dateKey'] ?? todayKey).toString().trim();
        if (s.isNotEmpty && Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final dBox = Hive.box(LocalStorageService.dispensaryBox);
          final dispRec = dBox.get('${branchId}_${dKey}_$s') ??
              dBox.get('$branchId-$s') ??
              dBox.get(s);
          if (dispRec is Map) {
            final recStatus = (dispRec['dispenseStatus'] ?? dispRec['status'] ?? '').toString().toLowerCase();
            if (recStatus == 'dispensed' || recStatus == 'completed') {
              ds = 'dispensed';
              e['dispenseStatus'] = 'dispensed';
            }
          }
        }
      }

      if (ds == 'dispensed' || st == 'dispensed') {
        dispensed.add(e);
      } else if (ds == 'on_hold' || ds == 'hold') {
        onHold.add(e);
      } else {
        pending.add(e);
      }
    }

    // Fair order (server-numbered by number, offline-issued slotted in by issue time).
    _replaceSorted(pending, newestFirst);
    _replaceSorted(onHold, newestFirst);
    _replaceSorted(dispensed, newestFirst);

    if (filter == 'pending') {
      return [...pending, ...onHold];
    } else if (filter == 'dispensed') {
      return dispensed;
    }
    return [...pending, ...onHold, ...dispensed];
  }

  /// Never undo a dispense: when a (replayed or stale) prescription/entry event is
  /// merged into an entry, carry over the dispensed state from any existing copy of
  /// that token so it cannot flip back to "waiting to dispense".
  static void keepDispensedState(Map<String, dynamic> updated, Iterable<dynamic> existingCopies) {
    for (final c in existingCopies) {
      if (c is Map && (c['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') {
        for (final k in const ['dispenseStatus', 'dispensedAt', 'dispensedBy', 'dispenserName']) {
          if (c[k] != null) updated[k] = c[k];
        }
        return;
      }
    }
  }

  /// Token-number order (then creation time).
  static int compareTokens(Map<String, dynamic> a, Map<String, dynamic> b, {bool newestFirst = false}) {
    final numA = parseSequenceFromSerial((a['serial'] ?? a['id'] ?? '').toString());
    final numB = parseSequenceFromSerial((b['serial'] ?? b['id'] ?? '').toString());
    if (numA != numB) {
      return newestFirst ? numB.compareTo(numA) : numA.compareTo(numB);
    }
    final dtA = a['createdAt']?.toString() ?? '';
    final dtB = b['createdAt']?.toString() ?? '';
    return newestFirst ? dtB.compareTo(dtA) : dtA.compareTo(dtB);
  }

  /// Patients still to dispense (not dispensed, not on hold), in queue order.
  static List<Map<String, dynamic>> activePending(List<Map<String, dynamic>> queue) =>
      queue.where((p) => !isDispensed(p) && !isOnHold(p)).toList();

  /// Patients still to dispense, smallest token first whatever order [queue] is shown in.
  /// The auto-load and the "only the smallest can be opened" lock follow this: with the
  /// list sorted newest first they took the largest token and locked everything below it.
  /// A token another desk is dispensing right now is left out (see [claim]).
  static List<Map<String, dynamic>> pendingInTokenOrder(List<Map<String, dynamic>> queue) =>
      TokenOrder.sortFairly(
          activePending(queue).where((p) => !isClaimedByOtherDesk(p['serial'])));

  static void _replaceSorted(List<Map<String, dynamic>> list, bool newestFirst) {
    final sorted = TokenOrder.sortFairly(list, newestFirst: newestFirst);
    list
      ..clear()
      ..addAll(sorted);
  }

  // ── Dispense claims ──────────────────────────────────────────────────────
  // Every desk loads the smallest waiting token by itself, so two desks could open the same
  // patient and both dispense them (medicines and stock given twice). The desk that opens a
  // patient tells the others over the LAN; they skip that token while the claim lasts. When
  // two desks open the same token at once, both keep the claim made first (then the smaller
  // desk id), so they agree on the winner and the other moves to the next patient.
  // Claims are live only: a desk that closes stops renewing and its claim lapses.

  static const _claimTtl = Duration(seconds: 40);

  /// How often the open form renews its claim (well inside [_claimTtl]).
  static const claimRenewal = Duration(seconds: 15);

  static final Map<String, _Claim> _claims = {};

  /// Bumped whenever a token's claim changes hands or lapses; queue hosts re-pick on it.
  static final ValueNotifier<int> claimsChanged = ValueNotifier(0);

  static StreamSubscription<Map<String, dynamic>>? _claimSub;
  static Timer? _claimSweep;

  /// Starts following other desks' claims (once per app; safe to call again).
  static void listenForClaims() {
    _claimSub ??= RealtimeManager().messageStream.listen(_onClaimMessage);
    _claimSweep ??= Timer.periodic(claimRenewal, (_) {
      final before = _claims.length;
      _claims.removeWhere((_, c) => c.lapsed);
      if (_claims.length != before) claimsChanged.value++;
    });
  }

  static String? get _myDesk {
    final id = RealtimeManager().clientId;
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Whether another desk is dispensing this token now.
  static bool isClaimedByOtherDesk(Object? serial) {
    final me = _myDesk;
    if (me == null || me.isEmpty) return false;
    final c = _claims[(serial ?? '').toString().trim().toUpperCase()];
    return c != null && !c.lapsed && c.desk != me;
  }

  /// Returns the name of the other desk that has claimed this token, or null.
  static String? claimingDeskName(Object? serial) {
    final me = _myDesk;
    if (me == null || me.isEmpty) return null;
    final c = _claims[(serial ?? '').toString().trim().toUpperCase()];
    if (c != null && !c.lapsed && c.desk != me) {
      return c.deskName ?? 'Another Counter';
    }
    return null;
  }

  /// This desk has opened [serial] to dispense: tell the other desks (also used to renew).
  static void claim(String serial, String branchId, {String? deskName}) {
    final me = _myDesk;
    final s = serial.trim().toUpperCase();
    if (me == null || s.isEmpty) return;
    final held = _claims[s];
    if (held != null && !held.lapsed && held.desk != me) return; // another desk was first
    final at = held?.desk == me ? held!.at : DateTime.now().millisecondsSinceEpoch;
    _claims[s] = _Claim(me, at, deskName: deskName ?? held?.deskName);
    RealtimeManager().sendLive(RealtimeEvents.payload(
      type: 'dispense_claim',
      branchId: branchId,
      data: {'serial': s, 'desk': me, 'deskName': deskName, 'at': at},
    ));
  }

  /// This desk closed [serial] (dispensed, or moved to another patient).
  static void release(String serial, String branchId) {
    final me = _myDesk;
    final s = serial.trim().toUpperCase();
    if (me == null || _claims[s]?.desk != me) return;
    _claims.remove(s);
    RealtimeManager().sendLive(RealtimeEvents.payload(
      type: 'dispense_release',
      branchId: branchId,
      data: {'serial': s, 'desk': me},
    ));
  }

  static void _onClaimMessage(Map<String, dynamic> event) {
    final type = event['event_type'];
    if (type != 'dispense_claim' && type != 'dispense_release') return;
    final decoded = event['decoded'];
    if (decoded is Map &&
        (decoded['_serverPush'] == true || decoded['isCatchUp'] == true || decoded['_isReplay'] == true)) {
      return;
    }
    final data = event['data'];
    if (data is! Map) return;
    final s = (data['serial'] ?? '').toString().trim().toUpperCase();
    final desk = (data['desk'] ?? '').toString();
    if (s.isEmpty || desk.isEmpty || desk == _myDesk) return;

    final held = _claims[s];
    if (type == 'dispense_release') {
      if (held?.desk == desk) {
        _claims.remove(s);
        claimsChanged.value++;
      }
      return;
    }
    final incoming = _Claim(
      desk,
      (data['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      deskName: data['deskName']?.toString(),
    );
    if (held == null || held.lapsed || held.desk == desk || incoming.isBefore(held)) {
      final changedHands = held == null || held.lapsed || held.desk != desk;
      _claims[s] = held?.desk == desk
          ? _Claim(desk, held!.at, deskName: data['deskName']?.toString() ?? held.deskName)
          : incoming;
      if (changedHands) claimsChanged.value++;
    }
  }

  /// Same token, whatever the casing. A prescription from the doctor re-wrote the entry's
  /// serial in lower case, so an exact compare took the open patient as gone and switched.
  static bool sameSerial(Object? a, Object? b) {
    final x = (a ?? '').toString().trim().toUpperCase();
    return x.isNotEmpty && x == (b ?? '').toString().trim().toUpperCase();
  }

  /// Who the dispense form should show: keeps [currentSerial] while it is still
  /// waiting (never switches away mid-dispense), otherwise the next in line;
  /// null when nobody is waiting. [skipSerial] is left out (e.g. the patient just
  /// dispensed, before the queue has caught up).
  static Map<String, dynamic>? pickNext(
    List<Map<String, dynamic>> queue, {
    String? currentSerial,
    String? skipSerial,
  }) {
    final skip = skipSerial?.trim().toUpperCase() ?? '';
    final pending = pendingInTokenOrder(queue)
        .where((p) => skip.isEmpty || !sameSerial(p['serial'], skip))
        .toList();
    if (pending.isEmpty) return null;
    final cur = currentSerial?.trim() ?? '';
    if (cur.isNotEmpty) {
      for (final p in pending) {
        if (sameSerial(p['serial'], cur)) return p;
      }
    }
    return pending.first;
  }
}

class _Claim {
  _Claim(this.desk, this.at, {this.deskName}) : seenAt = DateTime.now();

  /// The claiming desk's LAN client id.
  final String desk;

  /// Optional readable name of the desk.
  final String? deskName;

  /// When that desk opened the patient (its clock); the earlier claim wins.
  final int at;

  /// When this desk last heard of it; the claim lapses [DispenseQueue._claimTtl] later.
  final DateTime seenAt;

  bool get lapsed => DateTime.now().difference(seenAt) > DispenseQueue._claimTtl;

  bool isBefore(_Claim other) => at != other.at ? at < other.at : desk.compareTo(other.desk) < 0;
}
