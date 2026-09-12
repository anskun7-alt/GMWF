import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';

class CampSessionService {
  static const String _activeCampKey = 'active_camp_id';

  static const Map<String, String> _knownLabels = {
    'saddar': 'Saddar Dispensary',
    'kapayya': 'Saddar Dispensary',
    'kapaya': 'Saddar Dispensary',
    'haji_camp': 'Haji Camp Dispensary',
  };

  /// Returns user-friendly label for a camp ID, dynamically looking up branch-specific configured camps if available.
  static String getCampLabel(String id, [String? branchId]) {
    final key = id.trim().toLowerCase();
    if (_knownLabels.containsKey(key)) return _knownLabels[key]!;

    if (branchId != null && branchId.trim().isNotEmpty) {
      final camps = getCampsForBranch(branchId, includeClosed: true);
      for (final c in camps) {
        if ((c['id'] ?? '').toString().toLowerCase().trim() == key) {
          final name = (c['name'] ?? '').toString().trim();
          if (name.isNotEmpty) return name;
        }
      }
    }

    // Try all open branches in local cache
    try {
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        for (final bKey in box.keys) {
          final bVal = box.get(bKey);
          if (bVal is Map && bVal['camps'] is List) {
            for (final c in bVal['camps']) {
              if (c is Map && (c['id'] ?? '').toString().toLowerCase().trim() == key) {
                final name = (c['name'] ?? '').toString().trim();
                if (name.isNotEmpty) return name;
              }
            }
          }
        }
      }
    } catch (_) {}

    return id.split('_').map((word) => word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}').join(' ');
  }

  /// Retrieves all configured camps for a branch from local cache / defaults.
  static List<Map<String, dynamic>> getCampsForBranch(String? branchId, {bool includeClosed = false}) {
    if (branchId == null || branchId.trim().isEmpty) return [];
    final b = branchId.trim().toLowerCase();
    final List<Map<String, dynamic>> result = [];

    try {
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        final raw = box.get('branch:$b') ?? box.get(b);
        if (raw is Map) {
          if (raw['camps'] is List && (raw['camps'] as List).isNotEmpty) {
            for (final item in raw['camps'] as List) {
              if (item is Map) {
                final cMap = Map<String, dynamic>.from(item);
                final isClosed = cMap['isClosed'] == true || cMap['status'] == 'closed' || cMap['status'] == 'offboarded';
                cMap['isClosed'] = isClosed;
                cMap['status'] = isClosed ? 'closed' : 'active';
                if (includeClosed || !isClosed) {
                  result.add(cMap);
                }
              }
            }
            if (result.isNotEmpty || (raw['camps'] as List).isNotEmpty) {
              return result;
            }
          }

          // Fallback: Infer from multiple dispensaries if camps not explicitly configured
          if (raw['dispensaries'] is List && (raw['dispensaries'] as List).length > 1) {
            for (final d in raw['dispensaries'] as List) {
              if (d is Map) {
                final dMap = Map<String, dynamic>.from(d);
                final dId = (dMap['id'] ?? '').toString().trim().toLowerCase();
                final dName = (dMap['name'] ?? dId).toString().trim();
                if (dId.isNotEmpty) {
                  result.add({
                    'id': dId,
                    'name': dName.isNotEmpty ? dName : getCampLabel(dId),
                    'status': 'active',
                    'isClosed': false,
                    'departments': ['dispensary'],
                    'sessions': dMap['sessions'] is List ? List<String>.from(dMap['sessions']) : ['morning', 'evening'],
                    'sessionTimings': dMap['sessionTimings'] is Map ? Map<String, dynamic>.from(dMap['sessionTimings']) : {},
                  });
                }
              }
            }
            return result;
          }
        }
      }
    } catch (_) {}

    // Fallback: Default branch facilities
    if (b == 'karachi') {
      final defaultKarachiCamps = [
        {
          'id': 'saddar',
          'name': 'Saddar Dispensary',
          'status': 'active',
          'isClosed': false,
          'departments': ['dispensary', 'dasterkhwaan'],
          'sessions': ['morning', 'evening'],
        },
        {
          'id': 'haji_camp',
          'name': 'Haji Camp Dispensary',
          'status': 'active',
          'isClosed': false,
          'departments': ['dispensary'],
          'sessions': ['morning', 'evening'],
        },
      ];
      return defaultKarachiCamps;
    }

    return result;
  }

  /// Checks if a branch operates multi-camp facility sub-locations.
  static bool hasCampsForBranch(String? branchId) {
    if (branchId == null || branchId.trim().isEmpty) return false;
    final b = branchId.trim().toLowerCase();

    // 1. Dynamic check for configured camps (active or configured)
    final camps = getCampsForBranch(b, includeClosed: true);
    if (camps.isNotEmpty) {
      // If camps exist, check if there is at least 1 active camp or multiple camps
      return true;
    }

    if (b == 'karachi') return true;

    return false;
  }

  /// Saves camps list for a branch locally to Hive and syncs to Firestore asynchronously.
  static Future<void> saveBranchCamps(String branchId, List<Map<String, dynamic>> camps) async {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty) return;

    try {
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        final raw = box.get('branch:$b') ?? box.get(b);
        final map = raw is Map ? Map<String, dynamic>.from(raw) : {'id': branchId};
        map['camps'] = camps;
        map['campsCount'] = camps.length;
        await box.put('branch:$b', map);
      }
    } catch (e) {
      debugPrint('[CampSessionService] Error saving camps to local Hive: $e');
    }

    try {
      await FirebaseFirestore.instance.collection('branches').doc(branchId).set({
        'camps': camps,
        'campsCount': camps.length,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[CampSessionService] Error syncing camps to Firestore: $e');
    }
  }

  /// Closes (archives) or reactivates a camp under a branch, preserving all historic data.
  static Future<void> setCampStatus(
    String branchId,
    String campId, {
    required bool isClosed,
    String? reason,
    String? performedBy,
  }) async {
    final camps = getCampsForBranch(branchId, includeClosed: true);
    final nowIso = getAuthoritativeTime().toIso8601String();
    final user = performedBy ?? 'Admin';

    bool found = false;
    for (int i = 0; i < camps.length; i++) {
      if ((camps[i]['id'] ?? '').toString().toLowerCase().trim() == campId.toLowerCase().trim()) {
        camps[i]['isClosed'] = isClosed;
        camps[i]['status'] = isClosed ? 'closed' : 'active';
        if (isClosed) {
          camps[i]['closedAt'] = nowIso;
          camps[i]['closedBy'] = user;
          camps[i]['closureReason'] = reason ?? '';
          camps[i]['reactivatedAt'] = null;
        } else {
          camps[i]['reactivatedAt'] = nowIso;
          camps[i]['reactivatedBy'] = user;
          camps[i]['reactivationRemarks'] = reason ?? '';
          camps[i]['closedAt'] = null;
        }
        found = true;
        break;
      }
    }

    if (found) {
      await saveBranchCamps(branchId, camps);
    }
  }

  /// Validates if a serial belongs to the specified branch.
  /// Prevents LAN broadcasts or stale Hive entries from other branches (e.g. 'kap')
  /// from leaking into this branch's queue.
  static bool isSerialMatchingBranch(String? serial, String? branchId) {
    if (serial == null || serial.trim().isEmpty) return true;
    if (branchId == null || branchId.trim().isEmpty) return true;
    final b = branchId.toLowerCase().trim();
    final s = serial.toUpperCase().trim();
    final parts = s.split('-');
    if (parts.length >= 2) {
      final tag = parts[1].toLowerCase();
      // Karianwala tag (KAP)
      if (tag == 'kap' && !b.contains('kap') && !b.contains('karianwala')) return false;
      // Jalalpur Jattan tags (JLJ / JPJ)
      if ((tag == 'jlj' || tag == 'jpj') && !b.contains('jalalpur') && !b.contains('jattan') && !b.contains('temp')) return false;
      // Gujrat tags (GRT / GJT)
      if ((tag == 'grt' || tag == 'gjt') && !b.contains('gujrat')) return false;
      // Sialkot tag (SKT)
      if (tag == 'skt' && !b.contains('sialkot')) return false;
      // Lahore tag (LHR)
      if (tag == 'lhr' && !b.contains('lahore')) return false;
      // Rawalpindi tags (RWP / PND)
      if ((tag == 'rwp' || tag == 'pnd') && !b.contains('rawalpindi') && !b.contains('pindi')) return false;
      // Karachi camp tags (SADD / SADDAR / HAJI / KAPAYYA)
      if ((tag == 'saddar' || tag == 'sadd' || tag == 'haji_camp' || tag == 'haji' || tag == 'kapayya') && !b.contains('karachi')) return false;
    }
    return true;
  }

  /// Get formatted display string combining Branch Name and Camp Name.
  /// If the branch does NOT operate multi-camp facilities, returns ONLY the branch name.
  static String getBranchAndCampDisplayName({
    required String branchName,
    String? branchId,
    String? campId,
  }) {
    if (branchId != null && !hasCampsForBranch(branchId)) {
      return branchName;
    }

    final effectiveCamp = (campId != null && campId.isNotEmpty && campId != 'all')
        ? campId
        : getActiveCamp();

    if (effectiveCamp == null || effectiveCamp.isEmpty || effectiveCamp == 'all') {
      return branchName;
    }
    final campName = getCampLabel(effectiveCamp);
    return '$branchName — $campName';
  }

  static const String _boundCampKey    = 'bound_dispensary_id';
  static const String _serverOffsetKey = 'server_offset_ms';

  /// ValueNotifier exposing detected clock drift between PC clock and authoritative server time.
  static final ValueNotifier<ClockSkewInfo?> clockSkewNotifier = ValueNotifier<ClockSkewInfo?>(null);

  /// Get authoritative time adjusted by server clock offset
  static DateTime getAuthoritativeTime() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final offset = Hive.box('app_settings').get(_serverOffsetKey);
        if (offset is int && offset != 0) {
          return DateTime.now().add(Duration(milliseconds: offset));
        }
      }
    } catch (_) {}
    return DateTime.now();
  }

  /// Evaluates whether the local PC clock has drifted significantly from authoritative server time.
  static void checkClockSkew() {
    try {
      final local = DateTime.now();
      final auth = getAuthoritativeTime();
      final diffMinutes = auth.difference(local).inMinutes;
      final localSession = resolveShiftAndDateKey(local).session;
      final authSession = resolveShiftAndDateKey(auth).session;
      final mismatch = localSession != authSession;

      if (diffMinutes.abs() >= 5 || mismatch) {
        clockSkewNotifier.value = ClockSkewInfo(
          localTime: local,
          authoritativeTime: auth,
          offsetMinutes: diffMinutes,
          localSession: localSession,
          authoritativeSession: authSession,
          hasShiftMismatch: mismatch,
        );
      } else {
        clockSkewNotifier.value = null;
      }
    } catch (e) {
      debugPrint('[CampSessionService] checkClockSkew error: $e');
    }
  }

  /// Update server clock offset whenever cloud or LAN sync completes and refresh skew notifier
  static Future<void> updateServerOffset(DateTime serverTime) async {
    try {
      final offset = serverTime.difference(DateTime.now()).inMilliseconds;
      if (Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').put(_serverOffsetKey, offset);
      }
      checkClockSkew();
    } catch (e) {
      debugPrint('[CampSessionService] Error updating server offset: $e');
    }
  }

  /// Clear the saved server offset (resets to local PC clock)
  static Future<void> clearServerOffset() async {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').delete(_serverOffsetKey);
      }
      checkClockSkew();
    } catch (e) {
      debugPrint('[CampSessionService] Error clearing server offset: $e');
    }
  }

  /// Fetches authoritative Date and Time from reliable internet time sources
  /// (HTTP Date header or Time APIs) and synchronizes internal clock offset.
  static Future<DateTime?> syncInternetTime() async {
    DateTime? resolvedTime;

    // Source 1: Standard HTTP Date Header (Ultra fast, zero rate limit, universally available)
    final probeUrls = [
      'https://www.google.com',
      'https://firebase.google.com',
      'https://cloudflare.com',
    ];

    for (final url in probeUrls) {
      try {
        final res = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 3));
        final dateHeader = res.headers['date'];
        if (dateHeader != null && dateHeader.isNotEmpty) {
          final parsed = HttpDate.parse(dateHeader);
          resolvedTime = parsed.toLocal();
          break;
        }
      } catch (_) {}
    }

    // Source 2: TimeAPI fallback
    if (resolvedTime == null) {
      try {
        final res = await http
            .get(Uri.parse('https://timeapi.io/api/time/current/zone?timeZone=Asia/Karachi'))
            .timeout(const Duration(seconds: 4));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map && data['dateTime'] != null) {
            resolvedTime = DateTime.tryParse(data['dateTime'].toString());
          }
        }
      } catch (_) {}
    }

    if (resolvedTime != null) {
      await updateServerOffset(resolvedTime);
      debugPrint('[CampSessionService] Internet Date & Time synchronized: $resolvedTime (Offset: ${resolvedTime.difference(DateTime.now()).inMinutes} mins)');
      return resolvedTime;
    }

    return null;
  }

  /// Re-aligns tokens created within the last 24 hours
  /// into today's active dateKey and shift so Doctor & Dispenser can process them.
  static Future<int> realignOrphanedTokens({
    required String branchId,
    bool includeCompleted = false,
    String? targetShift,
  }) async {
    int fixedCount = 0;
    try {
      if (!Hive.isBoxOpen('local_entries')) {
        await Hive.openBox('local_entries');
      }
      final box = Hive.box('local_entries');
      final normBranch = branchId.toLowerCase().trim();
      final currentShiftInfo = resolveShiftAndDateKey();
      final activeDateKey = currentShiftInfo.dateKey;
      final activeShift = targetShift ?? currentShiftInfo.session;

      final now = getAuthoritativeTime();

      for (final key in box.keys) {
        final kStr = key.toString().toLowerCase();
        if (!kStr.startsWith('$normBranch-')) continue;

        final raw = box.get(key);
        if (raw is! Map) continue;

        final entry = Map<String, dynamic>.from(raw);
        final status = (entry['status'] as String?)?.toLowerCase().trim() ?? '';
        final hasPrescription = (entry['prescriptionId'] as String?)?.isNotEmpty == true;

        // Realign waiting entries, or completed if includeCompleted is true
        final isEligible = includeCompleted || ((status.isEmpty || status == 'waiting' || status == 'pending') && !hasPrescription);
        if (isEligible) {
          final entryDateKey = (entry['dateKey'] ?? '').toString().trim();
          final entrySession = (entry['session'] ?? '').toString().trim().toLowerCase();

          // Check timestamp age
          final rawTime = entry['timestamp'] ?? entry['createdAt'] ?? entry['date'];
          DateTime? entryTime;
          if (rawTime != null) {
            entryTime = DateTime.tryParse(rawTime.toString());
          }

          final isRecent = entryTime == null || now.difference(entryTime).inHours.abs() <= 24;

          final hasValidSession = entrySession.isNotEmpty && entrySession != 'unknown' && entrySession != 'auto';
          final prevDateKey = DateFormat('ddMMyy').format(now.subtract(const Duration(days: 1)));
          final isAlreadyValidDate = entryDateKey == activeDateKey || entryDateKey == prevDateKey;
          final needsDateFix = entryDateKey.isEmpty || (!isAlreadyValidDate && isRecent);
          final needsSessionFix = !hasValidSession;

          if (isRecent && (needsDateFix || needsSessionFix)) {
            if (needsDateFix) {
              entry['dateKey'] = activeDateKey;
            }
            if (needsSessionFix) {
              final effectiveTime = entryTime ?? now;
              entry['session'] = getCurrentSession(effectiveTime, branchId);
            }
            entry['realignedAt'] = now.toIso8601String();
            await box.put(key, entry);
            fixedCount++;

            // Broadcast via LAN & update Firestore
            try {
              RealtimeManager().sendMessage(RealtimeEvents.payload(
                type: RealtimeEvents.saveEntry,
                branchId: branchId,
                data: entry,
              ));
            } catch (_) {}

            final serial = (entry['serial'] ?? entry['id'])?.toString();
            if (serial != null && serial.isNotEmpty) {
              final queueType = _resolveQueueType(entry['queueType']?.toString() ?? entry['status']?.toString());
              final campDocKey = getCampDateDocId(
                branchId: branchId,
                dateKey: activeDateKey,
                campId: entry['campId']?.toString() ?? entry['dispensaryId']?.toString(),
                dispensaryTag: entry['dispensaryTag']?.toString(),
                serial: serial,
              );
              FirebaseFirestore.instance
                  .collection('branches').doc(branchId)
                  .collection('serials').doc(campDocKey)
                  .collection(queueType).doc(serial)
                  .set({'session': activeShift, 'dateKey': activeDateKey, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true))
                  .catchError((_) {});
            }
          }
        }
      }
      debugPrint('[CampSessionService] Re-aligned $fixedCount token(s) into shift: $activeShift, dateKey: $activeDateKey');
    } catch (e) {
      debugPrint('[CampSessionService] Error realigning tokens: $e');
    }
    return fixedCount;
  }

  /// Restores tokens that were accidentally realigned by auto-align
  /// back to their original dateKey and shift extracted from their serial or creation timestamp.
  static Future<int> restoreRealignedTokens({
    required String branchId,
  }) async {
    int restoredCount = 0;
    try {
      if (!Hive.isBoxOpen('local_entries')) {
        await Hive.openBox('local_entries');
      }
      final box = Hive.box('local_entries');
      final normBranch = branchId.toLowerCase().trim();
      final currentShiftInfo = resolveShiftAndDateKey();
      final todayDateKey = currentShiftInfo.dateKey;

      for (final key in box.keys) {
        final kStr = key.toString().toLowerCase();
        if (!kStr.startsWith('$normBranch-') && !kStr.contains(normBranch)) continue;

        final raw = box.get(key);
        if (raw is! Map) continue;

        final entry = Map<String, dynamic>.from(raw);
        final serial = (entry['serial'] ?? entry['id'] ?? '').toString().trim();
        
        // Extract true original dateKey from serial or createdAt
        String? originalDateKey;
        if (serial.isNotEmpty) {
          final sDk = getDateKeyFromSerial(serial);
          if (sDk.length == 6 && int.tryParse(sDk) != null) {
            originalDateKey = sDk;
          }
        }
        
        if (originalDateKey == null) {
          final rawTime = entry['createdAt'] ?? entry['timestamp'] ?? entry['date'];
          if (rawTime != null) {
            final dt = DateTime.tryParse(rawTime.toString());
            if (dt != null) {
              originalDateKey = DateFormat('ddMMyy').format(dt);
            }
          }
        }

        final currentDateKey = (entry['dateKey'] ?? '').toString().trim();
        final wasRealigned = entry.containsKey('realignedAt') || (originalDateKey != null && originalDateKey != currentDateKey);

        if (wasRealigned && originalDateKey != null && originalDateKey.isNotEmpty) {
          // Resolve original session based on creation timestamp
          String originalSession = (entry['originalSession'] ?? entry['session'] ?? 'morning').toString().trim().toLowerCase();
          final rawTime = entry['createdAt'] ?? entry['timestamp'] ?? entry['date'];
          if (rawTime != null) {
            final dt = DateTime.tryParse(rawTime.toString());
            if (dt != null) {
              originalSession = resolveShiftAndDateKey(dt).session;
            }
          }

          entry['dateKey'] = originalDateKey;
          entry['session'] = originalSession;
          entry.remove('realignedAt');
          await box.put(key, entry);
          restoredCount++;

          // Broadcast LAN update
          try {
            RealtimeManager().sendMessage(RealtimeEvents.payload(
              type: RealtimeEvents.saveEntry,
              branchId: branchId,
              data: entry,
            ));
          } catch (_) {}

          // Update Firestore: Delete from today's dateKey collection if moved, and restore under original dateKey
          if (serial.isNotEmpty) {
            final queueType = _resolveQueueType(entry['queueType']?.toString() ?? entry['status']?.toString());
            
            if (currentDateKey == todayDateKey && currentDateKey != originalDateKey) {
              final todayDocKey = getCampDateDocId(
                branchId: branchId,
                dateKey: todayDateKey,
                campId: entry['campId']?.toString() ?? entry['dispensaryId']?.toString(),
                dispensaryTag: entry['dispensaryTag']?.toString(),
                serial: serial,
              );
              FirebaseFirestore.instance
                  .collection('branches').doc(branchId)
                  .collection('serials').doc(todayDocKey)
                  .collection(queueType).doc(serial)
                  .delete()
                  .catchError((_) {});
            }

            final origDocKey = getCampDateDocId(
              branchId: branchId,
              dateKey: originalDateKey,
              campId: entry['campId']?.toString() ?? entry['dispensaryId']?.toString(),
              dispensaryTag: entry['dispensaryTag']?.toString(),
              serial: serial,
            );
            FirebaseFirestore.instance
                .collection('branches').doc(branchId)
                .collection('serials').doc(origDocKey)
                .collection(queueType).doc(serial)
                .set({
                  ...entry,
                  'session': originalSession,
                  'dateKey': originalDateKey,
                  'updatedAt': FieldValue.serverTimestamp(),
                }, SetOptions(merge: true))
                .catchError((_) {});
          }
        }
      }
      debugPrint('[CampSessionService] Restored $restoredCount token(s) back to original dateKey for $branchId');
    } catch (e) {
      debugPrint('[CampSessionService] Error restoring tokens: $e');
    }
    return restoredCount;
  }

  static String _resolveQueueType(String? raw) {
    final s = (raw ?? '').toLowerCase().trim();
    if (s.contains('non')) return 'non-zakat';
    if (s.contains('gmwf')) return 'gmwf';
    return 'zakat';
  }

  /// Update the session / shift of a single specific token
  static Future<bool> updateTokenSession({
    required String branchId,
    required String serial,
    required String newSession,
  }) async {
    try {
      if (!Hive.isBoxOpen('local_entries')) {
        await Hive.openBox('local_entries');
      }
      final box = Hive.box('local_entries');
      final normBranch = branchId.toLowerCase().trim();
      final normSerial = serial.toLowerCase().trim();
      final cleanSession = newSession.toLowerCase().trim();

      Map<String, dynamic>? updatedEntry;

      for (final key in box.keys) {
        final kStr = key.toString().toLowerCase();
        if (kStr == '$normBranch-$normSerial' || kStr == normSerial || kStr.endsWith('-$normSerial')) {
          final raw = box.get(key);
          if (raw is Map) {
            final entry = Map<String, dynamic>.from(raw);
            entry['session'] = cleanSession;
            entry['sessionUpdatedAt'] = getAuthoritativeTime().toIso8601String();
            await box.put(key, entry);
            updatedEntry = entry;
          }
        }
      }

      if (updatedEntry != null) {
        // Also put canonical key
        await box.put('$normBranch-${serial.toUpperCase()}', updatedEntry);

        // 1. Broadcast via LAN
        try {
          RealtimeManager().sendMessage(RealtimeEvents.payload(
            type: RealtimeEvents.saveEntry,
            branchId: branchId,
            data: updatedEntry,
          ));
        } catch (_) {}

        // 2. Persist to Firestore serials doc
        try {
          final dateKey = getDateKeyFromSerial(serial);
          final queueType = _resolveQueueType(updatedEntry['queueType']?.toString() ?? updatedEntry['status']?.toString());
          final campDocKey = getCampDateDocId(
            branchId: branchId,
            dateKey: dateKey,
            campId: updatedEntry['campId']?.toString() ?? updatedEntry['dispensaryId']?.toString(),
            dispensaryTag: updatedEntry['dispensaryTag']?.toString(),
            serial: serial,
          );
          FirebaseFirestore.instance
              .collection('branches').doc(branchId)
              .collection('serials').doc(campDocKey)
              .collection(queueType).doc(serial)
              .set({'session': cleanSession, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true))
              .catchError((_) {});
        } catch (_) {}

        return true;
      }
    } catch (e) {
      debugPrint('[CampSessionService] Error updating token session: $e');
    }
    return false;
  }

  /// Get hardware device-desk bound dispensary ID
  static String? getBoundDispensaryId() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final val = Hive.box('app_settings').get(_boundCampKey)?.toString().trim().toLowerCase();
        if (val != null && val.isNotEmpty && val != 'all') return val;
      }
    } catch (_) {}
    return null;
  }

  /// Bind hardware device to a specific dispensary desk
  static Future<void> setBoundDispensaryId(String? dispensaryId) async {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        if (dispensaryId == null || dispensaryId.trim().isEmpty) {
          await Hive.box('app_settings').delete(_boundCampKey);
        } else {
          await Hive.box('app_settings').put(_boundCampKey, dispensaryId.trim().toLowerCase());
        }
      }
    } catch (e) {
      debugPrint('[CampSessionService] Error setting bound dispensary: $e');
    }
  }

  /// Write-safe camp resolver. Unlike getActiveCamp(), this NEVER falls back
  /// to the mutable, session-wide active_camp_id — so it can't be silently
  /// changed out from under a write operation by another concurrently-open
  /// tab. Returns null (with a debug warning) if this desk has no hardware
  /// binding, rather than guessing.
  static String? requireBoundDispensaryId(String branchId) {
    final bound = getBoundDispensaryId();
    if (bound != null && bound.isNotEmpty) return bound;
    debugPrint(
      '[CampSessionService] ⚠️ requireBoundDispensaryId: no bound dispensary '
      'set for branch "$branchId". Refusing to fall back to the mutable '
      'session-wide active camp for a write operation.',
    );
    return null;
  }

  /// Default session config fallback if not yet configured in branch settings.
  /// Default session config fallback if not yet configured in branch settings.
  static Map<String, dynamic> getDefaultSessionConfig([String? branchId, String? department]) {
    final b = (branchId ?? '').toLowerCase().trim();
    final dep = (department ?? '').toLowerCase().trim();

    if (dep == 'dasterkhwaan' || dep == 'kitchen' || dep == 'food') {
      return {
        'morning': {'enabled': true, 'openTime': '06:00', 'closeTime': '10:00'},
        'lunch':   {'enabled': true, 'openTime': '12:00', 'closeTime': '16:00'},
        'dinner':  {'enabled': true, 'openTime': '18:00', 'closeTime': '22:00'},
        'night':   {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'},
      };
    } else if (dep == 'madrassa') {
      return {
        'morning': {'enabled': true, 'openTime': '06:00', 'closeTime': '12:00'},
        'evening': {'enabled': true, 'openTime': '14:00', 'closeTime': '18:00'},
        'night':   {'enabled': false, 'openTime': '19:00', 'closeTime': '22:00'},
      };
    } else if (dep == 'school') {
      return {
        'morning': {'enabled': true, 'openTime': '07:30', 'closeTime': '13:30'},
        'evening': {'enabled': false, 'openTime': '14:00', 'closeTime': '18:00'},
        'night':   {'enabled': false, 'openTime': '18:30', 'closeTime': '21:30'},
      };
    }

    // Default / Dispensary / Overall Branch
    if (b.contains('sialkot')) {
      return {
        'morning': {'enabled': true, 'openTime': '09:00', 'closeTime': '14:00'},
        'evening': {'enabled': true, 'openTime': '17:00', 'closeTime': '21:00'},
        'night': {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'},
      };
    } else if (b.contains('karachi')) {
      return {
        'morning': {'enabled': true, 'openTime': '08:00', 'closeTime': '14:00'},
        'evening': {'enabled': true, 'openTime': '16:00', 'closeTime': '22:00'},
        'night': {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'},
      };
    }

    return {
      'morning': {'enabled': true, 'openTime': '08:00', 'closeTime': '14:00'},
      'evening': {'enabled': true, 'openTime': '16:00', 'closeTime': '22:00'},
      'night': {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'},
    };
  }

  /// Returns the configured operational sessions and timing windows for a branch (and optional department).
  static Map<String, dynamic> getSessionConfig(String? branchId, {String? department, String? facilityId}) {
    final dep = (department ?? '').toLowerCase().trim();
    if (branchId != null && branchId.trim().isNotEmpty && branchId != 'all' && branchId != 'global') {
      final b = branchId.toLowerCase().trim();
      try {
        if (Hive.isBoxOpen('local_branches')) {
          final raw = Hive.box('local_branches').get('branch:$b');
          if (raw is Map && raw['sessionsConfig'] is Map) {
            final conf = Map<String, dynamic>.from(raw['sessionsConfig'] as Map);
            if (dep.isNotEmpty && conf[dep] is Map) {
              return Map<String, dynamic>.from(conf[dep] as Map);
            }
            return conf;
          }
        }
      } catch (_) {}
      return getDefaultSessionConfig(b, dep);
    }
    return getDefaultSessionConfig('default', dep);
  }

  /// Returns the configured operational sessions and timing windows for Dasterkhwaan.
  /// Converts 24-hour time (e.g. '17:00' or '07:30') or raw string to 12-hour format (e.g. '05:00 PM' or '07:30 AM')
  static String formatTo12Hour(String? timeStr) {
    if (timeStr == null || timeStr.trim().isEmpty) return '';
    final clean = timeStr.trim();
    if (clean.toUpperCase().contains('AM') || clean.toUpperCase().contains('PM')) {
      return clean;
    }
    final parts = clean.split(':');
    if (parts.isEmpty) return clean;
    int hour = int.tryParse(parts[0]) ?? 0;
    int minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final period = hour >= 12 ? 'PM' : 'AM';
    final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final hStr = h12.toString().padLeft(2, '0');
    final mStr = minute.toString().padLeft(2, '0');
    return '$hStr:$mStr $period';
  }

  /// Returns the configured operational sessions and timing windows for Dasterkhwaan (Breakfast, Lunch, Dinner).
  static Map<String, dynamic> getDasterkhwaanSessionConfig(String? branchId) {
    final conf = getSessionConfig(branchId, department: 'dasterkhwaan');
    
    // Read configured meals or map legacy morning/evening/night to breakfast/lunch/dinner
    final bf = conf['breakfast'];
    final lunch = conf['lunch'] ?? conf['morning'];
    final dinner = conf['dinner'] ?? conf['evening'] ?? conf['night'];

    final res = <String, dynamic>{};

    if (bf is Map) {
      if (bf['enabled'] != false) {
        res['breakfast'] = {
          'enabled': true,
          'openTime': formatTo12Hour(bf['openTime']?.toString() ?? '07:00'),
          'closeTime': formatTo12Hour(bf['closeTime']?.toString() ?? '11:30'),
        };
      }
    }

    if (lunch is Map) {
      if (lunch['enabled'] != false) {
        res['lunch'] = {
          'enabled': true,
          'openTime': formatTo12Hour(lunch['openTime']?.toString() ?? '12:00'),
          'closeTime': formatTo12Hour(lunch['closeTime']?.toString() ?? '16:30'),
        };
      }
    }

    if (dinner is Map) {
      if (dinner['enabled'] != false) {
        res['dinner'] = {
          'enabled': true,
          'openTime': formatTo12Hour(dinner['openTime']?.toString() ?? '17:00'),
          'closeTime': formatTo12Hour(dinner['closeTime']?.toString() ?? '23:59'),
        };
      }
    }

    // Default configuration if none explicitly configured in branch
    if (res.isEmpty) {
      res['breakfast'] = {'enabled': true, 'openTime': '07:00 AM', 'closeTime': '11:30 AM'};
      res['lunch'] = {'enabled': true, 'openTime': '12:00 PM', 'closeTime': '04:30 PM'};
      res['dinner'] = {'enabled': true, 'openTime': '05:00 PM', 'closeTime': '11:59 PM'};
    }

    return res;
  }

  /// Dynamically resolves whether current time belongs to breakfast, lunch, or dinner session for Dasterkhwaan.
  /// Rule:
  /// - Breakfast: Before 12:00 PM
  /// - Lunch: After 12:00 PM (12:00 PM to 5:00 PM)
  /// - Dinner: After 5:00 PM up to 12:00 AM midnight
  static String resolveDasterkhwaanSession([DateTime? time, String? branchId]) {
    final dt = time ?? getAuthoritativeTime();
    final hour = dt.hour; // 0 to 23

    String candidate;
    if (hour < 12) {
      candidate = 'breakfast';
    } else if (hour < 17) {
      candidate = 'lunch';
    } else {
      candidate = 'dinner';
    }

    final config = getDasterkhwaanSessionConfig(branchId);
    if (config.containsKey(candidate) && (config[candidate]['enabled'] == true)) {
      return candidate;
    }

    // If candidate meal is not enabled in this branch, fallback to the first enabled meal
    for (final key in ['breakfast', 'lunch', 'dinner']) {
      if (config.containsKey(key) && config[key]['enabled'] == true) {
        return key;
      }
    }

    return candidate;
  }

  /// Updates Dasterkhwaan session timings locally in Hive and pushes to Firestore
  static Future<void> saveDasterkhwaanSessionConfig(
    String branchId, {
    Map<String, dynamic>? sessionMap,
    String? breakfastOpen,
    String? breakfastClose,
    bool breakfastEnabled = true,
    String? lunchOpen,
    String? lunchClose,
    bool lunchEnabled = true,
    String? dinnerOpen,
    String? dinnerClose,
    bool dinnerEnabled = true,
    String? eveningOpen,
    String? eveningClose,
    String? nightOpen,
    String? nightClose,
  }) async {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty) return;

    final dasterkhwaanConfig = sessionMap ?? {
      'breakfast': {
        'enabled': breakfastEnabled,
        'openTime': breakfastOpen ?? '07:00 AM',
        'closeTime': breakfastClose ?? '11:30 AM',
      },
      'lunch': {
        'enabled': lunchEnabled,
        'openTime': lunchOpen ?? '12:00 PM',
        'closeTime': lunchClose ?? '04:30 PM',
      },
      'dinner': {
        'enabled': dinnerEnabled,
        'openTime': dinnerOpen ?? eveningOpen ?? '05:00 PM',
        'closeTime': dinnerClose ?? eveningClose ?? '11:59 PM',
      },
    };

    try {
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        final raw = box.get('branch:$b');
        if (raw is Map) {
          final updated = Map<String, dynamic>.from(raw);
          final sessions = (updated['sessionsConfig'] is Map)
              ? Map<String, dynamic>.from(updated['sessionsConfig'] as Map)
              : <String, dynamic>{};
          sessions['dasterkhwaan'] = dasterkhwaanConfig;
          updated['sessionsConfig'] = sessions;
          await box.put('branch:$b', updated);
        }
      }
    } catch (_) {}

    try {
      await FirebaseFirestore.instance.collection('branches').doc(b).set({
        'sessionsConfig': {'dasterkhwaan': dasterkhwaanConfig}
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// Returns the list of enabled session keys for a branch and optional department/facility/user.
  static List<String> getAllowedSessions(String? branchId, {String? department, String? facilityId, Map<String, dynamic>? userData}) {
    final dep = (department ?? '').toLowerCase().trim();
    final config = getSessionConfig(branchId, department: dep, facilityId: facilityId);
    final List<String> allowed = [];

    // 1. Get enabled sessions from configuration
    final knownSessions = dep == 'dasterkhwaan' || dep == 'kitchen' || dep == 'food'
        ? ['morning', 'lunch', 'dinner', 'night']
        : ['morning', 'evening', 'night'];

    for (final s in knownSessions) {
      final sConf = config[s];
      if (sConf is Map) {
        if (sConf['enabled'] == true) {
          allowed.add(s);
        }
      } else if (s != 'night') {
        allowed.add(s);
      }
    }

    if (allowed.isEmpty) {
      allowed.addAll(dep == 'dasterkhwaan' ? ['lunch', 'dinner'] : ['morning', 'evening']);
    }

    // 2. Facility filter if specified
    if (facilityId != null && facilityId.isNotEmpty && branchId != null) {
      try {
        if (Hive.isBoxOpen('local_branches')) {
          final raw = Hive.box('local_branches').get('branch:${branchId.toLowerCase().trim()}');
          if (raw is Map) {
            final facCategories = ['dispensaries', 'dasterkhwaans', 'madrassas', 'schools'];
            for (final cat in facCategories) {
              if (raw[cat] is List) {
                for (final f in raw[cat]) {
                  if (f is Map && (f['id'] == facilityId || f['name'] == facilityId)) {
                    if (f['sessions'] is List) {
                      final fSessions = (f['sessions'] as List).map((e) => e.toString().toLowerCase().trim()).toSet();
                      allowed.removeWhere((s) => !fSessions.contains(s));
                    }
                  }
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    // 3. User permission filter if specified
    if (userData != null) {
      final userSessions = getUserAllowedSessions(userData);
      if (!userSessions.contains('all') && userSessions.isNotEmpty) {
        allowed.removeWhere((s) => !userSessions.contains(s));
      }
    }

    return allowed.isNotEmpty ? allowed : ['morning', 'evening'];
  }

  /// Checks whether a specific session is allowed for this branch and context.
  static bool isSessionAllowed(String session, String? branchId, {String? department, String? facilityId, Map<String, dynamic>? userData}) {
    final s = session.toLowerCase().trim();
    if (s == 'all' || s == 'auto') return true;
    return getAllowedSessions(branchId, department: department, facilityId: facilityId, userData: userData).contains(s);
  }

  /// Helper to convert "HH:mm" to minutes from midnight
  static int _timeStrToMinutes(String? timeStr, int fallbackMinutes) {
    if (timeStr == null || timeStr.isEmpty) return fallbackMinutes;
    final parts = timeStr.trim().split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return h * 60 + m;
    }
    return fallbackMinutes;
  }

  /// Evaluates whether the given time falls within the open-close operational window of any enabled session.
  static bool isWithinOperationalHours(String? branchId, {String? department, String? facilityId, DateTime? time}) {
    final dt = time ?? getAuthoritativeTime();
    final currentMinutes = dt.hour * 60 + dt.minute;
    final config = getSessionConfig(branchId, department: department, facilityId: facilityId);
    final allowed = getAllowedSessions(branchId, department: department, facilityId: facilityId);

    for (final s in allowed) {
      final sConf = config[s] is Map ? config[s] as Map : null;
      if (sConf == null) continue;

      int openMin = _timeStrToMinutes(sConf['openTime']?.toString(), s == 'morning' ? 480 : (s == 'evening' || s == 'lunch' ? 720 : 1080));
      int closeMin = _timeStrToMinutes(sConf['closeTime']?.toString(), s == 'morning' ? 840 : (s == 'evening' || s == 'dinner' ? 1320 : 240));

      if (openMin < closeMin) {
        if (currentMinutes >= openMin && currentMinutes <= closeMin) return true;
      } else {
        // Crosses midnight (e.g. 22:00 to 04:00)
        if (currentMinutes >= openMin || currentMinutes <= closeMin) return true;
      }
    }
    return false;
  }

  /// Canonical single source of truth resolver for Shift and DateKey, factoring in branch-specific session windows.
  static ({String session, String dateKey}) resolveShiftAndDateKey([DateTime? time, String? branchId, String? department, String? facilityId]) {
    final dt = (time != null ? time.toLocal() : getAuthoritativeTime());
    final formatter = DateFormat('ddMMyy');
    final currentMinutes = dt.hour * 60 + dt.minute;

    final allowed = getAllowedSessions(branchId, department: department, facilityId: facilityId);
    final config = getSessionConfig(branchId, department: department, facilityId: facilityId);

    // If only 1 session is enabled, resolve directly to it
    if (allowed.length == 1) {
      final s = allowed.first;
      if (s == 'night' && dt.hour < 6) {
        return (session: s, dateKey: formatter.format(dt.subtract(const Duration(days: 1))));
      }
      return (session: s, dateKey: formatter.format(dt));
    }

    // Check configured time windows for allowed sessions
    for (final s in allowed) {
      final sConf = config[s] is Map ? config[s] as Map : null;
      if (sConf == null) continue;

      int openMin = _timeStrToMinutes(sConf['openTime']?.toString(), s == 'morning' ? 480 : (s == 'evening' ? 960 : (s == 'lunch' ? 720 : 1080)));
      int closeMin = _timeStrToMinutes(sConf['closeTime']?.toString(), s == 'morning' ? 840 : (s == 'evening' ? 1320 : (s == 'lunch' ? 960 : 1320)));

      if (openMin < closeMin) {
        if (currentMinutes >= openMin && currentMinutes < closeMin) {
          return (session: s, dateKey: formatter.format(dt));
        }
      } else {
        // Crosses midnight
        if (currentMinutes >= openMin || currentMinutes < closeMin) {
          if (dt.hour < 6) {
            return (session: s, dateKey: formatter.format(dt.subtract(const Duration(days: 1))));
          }
          return (session: s, dateKey: formatter.format(dt));
        }
      }
    }

    // Fallback if between windows:
    final hour = dt.hour;
    if (allowed.contains('morning') && (hour >= 6 && hour < 14 || !allowed.contains('evening'))) {
      return (session: 'morning', dateKey: formatter.format(dt));
    } else if (allowed.contains('lunch') && hour >= 11 && hour < 16) {
      return (session: 'lunch', dateKey: formatter.format(dt));
    } else if (allowed.contains('dinner') && hour >= 16 && hour < 23) {
      return (session: 'dinner', dateKey: formatter.format(dt));
    } else if (allowed.contains('evening') && (hour >= 14 && hour < 22 || !allowed.contains('night'))) {
      return (session: 'evening', dateKey: formatter.format(dt));
    } else if (allowed.contains('night')) {
      if (hour < 6) {
        return (session: 'night', dateKey: formatter.format(dt.subtract(const Duration(days: 1))));
      } else {
        return (session: 'night', dateKey: formatter.format(dt));
      }
    }

    final fallback = allowed.isNotEmpty ? allowed.first : 'morning';
    return (session: fallback, dateKey: formatter.format(dt));
  }

  /// Returns 'morning', 'evening', or 'night' for a given DateTime and branch.
  static String getCurrentSession([DateTime? time, String? branchId]) {
    return resolveShiftAndDateKey(time, branchId).session;
  }

  /// Returns the Firestore `serials` date document ID.
  /// For multi-camp branches like Karachi:
  /// - Saddar: '${dateKey}_saddar'
  /// - Haji Camp: '${dateKey}_haji'
  /// For single-camp branches: '${dateKey}'
  static String getCampDateDocId({
    required String branchId,
    required String dateKey,
    String? campId,
    String? dispensaryTag,
    String? serial,
  }) {
    final b = branchId.toLowerCase().trim();
    if (!hasCampsForBranch(b)) return dateKey;

    final ser = (serial ?? '').toUpperCase();
    final tag = (dispensaryTag ?? '').toUpperCase();
    final c = (campId ?? '').toLowerCase();

    if (ser.contains('-HAJI-') || ser.contains('-HC-') || tag == 'HAJI' || tag == 'HC' || c.contains('haji')) {
      return '${dateKey}_haji';
    }
    return '${dateKey}_saddar';
  }

  /// Returns all active Firestore date document IDs for a given dateKey.
  /// For multi-camp branches: ['${dateKey}_saddar', '${dateKey}_haji', dateKey] (includes legacy dateKey).
  /// For single-camp branches: [dateKey].
  static List<String> getAllCampDateDocIds({
    required String branchId,
    required String dateKey,
    String? selectedCamp,
  }) {
    final b = branchId.toLowerCase().trim();
    if (!hasCampsForBranch(b)) return [dateKey];

    final sel = (selectedCamp ?? '').toLowerCase().trim();
    if (sel == 'saddar' || sel == 'kapayya' || sel == 'kap') {
      return ['${dateKey}_saddar', dateKey];
    } else if (sel == 'haji_camp' || sel == 'haji' || sel == 'hc') {
      return ['${dateKey}_haji', dateKey];
    }
    return ['${dateKey}_saddar', '${dateKey}_haji', dateKey];
  }

  /// Returns the Firestore collection name for inventory.
  /// For multi-camp branches like Karachi:
  /// - Saddar: 'inventory_saddar'
  /// - Haji Camp: 'inventory_haji'
  /// For single-camp branches: 'inventory'
  static String getCampInventoryPath({
    required String branchId,
    String? campId,
    String? dispensaryTag,
    String? serial,
  }) {
    final b = branchId.toLowerCase().trim();
    if (!hasCampsForBranch(b)) return 'inventory';

    final ser = (serial ?? '').toUpperCase();
    final tag = (dispensaryTag ?? '').toUpperCase();
    final c = (campId ?? '').toLowerCase();

    if (ser.contains('-HAJI-') || ser.contains('-HC-') || tag == 'HAJI' || tag == 'HC' || c.contains('haji')) {
      return 'inventory_haji';
    }
    return 'inventory_saddar';
  }

  /// Returns all active Firestore inventory collection names for a given branch.
  static List<String> getAllCampInventoryPaths({
    required String branchId,
    String? selectedCamp,
  }) {
    final b = branchId.toLowerCase().trim();
    if (!hasCampsForBranch(b)) return ['inventory'];

    final sel = (selectedCamp ?? '').toLowerCase().trim();
    if (sel == 'saddar' || sel == 'kapayya' || sel == 'kap') {
      return ['inventory_saddar', 'inventory'];
    } else if (sel == 'haji_camp' || sel == 'haji' || sel == 'hc') {
      return ['inventory_haji', 'inventory'];
    }
    return ['inventory_saddar', 'inventory_haji', 'inventory'];
  }

  /// Validates keyword tag uniqueness when creating/editing a dispensary.
  static bool validateDispensaryTagUniqueness(
    List<Map<String, dynamic>> existingDispensaries,
    String tag, {
    String? excludeId,
  }) {
    final normNew = tag.trim().toUpperCase();
    if (normNew.isEmpty) return false;
    for (final d in existingDispensaries) {
      final id = d['id']?.toString();
      if (excludeId != null && id == excludeId) continue;
      final existingTag = (d['dispensaryTag'] ?? getDispensaryKeyword(id)).toString().toUpperCase();
      if (existingTag == normNew) return false; // Collision!
    }
    return true;
  }

  /// Returns the currently active selected camp ID for this session from Hive.
  /// Falls back to assigned camp from user profile if active_camp_id is not set.
  /// Returns null for branches that do NOT operate multi-camp facilities.
  static String? getActiveCamp([String? branchId]) {
    try {
      final effBranch = branchId ?? (() {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map) {
            final b = (uData['branchId'] ?? uData['branch'] ?? uData['selectedBranchId'])?.toString();
            if (b != null && b.isNotEmpty) return b;
          }
          final cb = box.get('current_branch_id')?.toString();
          if (cb != null && cb.isNotEmpty) return cb;
        }
        return null;
      })();

      if (effBranch != null && !hasCampsForBranch(effBranch)) {
        return null;
      }

      final bound = getBoundDispensaryId();
      if (bound != null && bound.isNotEmpty) {
        return bound; // Priority 1: Fixed hardware desk binding
      }

      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final uData = box.get('user_data') ?? box.get('currentUser');
        List<String> userAssigned = [];
        if (uData is Map) {
          userAssigned = getAssignedCamps(Map<String, dynamic>.from(uData));
        }
        if (userAssigned.isEmpty) {
          userAssigned = getAssignedCampsFromHive();
        }

        final manualVal = box.get(_activeCampKey)?.toString().trim().toLowerCase();
        if (manualVal != null && manualVal.isNotEmpty && manualVal != 'all') {
          // Enforce that cached active_camp_id MUST be assigned to current user
          if (userAssigned.isEmpty || userAssigned.contains(manualVal)) {
            return manualVal;
          }
        }

        if (uData is Map) {
          final userMap = Map<String, dynamic>.from(uData);
          final matching = getMatchingScheduledCamps(userMap);
          if (matching.length == 1) {
            return matching.first;
          }

          if (userAssigned.isNotEmpty) {
            return userAssigned.first;
          }
        }
      }

      final assigned = getAssignedCampsFromHive();
      if (assigned.isNotEmpty) {
        return assigned.first;
      }
    } catch (e) {
      debugPrint('[CampSessionService] Error getting active camp: $e');
    }
    return null;
  }

  /// Safely extracts the 6-digit dateKey from any serial format
  /// (e.g. KHI-HAJI-050926-Z001, HAJI-050926-Z001, X-050926-HAJI-Z001, 050926-Z001).
  static String getDateKeyFromSerial(String serial) {
    final s = serial.trim();
    if (s.isEmpty) return '';
    final parts = s.split('-');
    if (parts.isEmpty) return '';

    // Search for the 6-digit date part (ddMMyy)
    final dateReg = RegExp(r'^\d{6}$');
    for (final part in parts) {
      if (dateReg.hasMatch(part)) {
        return part;
      }
    }

    if (parts[0].toUpperCase() == 'X' && parts.length > 1) {
      return parts[1];
    }
    return parts[0];
  }

  /// Returns a clean short keyword tag for token serial prefixes (e.g. 'SKT', 'LHR', 'RWP', 'GRT', 'JLJ', 'SADD', 'HAJI', 'KAP')
  static String getDispensaryKeyword(String? id, {String? branchId}) {
    final effectiveCamp = (id != null && id.trim().isNotEmpty && id.trim().toLowerCase() != 'all')
        ? id.trim().toLowerCase()
        : getActiveCamp();

    // 1. Camp level checks first (e.g. for Karachi multi-camp)
    if (effectiveCamp != null && effectiveCamp.isNotEmpty) {
      if (effectiveCamp.contains('saddar') || effectiveCamp.contains('sadd') || effectiveCamp.contains('kapayya') || effectiveCamp.contains('kap')) return 'SADD';
      if (effectiveCamp.contains('haji')) return 'HAJI';
    }

    // 2. Branch level tags for single-facility branches or general branch tokens
    final b = (branchId ?? effectiveCamp ?? '').trim().toLowerCase();
    if (b.contains('sialkot') || b == 'skt') return 'SKT';
    if (b.contains('lahore') || b == 'lhr') return 'LHR';
    if (b.contains('rawalpindi') || b.contains('pindi') || b == 'rwp' || b == 'pnd') return 'RWP';
    if (b.contains('gujrat') || b == 'grt' || b == 'gjt') return 'GRT';
    if (b.contains('jalalpur') || b.contains('jattan') || b == 'jlj' || b == 'jpj') return 'JLJ';
    if (b.contains('karianwala') || b == 'kap') return 'KAP';
    if (b.contains('karachi')) return 'SADD';

    if (effectiveCamp != null && effectiveCamp.isNotEmpty) {
      final parts = effectiveCamp.split(RegExp(r'[^a-z0-9]')).where((p) => p.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        if (parts.length == 1) {
          final s = parts.first.toUpperCase();
          return s.length > 4 ? s.substring(0, 4) : s;
        }
        return parts.map((p) => p[0].toUpperCase()).join();
      }
    }

    return 'DISP';
  }

  /// Unified camp matching for filtering tokens, queues, and summaries across the entire app
  static bool matchesCamp({
    required String selectedCamp,
    String? dispensaryId,
    String? campId,
    String? dispensaryTag,
    String? serial,
  }) {
    final sel = selectedCamp.trim().toLowerCase();
    if (sel == 'all' || sel.isEmpty) return true;

    final isSaddar = sel.contains('saddar') || sel.contains('sadd') || sel.contains('kap');
    final isHaji = sel.contains('haji');

    final dId = (dispensaryId ?? '').trim().toLowerCase();
    final cId = (campId ?? '').trim().toLowerCase();
    final tag = (dispensaryTag ?? '').trim().toUpperCase();
    final ser = (serial ?? '').trim().toUpperCase();

    // 1. Immutable Serial / Tag Check (Highest Priority — never overridden by host PC activeCamp)
    final isExplicitSaddar = ser.contains('-SADD-') || ser.contains('-KAP-') || ser.contains('-KAPAYYA-') || ser.contains('KAPAYYA') || ser.contains('SADDAR') || tag == 'SADD' || tag == 'KAP' || tag == 'SADDAR' || tag == 'KAPAYYA';
    final isExplicitHaji   = ser.contains('-HAJI-') || ser.contains('-HAJ-') || ser.contains('-HC-') || ser.contains('HAJI') || tag == 'HAJI' || tag == 'HC' || tag == 'HAJICAMP';

    if (isExplicitSaddar) {
      return isSaddar;
    }
    if (isExplicitHaji) {
      return isHaji;
    }

    // 2. Secondary fallback by dispensaryId / campId
    final isHajiToken = dId.contains('haji') || cId.contains('haji');
    final isSaddarToken = dId.contains('sadd') || dId.contains('kap') || cId.contains('sadd') || cId.contains('kap');
    final isSharedGeneralStock = (dId == 'all' || cId == 'all' || (dId.isEmpty && cId.isEmpty)) && ser.isEmpty;

    if (isSharedGeneralStock) return true;

    if (isSaddar) {
      if (isHajiToken) return false;
      return true; // Any token not explicitly tagged as Haji belongs to Saddar / General
    }

    if (isHaji) {
      if (isSaddarToken) return false;
      return isHajiToken || dId == 'all' || cId == 'all';
    }

    // Generic fallback for any other camp ID
    final normSel = sel.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normD = dId.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normC = cId.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normD.isNotEmpty && (normD == normSel || normD.contains(normSel) || normSel.contains(normD))) return true;
    if (normC.isNotEmpty && (normC == normSel || normC.contains(normSel) || normSel.contains(normC))) return true;

    // Serial prefix fallback
    final tagFromSel = getDispensaryKeyword(selectedCamp).toUpperCase();
    if (tagFromSel.isNotEmpty && ser.contains('-$tagFromSel-')) return true;

    return false;
  }

  /// List of all known camps in the system.
  static const List<Map<String, String>> allCampsList = [
    {'id': 'saddar', 'label': 'Saddar Dispensary'},
    {'id': 'haji_camp', 'label': 'Haji Camp Dispensary'},
  ];

  /// Returns available camp options for the current user/context.
  /// Higher-level users (Admins, Global Admins, Supervisors, HQ Managers) get all active camps for the branch.
  static List<Map<String, String>> getAvailableCampOptions([Map<String, dynamic>? userData, String? branchId]) {
    final assigned = getAssignedCampsFromHive();

    // Resolve branch
    String? effBranch = branchId;
    if (effBranch == null || effBranch.isEmpty) {
      try {
        if (userData != null) {
          effBranch = (userData['branchId'] ?? userData['branch'] ?? userData['selectedBranchId'])?.toString();
        }
        if ((effBranch == null || effBranch.isEmpty) && Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final u = box.get('user_data') ?? box.get('currentUser');
          if (u is Map) {
            effBranch = (u['branchId'] ?? u['branch'] ?? u['selectedBranchId'])?.toString();
          }
          if (effBranch == null || effBranch.isEmpty) {
            effBranch = box.get('current_branch_id')?.toString();
          }
        }
      } catch (_) {}
    }

    final branchCamps = (effBranch != null && effBranch.isNotEmpty)
        ? getCampsForBranch(effBranch, includeClosed: false)
        : <Map<String, dynamic>>[];

    List<Map<String, String>> campList = [];
    if (branchCamps.isNotEmpty) {
      campList = branchCamps.map((c) => {
        'id': (c['id'] ?? '').toString().trim().toLowerCase(),
        'label': (c['name'] ?? c['id'] ?? '').toString().trim(),
      }).toList();
    } else {
      campList = allCampsList;
    }

    bool isHigherLevel = false;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final uData = userData ?? box.get('user_data') ?? box.get('currentUser');
        if (uData is Map) {
          final role = (uData['role'] ?? uData['userRole'] ?? '').toString().toLowerCase();
          if (role.contains('admin') || role.contains('supervisor') || role.contains('manager') || role.contains('chairman') || role.contains('ceo')) {
            isHigherLevel = true;
          }
        }
      }
    } catch (_) {}

    if (isHigherLevel || assigned.length > 1 || assigned.isEmpty) {
      return campList;
    }

    final filtered = campList.where((c) => assigned.contains(c['id'])).toList();
    return filtered.isNotEmpty ? filtered : campList;
  }

  /// Returns whether the user has only 1 camp and 1 session (or is single-context),
  /// so they should NEVER be prompted with confirmation dialogs or camp selectors.
  static bool isSingleContextUser({String? branchId}) {
    final effBranch = branchId ?? (() {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map) {
            final b = (uData['branchId'] ?? uData['branch'] ?? uData['selectedBranchId'])?.toString();
            if (b != null && b.isNotEmpty) return b;
          }
          final cb = box.get('current_branch_id')?.toString();
          if (cb != null && cb.isNotEmpty) return cb;
        }
      } catch (_) {}
      return null;
    })();

    if (effBranch != null && !hasCampsForBranch(effBranch)) {
      return true; // Non-multi-camp branch
    }

    if (getBoundDispensaryId() != null) {
      return true; // Fixed hardware desk binding
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final uData = box.get('user_data') ?? box.get('currentUser');
        if (uData is Map) {
          final userMap = Map<String, dynamic>.from(uData);
          final assignedCamps = getAssignedCamps(userMap);
          final allowedSessions = getUserAllowedSessions(userMap);

          // If user only has 1 assigned camp
          if (assignedCamps.length == 1) {
            return true;
          }

          // If user has <= 1 assigned camp and <= 1 session
          if (assignedCamps.length <= 1 && allowedSessions.length <= 1) {
            return true;
          }

          // If user's matching scheduled camps is 1 and allowed sessions <= 1
          final matching = getMatchingScheduledCamps(userMap);
          if (matching.length == 1 && allowedSessions.length <= 1) {
            return true;
          }
        }
      }
    } catch (_) {}

    final assigned = getAssignedCampsFromHive();
    if (assigned.length <= 1) {
      return true;
    }

    return false;
  }

  static final ValueNotifier<String?> activeCampNotifier = ValueNotifier<String?>(null);

  /// Store the active camp ID into Hive app_settings for this session.
  static Future<void> setActiveCamp(String campId) async {
    try {
      final norm = campId.trim().toLowerCase();
      final box = Hive.isBoxOpen('app_settings')
          ? Hive.box('app_settings')
          : await Hive.openBox('app_settings');
      await box.put(_activeCampKey, norm);
      activeCampNotifier.value = norm;
    } catch (e) {
      debugPrint('[CampSessionService] Error setting active camp: $e');
    }
  }

  /// Clear active camp ID on logout or switch.
  static Future<void> clearActiveCamp() async {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').delete(_activeCampKey);
      }
      activeCampNotifier.value = null;
    } catch (e) {
      debugPrint('[CampSessionService] Error clearing active camp: $e');
    }
  }

  /// Extract all assigned dispensary IDs for a given user data map.
  static List<String> getAssignedCamps(Map<String, dynamic> userData) {
    final List<String> result = [];

    // Check dispensaryIds list first
    if (userData['dispensaryIds'] is List) {
      final rawList = userData['dispensaryIds'] as List;
      for (final item in rawList) {
        final str = item.toString().trim().toLowerCase();
        if (str.isNotEmpty && str != 'all' && !result.contains(str)) {
          result.add(str);
        }
      }
    }

    // Fallback to legacy single dispensaryId
    if (result.isEmpty && userData['dispensaryId'] != null) {
      final str = userData['dispensaryId'].toString().trim().toLowerCase();
      if (str.isNotEmpty && str != 'all') {
        result.add(str);
      }
    }

    // Fallback to campSchedule if dispensaryIds/dispensaryId are empty
    if (result.isEmpty && userData['campSchedule'] is List) {
      final list = userData['campSchedule'] as List;
      for (final item in list) {
        if (item is Map && item['campId'] != null) {
          final str = item['campId'].toString().trim().toLowerCase();
          if (str.isNotEmpty && str != 'all' && !result.contains(str)) {
            result.add(str);
          }
        }
      }
    }

    // Fallback to alternate key names
    if (result.isEmpty) {
      for (final key in ['dispensary', 'camp', 'camps', 'facility', 'facilityId', 'branchCamp']) {
        final val = userData[key];
        if (val is List) {
          for (final item in val) {
            final str = item.toString().trim().toLowerCase();
            if (str.isNotEmpty && str != 'all' && !result.contains(str)) {
              result.add(str);
            }
          }
        } else if (val != null) {
          final str = val.toString().trim().toLowerCase();
          if (str.isNotEmpty && str != 'all' && !result.contains(str)) {
            result.add(str);
          }
        }
      }
    }

    return result;
  }

  /// Retrieves assigned camps by searching all available Hive storage locations.
  static List<String> getAssignedCampsFromHive() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final uData = box.get('user_data') ?? box.get('currentUser') ?? box.get('active_user');
        if (uData is Map) {
          final assigned = getAssignedCamps(Map<String, dynamic>.from(uData));
          if (assigned.isNotEmpty) return assigned;
        }
      }
    } catch (e) {
      debugPrint('[CampSessionService] app_settings read error: $e');
    }

    try {
      if (Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        for (final key in box.keys) {
          try {
            final val = box.get(key);
            if (val is Map) {
              final assigned = getAssignedCamps(Map<String, dynamic>.from(val));
              if (assigned.isNotEmpty) return assigned;
            }
          } catch (_) {
            // Ignore un-adapted Hive objects
          }
        }
      }
    } catch (e) {
      debugPrint('[CampSessionService] local_users read error: $e');
    }

    return [];
  }

  /// Extracts allowed sessions for a user (defaults to ['all'] for admins/supervisors/unrestricted).
  static List<String> getUserAllowedSessions(Map<String, dynamic> userData) {
    final List<String> sessions = [];

    // Check explicit allowedSessions list
    if (userData['allowedSessions'] is List) {
      for (final item in userData['allowedSessions'] as List) {
        final str = item.toString().trim().toLowerCase();
        if (str.isNotEmpty && !sessions.contains(str)) {
          sessions.add(str);
        }
      }
    }

    // Infer from campSchedule if allowedSessions is not explicitly set
    if (sessions.isEmpty && userData['campSchedule'] is List) {
      for (final item in userData['campSchedule'] as List) {
        if (item is Map && item['session'] != null) {
          final s = item['session'].toString().trim().toLowerCase();
          if (s.isNotEmpty && !sessions.contains(s)) {
            sessions.add(s);
          }
        }
      }
    }

    // Role-based un-restriction
    final role = (userData['role'] ?? userData['userRole'] ?? '').toString().toLowerCase();
    if (sessions.isEmpty || sessions.contains('all') ||
        role.contains('admin') || role.contains('supervisor') || role.contains('manager') || role.contains('chairman')) {
      return ['all'];
    }

    return sessions;
  }

  /// Get all camps scheduled for the active session (morning, evening, night).
  static List<String> getMatchingScheduledCamps(Map<String, dynamic> userData) {
    final List<String> matching = [];
    try {
      final scheduleRaw = userData['campSchedule'];
      if (scheduleRaw is! List || scheduleRaw.isEmpty) return matching;

      final currentShift = getCurrentSession();

      for (final entry in scheduleRaw) {
        if (entry is! Map) continue;
        final campId = entry['campId']?.toString().trim().toLowerCase();
        if (campId == null || campId.isEmpty) continue;

        final session = entry['session']?.toString().trim().toLowerCase();
        
        // Priority 1: Direct Session Matching (morning / evening / night / all)
        if (session != null && session.isNotEmpty) {
          if ((session == 'all' || session == currentShift) && !matching.contains(campId)) {
            matching.add(campId);
            continue;
          }
        }

        // Priority 2: Legacy fallback to start/end clock times if session not tagged
        final startStr = entry['startTime']?.toString().trim();
        final endStr   = entry['endTime']?.toString().trim();

        if (startStr != null && endStr != null) {
          final now = getAuthoritativeTime();
          final nowMinutes = now.hour * 60 + now.minute;
          final startMinutes = _parseMinutes(startStr);
          final endMinutes   = _parseMinutes(endStr);

          if (startMinutes != null && endMinutes != null) {
            bool matches = false;
            if (startMinutes <= endMinutes) {
              matches = nowMinutes >= startMinutes && nowMinutes < endMinutes;
            } else {
              matches = nowMinutes >= startMinutes || nowMinutes < endMinutes;
            }

            if (matches && !matching.contains(campId)) {
              matching.add(campId);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[CampSessionService] Error resolving schedule: $e');
    }
    return matching;
  }

  /// Resolves the active camp or determines if manual selection is required.
  static String? resolveActiveCamp(Map<String, dynamic> userData) {
    final matchingSchedules = getMatchingScheduledCamps(userData);

    if (matchingSchedules.length == 1) {
      return matchingSchedules.first;
    }

    final hiveActive = getActiveCamp();
    final assigned = getAssignedCamps(userData);

    if (matchingSchedules.length > 1) {
      if (hiveActive != null && matchingSchedules.contains(hiveActive)) {
        return hiveActive;
      }
      return matchingSchedules.first;
    }

    if (hiveActive != null && (assigned.isEmpty || assigned.contains(hiveActive))) {
      return hiveActive;
    }

    return assigned.isNotEmpty ? assigned.first : null;
  }

  static int? _parseMinutes(String timeStr) {
    try {
      final str = timeStr.trim().toUpperCase();
      final isPm = str.contains('PM');
      final isAm = str.contains('AM');

      final cleanStr = str.replaceAll(RegExp(r'[^\d:]'), '');
      final parts = cleanStr.split(':');
      if (parts.length >= 2) {
        int h = int.parse(parts[0]);
        int m = int.parse(parts[1]);

        if (isPm && h < 12) h += 12;
        if (isAm && h == 12) h = 0;

        return h * 60 + m;
      }
    } catch (_) {}
    return null;
  }
}

/// Data class representing detected drift between the local computer clock and server time.
class ClockSkewInfo {
  final DateTime localTime;
  final DateTime authoritativeTime;
  final int offsetMinutes;
  final String localSession;
  final String authoritativeSession;
  final bool hasShiftMismatch;

  const ClockSkewInfo({
    required this.localTime,
    required this.authoritativeTime,
    required this.offsetMinutes,
    required this.localSession,
    required this.authoritativeSession,
    required this.hasShiftMismatch,
  });

  bool get isSignificantDrift => offsetMinutes.abs() >= 5 || hasShiftMismatch;

  String get formattedOffset {
    final absMin = offsetMinutes.abs();
    final h = absMin ~/ 60;
    final m = absMin % 60;
    final timeStr = h > 0 ? '$h hrs $m mins' : '$m mins';
    return offsetMinutes > 0 ? '$timeStr behind' : '$timeStr ahead';
  }
}