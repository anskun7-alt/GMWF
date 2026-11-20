// lib/pages/school/utils/school_local_storage.dart
//
// School storage facade used by the School screens. Since the School ERP
// Phase 0 (2026-11-14) every read and write goes through `core/school_store.dart`:
//  * one branch rule (SchoolBranchId) for every key and path,
//  * saves stamp `lastModified`, write Hive, queue the upload and return at
//    once (no more 20–30 s freezes offline),
//  * reads find records stored under branch aliases.
// The public method names are unchanged so existing screens keep working.
// This file no longer imports any madrassa code.

import 'dart:async';
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/image_upload_service.dart';
import '../../../services/local_storage_service.dart';
import '../core/school_branch_id.dart';
import '../core/school_ids.dart';
import '../core/school_store.dart';

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

  static String normalizeBranch(String branchId) => SchoolBranchId.normalize(branchId);

  static const Map<String, List<String>> _mediaAliases = {
    'photoUrl': ['photoBase64', 'studentPhotoBase64'],
    'bformUrl': ['bformBase64', 'bFormUrl', 'bFormBase64'],
    'guardianCnicUrl': ['guardianCnicBase64', 'fatherCnicUrl', 'fatherCnicBase64'],
  };

  /// Compresses School student media (photo, B-Form, guardian CNIC, additional documents)
  /// to ensure payloads never exceed Firestore's 1 MiB document limit.
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
      for (final a in aliases) {
        out.remove(a);
      }
    });

    // 1. Compress primary media fields
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

    // 2. Compress additionalDocuments list
    if (out['additionalDocuments'] is List) {
      final docList = List<Map<String, dynamic>>.from(
        (out['additionalDocuments'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      for (final doc in docList) {
        final docUrl = doc['url'];
        if (docUrl is String && docUrl.length > 25000 && ImageUploadService.isValidMediaString(docUrl)) {
          try {
            final bytes = ImageUploadService.decodeBase64ToBytes(docUrl);
            if (bytes != null && bytes.isNotEmpty) {
              final recompressed = ImageUploadService.processBytesToBase64(
                bytes,
                maxWidth: 550,
                maxHeight: 550,
                quality: 45,
              );
              if (recompressed != null && recompressed.isNotEmpty && recompressed.length < docUrl.length) {
                doc['url'] = recompressed;
              }
            }
          } catch (_) {}
        }
      }
      out['additionalDocuments'] = docList;
    }

    // 3. Strict total document size verification for Firestore's 1 MiB limit
    try {
      final jsonStr = jsonEncode(out);
      if (jsonStr.length > 450000) {
        for (final primary in _mediaAliases.keys) {
          final val = out[primary];
          if (val is String && val.length > 20000 && ImageUploadService.isValidMediaString(val)) {
            final bytes = ImageUploadService.decodeBase64ToBytes(val);
            if (bytes != null && bytes.isNotEmpty) {
              final isAvatar = primary == 'photoUrl';
              final emergency = ImageUploadService.processBytesToBase64(
                bytes,
                maxWidth: isAvatar ? 250 : 400,
                maxHeight: isAvatar ? 250 : 400,
                quality: isAvatar ? 45 : 35,
              );
              if (emergency != null && emergency.isNotEmpty && emergency.length < val.length) {
                out[primary] = emergency;
              }
            }
          }
        }
        if (out['additionalDocuments'] is List) {
          final docList = List<Map<String, dynamic>>.from(
            (out['additionalDocuments'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
          );
          for (final doc in docList) {
            final docUrl = doc['url'];
            if (docUrl is String && docUrl.length > 20000 && ImageUploadService.isValidMediaString(docUrl)) {
              final bytes = ImageUploadService.decodeBase64ToBytes(docUrl);
              if (bytes != null && bytes.isNotEmpty) {
                final emergency = ImageUploadService.processBytesToBase64(
                  bytes,
                  maxWidth: 400,
                  maxHeight: 400,
                  quality: 35,
                );
                if (emergency != null && emergency.isNotEmpty && emergency.length < docUrl.length) {
                  doc['url'] = emergency;
                }
              }
            }
          }
          out['additionalDocuments'] = docList;
        }
      }
    } catch (_) {}

    return out;
  }

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

  // ── Generic helpers ────────────────────────────────────────────────────────
  static Stream<T> _watchBox<T>(String boxName, T Function() read) async* {
    final box = await SchoolStore.openBox(boxName);
    yield read();
    yield* box.watch().map((_) => read());
  }

  static bool _sameJson(Object? a, Object? b) {
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  // ── Students ───────────────────────────────────────────────────────────────
  /// Stores a cloud copy locally (no upload). Screens save with [saveStudent].
  static Future<void> cacheStudent(String branchId, String studentId, Map<String, dynamic> data) =>
      SchoolStore.putFromCloud(SchoolCollection.students, branchId, studentId, data);

  static Map<String, dynamic>? getStudentCached(String branchId, String studentId) =>
      SchoolStore.get(SchoolCollection.students, branchId, studentId);

  static List<Map<String, dynamic>> getAllStudentsCached(String branchId) =>
      SchoolStore.all(SchoolCollection.students, branchId);

  static Stream<List<Map<String, dynamic>>> streamStudentsCached(String branchId) =>
      _watchBox(studentsBox, () => getAllStudentsCached(branchId)).distinct(_sameJson);

  // ── Teachers ───────────────────────────────────────────────────────────────
  static Future<void> cacheTeacher(String branchId, String teacherId, Map<String, dynamic> data) =>
      SchoolStore.putFromCloud(SchoolCollection.teachers, branchId, teacherId, data);

  static Map<String, dynamic>? getTeacherCached(String branchId, String teacherId) =>
      SchoolStore.get(SchoolCollection.teachers, branchId, teacherId);

  static List<Map<String, dynamic>> getAllTeachersCached(String branchId) =>
      SchoolStore.all(SchoolCollection.teachers, branchId);

  static Stream<List<Map<String, dynamic>>> streamTeachersCached(String branchId) =>
      _watchBox(teachersBox, () => getAllTeachersCached(branchId)).distinct(_sameJson);

  // ── Books & Book Loans ─────────────────────────────────────────────────────
  static Future<void> cacheBook(String branchId, String bookId, Map<String, dynamic> data) =>
      SchoolStore.putFromCloud(SchoolCollection.books, branchId, bookId, data);

  static Map<String, dynamic>? getBookCached(String branchId, String bookId) =>
      SchoolStore.get(SchoolCollection.books, branchId, bookId);

  static List<Map<String, dynamic>> getAllBooksCached(String branchId) =>
      SchoolStore.all(SchoolCollection.books, branchId);

  static Stream<List<Map<String, dynamic>>> streamBooksCached(String branchId) =>
      _watchBox(booksBox, () => getAllBooksCached(branchId));

  static Future<void> cacheBookLoan(String branchId, String loanId, Map<String, dynamic> data) =>
      SchoolStore.putFromCloud(SchoolCollection.bookLoans, branchId, loanId, data);

  static Map<String, dynamic>? getBookLoanCached(String branchId, String loanId) =>
      SchoolStore.get(SchoolCollection.bookLoans, branchId, loanId);

  static List<Map<String, dynamic>> getAllBookLoansCached(String branchId) =>
      SchoolStore.all(SchoolCollection.bookLoans, branchId);

  static Stream<List<Map<String, dynamic>>> streamBookLoansCached(String branchId) =>
      _watchBox(bookLoansBox, () => getAllBookLoansCached(branchId));

  /// Copies of [bookId] currently out (loans not yet returned).
  static int activeLoanCount(String branchId, String bookId) => getAllBookLoansCached(branchId)
      // Only open loans hold a copy; returned and lost loans don't.
      .where((l) => l['bookId']?.toString() == bookId && (l['status'] ?? 'borrowed').toString() == 'borrowed')
      .length;

  /// Available copies are derived from loans, never typed: total − copies out.
  static int availableCopies(String branchId, Map<String, dynamic> book) {
    final total = (book['totalCopies'] as num?)?.toInt() ?? int.tryParse('${book['totalCopies']}') ?? 0;
    final out = activeLoanCount(branchId, book['id']?.toString() ?? '');
    return (total - out).clamp(0, total < 0 ? 0 : total);
  }

  // ── Attendance day logs ────────────────────────────────────────────────────
  static Future<void> cacheLog(String branchId, String dateKey, Map<String, dynamic> logData) =>
      SchoolStore.putFromCloud(SchoolCollection.attendance, branchId, dateKey, logData);

  static Future<void> cacheTeacherAttendanceLog(String branchId, String dateKey, Map<String, dynamic> logData) =>
      SchoolStore.putFromCloud(SchoolCollection.teacherAttendance, branchId, dateKey, logData);

  /// The day's log; for "all" every branch's entries are combined.
  static Map<String, dynamic>? getLogCached(String branchId, String dateKey) {
    final log = SchoolStore.get(SchoolCollection.attendance, branchId, dateKey);
    if (log == null && SchoolBranchId.isAll(branchId)) return {'date': dateKey, 'entries': <String, dynamic>{}};
    return log;
  }

  static Stream<Map<String, dynamic>?> streamLogCached(String branchId, String dateKey) =>
      _watchBox(logsBox, () => getLogCached(branchId, dateKey)).distinct(_sameJson);

  static Map<String, dynamic>? getTeacherLogCached(String branchId, String dateKey) {
    final log = SchoolStore.get(SchoolCollection.teacherAttendance, branchId, dateKey);
    if (log == null && SchoolBranchId.isAll(branchId)) return {'date': dateKey, 'entries': <String, dynamic>{}};
    return log;
  }

  static Stream<Map<String, dynamic>?> streamTeacherLogCached(String branchId, String dateKey) =>
      _watchBox(logsBox, () => getTeacherLogCached(branchId, dateKey)).distinct(_sameJson);

  static int _countPresent(Map<String, dynamic>? log) {
    final entries = (log?['entries'] as Map?) ?? const {};
    var count = 0;
    entries.forEach((_, v) {
      if (v is Map && (v['status'] ?? '').toString().toLowerCase() == 'present') count++;
    });
    return count;
  }

  static int getPresentStudentsCount(String branchId, String dateKey) => _countPresent(getLogCached(branchId, dateKey));

  static int getPresentTeachersCount(String branchId, String dateKey) =>
      _countPresent(getTeacherLogCached(branchId, dateKey));

  // ── Saves ──────────────────────────────────────────────────────────────────
  static Future<void> saveStudent({
    required String branchId,
    required String studentId,
    required Map<String, dynamic> studentData,
    String? editorName,
  }) async {
    final before = getStudentCached(branchId, studentId);
    final after = await SchoolStore.put(
      SchoolCollection.students,
      branchId: branchId,
      id: studentId,
      data: compactMediaForCloud(studentData),
      updatedBy: editorName,
    );
    final (b, a) = SchoolStore.diff(before, after);
    if (before == null || a.isNotEmpty) {
      await SchoolStore.audit(
        branchId: branchId,
        action: before == null ? 'STUDENT_ENROLLED' : 'STUDENT_UPDATED',
        user: editorName ?? 'Unknown',
        details: before == null
            ? 'Enrolled ${after['name'] ?? studentId}'
            : 'Updated ${after['name'] ?? studentId}: ${a.keys.join(', ')}',
        entity: 'student',
        entityId: studentId,
        before: before == null ? null : b,
        after: before == null ? null : a,
      );
    }
  }

  static Future<void> saveTeacher({
    required String branchId,
    required String teacherId,
    required Map<String, dynamic> teacherData,
    String? editorName,
  }) async {
    // Merge-save: fields the dialog does not know about (homeroomGrade,
    // homeroomSection) are kept instead of being dropped.
    final before = getTeacherCached(branchId, teacherId);
    final after = await SchoolStore.put(
      SchoolCollection.teachers,
      branchId: branchId,
      id: teacherId,
      data: teacherData,
      updatedBy: editorName,
    );
    final (b, a) = SchoolStore.diff(before, after);
    if (before == null || a.isNotEmpty) {
      await SchoolStore.audit(
        branchId: branchId,
        action: before == null ? 'TEACHER_ADDED' : 'TEACHER_UPDATED',
        user: editorName ?? 'Unknown',
        details: '${before == null ? 'Added' : 'Updated'} teacher ${after['name'] ?? teacherId}',
        entity: 'teacher',
        entityId: teacherId,
        before: before == null ? null : b,
        after: before == null ? null : a,
      );
    }
  }

  static Future<Map<String, dynamic>> saveBook({
    required String branchId,
    required String bookId,
    required Map<String, dynamic> bookData,
    String? editorName,
  }) async {
    final before = getBookCached(branchId, bookId);
    final data = Map<String, dynamic>.from(bookData)..remove('lastModified');
    final after = await SchoolStore.put(
      SchoolCollection.books,
      branchId: branchId,
      id: bookId,
      data: data,
      updatedBy: editorName,
    );
    final (b, a) = SchoolStore.diff(before, after, ignore: const {
      'lastModified', 'syncStatus', 'pendingSync', 'synced', 'lastSyncedAt', 'updatedBy', 'updatedAt', 'availableCopies',
    });
    if (before == null || a.isNotEmpty) {
      await SchoolStore.audit(
        branchId: branchId,
        action: before == null ? 'BOOK_ADDED' : 'BOOK_UPDATED',
        user: editorName ?? 'Unknown',
        details: '${before == null ? 'Added' : 'Updated'} book "${after['title'] ?? bookId}"',
        entity: 'book',
        entityId: bookId,
        before: before == null ? null : b,
        after: before == null ? null : a,
      );
    }
    return after;
  }

  static Future<Map<String, dynamic>> saveBookLoan({
    required String branchId,
    required String loanId,
    required Map<String, dynamic> loanData,
    String? editorName,
  }) {
    final data = Map<String, dynamic>.from(loanData)..remove('lastModified');
    return SchoolStore.put(
      SchoolCollection.bookLoans,
      branchId: branchId,
      id: loanId,
      data: data,
      updatedBy: editorName,
    );
  }

  /// Keeps the book's stored `availableCopies` equal to total − copies out.
  static Future<void> refreshBookAvailability(String branchId, String bookId, {String? editorName}) async {
    final book = getBookCached(branchId, bookId);
    if (book == null) return;
    final available = availableCopies(branchId, {...book, 'id': bookId});
    if ((book['availableCopies'] as num?)?.toInt() == available) return;
    await SchoolStore.put(
      SchoolCollection.books,
      branchId: branchId,
      id: bookId,
      data: {'availableCopies': available},
      updatedBy: editorName,
    );
  }

  static Future<void> saveDailyLog({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> logEntries,
    required String editorName,
  }) async {
    await SchoolStore.put(
      SchoolCollection.attendance,
      branchId: branchId,
      id: dateKey,
      updatedBy: editorName,
      data: {
        'date': dateKey,
        'lastUpdated': DateTime.now().toIso8601String(),
        'entries': SchoolStore.sanitize(logEntries),
      },
    );
    await logAudit(
      branchId: branchId,
      action: 'UPDATE_ATTENDANCE_LOG',
      user: editorName,
      details: 'Updated student daily log for date: $dateKey',
    );
  }

  static Future<void> saveTeacherDailyLog({
    required String branchId,
    required String dateKey,
    required Map<String, dynamic> logEntries,
    required String editorName,
  }) async {
    await SchoolStore.put(
      SchoolCollection.teacherAttendance,
      branchId: branchId,
      id: dateKey,
      updatedBy: editorName,
      data: {
        'date': dateKey,
        'lastUpdated': DateTime.now().toIso8601String(),
        'entries': SchoolStore.sanitize(logEntries),
      },
    );
    await logAudit(
      branchId: branchId,
      action: 'UPDATE_TEACHER_ATTENDANCE',
      user: editorName,
      details: 'Updated teacher attendance log for date: $dateKey',
    );
  }

  // ── Audit Logging ─────────────────────────────────────────────────────────
  static Future<void> logAudit({
    required String branchId,
    required String action,
    required String user,
    required String details,
  }) =>
      SchoolStore.audit(branchId: branchId, action: action, user: user, details: details);

  static List<Map<String, dynamic>> getAuditLogsCached(String branchId) {
    final list = SchoolStore.all(SchoolCollection.auditLogs, branchId);
    list.sort((a, b) => (b['timestamp'] ?? '').toString().compareTo((a['timestamp'] ?? '').toString()));
    return list;
  }

  // ── Grades ────────────────────────────────────────────────────────────────
  static Future<void> saveGrade({
    required String branchId,
    required String gradeId,
    required Map<String, dynamic> gradeData,
    String? editorName,
  }) async {
    if (gradeId.trim().isEmpty) {
      throw ArgumentError('saveGrade called with an empty gradeId');
    }
    await SchoolStore.put(
      SchoolCollection.grades,
      branchId: branchId,
      id: gradeId,
      data: Map<String, dynamic>.from(gradeData)..['id'] = gradeId,
      updatedBy: editorName,
    );
  }

  static List<Map<String, dynamic>> getAllGradesCached(String branchId) =>
      SchoolStore.all(SchoolCollection.grades, branchId);

  static Stream<List<Map<String, dynamic>>> streamGradesCached(String branchId) =>
      _watchBox(gradesBox, () => getAllGradesCached(branchId));

  // ── Fee Records ───────────────────────────────────────────────────────────
  static Future<void> saveFeeRecord({
    required String branchId,
    required String feeId,
    required Map<String, dynamic> feeData,
    required String editorName,
  }) async {
    final saved = await SchoolStore.put(
      SchoolCollection.fees,
      branchId: branchId,
      id: feeId,
      data: feeData,
      updatedBy: editorName,
    );
    await logAudit(
      branchId: branchId,
      action: 'UPDATE_FEE_RECORD',
      user: editorName,
      details: 'Recorded fee payment for ${saved['studentName']} (Roll: ${saved['rollNo']}) - '
          'Paid ${saved['paidAmount']} of ${saved['totalAmount']} - Status: ${saved['status']}',
    );
  }

  static List<Map<String, dynamic>> getAllFeeRecordsCached(String branchId) =>
      SchoolStore.all(SchoolCollection.fees, branchId);

  static Stream<List<Map<String, dynamic>>> streamFeeRecordsCached(String branchId) =>
      _watchBox(feesBox, () => getAllFeeRecordsCached(branchId));

  // ── Homeroom Teacher Assignment ───────────────────────────────────────────
  static Future<void> assignHomeroomTeacher({
    required String branchId,
    required String grade,
    required String section,
    required String? teacherId,
    required String? teacherName,
    required String editorName,
  }) async {
    final classKey = '${grade.trim()}_${section.trim()}';
    final nowIso = DateTime.now().toIso8601String();

    // A teacher is homeroom teacher of ONE class: release any other class they held.
    if (teacherId != null && teacherId.isNotEmpty) {
      for (final h in SchoolStore.all(SchoolCollection.homerooms, branchId)) {
        final hid = h['id']?.toString() ?? '';
        if (hid.isNotEmpty && hid != classKey && h['teacherId']?.toString() == teacherId) {
          await SchoolStore.put(
            SchoolCollection.homerooms,
            branchId: branchId,
            id: hid,
            updatedBy: editorName,
            data: {'teacherId': '', 'teacherName': 'Unassigned', 'assignedAt': nowIso, 'assignedBy': editorName},
          );
        }
      }
    }

    await SchoolStore.put(
      SchoolCollection.homerooms,
      branchId: branchId,
      id: classKey,
      updatedBy: editorName,
      data: {
        'grade': grade,
        'section': section,
        'teacherId': teacherId ?? '',
        'teacherName': teacherName ?? 'Unassigned',
        'assignedAt': nowIso,
        'assignedBy': editorName,
      },
    );

    for (final t in getAllTeachersCached(branchId)) {
      final tid = (t['id'] ?? '').toString();
      final curGrade = t['homeroomGrade'] ?? '';
      final curSec = t['homeroomSection'] ?? '';
      if (teacherId != null && tid == teacherId) {
        await saveTeacher(branchId: branchId, teacherId: tid, editorName: editorName, teacherData: {
          'homeroomGrade': grade,
          'homeroomSection': section,
          'designation': 'Class Incharge ($grade - $section)',
        });
      } else if (curGrade == grade && curSec == section && tid != teacherId) {
        await saveTeacher(branchId: branchId, teacherId: tid, editorName: editorName, teacherData: {
          'homeroomGrade': '',
          'homeroomSection': '',
          'designation': 'Teacher',
        });
      }
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

  static Map<String, dynamic>? getHomeroomAssignmentCached(String branchId, String grade, String section) =>
      SchoolStore.get(SchoolCollection.homerooms, branchId, '${grade.trim()}_${section.trim()}');

  static Stream<Map<String, dynamic>?> streamHomeroomAssignmentCached(String branchId, String grade, String section) =>
      _watchBox(homeroomBox, () => getHomeroomAssignmentCached(branchId, grade, section));

  /// New document id for a School record (`PREFIX-branch-millis-random`).
  static String newId(String prefix, String branchId) => SchoolIds.newId(prefix, branchId);
}
