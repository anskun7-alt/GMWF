import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import '../../../services/zkteco_network_service.dart';
import '../../../services/network_health_service.dart';
import '../models/madrassa_config.dart';

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

  // ── Cache keys ─────────────────────────────────────────────────────────────

  static String _studentKey(String branchId, String studentId) =>
      '${branchId.toLowerCase().trim()}__std__$studentId';

  static String _logKey(String branchId, String dateKey) =>
      '${branchId.toLowerCase().trim()}__log__$dateKey';

  static String _holidayKey(String branchId, String dateKey) =>
      '${branchId.toLowerCase().trim()}__hol__$dateKey';

  static String _feeKey(String branchId, int year, int month, String studentId) =>
      '${branchId.toLowerCase().trim()}__fee__${year}_${month}__$studentId';

  // ── Students Cache ─────────────────────────────────────────────────────────

  static Future<void> cacheStudent(String branchId, String studentId, Map<String, dynamic> data) async {
    final key = _studentKey(branchId, studentId);
    final box = await LocalStorageService.ensureBoxOpen(studentsBox);
    final rawExisting = box.get(key);
    final merged = <String, dynamic>{
      if (rawExisting is Map) ...Map<String, dynamic>.from(rawExisting),
      ...data,
    };
    await box.put(key, _sanitize(merged));
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
    final effectiveStudentId = studentId.isNotEmpty 
        ? studentId 
        : 'madrassa_std_${DateTime.now().millisecondsSinceEpoch}';
    final effectiveBranchId = branchId.toLowerCase().trim();

    final cleanData = Map<String, dynamic>.from(data);
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

    // 4. Always enqueue into LocalStorageService.syncBox for durable background Firestore upload
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_student',
        'branchId': effectiveBranchId,
        'studentId': effectiveStudentId,
        'data': cleanData,
        'isNew': isNew,
      });

      // Direct cloud push fallback if online
      try {
        if (NetworkHealthService().isStableOnline) {
          unawaited(FirebaseFirestore.instance
              .collection('branches')
              .doc(effectiveBranchId)
              .collection('madrassa_students')
              .doc(effectiveStudentId)
              .set(cleanData, SetOptions(merge: true))
              .catchError((_) {}));
        }
      } catch (_) {}

      unawaited(SyncService().triggerUpload());
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
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

            final matches = (guardianCnic.isNotEmpty && uCnic == guardianCnic) ||
                (studentCnic.isNotEmpty && uCnic == studentCnic) ||
                (phone.isNotEmpty && uPhone == phone) ||
                uStudentIds.contains(studentId);

            if (matches) {
              final updatedUser = Map<String, dynamic>.from(u);
              uStudentIds.remove(studentId);
              updatedUser['studentIds'] = uStudentIds;
              if (uStudentIds.isEmpty) {
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
                    if (uStudentIds.isEmpty) ...{
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
      unawaited(SyncService().triggerUpload());
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
    final effectiveBranchId = branchId.toLowerCase().trim();
    final box = await LocalStorageService.ensureBoxOpen(studentsBox);
    final key = _studentKey(effectiveBranchId, studentId);
    await box.delete(key);
    await box.flush();

    // 1. Direct Firestore delete if online
    try {
      if (NetworkHealthService().isStableOnline) {
        unawaited(FirebaseFirestore.instance
            .collection('branches')
            .doc(effectiveBranchId)
            .collection('madrassa_students')
            .doc(studentId)
            .delete()
            .catchError((_) {}));
      }
    } catch (_) {}

    // 2. Unenroll biometric PIN from device (background)
    unawaited(
      ZkTecoNetworkService.deleteBiometricCredential(studentId, branchId: effectiveBranchId).catchError((e) {
        debugPrint('[MadrassaLocalStorage] Background deleteBiometricCredential error: $e');
      }),
    );

    // 3. Broadcast to LAN WebSocket
    try {
      final payload = RealtimeEvents.payload(
        type: 'delete_madrassa_student',
        data: {
          'branchId': effectiveBranchId,
          'studentId': studentId,
        },
        branchId: effectiveBranchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // 4. Enqueue sync for cloud deletion
    try {
      await LocalStorageService.enqueueSync({
        'type': 'permanent_delete_madrassa_student',
        'branchId': effectiveBranchId,
        'studentId': studentId,
      });
      unawaited(SyncService().triggerUpload());
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Map<String, dynamic>? getStudentCached(String branchId, String studentId) {
    if (!Hive.isBoxOpen(studentsBox)) return null;
    final key = _studentKey(branchId, studentId);
    final box = _getStudentsBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static List<Map<String, dynamic>> getAllStudentsCached(String branchId) {
    if (!Hive.isBoxOpen(studentsBox)) return const [];
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'main' || cleanBranch == 'global';
    final prefix = '${cleanBranch}__std__';
    final box = _getStudentsBox();
    final list = box.keys
        .where((k) {
          final str = k.toString();
          if (isGlobal) return str.contains('__std__') || str.startsWith('madrassa_std_');
          if (str.startsWith(prefix)) return true;
          final kBranch = str.split('__std__').first;
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
          return name.isNotEmpty && !isDeleted;
        })
        .toList();

    list.sort((a, b) {
      final rollA = int.tryParse(a['rollNumber']?.toString() ?? '');
      final rollB = int.tryParse(b['rollNumber']?.toString() ?? '');
      if (rollA != null && rollB != null) return rollA.compareTo(rollB);
      if (rollA != null) return -1;
      if (rollB != null) return 1;
      return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
    });

    return list;
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
      yield getAllStudentsCached(branchId);
      await for (final _ in box.watch()) {
        yield getAllStudentsCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  static Future<void> downloadStudents(String branchId, {bool force = false}) async {
    try {
      final normBranch = branchId.toLowerCase().trim();
      final syncKey = 'madrassa_students_$normBranch';
      final lastSyncedTs = force ? null : LocalStorageService.getLastSyncedServerTimestamp(syncKey);

      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('branches')
          .doc(normBranch)
          .collection('madrassa_students');

      if (lastSyncedTs != null) {
        final parsedDate = DateTime.tryParse(lastSyncedTs);
        if (parsedDate != null) {
          query = query.where('lastUpdatedAt', isGreaterThan: Timestamp.fromDate(parsedDate)).orderBy('lastUpdatedAt', descending: false);
        }
      }

      final snap = await query.get();
      final box = await LocalStorageService.ensureBoxOpen(studentsBox);
      String? maxServerTs = lastSyncedTs;
      final Map<String, dynamic> studentUpdates = {};

      for (final doc in snap.docs) {
        final data = doc.data();
        final key = _studentKey(normBranch, doc.id);
        studentUpdates[key] = _sanitize(data);

        final dynamic docTsRaw = data['lastUpdatedAt'] ?? data['updatedAt'];
        if (docTsRaw != null) {
          String? docTs;
          if (docTsRaw is Timestamp) {
            docTs = docTsRaw.toDate().toIso8601String();
          } else if (docTsRaw is String) {
            docTs = docTsRaw;
          }
          if (docTs != null) {
            if (maxServerTs == null || docTs.compareTo(maxServerTs) > 0) {
              maxServerTs = docTs;
            }
          }
        }
      }

      if (studentUpdates.isNotEmpty) {
        await box.putAll(studentUpdates);
      }
      if (maxServerTs != null) {
        await LocalStorageService.setLastSyncedServerTimestamp(syncKey, maxServerTs);
      }
      await box.flush();
      debugPrint('[MadrassaLocalStorage] Downloaded ${snap.docs.length} madrassa students (Delta)');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading students: $e');
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
      final Map<String, dynamic> updates = {};
      for (final id in studentIds) {
        final doc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(branchId)
            .collection('madrassa_students')
            .doc(id)
            .get();
        if (doc.exists && doc.data() != null) {
          final key = _studentKey(branchId, doc.id);
          updates[key] = _sanitize(doc.data()!);
        }
      }
      if (updates.isNotEmpty) {
        final box = await LocalStorageService.ensureBoxOpen(studentsBox);
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
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'global' || cleanBranch == 'main';

    if (isGlobal) {
      final merged = <String, dynamic>{};
      bool foundAny = false;
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

    final key = _logKey(branchId, dateKey);
    final raw = box.get(key);
    if (raw != null && raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    // Fallback: check other matching keys for this branch and date
    for (final k in box.keys) {
      final keyStr = k.toString();
      if (keyStr.endsWith('__log__$dateKey') && keyStr.startsWith(cleanBranch)) {
        final raw = box.get(k);
        if (raw is Map) return Map<String, dynamic>.from(raw);
      }
    }
    return null;
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

  static Map<String, dynamic>? getDailyLogCached(String branchId, String dateKey) =>
      getLogCached(branchId, dateKey);

  static Future<void> cacheDailyLog(String branchId, String dateKey, Map<String, dynamic> data) async {
    final key = _logKey(branchId, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(logsBox);
    await box.put(key, _sanitize(data));
    await box.flush();
  }

  // This one watches Hive for changes. When viewing all branches, it watches the whole box.
  static Stream<Map<String, dynamic>> streamLogCached(String branchId, String dateKey) {
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'global' || cleanBranch == 'main';

    Stream<Map<String, dynamic>> source() async* {
      final box = await LocalStorageService.ensureBoxOpen(logsBox);
      yield getLogCached(branchId, dateKey) ?? {};
      if (isGlobal) {
        await for (final _ in box.watch()) {
          yield getLogCached(branchId, dateKey) ?? {};
        }
      } else {
        await for (final event in box.watch(key: _logKey(branchId, dateKey))) {
          yield (event.value != null) ? Map<String, dynamic>.from(event.value as Map) : (getLogCached(branchId, dateKey) ?? {});
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
    final key = _logKey(branchId, dateKey);
    final box = await LocalStorageService.ensureBoxOpen(logsBox);

    // Get current cache log or start empty
    final existing = getLogCached(branchId, dateKey) ?? {};
    final updated = Map<String, dynamic>.from(existing);

    // Merge changes
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
          final studentCache = getStudentCached(branchId, sId);
          if (studentCache != null) {
            studentCache['currentLines'] = data['currentLines'];
            cacheStudent(branchId, sId, studentCache);
          }
        }
      }
    });

    final sanitized = _sanitize(updated);
    await box.put(key, sanitized);
    await box.flush();

    // Broadcast LAN event (Server and peers)
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaDailyLog,
        data: {
          'branchId': branchId,
          'dateKey': dateKey,
          'logData': sanitized,
          'editorName': editorName,
          'editorRole': editorRole,
        },
        branchId: branchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] LAN broadcast error: $e');
    }

    // Always enqueue sync action for durable Firestore upload
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_log',
        'branchId': branchId,
        'dateKey': dateKey,
        'data': sanitized,
      });

      // Enqueue sync actions for changed students' currentLines
      logData.forEach((sId, data) {
        if (data is Map && data.containsKey('currentLines')) {
          LocalStorageService.enqueueSync({
            'type': 'update_madrassa_student',
            'branchId': branchId,
            'studentId': sId,
            'currentLines': data['currentLines'],
          });
        }
      });

      // Direct cloud push fallback if online
      try {
        if (NetworkHealthService().isStableOnline) {
          unawaited(FirebaseFirestore.instance
              .collection('branches')
              .doc(branchId)
              .collection('madrassa_daily_logs')
              .doc(dateKey)
              .set(sanitized, SetOptions(merge: true))
              .catchError((_) {}));
        }
      } catch (_) {}

      unawaited(SyncService().triggerUpload());
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadLogsForMonth(String branchId, int year, int month) async {
    try {
      final startStr = DateFormat('yyyy-MM-01').format(DateTime(year, month, 1));
      final endStr = DateFormat('yyyy-MM-dd').format(DateTime(year, month + 1, 0));

      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('madrassa_daily_logs')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: startStr)
          .where(FieldPath.documentId, isLessThanOrEqualTo: endStr)
          .get();

      final box = await LocalStorageService.ensureBoxOpen(logsBox);
      final Map<String, dynamic> logUpdates = {};
      for (final doc in snap.docs) {
        final key = _logKey(branchId, doc.id);
        
        // Merge cloud fields preserving local updates if local is newer (LWW conflict resolution)
        final existing = box.get(key) ?? logUpdates[key];
        if (existing == null) {
          logUpdates[key] = _sanitize(doc.data());
        } else {
          final exMap = Map<String, dynamic>.from(existing as Map);
          
          // Simple conflict resolution: if Firestore document has updates, we can merge them
          final Map<String, dynamic> merged = {...exMap, ...doc.data()};
          logUpdates[key] = _sanitize(merged);
        }
      }
      if (logUpdates.isNotEmpty) {
        await box.putAll(logUpdates);
      }
      await box.flush();
      debugPrint('[MadrassaLocalStorage] Downloaded ${snap.docs.length} daily log documents for $year-$month.');
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] Error downloading daily logs: $e');
    }
  }

  static List<Map<String, dynamic>> getLogsForMonthCached(String branchId, int year, int month) {
    if (!Hive.isBoxOpen(logsBox)) return const [];
    final monthStr = '$year-${month.toString().padLeft(2, '0')}';
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'global' || cleanBranch == 'main';
    final box = _getLogsBox();

    if (isGlobal) {
      final mapByDate = <String, Map<String, dynamic>>{};
      for (final k in box.keys) {
        final keyStr = k.toString();
        if (keyStr.contains('__log__$monthStr-')) {
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

    final prefix = '${cleanBranch}__log__$monthStr-';
    return box.keys
        .where((k) => k.toString().startsWith(prefix))
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().split('__log__').last;
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static List<Map<String, dynamic>> getAllLogsCached(String branchId) {
    if (!Hive.isBoxOpen(logsBox)) return const [];
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'global' || cleanBranch == 'main';
    final box = _getLogsBox();

    if (isGlobal) {
      final mapByDate = <String, Map<String, dynamic>>{};
      for (final k in box.keys) {
        final keyStr = k.toString();
        if (keyStr.contains('__log__')) {
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

    final prefix = '${cleanBranch}__log__';
    final list = box.keys
        .where((k) => k.toString().startsWith(prefix))
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().split('__log__').last;
          m['dateKey'] = k.toString().split('__log__').last;
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
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
      unawaited(SyncService().triggerUpload());
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
      unawaited(SyncService().triggerUpload());
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
    required String status, // 'paid' or 'unpaid'
    required String markedBy,
    required String markedByRole,
    String? note,
  }) async {
    final effectiveBranchId = branchId.toLowerCase().trim();
    final docId = '${year}_${month}_$studentId';
    final key = _feeKey(effectiveBranchId, year, month, studentId);
    final box = await LocalStorageService.ensureBoxOpen(feesBox);
    final now = DateTime.now();

    final existing = box.get(key);
    final currentRecord = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};

    final auditList = List<Map<String, dynamic>>.from(
      (currentRecord['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );
    auditList.add({
      'status': status,
      'by': markedBy,
      'role': markedByRole,
      'timestamp': now.toIso8601String(),
      'note': note ?? '',
      'amountPaid': amountPaid,
      'amountDue': amountDue,
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
      'amountPaid': amountPaid,
      'status': status,
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

      unawaited(SyncService().triggerUpload());
    } catch (e) {
      debugPrint('[MadrassaLocalStorage] enqueueSync error: $e');
    }
  }

  static Future<void> downloadFeePaymentsForMonth(String branchId, int year, int month) async {
    try {
      final normBranch = branchId.toLowerCase().trim();
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(normBranch)
          .collection('madrassa_fee_payments')
          .where('year', isEqualTo: year)
          .where('month', isEqualTo: month)
          .get();

      final box = await LocalStorageService.ensureBoxOpen(feesBox);
      final Map<String, dynamic> updates = {};
      for (final doc in snap.docs) {
        final data = doc.data();
        final sId = data['studentId']?.toString() ?? doc.id.split('_').last;
        final key = _feeKey(normBranch, year, month, sId);
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

  static List<Map<String, dynamic>> getAllTeachersCached(String branchId) {
    if (!Hive.isBoxOpen(LocalStorageService.usersBox)) return const [];
    final cleanBranch = branchId.toLowerCase().trim();
    final isGlobal = cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'main' || cleanBranch == 'global';
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
          final rootSnap = await FirebaseFirestore.instance.collection('users').get();
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

      // Direct push if online
      try {
        if (NetworkHealthService().isStableOnline) {
          unawaited(FirebaseFirestore.instance
              .collection('users')
              .doc(teacherId)
              .set(merged, SetOptions(merge: true))
              .catchError((_) {}));
          unawaited(FirebaseFirestore.instance
              .collection('branches')
              .doc(cleanBranch)
              .collection('users')
              .doc(teacherId)
              .set(merged, SetOptions(merge: true))
              .catchError((_) {}));
        }
      } catch (_) {}

      unawaited(SyncService().triggerUpload());
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

      // Direct push if online
      try {
        if (NetworkHealthService().isStableOnline) {
          unawaited(FirebaseFirestore.instance
              .collection('branches')
              .doc(cleanBranch)
              .collection('madrassa_teacher_attendance')
              .doc(dateKey)
              .set(logData, SetOptions(merge: true))
              .catchError((_) {}));
        }
      } catch (_) {}

      unawaited(SyncService().triggerUpload());
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
    final cleanBranch = branchId.toLowerCase().trim();
    if (cleanBranch.isEmpty || cleanBranch == 'all' || cleanBranch == 'unknown') return;

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