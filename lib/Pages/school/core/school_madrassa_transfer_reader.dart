// lib/pages/school/core/school_madrassa_transfer_reader.dart
//
// READ-ONLY bridge for "Transfer from Madrassa" at school admission.
//
// The School module never imports madrassa code and never writes madrassa data
// (School ERP plan §0). This reader opens the madrassa students Hive box
// directly and returns plain maps for pre-filling the admission form.
//
// Key format mirrors madrassa `MadrassaLocalStorage.getAllStudentsCached`
// (`<branch>__std__<id>`, legacy `madrassa_std_<id>`) as of 2026-11. If madrassa
// changes its keys, only this file needs updating.

import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/local_storage_service.dart';
import 'school_branch_id.dart';

abstract final class SchoolMadrassaTransferReader {
  /// Active madrassa students of [branchId] ("all" = every branch), sorted by name.
  static List<Map<String, dynamic>> students(String branchId) {
    final boxName = LocalStorageService.madrassaStudentsBox;
    if (!Hive.isBoxOpen(boxName)) return const [];
    final box = Hive.box(boxName);
    final target = SchoolBranchId.normalize(branchId);
    final isAll = target == SchoolBranchId.all;

    final out = <Map<String, dynamic>>[];
    for (final k in box.keys) {
      final key = k.toString();
      final isStd = key.contains('__std__');
      if (!isStd && !key.startsWith('madrassa_std_')) continue;
      if (!isAll && isStd && SchoolBranchId.normalize(key.split('__std__').first) != target) continue;

      final raw = box.get(k);
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);

      final name = (m['name'] ?? '').toString().trim();
      final status = (m['status'] ?? '').toString().toLowerCase();
      final deleted = m['isDeleted'] == true || m['deleted'] == true || status == 'deleted';
      if (name.isEmpty || deleted) continue;

      final recordBranch = (m['branchId'] ?? '').toString();
      if (!isAll && recordBranch.isNotEmpty && SchoolBranchId.normalize(recordBranch) != target) continue;

      m['id'] = isStd ? key.split('__std__').last : key.replaceFirst('madrassa_std_', '');
      out.add(m);
    }
    out.sort((a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo((b['name'] ?? '').toString().toLowerCase()));
    return out;
  }
}
