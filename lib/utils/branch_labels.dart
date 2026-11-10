import '../services/camp_session_service.dart';
import '../services/local_storage_service.dart';

/// Display-only labels for the dispensary token types that depend on the branch.
///
/// Karachi-related branches (Karachi, its camps Saddar / Haji Camp / Kapaya, and `khi` ids)
/// never show the word "Zakat": the Rs 20 token is shown as "20 PKR" and the Rs 100 token as
/// "100 PKR". Every other branch keeps "Zakat" / "Non-Zakat".
///
/// Only the displayed text changes. Stored values (`'Zakat'`, `'zakat'`, `'non-zakat'`),
/// Firestore/Hive field names and keys must keep using the original words.
class BranchLabels {
  BranchLabels._();

  static const String karachiZakatLabel = '20 PKR';
  static const String karachiNonZakatLabel = '100 PKR';

  /// True for Karachi and all Karachi camp/sub-branch ids (`karachi`, `karachi_haji`,
  /// `saddar`, `haji_camp`, `kapaya`, `khi`, `khi-...`).
  static bool isKarachiBranch(String? branchId) {
    if (branchId == null) return false;
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty) return false;
    if (b == 'khi' || b.startsWith('khi_') || b.startsWith('khi-')) return true;
    return CampSessionService.isKarachiFamily(b);
  }

  /// Uses [branchId] when given, otherwise the signed-in user's active branch.
  static bool _isKarachi(String? branchId) {
    if (branchId != null && branchId.trim().isNotEmpty && branchId.trim().toLowerCase() != 'all') {
      return isKarachiBranch(branchId);
    }
    if (branchId != null && branchId.trim().toLowerCase() == 'all') return false;
    try {
      return isKarachiBranch(LocalStorageService.getActiveBranchId());
    } catch (_) {
      return false;
    }
  }

  /// "Zakat" or "20 PKR" (Karachi).
  static String zakat([String? branchId]) => _isKarachi(branchId) ? karachiZakatLabel : 'Zakat';

  /// "Non-Zakat" or "100 PKR" (Karachi).
  static String nonZakat([String? branchId]) =>
      _isKarachi(branchId) ? karachiNonZakatLabel : 'Non-Zakat';

  /// Rewrites any text containing "Zakat" / "Non-Zakat" (any case, `Non Zakat`, `non_zakat`)
  /// for display. Non-Karachi branches get [text] back unchanged.
  static String text(String text, [String? branchId]) {
    if (!_isKarachi(branchId)) return text;
    return replaceForKarachi(text);
  }

  static final RegExp _nonZakatRe = RegExp(r'non[\s_\-]?zakat', caseSensitive: false);
  static final RegExp _zakatRe = RegExp(r'zakat', caseSensitive: false);

  /// Pure replacement used by [text]; exposed for tests.
  static String replaceForKarachi(String text) {
    return text
        .replaceAll(_nonZakatRe, karachiNonZakatLabel)
        .replaceAll(_zakatRe, karachiZakatLabel);
  }
}
