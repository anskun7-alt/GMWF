// lib/pages/school/grades/school_grade_service.dart
//
// Grade & exam attachment reads/writes over SchoolStore (Phase 5):
//   • Enforces role permissions (teachers can only enter marks for their
//     assigned classes & subjects; unknown roles blocked).
//   • Validates marks <= totalMarks before writing anything.
//   • Stores exam attachments ONCE in `school_grade_attachments` (instead of
//     copying base64 files into every student's grade doc).

import '../core/school_store.dart';
import '../models/school_grade.dart';
import '../utils/school_auth_helper.dart';
import 'grade_rules.dart';

class SchoolGradeException implements Exception {
  final String message;
  final Map<String, String> studentErrors;

  const SchoolGradeException(this.message, {this.studentErrors = const {}});

  @override
  String toString() => message;
}

abstract final class SchoolGradeService {
  static List<String> get watchedBoxes => [
        SchoolCollection.grades.box,
        SchoolCollection.students.box,
        SchoolCollection.events.box,
      ];

  static List<SchoolGrade> allGrades(String branchId) => SchoolStore.all(SchoolCollection.grades, branchId)
      .map((m) => SchoolGrade.fromMap((m['id'] ?? '').toString(), m))
      .where((g) => g.id.isNotEmpty)
      .toList();

  static List<SchoolGradeAttachment> allAttachments(String branchId) =>
      SchoolStore.all(SchoolCollection.gradeAttachments, branchId)
          .map((m) => SchoolGradeAttachment.fromMap((m['id'] ?? '').toString(), m))
          .where((a) => a.id.isNotEmpty && a.active)
          .toList();

  /// Returns the shared attachment for one exam, or null if none / removed.
  static SchoolGradeAttachment? attachmentFor({
    required String branchId,
    required String grade,
    required String section,
    required String subject,
    required String examType,
    required String term,
  }) {
    final id = GradeRules.attachmentDocId(
      grade: grade,
      section: section,
      subject: subject,
      examType: examType,
      term: term,
    );
    final raw = SchoolStore.get(SchoolCollection.gradeAttachments, branchId, id);
    if (raw == null) return null;
    final att = SchoolGradeAttachment.fromMap(id, raw);
    return att.active ? att : null;
  }

  /// Stores an exam marksheet / file ONCE in `school_grade_attachments`.
  static Future<SchoolGradeAttachment> saveAttachment({
    required String branchId,
    required String grade,
    required String section,
    required String subject,
    required String examType,
    required String term,
    required String fileName,
    required String fileType,
    required String dataUri,
    required String editorName,
    required String userRole,
    DateTime? now,
  }) async {
    _checkPermission(branchId: branchId, userRole: userRole, editorName: editorName, grade: grade, subject: subject);
    final at = now ?? DateTime.now();
    final id = GradeRules.attachmentDocId(
      grade: grade,
      section: section,
      subject: subject,
      examType: examType,
      term: term,
    );
    final att = SchoolGradeAttachment(
      id: id,
      grade: grade,
      section: section,
      subject: subject,
      examType: examType,
      term: term,
      fileName: fileName,
      fileType: fileType,
      dataUri: dataUri,
      active: true,
      uploadedBy: editorName,
      uploadedAt: at.toIso8601String(),
    );
    await SchoolStore.put(
      SchoolCollection.gradeAttachments,
      branchId: branchId,
      id: id,
      updatedBy: editorName,
      now: at,
      data: att.toMap(),
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'GRADE_ATTACHMENT_SAVED',
      user: editorName,
      details: 'Attached $fileName for Class $grade-$section · $subject ($examType, $term)',
      entity: 'grade_attachment',
      entityId: id,
    );
    return att;
  }

  /// Soft-removes an exam attachment (`active: false`; never hard-deleted).
  static Future<void> removeAttachment({
    required String branchId,
    required String attachmentId,
    required String grade,
    required String subject,
    required String editorName,
    required String userRole,
    DateTime? now,
  }) async {
    _checkPermission(branchId: branchId, userRole: userRole, editorName: editorName, grade: grade, subject: subject);
    await SchoolStore.put(
      SchoolCollection.gradeAttachments,
      branchId: branchId,
      id: attachmentId,
      updatedBy: editorName,
      now: now,
      data: {'active': false},
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'GRADE_ATTACHMENT_REMOVED',
      user: editorName,
      details: 'Removed marksheet attachment $attachmentId',
      entity: 'grade_attachment',
      entityId: attachmentId,
    );
  }

  /// Validates and saves a batch of student marks for one exam.
  /// References [attachment] by id/name/type ONLY — `attachmentUrl` stays empty
  /// on student grade records so files are never duplicated per student.
  static Future<int> saveBatch({
    required String branchId,
    required String grade,
    required String section,
    required String subject,
    required String examType,
    required String term,
    required double totalMarks,
    required List<GradeEntryInput> entries,
    required String editorName,
    required String userRole,
    SchoolGradeAttachment? attachment,
    DateTime? now,
  }) async {
    _checkPermission(branchId: branchId, userRole: userRole, editorName: editorName, grade: grade, subject: subject);
    if (totalMarks <= 0) {
      throw const SchoolGradeException('Total marks must be greater than 0.');
    }

    // Validate all rows before saving anything.
    final errors = <String, String>{};
    for (final entry in entries) {
      final err = GradeRules.validateMark(obtained: entry.marksObtained, totalMarks: totalMarks);
      if (err != null) errors[entry.student.id] = err;
    }
    if (errors.isNotEmpty) {
      final first = errors.values.first;
      throw SchoolGradeException(
        'Check marks (${errors.length} ${errors.length == 1 ? 'student' : 'students'}): $first',
        studentErrors: errors,
      );
    }
    if (entries.isEmpty) return 0;

    final at = now ?? DateTime.now();
    final dateStr =
        '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

    final existingByStudent = <String, SchoolGrade>{};
    for (final g in allGrades(branchId)) {
      if (g.grade == grade && g.subject == subject && g.examType == examType && g.term == term) {
        existingByStudent[g.studentId] = g;
      }
    }

    var savedCount = 0;
    for (final entry in entries) {
      final s = entry.student;
      final existing = existingByStudent[s.id];
      final id = (existing != null && existing.id.isNotEmpty)
          ? existing.id
          : GradeRules.gradeDocId(studentId: s.id, subject: subject, examType: examType, term: term);

      final obj = SchoolGrade(
        id: id,
        studentId: s.id,
        studentName: s.name,
        rollNo: s.rollNo,
        grade: s.grade,
        section: s.section,
        subject: subject,
        examType: examType,
        term: term,
        marksObtained: entry.marksObtained,
        totalMarks: totalMarks,
        date: dateStr,
        enteredBy: editorName,
        remarks: entry.remarks.trim(),
        attachmentId: attachment?.id ?? existing?.attachmentId ?? '',
        attachmentUrl: '', // Stored once in `school_grade_attachments`, never copied per student.
        attachmentName: attachment?.fileName ?? existing?.attachmentName ?? '',
        attachmentType: attachment?.fileType ?? existing?.attachmentType ?? '',
        academicYear: s.academicYear,
        branchId: branchId,
      );

      await SchoolStore.put(
        SchoolCollection.grades,
        branchId: branchId,
        id: id,
        updatedBy: editorName,
        now: at,
        data: obj.toMap(),
      );
      savedCount++;
    }

    await SchoolStore.audit(
      branchId: branchId,
      action: 'GRADE_ENTRY_BATCH',
      user: editorName,
      details: 'Recorded $savedCount marks for Class $grade-$section · $subject ($examType, $term, out of ${GradeRules.formatMark(totalMarks)})',
      entity: 'grade',
      entityId: '$grade-$section-$subject-$examType-$term',
      after: {
        'grade': grade,
        'section': section,
        'subject': subject,
        'examType': examType,
        'term': term,
        'totalMarks': totalMarks,
        'count': savedCount,
      },
    );
    return savedCount;
  }

  static void _checkPermission({
    required String branchId,
    required String userRole,
    required String editorName,
    required String grade,
    required String subject,
  }) {
    if (SchoolAuthHelper.isAdminOrPrincipal(userRole)) return;
    if (!SchoolAuthHelper.isTeacher(userRole)) {
      throw const SchoolGradeException('Your role does not have permission to enter grades.');
    }
    if (!SchoolAuthHelper.canAccessGrade(branchId, userRole, editorName, grade)) {
      throw SchoolGradeException('You are not assigned to Class $grade.');
    }
    if (!SchoolAuthHelper.canAccessSubject(branchId, userRole, editorName, subject)) {
      throw SchoolGradeException('You are not assigned to teach $subject.');
    }
  }
}
