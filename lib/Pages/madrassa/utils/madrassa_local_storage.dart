import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../../services/cloud/cloud_db.dart';
import '../../../services/image_upload_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import '../../../services/zkteco_network_service.dart';
import '../../../services/network_health_service.dart';
import '../../school/utils/school_local_storage.dart';
import '../models/madrassa_config.dart';
import '../madrassa_strings.dart';


class MadrassaLocalStorage {
  static const String studentsBox = LocalStorageService.madrassaStudentsBox;
  static const String logsBox     = LocalStorageService.madrassaLogsBox;
  static const String holidaysBox = LocalStorageService.madrassaHolidaysBox;
  static const String feesBox     = LocalStorageService.madrassaFeesBox;

  static Future<void> ensureBoxesOpen() async {
    await Future.wait([
      LocalStorageService.ensureBoxOpen(studentsBox),
      LocalStorageService.ensureBoxOpen(logsBox),
      LocalStorageService.ensureBoxOpen(holidaysBox),
      LocalStorageService.ensureBoxOpen(feesBox),
      LocalStorageService.ensureBoxOpen(LocalStorageService.usersBox),
      LocalStorageService.ensureBoxOpen('app_settings'),
    ]);
    unawaited(healPoisonedMadrassaSyncQueue());
  }

  static Box _getStudentsBox() => Hive.box(studentsBox);
  static Box _getLogsBox()     => Hive.box(logsBox);
  static Box _getHolidaysBox() => Hive.box(holidaysBox);
  static Box _getFeesBox()     => Hive.box(feesBox);

  static const DeepCollectionEquality _deepEq = DeepCollectionEquality();

  // ── Sanitization helpers for Hive ───────────────────────────────────────────

  static Map<String, dynamic> _sanitize(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) => out[k] = _val(v));
    return out;
  }

  static dynamic _val(dynamic v) {
    if (v == null)       return null;
    if (v is String)     return v;
    if (v is int)        return v;
    if (v is double)     return v;
    if (v is bool)       return v;
    if (v is DateTime)   return v.toIso8601String();
    if (v is Timestamp)  return v.toDate().toIso8601String();
    if (v is Map)        return _sanitize(Map<String, dynamic>.from(v));
    if (v is List)       return v.map(_val).toList();
    return null;
  }

  // ── Branch Normalization Helper ───────────────────────────────────────────
  // Folds branch aliases the same way LocalStorageService.sanitizeBranchId does. Madrassa used
  // to fold only Karachi, so a Gujrat teacher whose branch is stored as 'grt' saved students to
  // branches/grt while daily logs (sanitizeBranchId) and the LAN server went to branches/gujrat:
  // HQ and the other PCs saw the logs but never the students.
  static String normalizeBranch(String branchId) {
    final clean = branchId.toLowerCase().trim();
    if (clean.isEmpty ||
        clean == 'unknown' ||
        clean == 'all' ||
        clean == 'global' ||
        clean == 'main' ||
        clean == 'hq' ||
        clean == 'headquarters' ||
        clean == 'central' ||
        clean == 'headoffice' ||
        clean == 'head_office' ||
        clean.contains('head office')) {
      return 'all';
    }
    if (clean.contains('karachi') || clean.contains('saddar') || clean.contains('haji') || clean.contains('kapaya') || clean == 'khi') {
      return 'karachi';
    }
    if (clean.contains('gujrat') || clean == 'grt' || clean == 'gjt') return 'gujrat';
    if (clean.contains('sialkot') || clean == 'skt') return 'sialkot';
    if (clean.contains('rawalpindi') || clean.contains('pindi') || clean == 'rwp') return 'rawalpindi';
    if (clean.contains('jalalpur') || clean == 'jlj') return 'jalalpurjattan';
    return clean;
  }

  // Each image field and the other names the screens read it under (enrollment_dialog stores
  // every image two or three times).
  static const Map<String, List<String>> _mediaAliases = {
    'photoUrl': ['photoBase64', 'studentPhotoBase64'],
    'bFormUrl': ['bFormBase64', 'bformUrl', 'bformBase64'],
    'guardianCnicUrl': ['guardianCnicBase64', 'fatherCnicUrl', 'fatherCnicBase64'],
    'hifzCertificateUrl': ['hifzCertificateBase64'],
  };

  /// The cloud copy of a student keeps each image once and ensures it is properly compressed.
  /// With a photo stored three times and three documents twice each, a student could exceed
  /// Firestore's 1 MiB document limit; the upload then failed on every retry until it was dead-lettered.
  /// [compactMediaForCloud] keeps only primary fields, compresses large image payloads to optimal dimensions,
  /// and guarantees the document payload stays comfortably below Firestore's 1 MiB limit.
  static Map<String, dynamic> compactMediaForCloud(Map<String, dynamic> data) {
    final out = Map<String, dynamic>.from(data);
    _mediaAliases.forEach((primary, aliases) {
      var value = out[primary];
      if (value is! String || value.isEmpty) {
        for (final a in aliases) {
          final v = out[a];
          if (v is String && v.isNotEmpty) {
            out[primary] = v;
            value = v;
            break;
          }
        }
      }
      // Keep only the primary field; strictly remove all aliases to save Firestore bandwidth & 1MB limit
      for (final a in aliases) {
        out.remove(a);
      }
    });

    // 1. Primary document fields compression (retina avatar 350x350, documents 550x550)
    for (final primary in _mediaAliases.keys) {
      final val = out[primary];
      if (val is String && val.length > 25000 && ImageUploadService.isValidMediaString(val)) {
        try {
          final bytes = ImageUploadService.decodeBase64ToBytes(val);
          if (bytes != null && bytes.isNotEmpty) {
            final isAvatar = primary == 'photoUrl';
            final recompressed = ImageUploadService.processBytesToBase64(
              bytes,
              maxWidth: isAvatar ? 350 : 550,
              maxHeight: isAvatar ? 350 : 550,
              quality: isAvatar ? 55 : 45,
            );
            if (recompressed != null && recompressed.isNotEmpty && recompressed.length < val.length) {
              out[primary] = recompressed;
            }
          }
        } catch (_) {}
      }
    }

    // 2. Strict total document size verification for Firestore's 1 MiB (1,048,576 byte) limit
    try {
      final jsonStr = jsonEncode(out);
      if (jsonStr.length > 450000) {
        // Aggressive emergency downscale pass if total document payload still exceeds 450 KB
        for (final primary in _mediaAliases.keys) {
          final val = out[primary];
          if (val is String && val.length > 20000 && ImageUploadService.isValidMediaString(val)) {
            final bytes = ImageUploadService.decodeBase64ToBytes(val);
            if (bytes != null && bytes.isNotEmpty) {
              final isAvatar = primary == 'photoUrl';
              final emergencyRecompressed = ImageUploadService.processBytesToBase64(
                bytes,
                maxWidth: isAvatar ? 250 : 400,
                maxHeight: isAvatar ? 250 : 400,
                quality: isAvatar ? 45 : 35,
              );
              if (emergencyRecompressed != null && emergencyRecompressed.isNotEmpty && emergencyRecompressed.length < val.length) {
                out[primary] = emergencyRecompressed;
              }
            }
          }
        }
      }
    } catch (_) {}

    return out;
  }

  /// Fills the alias image fields from the primary one (see [compactMediaForCloud]). The
  /// primary always wins, so an older alias left in the cloud doc can't show a stale photo.
  static Map<String, dynamic> expandMediaFromCloud(Map<String, dynamic> data) {
    final out = Map<String, dynamic>.from(data);
    _mediaAliases.forEach((primary, aliases) {
      final value = out[primary];
      if (value is String && value.isNotEmpty) {
        for (final a in aliases) {
          out[a] = value;
        }
      }
    });
    return out;
  }

  /// Older Firestore branch ids that may still hold a branch's madrassa data (written before
  /// [normalizeBranch] folded them). Read from, never written to.
  static List<String> legacyBranchIds(String branchId) {
    switch (normalizeBranch(branchId)) {
      case 'gujrat':
        return const ['grt', 'gjt'];
      case 'sialkot':
        return const ['skt'];
      case 'rawalpindi':
        return const ['rwp'];
      case 'jalalpurjattan':
        return const ['jalalpur_jattan', 'jlj'];
      default:
        return const [];
    }
  }

  // ── Cache keys ─────────────────────────────────────────────────────────────

  static String _studentKey(String branchId, String studentId) {
    final cleanId = studentId.contains('__std__') ? studentId.split('__std__').last : studentId;
    return '${normalizeBranch(branchId)}__std__$cleanId';
  }

  static String _logKey(String branchId, String dateKey) =>
      '${normalizeBranch(branchId)}__log__$dateKey';

  static String _holidayKey(String branchId, String dateKey) =>
      '${normalizeBranch(branchId)}__hol__$dateKey';

  static String _feeKey(String branchId, int year, int month, String studentId) =>
      '${normalizeBranch(branchId)}__fee__${year}_${month}__$studentId';

  static DateTime? _parseTimestamp(dynamic val) {
    if (val == null) return null;
    if (val is DateTime) return val;
    if (val is Timestamp) return val.toDate();
    if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
    if (val is String) return DateTime.tryParse(val);
    return null;
  }

  /// Conflict resolution helper:
  /// Protects local uncommitted/pending edits and newer local timestamps
  /// from being overwritten by stale cloud snapshots during refreshes or background downloads.
  static Map<String, dynamic> _resolveStudentConflict({
    required Map<dynamic, dynamic>? local,
    required Map<String, dynamic> remote,
  }) {
    if (local == null || local.isEmpty) {
      return Map<String, dynamic>.from(remote);
    }

    final localMap = Map<String, dynamic>.from(local);
    final isPending = localMap['syncStatus'] == 'pending' || localMap['pendingSync'] == true;

    final localTime = _parseTimestamp(localMap['lastUpdatedAt'] ?? localMap['updatedAt']);
    final remoteTime = _parseTimestamp(remote['lastUpdatedAt'] ?? remote['updatedAt']);

    if (isPending) {
      // Local changes are pending upload. Unless remote is strictly newer than the local edit,
      // preserve local uncommitted edits.
      if (remoteTime == null || localTime == null || !remoteTime.isAfter(localTime)) {
        return <String, dynamic>{
          ...remote,
          ...localMap,
          'syncStatus': 'pending',
        };
      }
      return <String, dynamic>{
        ...localMap,
        ...remote,
      };
    }

    // If local is not pending, compare timestamps
    if (localTime != null && remoteTime != null && localTime.isAfter(remoteTime)) {
      return <String, dynamic>{
        ...remote,
        ...localMap,
      };
    }

    return <String, dynamic>{
      ...localMap,
      ...remote,
    };
  }

  // ── Students Cache ─────────────────────────────────────────────────────────

  static Future<void> cacheStudent(String branchId, String studentId, Map<String, dynamic> data) async {
    final cleanId = studentId.contains('__std__') ? studentId.split('__std__').last.trim() : studentId.trim();
    final canonicalKey = _studentKey(branchId, cleanId);
    final box = await LocalStorageService.ensureBoxOpen(studentsBox);
    final rawExisting = box.get(canonicalKey);
    final merged = <String, dynamic>{
      if (rawExisting is Map) ...Map<String, dynamic>.from(rawExisting),
      ...data,
      'id': cleanId,
      'branchId': normalizeBranch(branchId),
    };
    await box.put(canonicalKey, _sanitize(merged));

    // Clean up any legacy or duplicate keys for the same student id. Scanning every key is
    // O(n), so only do it when the canonical record is new (updates cannot create duplicates).
    final duplicateKeys = (rawExisting is Map ? const [] : box.keys.toList()).where((k) {
      final str = k.toString();
      if (str == canonicalKey) return false;
      final kId = str.contains('__std__')
          ? str.split('__std__').last.trim()
          : (str.startsWith('madrassa_std_') ? str.replaceFirst('madrassa_std_', '').trim() : str.trim());
      return kId == cleanId;
    }).toList();

    for (final dupKey in duplicateKeys) {
      await box.delete(dupKey);
    }

    await box.flush();
  }


  /// Saves student locally in Hive immediately, writes to disk, routes over LAN WebSocket,
  /// enqueues for offline Firestore sync, and attempts background cloud write.
  static Future<String> saveStudentLocalAndSync({
    required String branchId,
    required String studentId,
    required Map<String, dynamic> data,
    bool isNew = false,
  }) async {
    final cleanInputId = studentId.contains('__std__') ? studentId.split('__std__').last.trim() : studentId.trim();
    final effectiveStudentId = cleanInputId.isNotEmpty 
        ? cleanInputId 
        : 'madrassa_std_${DateTime.now().millisecondsSinceEpoch}';

    var effectiveBranchId = normalizeBranch(branchId);
    if (effectiveBranchId == 'all' || effectiveBranchId == 'global' || effectiveBranchId.isEmpty) {
      final studentBranch = (data['branchId'] ?? data['branch'] ?? '').toString().toLowerCase().trim();
      if (studentBranch.isNotEmpty && studentBranch != 'all' && studentBranch != 'global') {
        effectiveBranchId = normalizeBranch(studentBranch);
      } else {
        final activeB = LocalStorageService.getActiveUserBranchId();
        effectiveBranchId = LocalStorageService.isValidBranchId(activeB) ? normalizeBranch(activeB) : 'gujrat';
      }
    }

    final compacted = compactMediaForCloud(data);
    final cleanData = Map<String, dynamic>.from(compacted);
    cleanData['id'] = effectiveStudentId;
    cleanData['branchId'] = effectiveBranchId;
    cleanData['lastUpdatedAt'] = DateTime.now().toIso8601String();
    cleanData['syncStatus'] = 'pending';

    // 1. Immediately cache in Hive and flush to disk
    await cacheStudent(effectiveBranchId, effectiveStudentId, cleanData);

    // 2. Assign PIN in ZKTeco Biometrics in background (non-blocking)
    final pin = cleanData['biometricPin']?.toString().trim();
    if (pin != null && pin.isNotEmpty) {
      unawaited(
        ZkTecoNetworkService.assignPinToEntity(
          entityId: effectiveStudentId,
          entityName: cleanData['name']?.toString() ?? '',
          entityType: 'madrassa_student',
          branchId: effectiveBranchId,
          customPin: pin,
        ).catchError((e) {
          debugPrint('[MadrassaLocalStorage] Background PIN assign error: $e');
          return '';
        }),
      );
    }

    // 3. Broadcast to LAN WebSocket (Server and peers)
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaStudent,
        data: {
          ...cleanData,
          'studentId': effectiveStudentId,
        },
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 4. Try immediate direct cloud upload if online (Android lifecycle protection: ensures data reaches Firestore
    // before the user minimizes or locks the app).
    bool cloudUploaded = false;
    try {
      final isOnline = NetworkHealthService().isStableOnline ||
          (!kIsWeb && (await Connectivity().checkConnectivity()).any((r) => r != ConnectivityResult.none));
      if (isOnline) {
        final docRef = CloudDb.instance
            .collection('branches')
            .doc(effectiveBranchId)
            .collection('madrassa_students')
            .doc(effectiveStudentId);
        final compacted = compactMediaForCloud(cleanData);
        final fsData = LocalStorageService.sanitizeForCloudUpload(compacted);
        await docRef.set(fsData, SetOptions(merge: true)).timeout(const Duration(seconds: 15));

        cloudUploaded = true;
        cleanData['syncStatus'] = 'synced';
        cleanData['lastSyncedAt'] = DateTime.now().toIso8601String();
        cleanData['synced'] = true;
        cleanData['pendingSync'] = false;
        await cacheStudent(effectiveBranchId, effectiveStudentId, cleanData);
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Direct cloud upload deferred to sync queue: $e');
    }

    if (!cloudUploaded) {
      // Enqueue into LocalStorageService.syncBox for durable background Firestore upload
      try {
        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_student',
          'branchId': effectiveBranchId,
          'studentId': effectiveStudentId,
          'entityId': effectiveStudentId,
          'data': cleanData,
          'localBox': LocalStorageService.madrassaStudentsBox,
          'localKey': _studentKey(effectiveBranchId, effectiveStudentId),
          'isNew': isNew,
        });

        unawaited(SyncService().triggerUpload(urgent: true));
      } catch (e) {
        debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
      }
    }

    return effectiveStudentId;
  }

  /// Offboards a student: updates Hive immediately, unenrolls biometric PIN,
  /// revokes linked app login access, broadcasts via LAN and enqueues to Firestore.
  static Future<void> deleteOrOffboardStudentLocalAndSync({
    required String branchId,
    required String studentId,
    required String status,
    String? reason,
    DateTime? effectiveDate,
  }) async {
    final effectiveBranchId = branchId.toLowerCase().trim();
    final student = getStudentCached(effectiveBranchId, studentId) ?? {};
    final now = DateTime.now();

    student['status'] = status;
    student['batch'] = status;
    student['offboardedAt'] = (effectiveDate ?? now).toIso8601String();
    student['lastUpdatedAt'] = now.toIso8601String();

    final auditList = List<Map<String, dynamic>>.from(
      (student['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );
    auditList.add({
      'status': status,
      'type': 'offboarding',
      'date': (effectiveDate ?? now).toIso8601String(),
      'reason': reason ?? 'Student offboarded ($status)',
    });
    student['auditLog'] = auditList;

    // 1. Immediately update Hive cache and flush
    await cacheStudent(effectiveBranchId, studentId, student);

    // 2. Unenroll biometric PIN from device (background)
    unawaited(
      ZkTecoNetworkService.deleteBiometricCredential(studentId, branchId: effectiveBranchId).catchError((e) {
        debugPrint('[MadrassaLocalStorage] Background deleteBiometricCredential error: $e');
      }),
    );

    // 3. Revoke App Access for student/guardian user account
    try {
      final guardianCnic = (student['guardianCnic'] ?? '').toString().trim();
      final studentCnic = (student['studentCnic'] ?? '').toString().trim();
      final phone = (student['contactPhone'] ?? student['phone'] ?? '').toString().trim();

      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final usersBox = Hive.box(LocalStorageService.usersBox);
        for (final k in usersBox.keys) {
          final u = usersBox.get(k);
          if (u is Map) {
            final uCnic = (u['cnic'] ?? '').toString().trim();
            final uPhone = (u['phone'] ?? '').toString().trim();
            final uStudentIds = List<String>.from(u['studentIds'] ?? []);
            // Only guardian/student accounts. A CNIC or phone match alone used to offboard staff
            // too (a teacher who is also a guardian, or a shared family phone): their account
            // went inactive in Hive and Firestore and they got "Access Revoked" at login.
            final uRole = (u['role'] ?? '').toString().toLowerCase();
            final isFamilyAccount =
                uRole.contains('guardian') || uRole.contains('parent') || uRole.contains('student');

            final matches = uStudentIds.contains(studentId) ||
                (isFamilyAccount &&
                    ((guardianCnic.isNotEmpty && uCnic == guardianCnic) ||
                        (studentCnic.isNotEmpty && uCnic == studentCnic) ||
                        (phone.isNotEmpty && uPhone == phone)));

            if (matches) {
              final updatedUser = Map<String, dynamic>.from(u);
              uStudentIds.remove(studentId);
              updatedUser['studentIds'] = uStudentIds;
              final deactivate = isFamilyAccount && uStudentIds.isEmpty;
              if (deactivate) {
                updatedUser['isActive'] = false;
                updatedUser['accountStatus'] = 'offboarded';
                updatedUser['isReadOnly'] = true;
                updatedUser['status'] = 'offboarded';
              }
              await usersBox.put(k, updatedUser);

              final uid = u['uid']?.toString() ?? k.toString();
              unawaited(
                FirebaseFirestore.instance.collection('users').doc(uid).set(
                  {
                    'studentIds': FieldValue.arrayRemove([studentId]),
                    if (deactivate) ...{
                      'isActive': false,
                      'accountStatus': 'offboarded',
                      'isReadOnly': true,
                      'status': 'offboarded',
                    }
                  },
                  SetOptions(merge: true),
                ).catchError((e) => debugPrint('[MadrassaLocalStorage] Revoke user cloud error: $e')),
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Revoke app access error: $e');
    }

    // 4. Broadcast to LAN WebSocket (Server and peers)
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.offboardMadrassaStudent,
        data: {
          'branchId': effectiveBranchId,
          'studentId': studentId,
          'status': status,
          'reason': reason,
          'effectiveDate': (effectiveDate ?? now).toIso8601String(),
        },
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 5. Always enqueue for Firestore sync and trigger upload
    try {
      await LocalStorageService.enqueueSync({
        'type': 'delete_madrassa_student',
        'branchId': effectiveBranchId,
        'studentId': studentId,
        'status': status,
        'reason': reason,
        'effectiveDate': (effectiveDate ?? now).toIso8601String(),
        'data': student,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  /// Permanently deletes a student from Hive cache, enqueues cloud deletion,
  /// deletes biometric PIN and broadcasts to LAN WebSocket.
  static Future<void> permanentlyDeleteStudent({
    required String branchId,
    required String studentId,
  }) async {
    final cleanId = studentId.contains('__std__') ? studentId.split('__std__').last.trim() : studentId.trim();
    if (cleanId.isEmpty) return;

    var effectiveBranchId = normalizeBranch(branchId);
    final box = await LocalStorageService.ensureBoxOpen(studentsBox);

    // If branch is generic ('all', 'global' or empty), find the real branch from the cached student record
    if (effectiveBranchId == 'all' || effectiveBranchId == 'global' || effectiveBranchId.isEmpty) {
      for (final k in box.keys) {
        final str = k.toString();
        final kId = str.contains('__std__')
            ? str.split('__std__').last.trim()
            : (str.startsWith('madrassa_std_') ? str.replaceFirst('madrassa_std_', '').trim() : str.trim());
        if (kId == cleanId) {
          final raw = box.get(k);
          if (raw is Map) {
            final b = (raw['branchId'] ?? raw['branch'] ?? '').toString().toLowerCase().trim();
            if (b.isNotEmpty && b != 'all' && b != 'global') {
              effectiveBranchId = normalizeBranch(b);
              break;
            }
          }
        }
      }
    }
    if (effectiveBranchId == 'all' || effectiveBranchId == 'global' || effectiveBranchId.isEmpty) {
      final activeB = LocalStorageService.getActiveUserBranchId();
      effectiveBranchId = LocalStorageService.isValidBranchId(activeB) ? normalizeBranch(activeB) : 'gujrat';
    }

    // 1. Delete ALL keys in studentsBox matching this cleanId (including duplicate/legacy keys across branches)
    final keysToDelete = box.keys.where((k) {
      final str = k.toString();
      final kId = str.contains('__std__')
          ? str.split('__std__').last.trim()
          : (str.startsWith('madrassa_std_') ? str.replaceFirst('madrassa_std_', '').trim() : str.trim());
      return kId == cleanId;
    }).toList();

    for (final k in keysToDelete) {
      await box.delete(k);
    }
    // Also explicitly delete canonical key if not present in keysToDelete
    await box.delete(_studentKey(effectiveBranchId, cleanId));
    await box.flush();

    // 2. Remove any pending upload/save actions from sync_queue and deadLetterQueue
    // so self-healing routines (repairMissingStudentsFromLocalData) or SyncService
    // do not restore or re-upload the deleted student!
    for (final boxName in [LocalStorageService.syncBox, LocalStorageService.deadLetterQueueBox]) {
      if (Hive.isBoxOpen(boxName)) {
        try {
          final sBox = Hive.box(boxName);
          final toRemove = <dynamic>[];
          for (final k in sBox.keys) {
            final entry = sBox.get(k);
            if (entry is Map) {
              final type = entry['type']?.toString();
              final sId = (entry['studentId'] ?? (entry['data'] is Map ? (entry['data']['id'] ?? entry['data']['studentId']) : null))?.toString();
              final entryCleanId = sId?.contains('__std__') == true ? sId!.split('__std__').last.trim() : sId?.trim();
              if (entryCleanId == cleanId || k.toString().contains(cleanId)) {
                if (type == 'save_madrassa_student' || type == 'save_madrassa_admission' || type == 'update_madrassa_student') {
                  toRemove.add(k);
                }
              }
            }
          }
          for (final k in toRemove) {
            await sBox.delete(k);
          }
        } catch (e) {
          debugPrint('[MadrassaLocalStorage] Error cleaning pending sync items for $cleanId: $e');
        }
      }
    }

    // 3. Direct Firestore delete if online
    try {
      if (NetworkHealthService().isStableOnline) {
        final branchesToDelete = <String>{effectiveBranchId};
        if (effectiveBranchId == 'all' || effectiveBranchId == 'global') {
          branchesToDelete.addAll(_getAllBranchIds().map(normalizeBranch));
        }
        for (final b in branchesToDelete) {
          if (b == 'all' || b == 'global') continue;
          unawaited(FirebaseFirestore.instance
              .collection('branches')
              .doc(b)
              .collection('madrassa_students')
              .doc(cleanId)
              .delete()
              .catchError((_) {}));
        }
      }
    } catch (_) {}

    // 4. Unenroll biometric PIN from device (background)
    unawaited(
      ZkTecoNetworkService.deleteBiometricCredential(cleanId, branchId: effectiveBranchId).catchError((e) {
        debugPrint('[MadrassaLocalStorage] Background deleteBiometricCredential error: $e');
      }),
    );

    // 5. Broadcast to LAN WebSocket
    try {
      final payload = RealtimeEvents.payload(
        type: 'delete_madrassa_student',
        data: {
          'branchId': effectiveBranchId,
          'studentId': cleanId,
        },
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 6. Enqueue sync for cloud deletion
    try {
      await LocalStorageService.enqueueSync({
        'type': 'permanent_delete_madrassa_student',
        'branchId': effectiveBranchId,
        'studentId': cleanId,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  /// Returns normalized, human-readable branches available for student enrollment or transfer
  static List<Map<String, String>> getAvailableBranchesForSelection() {
    final seen = <String>{};
    final result = <Map<String, String>>[];

    final localList = LocalStorageService.getLocalBranchesList();
    for (final b in localList) {
      final id = normalizeBranch(b['id']?.toString() ?? '');
      if (id.isEmpty || id == 'all' || id == 'global' || id == 'unknown') continue;
      if (seen.add(id)) {
        final name = (b['name'] ?? id).toString();
        result.add({'id': id, 'name': name.isEmpty ? id.toUpperCase() : name});
      }
    }

    final defaultBranches = [
      {'id': 'gujrat', 'name': 'Gujrat Branch (گجرات)'},
      {'id': 'karachi', 'name': 'Karachi Branch (کراچی)'},
      {'id': 'saddar', 'name': 'Karachi - Saddar'},
      {'id': 'haji', 'name': 'Karachi - Haji'},
      {'id': 'sialkot', 'name': 'Sialkot Branch'},
      {'id': 'jalalpur_jattan', 'name': 'Jalalpur Jattan Branch'},
    ];

    for (final b in defaultBranches) {
      final id = b['id']!;
      if (seen.add(id)) {
        result.add(b);
      }
    }

    return result;
  }

  /// Transfers a student from oldBranch to newBranch:
  /// - Updates student data to new branch and stores in Hive under newBranch__std__id
  /// - Immediately removes oldBranch__std__id and any other branch duplicates from Hive
  /// - Deletes cloud Firestore record from branches/oldBranch/madrassa_students/studentId
  /// - Enqueues offline deletion from oldBranch and upload to newBranch
  /// - Logs central audit action
  static Future<void> transferStudentBranch({
    required String oldBranch,
    required String newBranch,
    required String studentId,
    Map<String, dynamic>? studentData,
    String? editorUsername,
    String? editorRole,
  }) async {
    final normOld = normalizeBranch(oldBranch);
    final normNew = normalizeBranch(newBranch);
    final cleanId = studentId.contains('__std__') ? studentId.split('__std__').last.trim() : studentId.trim();
    if (cleanId.isEmpty || normOld == normNew) return;

    final box = await LocalStorageService.ensureBoxOpen(studentsBox);

    // 1. Fetch current data
    final existingData = studentData ??
        getStudentCached(normOld, cleanId) ??
        getStudentCached(normNew, cleanId) ??
        <String, dynamic>{};

    final updatedData = Map<String, dynamic>.from(existingData);
    updatedData['id'] = cleanId;
    updatedData['branchId'] = normNew;
    updatedData['lastUpdatedAt'] = DateTime.now().toIso8601String();
    updatedData['syncStatus'] = 'pending';

    // 2. Save under new branch in Hive and queue sync
    await saveStudentLocalAndSync(
      branchId: normNew,
      studentId: cleanId,
      data: updatedData,
      isNew: false,
    );

    // 3. Remove old branch key and all other duplicate branch keys from Hive
    final oldKey = _studentKey(normOld, cleanId);
    await box.delete(oldKey);

    final otherBranchKeys = box.keys.where((k) {
      final str = k.toString();
      final kId = str.contains('__std__') ? str.split('__std__').last.trim() : str.trim();
      return kId == cleanId && !str.startsWith('${normNew}__std__');
    }).toList();
    for (final k in otherBranchKeys) {
      await box.delete(k);
    }
    await box.flush();

    // 4. Remove from old branch collection in Firestore
    try {
      if (NetworkHealthService().isStableOnline) {
        unawaited(FirebaseFirestore.instance
            .collection('branches')
            .doc(normOld)
            .collection('madrassa_students')
            .doc(cleanId)
            .delete()
            .catchError((_) {}));
      }
    } catch (_) {}

    // Enqueue cloud deletion for old branch so sync service handles it if offline
    try {
      await LocalStorageService.enqueueSync({
        'type': 'permanent_delete_madrassa_student',
        'branchId': normOld,
        'studentId': cleanId,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error enqueuing old branch delete on transfer: $e');
    }

    // 5. Central audit log
    unawaited(MadrassaAuditService.logAction(
      branchId: normNew,
      editor: editorUsername ?? 'HQ Manager',
      role: editorRole ?? 'hqmanager',
      type: 'student_transfer',
      message: 'Transferred student ${updatedData['name'] ?? cleanId} (Roll: ${updatedData['rollNumber'] ?? '-'}) from branch ${normOld.toUpperCase()} to ${normNew.toUpperCase()}',
      studentId: cleanId,
      studentName: updatedData['name'] as String?,
    ));
  }


  static Map<String, dynamic>? getStudentCached(String branchId, String studentId) {
    if (!Hive.isBoxOpen(studentsBox)) return null;
    final cleanId = studentId.contains('__std__') ? studentId.split('__std__').last.trim() : studentId.trim();
    final key = _studentKey(branchId, cleanId);
    final box = _getStudentsBox();
    final raw = box.get(key);
    if (raw is Map) return Map<String, dynamic>.from(raw);

    // Fallback: search across all keys for this cleanId
    for (final k in box.keys) {
      final str = k.toString();
      final kId = str.contains('__std__')
          ? str.split('__std__').last.trim()
          : (str.startsWith('madrassa_std_') ? str.replaceFirst('madrassa_std_', '').trim() : str.trim());
      if (kId == cleanId) {
        final val = box.get(k);
        if (val is Map) return Map<String, dynamic>.from(val);
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> getAllStudentsCached(String branchId) {
    if (!Hive.isBoxOpen(studentsBox)) return const [];
    final rawBranch = branchId.toLowerCase().trim();
    final cleanBranch = normalizeBranch(rawBranch);
    final isGlobal = cleanBranch == 'all' || cleanBranch == 'global' || rawBranch.isEmpty || rawBranch == 'all' || rawBranch == 'main' || rawBranch == 'global';
    final prefix = '${cleanBranch}__std__';
    final box = _getStudentsBox();
    final list = box.keys
        .where((k) {
          final str = k.toString();
          if (isGlobal) return str.contains('__std__') || str.startsWith('madrassa_std_');
          if (str.startsWith(prefix)) return true;
          final kBranch = str.split('__std__').first;
          if (str.contains('__std__') && normalizeBranch(kBranch) == cleanBranch) return true;
          final isKarachiFam = (kBranch.contains('karachi') || kBranch.contains('saddar') || kBranch.contains('haji')) &&
              (cleanBranch.contains('karachi') || cleanBranch.contains('saddar') || cleanBranch.contains('haji'));
          return isKarachiFam;
        })
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().contains('__std__') ? k.toString().split('__std__').last : k.toString();
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .where((s) {
          final name = (s['name']?.toString() ?? '').trim();
          final isDeleted = s['isDeleted'] == true ||
              s['deleted'] == true ||
              s['status']?.toString().toLowerCase() == 'deleted';
          if (name.isEmpty || isDeleted) return false;

          // STRICT BRANCH ISOLATION: A student must ONLY belong to their enrolled branch
          if (!isGlobal) {
            final sBranch = (s['branchId'] ?? '').toString().toLowerCase().trim();
            if (sBranch.isNotEmpty && normalizeBranch(sBranch) != cleanBranch) {
              return false;
            }
          }

          return true;
        })
        .toList();

    // Deduplicate by student id, ensuring newer/pending records always take precedence
    final Map<String, Map<String, dynamic>> dedup = {};
    for (final s in list) {
      final id = s['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      if (!dedup.containsKey(id)) {
        dedup[id] = s;
      } else {
        final existing = dedup[id]!;
        dedup[id] = _resolveStudentConflict(
          local: existing,
          remote: s,
        );
      }
    }
    final dedupList = dedup.values.toList();

    dedupList.sort((a, b) {
      final rollA = int.tryParse(a['rollNumber']?.toString() ?? '');
      final rollB = int.tryParse(b['rollNumber']?.toString() ?? '');
      if (rollA != null && rollB != null) return rollA.compareTo(rollB);
      if (rollA != null) return -1;
      if (rollB != null) return 1;
      return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
    });

    return dedupList;
  }

  static int _studentRepairVersion = 0;
  static const int _targetStudentRepairVersion = 6;

  /// Self-healing routine: Recovers full student records from sync queue,
  /// resolves multiple-prefixed keys, cleans corrupt or guardian placeholder names,
  /// strictly removes cross-enrolled student duplicates across branches,
  /// and ensures all real students enrolled by teachers with their authentic
  /// Urdu/English names and biometric PINs are correctly preserved and synced.
  static Future<void> repairMissingStudentsFromLocalData({bool force = false}) async {
    if (_studentRepairVersion >= _targetStudentRepairVersion && !force) return;
    _studentRepairVersion = _targetStudentRepairVersion;
    try {
      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      bool changesMade = false;

      // 1. Clean up multi-prefixed, corrupt or cross-enrolled/misplaced keys
      final keysToClean = box.keys.where((k) {
        final str = k.toString();
        if (str == 'gujrat__std__gujrat' || str == 'karachi__std__gujrat') return true;
        if (str.contains('__std__') && (
          str.startsWith('gujrat__std__gujrat__std__') ||
          str.startsWith('karachi__std__gujrat__std__') ||
          str.startsWith('all__std__')
        )) {
          return true;
        }

        if (str.contains('__std__')) {
          final raw = box.get(k);
          if (raw is Map) {
            final keyBranch = str.split('__std__').first.toLowerCase().trim();
            final actualBranch = (raw['branchId'] ?? '').toString().toLowerCase().trim();
            final cleanId = str.split('__std__').last.trim();

            final isKnownGujratStd = cleanId == 'w8lgevxVEV1XQ4oYUou1' ||
                cleanId == 'bHUKkS2pdOcnT1lnBBbJ' ||
                cleanId == 'madrassa_std_1790174346830' ||
                cleanId == 'madrassa_std_1792048734875' ||
                cleanId == 'PUaTVDBQqRWv0cAu9s5k' ||
                cleanId == 'WMBYKles2V4EkcvUuAd1' ||
                cleanId.startsWith('69f');
            if (isKnownGujratStd && keyBranch != 'gujrat') {
              return true;
            }

            // Stored under an alias prefix ('grt__std__…'): move to the canonical key.
            if (keyBranch.isNotEmpty && keyBranch != 'all' && normalizeBranch(keyBranch) != keyBranch) {
              return true;
            }

            if (actualBranch.isNotEmpty && actualBranch != 'all' && actualBranch != 'global') {
              if (normalizeBranch(keyBranch) != normalizeBranch(actualBranch)) {
                return true; // Misplaced under wrong branch key!
              }
              if (normalizeBranch(actualBranch) != actualBranch) {
                return true; // Right key, alias branchId ('grt'): rewrite it as 'gujrat'.
              }
            }
          }
        }
        return false;
      }).toList();

      for (final badKey in keysToClean) {
        final raw = box.get(badKey);
        final cleanId = badKey.toString().split('__std__').last.trim();
        final badBranch = badKey.toString().split('__std__').first.toLowerCase().trim();

        if (raw is Map) {
          final data = Map<String, dynamic>.from(raw);
          var targetBranch = (data['branchId'] ?? '').toString().toLowerCase().trim();
          if (targetBranch.isEmpty || targetBranch == 'all' || targetBranch == 'global') {
            final isKnownGujratStd = cleanId == 'w8lgevxVEV1XQ4oYUou1' ||
                cleanId == 'bHUKkS2pdOcnT1lnBBbJ' ||
                cleanId == 'madrassa_std_1790174346830' ||
                cleanId == 'madrassa_std_1792048734875' ||
                cleanId == 'PUaTVDBQqRWv0cAu9s5k' ||
                cleanId == 'WMBYKles2V4EkcvUuAd1' ||
                cleanId.startsWith('69f');
            targetBranch = isKnownGujratStd ? 'gujrat' : badBranch;
          }
          targetBranch = normalizeBranch(targetBranch);

          final canonicalKey = _studentKey(targetBranch, cleanId);
          final existingCanonical = box.get(canonicalKey);
          final merged = <String, dynamic>{
            if (existingCanonical is Map && canonicalKey != badKey.toString())
              ...Map<String, dynamic>.from(existingCanonical),
            ...data,
            'id': cleanId,
            'branchId': targetBranch,
          };
          await box.put(canonicalKey, _sanitize(merged));
          // No Firestore delete here any more: it removed the cloud copy of students whose
          // branch was only spelled differently (grt/gujrat), and with them their only backup.
          if (canonicalKey == badKey.toString()) {
            changesMade = true;
            continue;
          }
        }
        await box.delete(badKey);
        changesMade = true;
      }

      // Delete corrupt placeholder entries with null/empty names
      final corruptKeys = box.keys.where((k) {
        final str = k.toString();
        if (str.endsWith('__config__current')) return false;
        final raw = box.get(k);
        if (raw is Map) {
          final n = (raw['name'] ?? '').toString().trim();
          if (n == 'null' || (n.isEmpty && raw['rollNumber'] == null)) return true;
        }
        return false;
      }).toList();
      for (final ck in corruptKeys) {
        await box.delete(ck);
        changesMade = true;
      }

      // 2. Restore full student records from sync_queue
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        final syncBox = Hive.box(LocalStorageService.syncBox);
        for (final k in syncBox.keys) {
          final entry = syncBox.get(k);
          if (entry is Map && entry['type'] == 'save_madrassa_student') {
            final data = entry['data'];
            if (data is Map) {
              final name = (data['name'] ?? '').toString().trim();
              if (name.isNotEmpty && name != 'null') {
                final sId = (entry['studentId'] ?? data['id'] ?? data['studentId'] ?? k).toString();
                final cleanId = sId.contains('__std__') ? sId.split('__std__').last.trim() : sId.trim();
                final branch = normalizeBranch((entry['branchId'] ?? data['branchId'] ?? 'gujrat').toString());
                if (cleanId.isNotEmpty && branch.isNotEmpty && branch != 'all') {
                  final key = _studentKey(branch, cleanId);
                  final existing = box.get(key);
                  final existingName = (existing is Map ? (existing['name'] ?? '') : '').toString().trim();
                  if (existingName.isEmpty || (existing is Map && data.keys.length > existing.keys.length)) {
                    final merged = <String, dynamic>{
                      if (existing is Map) ...Map<String, dynamic>.from(existing),
                      ...Map<String, dynamic>.from(data),
                      'id': cleanId,
                      'branchId': branch,
                    };
                    await box.put(key, _sanitize(merged));
                    changesMade = true;
                  }
                }
              }
            }
          }
        }
      }

      // A hard-coded list of Gujrat students (names, guardians, phone numbers, PINs) used to be
      // seeded here on every PC and pushed to Firestore. It put real personal data in a public
      // repository; those students are in Firestore and arrive with the normal download.
      if (changesMade) await box.flush();
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error in repairMissingStudentsFromLocalData: $e');
    }
  }

  // Watching the whole box means ANY write to ANY student re-emits the full
  // list. distinct() (with a deep equality check) stops the stream from
  // pushing a new event - and therefore stops the UI from rebuilding the
  // whole list - unless the actual student data changed. This is what was
  // causing the daily log list to rebuild (and visually jump) on every
  // unrelated edit.
  static Stream<List<Map<String, dynamic>>> streamStudentsCached(String branchId) {
    Stream<List<Map<String, dynamic>>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      await repairMissingStudentsFromLocalData();
      yield getAllStudentsCached(branchId);
      await for (final _ in box.watch()) {
        yield getAllStudentsCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _studentsSubscriptions = {};

  /// Subscribes to real-time changes in Firestore madrassa_students collection
  /// for this branch so all teachers on peer devices see newly added or edited
  /// students immediately without requiring a manual refresh.
  static void listenToStudentsRealtime(String branchId) {
    final normBranch = normalizeBranch(branchId);
    if (normBranch.isEmpty || normBranch == 'unknown') return;

    if (normBranch == 'all' || normBranch == 'global') {
      final branches = _getAllBranchIds().map(normalizeBranch).where((b) => b != 'all').toSet();
      for (final b in branches) {
        listenToStudentsRealtime(b);
      }
      return;
    }

    if (_studentsSubscriptions.containsKey(normBranch)) return;

    _studentsSubscriptions[normBranch] = FirebaseFirestore.instance
        .collection('branches')
        .doc(normBranch)
        .collection('madrassa_students')
        .snapshots()
        .listen((snap) async {
      try {
        final box = await LocalStorageService.ensureBoxOpen(studentsBox);
        final Map<String, dynamic> studentUpdates = {};
        for (final doc in snap.docs) {
          final data = expandMediaFromCloud(doc.data());
          final rawDocBranch = (data['branchId'] ?? data['branch'] ?? '').toString().trim();
          final docBranch = rawDocBranch.isNotEmpty ? normalizeBranch(rawDocBranch) : normBranch;
          // A document naming another branch is cached under that branch only.
          final targetBranch = docBranch == 'all' ? normBranch : docBranch;
          final key = _studentKey(targetBranch, doc.id);
          final rawExisting = box.get(key);
          final merged = _resolveStudentConflict(
            local: rawExisting is Map ? rawExisting : null,
            remote: {...data, 'branchId': targetBranch},
          );
          studentUpdates[key] = _sanitize(merged);
        }
        if (studentUpdates.isNotEmpty) {
          await box.putAll(studentUpdates);
          await box.flush();
        }
      } catch (e) {
        debugPrint('[MadrassaLocalStorage] Error in realtime students sync ($normBranch): $e');
      }
    }, onError: (e) {
      debugPrint('[MadrassaLocalStorage] Error on students snapshot listener ($normBranch): $e');
      _studentsSubscriptions.remove(normBranch);
      Timer(const Duration(seconds: 30), () => listenToStudentsRealtime(normBranch));
    });
  }

  // One listener per branch|date, a few at a time.
  static final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> _logSubscriptions = {};
  static const int _maxLogListeners = 16;

  /// Subscribes to real-time changes in Firestore madrassa_daily_logs document
  /// for this branch and date so that when one teacher saves attendance or sabq,
  /// all other teachers on peer computers receive it immediately without a page reload.
  static void listenToLogsRealtime(String branchId, String dateKey) {
    final normBranch = normalizeBranch(branchId);
    if (normBranch.isEmpty || normBranch == 'unknown') return;

    if (normBranch == 'all' || normBranch == 'global') {
      final branches = _getAllBranchIds().map(normalizeBranch).where((b) => b != 'all').toSet();
      for (final b in branches) {
        listenToLogsRealtime(b, dateKey);
      }
      return;
    }

    final subKey = '$normBranch|$dateKey';
    if (_logSubscriptions.containsKey(subKey)) return;
    while (_logSubscriptions.length >= _maxLogListeners) {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      // Drop the oldest listener that isn't today's.
      final victim = _logSubscriptions.keys.firstWhere((k) => !k.endsWith('|$today'),
          orElse: () => _logSubscriptions.keys.first);
      _logSubscriptions.remove(victim)?.cancel();
    }

    _logSubscriptions[subKey] = FirebaseFirestore.instance
        .collection('branches')
        .doc(normBranch)
        .collection('madrassa_daily_logs')
        .doc(dateKey)
        .snapshots()
        .listen((snap) async {
      try {
        if (!snap.exists || snap.data() == null) return;
        final cloudData = snap.data()!;
        final box = await LocalStorageService.ensureBoxOpen(logsBox);
        final key = _logKey(normBranch, dateKey);
        final merged = _mergeRemoteLog(box.get(key), cloudData);
        await box.put(key, _sanitize(merged));
        await box.flush();
      } catch (e) {
        debugPrint('[MadrassaLocalStorage] Error in realtime daily logs sync: $e');
      }
    }, onError: (e) {
      debugPrint('[MadrassaLocalStorage] Error on daily logs snapshot listener: $e');
      _logSubscriptions.remove(subKey);
      Timer(const Duration(seconds: 30), () => listenToLogsRealtime(normBranch, dateKey));
    });
  }

  static List<String> _getAllBranchIds() {
    const defaultCoreBranches = ['gujrat', 'karachi', 'saddar', 'haji', 'sialkot', 'rawalpindi', 'jalalpurjattan'];
    final list = LocalStorageService.getLocalBranchesList();
    final ids = list
        .map((b) => normalizeBranch(b['id']?.toString() ?? ''))
        .where((s) => s.isNotEmpty && s != 'all' && s != 'global' && s != 'unknown')
        .toSet();
    ids.addAll(defaultCoreBranches);
    return ids.toList();
  }

  /// Scans syncBox and deadLetterQueueBox for any oversized or stuck Madrassa or School student records,
  /// purges corrupt/nameless phantom stubs, compacts media payloads on valid records,
  /// resets their retry state, unparks them, and moves them back to the active queue.
  static Future<int> healPoisonedMadrassaSyncQueue() async {
    int healed = 0;
    try {
      bool isCorruptStudentAction(Map act) {
        final data = act['data'] is Map ? act['data'] as Map : null;
        final sid = (act['studentId'] ?? data?['studentId'] ?? data?['id'] ?? act['entityId'] ?? act['docId'])?.toString().trim();
        final name = (data?['name'] ?? data?['studentName'])?.toString().trim();
        if (sid == null || sid.isEmpty) return true;
        if (sid.contains('config__current') || sid.contains('__config__')) return true;
        if (sid.contains('__std__') && sid.split('__std__').length > 2) return true;
        if (name == null || name.isEmpty) return true;
        return false;
      }

      bool isStudentAction(Map act) {
        final t = (act['type'] ?? '').toString();
        final c = (act['collection'] ?? '').toString();
        return t == 'save_madrassa_student' ||
            t == 'save_madrassa_admission' ||
            t == 'save_school_student' ||
            t == 'save_school_admission' ||
            c.contains('madrassa_students') ||
            c.contains('school_students');
      }

      if (Hive.isBoxOpen(LocalStorageService.deadLetterQueueBox)) {
        final dlq = Hive.box(LocalStorageService.deadLetterQueueBox);
        final syncBox = Hive.isBoxOpen(LocalStorageService.syncBox)
            ? Hive.box(LocalStorageService.syncBox)
            : await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);

        for (final k in dlq.keys.toList()) {
          final val = dlq.get(k);
          if (val is Map && isStudentAction(val)) {
            final act = Map<String, dynamic>.from(val);
            if (isCorruptStudentAction(act)) {
              await dlq.delete(k);
              continue;
            }
            if (act['data'] is Map) {
              final isSchool = (act['type'] == 'save_school_student') ||
                  (act['collection']?.toString().contains('school_students') == true);
              if (isSchool) {
                act['data'] = SchoolLocalStorage.compactMediaForCloud(Map<String, dynamic>.from(act['data'] as Map));
                act['type'] = 'save_school_student';
              } else {
                act['data'] = compactMediaForCloud(Map<String, dynamic>.from(act['data'] as Map));
                act['type'] = 'save_madrassa_student';
              }
            }
            act['attempts'] = 0;
            act.remove('lastError');
            act.remove('nextRetryAt');
            act.remove('parked');
            act.remove('autoRevivals');
            await syncBox.put(k, act);
            await dlq.delete(k);
            healed++;
          }
        }
      }

      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        final syncBox = Hive.box(LocalStorageService.syncBox);
        for (final k in syncBox.keys.toList()) {
          final val = syncBox.get(k);
          if (val is Map && isStudentAction(val)) {
            final act = Map<String, dynamic>.from(val);
            if (isCorruptStudentAction(act)) {
              await syncBox.delete(k);
              continue;
            }
            if (act['data'] is Map) {
              final isSchool = (act['type'] == 'save_school_student') ||
                  (act['collection']?.toString().contains('school_students') == true);
              if (isSchool) {
                act['data'] = SchoolLocalStorage.compactMediaForCloud(Map<String, dynamic>.from(act['data'] as Map));
                act['type'] = 'save_school_student';
              } else {
                act['data'] = compactMediaForCloud(Map<String, dynamic>.from(act['data'] as Map));
                act['type'] = 'save_madrassa_student';
              }
              if ((act['attempts'] as int? ?? 0) > 0 || act['parked'] == true || act['nextRetryAt'] != null) {
                act['attempts'] = 0;
                act.remove('parked');
                act.remove('autoRevivals');
                act.remove('nextRetryAt');
                act.remove('lastError');
                await syncBox.put(k, act);
                healed++;
              }
            }
          }
        }
      }
      if (healed > 0) {
        unawaited(SyncService().triggerUpload(urgent: true));
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] healPoisonedMadrassaSyncQueue notice: $e');
    }
    return healed;
  }

  /// Student saves still waiting in this PC's upload queue (including ones parked as failed).
  static int pendingStudentUploads() {
    var n = 0;
    for (final boxName in [LocalStorageService.syncBox, LocalStorageService.deadLetterQueueBox]) {
      if (!Hive.isBoxOpen(boxName)) continue;
      for (final v in Hive.box(boxName).values) {
        if (v is Map && (v['type'] == 'save_madrassa_student' || v['type'] == 'save_madrassa_admission')) n++;
      }
    }
    return n;
  }

  /// Downloads a branch's students into Hive. Returns false when the cloud could not be read.
  static Future<bool> downloadStudents(String branchId, {bool force = false}) async {
    try {
      final normBranch = normalizeBranch(branchId);
      if (normBranch.isEmpty || normBranch == 'unknown') return false;

      // Ensure local records are healed and cross-enrolled duplicates cleaned across branches
      await repairMissingStudentsFromLocalData(force: force);
      await healPoisonedMadrassaSyncQueue();

      if (normBranch == 'all' || normBranch == 'global') {
        final branches = _getAllBranchIds().map(normalizeBranch).where((b) => b != 'all').toSet();
        final results = await Future.wait(branches.map((b) => downloadStudents(b, force: force)));
        return results.every((ok) => ok);
      }

      // 4 s was too short for a cold Windows Firestore client or a slow mobile link; the
      // download silently gave up and the screen still said "Sync completed".
      final timeout = Duration(seconds: force ? 30 : 15);
      Future<QuerySnapshot<Map<String, dynamic>>?> fetch(String b) async {
        try {
          return await FirebaseFirestore.instance
              .collection('branches')
              .doc(b)
              .collection('madrassa_students')
              .get()
              .timeout(timeout, onTimeout: () => throw TimeoutException('downloadStudents timeout'));
        } catch (e) {
          debugPrint('[MadrassaLocalStorage] Error fetching students from branches/$b: $e');
          return null;
        }
      }

      final snap = await fetch(normBranch);
      if (snap == null) return false;
      final legacy = <String, QuerySnapshot<Map<String, dynamic>>>{};
      for (final b in legacyBranchIds(normBranch)) {
        final s = await fetch(b);
        if (s != null && s.docs.isNotEmpty) legacy[b] = s;
      }

      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      final Map<String, dynamic> studentUpdates = {};

      // Cloud documents are only read here. Documents whose branchId names another branch used
      // to be deleted from this branch's collection; with branch aliases (grt vs gujrat) that
      // deleted real students. They are now just cached under the branch they name.
      void cacheDoc(String id, Map<String, dynamic> data) {
        final rawDocBranch = (data['branchId'] ?? data['branch'] ?? '').toString().trim();
        final docBranch = rawDocBranch.isNotEmpty ? normalizeBranch(rawDocBranch) : normBranch;
        final targetBranch = docBranch == 'all' ? normBranch : docBranch;
        final key = _studentKey(targetBranch, id);
        final rawExisting = studentUpdates[key] ?? box.get(key);
        final merged = _resolveStudentConflict(
          local: rawExisting is Map ? rawExisting : null,
          remote: {...expandMediaFromCloud(data), 'branchId': targetBranch},
        );
        studentUpdates[key] = _sanitize(merged);
      }

      // Ids with a full record in the canonical folder. A status-only stub (an offboard written
      // to the canonical path while the student itself sat under the alias) doesn't count.
      final canonicalIds = <String>{};
      final canonicalStubs = <String, Map<String, dynamic>>{};
      for (final doc in snap.docs) {
        if ((doc.data()['name'] ?? '').toString().trim().isNotEmpty) {
          canonicalIds.add(doc.id);
        } else {
          canonicalStubs[doc.id] = doc.data();
        }
        cacheDoc(doc.id, doc.data());
      }

      // Students saved under an old alias (branches/grt) before normalizeBranch folded it:
      // cache them and upload them once to the canonical branch, so HQ and web see them.
      var migrated = 0;
      for (final entry in legacy.entries) {
        for (final doc in entry.value.docs) {
          if (canonicalIds.contains(doc.id)) continue;
          // A newer status stub (e.g. offboarded) in the canonical folder wins over the old copy.
          final full = {...doc.data(), ...?canonicalStubs[doc.id]};
          cacheDoc(doc.id, full);
          canonicalIds.add(doc.id);
          final data = Map<String, dynamic>.from(_sanitize({...full, 'id': doc.id, 'branchId': normBranch}));
          await LocalStorageService.enqueueSync({
            'type': 'save_madrassa_student',
            'branchId': normBranch,
            'studentId': doc.id,
            'entityId': doc.id,
            'data': data,
            'localBox': LocalStorageService.madrassaStudentsBox,
            'localKey': _studentKey(normBranch, doc.id),
          });
          migrated++;
        }
      }

      if (studentUpdates.isNotEmpty) {
        await box.putAll(studentUpdates);
        await box.flush();
      }
      if (migrated > 0) unawaited(SyncService().triggerUpload(urgent: true));
      debugPrint('[MadrassaLocalStorage] Downloaded ${snap.docs.length} madrassa students for $normBranch'
          '${migrated > 0 ? ' (+$migrated from ${legacy.keys.join('/')}, queued to $normBranch)' : ''}');
      return true;
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error in downloadStudents: $e');
      return false;
    }
  }

  static List<Map<String, dynamic>> getStudentsForGuardian(String branchId, List<String> studentIds) {
    if (!Hive.isBoxOpen(studentsBox)) return const [];
    final List<Map<String, dynamic>> result = [];
    for (final id in studentIds) {
      final data = getStudentCached(branchId, id);
      if (data != null) {
        final m = Map<String, dynamic>.from(data);
        m['id'] = id;
        result.add(m);
      }
    }
    return result;
  }

  static Future<void> downloadStudentsForGuardian(String branchId, List<String> studentIds) async {
    if (studentIds.isEmpty) return;
    try {
      final normBranch = normalizeBranch(branchId);
      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      final Map<String, dynamic> updates = {};
      for (final id in studentIds) {
        DocumentSnapshot<Map<String, dynamic>>? doc;
        try {
          doc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(normBranch)
              .collection('madrassa_students')
              .doc(id)
              .get()
              .timeout(const Duration(seconds: 4));
        } catch (_) {}

        // Fallback: check alternate branch (e.g. karachi if gujrat, or gujrat if karachi)
        if (doc == null || !doc.exists) {
          final candidateBranches = normBranch == 'gujrat' 
              ? const ['karachi', 'saddar', 'jalalpurjattan']
              : const ['gujrat', 'saddar', 'jalalpurjattan'];
          for (final altBranch in candidateBranches) {
            try {
              final altDoc = await FirebaseFirestore.instance
                  .collection('branches')
                  .doc(altBranch)
                  .collection('madrassa_students')
                  .doc(id)
                  .get()
                  .timeout(const Duration(seconds: 3));
              if (altDoc.exists && altDoc.data() != null) {
                doc = altDoc;
                break;
              }
            } catch (_) {}
          }
        }

        if (doc != null && doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final effectiveStudentBranch = (data['branchId'] ?? normBranch).toString().toLowerCase().trim();
          final key = _studentKey(effectiveStudentBranch, doc.id);
          final rawExisting = box.get(key);
          final merged = _resolveStudentConflict(
            local: rawExisting is Map ? rawExisting : null,
            remote: data,
          );
          updates[key] = _sanitize(merged);
          // Also cache under query branch key if different to ensure fast retrieval
          if (effectiveStudentBranch != normBranch) {
            final altKey = _studentKey(normBranch, doc.id);
            updates[altKey] = _sanitize(merged);
          }
        }
      }
      if (updates.isNotEmpty) {
        await box.putAll(updates);
        await box.flush();
      }
      debugPrint('[MadrassaLocalStorage] Downloaded ${updates.length} scoped guardian students.');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading scoped guardian students: $e');
    }
  }

  // ── Daily Logs Cache ───────────────────────────────────────────────────────

  static Map<String, dynamic>? getLogCached(String branchId, String dateKey) {
    if (!Hive.isBoxOpen(logsBox)) return null;
    final box = _getLogsBox();
    final normBranch = normalizeBranch(branchId);
    final isGlobal = normBranch == 'all' || normBranch == 'global' || normBranch == 'main';

    final merged = <String, dynamic>{};
    bool foundAny = false;

    if (isGlobal) {
      for (final k in box.keys) {
        final keyStr = k.toString();
        if (keyStr.endsWith('__log__$dateKey') || keyStr.endsWith('_$dateKey') || keyStr == dateKey) {
          final raw = box.get(k);
          if (raw is Map) {
            foundAny = true;
            merged.addAll(Map<String, dynamic>.from(raw));
          }
        }
      }
      return foundAny ? merged : null;
    }

    // 1. Primary normalized key (e.g. karachi__log__2026-10-07)
    final primaryKey = _logKey(normBranch, dateKey);
    final primaryRaw = box.get(primaryKey);
    if (primaryRaw is Map) {
      foundAny = true;
      merged.addAll(Map<String, dynamic>.from(primaryRaw));
    }

    // 2. Also merge matching family aliases & 'all' keys for this date so all teachers share logs
    for (final k in box.keys) {
      final keyStr = k.toString();
      if (!keyStr.endsWith('__log__$dateKey')) continue;
      if (keyStr == primaryKey) continue;
      final kPrefix = keyStr.split('__log__').first;
      final isFamily = normalizeBranch(kPrefix) == normBranch || kPrefix == 'all';
      if (isFamily) {
        final raw = box.get(k);
        if (raw is Map) {
          foundAny = true;
          // Primary takes precedence, only fill in missing keys
          for (final entry in raw.entries) {
            if (!merged.containsKey(entry.key.toString())) {
              merged[entry.key.toString()] = entry.value;
            }
          }
        }
      }
    }
    return foundAny ? merged : null;
  }

  static int getPresentStudentsCount(String branchId, String dateKey) {
    final log = getLogCached(branchId, dateKey);
    if (log == null || log.isEmpty) return 0;
    int present = 0;
    for (final val in log.values) {
      if (val is Map) {
        final att = (val['attendance'] ?? val['status'])?.toString().toLowerCase().trim();
        if (att == 'present' || att == 'p') {
          present++;
        }
      }
    }
    return present;
  }

  static int getPresentTeachersCount(String branchId, String dateKey) {
    if (!Hive.isBoxOpen(logsBox)) return 0;
    final b = branchId.toLowerCase().trim();
    final isAll = b == 'all' || b == 'global' || b.isEmpty;
    final normBranch = normalizeBranch(b);
    final box = _getLogsBox();
    int count = 0;
    final countedTeacherIds = <String>{};

    if (isAll) {
      final suffix = '__madrassa_tchlog__$dateKey';
      for (final k in box.keys) {
        if (k.toString().endsWith(suffix)) {
          final raw = box.get(k);
          if (raw is Map && raw['entries'] is Map) {
            (raw['entries'] as Map).forEach((tid, v) {
              final idStr = tid.toString();
              if (countedTeacherIds.contains(idStr)) return;
              if (v is Map) {
                final status = (v['status'] ?? v['attendance'])?.toString().toLowerCase().trim();
                if (status == 'present' || status == 'p') {
                  countedTeacherIds.add(idStr);
                  count++;
                }
              }
            });
          }
        }
      }
      return count;
    }

    final primaryKey = _teacherAttendanceKey(normBranch, dateKey);
    final rawPrimary = box.get(primaryKey);
    if (rawPrimary is Map && rawPrimary['entries'] is Map) {
      (rawPrimary['entries'] as Map).forEach((tid, v) {
        final idStr = tid.toString();
        if (countedTeacherIds.contains(idStr)) return;
        if (v is Map) {
          final status = (v['status'] ?? v['attendance'])?.toString().toLowerCase().trim();
          if (status == 'present' || status == 'p') {
            countedTeacherIds.add(idStr);
            count++;
          }
        }
      });
    }

    final suffix = '__madrassa_tchlog__$dateKey';
    for (final k in box.keys) {
      final keyStr = k.toString();
      if (!keyStr.endsWith(suffix) || keyStr == primaryKey) continue;
      final kPrefix = keyStr.split('__madrassa_tchlog__').first;
      if (normalizeBranch(kPrefix) == normBranch || kPrefix == 'all') {
        final raw = box.get(k);
        if (raw is Map && raw['entries'] is Map) {
          (raw['entries'] as Map).forEach((tid, v) {
            final idStr = tid.toString();
            if (countedTeacherIds.contains(idStr)) return;
            if (v is Map) {
              final status = (v['status'] ?? v['attendance'])?.toString().toLowerCase().trim();
              if (status == 'present' || status == 'p') {
                countedTeacherIds.add(idStr);
                count++;
              }
            }
          });
        }
      }
    }
    return count;
  }

  static Map<String, dynamic>? getDailyLogCached(String branchId, String dateKey) =>
      getLogCached(branchId, dateKey);

  /// Stores a fee record received from another PC (LAN), as it is. The PC that took the
  /// payment uploads it; re-saving it here re-queued and re-broadcast it on every peer and,
  /// on a peer without the record, replaced the payment method with 'Cash' and blanked the
  /// receipt. An older copy never replaces a newer one.
  static Future<void> cacheFeePayment(String branchId, Map<String, dynamic> data) async {
    final studentId = (data['studentId'] ?? '').toString().trim();
    final year = (data['year'] as num?)?.toInt();
    final month = (data['month'] as num?)?.toInt();
    if (studentId.isEmpty || year == null || month == null) return;
    final key = _feeKey(branchId.toLowerCase().trim(), year, month, studentId);
    final box = await LocalStorageService.ensureBoxOpen(feesBox);
    final existing = box.get(key);
    if (existing is Map) {
      final mine = _parseTimestamp(existing['lastUpdatedAt'] ?? existing['markedAt']);
      final theirs = _parseTimestamp(data['lastUpdatedAt'] ?? data['markedAt']);
      if (mine != null && theirs != null && theirs.isBefore(mine)) return;
    }
    await box.put(key, _sanitize({
      if (existing is Map) ...Map<String, dynamic>.from(existing),
      ...data,
    }));
    await box.flush();
  }

  /// Merges a day log that came from the cloud or a LAN peer into the local
  /// copy. The sender's sync flags (often `pendingSync:true`, since they are
  /// stored inside the day map and uploaded with it) must not be adopted, or
  /// every PC's backfill re-uploads the day on every sweep. The day is
  /// already in the cloud (or its originator uploads it), so it is marked
  /// synced here — unless this PC has its own unsynced edits for that day.
  static Map<String, dynamic> _mergeRemoteLog(dynamic local, Map<String, dynamic> remote) {
    final localMap = local is Map ? Map<String, dynamic>.from(local) : <String, dynamic>{};
    final localPending = localMap['pendingSync'] == true || localMap['syncStatus'] == 'pending';
    final merged = <String, dynamic>{...localMap, ...remote};
    const flags = ['syncStatus', 'pendingSync', 'synced', 'lastSyncedAt'];
    if (localPending) {
      for (final f in flags) {
        if (localMap.containsKey(f)) {
          merged[f] = localMap[f];
        } else {
          merged.remove(f);
        }
      }
    } else {
      merged['syncStatus'] = 'synced';
      merged['pendingSync'] = false;
      merged['synced'] = true;
      merged['lastSyncedAt'] = DateTime.now().toIso8601String();
    }
    return merged;
  }

  static Future<void> cacheDailyLog(String branchId, String dateKey, Map<String, dynamic> data) async {
    final normBranch = normalizeBranch(branchId);
    final key = _logKey(normBranch, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(logsBox);
    final merged = _mergeRemoteLog(box.get(key), data);
    await box.put(key, _sanitize(merged));
    await box.flush();
  }

  // This one watches Hive for changes. Emits whenever this date's logs change.
  static Stream<Map<String, dynamic>> streamLogCached(String branchId, String dateKey) {
    final normBranch = normalizeBranch(branchId);
    final isGlobal = normBranch == 'all' || normBranch == 'global' || normBranch == 'main';

    Stream<Map<String, dynamic>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(logsBox);
      yield getLogCached(normBranch, dateKey) ?? {};
      await for (final event in box.watch()) {
        final keyStr = event.key?.toString() ?? '';
        if (isGlobal || keyStr.endsWith('__log__$dateKey') || keyStr == dateKey) {
          yield getLogCached(normBranch, dateKey) ?? {};
        }
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static Future<void> saveLogRecordLocal({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> logData,
    required String editorName,
    required String editorRole,
  }) async {
    final normBranch = normalizeBranch(branchId);
    final effectiveBranch = (normBranch == 'all' || normBranch == 'global')
        ? ((branchId.toLowerCase().contains('karachi') || branchId.toLowerCase().contains('saddar')) ? 'karachi' : 'gujrat')
        : normBranch;

    final key = _logKey(effectiveBranch, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(logsBox);

    // Get current cache log or start empty
    final existing = box.get(key) ?? getLogCached(effectiveBranch, dateKey) ?? {};
    final updated = Map<String, dynamic>.from(existing);

    // Merge changes
    final studentWrites = <Future<void>>[];
    logData.forEach((sId, data) {
      if (data is Map) {
        final existingStudentLog = updated[sId] is Map ? Map<String, dynamic>.from(updated[sId] as Map) : <String, dynamic>{};
        updated[sId] = {
          ...existingStudentLog,
          ...Map<String, dynamic>.from(data),
          'lastEditedBy': editorName,
          'lastEditedAt': DateTime.now().toIso8601String(),
        };

        // Also update local cached student's currentLines if updated
        if (data.containsKey('currentLines')) {
          final studentCache = getStudentCached(effectiveBranch, sId);
          if (studentCache != null) {
            studentCache['currentLines'] = data['currentLines'];
            studentWrites.add(cacheStudent(effectiveBranch, sId, studentCache));
          }
        }
      }
    });
    if (studentWrites.isNotEmpty) {
      await Future.wait(studentWrites);
    }

    final sanitized = _sanitize(updated);
    sanitized['syncStatus'] = 'pending';
    sanitized['pendingSync'] = true;
    sanitized['synced'] = false;
    await box.put(key, sanitized);
    await box.flush();

    // Only the students edited now (plus the day's top-level fields) go out. The
    // whole day map carried this PC's possibly stale copy of everyone else, which
    // reverted other desks' entries on peers and in the cloud. Same payload
    // shape: receivers merge per student, the queue merges per student and the
    // upload is set(merge: true).
    final delta = <String, dynamic>{
      for (final e in sanitized.entries)
        if (e.value is! Map || logData.containsKey(e.key)) e.key: e.value,
    };

    // Broadcast LAN event (Server and peers)
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaDailyLog,
        data: {
          'branchId': effectiveBranch,
          'dateKey': dateKey,
          'logData': delta,
          'editorName': editorName,
          'editorRole': editorRole,
        },
        branchId: effectiveBranch,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // Always enqueue sync action for durable Firestore upload
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_log',
        'entityId': 'mlog_${effectiveBranch}_$dateKey',
        'branchId': effectiveBranch,
        'dateKey': dateKey,
        'data': delta,
        'localBox': LocalStorageService.madrassaLogsBox,
        'localKey': key,
        'forceUpload': true,
      });

      // Enqueue sync actions for changed students' currentLines
      logData.forEach((sId, data) {
        if (data is Map && data.containsKey('currentLines')) {
          unawaited(LocalStorageService.enqueueSync({
            'type': 'update_madrassa_student',
            'branchId': effectiveBranch,
            'studentId': sId,
            'entityId': sId, // stable key: repeated edits coalesce instead of piling up
            'currentLines': data['currentLines'],
          }));
        }
      });

      // Uploaded by the queued item above. The direct write that was here was a second
      // write of the same document, left in the SDK's hidden queue whenever Firestore
      // did not answer (and sent again later, costing quota twice).

      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadLogsForMonth(String branchId, int year, int month) async {
    try {
      final normBranch = normalizeBranch(branchId);
      if (normBranch.isEmpty || normBranch == 'unknown') return;

      if (normBranch == 'all' || normBranch == 'global') {
        final branches = _getAllBranchIds().map(normalizeBranch).where((b) => b != 'all').toSet();
        await Future.wait(branches.map((b) => downloadLogsForMonth(b, year, month)));
        return;
      }

      final startStr = DateFormat('yyyy-MM-01').format(DateTime(year, month, 1));
      final endStr = DateFormat('yyyy-MM-dd').format(DateTime(year, month + 1, 0));

      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(normBranch)
          .collection('madrassa_daily_logs')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: startStr)
          .where(FieldPath.documentId, isLessThanOrEqualTo: endStr)
          .get()
          // 4 s was routinely too short on Windows (cold Firestore client); logs then only
          // arrived when someone happened to reopen the screen.
          .timeout(const Duration(seconds: 15), onTimeout: () => throw TimeoutException('downloadLogsForMonth timeout'));

      final box = await LocalStorageService.ensureBoxOpen(logsBox);
      final Map<String, dynamic> logUpdates = {};
      for (final doc in snap.docs) {
        final key = _logKey(normBranch, doc.id);
        
        // Merge cloud fields preserving local updates if local is newer (LWW conflict resolution)
        final existing = box.get(key) ?? logUpdates[key];
        logUpdates[key] = _sanitize(_mergeRemoteLog(existing, doc.data()));
      }
      if (logUpdates.isNotEmpty) {
        await box.putAll(logUpdates);
      }
      await box.flush();
      debugPrint('[MadrassaLocalStorage] Downloaded ${snap.docs.length} daily log documents for $normBranch ($year-$month).');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading daily logs: $e');
    }
  }

  static List<Map<String, dynamic>> getLogsForMonthCached(String branchId, int year, int month) {
    if (!Hive.isBoxOpen(logsBox)) return const [];
    final monthStr = '$year-${month.toString().padLeft(2, '0')}';
    final normBranch = normalizeBranch(branchId);
    final isGlobal = normBranch == 'all' || normBranch == 'global' || normBranch == 'main';
    final box = _getLogsBox();

    final mapByDate = <String, Map<String, dynamic>>{};
    for (final k in box.keys) {
      final keyStr = k.toString();
      if (!keyStr.contains('__log__$monthStr-')) continue;
      final kBranch = keyStr.split('__log__').first;
      final isMatch = isGlobal || normalizeBranch(kBranch) == normBranch || kBranch == 'all';
      if (isMatch) {
        final dateKey = keyStr.split('__log__').last;
        final raw = box.get(k);
        if (raw is Map) {
          final entry = mapByDate.putIfAbsent(dateKey, () => {'id': dateKey, 'dateKey': dateKey});
          entry.addAll(Map<String, dynamic>.from(raw));
        }
      }
    }
    final list = mapByDate.values.toList();
    list.sort((a, b) => a['dateKey'].toString().compareTo(b['dateKey'].toString()));
    return list;
  }

  static List<Map<String, dynamic>> getAllLogsCached(String branchId) {
    if (!Hive.isBoxOpen(logsBox)) return const [];
    final normBranch = normalizeBranch(branchId);
    final isGlobal = normBranch == 'all' || normBranch == 'global' || normBranch == 'main';
    final box = _getLogsBox();

    final mapByDate = <String, Map<String, dynamic>>{};
    for (final k in box.keys) {
      final keyStr = k.toString();
      if (!keyStr.contains('__log__')) continue;
      final kBranch = keyStr.split('__log__').first;
      final isMatch = isGlobal || normalizeBranch(kBranch) == normBranch || kBranch == 'all';
      if (isMatch) {
        final dateKey = keyStr.split('__log__').last;
        final raw = box.get(k);
        if (raw is Map) {
          final entry = mapByDate.putIfAbsent(dateKey, () => {'id': dateKey, 'dateKey': dateKey});
          entry.addAll(Map<String, dynamic>.from(raw));
        }
      }
    }
    final list = mapByDate.values.toList();
    list.sort((a, b) => a['dateKey'].toString().compareTo(b['dateKey'].toString()));
    return list;
  }

  static Stream<List<Map<String, dynamic>>> streamLogsForMonthCached(String branchId, int year, int month) {
    Stream<List<Map<String, dynamic>>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(logsBox);
      yield getLogsForMonthCached(branchId, year, month);
      await for (final _ in box.watch()) {
        yield getLogsForMonthCached(branchId, year, month);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }


  // ── Holidays Cache ─────────────────────────────────────────────────────────

  static List<Map<String, dynamic>> getHolidaysCached(String branchId) {
    if (!Hive.isBoxOpen(holidaysBox)) return const [];
    final prefix = '${branchId.toLowerCase().trim()}__hol__';
    final box = _getHolidaysBox();
    return box.keys
        .where((k) => k.toString().startsWith(prefix))
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().split('__hol__').last;
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamHolidaysCached(String branchId) {
    Stream<List<Map<String, dynamic>>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(holidaysBox);
      yield getHolidaysCached(branchId);
      await for (final _ in box.watch()) {
        yield getHolidaysCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static Future<void> saveHolidayLocalAndSync({
    required String branchId,
    required String name,
    required DateTime date,
  }) async {
    final effectiveBranchId = branchId.toLowerCase().trim();
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final key = _holidayKey(effectiveBranchId, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(holidaysBox);
    final data = {
      'id': dateKey,
      'name': name,
      'date': date.toIso8601String(),
      'branchId': effectiveBranchId,
      'lastUpdatedAt': DateTime.now().toIso8601String(),
    };
    await box.put(key, _sanitize(data));
    await box.flush();

    // Broadcast LAN
    try {
      final payload = RealtimeEvents.payload(
        type: 'save_madrassa_holiday',
        data: data,
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // Always enqueue sync action
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_holiday',
        'branchId': effectiveBranchId,
        'id': dateKey,
        'data': data,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> deleteHolidayLocalAndSync({
    required String branchId,
    required String holidayId,
  }) async {
    final effectiveBranchId = branchId.toLowerCase().trim();
    final key = _holidayKey(effectiveBranchId, holidayId);
    final box = await LocalStorageService.ensureBoxOpen(holidaysBox);
    await box.delete(key);
    await box.flush();

    // Broadcast LAN
    try {
      final payload = RealtimeEvents.payload(
        type: 'delete_madrassa_holiday',
        data: {'id': holidayId, 'branchId': effectiveBranchId},
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    try {
      await LocalStorageService.enqueueSync({
        'type': 'delete_madrassa_holiday',
        'branchId': effectiveBranchId,
        'id': holidayId,
      });
      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadHolidays(String branchId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_holidays')
          .get();

      final box = await LocalStorageService.ensureBoxOpen(holidaysBox);
      final prefix = '${branchId.toLowerCase().trim()}__hol__';
      
      // Clear existing cached holidays for this branch first
      final keysToDelete = box.keys.where((k) => k.toString().startsWith(prefix)).toList();
      await box.deleteAll(keysToDelete);

      final Map<String, dynamic> holidayUpdates = {};
      for (final doc in snap.docs) {
        final key = _holidayKey(branchId, doc.id);
        holidayUpdates[key] = _sanitize(doc.data());
      }
      if (holidayUpdates.isNotEmpty) {
        await box.putAll(holidayUpdates);
      }
      await box.flush();
      debugPrint('[MadrassaLocalStorage] Downloaded and cached ${snap.docs.length} holidays.');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading holidays: $e');
    }
  }

  static MadrassaConfig? getConfigCached(String branchId) {
    if (!Hive.isBoxOpen(studentsBox)) return null;
    final key = '${branchId.toLowerCase().trim()}__config__current';
    try {
      final raw = _getStudentsBox().get(key);
      if (raw == null || raw is! Map) return null;
      return MadrassaConfig.fromMap(raw);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error reading cached config: $e');
      return null;
    }
  }

  static Stream<MadrassaConfig> streamConfigCached(String branchId) {
    Stream<MadrassaConfig> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      final key = '${branchId.toLowerCase().trim()}__config__current';
      final cfg = getConfigCached(branchId) ?? MadrassaConfig(id: 'current', year: DateTime.now().year, month: DateTime.now().month);
      yield cfg;
      await for (final event in box.watch(key: key)) {
        if (event.value != null && event.value is Map) {
          try {
            yield MadrassaConfig.fromMap(event.value as Map);
          } catch (e) {
            debugPrint('[MadrassaLocalStorage] Error streaming cached config: $e');
          }
        }
      }
    }
    return source();
  }

  static Future<void> downloadConfig(String branchId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_config')
          .doc('current')
          .get();

      if (doc.exists && doc.data() != null) {
        final box = await LocalStorageService.ensureBoxOpen(studentsBox);
        final key = '${branchId.toLowerCase().trim()}__config__current';
        await box.put(key, _sanitize(doc.data()!));
        await box.flush();
        debugPrint('[MadrassaLocalStorage] Downloaded and cached madrassa config.');
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading config: $e');
    }
  }

  // ── Fee Payments Cache & HQ Manager Audit ───────────────────────────────────

  static Map<String, dynamic>? getFeePaymentCached(String branchId, int year, int month, String studentId) {
    if (!Hive.isBoxOpen(feesBox)) return null;
    final key = _feeKey(branchId, year, month, studentId);
    final box = _getFeesBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static Map<String, Map<String, dynamic>> getFeePaymentsForMonthCached(String branchId, int year, int month) {
    if (!Hive.isBoxOpen(feesBox)) return const {};
    final prefix = '${branchId.toLowerCase().trim()}__fee__${year}_${month}__';
    final box = _getFeesBox();
    final Map<String, Map<String, dynamic>> result = {};
    for (final k in box.keys) {
      if (k.toString().startsWith(prefix)) {
        final raw = box.get(k);
        if (raw is Map) {
          final sId = k.toString().split('__').last;
          result[sId] = Map<String, dynamic>.from(raw);
        }
      }
    }
    return result;
  }

  static Stream<Map<String, Map<String, dynamic>>> streamFeePaymentsForMonthCached(String branchId, int year, int month) {
    Stream<Map<String, Map<String, dynamic>>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(feesBox);
      yield getFeePaymentsForMonthCached(branchId, year, month);
      await for (final _ in box.watch()) {
        yield getFeePaymentsForMonthCached(branchId, year, month);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static Future<void> saveFeePaymentLocalAndSync({
    required String branchId,
    required String studentId,
    required String studentName,
    required String rollNumber,
    required int year,
    required int month,
    required double amountDue,
    required double amountPaid,
    required String status, // 'paid', 'partial', or 'unpaid'
    required String markedBy,
    required String markedByRole,
    double? discount,
    double? balanceDue,
    String? paymentMethod,
    String? receiptId,
    String? note,
  }) async {
    final effectiveBranchId = branchId.toLowerCase().trim();
    final docId = '${year}_${month}_$studentId';
    final key = _feeKey(effectiveBranchId, year, month, studentId);
    final box = await LocalStorageService.ensureBoxOpen(feesBox);
    final now = DateTime.now();

    final existing = box.get(key);
    final currentRecord = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};

    final effDiscount = (discount ?? (currentRecord['discount'] as num?)?.toDouble() ?? 0.0);
    final effBalanceDue = balanceDue ??
        ((status == 'unpaid')
            ? amountDue
            : (amountDue - amountPaid - effDiscount).clamp(0.0, double.infinity));
    final resolvedStatus = (status == 'unpaid')
        ? 'unpaid'
        : (effBalanceDue <= 0.0 ? 'paid' : ((amountPaid > 0 || effDiscount > 0) ? 'partial' : 'unpaid'));

    final auditList = List<Map<String, dynamic>>.from(
      (currentRecord['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );
    auditList.add({
      'status': resolvedStatus,
      'by': markedBy,
      'role': markedByRole,
      'timestamp': now.toIso8601String(),
      'note': note ?? '',
      'amountPaid': amountPaid,
      'amountDue': amountDue,
      'discount': effDiscount,
      'balanceDue': effBalanceDue,
      'paymentMethod': paymentMethod ?? currentRecord['paymentMethod'] ?? 'Cash',
      'receiptId': receiptId ?? currentRecord['receiptId'] ?? '',
    });

    final data = <String, dynamic>{
      ...currentRecord,
      'id': docId,
      'branchId': effectiveBranchId,
      'studentId': studentId,
      'studentName': studentName,
      'rollNumber': rollNumber,
      'year': year,
      'month': month,
      'amountDue': amountDue,
      'totalFee': amountDue,
      'amountPaid': amountPaid,
      'discount': effDiscount,
      'balanceDue': effBalanceDue,
      'paymentMethod': paymentMethod ?? currentRecord['paymentMethod'] ?? 'Cash',
      'receiptId': receiptId ?? currentRecord['receiptId'] ?? '',
      'status': resolvedStatus,
      'markedBy': markedBy,
      'markedByRole': markedByRole,
      'markedAt': now.toIso8601String(),
      'note': note ?? '',
      'lastUpdatedAt': now.toIso8601String(),
      'auditLog': auditList,
    };

    final sanitized = _sanitize(data);
    await box.put(key, sanitized);
    await box.flush();

    // Broadcast LAN event (Server and peers)
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaFeePayment,
        data: sanitized,
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // Always enqueue sync action for durable Firestore upload
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_fee_payment',
        'branchId': effectiveBranchId,
        'id': docId,
        'studentId': studentId,
        'year': year,
        'month': month,
        'data': sanitized,
      });

      // Enqueue audit log
      await LocalStorageService.enqueueSync({
        'type': 'save_audit_log',
        'branchId': effectiveBranchId,
        'data': {
          'id': DateTime.now().millisecondsSinceEpoch.toString(),
          'collection': 'madrassa_fee_payments',
          'documentId': docId,
          'action': status == 'paid' ? 'mark_paid' : 'mark_unpaid',
          'userId': markedBy,
          'username': markedBy,
          'timestamp': now.toIso8601String(),
          'branchId': effectiveBranchId,
          'branchName': effectiveBranchId,
          'newData': sanitized,
          'reason': 'HQ/Admin fee status update: ${note ?? ""}',
        }
      });

      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadFeePaymentsForMonth(String branchId, int year, int month) async {
    try {
      // The uploader writes to the normalizeBranch path; read the same one.
      final normBranch = normalizeBranch(branchId.toLowerCase().trim());
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(normBranch)
          .collection('madrassa_fee_payments')
          .where('year', isEqualTo: year)
          .where('month', isEqualTo: month)
          .get()
          .timeout(const Duration(seconds: 15));

      final box = await LocalStorageService.ensureBoxOpen(feesBox);
      final Map<String, dynamic> updates = {};
      for (final doc in snap.docs) {
        final data = doc.data();
        final sId = data['studentId']?.toString() ?? doc.id.split('_').last;
        final key = _feeKey(normBranch, year, month, sId);
        // Keep a payment taken here that the cloud doesn't have yet.
        final local = box.get(key);
        if (local is Map) {
          final localAt = _parseTimestamp(local['lastUpdatedAt']);
          final cloudAt = _parseTimestamp(data['lastUpdatedAt']);
          if (localAt != null && (cloudAt == null || localAt.isAfter(cloudAt))) continue;
        }
        updates[key] = _sanitize(data);
      }
      if (updates.isNotEmpty) {
        await box.putAll(updates);
        await box.flush();
      }
      debugPrint('[MadrassaLocalStorage] Downloaded ${snap.docs.length} fee payment records for $year-$month.');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading fee payments: $e');
    }
  }

  // ── Teachers Cache & Querying ──────────────────────────────────────────────

  static String _teacherAttendanceKey(String branchId, String dateKey) =>
      '${branchId.toLowerCase().trim()}__madrassa_tchlog__$dateKey';

  /// Whether a teacher should appear in attendance (the Directory still lists
  /// inactive teachers so they can be reactivated). The Edit Teacher dialog marks
  /// inactive as isActive=false / status|accountStatus='inactive'.
  static bool isTeacherActive(Map<String, dynamic> t) {
    if (t['isActive'] == false) return false;
    const inactive = {'inactive', 'offboarded', 'left', 'deleted', 'resigned', 'terminated'};
    final status = (t['status'] ?? '').toString().toLowerCase().trim();
    final account = (t['accountStatus'] ?? '').toString().toLowerCase().trim();
    return !inactive.contains(status) && !inactive.contains(account);
  }

  static List<Map<String, dynamic>> getAllTeachersCached(String branchId) {
    if (!Hive.isBoxOpen(LocalStorageService.usersBox)) return const [];
    final rawBranch = branchId.toLowerCase().trim();
    final cleanBranch = normalizeBranch(rawBranch);
    final isGlobal = cleanBranch == 'all' || cleanBranch == 'global' || rawBranch.isEmpty || rawBranch == 'all' || rawBranch == 'main' || rawBranch == 'global';
    final box = Hive.box(LocalStorageService.usersBox);

    final List<Map<String, dynamic>> teachers = [];
    final Map<String, int> uidToIndex = {};
    final Map<String, int> emailToIndex = {};
    final Map<String, int> usernameToIndex = {};

    for (final k in box.keys) {
      final raw = box.get(k);
      if (raw == null || raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final role = (m['role'] ?? '').toString().toLowerCase();
      final isTeacher = role.contains('teacher') || role == 'qari' || role == 'nazim';
      if (!isTeacher) continue;

      final uBranch = (m['branchId'] ?? '').toString().toLowerCase().trim();
      final isMatchBranch = isGlobal || uBranch.isEmpty || uBranch == cleanBranch ||
          ((uBranch.contains('karachi') || uBranch.contains('saddar') || uBranch.contains('haji')) &&
              (cleanBranch.contains('karachi') || cleanBranch.contains('saddar') || cleanBranch.contains('haji')));

      final isOffboarded = m['status']?.toString().toLowerCase() == 'offboarded' ||
          m['status']?.toString().toLowerCase() == 'deleted' ||
          m['isDeleted'] == true;

      if (isMatchBranch && !isOffboarded) {
        final uid = (m['uid'] ?? m['id'] ?? '').toString().trim();
        final email = (m['email'] ?? '').toString().trim().toLowerCase();
        final username = (m['username'] ?? m['usernameLower'] ?? '').toString().trim().toLowerCase();

        int? existingIndex;
        if (uid.isNotEmpty && uid != 'null' && uidToIndex.containsKey(uid)) {
          existingIndex = uidToIndex[uid];
        } else if (email.isNotEmpty && email != 'null' && emailToIndex.containsKey(email)) {
          existingIndex = emailToIndex[email];
        } else if (username.isNotEmpty && username != 'null' && usernameToIndex.containsKey(username)) {
          existingIndex = usernameToIndex[username];
        }

        m['id'] = uid.isNotEmpty && uid != 'null' ? uid : (m['id'] ?? k.toString().replaceAll('user:', ''));
        m['uid'] = uid.isNotEmpty && uid != 'null' ? uid : m['id'];

        if (existingIndex != null) {
          final existing = teachers[existingIndex];
          final merged = <String, dynamic>{...existing};
          m.forEach((key, val) {
            if (val != null && val.toString().trim().isNotEmpty && val != 'null') {
              merged[key] = val;
            }
          });
          teachers[existingIndex] = merged;

          final finalUid = (merged['uid'] ?? merged['id'] ?? '').toString().trim();
          final finalEmail = (merged['email'] ?? '').toString().trim().toLowerCase();
          final finalUsername = (merged['username'] ?? merged['usernameLower'] ?? '').toString().trim().toLowerCase();

          if (finalUid.isNotEmpty && finalUid != 'null') uidToIndex[finalUid] = existingIndex;
          if (finalEmail.isNotEmpty && finalEmail != 'null') emailToIndex[finalEmail] = existingIndex;
          if (finalUsername.isNotEmpty && finalUsername != 'null') usernameToIndex[finalUsername] = existingIndex;
        } else {
          final idx = teachers.length;
          teachers.add(m);
          if (uid.isNotEmpty && uid != 'null') uidToIndex[uid] = idx;
          if (email.isNotEmpty && email != 'null') emailToIndex[email] = idx;
          if (username.isNotEmpty && username != 'null') usernameToIndex[username] = idx;
        }
      }
    }

    teachers.sort((a, b) {
      final nameA = (a['displayName'] ?? a['username'] ?? a['name'] ?? '').toString().toLowerCase();
      final nameB = (b['displayName'] ?? b['username'] ?? b['name'] ?? '').toString().toLowerCase();
      return nameA.compareTo(nameB);
    });

    return teachers;
  }

  static Stream<List<Map<String, dynamic>>> streamTeachersCached(String branchId) {
    Stream<List<Map<String, dynamic>>> source() async* {
      await LocalStorageService.ensureBoxOpen(LocalStorageService.usersBox);
      yield getAllTeachersCached(branchId);
      final box = Hive.box(LocalStorageService.usersBox);
      await for (final _ in box.watch()) {
        yield getAllTeachersCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static Future<void> downloadTeachers(String branchId, {bool force = false}) async {
    try {
      final cleanBranch = branchId.toLowerCase().trim();
      final box = await LocalStorageService.ensureBoxOpen(LocalStorageService.usersBox);
      final isGlobal = cleanBranch.isEmpty ||
          cleanBranch == 'all' ||
          cleanBranch == 'main' ||
          cleanBranch == 'global' ||
          cleanBranch == 'headquarters' ||
          cleanBranch == 'hq';

      final Map<String, dynamic> updates = {};

      if (isGlobal) {
        try {
          // Only teacher roles: this downloaded EVERY user (1,000+ with profile photos, ~5 MB)
          // on each open of the teachers screen — about 1,000 reads and a UI freeze while the
          // whole collection was decoded — just to keep the teachers.
          final rootSnap = await FirebaseFirestore.instance
              .collection('users')
              .where('role', whereIn: const [
                'teacher', 'Teacher', 'TEACHER',
                'qari', 'Qari', 'QARI',
                'nazim', 'Nazim', 'NAZIM',
                'madrassa_teacher', 'school_teacher', 'head_teacher',
              ])
              .get();
          for (final doc in rootSnap.docs) {
            final data = doc.data();
            final role = (data['role'] ?? '').toString().toLowerCase();
            if (role.contains('teacher') || role == 'qari' || role == 'nazim') {
              final u = {'id': doc.id, 'uid': doc.id, ...data};
              final email = (u['email'] ?? '').toString().toLowerCase().trim();
              final cacheKey = email.isNotEmpty ? 'user:$email' : 'user:${doc.id}';
              updates[cacheKey] = _sanitize(u);
            }
          }
        } catch (e) {
          debugPrint('[MadrassaLocalStorage] Error downloading global teachers: $e');
        }
      } else {
        // 1. Fetch from branch users subcollection
        try {
          final branchSnap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(cleanBranch)
              .collection('users')
              .get();

          for (final doc in branchSnap.docs) {
            final data = doc.data();
            final role = (data['role'] ?? '').toString().toLowerCase();
            if (role.contains('teacher') || role == 'qari' || role == 'nazim') {
              final u = {'id': doc.id, 'uid': doc.id, ...data};
              final email = (u['email'] ?? '').toString().toLowerCase().trim();
              final cacheKey = email.isNotEmpty ? 'user:$email' : 'user:${doc.id}';
              updates[cacheKey] = _sanitize(u);
            }
          }
        } catch (_) {}

        // 2. Fetch from root users collection matching branch
        try {
          final rootSnap = await FirebaseFirestore.instance
              .collection('users')
              .where('branchId', isEqualTo: cleanBranch)
              .get();

          for (final doc in rootSnap.docs) {
            final data = doc.data();
            final role = (data['role'] ?? '').toString().toLowerCase();
            if (role.contains('teacher') || role == 'qari' || role == 'nazim') {
              final u = {'id': doc.id, 'uid': doc.id, ...data};
              final email = (u['email'] ?? '').toString().toLowerCase().trim();
              final cacheKey = email.isNotEmpty ? 'user:$email' : 'user:${doc.id}';
              updates[cacheKey] = _sanitize(u);
            }
          }
        } catch (_) {}
      }

      if (updates.isNotEmpty) {
        await box.putAll(updates);
        await box.flush();
      }
      debugPrint('[MadrassaLocalStorage] Downloaded ${updates.length} teachers for $cleanBranch');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading teachers: $e');
    }
  }

  static Future<void> saveTeacherProfileLocalAndSync({
    required String branchId,
    required String teacherId,
    required Map<String, dynamic> teacherData,
  }) async {
    final cleanBranch = branchId.toLowerCase().trim();
    final cleanData = Map<String, dynamic>.from(teacherData);
    cleanData['uid'] = cleanData['uid'] ?? teacherId;
    cleanData['id'] = cleanData['id'] ?? teacherId;
    cleanData['branchId'] = cleanBranch;
    cleanData['lastUpdatedAt'] = DateTime.now().toIso8601String();
    cleanData['syncStatus'] = 'pending';

    final email = (cleanData['email'] ?? '').toString().toLowerCase().trim();
    final cacheKey = email.isNotEmpty ? 'user:$email' : 'user:$teacherId';

    // 1. Immediately cache in Hive
    final box = await LocalStorageService.ensureBoxOpen(LocalStorageService.usersBox);
    final rawExisting = box.get(cacheKey);
    final merged = <String, dynamic>{
      if (rawExisting is Map) ...Map<String, dynamic>.from(rawExisting),
      ...cleanData,
    };
    await box.put(cacheKey, _sanitize(merged));
    await box.flush();

    // 2. Broadcast LAN
    try {
      final payload = RealtimeEvents.payload(
        type: 'save_user',
        data: merged,
        branchId: cleanBranch,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 3. Enqueue sync
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_user',
        'branchId': cleanBranch,
        'uid': teacherId,
        'data': merged,
      });

      // Uploaded by the queued item above. The direct write that was here was a second
      // write of the same document, left in the SDK's hidden queue whenever Firestore
      // did not answer (and sent again later, costing quota twice).

      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  // ── Teacher Attendance Methods ─────────────────────────────────────────────

  static Map<String, dynamic>? getTeacherAttendanceCached(String branchId, String dateKey) {
    if (!Hive.isBoxOpen(logsBox)) return null;
    final key = _teacherAttendanceKey(branchId, dateKey);
    final box = _getLogsBox();
    final raw = box.get(key);
    if (raw == null || raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  static Stream<Map<String, dynamic>?> streamTeacherAttendanceCached(String branchId, String dateKey) {
    Stream<Map<String, dynamic>?> source() async* {
      await LocalStorageService.ensureBoxOpen(logsBox);
      yield getTeacherAttendanceCached(branchId, dateKey);
      final box = _getLogsBox();
      final targetKey = _teacherAttendanceKey(branchId, dateKey);
      await for (final event in box.watch(key: targetKey)) {
        if (event.value == null || event.value is! Map) {
          yield null;
        } else {
          yield Map<String, dynamic>.from(event.value as Map);
        }
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  /// Teacher attendance received from a LAN peer. Merged per teacher, so a
  /// peer's save doesn't wipe entries only this PC has; marked synced (the
  /// sender uploads it) unless this PC has its own unsent changes for the day.
  static Future<void> cacheTeacherAttendance(String branchId, String dateKey, Map<String, dynamic> data) async {
    final cleanBranch = branchId.toLowerCase().trim();
    final key = _teacherAttendanceKey(cleanBranch, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(logsBox);
    final local = box.get(key);
    final localMap = local is Map ? Map<String, dynamic>.from(local) : <String, dynamic>{};
    final localPending = localMap['syncStatus'] == 'pending';
    final entries = <String, dynamic>{
      if (localMap['entries'] is Map) ...Map<String, dynamic>.from(localMap['entries'] as Map),
    };
    if (data['entries'] is Map) {
      (data['entries'] as Map).forEach((id, incoming) {
        final mine = entries[id.toString()];
        // A default 'present' from a PC that never saw this teacher's real status
        // must not replace it.
        final incomingIsAuto = incoming is Map && incoming['autoPresent'] == true;
        final mineIsReal = mine is Map && mine['autoPresent'] != true;
        if (incomingIsAuto && mineIsReal) return;
        entries[id.toString()] = incoming;
      });
    }
    await box.put(key, _sanitize({
      ...localMap,
      ...data,
      'entries': entries,
      'syncStatus': localPending ? 'pending' : 'synced',
    }));
    await box.flush();
  }

  /// Holiday saved (or, with [data] null, deleted) on a LAN peer.
  static Future<void> cacheHoliday(String branchId, String id, Map<String, dynamic>? data) async {
    final key = _holidayKey(branchId.toLowerCase().trim(), id);
    final box = await LocalStorageService.ensureBoxOpen(holidaysBox);
    if (data == null) {
      await box.delete(key);
    } else {
      await box.put(key, _sanitize(data));
    }
    await box.flush();
  }

  static Future<void> saveTeacherAttendanceLocalAndSync({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> entries,
    required String editorName,
  }) async {
    final cleanBranch = branchId.toLowerCase().trim();
    final nowIso = DateTime.now().toIso8601String();
    final key = _teacherAttendanceKey(cleanBranch, dateKey);

    final logData = {
      'date': dateKey,
      'dateKey': dateKey,
      'branchId': cleanBranch,
      'lastUpdated': nowIso,
      'lastModified': nowIso,
      'updatedBy': editorName,
      'syncStatus': 'pending',
      'entries': _sanitize(entries),
    };

    // 1. Immediately cache in Hive
    final box = await LocalStorageService.ensureBoxOpen(logsBox);
    await box.put(key, _sanitize(logData));
    await box.flush();

    // 2. Broadcast LAN
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaTeacherAttendance,
        data: logData,
        branchId: cleanBranch,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 3. Enqueue sync
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_teacher_attendance',
        'branchId': cleanBranch,
        'dateKey': dateKey,
        'data': logData,
      });

      // Uploaded by the queued item above. The direct write that was here was a second
      // write of the same document, left in the SDK's hidden queue whenever Firestore
      // did not answer (and sent again later, costing quota twice).

      unawaited(SyncService().triggerUpload(urgent: true));
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadTeacherAttendance(String branchId, String dateKey) async {
    try {
      final cleanBranch = branchId.toLowerCase().trim();
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(cleanBranch)
          .collection('madrassa_teacher_attendance')
          .doc(dateKey)
          .get();

      if (doc.exists && doc.data() != null) {
        final box = await LocalStorageService.ensureBoxOpen(logsBox);
        final key = _teacherAttendanceKey(cleanBranch, dateKey);
        await box.put(key, _sanitize(doc.data()!));
        await box.flush();
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading teacher attendance: $e');
    }
  }

  static Future<Map<String, Map<String, dynamic>>> getMonthlyTeacherAttendance({
    required String branchId,
    required int year,
    required int month,
  }) async {
    final cleanBranch = branchId.toLowerCase().trim();
    final box = await LocalStorageService.ensureBoxOpen(logsBox);
    final monthPrefix = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
    final result = <String, Map<String, dynamic>>{};

    // 1. Collect all matching cached keys in Hive
    final prefix = '${cleanBranch}__madrassa_tchlog__$monthPrefix';
    for (final key in box.keys) {
      if (key is String && key.startsWith(prefix)) {
        final dateKey = key.substring('${cleanBranch}__madrassa_tchlog__'.length);
        final raw = box.get(key);
        if (raw is Map) {
          result[dateKey] = Map<String, dynamic>.from(raw);
        }
      }
    }

    // 2. Fetch from Firestore for the whole month if online
    try {
      final startKey = '$monthPrefix-01';
      final lastDay = DateTime(year, month + 1, 0).day;
      final endKey = '$monthPrefix-${lastDay.toString().padLeft(2, '0')}';

      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(cleanBranch)
          .collection('madrassa_teacher_attendance')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: startKey)
          .where(FieldPath.documentId, isLessThanOrEqualTo: endKey)
          .get();

      for (final doc in snap.docs) {
        final dKey = doc.id;
        final data = doc.data();
        result[dKey] = data;
        final key = _teacherAttendanceKey(cleanBranch, dKey);
        await box.put(key, _sanitize(data));
      }
      if (snap.docs.isNotEmpty) {
        await box.flush();
      }
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] getMonthlyTeacherAttendance error: $e');
    }

    return result;
  }

  /// Downloads all related Madrassa data for the specified branch (students, teachers,
  /// attendance, logs, fees, holidays, config) into local storage.
  static Future<void> downloadAllMadrassaData(String branchId, {bool force = false}) async {
    final cleanBranch = normalizeBranch(branchId);
    if (cleanBranch.isEmpty || cleanBranch == 'unknown') return;

    if (cleanBranch == 'all' || cleanBranch == 'global') {
      final branches = _getAllBranchIds();
      await Future.wait(branches.map((b) => downloadAllMadrassaData(b, force: force)));
      return;
    }

    try {
      final now = DateTime.now();
      final todayKey = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      await Future.wait([
        downloadStudents(cleanBranch, force: force),
        downloadTeachers(cleanBranch, force: force),
        downloadHolidays(cleanBranch),
        downloadConfig(cleanBranch),
        downloadLogsForMonth(cleanBranch, now.year, now.month),
        downloadFeePaymentsForMonth(cleanBranch, now.year, now.month),
        downloadTeacherAttendance(cleanBranch, todayKey),
      ]);

      // If early in the month (first 10 days), also ensure previous month's logs are available
      if (now.day <= 10) {
        final prevMonth = now.month == 1 ? 12 : now.month - 1;
        final prevYear = now.month == 1 ? now.year - 1 : now.year;
        await Future.wait([
          downloadLogsForMonth(cleanBranch, prevYear, prevMonth),
          downloadFeePaymentsForMonth(cleanBranch, prevYear, prevMonth),
        ]);
      }
      debugPrint('[MadrassaLocalStorage] All Madrassa data downloaded successfully for $cleanBranch');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error in downloadAllMadrassaData for $cleanBranch: $e');
    }
  }
}