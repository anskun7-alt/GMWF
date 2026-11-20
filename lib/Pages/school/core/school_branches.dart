// lib/pages/school/core/school_branches.dart
//
// Branches that run a school, and the HQ user's chosen branch (School ERP
// Phase 2). Before this, HQ / executive users opening School were always put
// on Gujrat. School records must be saved to one real branch (SchoolStore
// refuses "all"), so HQ picks the branch to work in; the choice is remembered
// on the device.

import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/local_storage_service.dart';
import 'school_branch_id.dart';

abstract final class SchoolBranches {
  static const String _prefKey = 'school_hq_branch';
  static const String fallback = 'gujrat';

  /// Normalized ids of branches with a school facility, Gujrat first.
  static List<String> withSchool() {
    final out = <String>{};
    try {
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final k in box.keys) {
          final key = k.toString();
          if (!key.startsWith('branch:')) continue;
          final id = SchoolBranchId.normalize(key.substring(7));
          if (id == SchoolBranchId.all) continue;
          if (LocalStorageService.hasSchoolFacility(id)) out.add(id);
        }
      }
    } catch (_) {}
    if (LocalStorageService.hasSchoolFacility(fallback)) out.add(fallback);
    final list = out.toList()..sort();
    if (list.remove(fallback)) list.insert(0, fallback);
    return list.isEmpty ? const [fallback] : list;
  }

  /// The branch an HQ user last worked in (if it still runs a school).
  static String hqChoice() {
    final options = withSchool();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final saved = SchoolBranchId.normalize(Hive.box('app_settings').get(_prefKey)?.toString());
        if (options.contains(saved)) return saved;
      }
    } catch (_) {}
    return options.first;
  }

  static Future<void> setHqChoice(String branchId) async {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').put(_prefKey, SchoolBranchId.normalize(branchId));
      }
    } catch (_) {}
  }
}
