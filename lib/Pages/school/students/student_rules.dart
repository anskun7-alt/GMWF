// lib/pages/school/students/student_rules.dart
//
// School student rules (School ERP plan §3.3, Phase 2, 2026-11-17). Pure
// functions, no storage, so they are easy to test:
//   • status lifecycle with effective dates (no delete; "entered by mistake" = void)
//   • academic year from a date
//   • admission numbers (unique per branch) and roll numbers (per class-section-year)
//   • duplicate and sibling detection
//   • field validation
//
// The madrassa module has its own, separate rules; nothing here is shared with it.

import '../core/school_branch_id.dart';
import '../models/school_student.dart';

/// Student statuses. Stored as the enum name, except [voided] → "void".
enum StudentStatus {
  active('active', 'Active'),
  suspended('suspended', 'Suspended'),
  left('left', 'Left'),
  graduated('graduated', 'Graduated'),
  voided('void', 'Entered by mistake');

  const StudentStatus(this.value, this.label);
  final String value;
  final String label;

  static StudentStatus parse(String? raw) {
    final v = SchoolStudent.normalizeStatus(raw);
    return StudentStatus.values.firstWhere((s) => s.value == v, orElse: () => StudentStatus.active);
  }

  /// Name of the action that moves a student INTO this status.
  String actionFrom(StudentStatus from) => switch (this) {
        StudentStatus.active => switch (from) {
            StudentStatus.suspended => 'Lift suspension',
            StudentStatus.left => 'Rejoin',
            StudentStatus.voided => 'Restore record',
            StudentStatus.graduated => 'Undo graduation',
            StudentStatus.active => 'Active',
          },
        StudentStatus.suspended => 'Suspend',
        StudentStatus.left => 'Mark as left',
        StudentStatus.graduated => 'Mark graduated',
        StudentStatus.voided => 'Entered by mistake',
      };

  /// Whether a reason must be typed for this change.
  bool get needsReason => this != StudentStatus.active;
}

abstract final class StudentRules {
  // ── Status lifecycle ──────────────────────────────────────────────────────

  static const Map<StudentStatus, Set<StudentStatus>> _transitions = {
    StudentStatus.active: {StudentStatus.suspended, StudentStatus.left, StudentStatus.graduated, StudentStatus.voided},
    StudentStatus.suspended: {StudentStatus.active, StudentStatus.left, StudentStatus.voided},
    StudentStatus.left: {StudentStatus.active, StudentStatus.voided},
    StudentStatus.graduated: {StudentStatus.active, StudentStatus.voided},
    StudentStatus.voided: {StudentStatus.active},
  };

  /// Statuses a student in [from] can move to. Restoring a voided record and
  /// undoing a graduation are Principal / School Admin only.
  static List<StudentStatus> nextStatuses(StudentStatus from, {required bool isPrincipal}) {
    final out = _transitions[from]!.toList();
    if (!isPrincipal && (from == StudentStatus.voided || from == StudentStatus.graduated)) {
      out.remove(StudentStatus.active);
    }
    return out;
  }

  /// Null when the change is allowed, otherwise the reason it is not.
  static String? validateStatusChange({
    required SchoolStudent student,
    required StudentStatus to,
    required DateTime effectiveDate,
    required String reason,
    required bool isPrincipal,
    required DateTime now,
  }) {
    final from = StudentStatus.parse(student.status);
    if (from == to) return 'The student is already ${to.label.toLowerCase()}.';
    if (!nextStatuses(from, isPrincipal: isPrincipal).contains(to)) {
      return 'A ${from.label.toLowerCase()} student cannot be changed to ${to.label.toLowerCase()}'
          '${isPrincipal ? '' : ' (Principal only)'}.';
    }
    final day = _day(effectiveDate);
    if (day.isAfter(_day(now).add(const Duration(days: 31)))) {
      return 'The effective date can be at most one month ahead.';
    }
    final admitted = DateTime.tryParse(student.admissionDate);
    if (admitted != null && day.isBefore(_day(admitted)) && to != StudentStatus.voided) {
      return 'The effective date is before the admission date (${student.admissionDate}).';
    }
    final lastChange = student.statusHistory.isEmpty ? null : DateTime.tryParse(student.statusHistory.last.effectiveDate);
    if (lastChange != null && day.isBefore(_day(lastChange))) {
      return 'The effective date is before the last status change (${student.statusHistory.last.effectiveDate}).';
    }
    if (to.needsReason && reason.trim().isEmpty) return 'Please write a reason.';
    return null;
  }

  /// Whether the student counted as enrolled on [day], replaying the status
  /// history (used later for fee proration and attendance rosters).
  static bool isActiveOn(SchoolStudent s, DateTime day) {
    final d = _day(day);
    final admitted = DateTime.tryParse(s.admissionDate);
    if (admitted != null && d.isBefore(_day(admitted))) return false;
    if (StudentStatus.parse(s.status) == StudentStatus.voided) return false;
    var status = StudentStatus.active;
    final history = [...s.statusHistory]..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
    if (history.isEmpty) return StudentStatus.parse(s.status) == StudentStatus.active || _before(s.statusDate, d);
    for (final h in history) {
      final at = DateTime.tryParse(h.effectiveDate);
      if (at == null || _day(at).isAfter(d)) break;
      status = StudentStatus.parse(h.to);
    }
    return status == StudentStatus.active;
  }

  static bool _before(String date, DateTime d) {
    final at = DateTime.tryParse(date);
    return at != null && d.isBefore(_day(at));
  }

  // ── Academic year ─────────────────────────────────────────────────────────

  /// Month the school year starts (Punjab schools: April).
  static const int yearStartMonth = 4;

  /// "2026-27" for any date from 1 April 2026 to 31 March 2027.
  static String academicYearOf(DateTime d) {
    final start = d.month >= yearStartMonth ? d.year : d.year - 1;
    return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
  }

  // ── Admission & roll numbers ──────────────────────────────────────────────

  static const Map<String, String> _branchCodes = {
    'gujrat': 'GRT',
    'sialkot': 'SKT',
    'rawalpindi': 'RWP',
    'karachi': 'KHI',
    'lahore': 'LHR',
    'islamabad': 'ISB',
  };

  static String branchCode(String branchId) {
    final b = SchoolBranchId.normalize(branchId);
    final code = _branchCodes[b];
    if (code != null) return code;
    final letters = b.replaceAll(RegExp('[^a-z]'), '').toUpperCase();
    return letters.isEmpty ? 'SCH' : letters.padRight(3, 'X').substring(0, 3);
  }

  static final RegExp _admPattern = RegExp(r'^([A-Z]{3})-(\d+)$');

  /// Next admission number for the branch: `GRT-0001`, `GRT-0002`, …
  /// Older typed numbers (e.g. "101") are left alone and do not affect the series.
  static String nextAdmissionNo(String branchId, Iterable<SchoolStudent> students) {
    final code = branchCode(branchId);
    var max = 0;
    for (final s in students) {
      final m = _admPattern.firstMatch(s.admissionNo.trim().toUpperCase());
      if (m != null && m.group(1) == code) {
        final n = int.parse(m.group(2)!);
        if (n > max) max = n;
      }
    }
    return '$code-${(max + 1).toString().padLeft(4, '0')}';
  }

  /// Other (non-void) students using [admissionNo]. Case and spaces ignored.
  static List<SchoolStudent> admissionNoTakenBy(String admissionNo, Iterable<SchoolStudent> students, {String? exceptId}) {
    final key = _norm(admissionNo);
    if (key.isEmpty) return const [];
    return students.where((s) => s.id != exceptId && !s.isVoid && _norm(s.admissionNo) == key).toList();
  }

  /// Students sharing an admission number (two devices offline can issue the
  /// same next number; the list screen shows these so one can be corrected).
  static Map<String, List<SchoolStudent>> admissionNoConflicts(Iterable<SchoolStudent> students) {
    final by = <String, List<SchoolStudent>>{};
    for (final s in students) {
      if (s.isVoid) continue;
      final k = _norm(s.admissionNo);
      if (k.isEmpty) continue;
      (by[k] ??= []).add(s);
    }
    by.removeWhere((_, v) => v.length < 2);
    return by;
  }

  static bool _inClass(SchoolStudent s, String grade, String section, String year) =>
      s.grade == grade &&
      s.section == section &&
      (s.academicYear.isEmpty || year.isEmpty || s.academicYear == year) &&
      (s.status == 'active' || s.status == 'suspended');

  /// Next free roll number in the class-section for the year (1, 2, 3 …).
  static String suggestRollNo(Iterable<SchoolStudent> students, {required String grade, required String section, required String academicYear, String? exceptId}) {
    var max = 0;
    for (final s in students) {
      if (s.id == exceptId || !_inClass(s, grade, section, academicYear)) continue;
      final n = int.tryParse(s.rollNo.trim());
      if (n != null && n > max) max = n;
    }
    return '${max + 1}';
  }

  /// The student already using [rollNo] in that class-section-year, if any.
  static SchoolStudent? rollNoTakenBy(String rollNo, Iterable<SchoolStudent> students, {required String grade, required String section, required String academicYear, String? exceptId}) {
    final key = _norm(rollNo);
    if (key.isEmpty) return null;
    for (final s in students) {
      if (s.id != exceptId && _inClass(s, grade, section, academicYear) && _norm(s.rollNo) == key) return s;
    }
    return null;
  }

  // ── Duplicates & siblings ─────────────────────────────────────────────────

  static String digits(String v) => v.replaceAll(RegExp(r'\D'), '');
  static String _norm(String v) => v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Existing (non-void) students that look like the same child as [candidate].
  static List<StudentMatch> duplicatesOf(SchoolStudent candidate, Iterable<SchoolStudent> students) {
    final out = <StudentMatch>[];
    final bform = digits(candidate.bformNo);
    final cnic = digits(candidate.guardianCnic);
    final name = _norm(candidate.name);
    final father = _norm(candidate.guardianName);
    for (final s in students) {
      if (s.id == candidate.id || s.isVoid) continue;
      if (bform.length >= 13 && digits(s.bformNo) == bform) {
        out.add(StudentMatch(s, 'Same B-Form number ($bform)'));
      } else if (cnic.length >= 13 && digits(s.guardianCnic) == cnic && _norm(s.name) == name) {
        out.add(StudentMatch(s, "Same name and father's CNIC"));
      } else if (name.isNotEmpty &&
          _norm(s.name) == name &&
          _norm(s.guardianName) == father &&
          candidate.dob.isNotEmpty &&
          s.dob == candidate.dob) {
        out.add(StudentMatch(s, "Same name, father's name and date of birth"));
      }
    }
    return out;
  }

  /// Brothers and sisters: same father's CNIC, or (when no CNIC) the same
  /// father's name and phone. Void records are left out.
  static List<SchoolStudent> siblingsOf(SchoolStudent student, Iterable<SchoolStudent> students) {
    final cnic = digits(student.guardianCnic);
    final phone = digits(student.guardianPhone);
    final father = _norm(student.guardianName);
    return students.where((s) {
      if (s.id == student.id || s.isVoid) return false;
      if (cnic.length >= 13) return digits(s.guardianCnic) == cnic;
      return father.isNotEmpty && phone.length >= 10 && _norm(s.guardianName) == father && digits(s.guardianPhone) == phone;
    }).toList();
  }

  // ── Validation ────────────────────────────────────────────────────────────

  /// Field problems, keyed by field name. Empty map = valid.
  static Map<String, String> validate(SchoolStudent s, {required DateTime now}) {
    final e = <String, String>{};
    if (s.name.trim().isEmpty) e['name'] = 'Student name is required';
    if (s.guardianName.trim().isEmpty) e['guardianName'] = "Father's / guardian name is required";
    final phone = digits(s.guardianPhone);
    if (phone.length != 11) e['guardianPhone'] = 'Phone number must be exactly 11 digits';
    final cnic = digits(s.guardianCnic);
    if (cnic.isNotEmpty && cnic.length != 13) e['guardianCnic'] = 'CNIC must have 13 digits';
    final bform = digits(s.bformNo);
    if (bform.isNotEmpty && bform.length != 13) e['bformNo'] = 'B-Form number must have 13 digits';
    final ec = digits(s.emergencyContact);
    if (ec.isNotEmpty && ec.length != 11) e['emergencyContact'] = 'Emergency contact must be 11 digits';
    if (s.admissionNo.trim().isEmpty) e['admissionNo'] = 'Admission number is required';
    if (s.rollNo.trim().isEmpty) e['rollNo'] = 'Roll number is required';
    final dob = DateTime.tryParse(s.dob);
    final admitted = DateTime.tryParse(s.admissionDate);
    if (dob != null) {
      if (dob.isAfter(now)) {
        e['dob'] = 'Date of birth cannot be in the future';
      } else if (admitted != null && admitted.difference(dob).inDays < 365 * 2) {
        e['dob'] = 'The student would be under 2 years old at admission';
      }
    }
    if (admitted == null) {
      e['admissionDate'] = 'Admission date is required';
    } else if (_day(admitted).isAfter(_day(now).add(const Duration(days: 60)))) {
      e['admissionDate'] = 'Admission date is too far in the future';
    }
    return e;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
}

/// An existing student that looks like the one being saved.
class StudentMatch {
  final SchoolStudent student;
  final String reason;
  const StudentMatch(this.student, this.reason);
}
