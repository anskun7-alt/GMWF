// lib/pages/school/students/promotion_rules.dart
//
// End-of-year bulk promotion rules (School ERP plan §3.3, Phase 5).
// Pure functions, no storage, so every edge case is unit-tested:
//   • academic year progression ("2026-27" → "2027-28")
//   • class progression along SchoolConstants.grades (final class "10th" graduates)
//   • per-student decision: promote, hold back, graduate, or skip
//   • collision-free roll number assignment in the target academic year

import '../constants/school_constants.dart';
import '../models/school_student.dart';
import 'student_rules.dart';

enum PromotionAction {
  promote('Promote'),
  holdBack('Hold back'),
  graduate('Graduate'),
  skip('Skip');

  const PromotionAction(this.label);
  final String label;
}

class PromotionDecision {
  final String studentId;
  final PromotionAction action;
  final String targetSection;
  final String targetGroup;

  const PromotionDecision({
    required this.studentId,
    required this.action,
    required this.targetSection,
    this.targetGroup = 'General',
  });

  PromotionDecision copyWith({PromotionAction? action, String? targetSection, String? targetGroup}) => PromotionDecision(
        studentId: studentId,
        action: action ?? this.action,
        targetSection: targetSection ?? this.targetSection,
        targetGroup: targetGroup ?? this.targetGroup,
      );
}

class PromotionPlanRow {
  final SchoolStudent student;
  final PromotionAction action;
  final String targetGrade;
  final String targetSection;
  final String targetGroup;
  final String targetRollNo;
  final bool alreadyInTargetYear;

  const PromotionPlanRow({
    required this.student,
    required this.action,
    required this.targetGrade,
    required this.targetSection,
    required this.targetGroup,
    required this.targetRollNo,
    required this.alreadyInTargetYear,
  });
}

class PromotionBatchResult {
  final int promoted;
  final int heldBack;
  final int graduated;
  final int skipped;
  final String targetYear;

  const PromotionBatchResult({
    required this.promoted,
    required this.heldBack,
    required this.graduated,
    required this.skipped,
    required this.targetYear,
  });

  int get totalChanged => promoted + heldBack + graduated;
}

abstract final class PromotionRules {
  static final RegExp _yearPattern = RegExp(r'^(\d{4})-(\d{2})$');

  /// "2026-27" → "2027-28". Falls back to the next year from [now] if malformed.
  static String nextAcademicYear(String currentYear, {DateTime? now}) {
    final m = _yearPattern.firstMatch(currentYear.trim());
    if (m != null) {
      final start = int.parse(m.group(1)!) + 1;
      return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
    }
    final d = now ?? DateTime.now();
    final cur = StudentRules.academicYearOf(d);
    final cm = _yearPattern.firstMatch(cur)!;
    final start = int.parse(cm.group(1)!) + 1;
    return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
  }

  /// Next class in [SchoolConstants.grades], or null when [grade] is the final
  /// class (graduating class, e.g. `10th`) or unknown.
  static String? nextGradeOf(String grade) {
    final idx = SchoolConstants.grades.indexOf(grade);
    if (idx < 0 || idx + 1 >= SchoolConstants.grades.length) return null;
    return SchoolConstants.grades[idx + 1];
  }

  static bool isFinalGrade(String grade) =>
      SchoolConstants.grades.isNotEmpty && SchoolConstants.grades.last == grade;

  /// Default per-student decision for active students in [sourceGrade].
  static PromotionDecision defaultDecision(SchoolStudent s, {required String targetYear}) {
    final already = s.academicYear.trim() == targetYear.trim();
    if (already) {
      return PromotionDecision(
        studentId: s.id,
        action: PromotionAction.skip,
        targetSection: s.section.isEmpty ? 'A' : s.section,
        targetGroup: s.academicGroup.isEmpty ? 'General' : s.academicGroup,
      );
    }
    final next = nextGradeOf(s.grade);
    final targetGrade = next ?? s.grade;
    final groups = SchoolConstants.getAcademicGroupsForGrade(targetGrade);
    final group = groups.contains(s.academicGroup) ? s.academicGroup : groups.first;
    return PromotionDecision(
      studentId: s.id,
      action: next == null ? PromotionAction.graduate : PromotionAction.promote,
      targetSection: SchoolConstants.sections.contains(s.section) ? s.section : SchoolConstants.sections.first,
      targetGroup: group,
    );
  }

  /// Builds the exact preview plan with collision-free target roll numbers.
  ///
  /// Existing students who are ALREADY in [targetYear] keep their roll numbers;
  /// promoted and held-back students receive the next free sequential roll
  /// numbers per target `(grade, section, targetYear)`, ordered by current roll
  /// number then name.
  static List<PromotionPlanRow> buildPlan({
    required List<SchoolStudent> candidates,
    required Iterable<SchoolStudent> allStudents,
    required Map<String, PromotionDecision> decisions,
    required String targetYear,
  }) {
    final ordered = [...candidates]..sort((a, b) {
        final sec = a.section.compareTo(b.section);
        if (sec != 0) return sec;
        final ra = int.tryParse(a.rollNo) ?? 99999;
        final rb = int.tryParse(b.rollNo) ?? 99999;
        if (ra != rb) return ra.compareTo(rb);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    // Track highest numeric roll already taken in each (grade, section) for targetYear.
    final maxRoll = <String, int>{};
    String bucketKey(String grade, String sec) => '$grade|$sec';
    for (final s in allStudents) {
      if (s.isVoid) continue;
      if (s.status != 'active' && s.status != 'suspended') continue;
      if (s.academicYear.trim() != targetYear.trim()) continue;
      final n = int.tryParse(s.rollNo.trim()) ?? 0;
      final k = bucketKey(s.grade, s.section);
      if (n > (maxRoll[k] ?? 0)) maxRoll[k] = n;
    }

    final rows = <PromotionPlanRow>[];
    for (final s in ordered) {
      final d = decisions[s.id] ?? defaultDecision(s, targetYear: targetYear);
      final already = s.academicYear.trim() == targetYear.trim();
      final nextGrade = nextGradeOf(s.grade);

      // Guard: cannot promote beyond the final class; coerce to graduate.
      final effectiveAction = (d.action == PromotionAction.promote && nextGrade == null)
          ? PromotionAction.graduate
          : d.action;

      final targetGrade = switch (effectiveAction) {
        PromotionAction.promote => nextGrade!,
        PromotionAction.holdBack => s.grade,
        PromotionAction.graduate => s.grade,
        PromotionAction.skip => s.grade,
      };
      final targetSection = SchoolConstants.sections.contains(d.targetSection)
          ? d.targetSection
          : (SchoolConstants.sections.contains(s.section) ? s.section : SchoolConstants.sections.first);
      final allowedGroups = SchoolConstants.getAcademicGroupsForGrade(targetGrade);
      final targetGroup = allowedGroups.contains(d.targetGroup) ? d.targetGroup : allowedGroups.first;

      String targetRoll;
      if (effectiveAction == PromotionAction.promote || effectiveAction == PromotionAction.holdBack) {
        final k = bucketKey(targetGrade, targetSection);
        final nextRoll = (maxRoll[k] ?? 0) + 1;
        maxRoll[k] = nextRoll;
        targetRoll = '$nextRoll';
      } else {
        targetRoll = s.rollNo;
      }

      rows.add(PromotionPlanRow(
        student: s,
        action: effectiveAction,
        targetGrade: targetGrade,
        targetSection: targetSection,
        targetGroup: targetGroup,
        targetRollNo: targetRoll,
        alreadyInTargetYear: already,
      ));
    }
    return rows;
  }

  static String? validateTargetYear(String targetYear) {
    final trimmed = targetYear.trim();
    if (!_yearPattern.hasMatch(trimmed)) {
      return 'Academic year must look like 2027-28.';
    }
    final m = _yearPattern.firstMatch(trimmed)!;
    final y1 = int.parse(m.group(1)!);
    final y2 = int.parse(m.group(2)!);
    if ((y1 + 1) % 100 != y2) {
      return 'End year must follow start year (e.g. $y1-${((y1 + 1) % 100).toString().padLeft(2, '0')}).';
    }
    return null;
  }
}
