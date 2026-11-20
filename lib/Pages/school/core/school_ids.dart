// lib/pages/school/core/school_ids.dart
//
// Document ids for School records. Old ids were `PREFIX-<millis>` (and
// receipts used only the last 6 digits of millis), so two saves in the same
// millisecond, or two PCs at once, could collide and overwrite each other.
// New ids add the branch and a random tail.
//
// Human-facing sequential numbers (admission no., receipt no.) are NOT made
// here; they come from per-branch counters in a later phase.

import 'dart:math';

import 'school_branch_id.dart';

abstract final class SchoolIds {
  static final Random _rng = Random.secure();
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _tail(int length) =>
      List.generate(length, (_) => _alphabet[_rng.nextInt(_alphabet.length)]).join();

  /// `PREFIX-<branch>-<millis>-<5 random>`, e.g. `BK-gujrat-1763112000000-K7Q2M`.
  static String newId(String prefix, String branchId, {DateTime? now}) {
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return '$prefix-${SchoolBranchId.normalize(branchId)}-$ms-${_tail(5)}';
  }

  /// Audit entries only need uniqueness, not readability.
  static String auditId({DateTime? now}) =>
      'AUD-${(now ?? DateTime.now()).microsecondsSinceEpoch}-${_tail(4)}';
}
