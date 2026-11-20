// lib/pages/school/core/school_roles.dart
//
// The one School role rule (School ERP plan §3, Phase 5 roles hardening,
// 2026-11-17). Every School screen asks this instead of matching role text.
//
//   executive   Chairman, HQ Manager, CEO, system admin, managers: everything
//   principal   Principal / Headmaster / Headmistress / Vice principal: everything
//   schoolAdmin School admin: everything
//   accountant  Fees only
//   librarian   Library only
//   teacher     Own class: daily log, grades, class list (read-only), library
//   none        Unknown role: no access (was: full access)
//
// Matching is exact on whole words, so "Madrassa admin" or "Finance admin" are
// not School admins any more.

import '../../../services/local_storage_service.dart';
import '../utils/school_local_storage.dart';

enum SchoolRole { executive, principal, schoolAdmin, accountant, librarian, teacher, none }

/// The School pages, in the executive order (index = the app's section index).
enum SchoolPage { dashboard, students, dailyLog, staffAttendance, teachers, fees, library, grades, audit }

abstract final class SchoolRoles {
  static const _executive = {
    'chairman',
    'ceo',
    'hq manager',
    'admin',
    'super admin',
    'superadmin',
    'global admin',
    'master admin',
    'global user',
    'manager',
    'branch manager',
    'supervisor',
  };

  static String _norm(String role) => role.toLowerCase().replaceAll(RegExp(r'[_\-]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _word(String r, String w) => RegExp('(^| )${RegExp.escape(w)}( |\$)').hasMatch(r);

  static SchoolRole resolve(String role) {
    final r = _norm(role);
    if (r.isEmpty) return SchoolRole.none;
    if (_word(r, 'principal') || _word(r, 'headmaster') || _word(r, 'headmistress')) return SchoolRole.principal;
    if (r == 'school' || r == 'school admin' || r == 'school administrator') return SchoolRole.schoolAdmin;
    if (_word(r, 'accountant')) return SchoolRole.accountant;
    if (_word(r, 'librarian')) return SchoolRole.librarian;
    if (_word(r, 'teacher')) return SchoolRole.teacher;
    if (_executive.contains(r) || _word(r, 'chairman') || r.contains('hq manager')) return SchoolRole.executive;
    return SchoolRole.none;
  }

  /// Full access: executive, principal, school admin.
  static bool isManager(SchoolRole r) => r == SchoolRole.executive || r == SchoolRole.principal || r == SchoolRole.schoolAdmin;

  static bool canOpen(SchoolRole r, SchoolPage p) {
    if (isManager(r)) return true;
    return switch (r) {
      SchoolRole.accountant => p == SchoolPage.fees,
      SchoolRole.librarian => p == SchoolPage.library,
      SchoolRole.teacher => p == SchoolPage.dailyLog || p == SchoolPage.grades || p == SchoolPage.students || p == SchoolPage.library,
      _ => false,
    };
  }

  static List<SchoolPage> pagesFor(SchoolRole r) => [for (final p in SchoolPage.values) if (canOpen(r, p)) p];

  static String label(SchoolRole r) => switch (r) {
        SchoolRole.executive => 'Executive',
        SchoolRole.principal => 'Principal',
        SchoolRole.schoolAdmin => 'School admin',
        SchoolRole.accountant => 'Accountant',
        SchoolRole.librarian => 'Librarian',
        SchoolRole.teacher => 'Teacher',
        SchoolRole.none => 'No School role',
      };
}

/// Who is signed in, for matching a teacher record: ids, never a partial name.
class SchoolUserIdentity {
  const SchoolUserIdentity({this.ids = const {}, this.name = ''});

  /// Lower-cased user id, username and email of the login.
  final Set<String> ids;

  /// Display name; only used when exactly one teacher has it.
  final String name;

  static SchoolUserIdentity current({String fallbackName = ''}) {
    final u = LocalStorageService.getActiveUserData();
    String s(Object? v) => (v ?? '').toString().trim().toLowerCase();
    final ids = {
      s(u['uid']),
      s(u['id']),
      s(u['username']),
      s(u['userName']),
      s(u['usernameLower']),
      s(u['email']),
    }..removeWhere((e) => e.isEmpty);
    final name = s(u['name']).isNotEmpty ? s(u['name']) : s(fallbackName);
    return SchoolUserIdentity(ids: ids, name: name);
  }

  /// The teacher record that belongs to this login, or null.
  /// Matches the record's user id / username / email / employee id exactly; a
  /// name counts only when no other teacher has the same name.
  Map<String, dynamic>? teacherIn(String branchId) => matchTeacher(SchoolLocalStorage.getAllTeachersCached(branchId));

  Map<String, dynamic>? matchTeacher(List<Map<String, dynamic>> teachers) {
    String s(Object? v) => (v ?? '').toString().trim().toLowerCase();
    for (final t in teachers) {
      final keys = {s(t['userId']), s(t['uid']), s(t['username']), s(t['email']), s(t['employeeId'])}..removeWhere((e) => e.isEmpty);
      if (keys.any(ids.contains)) return t;
    }
    if (name.isEmpty) return null;
    final byName = teachers.where((t) => s(t['name']) == name).toList();
    return byName.length == 1 ? byName.single : null;
  }
}
