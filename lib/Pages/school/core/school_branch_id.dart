// lib/pages/school/core/school_branch_id.dart
//
// The ONE place the School module turns a branch id into the id it stores
// and reads under. Every School read and write (Hive keys, Firestore paths,
// sync items) goes through [SchoolBranchId.normalize], so a record saved as
// "grt" and a screen opened as "gujrat" always meet.
//
// Adapted from madrassa `MadrassaLocalStorage.normalizeBranch` (2026-11).
// School keeps its own copy on purpose: the School module never imports
// madrassa code, and a future madrassa alias change must not move School data.

abstract final class SchoolBranchId {
  /// Branch id used for "every branch" (HQ / head office views).
  static const String all = 'all';

  /// Canonical, lower-case branch id. Aliases (grt, khi, hq, head office…)
  /// collapse to one name; HQ-like ids collapse to [all].
  static String normalize(String? branchId) {
    final clean = (branchId ?? '').toLowerCase().trim();
    if (clean.isEmpty ||
        clean == 'unknown' ||
        clean == 'all' ||
        clean == 'global' ||
        clean == 'main' ||
        clean == 'hq' ||
        clean == 'headquarters' ||
        clean == 'central' ||
        clean == 'headoffice' ||
        clean == 'head_office' ||
        clean.contains('head office')) {
      return all;
    }
    if (clean.contains('karachi') ||
        clean.contains('saddar') ||
        clean.contains('haji') ||
        clean.contains('kapaya') ||
        clean == 'khi') {
      return 'karachi';
    }
    if (clean.contains('gujrat') || clean == 'grt' || clean == 'gjt') return 'gujrat';
    if (clean.contains('sialkot') || clean == 'skt') return 'sialkot';
    if (clean.contains('rawalpindi') || clean.contains('pindi') || clean == 'rwp') return 'rawalpindi';
    if (clean.contains('jalalpur') || clean == 'jlj') return 'jalalpurjattan';
    return clean;
  }

  /// True when [branchId] means "all branches" (no single branch to write to).
  static bool isAll(String? branchId) => normalize(branchId) == all;

  /// The Hive key prefix for a branch, including the `__` separator, so
  /// "gujrat" never matches keys of a branch called "gujrat2".
  static String keyPrefix(String? branchId) => '${normalize(branchId)}__';

  /// The branch part of a School Hive key (`<branch>__…`), or null.
  static String? branchOfKey(Object? key) {
    final k = key?.toString() ?? '';
    final i = k.indexOf('__');
    if (i <= 0) return null;
    return k.substring(0, i);
  }
}
