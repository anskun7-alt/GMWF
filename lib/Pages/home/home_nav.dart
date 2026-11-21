// lib/pages/home/home_nav.dart
//
// The one nav registry for the redesigned home: ModuleRegistry → GNavItem tree.
// Categories become sidebar groups; each group opens on its overview page,
// then lists its modules. Module icons follow gmwf_ui (GIcons), with the
// registry's own icon as the fallback.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../models/module_registry.dart';
import 'home_sections.dart';

/// Destination ids used by the home shell. Modules are `mod:<moduleId>`.
abstract final class HomeDest {
  static const home = 'home';
  static const notifications = 'notifications';
  static const settings = 'settings';
  static const search = 'search';

  static String category(ModuleCategory c) => 'cat:${c.name}';
  static String group(ModuleCategory c) => 'grp:${c.name}';

  /// `mod:<id>` or, for a module's section, `mod:<id>@<section>`.
  static String module(String id, [String? section]) => section == null ? 'mod:$id' : 'mod:$id@$section';

  static String? sectionOf(String id) {
    if (!id.startsWith('mod:')) return null;
    final at = id.indexOf('@');
    return at < 0 ? null : id.substring(at + 1);
  }

  static ModuleCategory? categoryOf(String id) {
    if (!id.startsWith('cat:')) return null;
    final name = id.substring(4);
    for (final c in ModuleCategory.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  static String? moduleIdOf(String id) {
    if (!id.startsWith('mod:')) return null;
    final at = id.indexOf('@');
    return at < 0 ? id.substring(4) : id.substring(4, at);
  }
}

/// Label, icon and colour for each module category.
extension HomeCategoryMeta on ModuleCategory {
  String get label => switch (this) {
        ModuleCategory.office => 'Office & Finance',
        ModuleCategory.dispensary => 'Dispensary',
        ModuleCategory.dasterkhwaan => 'Dasterkhwaan',
        ModuleCategory.madrassa => 'Madrassa',
        ModuleCategory.school => 'School',
      };

  String get blurb => switch (this) {
        ModuleCategory.office => 'Finance, donations, staff, users and branches',
        ModuleCategory.dispensary => 'Reception, doctor, pharmacy and medicine stock',
        ModuleCategory.dasterkhwaan => 'Food tokens, kitchen and rations stock',
        ModuleCategory.madrassa => 'Students, teachers, daily log and guardians',
        ModuleCategory.school => 'Admissions, attendance, fees and grading',
      };

  // Project icons follow the logo: wheat/food for Dasterkhwaan, graduation cap
  // for School, open book for Madrassa.
  IconData get icon => switch (this) {
        ModuleCategory.office => GIcons.office,
        ModuleCategory.dispensary => GIcons.dispensary,
        ModuleCategory.dasterkhwaan => GIcons.food,
        ModuleCategory.madrassa => GIcons.madrassa,
        ModuleCategory.school => GIcons.student,
      };

  Color color(GComfortColors c) => switch (this) {
        ModuleCategory.office => c.chart2,
        ModuleCategory.dispensary => c.chart1,
        ModuleCategory.dasterkhwaan => c.chart4,
        ModuleCategory.madrassa => c.success,
        ModuleCategory.school => c.info,
      };
}

const Map<String, IconData> _moduleIcons = {
  // Office & finance
  'finance': GIcons.money,
  'donations': GIcons.donation,
  'branches_management': GIcons.branch,
  'users': GIcons.users,
  'employees': GIcons.employee,
  'register_user': GIcons.registerPatient,
  'ramadan_welfare': GIcons.ramadan,
  'reports': GIcons.download,
  'register_branch': GIcons.branch,
  'cash_flow': GIcons.bank,
  'payroll': GIcons.salary,
  'loans': GIcons.cheque,
  'expenses': GIcons.expense,
  'finance_reports': GIcons.report,
  'server_sync': GIcons.server,
  // Dispensary
  'branches': GIcons.branch,
  'patients_registration': GIcons.token,
  'doctor_consultation': GIcons.doctor,
  'pharmacy': GIcons.pharmacy,
  'inventory': GIcons.inventory,
  // Legacy 'proforma' module ID kept for saved permissions/shortcuts (folded into inventory).
  'medicine_proforma': GIcons.receiptLong,
  'inventory_ledger': GIcons.ledger,
  'pending_requests': GIcons.checklist,
  'patients_list': GIcons.patient,
  'patient_register_standalone': GIcons.registerPatient,
  'patient_details': GIcons.history,
  // Dasterkhwaan
  'office_boy': GIcons.token,
  'kitchen': GIcons.kitchen,
  'dasterkhwaan_inventory': GIcons.stock,
  'dasterkhwaan_food_log': GIcons.ledger,
  // Madrassa
  'madrassa': GIcons.madrassa,
  'madrassa_guardian': GIcons.guardian,
  // School
  'school_module': GIcons.student,
  'school_attendance': GIcons.attendance,
  'school_teacher_attendance': GIcons.teacher,
  'school_students': GIcons.student,
  'school_teachers': GIcons.teacher,
  'school_library': GIcons.book,
  'school_fees': GIcons.fees,
  'school_grading': GIcons.exam,
  'school_audit': GIcons.audit,
};

/// Sectioned modules whose sections sit straight under their category when
/// they are the only module there.
const Set<String> _flatModules = {'school_module'};

IconData moduleIcon(AppModule m) => _moduleIcons[m.id] ?? m.icon;

/// Modules grouped by category, in registry order, empty categories dropped.
Map<ModuleCategory, List<AppModule>> groupModules(List<AppModule> modules) {
  final out = <ModuleCategory, List<AppModule>>{};
  for (final c in ModuleCategory.values) {
    final list = modules.where((m) => m.category == c).toList();
    if (list.isNotEmpty) out[c] = list;
  }
  return out;
}

/// Builds the sidebar tree for [modules] (already filtered by role/permission).
List<GNavItem> buildHomeNav({
  required List<AppModule> modules,
  required bool showNotifications,
  int notificationCount = 0,
}) {
  // Sections fold into their parent screen when the parent is available.
  final ids = modules.map((m) => m.id).toSet();
  final groups = groupModules([
    for (final m in modules)
      if (homeResolve(m.id, ids).$1 == m.id) m,
  ]);

  GNavItem item(AppModule m) {
    final secs = homeSections[m.id];
    if (secs == null) return GNavItem(id: HomeDest.module(m.id), label: m.title, icon: moduleIcon(m));
    return GNavItem(
      id: 'mgrp:${m.id}',
      label: m.title,
      icon: moduleIcon(m),
      children: [for (final s in secs) GNavItem(id: HomeDest.module(m.id, s.key), label: s.label, icon: s.icon)],
    );
  }

  // A category that is really one sectioned screen (School = the Taleem-wa-
  // Tarbiyat school) lists that screen's sections directly: no second
  // "Overview" and no extra nesting level.
  List<GNavItem> children(ModuleCategory cat, List<AppModule> mods) {
    final only = mods.length == 1 ? mods.single : null;
    if (only != null && _flatModules.contains(only.id)) {
      return [for (final s in homeSections[only.id]!) GNavItem(id: HomeDest.module(only.id, s.key), label: s.label, icon: s.icon)];
    }
    return [
      GNavItem(id: HomeDest.category(cat), label: 'Overview', icon: GIcons.gridView),
      for (final m in mods) item(m),
    ];
  }

  return [
    const GNavItem(id: HomeDest.home, label: 'Dashboard', icon: GIcons.dashboard),
    if (groups.isNotEmpty) const GNavItem.section('Modules'),
    for (final e in groups.entries)
      GNavItem(
        id: HomeDest.group(e.key),
        label: e.key.label,
        icon: e.key.icon,
        children: children(e.key, e.value),
      ),
    if (showNotifications) const GNavItem.section('Workspace'),
    if (showNotifications)
      GNavItem(id: HomeDest.notifications, label: 'Notifications', icon: GIcons.notifications, badge: notificationCount),
    // Account settings live on the user card at the foot of the sidebar.
  ];
}
