// lib/pages/school/grades/grade_rules.dart
//
// Pure grading & report-card rules (School ERP plan §3.6, Phase 5):
//   • validation (0 <= marks <= totalMarks, positive totalMarks)
//   • deterministic IDs per student + subject + exam + term
//   • single-attachment metadata model (stored once per exam, not per student)
//   • class summary stats (average, highest, lowest, pass rate)
//   • student term report & class ranking

import '../events/event_models.dart';
import '../models/school_grade.dart';
import '../models/school_student.dart';

/// Exam marksheet / document stored ONCE per assessment (`school_grade_attachments`).
class SchoolGradeAttachment {
  final String id;
  final String grade;
  final String section;
  final String subject;
  final String examType;
  final String term;
  final String fileName;
  final String fileType; // excel | pdf | image
  final String dataUri;
  final bool active;
  final String uploadedBy;
  final String uploadedAt;

  const SchoolGradeAttachment({
    required this.id,
    required this.grade,
    required this.section,
    required this.subject,
    required this.examType,
    required this.term,
    required this.fileName,
    required this.fileType,
    required this.dataUri,
    this.active = true,
    this.uploadedBy = '',
    this.uploadedAt = '',
  });

  factory SchoolGradeAttachment.fromMap(String id, Map m) => SchoolGradeAttachment(
        id: id,
        grade: (m['grade'] ?? '').toString(),
        section: (m['section'] ?? 'A').toString(),
        subject: (m['subject'] ?? '').toString(),
        examType: (m['examType'] ?? '').toString(),
        term: (m['term'] ?? '').toString(),
        fileName: (m['fileName'] ?? '').toString(),
        fileType: (m['fileType'] ?? '').toString(),
        dataUri: (m['dataUri'] ?? '').toString(),
        active: m['active'] != false,
        uploadedBy: (m['uploadedBy'] ?? '').toString(),
        uploadedAt: (m['uploadedAt'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'grade': grade,
        'section': section,
        'subject': subject,
        'examType': examType,
        'term': term,
        'fileName': fileName,
        'fileType': fileType,
        'dataUri': dataUri,
        'active': active,
        'uploadedBy': uploadedBy,
        'uploadedAt': uploadedAt,
      };
}

class ClassExamStats {
  final int totalStudents;
  final int gradedCount;
  final double averagePct;
  final double highestPct;
  final double lowestPct;
  final int passCount;
  final double passRate;

  const ClassExamStats({
    required this.totalStudents,
    required this.gradedCount,
    required this.averagePct,
    required this.highestPct,
    required this.lowestPct,
    required this.passCount,
    required this.passRate,
  });
}

class StudentTermReport {
  final SchoolStudent student;
  final String term;
  final List<SchoolGrade> grades;
  final double totalObtained;
  final double totalPossible;
  final double percentage;
  final String letterGrade;
  final double gpa;
  final int? rank;
  final int classSize;
  final StudentEventSummary events;

  const StudentTermReport({
    required this.student,
    required this.term,
    required this.grades,
    required this.totalObtained,
    required this.totalPossible,
    required this.percentage,
    required this.letterGrade,
    required this.gpa,
    required this.rank,
    required this.classSize,
    required this.events,
  });

  bool get hasGrades => grades.isNotEmpty;
  bool get passed => hasGrades && percentage >= GradeRules.passPercent;
}

class GradeEntryInput {
  final SchoolStudent student;
  final double marksObtained;
  final String remarks;

  const GradeEntryInput({
    required this.student,
    required this.marksObtained,
    this.remarks = '',
  });
}

abstract final class GradeRules {
  static const double passPercent = 50.0;
  static const List<String> examTypes = ['Quiz', 'Assignment', 'Midterm', 'Final'];
  static const List<String> terms = ['Term 1', 'Term 2', 'Final Term'];

  static String slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');

  /// Stable deterministic document ID per student + subject + exam + term.
  static String gradeDocId({
    required String studentId,
    required String subject,
    required String examType,
    required String term,
  }) =>
      'GRD-$studentId-${slug(subject)}-${slug(examType)}-${slug(term)}';

  /// Stable deterministic document ID for the single exam-level attachment.
  static String attachmentDocId({
    required String grade,
    required String section,
    required String subject,
    required String examType,
    required String term,
  }) =>
      'ATT-${slug(grade)}-${slug(section)}-${slug(subject)}-${slug(examType)}-${slug(term)}';

  static double percentageOf(double obtained, double total) =>
      total > 0 ? (obtained / total) * 100.0 : 0.0;

  static String letterOf(double pct) {
    if (pct >= 90) return 'A+';
    if (pct >= 80) return 'A';
    if (pct >= 70) return 'B';
    if (pct >= 60) return 'C';
    if (pct >= 50) return 'D';
    return 'F';
  }

  static double gpaOf(double pct) {
    if (pct >= 90) return 4.0;
    if (pct >= 80) return 3.7;
    if (pct >= 70) return 3.0;
    if (pct >= 60) return 2.0;
    if (pct >= 50) return 1.0;
    return 0.0;
  }

  /// Null when valid, otherwise an error message.
  static String? validateMark({required double? obtained, required double totalMarks}) {
    if (totalMarks <= 0) return 'Total marks must be greater than 0.';
    if (obtained == null) return 'Enter a valid number.';
    if (obtained < 0) return 'Marks cannot be negative.';
    if (obtained > totalMarks) {
      return 'Marks (${formatMark(obtained)}) cannot exceed total (${formatMark(totalMarks)}).';
    }
    return null;
  }

  static String formatMark(double v) => v.truncateToDouble() == v ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static ClassExamStats summarizeExam({
    required int totalStudents,
    required Iterable<SchoolGrade> examGrades,
  }) {
    var sumPct = 0.0;
    var graded = 0;
    var highest = 0.0;
    var lowest = 100.0;
    var pass = 0;

    for (final g in examGrades) {
      if (g.totalMarks <= 0) continue;
      final pct = g.percentage;
      sumPct += pct;
      graded++;
      if (pct > highest) highest = pct;
      if (pct < lowest) lowest = pct;
      if (pct >= passPercent) pass++;
    }

    return ClassExamStats(
      totalStudents: totalStudents,
      gradedCount: graded,
      averagePct: graded > 0 ? sumPct / graded : 0.0,
      highestPct: graded > 0 ? highest : 0.0,
      lowestPct: graded > 0 ? lowest : 0.0,
      passCount: pass,
      passRate: graded > 0 ? (pass / graded) * 100.0 : 0.0,
    );
  }

  /// Builds ranked term reports for every student in [students].
  /// Students with the same percentage share the same rank (standard competition
  /// ranking: 1, 2, 2, 4). Students with no grades yet get `rank: null`.
  static List<StudentTermReport> buildTermReports({
    required List<SchoolStudent> students,
    required Iterable<SchoolGrade> allGrades,
    required Iterable<SchoolEvent> allEvents,
    required String term,
    String? examTypeFilter,
  }) {
    final byStudent = <String, List<SchoolGrade>>{};
    for (final g in allGrades) {
      if (g.term != term) continue;
      if (examTypeFilter != null && examTypeFilter != 'All' && g.examType != examTypeFilter) continue;
      (byStudent[g.studentId] ??= []).add(g);
    }

    final raw = <({
      SchoolStudent student,
      List<SchoolGrade> grades,
      double obtained,
      double possible,
      double pct,
      double gpa,
      StudentEventSummary events,
    })>[];

    for (final s in students) {
      final list = (byStudent[s.id] ?? const <SchoolGrade>[]).toList()
        ..sort((a, b) {
          final sub = a.subject.compareTo(b.subject);
          return sub != 0 ? sub : a.examType.compareTo(b.examType);
        });
      final obt = list.fold<double>(0.0, (acc, g) => acc + g.marksObtained);
      final pos = list.fold<double>(0.0, (acc, g) => acc + g.totalMarks);
      final pct = percentageOf(obt, pos);
      final gpa = list.isEmpty ? 0.0 : list.fold<double>(0.0, (acc, g) => acc + g.gpaPoint) / list.length;
      final events = StudentEventSummary.forStudent(s, allEvents, academicYear: s.academicYear);
      raw.add((student: s, grades: list, obtained: obt, possible: pos, pct: pct, gpa: gpa, events: events));
    }

    // Compute ranks among graded students in this group.
    final graded = raw.where((r) => r.grades.isNotEmpty).toList()..sort((a, b) => b.pct.compareTo(a.pct));
    final ranks = <String, int>{};
    for (var i = 0; i < graded.length; i++) {
      if (i > 0 && (graded[i].pct - graded[i - 1].pct).abs() < 0.001) {
        ranks[graded[i].student.id] = ranks[graded[i - 1].student.id]!;
      } else {
        ranks[graded[i].student.id] = i + 1;
      }
    }

    return [
      for (final r in raw)
        StudentTermReport(
          student: r.student,
          term: term,
          grades: r.grades,
          totalObtained: r.obtained,
          totalPossible: r.possible,
          percentage: r.pct,
          letterGrade: r.grades.isEmpty ? '—' : letterOf(r.pct),
          gpa: r.gpa,
          rank: ranks[r.student.id],
          classSize: graded.length,
          events: r.events,
        ),
    ];
  }
}
