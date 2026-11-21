// lib/services/branch_directory.dart
//
// The ONE list of real branches for pickers and tab strips (user rule 2026-11-21):
//   • "All Branches" is NOT a branch. It is a filter/tab inside a screen, never an entry in
//     the top-bar branch picker.
//   • Ids that are not branches never show: 'all', 'global', 'main', 'default', 'unknown',
//     placeholders, and camps (Saddar, Haji Camp → part of Karachi).
//   • Old spellings fold into one branch ('jalalpur_jattan' → 'jalalpurjattan'), so a branch
//     never appears twice. (The old cloud folder is still READ for history; only the list
//     shown to people is cleaned.)
//   • Offboarded / deleted branches do not show.

import 'package:hive_flutter/hive_flutter.dart';

import 'local_storage_service.dart';

class BranchDirectory {
  BranchDirectory._();

  static const Map<String, String> _defaultNames = {
    'karachi': 'Karachi',
    'gujrat': 'Gujrat',
    'sialkot': 'Sialkot',
    'rawalpindi': 'Rawalpindi',
    'jalalpurjattan': 'Jalal Pur Jattan',
  };

  static const Set<String> _notBranches = {
    'all', 'global', 'main', 'default', 'unknown', 'null', 'undefined', 'none', 'hq', 'headquarters',
  };

  /// Canonical branch id, or null when [raw] is not a real branch (junk, camp of another
  /// branch handled by folding, or empty).
  static String? canonical(String? raw) {
    final r = (raw ?? '').trim().toLowerCase();
    if (r.isEmpty || _notBranches.contains(r) || r.startsWith('karachi_')) {
      // karachi_1 / karachi_2 … are old placeholders; they fold into Karachi.
      return r.startsWith('karachi_') ? 'karachi' : null;
    }
    // Camps belong to Karachi.
    if (r.contains('haji') || r.contains('saddar') || r.contains('kapay') || r == 'khi') return 'karachi';
    final s = LocalStorageService.sanitizeBranchId(r, fallback: r);
    if (s.isEmpty || _notBranches.contains(s)) return null;
    return s;
  }

  static String _prettyName(String id, String? stored) {
    final n = (stored ?? '').trim();
    final fallback = _defaultNames[id] ?? id.replaceAll('_', ' ');
    if (n.isEmpty || n.toLowerCase() == id) return _title(fallback);
    // Stored names like "JALAL PUR JATTAN" / "Jalalpur Jattan Branch": one tidy form.
    if (_defaultNames.containsKey(id)) return _defaultNames[id]!;
    return n.toUpperCase() == n ? _title(n) : n;
  }

  static String _title(String s) =>
      s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');

  static bool _isOff(Map v) {
    final status = (v['status'] ?? '').toString().toLowerCase();
    return v['isOffboarded'] == true ||
        v['isDeleted'] == true ||
        status == 'offboarded' ||
        status == 'deleted' ||
        status == 'inactive';
  }

  /// Real branches as [{id, name}], one per branch, sorted by name. Never contains 'all'.
  static List<Map<String, String>> list() {
    final byId = <String, String>{};
    final off = <String>{};

    void addFrom(Box box) {
      for (final key in box.keys) {
        final v = box.get(key);
        if (v is! Map) continue;
        final rawId = (v['id'] ?? key.toString().replaceAll('branch:', '').replaceAll('branch_', '')).toString();
        final id = canonical(rawId);
        if (id == null) continue;
        // A camp record (e.g. "Haji Camp KHI") folds into its branch; it never names it.
        final isFolded = rawId.trim().toLowerCase() != id;
        if (_isOff(v) && !isFolded) {
          off.add(id);
          continue;
        }
        final name = (v['name'] ?? v['branchName'] ?? '').toString();
        if (!byId.containsKey(id) || (!isFolded && (byId[id] ?? '').isEmpty)) {
          byId[id] = isFolded ? (byId[id] ?? '') : name;
        }
      }
    }

    try {
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) addFrom(Hive.box(LocalStorageService.branchesBox));
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('local_branches')) addFrom(Hive.box('local_branches'));
    } catch (_) {}
    for (final id in _defaultNames.keys) {
      if (!off.contains(id)) byId.putIfAbsent(id, () => '');
    }
    for (final id in off) {
      byId.remove(id);
    }

    final out = [
      for (final e in byId.entries) {'id': e.key, 'name': _prettyName(e.key, e.value)},
    ]..sort((a, b) => a['name']!.compareTo(b['name']!));
    return out;
  }
}
