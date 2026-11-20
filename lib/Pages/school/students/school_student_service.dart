// lib/pages/school/students/school_student_service.dart
//
// Student reads and writes over the School store (School ERP Phase 2). Screens
// call this; the rules are in student_rules.dart.
//
//   • save(): new admission or edit. Assigns the admission number, checks the
//     roll number, duplicates and fields, records class moves, keeps fields the
//     form does not show (madrassa link, history, documents), audits the change.
//   • changeStatus(): dated status change appended to the history. No deletes.

import '../core/school_store.dart';
import '../models/school_student.dart';
import '../utils/school_local_storage.dart';
import 'promotion_rules.dart';
import 'student_rules.dart';

class StudentException implements Exception {
  final String message;

  /// Possible duplicates found; the screen can ask and save again with
  /// `allowDuplicates: true`.
  final List<StudentMatch> duplicates;

  /// Field problems from [StudentRules.validate].
  final Map<String, String> fields;

  const StudentException(this.message, {this.duplicates = const [], this.fields = const {}});

  @override
  String toString() => message;
}

/// Students of one branch, read once per rebuild.
class StudentRoster {
  final List<SchoolStudent> students;
  StudentRoster(this.students) : _byId = {for (final s in students) s.id: s};

  final Map<String, SchoolStudent> _byId;

  SchoolStudent? byId(String id) => _byId[id];
  List<SchoolStudent> siblingsOf(SchoolStudent s) => StudentRules.siblingsOf(s, students);
  Map<String, List<SchoolStudent>> get admissionConflicts => StudentRules.admissionNoConflicts(students);

  int count(StudentStatus status) => students.where((s) => s.status == status.value).length;
}

abstract final class SchoolStudentService {
  static StudentRoster roster(String branchId) {
    final list = SchoolLocalStorage.getAllStudentsCached(branchId)
        .map((m) => SchoolStudent.fromMap((m['id'] ?? '').toString(), m))
        .where((s) => s.id.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return StudentRoster(list);
  }

  static String nextAdmissionNo(String branchId) =>
      StudentRules.nextAdmissionNo(branchId, roster(branchId).students);

  /// Saves a new admission ([existingId] null) or an edit.
  ///
  /// [form] holds only the fields the form shows. Fields it does not hold are
  /// kept from the stored record. Throws [StudentException] when something is
  /// wrong; nothing is written then. Returns the student id.
  static Future<String> save({
    required String branchId,
    String? existingId,
    required Map<String, dynamic> form,
    required String editorName,
    bool allowDuplicates = false,
    bool canEditAdmissionNo = false,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final roster = SchoolStudentService.roster(branchId);
    final before = existingId == null ? null : roster.byId(existingId);
    if (existingId != null && before == null) {
      throw const StudentException('This student was not found on this device. Sync and try again.');
    }
    final id = existingId ?? SchoolLocalStorage.newId('STD', branchId);

    final data = <String, dynamic>{...form};
    final admissionDate = DateTime.tryParse((data['admissionDate'] ?? before?.admissionDate ?? '').toString()) ?? at;

    // Admission number: issued once; only Principal / School Admin may change it.
    final typedAdm = (data['admissionNo'] ?? '').toString().trim();
    if (before == null) {
      data['admissionNo'] = typedAdm.isEmpty ? StudentRules.nextAdmissionNo(branchId, roster.students) : typedAdm;
      data['status'] = StudentStatus.active.value;
      data['statusDate'] = _ymd(admissionDate);
      data['statusHistory'] = const <Map<String, dynamic>>[];
      data['classHistory'] = const <Map<String, dynamic>>[];
      if ((data['transferredFromMadrassaId'] ?? '').toString().isNotEmpty) {
        data['transferredAt'] = at.toIso8601String();
      }
    } else {
      if (typedAdm.isEmpty || (!canEditAdmissionNo && typedAdm != before.admissionNo)) {
        data['admissionNo'] = before.admissionNo;
      }
      // Status only changes through changeStatus().
      data.remove('status');
      data.remove('statusDate');
      data.remove('statusHistory');
      // The madrassa link is set once at admission.
      if ((data['transferredFromMadrassaId'] ?? '').toString().isEmpty) {
        data.remove('transferredFromMadrassaId');
      }
    }
    data['academicYear'] = (data['academicYear'] ?? '').toString().isNotEmpty
        ? data['academicYear']
        : (before?.academicYear.isNotEmpty ?? false)
            ? before!.academicYear
            : StudentRules.academicYearOf(admissionDate);

    final candidate = SchoolStudent.fromMap(id, {...?before?.toMap(), ...data});

    final problems = StudentRules.validate(candidate, now: at);
    if (problems.isNotEmpty) {
      throw StudentException(problems.values.first, fields: problems);
    }
    // Numbers are checked when new or changed, so an old record that already
    // shares a number (typed by hand before Phase 2) can still be edited.
    final admChanged = before == null || before.admissionNo != candidate.admissionNo;
    final rollChanged = before == null ||
        before.rollNo != candidate.rollNo ||
        before.grade != candidate.grade ||
        before.section != candidate.section;
    final admTaken = admChanged
        ? StudentRules.admissionNoTakenBy(candidate.admissionNo, roster.students, exceptId: id)
        : const <SchoolStudent>[];
    if (admTaken.isNotEmpty) {
      throw StudentException(
        'Admission number ${candidate.admissionNo} already belongs to ${admTaken.first.name}.',
        fields: {'admissionNo': 'Already used by ${admTaken.first.name}'},
      );
    }
    final rollTaken = !rollChanged
        ? null
        : StudentRules.rollNoTakenBy(
            candidate.rollNo,
            roster.students,
            grade: candidate.grade,
            section: candidate.section,
            academicYear: candidate.academicYear,
            exceptId: id,
          );
    if (rollTaken != null) {
      throw StudentException(
        'Roll number ${candidate.rollNo} is already used in class ${candidate.grade}-${candidate.section} by ${rollTaken.name}.',
        fields: {'rollNo': 'Used by ${rollTaken.name}'},
      );
    }
    if (!allowDuplicates && (before == null || _identityChanged(before, candidate))) {
      final dups = StudentRules.duplicatesOf(candidate, roster.students);
      if (dups.isNotEmpty) {
        throw StudentException('This student may already be registered.', duplicates: dups);
      }
    }

    // Class/section move after admission → dated entry in the class history.
    if (before != null && (before.grade != candidate.grade || before.section != candidate.section)) {
      data['classHistory'] = [
        ...before.classHistory.map((e) => e.toMap()),
        SchoolStudentClassChange(
          fromGrade: before.grade,
          fromSection: before.section,
          toGrade: candidate.grade,
          toSection: candidate.section,
          effectiveDate: _ymd(at),
          by: editorName,
          at: at.toIso8601String(),
        ).toMap(),
      ];
    }

    await SchoolLocalStorage.saveStudent(
      branchId: branchId,
      studentId: id,
      studentData: data,
      editorName: editorName,
    );
    return id;
  }

  /// Moves a student to [to] from [effectiveDate], with a reason.
  static Future<void> changeStatus({
    required String branchId,
    required String studentId,
    required StudentStatus to,
    required DateTime effectiveDate,
    required String reason,
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final s = roster(branchId).byId(studentId);
    if (s == null) throw const StudentException('This student was not found on this device.');
    final problem = StudentRules.validateStatusChange(
      student: s,
      to: to,
      effectiveDate: effectiveDate,
      reason: reason,
      isPrincipal: isPrincipal,
      now: at,
    );
    if (problem != null) throw StudentException(problem);

    final change = SchoolStudentStatusChange(
      from: s.status,
      to: to.value,
      effectiveDate: _ymd(effectiveDate),
      reason: reason.trim(),
      by: editorName,
      at: at.toIso8601String(),
    );
    await SchoolStore.put(
      SchoolCollection.students,
      branchId: branchId,
      id: studentId,
      updatedBy: editorName,
      data: {
        'status': to.value,
        'statusDate': change.effectiveDate,
        'statusReason': change.reason,
        'statusHistory': [...s.statusHistory.map((e) => e.toMap()), change.toMap()],
      },
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'STUDENT_STATUS',
      user: editorName,
      details: '${s.name}: ${StudentStatus.parse(s.status).label} → ${to.label} from ${change.effectiveDate}'
          '${change.reason.isEmpty ? '' : ' (${change.reason})'}',
      entity: 'student',
      entityId: studentId,
      before: {'status': s.status},
      after: {'status': to.value, 'effectiveDate': change.effectiveDate},
    );
  }

  /// End-of-year bulk promotion for one class (School ERP plan §3.3, Phase 5).
  /// Principal / School Admin only. Promotes students to the next class (with
  /// fresh roll numbers and dated class history), holds back selected students
  /// in the same class for the new academic year, and graduates final-class
  /// students via [changeStatus] so fee proration history stays intact.
  static Future<PromotionBatchResult> promoteBatch({
    required String branchId,
    required String sourceGrade,
    required String targetYear,
    required DateTime effectiveDate,
    required List<PromotionPlanRow> plan,
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    if (!isPrincipal) {
      throw const StudentException('Only Principal or School Admin can run year-end promotion.');
    }
    final yearErr = PromotionRules.validateTargetYear(targetYear);
    if (yearErr != null) throw StudentException(yearErr);

    final at = now ?? DateTime.now();
    final effYmd = _ymd(effectiveDate);
    var promoted = 0;
    var heldBack = 0;
    var graduated = 0;
    var skipped = 0;

    for (final row in plan) {
      final fresh = roster(branchId).byId(row.student.id);
      if (fresh == null || !fresh.isActive) {
        skipped++;
        continue;
      }
      switch (row.action) {
        case PromotionAction.skip:
          skipped++;
        case PromotionAction.graduate:
          await changeStatus(
            branchId: branchId,
            studentId: fresh.id,
            to: StudentStatus.graduated,
            effectiveDate: effectiveDate,
            reason: 'Graduated from Class ${fresh.grade}-${fresh.section} (${fresh.academicYear.isEmpty ? sourceGrade : fresh.academicYear})',
            editorName: editorName,
            isPrincipal: isPrincipal,
            now: at,
          );
          graduated++;
        case PromotionAction.promote:
        case PromotionAction.holdBack:
          final history = [
            ...fresh.classHistory.map((e) => e.toMap()),
            SchoolStudentClassChange(
              fromGrade: fresh.grade,
              fromSection: fresh.section,
              toGrade: row.targetGrade,
              toSection: row.targetSection,
              effectiveDate: effYmd,
              by: editorName,
              at: at.toIso8601String(),
            ).toMap(),
          ];
          await SchoolStore.put(
            SchoolCollection.students,
            branchId: branchId,
            id: fresh.id,
            updatedBy: editorName,
            now: at,
            data: {
              'grade': row.targetGrade,
              'section': row.targetSection,
              'academicGroup': row.targetGroup,
              'academicYear': targetYear.trim(),
              'rollNo': row.targetRollNo,
              'classHistory': history,
            },
          );
          if (row.action == PromotionAction.promote) {
            promoted++;
          } else {
            heldBack++;
          }
      }
    }

    if (promoted + heldBack + graduated > 0) {
      await SchoolStore.audit(
        branchId: branchId,
        action: 'STUDENT_PROMOTION_BATCH',
        user: editorName,
        details: 'Class $sourceGrade → session $targetYear: $promoted promoted, $heldBack held back, $graduated graduated'
            '${skipped > 0 ? ', $skipped skipped' : ''}',
        entity: 'promotion',
        entityId: '$sourceGrade-$targetYear',
        after: {
          'sourceGrade': sourceGrade,
          'targetYear': targetYear,
          'effectiveDate': effYmd,
          'promoted': promoted,
          'heldBack': heldBack,
          'graduated': graduated,
          'skipped': skipped,
        },
      );
    }

    return PromotionBatchResult(
      promoted: promoted,
      heldBack: heldBack,
      graduated: graduated,
      skipped: skipped,
      targetYear: targetYear.trim(),
    );
  }

  static bool _identityChanged(SchoolStudent a, SchoolStudent b) =>
      a.name != b.name ||
      a.guardianName != b.guardianName ||
      a.dob != b.dob ||
      StudentRules.digits(a.bformNo) != StudentRules.digits(b.bformNo) ||
      StudentRules.digits(a.guardianCnic) != StudentRules.digits(b.guardianCnic);

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
