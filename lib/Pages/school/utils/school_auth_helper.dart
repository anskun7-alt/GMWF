// lib/pages/school/utils/school_auth_helper.dart

import 'school_local_storage.dart';

/// Centralized role authorization and data isolation helper for Taleem-wa-Tarbiyat School modules.
/// Enforces:
/// 1. Chairman and HQ Manager are the highest authority (unrestricted access across all school data).
/// 2. Teachers can only see their own assigned classes, assigned subjects, and their own teacher record.
/// 3. One teacher cannot see another teacher's profile/attendance/salary/grading data.
/// 4. Teachers cannot see Admin or Principal data (fees, financial summaries, principal dashboard, audit trail).
class SchoolAuthHelper {
  /// Returns true if the user has highest executive authority (Chairman, HQ Manager, CEO, Superadmin, Global Admin).
  static bool isHighestAuthority(String role) {
    final r = role.toLowerCase().trim();
    return r == 'chairman' ||
        r.contains('chairman') ||
        r == 'hq manager' ||
        r == 'hq_manager' ||
        r.contains('hq manager') ||
        r.contains('hq_manager') ||
        r == 'ceo' ||
        r == 'admin' ||
        r == 'superadmin' ||
        r == 'super_admin' ||
        r == 'global admin' ||
        r == 'global_admin' ||
        r == 'master admin';
  }

  /// Returns true if the user is an Administrator or Principal (or highest executive).
  static bool isAdminOrPrincipal(String role) {
    if (isHighestAuthority(role)) return true;
    final r = role.toLowerCase().trim();
    return r.contains('principal') ||
        r.contains('school admin') ||
        r.contains('school_admin') ||
        r == 'school' ||
        r == 'headmaster' ||
        r == 'headmistress' ||
        r.contains('headmaster') ||
        r.contains('headmistress');
  }

  /// Returns true only if the user is purely a teacher (not admin, not principal, not chairman).
  static bool isTeacher(String role) {
    if (isAdminOrPrincipal(role)) return false;
    final r = role.toLowerCase().trim();
    return r.contains('teacher');
  }

  /// Finds the teacher's cached record by matching name or email.
  static Map<String, dynamic>? findTeacherRecord(String branchId, String userNameOrEmail) {
    final query = userNameOrEmail.toLowerCase().trim();
    if (query.isEmpty) return null;

    final teachers = SchoolLocalStorage.getAllTeachersCached(branchId);
    for (final t in teachers) {
      final name = (t['name'] ?? '').toString().toLowerCase().trim();
      final email = (t['email'] ?? '').toString().toLowerCase().trim();
      final empId = (t['employeeId'] ?? '').toString().toLowerCase().trim();
      final id = (t['id'] ?? '').toString().toLowerCase().trim();

      if (name == query ||
          email == query ||
          empId == query ||
          id == query ||
          (query.contains('@') && email == query)) {
        return t;
      }
    }

    // Secondary partial matching if exact match not found
    for (final t in teachers) {
      final name = (t['name'] ?? '').toString().toLowerCase().trim();
      if (name.isNotEmpty && (name.contains(query) || query.contains(name))) {
        return t;
      }
    }

    return null;
  }

  /// Returns the assigned grades for a teacher.
  /// If admin/principal/chairman, returns an empty list meaning "no restriction / all grades".
  static List<String> getTeacherAssignedGrades(String branchId, String role, String userNameOrEmail) {
    if (isAdminOrPrincipal(role)) return [];

    final teacher = findTeacherRecord(branchId, userNameOrEmail);
    if (teacher == null) return [];

    final grades = <String>{};
    final homeroom = (teacher['homeroomGrade'] ?? '').toString().trim();
    if (homeroom.isNotEmpty) {
      grades.add(homeroom);
    }

    if (teacher['assignedGrades'] is List) {
      for (final g in teacher['assignedGrades']) {
        final gs = g.toString().trim();
        if (gs.isNotEmpty) grades.add(gs);
      }
    }

    return grades.toList();
  }

  /// Returns the assigned subjects for a teacher.
  /// If admin/principal/chairman, returns an empty list meaning "all subjects".
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

  /// Checks if the user is authorized to view or edit a specific class grade.
  static bool canAccessGrade(String branchId, String role, String userNameOrEmail, String grade) {
    if (isAdminOrPrincipal(role)) return true;
    if (grade == 'All') return false; // Teachers can only view specific assigned class

    final assigned = getTeacherAssignedGrades(branchId, role, userNameOrEmail);
    if (assigned.isEmpty) {
      // Fallback: Check if teacher name is assigned in homeroom box directly
      final hr = SchoolLocalStorage.getHomeroomAssignmentCached(branchId, grade, 'A');
      final assignedName = (hr?['teacherName'] ?? '').toString().toLowerCase().trim();
      if (assignedName.isNotEmpty && assignedName == userNameOrEmail.toLowerCase().trim()) {
        return true;
      }
      return false;
    }

    final normalized = grade.toLowerCase().trim();
    return assigned.any((g) => g.toLowerCase().trim() == normalized);
  }

  /// Checks if the user is authorized to view or edit marks for a specific subject.
  static bool canAccessSubject(String branchId, String role, String userNameOrEmail, String subject) {
    if (isAdminOrPrincipal(role)) return true;

    final assigned = getTeacherAssignedSubjects(branchId, role, userNameOrEmail);
    if (assigned.isEmpty) return true; // If no specific subjects configured, allow assigned grade subjects

    final normalized = subject.toLowerCase().trim();
    return assigned.any((s) => s.toLowerCase().trim() == normalized);
  }
}
