// lib/pages/school/utils/school_auth_helper.dart
//
// Role checks for the School screens. Since Phase 5 (2026-11-17) every check
// goes through the one rule in core/school_roles.dart:
//   • an unknown role gets no access (it used to get everything);
//   • "admin" only counts as School admin when the role says School;
//   • a teacher's record is found by user id / username / email / employee id,
//     or an exact name only when no other teacher shares it (never a partial name).

import '../constants/school_constants.dart';
import '../core/school_roles.dart';
import 'school_local_storage.dart';

class SchoolAuthHelper {
  static SchoolRole roleOf(String role) => SchoolRoles.resolve(role);

  /// Chairman, HQ Manager, CEO, system admin, managers.
  static bool isHighestAuthority(String role) => roleOf(role) == SchoolRole.executive;

  /// School admin (not any other kind of admin).
  static bool isSchoolAdmin(String role) => roleOf(role) == SchoolRole.schoolAdmin;

  static bool isPrincipal(String role) => roleOf(role) == SchoolRole.principal;

  /// Full School access: executive, principal or school admin.
  static bool isAdminOrPrincipal(String role) => SchoolRoles.isManager(roleOf(role));

  static bool isTeacher(String role) => roleOf(role) == SchoolRole.teacher;
  static bool isAccountant(String role) => roleOf(role) == SchoolRole.accountant;
  static bool isLibrarian(String role) => roleOf(role) == SchoolRole.librarian;

  /// No School role at all: no access.
  static bool hasNoAccess(String role) => roleOf(role) == SchoolRole.none;

  /// The teacher record of the signed-in user. [userNameOrEmail] is what the
  /// screen knows about the user; the login's id, username and email are added.
  static Map<String, dynamic>? findTeacherRecord(String branchId, String userNameOrEmail) {
    final me = SchoolUserIdentity.current(fallbackName: userNameOrEmail);
    final extra = userNameOrEmail.trim().toLowerCase();
    final identity = SchoolUserIdentity(ids: {...me.ids, if (extra.isNotEmpty) extra}, name: me.name);
    return identity.matchTeacher(SchoolLocalStorage.getAllTeachersCached(branchId));
  }

  /// The teacher's classes (homeroom + assigned). Empty for managers, meaning
  /// "all classes". Empty for a teacher with no matching record, meaning none.
  static List<String> getTeacherAssignedGrades(String branchId, String role, String userNameOrEmail) {
    if (isAdminOrPrincipal(role)) return [];
    final teacher = findTeacherRecord(branchId, userNameOrEmail);
    if (teacher == null) return [];
    final grades = <String>{};
    final homeroom = (teacher['homeroomGrade'] ?? '').toString().trim();
    if (homeroom.isNotEmpty) grades.add(homeroom);
    if (teacher['assignedGrades'] is List) {
      for (final g in teacher['assignedGrades']) {
        final gs = g.toString().trim();
        if (gs.isNotEmpty) grades.add(gs);
      }
    }
    return grades.toList();
  }

  /// The teacher's subjects. Empty for managers, meaning "all subjects".
  static List<String> getTeacherAssignedSubjects(String branchId, String role, String userNameOrEmail) {
    if (isAdminOrPrincipal(role)) return [];
    final teacher = findTeacherRecord(branchId, userNameOrEmail);
    if (teacher == null) return [];
    final subjects = <String>{};
    if (teacher['subjects'] is List) {
      for (final s in teacher['subjects']) {
        final ss = s.toString().trim();
        if (ss.isNotEmpty) subjects.add(ss);
      }
    }
    return subjects.toList();
  }

  /// Can this user open [grade]? Managers: any. Teachers: only their own
  /// classes, found through their own teacher record.
  static bool canAccessGrade(String branchId, String role, String userNameOrEmail, String grade) {
    if (isAdminOrPrincipal(role)) return true;
    if (!isTeacher(role) || grade == 'All') return false;
    final normalized = grade.toLowerCase().trim();
    final assigned = getTeacherAssignedGrades(branchId, role, userNameOrEmail);
    if (assigned.any((g) => g.toLowerCase().trim() == normalized)) return true;
    // A homeroom assignment in any configured section that names this teacher's record.
    final teacher = findTeacherRecord(branchId, userNameOrEmail);
    if (teacher == null) return false;
    final teacherId = (teacher['id'] ?? '').toString().trim();
    if (teacherId.isEmpty) return false;
    for (final sec in SchoolConstants.sections) {
      final hr = SchoolLocalStorage.getHomeroomAssignmentCached(branchId, grade, sec);
      final hrTeacher = (hr?['teacherId'] ?? '').toString().trim();
      if (hrTeacher.isNotEmpty && hrTeacher == teacherId) return true;
    }
    return false;
  }

  /// Can this user enter marks for [subject]? Managers: any. Teachers: their
  /// subjects, or any subject of their own class when none are listed.
  static bool canAccessSubject(String branchId, String role, String userNameOrEmail, String subject) {
    if (isAdminOrPrincipal(role)) return true;
    if (!isTeacher(role)) return false;
    final assigned = getTeacherAssignedSubjects(branchId, role, userNameOrEmail);
    if (assigned.isEmpty) return findTeacherRecord(branchId, userNameOrEmail) != null;
    final normalized = subject.toLowerCase().trim();
    return assigned.any((s) => s.toLowerCase().trim() == normalized);
  }
}
