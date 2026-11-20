// lib/pages/home/home_sections.dart
//
// Modules whose own screen has sections (Madrassa, School, Finance). In the
// shell, those sections become sidebar items under the module, and the
// module's own rail / tabs are hidden. The screens stay unchanged for users
// who open them directly (madrassa staff, school staff).
//
// Some registry modules are just one section of another (Payroll is Finance's
// payroll tab; Student Attendance is a School tab). When the parent module is
// available, those are folded into it so the sidebar lists each screen once.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../models/module_registry.dart';
import '../../services/local_storage_service.dart';
import '../madrassa/madrassa_dashboard.dart' show MadrassaDashboard;
import '../office/finance_page.dart' show FinancePage;
import '../school/school_dashboard.dart' show SchoolDashboard;

@immutable
class HomeSection {
  const HomeSection(this.key, this.label, this.icon, {this.index});
  final String key;
  final String label;
  final IconData icon;

  /// Tab index in the module's screen, where it is index-driven.
  final int? index;
}

const Map<String, List<HomeSection>> homeSections = {
  'madrassa': [
    HomeSection('overview', 'Insights', GIcons.dashboard),
    HomeSection('daily', 'Daily log', GIcons.calendar),
    HomeSection('students', 'Students', GIcons.users),
    HomeSection('teachers', 'Teachers', GIcons.teacher),
    HomeSection('progress', 'Progress', GIcons.trendUp),
    HomeSection('monthly', 'Monthly report', GIcons.chart),
    HomeSection('config', 'Config', GIcons.settings),
  ],
  // Executive (non-school-staff) order in SchoolDashboard.
  'school_module': [
    HomeSection('overview', 'Overview', GIcons.dashboard, index: 0),
    HomeSection('admissions', 'Admissions', GIcons.registerPatient, index: 1),
    HomeSection('attendance', 'Student attendance', GIcons.attendance, index: 2),
    HomeSection('faculty_attendance', 'Faculty attendance', GIcons.teacher, index: 3),
    HomeSection('faculty', 'Faculty registry', GIcons.team, index: 4),
    HomeSection('fees', 'Fees', GIcons.fees, index: 5),
    HomeSection('library', 'Library', GIcons.book, index: 6),
    HomeSection('grading', 'Grading & reports', GIcons.exam, index: 7),
    HomeSection('audit', 'Audit trail', GIcons.audit, index: 8),
  ],
  'finance': [
    HomeSection('treasury', 'Treasury & accounts', GIcons.bank, index: 0),
    HomeSection('employees', 'Employees', GIcons.employee, index: 1),
    HomeSection('payroll', 'Payroll', GIcons.salary, index: 3),
    HomeSection('loans', 'Loans & advances', GIcons.cheque, index: 4),
    HomeSection('expenses', 'Expenses', GIcons.expense, index: 5),
    HomeSection('audit', 'Audit trail', GIcons.audit, index: 6),
    HomeSection('reports', 'Reports & reconcile', GIcons.report, index: 7),
  ],
};

/// Registry modules that are a section of another module: id → (parent, section).
const Map<String, (String, String)> homeFolded = {
  'cash_flow': ('finance', 'treasury'),
  'employees': ('finance', 'employees'),
  'payroll': ('finance', 'payroll'),
  'loans': ('finance', 'loans'),
  'expenses': ('finance', 'expenses'),
  'finance_reports': ('finance', 'reports'),
  'school_students': ('school_module', 'admissions'),
  'school_attendance': ('school_module', 'attendance'),
  'school_teacher_attendance': ('school_module', 'faculty_attendance'),
  'school_teachers': ('school_module', 'faculty'),
  'school_fees': ('school_module', 'fees'),
  'school_library': ('school_module', 'library'),
  'school_grading': ('school_module', 'grading'),
  'school_audit': ('school_module', 'audit'),
};

/// Where [moduleId] really opens for a user with [available] modules:
/// its parent and section when folded, else itself.
(String, String?) homeResolve(String moduleId, Iterable<String> available) {
  final f = homeFolded[moduleId];
  if (f != null && available.contains(f.$1)) return f;
  return (moduleId, null);
}

String? defaultSection(String moduleId) => homeSections[moduleId]?.first.key;

String? sectionLabel(String moduleId, String? section) {
  if (section == null) return null;
  for (final s in homeSections[moduleId] ?? const <HomeSection>[]) {
    if (s.key == section) return s.label;
  }
  return null;
}

/// [m] with a builder that shows [section] with the screen's own navigation
/// hidden. Modules without sections come back unchanged.
AppModule withSection(AppModule m, String? section, {ValueChanged<String>? onSectionChanged}) {
  final secs = homeSections[m.id];
  if (secs == null) return m;
  final sec = secs.firstWhere((s) => s.key == section, orElse: () => secs.first);
  String branch(Map<String, dynamic> d) => (d['branchId'] ?? 'all').toString();

  return switch (m.id) {
    'madrassa' => m.copyWith(
        builder: (_, d) => MadrassaDashboard(
          branchId: branch(d),
          username: (d['name'] ?? d['username'] ?? 'User').toString(),
          role: (d['role'] ?? 'admin').toString(),
          isAdmin: true,
          hideNavigation: true,
          section: sec.key,
          onSectionChanged: onSectionChanged,
        ),
      ),
    'school_module' => m.copyWith(
        builder: (_, d) => SchoolDashboard(
          branchId: branch(d),
          username: (d['name'] ?? d['username'] ?? LocalStorageService.getActiveUsername()).toString(),
          role: (d['role'] ?? LocalStorageService.getActiveUserRole()).toString(),
          initialTabIndex: sec.index ?? 0,
          hideNavigation: true,
        ),
      ),
    'finance' => m.copyWith(
        builder: (_, d) => FinancePage(branchId: branch(d), isAdmin: true, initialTabIndex: sec.index ?? 0),
      ),
    _ => m,
  };
}
