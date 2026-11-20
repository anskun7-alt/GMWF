// lib/services/stock/stock_pool.dart
//
// The one rule for "whose stock is this".
//
// A branch without camps has ONE stock pool; a branch with camps has one pool per camp.
// Doctor and dispensar in the same pool always read and change the same figures.
// Every stock record carries its pool explicitly (`pool` field), so screens never guess
// the camp from serial prefixes, tags or substrings again.

import '../camp_session_service.dart';
import '../local_storage_service.dart';

class StockPool {
  /// Branch id as used everywhere in the app (lower case, aliases folded: khi → karachi).
  final String branch;

  /// Canonical camp id, or null for a branch without camps.
  final String? camp;

  const StockPool._(this.branch, this.camp);

  /// The pool key stored on every record: `branch` or `branch/camp`.
  String get key => camp == null ? branch : '$branch/$camp';

  bool get hasCamp => camp != null;

  /// Cloud collection under `branches/{cloudBranch}` that holds this pool.
  /// Karachi keeps its historical names (inventory_haji / inventory_saddar).
  String get collection {
    final c = camp;
    if (c == null) return 'inventory';
    if (CampSessionService.isKarachiFamily(branch)) {
      if (c.contains('haji')) return 'inventory_haji';
      if (c.contains('sadd') || c.contains('kap')) return 'inventory_saddar';
    }
    return 'inventory_$c';
  }

  /// Firestore branch document id.
  String get cloudBranch => CampSessionService.isKarachiFamily(branch) ? 'karachi' : branch;

  @override
  bool operator ==(Object other) => other is StockPool && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;

  static String normalizeBranch(String? branchId) {
    final raw = (branchId ?? '').trim().toLowerCase();
    if (raw.isEmpty) return '';
    return LocalStorageService.sanitizeBranchId(raw);
  }

  static String? normalizeCamp(String? campId) {
    final raw = (campId ?? '').trim().toLowerCase();
    if (raw.isEmpty || raw == 'all' || raw == 'general' || raw == 'null' || raw == 'default') return null;
    return CampSessionService.canonicalizeCampId(raw);
  }

  /// Pool for a branch + camp. The camp is dropped for a branch without camps, and for a
  /// branch with camps an unknown/empty camp falls back to [fallbackCamp] (usually this PC's
  /// active camp). Returns null when a camp is required but none can be worked out.
  static StockPool? of(String? branchId, String? campId, {String? fallbackCamp}) {
    final b = normalizeBranch(branchId);
    if (b.isEmpty) return null;
    if (!CampSessionService.hasCampsForBranch(b)) return StockPool._(b, null);
    final c = normalizeCamp(campId) ?? normalizeCamp(fallbackCamp) ?? normalizeCamp(CampSessionService.getActiveCamp(b));
    if (c == null) return null;
    return StockPool._(b, c);
  }

  /// Pool for this PC right now (its branch + active camp).
  static StockPool? current([String? branchId]) {
    final b = branchId ?? LocalStorageService.getActiveUserBranchId();
    return of(b, CampSessionService.getActiveCamp(b));
  }

  /// Rebuilds a pool from its stored key. Does not consult camp configuration.
  static StockPool? fromKey(String? key) {
    final k = (key ?? '').trim().toLowerCase();
    if (k.isEmpty) return null;
    final i = k.indexOf('/');
    if (i < 0) return StockPool._(k, null);
    final b = k.substring(0, i);
    final c = k.substring(i + 1);
    if (b.isEmpty) return null;
    return StockPool._(b, c.isEmpty ? null : c);
  }

  /// Every pool of a branch (one, or one per open camp).
  static List<StockPool> allFor(String? branchId) {
    final b = normalizeBranch(branchId);
    if (b.isEmpty) return const [];
    if (!CampSessionService.hasCampsForBranch(b)) return [StockPool._(b, null)];
    final out = <String, StockPool>{};
    for (final c in CampSessionService.getCampsForBranch(b)) {
      final id = normalizeCamp(c['id']?.toString());
      if (id != null) out[id] = StockPool._(b, id);
    }
    return out.values.toList();
  }

  /// Pool of a legacy stock record that has no `pool` field yet (used once, by the repair
  /// and when old-format records arrive). Uses the record's own camp fields and id prefix.
  static StockPool? ofLegacyRecord(Map item, {String? branchFallback}) {
    final explicit = fromKey(item['pool']?.toString());
    if (explicit != null) return explicit;
    final b = normalizeBranch((item['branchId'] ?? branchFallback)?.toString());
    if (b.isEmpty) return null;
    if (!CampSessionService.hasCampsForBranch(b)) return StockPool._(b, null);
    final id = (item['id'] ?? item['medicineId'] ?? '').toString().toLowerCase();
    if (CampSessionService.isKarachiFamily(b)) {
      if (id.startsWith('hajicamp--') || id.startsWith('haji--')) return StockPool._(b, 'haji_camp');
      if (id.startsWith('saddar--') || id.startsWith('kapayya--')) return StockPool._(b, 'saddar');
      final tag = (item['dispensaryTag'] ?? '').toString().toUpperCase();
      if (tag == 'HAJI' || tag == 'HC' || tag == 'HAJICAMP') return StockPool._(b, 'haji_camp');
      if (tag == 'SADD' || tag == 'KAP' || tag == 'SADDAR') return StockPool._(b, 'saddar');
    }
    final camp = normalizeCamp((item['campId'] ?? item['dispensaryId'])?.toString());
    if (camp == null) return null;
    // Only camps the branch really has.
    final known = allFor(b).map((p) => p.camp).toSet();
    if (known.isNotEmpty && !known.contains(camp)) return null;
    return StockPool._(b, camp);
  }
}
