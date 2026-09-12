// lib/pages/school/utils/school_local_storage.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:collection/collection.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';

class SchoolLocalStorage {
  static const String studentsBox  = LocalStorageService.schoolStudentsBox;
  static const String logsBox      = LocalStorageService.schoolLogsBox;
  static const String teachersBox  = LocalStorageService.schoolTeachersBox;
  static const String booksBox     = LocalStorageService.schoolBooksBox;
  static const String bookLoansBox = LocalStorageService.schoolBookLoansBox;
  static const String auditBox     = LocalStorageService.schoolAuditLogsBox;
  static const String gradesBox    = LocalStorageService.schoolGradesBox;
  static const String feesBox      = LocalStorageService.schoolFeesBox;
  static const String homeroomBox  = LocalStorageService.schoolHomeroomBox;

  static Future<void> ensureBoxesOpen() async {
    final boxes = [
      studentsBox,
      logsBox,
      teachersBox,
      booksBox,
      bookLoansBox,
      auditBox,
      gradesBox,
      feesBox,
      homeroomBox,
      LocalStorageService.syncMetaBox,
    ];
    for (final name in boxes) {
      if (!Hive.isBoxOpen(name)) {
        await LocalStorageService.openBoxSafe(name);
      }
    }
  }

  static Box _getStudentsBox()  => Hive.box(studentsBox);
  static Box _getLogsBox()      => Hive.box(logsBox);
  static Box _getTeachersBox()  => Hive.box(teachersBox);
  static Box _getBooksBox()     => Hive.box(booksBox);
  static Box _getBookLoansBox() => Hive.box(bookLoansBox);

  static const DeepCollectionEquality _deepEq = DeepCollectionEquality();

  // ── Sync Metadata ──────────────────────────────────────────────────────────
  static String? getLastSchoolSyncTimestamp() {
    if (!Hive.isBoxOpen(LocalStorageService.syncMetaBox)) return null;
    final box = Hive.box(LocalStorageService.syncMetaBox);
    return box.get('school_last_synced_ts')?.toString();
  }

  static Future<void> setLastSchoolSyncTimestamp(String timestamp) async {
    if (!Hive.isBoxOpen(LocalStorageService.syncMetaBox)) return;
    final box = Hive.box(LocalStorageService.syncMetaBox);
    await box.put('school_last_synced_ts', timestamp);
    await box.flush();
  }

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

  static String _teacherKey(String branchId, String teacherId) =>
      '${branchId.toLowerCase().trim()}__tch__$teacherId';

  static String _logKey(String branchId, String dateKey) =>
      '${branchId.toLowerCase().trim()}__log__$dateKey';

  static String _bookKey(String branchId, String bookId) =>
      '${branchId.toLowerCase().trim()}__$bookId';

  static String _bookLoanKey(String branchId, String loanId) =>
      '${branchId.toLowerCase().trim()}__$loanId';

  // ── Students Cache ─────────────────────────────────────────────────────────
  static Future<void> cacheStudent(String branchId, String studentId, Map<String, dynamic> data) async {
    final key = _studentKey(branchId, studentId);
    final box = _getStudentsBox();
    await box.put(key, _sanitize(data));
    await box.flush();
  }

  static Map<String, dynamic>? getStudentCached(String branchId, String studentId) {
    final key = _studentKey(branchId, studentId);
    final box = _getStudentsBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static List<Map<String, dynamic>> getAllStudentsCached(String branchId) {
    final prefix = '${branchId.toLowerCase().trim()}__std__';
    final box = _getStudentsBox();
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().split('__std__').last;
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamStudentsCached(String branchId) {
    Stream<List<Map<String, dynamic>>> source() async* {
      yield getAllStudentsCached(branchId);
      await for (final _ in _getStudentsBox().watch()) {
        yield getAllStudentsCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  // ── Teachers Cache ─────────────────────────────────────────────────────────
  static Future<void> cacheTeacher(String branchId, String teacherId, Map<String, dynamic> data) async {
    final key = _teacherKey(branchId, teacherId);
    final box = _getTeachersBox();
    await box.put(key, _sanitize(data));
    await box.flush();
  }

  static Map<String, dynamic>? getTeacherCached(String branchId, String teacherId) {
    final key = _teacherKey(branchId, teacherId);
    final box = _getTeachersBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static List<Map<String, dynamic>> getAllTeachersCached(String branchId) {
    final prefix = '${branchId.toLowerCase().trim()}__tch__';
    final box = _getTeachersBox();
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          m['id'] = k.toString().split('__tch__').last;
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamTeachersCached(String branchId) {
    Stream<List<Map<String, dynamic>>> source() async* {
      yield getAllTeachersCached(branchId);
      await for (final _ in _getTeachersBox().watch()) {
        yield getAllTeachersCached(branchId);
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  // ── Books & Book Loans Cache ────────────────────────────────────────────────
  static Future<void> cacheBook(String branchId, String bookId, Map<String, dynamic> data) async {
    final key = _bookKey(branchId, bookId);
    final box = _getBooksBox();
    await box.put(key, _sanitize(data));
    await box.flush();
  }

  static Map<String, dynamic>? getBookCached(String branchId, String bookId) {
    final key = _bookKey(branchId, bookId);
    final box = _getBooksBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static List<Map<String, dynamic>> getAllBooksCached(String branchId) {
    final prefix = '${branchId.toLowerCase().trim()}__';
    final box = _getBooksBox();
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          final m = Map<String, dynamic>.from(raw as Map);
          return m;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamBooksCached(String branchId) async* {
    yield getAllBooksCached(branchId);
    yield* _getBooksBox().watch().map((_) => getAllBooksCached(branchId));
  }

  static Future<void> cacheBookLoan(String branchId, String loanId, Map<String, dynamic> data) async {
    final key = _bookLoanKey(branchId, loanId);
    final box = _getBookLoansBox();
    await box.put(key, _sanitize(data));
    await box.flush();
  }

  static List<Map<String, dynamic>> getAllBookLoansCached(String branchId) {
    final prefix = '${branchId.toLowerCase().trim()}__';
    final box = _getBookLoansBox();
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) {
          final raw = box.get(k);
          if (raw == null) return null;
          return Map<String, dynamic>.from(raw as Map);
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamBookLoansCached(String branchId) async* {
    yield getAllBookLoansCached(branchId);
    yield* _getBookLoansBox().watch().map((_) => getAllBookLoansCached(branchId));
  }

  // ── Attendance Logs Cache ──────────────────────────────────────────────────
  static Future<void> cacheLog(String branchId, String dateKey, Map<String, dynamic> logData) async {
    final key = _logKey(branchId, dateKey);
    final box = _getLogsBox();
    await box.put(key, _sanitize(logData));
    await box.flush();
  }

  static Map<String, dynamic>? getLogCached(String branchId, String dateKey) {
    final key = _logKey(branchId, dateKey);
    final box = _getLogsBox();
    final raw = box.get(key);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  static Stream<Map<String, dynamic>?> streamLogCached(String branchId, String dateKey) {
    final targetKey = _logKey(branchId, dateKey);
    Stream<Map<String, dynamic>?> source() async* {
      yield getLogCached(branchId, dateKey);
      await for (final event in _getLogsBox().watch()) {
        if (event.key == targetKey) {
          yield getLogCached(branchId, dateKey);
        }
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  // ── Save Student Offline/Firestore ──────────────────────────────────────────
  static Future<void> saveStudent({
    required String branchId,
    required String studentId,
    required Map<String, dynamic> studentData,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    studentData['lastModified'] = studentData['lastModified'] ?? nowIso;
    studentData['syncStatus'] = 'pending';

    final cleanData = _sanitize(studentData);
    await cacheStudent(branchId, studentId, cleanData);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_students')
          .doc(studentId);
      await docRef.set(cleanData, SetOptions(merge: true));

      // Mark synced on cloud success
      cleanData['syncStatus'] = 'synced';
      cleanData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await cacheStudent(branchId, studentId, cleanData);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Cloud save failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_students',
        'docId': studentId,
        'data': cleanData,
      });
      SyncService().triggerUpload();
    }
  }

  // ── Save Teacher Offline/Firestore ──────────────────────────────────────────
  static Future<void> saveTeacher({
    required String branchId,
    required String teacherId,
    required Map<String, dynamic> teacherData,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    teacherData['lastModified'] = teacherData['lastModified'] ?? nowIso;
    teacherData['syncStatus'] = 'pending';

    final cleanData = _sanitize(teacherData);
    await cacheTeacher(branchId, teacherId, cleanData);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_teachers')
          .doc(teacherId);
      await docRef.set(cleanData, SetOptions(merge: true));

      cleanData['syncStatus'] = 'synced';
      cleanData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await cacheTeacher(branchId, teacherId, cleanData);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Cloud teacher save failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_teachers',
        'docId': teacherId,
        'data': cleanData,
      });
      SyncService().triggerUpload();
    }
  }

  // ── Save Book Offline/Firestore ─────────────────────────────────────────────
  static Future<void> saveBook({
    required String branchId,
    required String bookId,
    required Map<String, dynamic> bookData,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    bookData['lastModified'] = bookData['lastModified'] ?? nowIso;
    bookData['syncStatus'] = 'pending';

    final cleanData = _sanitize(bookData);
    await cacheBook(branchId, bookId, cleanData);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_books')
          .doc(bookId);
      await docRef.set(cleanData, SetOptions(merge: true));

      cleanData['syncStatus'] = 'synced';
      cleanData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await cacheBook(branchId, bookId, cleanData);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Cloud book save failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_books',
        'docId': bookId,
        'data': cleanData,
      });
      SyncService().triggerUpload();
    }
  }

  // ── Save Book Loan Offline/Firestore ────────────────────────────────────────
  static Future<void> saveBookLoan({
    required String branchId,
    required String loanId,
    required Map<String, dynamic> loanData,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    loanData['lastModified'] = loanData['lastModified'] ?? nowIso;
    loanData['syncStatus'] = 'pending';

    final cleanData = _sanitize(loanData);
    await cacheBookLoan(branchId, loanId, cleanData);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_book_loans')
          .doc(loanId);
      await docRef.set(cleanData, SetOptions(merge: true));

      cleanData['syncStatus'] = 'synced';
      cleanData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await cacheBookLoan(branchId, loanId, cleanData);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Cloud book loan save failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_book_loans',
        'docId': loanId,
        'data': cleanData,
      });
      SyncService().triggerUpload();
    }
  }

  // ── Save Daily Attendance Log ──────────────────────────────────────────────
  static Future<void> saveDailyLog({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> logEntries,
    required String editorName,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final logData = {
      'date': dateKey,
      'lastUpdated': nowIso,
      'lastModified': nowIso,
      'syncStatus': 'pending',
      'updatedBy': editorName,
      'entries': _sanitize(logEntries),
    };

    await cacheLog(branchId, dateKey, logData);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_attendance')
          .doc(dateKey);
      await docRef.set(logData, SetOptions(merge: true));

      logData['syncStatus'] = 'synced';
      logData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await cacheLog(branchId, dateKey, logData);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Save attendance log failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_attendance',
        'docId': dateKey,
        'data': logData,
      });
      SyncService().triggerUpload();
    }

    await logAudit(
      branchId: branchId,
      action: 'UPDATE_ATTENDANCE_LOG',
      user: editorName,
      details: 'Updated student daily log for date: $dateKey',
    );
  }

  // ── Save Teacher Daily Attendance Log ─────────────────────────────────────
  static Future<void> saveTeacherDailyLog({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> logEntries,
    required String editorName,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final logData = {
      'date': dateKey,
      'lastUpdated': nowIso,
      'lastModified': nowIso,
      'syncStatus': 'pending',
      'updatedBy': editorName,
      'entries': _sanitize(logEntries),
    };

    final key = '${branchId.toLowerCase().trim()}__tchlog__$dateKey';
    final box = Hive.box(LocalStorageService.schoolLogsBox);
    await box.put(key, _sanitize(logData));
    await box.flush();

    try {
      final docRef = FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_teacher_attendance')
          .doc(dateKey);
      await docRef.set(logData, SetOptions(merge: true));

      logData['syncStatus'] = 'synced';
      logData['lastSyncedAt'] = DateTime.now().toIso8601String();
      await box.put(key, _sanitize(logData));
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Save teacher attendance log failed: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_teacher_attendance',
        'docId': dateKey,
        'data': logData,
      });
      SyncService().triggerUpload();
    }

    await logAudit(
      branchId: branchId,
      action: 'UPDATE_TEACHER_ATTENDANCE',
      user: editorName,
      details: 'Updated teacher attendance log for date: $dateKey',
    );
  }

  static int getPresentStudentsCount(String branchId, String dateKey) {
    final log = getLogCached(branchId, dateKey);
    if (log == null) return 0;
    final entries = (log['entries'] as Map?) ?? {};
    int count = 0;
    entries.forEach((k, v) {
      if (v is Map && (v['status'] ?? '').toString().toLowerCase() == 'present') {
        count++;
      }
    });
    return count;
  }

  static int getPresentTeachersCount(String branchId, String dateKey) {
    final key = '${branchId.toLowerCase().trim()}__tchlog__$dateKey';
    final box = Hive.box(LocalStorageService.schoolLogsBox);
    final raw = box.get(key);
    if (raw == null) return 0;
    final log = Map<String, dynamic>.from(raw as Map);
    final entries = (log['entries'] as Map?) ?? {};
    int count = 0;
    entries.forEach((k, v) {
      if (v is Map && (v['status'] ?? '').toString().toLowerCase() == 'present') {
        count++;
      }
    });
    return count;
  }

  static Stream<Map<String, dynamic>?> streamTeacherLogCached(String branchId, String dateKey) {
    final targetKey = '${branchId.toLowerCase().trim()}__tchlog__$dateKey';
    final box = Hive.box(LocalStorageService.schoolLogsBox);
    Stream<Map<String, dynamic>?> source() async* {
      final raw = box.get(targetKey);
      yield raw != null ? Map<String, dynamic>.from(raw as Map) : null;
      await for (final event in box.watch()) {
        if (event.key == targetKey) {
          final r = box.get(targetKey);
          yield r != null ? Map<String, dynamic>.from(r as Map) : null;
        }
      }
    }
    return source().distinct((a, b) => _deepEq.equals(a, b));
  }

  // ── Audit Logging ─────────────────────────────────────────────────────────
  static Future<void> logAudit({
    required String branchId,
    required String action,
    required String user,
    required String details,
  }) async {
    final auditId = 'AUD-${DateTime.now().millisecondsSinceEpoch}';
    final entry = {
      'id': auditId,
      'action': action,
      'user': user,
      'details': details,
      'timestamp': DateTime.now().toIso8601String(),
      'branchId': branchId,
    };

    final box = Hive.box(LocalStorageService.schoolAuditLogsBox);
    final key = '${branchId.toLowerCase()}__$auditId';
    await box.put(key, entry);

    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_audit_logs')
          .doc(auditId)
          .set(entry);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Cloud audit log save failed: $e');
    }
  }

  static List<Map<String, dynamic>> getAuditLogsCached(String branchId) {
    final prefix = '${branchId.toLowerCase()}__';
    final box = Hive.box(LocalStorageService.schoolAuditLogsBox);
    final list = box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .toList();

    list.sort((a, b) => (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));
    return list;
  }

  // ── Grades Storage & Caching ──────────────────────────────────────────────
  static Future<void> saveGrade({
    required String branchId,
    required String gradeId,
    required Map<String, dynamic> gradeData,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final dataToSave = Map<String, dynamic>.from(gradeData);
    dataToSave['syncStatus'] = 'pending';
    dataToSave['lastModified'] = nowIso;
    dataToSave['branchId'] = branchId;

    final box = Hive.box(gradesBox);
    final key = '${branchId.toLowerCase()}__$gradeId';
    await box.put(key, dataToSave);

    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_grades')
          .doc(gradeId)
          .set(dataToSave, SetOptions(merge: true));

      dataToSave['syncStatus'] = 'synced';
      dataToSave['lastSyncedAt'] = DateTime.now().toIso8601String();
      await box.put(key, dataToSave);
    } catch (e) {
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_grades',
        'docId': gradeId,
        'data': dataToSave,
      });
      SyncService().triggerUpload();
    }
  }

  static List<Map<String, dynamic>> getAllGradesCached(String branchId) {
    final prefix = '${branchId.toLowerCase()}__';
    final box = Hive.box(gradesBox);
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamGradesCached(String branchId) async* {
    yield getAllGradesCached(branchId);
    final box = Hive.box(gradesBox);
    yield* box.watch().map((_) => getAllGradesCached(branchId));
  }

  // ── Fee Records Storage & Caching ──────────────────────────────────────────
  static Future<void> saveFeeRecord({
    required String branchId,
    required String feeId,
    required Map<String, dynamic> feeData,
    required String editorName,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final dataToSave = Map<String, dynamic>.from(feeData);
    dataToSave['lastModified'] = nowIso;
    dataToSave['syncStatus'] = 'pending';
    dataToSave['branchId'] = branchId;

    final box = Hive.isBoxOpen(feesBox) ? Hive.box(feesBox) : await LocalStorageService.openBoxSafe(feesBox);
    final key = '${branchId.toLowerCase()}__$feeId';
    await box.put(key, dataToSave);

    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_fees')
          .doc(feeId)
          .set(dataToSave, SetOptions(merge: true));

      dataToSave['syncStatus'] = 'synced';
      dataToSave['lastSyncedAt'] = DateTime.now().toIso8601String();
      await box.put(key, dataToSave);
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Fee record cloud save error: $e');
      await LocalStorageService.enqueueSync({
        'action': 'set',
        'collection': 'branches/$branchId/school_fees',
        'docId': feeId,
        'data': dataToSave,
      });
      SyncService().triggerUpload();
    }

    await logAudit(
      branchId: branchId,
      action: 'UPDATE_FEE_RECORD',
      user: editorName,
      details: 'Recorded fee payment for ${feeData['studentName']} (Roll: ${feeData['rollNo']}) - Status: ${feeData['status']}',
    );
  }

  static List<Map<String, dynamic>> getAllFeeRecordsCached(String branchId) {
    if (!Hive.isBoxOpen(feesBox)) return [];
    final prefix = '${branchId.toLowerCase()}__';
    final box = Hive.box(feesBox);
    return box.keys
        .where((k) => k.toString().startsWith(prefix) || branchId == 'all')
        .map((k) {
          final val = box.get(k);
          if (val is Map) return Map<String, dynamic>.from(val);
          return null;
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  static Stream<List<Map<String, dynamic>>> streamFeeRecordsCached(String branchId) async* {
    if (!Hive.isBoxOpen(feesBox)) {
      await LocalStorageService.openBoxSafe(feesBox);
    }
    final box = Hive.box(feesBox);
    yield getAllFeeRecordsCached(branchId);
    yield* box.watch().map((_) => getAllFeeRecordsCached(branchId));
  }

  // ── Homeroom Teacher Assignment & Restrictions ────────────────────────────
  static Future<void> assignHomeroomTeacher({
    required String branchId,
    required String grade,
    required String section,
    required String? teacherId,
    required String? teacherName,
    required String editorName,
  }) async {
    final classKey = '${grade.trim()}_${section.trim()}';
    final box = Hive.isBoxOpen(homeroomBox) ? Hive.box(homeroomBox) : await LocalStorageService.openBoxSafe(homeroomBox);
    final key = '${branchId.toLowerCase()}__$classKey';

    final assignmentData = {
      'grade': grade,
      'section': section,
      'teacherId': teacherId ?? '',
      'teacherName': teacherName ?? 'Unassigned',
      'assignedAt': DateTime.now().toIso8601String(),
      'assignedBy': editorName,
    };

    await box.put(key, assignmentData);

    // Update teacher model in cache & Firestore if teacherId is provided
    final teachers = getAllTeachersCached(branchId);
    for (final t in teachers) {
      final tid = t['id'] ?? '';
      final curGrade = t['homeroomGrade'] ?? '';
      final curSec = t['homeroomSection'] ?? '';

      if (teacherId != null && tid == teacherId) {
        t['homeroomGrade'] = grade;
        t['homeroomSection'] = section;
        t['designation'] = 'Class Incharge ($grade - $section)';
        await saveTeacher(branchId: branchId, teacherId: tid, teacherData: t);
      } else if (curGrade == grade && curSec == section && tid != teacherId) {
        // Remove previous homeroom assignment from other teacher
        t['homeroomGrade'] = '';
        t['homeroomSection'] = '';
        t['designation'] = 'Teacher';
        await saveTeacher(branchId: branchId, teacherId: tid, teacherData: t);
      }
    }

    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('school_homerooms')
          .doc(classKey)
          .set(assignmentData, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[SchoolLocalStorage] Homeroom cloud save error: $e');
    }

    await logAudit(
      branchId: branchId,
      action: 'ASSIGN_HOMEROOM',
      user: editorName,
      details: teacherId != null && teacherId.isNotEmpty
          ? 'Assigned $teacherName as Homeroom Teacher for $grade - Section $section'
          : 'Removed Homeroom Teacher assignment for $grade - Section $section',
    );
  }

  static Map<String, dynamic>? getHomeroomAssignmentCached(String branchId, String grade, String section) {
    if (!Hive.isBoxOpen(homeroomBox)) return null;
    final classKey = '${grade.trim()}_${section.trim()}';
    final key = '${branchId.toLowerCase()}__$classKey';
    final box = Hive.box(homeroomBox);
    final val = box.get(key);
    if (val is Map) return Map<String, dynamic>.from(val);
    return null;
  }

  static Stream<Map<String, dynamic>?> streamHomeroomAssignmentCached(String branchId, String grade, String section) async* {
    if (!Hive.isBoxOpen(homeroomBox)) {
      await LocalStorageService.openBoxSafe(homeroomBox);
    }
    yield getHomeroomAssignmentCached(branchId, grade, section);
    final box = Hive.box(homeroomBox);
    yield* box.watch().map((_) => getHomeroomAssignmentCached(branchId, grade, section));
  }
}
