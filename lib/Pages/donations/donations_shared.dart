import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'package:collection/collection.dart';
import 'package:gmwf/models/donation_models.dart';
import 'package:gmwf/services/donations_local_storage.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/theme/app_theme.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../constants/colors.dart';
import '../../services/local_storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// USER ROLE
// ─────────────────────────────────────────────────────────────────────────────

enum UserRole { chairman, hqManager, manager, officeBoy, staff }

extension UserRoleX on UserRole {
  String get displayLabel {
    switch (this) {
      case UserRole.chairman:  return 'Chairman';
      case UserRole.hqManager: return 'Manager';
      case UserRole.manager:   return 'Branch Manager';
      case UserRole.officeBoy: return 'Office Boy';
      case UserRole.staff:     return 'Staff';
    }
  }
  bool get isOfficeBoy       => this == UserRole.officeBoy;
  bool get isManager         => this == UserRole.manager;
  bool get isHqManager       => this == UserRole.hqManager;
  bool get isChairman        => this == UserRole.chairman;
  bool get canApprove        => isChairman || isHqManager || isManager;
  bool get canMarkReceived   => isHqManager || isManager;
  bool get canSeeAllBranches => isChairman || isHqManager;

  Color get roleColor {
    switch (this) {
      case UserRole.chairman:  return const Color(0xFFF59E0B);
      case UserRole.hqManager: return const Color(0xFF047857);
      case UserRole.manager:   return const Color(0xFF10B981);
      case UserRole.officeBoy: return const Color(0xFF60A5FA);
      case UserRole.staff:     return const Color(0xFF94A3B8);
    }
  }

  static UserRole fromString(String raw, [String? username]) {
    final n = raw.toLowerCase().trim();
    final u = (username ?? '').toLowerCase().trim();

    // ── Exact match first (most reliable) ───────────────────────────────────
    if (n == 'chairman') return UserRole.chairman;
    if (n == 'hq manager' || n == 'hqmanager' || n == 'hq' || n == 'hq_manager') {
      return UserRole.hqManager;
    }
    if (n == 'branch manager' || n == 'branch_manager') return UserRole.manager;
    // 'manager' alone could be HQ Manager whose account has a partial Firestore
    // record — do NOT auto-assign Branch Manager for a plain 'manager' string;
    // fall through to the username/branchId check below.
    if (n == 'admin') return UserRole.manager;
    if (n == 'officeboy' || n == 'ob' || n == 'office_boy' || n == 'office boy') {
      return UserRole.officeBoy;
    }
    if (n == 'staff' || n == 'receptionist') return UserRole.staff;

    // ── Substring fallback in the role string ────────────────────────────────
    if (n.contains('chairman')) return UserRole.chairman;
    if (n.contains('hq')) return UserRole.hqManager;
    if (n.contains('branch manager') || n.contains('branch_manager')) {
      return UserRole.manager;
    }
    // 'manager' in role string without 'branch' prefix → could be HQ Manager
    if (n == 'manager' || n == 'hq_manager' || n == 'hq manager') {
      return UserRole.hqManager;
    }
    if (n.contains('manager')) return UserRole.manager;
    if (n.contains('admin')) return UserRole.hqManager;
    if (n.contains('officeboy') || n.contains('office boy') ||
        n.contains('office_boy')) {
      return UserRole.officeBoy;
    }

    // ── Last resort: username hints (only unambiguous patterns) ──────────────
    if (u == 'chairman' || u.startsWith('chairman')) return UserRole.chairman;
    if (u.contains('hq') || u == 'hqmanager') return UserRole.hqManager;
    // NOTE: username 'manager' is intentionally NOT mapped to Branch Manager here
    // because HQ Manager accounts often have username 'manager'. Safer default = staff.
    return UserRole.staff;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN SYSTEM - DONATION SPECIFIC
// NOTE: DonDS is defined in donations_screen.dart to avoid duplicate symbol.
// Import donations_screen.dart wherever DonDS is needed.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN SYSTEM - SHARED
// ─────────────────────────────────────────────────────────────────────────────

class DS {
  static const navy900 = Color(0xFF0B1426);
  static const navy800 = Color(0xFF112244);
  static const navy700 = Color(0xFF163567);
  static const navy600 = Color(0xFF1B4280);
  static const navy100 = Color(0xFFE8EEF7);

  static const emerald700 = Color(0xFF065F46);
  static const emerald600 = Color(0xFF047857);
  static const emerald500 = Color(0xFF059669);
  static const emerald100 = Color(0xFFD1FAE5);

  static const sapphire700 = Color(0xFF1E3A8A);
  static const sapphire500 = Color(0xFF3B82F6);
  static const sapphire100 = Color(0xFFDBEAFE);

  static const plum700 = Color(0xFF6B21A8);
  static const plum500 = Color(0xFFA855F7);
  static const plum100 = Color(0xFFF3E8FF);

  static const gold700 = Color(0xFF92400E);
  static const gold600 = Color(0xFFB45309);
  static const gold500 = Color(0xFFD97706);
  static const gold400 = Color(0xFFFBBF24);
  static const gold100 = Color(0xFFFEF3C7);

  static const crimson700 = Color(0xFF9B1C1C);
  static const crimson500 = Color(0xFFEF4444);
  static const crimson100 = Color(0xFFFEE2E2);

  static const statusPending       = Color(0xFF64748B);
  static const statusPendingBg     = Color(0xFFF1F5F9);
  static const statusPendingBorder = Color(0xFFCBD5E1);
  static const statusApproved      = Color(0xFF059669);
  static const statusRejected      = Color(0xFFDC2626);
  static const statusReceived      = Color(0xFF0284C7);
  static const statusReceivedBg    = Color(0xFFE0F2FE);
  static const statusReceivedBorder= Color(0xFF7DD3FC);

  static const amberAccent = Color(0xFFD97706);

  static const ink900 = Color(0xFF111827);
  static const ink700 = Color(0xFF374151);
  static const ink500 = Color(0xFF6B7280);
  static const ink300 = Color(0xFFD1D5DB);
  static const ink200 = Color(0xFFE5E7EB);
  static const ink100 = Color(0xFFF3F4F6);
  static const ink50  = Color(0xFFF9FAFB);

  static List<BoxShadow> get shadowSm => [
    const BoxShadow(color: Color(0x0C000000), blurRadius: 6, offset: Offset(0, 2)),
  ];
  static List<BoxShadow> get shadowMd => [
    const BoxShadow(color: Color(0x10000000), blurRadius: 16, offset: Offset(0, 4)),
    const BoxShadow(color: Color(0x06000000), blurRadius: 4, offset: Offset(0, 1)),
  ];
  static List<BoxShadow> get shadowLg => [
    const BoxShadow(color: Color(0x16000000), blurRadius: 32, offset: Offset(0, 8)),
    const BoxShadow(color: Color(0x08000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static List<BoxShadow> get shadowXl => shadowLg;

  static const rSm  = 6.0;
  static const rMd  = 10.0;
  static const rLg  = 14.0;
  static const rXl  = 18.0;
  static const r2xl = 24.0;

  static TextStyle display({Color color = ink900}) => TextStyle(
      fontSize: 24, fontWeight: FontWeight.w800, color: color,
      letterSpacing: -0.8, height: 1.15);
  static TextStyle heading({Color color = ink900}) => TextStyle(
      fontSize: 17, fontWeight: FontWeight.w700, color: color,
      letterSpacing: -0.3);
  static TextStyle subheading({Color color = ink700}) =>
      TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color);
  static TextStyle body({Color color = ink700}) =>
      TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: color);
  static TextStyle label({Color color = ink500}) => TextStyle(
      fontSize: 11, fontWeight: FontWeight.w700, color: color,
      letterSpacing: 0.6);
  static TextStyle caption({Color color = ink500}) =>
      TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color);
  static TextStyle mono({Color color = ink900, double size = 20}) => GoogleFonts.dmMono(
      fontSize: size, fontWeight: FontWeight.w800, color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
      letterSpacing: -0.4);
}

// ─────────────────────────────────────────────────────────────────────────────
// STATUS CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const String kStatusPending     = 'pending';
const String kStatusReceived    = 'received';

const PdfPageFormat kReceiptFormat =
    PdfPageFormat(4 * PdfPageFormat.inch, 5.7 * PdfPageFormat.inch);

// ─────────────────────────────────────────────────────────────────────────────
// PAYMENT METHOD
// ─────────────────────────────────────────────────────────────────────────────

enum PaymentMethod { cash, cheque, bankDeposit }

extension PaymentMethodX on PaymentMethod {
  String get label {
    switch (this) {
      case PaymentMethod.cash:        return 'Cash';
      case PaymentMethod.cheque:      return 'Cheque';
      case PaymentMethod.bankDeposit: return 'Bank Deposit';
    }
  }
  IconData get icon {
    switch (this) {
      case PaymentMethod.cash:        return Icons.payments_rounded;
      case PaymentMethod.cheque:      return Icons.description_rounded;
      case PaymentMethod.bankDeposit: return Icons.account_balance_rounded;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BRANCH HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String branchCodeFor(String branchId) {
  final id = branchId.toLowerCase().trim();
  if (id.contains('gujrat'))     return 'GRT';
  if (id.contains('jalalpur'))   return 'JPT';
  if (id.contains('karachi-1') || id == 'karachi1') return 'KHI1';
  if (id.contains('karachi-2') || id == 'karachi2') return 'KHI2';
  if (id.contains('rawalpindi')) return 'RWP';
  if (id.contains('sialkot'))    return 'SKT';
  if (id.contains('lahore') || id == 'lhr') return 'LHR';
  return id.length >= 3 ? id.substring(0, 3).toUpperCase() : id.toUpperCase();
}

/// Builds a receipt number like SKT-00000001 (no suffix).
/// NOTE: If your LocalStorageService appends '-L' (meaning "Local/offline"),
/// strip it here so receipts always show clean numbers.
String buildReceiptNumber(String branchId, int seq) {
  final code   = branchCodeFor(branchId);
  final seqStr = seq.toString().padLeft(8, '0');
  return '$code-$seqStr';
}

/// Strips any trailing '-L' or '-O' suffix that LocalStorageService may add
/// to distinguish local vs online receipts. Displayed receipt numbers should
/// not expose internal storage mode to donors.
String cleanReceiptNumber(String raw) {
  // Remove trailing -L (local) or -O (online) suffix added by storage layer
  return raw.replaceAll(RegExp(r'-[LO]$'), '');
}

/// Returns contact phone numbers for a branch.
/// HQ phones are always included first, followed by branch-specific ones.
List<String> branchPhonesFor(String branchId) {
  const hq = ['0331-8525333', '0533525333'];
  final id = branchId.toLowerCase().trim();

  // Dynamic lookup from local_branches (configured in Branches Management)
  try {
    if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
      final box = Hive.box(LocalStorageService.branchesBox);
      dynamic branchData = box.get('branch_$id') ?? box.get(id);
      if (branchData == null) {
        for (final k in box.keys) {
          final v = box.get(k);
          if (v is Map) {
            final bId = (v['id'] ?? '').toString().toLowerCase().trim();
            if (bId == id || (id.isNotEmpty && bId.contains(id))) {
              branchData = v;
              break;
            }
          }
        }
      }
      if (branchData is Map) {
        final customNumbers = <String>[];
        final vPhone = branchData['verificationPhone']?.toString().trim();
        final cPhone = branchData['complaintPhone']?.toString().trim();
        final gPhone = branchData['phone']?.toString().trim();
        final phonesList = branchData['contactNumbers'];

        if (vPhone != null && vPhone.isNotEmpty) customNumbers.add(vPhone);
        if (cPhone != null && cPhone.isNotEmpty && !customNumbers.contains(cPhone)) customNumbers.add(cPhone);
        if (gPhone != null && gPhone.isNotEmpty && !customNumbers.contains(gPhone)) customNumbers.add(gPhone);
        if (phonesList is List) {
          for (final p in phonesList) {
            final pStr = p?.toString().trim() ?? '';
            if (pStr.isNotEmpty && !customNumbers.contains(pStr)) customNumbers.add(pStr);
          }
        }
        if (customNumbers.isNotEmpty) {
          return [...hq, ...customNumbers];
        }
      }
    }
  } catch (_) {}

  // Built-in defaults per branch
  if (id.contains('sialkot'))    return [...hq, '0310-7222821', '0316-7916223'];
  if (id.contains('karachi') || id.contains('khi')) return [...hq, '0333-3047931'];
  if (id.contains('lahore'))     return [...hq, '04235292905', '0333-4504497'];
  if (id.contains('rawalpindi')) return [...hq, '0533525333'];
  return List.from(hq);
}

String _titlize(String text) {
  if (text.isEmpty) return text;
  // If it's something like "karachi-1", turn it into "Karachi 1"
  final t = text.replaceAll('-', ' ').trim();
  final parts = t.split(' ');
  return parts.map((p) => p.isNotEmpty ? p[0].toUpperCase() + p.substring(1).toLowerCase() : '').join(' ');
}

String resolveBranchName(String branchId) {
  final id = branchId.toLowerCase().trim();
  if (id.isEmpty || id == 'all') return 'GMWF Branch';
  if (id.contains('gujrat'))     return 'Gujrat';
  if (id.contains('jalalpur'))   return 'Jalalpur Sharif';
  if (id.contains('karachi-1'))  return 'Karachi 1';
  if (id.contains('karachi-2'))  return 'Karachi 2';
  if (id.contains('rawalpindi')) return 'Rawalpindi';
  if (id.contains('sialkot'))    return 'Sialkot';
  if (id.contains('lahore'))     return 'Lahore';
  return _titlize(id);
}

// ─────────────────────────────────────────────────────────────────────────────
// EXTENSIONS
// ─────────────────────────────────────────────────────────────────────────────

extension DonationTheme on RoleThemeData {
  Color get donationAccent        => accent;
  Color get donationSurface       => bgCard;
  Color get donationBg            => bg;
  Color get donationRule          => bgRule;
  Color get donationTextPrimary   => textPrimary;
  Color get donationTextSecondary => textSecondary;
  Color get donationTextTertiary  => textTertiary;
  Color get donationDanger        => danger;
}

// ─────────────────────────────────────────────────────────────────────────────
// DONATION CATEGORIES
// ─────────────────────────────────────────────────────────────────────────────

enum DonationCategory { all, jamia, gmwf }

extension DonationCategoryX on DonationCategory {
  String get label {
    switch (this) {
      case DonationCategory.all:   return 'All Donations';
      case DonationCategory.jamia: return 'Jamia / Masjid';
      case DonationCategory.gmwf:  return 'GMWF';
    }
  }
  String get shortLabel {
    switch (this) {
      case DonationCategory.all:   return 'All';
      case DonationCategory.jamia: return 'Jamia';
      case DonationCategory.gmwf:  return 'GMWF';
    }
  }
  IconData get icon {
    switch (this) {
      case DonationCategory.all:   return Icons.dashboard_rounded;
      case DonationCategory.jamia: return Icons.mosque_rounded;
      case DonationCategory.gmwf:  return Icons.volunteer_activism_rounded;
    }
  }
  Color get color {
    switch (this) {
      case DonationCategory.all:   return DS.navy700;
      case DonationCategory.jamia: return DS.sapphire700;
      case DonationCategory.gmwf:  return DS.emerald600;
    }
  }
  Color get lightColor {
    switch (this) {
      case DonationCategory.all:   return DS.navy100;
      case DonationCategory.jamia: return DS.sapphire100;
      case DonationCategory.gmwf:  return DS.emerald100;
    }
  }
  List<Color> get gradient {
    switch (this) {
      case DonationCategory.all:
        return [DS.navy800, DS.navy700, DS.navy600];
      case DonationCategory.jamia: 
        return [DS.sapphire700, const Color(0xFF1E40AF), DS.sapphire500];
      case DonationCategory.gmwf:  
        return [DS.emerald700, const Color(0xFF059669), DS.emerald500];
    }
  }
  PdfColor get pdfPrimary {
    switch (this) {
      case DonationCategory.all:   return const PdfColor(0.043, 0.078, 0.149);
      case DonationCategory.jamia: return const PdfColor(0.118, 0.227, 0.541);
      case DonationCategory.gmwf:  return const PdfColor(0.016, 0.471, 0.341);
    }
  }
  PdfColor get pdfDark {
    switch (this) {
      case DonationCategory.all:   return const PdfColor(0.043, 0.078, 0.149);
      case DonationCategory.jamia: return const PdfColor(0.043, 0.122, 0.361);
      case DonationCategory.gmwf:  return const PdfColor(0.024, 0.373, 0.275);
    }
  }
  PdfColor get pdfLight {
    switch (this) {
      case DonationCategory.all:   return const PdfColor(0.910, 0.933, 0.969);
      case DonationCategory.jamia: return const PdfColor(0.859, 0.918, 0.996);
      case DonationCategory.gmwf:  return const PdfColor(0.820, 0.980, 0.898);
    }
  }
  String get pdfCategoryFullLabel {
    switch (this) {
      case DonationCategory.all:   return 'Combined Donations';
      case DonationCategory.jamia: return 'Jamia / Masjid Fund';
      case DonationCategory.gmwf:  return 'GMWF General Fund';
    }
  }

  /// Website URL shown on receipts (used in footer text and QR label).
  /// Jamia/Anjuman → gulzarmadina.com   |   GMWF → gmwf.pk
  String get websiteUrl {
    switch (this) {
      case DonationCategory.all:   return 'gmwf.pk';
      case DonationCategory.jamia: return 'gulzarmadina.com';
      case DonationCategory.gmwf:  return 'gmwf.pk';
    }
  }

  PdfColor get pdfAccent     => pdfPrimary;
  PdfColor get pdfAccentDark => pdfDark;
  PdfColor get pdfAccentMid  => pdfPrimary;
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY TYPE
// ─────────────────────────────────────────────────────────────────────────────

enum DonationEntryType { cash, goods }

extension DonationEntryTypeX on DonationEntryType {
  bool get isGoods => this == DonationEntryType.goods;
  String get label =>
      this == DonationEntryType.cash ? 'Cash' : 'Goods / Ajnas';
  IconData get icon => this == DonationEntryType.cash
      ? Icons.payments_rounded
      : Icons.inventory_2_rounded;
}

// ─────────────────────────────────────────────────────────────────────────────
// GMWF SUB-CATEGORY
// ─────────────────────────────────────────────────────────────────────────────

enum GmwfSubCategory {
  dasterkhwaan,
  dispensary,
  madrisa,
  school,
  libaas,
  rashan,
  general,
}

extension GmwfSubCategoryX on GmwfSubCategory {
  String get label {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return 'Dasterkhwaan';
      case GmwfSubCategory.dispensary:   return 'Dispensary';
      case GmwfSubCategory.madrisa:      return 'Madrisa';
      case GmwfSubCategory.school:       return 'School';
      case GmwfSubCategory.libaas:       return 'Libaas';
      case GmwfSubCategory.rashan:       return 'Rashan';
      case GmwfSubCategory.general:      return 'General';
    }
  }
  String get labelUrdu {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return 'دسترخوان';
      case GmwfSubCategory.dispensary:   return 'ڈسپنسری';
      case GmwfSubCategory.madrisa:      return 'مدرسہ';
      case GmwfSubCategory.school:       return 'سکول';
      case GmwfSubCategory.libaas:       return 'لباس';
      case GmwfSubCategory.rashan:       return 'راشن';
      case GmwfSubCategory.general:      return 'عمومی';
    }
  }
  IconData get icon {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return Icons.restaurant_rounded;
      case GmwfSubCategory.dispensary:   return Icons.local_hospital_rounded;
      case GmwfSubCategory.madrisa:      return Icons.school_rounded;
      case GmwfSubCategory.school:       return Icons.menu_book_rounded;
      case GmwfSubCategory.libaas:       return Icons.checkroom_rounded;
      case GmwfSubCategory.rashan:       return Icons.kitchen_rounded;
      case GmwfSubCategory.general:      return Icons.volunteer_activism_rounded;
    }
  }
  Color get color {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return DS.gold600;
      case GmwfSubCategory.dispensary:   return DS.crimson500;
      case GmwfSubCategory.madrisa:      return DS.plum700;
      case GmwfSubCategory.school:       return const Color(0xFF3B82F6);
      case GmwfSubCategory.libaas:       return const Color(0xFF0891B2);
      case GmwfSubCategory.rashan:       return const Color(0xFF65A30D);
      case GmwfSubCategory.general:      return DS.emerald600;
    }
  }
  Color get lightColor {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return DS.gold100;
      case GmwfSubCategory.dispensary:   return DS.crimson100;
      case GmwfSubCategory.madrisa:      return DS.plum100;
      case GmwfSubCategory.school:       return const Color(0xFFDBEAFE);
      case GmwfSubCategory.libaas:       return const Color(0xFFCFFAFE);
      case GmwfSubCategory.rashan:       return const Color(0xFFECFCCB);
      case GmwfSubCategory.general:      return DS.emerald100;
    }
  }
  List<Color> get gradient {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return [const Color(0xFF92400E), DS.gold600, const Color(0xFFD97706)];
      case GmwfSubCategory.dispensary:   return [const Color(0xFF991B1B), DS.crimson500, const Color(0xFFEF4444)];
      case GmwfSubCategory.madrisa:      return [const Color(0xFF581C87), DS.plum700, const Color(0xFF9333EA)];
      case GmwfSubCategory.school:       return [const Color(0xFF1E3A8A), const Color(0xFF3B82F6), const Color(0xFF60A5FA)];
      case GmwfSubCategory.libaas:       return [const Color(0xFF155E75), const Color(0xFF0891B2), const Color(0xFF06B6D4)];
      case GmwfSubCategory.rashan:       return [const Color(0xFF3F6212), const Color(0xFF65A30D), const Color(0xFF84CC16)];
      case GmwfSubCategory.general:      return [DS.emerald700, DS.emerald600, DS.emerald500];
    }
  }

  PdfColor get pdfPrimary {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return const PdfColor.fromInt(0xFF92400E);
      case GmwfSubCategory.dispensary:   return const PdfColor.fromInt(0xFF991B1B);
      case GmwfSubCategory.madrisa:      return const PdfColor.fromInt(0xFF581C87);
      case GmwfSubCategory.school:       return const PdfColor.fromInt(0xFF1E3A8A);
      case GmwfSubCategory.libaas:       return const PdfColor.fromInt(0xFF155E75);
      case GmwfSubCategory.rashan:       return const PdfColor.fromInt(0xFF3F6212);
      case GmwfSubCategory.general:      return const PdfColor.fromInt(0xFF065F46);
    }
  }

  PdfColor get pdfDark {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return const PdfColor.fromInt(0xFF78350F);
      case GmwfSubCategory.dispensary:   return const PdfColor.fromInt(0xFF7F1D1D);
      case GmwfSubCategory.madrisa:      return const PdfColor.fromInt(0xFF3B0764);
      case GmwfSubCategory.school:       return const PdfColor.fromInt(0xFF0F172A);
      case GmwfSubCategory.libaas:       return const PdfColor.fromInt(0xFF164E63);
      case GmwfSubCategory.rashan:       return const PdfColor.fromInt(0xFF1A2E05);
      case GmwfSubCategory.general:      return const PdfColor.fromInt(0xFF064E3B);
    }
  }

  PdfColor get pdfLight {
    switch (this) {
      case GmwfSubCategory.dasterkhwaan: return const PdfColor.fromInt(0xFFFEF3C7);
      case GmwfSubCategory.dispensary:   return const PdfColor.fromInt(0xFFFEE2E2);
      case GmwfSubCategory.madrisa:      return const PdfColor.fromInt(0xFFF3E8FF);
      case GmwfSubCategory.school:       return const PdfColor.fromInt(0xFFDBEAFE);
      case GmwfSubCategory.libaas:       return const PdfColor.fromInt(0xFFCFFAFE);
      case GmwfSubCategory.rashan:       return const PdfColor.fromInt(0xFFECFCCB);
      case GmwfSubCategory.general:      return const PdfColor.fromInt(0xFFD1FAE5);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DONATION SUBTYPES
// ─────────────────────────────────────────────────────────────────────────────

enum DonationSubtype {
  construction, maintenance, iftar,
  zakat, sadqaWajiba, sadqaAtyaat, general,
  fitrana, fidya,
}

extension DonationSubtypeX on DonationSubtype {
  String get label {
    switch (this) {
      case DonationSubtype.construction: return 'Construction';
      case DonationSubtype.maintenance:  return 'Maintenance';
      case DonationSubtype.iftar:        return 'Iftar';
      case DonationSubtype.zakat:        return 'Zakat';
      case DonationSubtype.sadqaWajiba:  return 'Sadqa Wajiba';
      case DonationSubtype.sadqaAtyaat:  return 'Sadqa / Atyaat';
      case DonationSubtype.general:      return 'General';
      case DonationSubtype.fitrana:      return 'Fitrana';
      case DonationSubtype.fidya:        return 'Fidya';
    }
  }
  IconData get icon {
    switch (this) {
      case DonationSubtype.construction: return Icons.construction_rounded;
      case DonationSubtype.maintenance:  return Icons.build_circle_rounded;
      case DonationSubtype.iftar:        return Icons.dinner_dining_rounded;
      case DonationSubtype.zakat:        return Icons.account_balance_rounded;
      case DonationSubtype.sadqaWajiba:  return Icons.star_rounded;
      case DonationSubtype.sadqaAtyaat:  return Icons.favorite_rounded;
      case DonationSubtype.general:      return Icons.circle_outlined;
      case DonationSubtype.fitrana:      return Icons.volunteer_activism_rounded;
      case DonationSubtype.fidya:        return Icons.healing_rounded;
    }
  }
  Color get color {
    switch (this) {
      case DonationSubtype.construction: return DS.sapphire700;
      case DonationSubtype.maintenance:  return DS.sapphire500;
      case DonationSubtype.iftar:        return DS.gold600;
      case DonationSubtype.zakat:        return DS.emerald700;
      case DonationSubtype.sadqaWajiba:  return const Color(0xFFDB2777);
      case DonationSubtype.sadqaAtyaat:  return DS.plum700;
      case DonationSubtype.general:      return DS.ink500;
      case DonationSubtype.fitrana:      return DS.emerald600;
      case DonationSubtype.fidya:        return DS.gold600;
    }
  }
  List<Color> get gradient {
    switch (this) {
      case DonationSubtype.construction: return [DS.sapphire700, const Color(0xFF1D4ED8), DS.sapphire500];
      case DonationSubtype.maintenance:  return [const Color(0xFF1E40AF), DS.sapphire500, const Color(0xFF3B82F6)];
      case DonationSubtype.iftar:        return [const Color(0xFF92400E), DS.gold600, const Color(0xFFD97706)];
      case DonationSubtype.zakat:        return [const Color(0xFF065F46), DS.emerald700, const Color(0xFF059669)];
      case DonationSubtype.sadqaWajiba:  return [const Color(0xFF9D174D), const Color(0xFFDB2777), const Color(0xFFEC4899)];
      case DonationSubtype.sadqaAtyaat:  return [const Color(0xFF6B21A8), DS.plum700, const Color(0xFFA855F7)];
      case DonationSubtype.general:      return [const Color(0xFF1F2937), DS.ink500, const Color(0xFF6B7280)];
      case DonationSubtype.fitrana:      return [const Color(0xFF059669), DS.emerald600, const Color(0xFF34D399)];
      case DonationSubtype.fidya:        return [const Color(0xFFB45309), DS.gold600, const Color(0xFFFBBF24)];
    }
  }
}

List<DonationSubtype> subtypesFor({
  required DonationCategory  category,
  required DonationEntryType entryType,
  GmwfSubCategory?           gmwfSub,
}) {
  if (category == DonationCategory.all) return [];
  
  if (category == DonationCategory.jamia) {
    return [
      DonationSubtype.construction,
      DonationSubtype.maintenance,
      DonationSubtype.iftar,
      DonationSubtype.general,
    ];
  }

  // GMWF Category logic
  final all = DonationSubtype.values.toList();
  
  if (gmwfSub == null || gmwfSub == GmwfSubCategory.general) {
    return all;
  }

  switch (gmwfSub) {
    case GmwfSubCategory.madrisa:
      return all.where((s) => 
        s != DonationSubtype.zakat && 
        s != DonationSubtype.iftar
      ).toList();
      
    case GmwfSubCategory.dispensary:
      return all.where((s) => 
        s != DonationSubtype.zakat && 
        s != DonationSubtype.sadqaAtyaat
      ).toList();
      
    case GmwfSubCategory.dasterkhwaan:
      return all;
      
    case GmwfSubCategory.school:
      return all.where((s) => 
        s != DonationSubtype.zakat && 
        s != DonationSubtype.iftar && 
        s != DonationSubtype.sadqaAtyaat
      ).toList();
      
    case GmwfSubCategory.libaas:
    case GmwfSubCategory.rashan:
      return all.where((s) => 
        s != DonationSubtype.construction && 
        s != DonationSubtype.maintenance
      ).toList();
      
    default:
      return all;
  }
}

const List<String> kUnits = [
  'kg', 'gram', 'liter', 'piece', 'packet', 'maund', 'quintal',
  'suit', 'pair', 'bundle', 'bag',
];

// ─────────────────────────────────────────────────────────────────────────────
// DONOR MODEL
// ─────────────────────────────────────────────────────────────────────────────

class DonorRecord {
  final String id;
  final List<String> phones;
  final List<String> accountNumbers;
  final String address;
  final String branchId;
  final String createdAt;
  final String? cnic;
  final String? householdId;
  final String? notes;
  final String? place;
  // Historical / pre-app data
  final String? joinedSince;     // ISO date string: 'yyyy-MM-dd'
  final double  openingBalance;  // Pre-app donation total (PKR)
  final String? lastUpdatedAt;
  // Display fields
  final String name;

  /// Primary phone — computed from the list to avoid dual-storage drift.
  String get phone => phones.isNotEmpty ? phones.first : '';

  const DonorRecord({
    required this.id,
    required this.name,
    this.phones = const [],
    this.accountNumbers = const [],
    required this.branchId,
    required this.createdAt,
    this.address = '',
    this.cnic,
    this.householdId,
    this.notes,
    this.place,
    this.joinedSince,
    this.openingBalance = 0.0,
    this.lastUpdatedAt,
  });

  factory DonorRecord.fromMap(Map<String, dynamic> m) {
    final rawPhone = m['phone'];
    final phoneList = m['phones'] is List
        ? List<String>.from(m['phones'])
        : (rawPhone != null && rawPhone.toString().isNotEmpty
            ? [rawPhone.toString()]
            : <String>[]);

    return DonorRecord(
      id:             m['id']             as String? ?? '',
      name:           m['name']           as String? ?? '',
      phones:         phoneList,
      accountNumbers: List<String>.from(m['accountNumbers'] ?? []),
      address:        m['address']        as String? ?? '',
      branchId:       m['branchId']       as String? ?? '',
      createdAt:      m['createdAt']      as String? ?? '',
      cnic:           m['cnic']           as String?,
      householdId:    m['householdId']    as String?,
      notes:          m['notes']          as String?,
      place:          m['place']          as String?,
      joinedSince:    m['joinedSince']    as String?,
      openingBalance: (m['openingBalance'] as num?)?.toDouble() ?? 0.0,
      lastUpdatedAt:  m['lastUpdatedAt']  as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'id':             id,
    'name':           name,
    'phones':         phones,
    'phone':          phone,   // kept for legacy Firestore/Hive readers
    'accountNumbers': accountNumbers,
    'address':        address,
    'branchId':       branchId,
    'createdAt':      createdAt,
    'lastUpdatedAt':  lastUpdatedAt,
    if (cnic           != null) 'cnic':           cnic,
    if (householdId    != null) 'householdId':    householdId,
    if (notes          != null) 'notes':          notes,
    if (place          != null) 'place':          place,
    if (joinedSince    != null) 'joinedSince':    joinedSince,
    if (openingBalance > 0)     'openingBalance': openingBalance,
  };

  DonorRecord copyWith({
    String? name,
    List<String>? phones,
    List<String>? accountNumbers,
    String? address,
    String? cnic,
    String? householdId,
    String? notes,
    String? place,
    String? joinedSince,
    double? openingBalance,
    String? lastUpdatedAt,
  }) {
    return DonorRecord(
      id:             id,
      name:           name           ?? this.name,
      phones:         phones         ?? this.phones,
      accountNumbers: accountNumbers ?? this.accountNumbers,
      address:        address        ?? this.address,
      branchId:       branchId,
      createdAt:      createdAt,
      cnic:           cnic           ?? this.cnic,
      householdId:    householdId    ?? this.householdId,
      notes:          notes          ?? this.notes,
      place:          place          ?? this.place,
      joinedSince:    joinedSince    ?? this.joinedSince,
      openingBalance: openingBalance ?? this.openingBalance,
      lastUpdatedAt:  lastUpdatedAt  ?? this.lastUpdatedAt,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DONOR STATS MODEL
// ─────────────────────────────────────────────────────────────────────────────

class DonorStats {
  final double totalAllTime;
  final double totalThisMonth;
  final double totalThisWeek;
  final int    totalDonations;
  final String lastDonationDate;
  final Map<String, double> perCategory;
  final List<MonthlyDonation> monthlyBreakdown;

  const DonorStats({
    required this.totalAllTime,
    required this.totalThisMonth,
    required this.totalThisWeek,
    required this.totalDonations,
    required this.lastDonationDate,
    required this.perCategory,
    required this.monthlyBreakdown,
  });

  factory DonorStats.fromDonations(List<Map<String, dynamic>> donations) {
    final now       = DateTime.now();
    final monthKey  = DateFormat('yyyy-MM').format(now);
    final weekStart = now.subtract(Duration(days: now.weekday - 1));

    double total = 0, thisMonth = 0, thisWeek = 0;
    final Map<String, double> perCat  = {};
    final Map<String, double> monthly = {};
    String lastDate = '';

    for (final d in donations) {
      final isGoods = (d['entryType'] as String? ?? '') == 'goods';
      if (isGoods) continue;
      final amt  = (d['amount'] as num?)?.toDouble() ?? 0.0;
      final date = (d['date']   as String? ?? '');
      final catId= (d['categoryId'] as String? ?? '');
      final mk   = date.length >= 7 ? date.substring(0, 7) : '';

      total += amt;
      perCat[catId]  = (perCat[catId]  ?? 0) + amt;
      monthly[mk]    = (monthly[mk]    ?? 0) + amt;

      if (mk == monthKey) thisMonth += amt;
      try {
        final dt = DateTime.parse(date);
        if (!dt.isBefore(weekStart)) thisWeek += amt;
      } catch (_) {}

      if (date.compareTo(lastDate) > 0) lastDate = date;
    }

    final monthList = monthly.entries
        .map((e) => MonthlyDonation(month: e.key, amount: e.value))
        .toList()
      ..sort((a, b) => b.month.compareTo(a.month));

    return DonorStats(
      totalAllTime:     total,
      totalThisMonth:   thisMonth,
      totalThisWeek:    thisWeek,
      totalDonations:   donations.where((d) =>
          (d['entryType'] as String? ?? '') != 'goods').length,
      lastDonationDate: lastDate,
      perCategory:      perCat,
      monthlyBreakdown: monthList.take(12).toList(),
    );
  }
}

class MonthlyDonation {
  final String month;
  final double amount;
  const MonthlyDonation({required this.month, required this.amount});

  String get displayLabel {
    try {
      final d = DateTime.parse('$month-01');
      return DateFormat('MMM yy').format(d);
    } catch (_) { return month; }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BANK SLIP MODEL
// ─────────────────────────────────────────────────────────────────────────────

class BankSlip {
  final String id;
  final String branchId;
  final String donorId;
  final String donorName;
  final String weekStart;
  final String weekEnd;
  final double amount;
  final String bankName;
  final String accountNumber;
  final String slipNumber;
  final String depositDate;
  final String imagePath;
  final String uploadedBy;
  final String createdAt;
  final String? notes;

  const BankSlip({
    required this.id,
    required this.branchId,
    required this.donorId,
    required this.donorName,
    required this.weekStart,
    required this.weekEnd,
    required this.amount,
    required this.bankName,
    required this.accountNumber,
    required this.slipNumber,
    required this.depositDate,
    required this.imagePath,
    required this.uploadedBy,
    required this.createdAt,
    this.notes,
  });

  factory BankSlip.fromMap(Map<String, dynamic> m) => BankSlip(
    id:            m['id']            as String? ?? '',
    branchId:      m['branchId']      as String? ?? '',
    donorId:       m['donorId']       as String? ?? '',
    donorName:     m['donorName']     as String? ?? '',
    weekStart:     m['weekStart']     as String? ?? '',
    weekEnd:       m['weekEnd']       as String? ?? '',
    amount:        (m['amount'] as num?)?.toDouble() ?? 0.0,
    bankName:      m['bankName']      as String? ?? '',
    accountNumber: m['accountNumber'] as String? ?? '',
    slipNumber:    m['slipNumber']    as String? ?? '',
    depositDate:   m['depositDate']   as String? ?? '',
    imagePath:     m['imagePath']     as String? ?? '',
    uploadedBy:    m['uploadedBy']    as String? ?? '',
    createdAt:     m['createdAt']     as String? ?? '',
    notes:         m['notes']         as String?,
  );

  Map<String, dynamic> toMap() => {
    'id':            id,
    'branchId':      branchId,
    'donorId':       donorId,
    'donorName':     donorName,
    'weekStart':     weekStart,
    'weekEnd':       weekEnd,
    'amount':        amount,
    'bankName':      bankName,
    'accountNumber': accountNumber,
    'slipNumber':    slipNumber,
    'depositDate':   depositDate,
    'imagePath':     imagePath,
    'uploadedBy':    uploadedBy,
    'createdAt':     createdAt,
    if (notes != null) 'notes': notes,
  };

  String get weekLabel {
    try {
      final s = DateFormat('dd MMM').format(DateTime.parse(weekStart));
      final e = DateFormat('dd MMM yyyy').format(DateTime.parse(weekEnd));
      return '$s – $e';
    } catch (_) { return '$weekStart – $weekEnd'; }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MESSAGING HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String buildThankYouMessage({
  required String           donorName,
  required String           receiptNo,
  required DonationCategory category,
  required double           amount,
  required String           unit,
  required String           branchName,
  String                    branchId      = '',
  DonationSubtype?          subtype,
  GmwfSubCategory?          gmwfSub,
  String                    paymentMethod = 'Cash',
  bool                      isGoods       = false,
  String?                   date,
  String                    goodsItem     = '',
}) {
  final dateStr = date ?? DateFormat('dd MMM yyyy').format(DateTime.now());
  // Always show clean receipt number (strip -L/-O suffix)
  final cleanReceipt = cleanReceiptNumber(receiptNo);

  final orgLine = branchName.trim().isNotEmpty
      ? 'Gulzar Madina Welfare Foundation - $branchName'
      : 'Gulzar Madina Welfare Foundation';
  final amtLine = isGoods
      ? (goodsItem.isNotEmpty ? goodsItem : '${amount % 1 == 0 ? amount.toInt() : amount} $unit')
      : 'PKR ${NumberFormat('#,##0', 'en_US').format(amount)}';
  String purpose = category.label;
  if (category == DonationCategory.gmwf && gmwfSub != null) {
    purpose += ' – ${gmwfSub.label}';
  }
  if (subtype != null && subtype != DonationSubtype.general) {
    purpose += ' (${subtype.label})';
  }

  final phones = branchPhonesFor(branchId.isNotEmpty ? branchId : branchName.toLowerCase());
  final phoneStr = phones.join(' / ');

  return 'Assalam-o-Alaikum *$donorName*,\n\n'
      'JazakAllah Khair for your generous donation. '
      'May Allah accept it and reward you abundantly.\n\n'
      '*DONATION RECEIPT*\n'
      '----------------------------\n'
      'Organisation:  $orgLine\n'
      'Receipt No:    $cleanReceipt\n'
      'Date:          $dateStr\n'
      'Purpose:       $purpose\n'
      '${isGoods ? 'Items:         $amtLine' : 'Amount:        $amtLine'}\n'
      '${isGoods ? 'Status:        RECEIVED\n' : 'Payment:       $paymentMethod\n'}'
      '----------------------------\n\n'
      'Verify this receipt at: https://${category.websiteUrl}/verify?id=${Uri.encodeComponent(cleanReceipt)}\n\n'
      'For queries, contact us: $phoneStr\n'
      '_Gulzar Madina Welfare Foundation_';
}

// ── SMS — opens native SMS app directly, no blocking ─────────────────────────
Future<void> sendSmsThankYou(DonationRecord r) async {
  final phone = r.phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (phone.isEmpty) return;
  final body = buildThankYouMessage(
    donorName: r.donorName, receiptNo: r.receiptNo, category: r.category,
    amount: r.amount, unit: r.unit ?? 'PKR', branchName: r.branchName,
    branchId: r.branchId,
    subtype: r.subtype, gmwfSub: r.gmwfSubCategory,
    paymentMethod: r.paymentMethod, isGoods: r.isGoods,
    goodsItem: r.goodsItem ?? '',
  );
  final smsUri = Uri(scheme: 'sms', path: phone, queryParameters: {'body': body});
  if (await canLaunchUrl(smsUri)) {
    await launchUrl(smsUri, mode: LaunchMode.externalApplication);
  } else {
    debugPrint('[SMS] Cannot open SMS app');
  }
}

// ── WhatsApp — opens wa.me link directly, PDF shared separately ──────────────
Future<void> shareReceiptWhatsApp(DonationRecord r) async {
  if (r.phone.isEmpty) return;

  String clean = r.phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (clean.startsWith('0')) {
    clean = '+92${clean.substring(1)}';
  } else if (clean.startsWith('92') && !clean.startsWith('+')) {
    clean = '+$clean';
  } else if (!clean.startsWith('+')) {
    clean = '+92$clean';
  }

  final caption = buildThankYouMessage(
    donorName: r.donorName, receiptNo: r.receiptNo, category: r.category,
    amount: r.amount, unit: r.unit ?? 'PKR', branchName: r.branchName,
    branchId: r.branchId,
    subtype: r.subtype, gmwfSub: r.gmwfSubCategory,
    paymentMethod: r.paymentMethod, isGoods: r.isGoods,
    goodsItem: r.goodsItem ?? '',
  );

  final waNumber    = clean.replaceAll('+', '');
  final encodedText = Uri.encodeComponent(caption);
  final waUri       = Uri.parse('https://wa.me/$waNumber?text=$encodedText');

  if (await canLaunchUrl(waUri)) {
    await launchUrl(waUri, mode: LaunchMode.externalApplication);
  }
}

// ── Share PDF via system share sheet (non-blocking) ───────────────────────────
Future<void> sharePdfReceipt(DonationRecord r, BuildContext context) async {
  try {
    _showPdfLoadingDialog(context, 'Preparing PDF for sharing...');
    final enriched = await injectPdfAssets(r.toMap());
    final bytes = await compute(_buildReceiptPdfIsolate, enriched);
    
    if (context.mounted) Navigator.pop(context); // Close loading

    final receiptNo = cleanReceiptNumber(r.receiptNo);
    await Share.shareXFiles(
      [XFile.fromData(bytes, name: 'Receipt-$receiptNo.pdf', mimeType: 'application/pdf')],
      text: 'Donation Receipt $receiptNo',
    );
  } catch (e) {
    if (context.mounted) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      _showPdfErrorSnackBar(context, 'PDF Share failed: $e');
    }
  }
}

Future<void> downloadDonorWeeklyReport(DonorRecord donor, List<Map<String, dynamic>> donations, BuildContext context, {String title = 'Weekly Contribution Report'}) async {
  try {
    _showPdfLoadingDialog(context, 'Generating Donor Report...');
    
    // Enrich donations with assets
    if (PdfAssetCache.logo == null) await PdfAssetCache.preload();
    final logoBytes = PdfAssetCache.logo;
    
    final enriched = {
      'donor': donor.toMap(),
      'donations': donations,
      'title': title,
      '_logoBytes': logoBytes,
    };

    final bytes = await compute(_buildDonorReportPdfIsolate, enriched);
    
    if (context.mounted) Navigator.pop(context); // Close loading

    await Printing.sharePdf(
      bytes: bytes,
      filename: 'GMWF-Donor-Report-${donor.name.replaceAll(' ', '_')}.pdf',
    );
  } catch (e) {
    if (context.mounted) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      _showPdfErrorSnackBar(context, 'Report generation failed: $e');
    }
  }
}

Future<Uint8List> _buildDonorReportPdfIsolate(Map<String, dynamic> data) async {
  final donor = DonorRecord.fromMap(data['donor']);
  final donations = (data['donations'] as List).cast<Map<String, dynamic>>();
  final title = data['title'] as String;
  final logoBytes = data['_logoBytes'] as Uint8List?;

  final pdf = pw.Document();
  final fontB = pw.Font.helveticaBold();
  final fontR = pw.Font.helvetica();

  pw.MemoryImage? logo;
  if (logoBytes != null) logo = pw.MemoryImage(logoBytes);

  double total = donations.fold(0.0, (sum, d) {
    final amt = (d['amount'] as num?)?.toDouble() ?? 0.0;
    final probable = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
    return sum + (amt > 0 ? amt : probable);
  });

  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    header: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 20),
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 1))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Row(children: [
            if (logo != null) pw.Container(width: 40, height: 40, margin: const pw.EdgeInsets.only(right: 12), child: pw.Image(logo)),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('GMWF DONOR REPORT', style: pw.TextStyle(font: fontB, fontSize: 16, color: PdfColor.fromInt(0xFF0F172A))),
              pw.Text(title, style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey600)),
            ]),
          ]),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(DateFormat('dd MMM yyyy').format(DateTime.now()), style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey600)),
              pw.SizedBox(height: 8),
              if (donor.id.isNotEmpty)
                pw.Container(
                  padding: const pw.EdgeInsets.all(2),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300, width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
                  child: pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: 'https://gmwf.pk/verify?household=${Uri.encodeComponent(donor.id)}',
                    width: 40, height: 40,
                  ),
                ),
              if (donor.id.isNotEmpty)
                pw.Text('SCAN TO VERIFY HOUSEHOLD', style: pw.TextStyle(font: fontB, fontSize: 5, color: PdfColors.grey500)),
            ],
          ),
        ],
      ),
    ),
    build: (ctx) => [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('DONOR DETAILS', style: pw.TextStyle(font: fontB, fontSize: 8, color: PdfColors.grey500, letterSpacing: 1)),
                pw.SizedBox(height: 4),
                pw.Text(donor.name, style: pw.TextStyle(font: fontB, fontSize: 14, color: PdfColors.black)),
                pw.Text(donor.phones.join(', '), style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey700)),
              ],
            ),
          ),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(color: PdfColors.blue50, borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Column(
              children: [
                pw.Text('TOTAL CONTRIBUTED', style: pw.TextStyle(font: fontB, fontSize: 8, color: PdfColors.blue900)),
                pw.SizedBox(height: 4),
                pw.Text('PKR ${NumberFormat('#,###').format(total)}', style: pw.TextStyle(font: fontB, fontSize: 16, color: PdfColors.blue900)),
              ],
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 30),
      pw.Text('DONATION LOG', style: pw.TextStyle(font: fontB, fontSize: 10, color: PdfColors.grey600, letterSpacing: 0.5)),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey200, width: 0.5),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey100),
            children: [
              _pdfCell('Verify', fontB, 8, true),
              _pdfCell('Date', fontB, 8, true),
              _pdfCell('Receipt #', fontB, 8, true),
              _pdfCell('Category/Purpose', fontB, 8, true),
              _pdfCell('Type/Method', fontB, 8, true),
              _pdfCell('Amount', fontB, 8, true, alignRight: true),
            ],
          ),
          ...donations.map((d) {
            final date = d['date'] as String? ?? '';
            final receiptNo = cleanReceiptNumber(d['receiptNo'] as String? ?? '');
            final category = d['categoryId'] as String? ?? '';
            final subtype = d['subtypeId'] as String? ?? '';
            final isGoods = (d['entryType'] as String? ?? '') == 'goods';
            final payMethod = d['paymentMethod'] as String? ?? 'N/A';
            final goodsItem = d['goodsItem'] as String? ?? '';
            
            final rawAmt = (d['amount'] as num?)?.toDouble() ?? 0.0;
            final probable = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
            final amt = rawAmt > 0 ? rawAmt : probable;

            final categoryId = (d['categoryId'] as String? ?? '').trim();
            final catEnum = DonationCategory.values.firstWhere(
              (c) => c.name == categoryId, orElse: () => DonationCategory.gmwf);
            final domain = catEnum.websiteUrl;
            final qrData = 'https://$domain/verify?id=${Uri.encodeComponent(receiptNo)}';
            
            return pw.TableRow(
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Center(
                    child: pw.SizedBox(
                      width: 20, height: 20,
                      child: pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: qrData,
                      ),
                    ),
                  ),
                ),
                _pdfCell(_fmtDate(date), fontR, 7, false),
                _pdfCell(receiptNo, fontR, 7, false),
                _pdfCell('${category.toUpperCase()}\n$subtype', fontR, 7, false),
                _pdfCell(isGoods ? 'GOODS\n$goodsItem' : 'CASH\n$payMethod', fontR, 7, false),
                _pdfCell(amt > 0 ? NumberFormat('#,###').format(amt) : 'N/A', fontB, 8, false, alignRight: true),
              ],
            );
          }),
        ],
      ),
      pw.SizedBox(height: 40),
      pw.Center(child: pw.Text('Thank you for your kindness and support.', style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey500, fontStyle: pw.FontStyle.italic))),
      pw.SizedBox(height: 10),
      pw.Center(child: pw.Text('This is a computer-generated report.', style: pw.TextStyle(font: fontR, fontSize: 8, color: PdfColors.grey400))),
    ],
  ));

  return pdf.save();
}

Future<void> downloadTransactionsLedgerPdf(List<DonationRecord> donations, String branchName, BuildContext context) async {
  try {
    _showPdfLoadingDialog(context, 'Generating Transactions Ledger...');
    
    if (PdfAssetCache.logo == null) await PdfAssetCache.preload();
    final logoBytes = PdfAssetCache.logo;
    
    final enriched = {
      'donations': donations.map((d) => d.toMap()).toList(),
      'branchName': branchName,
      '_logoBytes': logoBytes,
    };

    final bytes = await compute(_buildTransactionsLedgerPdfIsolate, enriched);
    
    if (context.mounted) Navigator.pop(context); // Close loading

    // Use FilePicker for a direct save dialog on Windows
    final String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Transactions Ledger',
      fileName: 'GMWF-Ledger-${branchName.replaceAll(' ', '_')}-${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (outputFile != null) {
      final file = File(outputFile);
      await file.writeAsBytes(bytes);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ledger saved to: $outputFile'), backgroundColor: Colors.green));
      }
    }
  } catch (e) {
    if (context.mounted) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      _showPdfErrorSnackBar(context, 'Ledger generation failed: $e');
    }
  }
}

Future<Uint8List> _buildTransactionsLedgerPdfIsolate(Map<String, dynamic> data) async {
  final donations = (data['donations'] as List).cast<Map<String, dynamic>>();
  final branchName = data['branchName'] as String;
  final logoBytes = data['_logoBytes'] as Uint8List?;

  final pdf = pw.Document();
  final fontB = pw.Font.helveticaBold();
  final fontR = pw.Font.helvetica();

  pw.MemoryImage? logo;
  if (logoBytes != null) logo = pw.MemoryImage(logoBytes);

  double total = donations.fold(0.0, (sum, d) {
    final amt = (d['amount'] as num?)?.toDouble() ?? 0.0;
    final probable = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
    return sum + (amt > 0 ? amt : probable);
  });

  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(30),
    header: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 20),
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 1))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Row(children: [
            if (logo != null) pw.Container(width: 40, height: 40, margin: const pw.EdgeInsets.only(right: 12), child: pw.Image(logo)),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('GMWF TRANSACTIONS LEDGER', style: pw.TextStyle(font: fontB, fontSize: 16, color: PdfColor.fromInt(0xFF0F172A))),
              pw.Text('Branch: $branchName', style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey600)),
            ]),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(DateFormat('dd MMM yyyy HH:mm').format(DateTime.now()), style: pw.TextStyle(font: fontR, fontSize: 10, color: PdfColors.grey600)),
            pw.Text('Total: PKR ${NumberFormat('#,###').format(total)}', style: pw.TextStyle(font: fontB, fontSize: 12, color: PdfColor.fromInt(0xFF0F172A))),
          ]),
        ],
      ),
    ),
    build: (ctx) => [
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey200, width: 0.5),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey100),
            children: [
              _pdfCell('Date', fontB, 8, true),
              _pdfCell('Receipt #', fontB, 8, true),
              _pdfCell('Donor', fontB, 8, true),
              _pdfCell('Category', fontB, 8, true),
              _pdfCell('Program', fontB, 8, true),
              _pdfCell('Type', fontB, 8, true),
              _pdfCell('Amount', fontB, 8, true, alignRight: true),
              _pdfCell('Method', fontB, 8, true),
            ],
          ),
          ...donations.map((d) {
            final date = d['date'] as String? ?? '';
            final receiptNo = cleanReceiptNumber(d['receiptNo'] as String? ?? '');
            final category = d['categoryId'] as String? ?? '';
            final program = d['gmwfSubCategoryId'] as String? ?? '';
            final subtype = d['subtypeId'] as String? ?? '';
            final isGoods = (d['entryType'] as String? ?? '') == 'goods';
            final payMethod = d['paymentMethod'] as String? ?? 'N/A';
            final goodsItem = d['goodsItem'] as String?;
            
            final rawAmt = (d['amount'] as num?)?.toDouble() ?? 0.0;
            final probable = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
            final amt = rawAmt > 0 ? rawAmt : probable;

            // Logic for Program, Type, and Method based on user feedback:
            // 1. JAMIA category: Program is empty, Type shows the subtype (maintenance, etc.) to avoid duplication.
            // 2. GOODS: Method is 'GOODS' and Type shows the Goods Name/Item.
            final String finalProgram = (category.toUpperCase() == 'JAMIA') ? '' : program;
            final String finalType    = (category.toUpperCase() == 'JAMIA') ? subtype : (isGoods ? (goodsItem ?? '') : subtype);
            final String finalMethod  = isGoods ? 'GOODS' : payMethod;

            final isEven = donations.indexOf(d) % 2 == 0;
            final rowColor = isEven ? PdfColors.white : PdfColor.fromInt(0xFFF8FAFC);

            return pw.TableRow(
              decoration: pw.BoxDecoration(color: rowColor),
              children: [
                _pdfCell(_fmtDate(date), fontR, 7, false),
                _pdfCell(receiptNo, fontR, 7, false),
                _pdfCell(d['donorName'] ?? 'N/A', fontR, 7, false),
                _pdfCell(category.toUpperCase(), fontR, 7, false),
                _pdfCell(finalProgram, fontR, 7, false),
                _pdfCell(finalType, fontR, 7, false),
                _pdfCell(amt > 0 ? NumberFormat('#,###').format(amt) : '0', fontB, 8, false, alignRight: true),
                _pdfCell(finalMethod, fontR, 7, false),
              ],
            );
          }),
        ],
      ),
    ],
  ));

  return pdf.save();
}

pw.Widget _pdfCell(String text, pw.Font font, double size, bool isHeader, {bool alignRight = false}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.all(6),
    child: pw.Text(
      text,
      textAlign: alignRight ? pw.TextAlign.right : pw.TextAlign.left,
      style: pw.TextStyle(font: font, fontSize: size, color: isHeader ? PdfColors.black : PdfColors.grey800),
    ),
  );
}

// ── Direct download / save PDF using printing package ────────────────────────
Future<void> downloadReceiptPdf(DonationRecord r, BuildContext context) async {
  try {
    _showPdfLoadingDialog(context, 'Generating Receipt PDF...');
    final enriched = await injectPdfAssets(r.toMap());
    final bytes = await compute(_buildReceiptPdfIsolate, enriched);
    
    if (context.mounted) Navigator.pop(context); // Close loading

    await Printing.sharePdf(
      bytes: bytes,
      filename: 'Receipt-${cleanReceiptNumber(r.receiptNo)}.pdf',
    );
  } catch (e) {
    if (context.mounted) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      _showPdfErrorSnackBar(context, 'Download failed: $e');
    }
  }
}

// ── Print to printer (non-blocking layout callback) ──────────────────────────
Future<void> printReceiptPdf(DonationRecord r, BuildContext context) async {
  try {
    _showPdfLoadingDialog(context, 'Preparing for Print...');
    final enriched = await injectPdfAssets(r.toMap());
    
    if (context.mounted) Navigator.pop(context); // Close loading

    await Printing.layoutPdf(
      name: 'Receipt-${cleanReceiptNumber(r.receiptNo)}',
      format: kReceiptFormat,
      onLayout: (_) async => compute(_buildReceiptPdfIsolate, enriched),
    );
  } catch (e) {
    if (context.mounted) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      _showPdfErrorSnackBar(context, 'Printing failed: $e');
    }
  }
}

void _showPdfLoadingDialog(BuildContext context, String message) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => WillPopScope(
      onWillPop: () async => false,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3),
              const SizedBox(height: 20),
              Text(message, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.gray900)),
              const SizedBox(height: 8),
              const Text('Please wait a moment...', style: TextStyle(fontSize: 13, color: AppColors.gray500)),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showPdfErrorSnackBar(BuildContext context, String error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(error, style: const TextStyle(fontWeight: FontWeight.w600)),
    backgroundColor: DS.statusRejected,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.all(16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.rMd)),
  ));
}

class _ShareBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ShareBtn({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ISOLATE-SAFE PDF BUILDER  (top-level function required for compute())
// ─────────────────────────────────────────────────────────────────────────────

Future<Uint8List> _buildReceiptPdfIsolate(Map<String, dynamic> d) async {
  return await buildReceiptPdfSync(d);
}

// ─────────────────────────────────────────────────────────────────────────────
// ASSET CACHE — Avoid redundant disk reads for PDF generation
// ─────────────────────────────────────────────────────────────────────────────

class PdfAssetCache {
  static Uint8List? logo;
  static Uint8List? logoJpg;
  static Uint8List? qrAnjuman;
  static Uint8List? qrGm;

  static Future<void> preload() async {
    try {
      // Use gmwf-1.png (880KB) for watermarks (supports transparency)
      logo      ??= (await rootBundle.load('assets/logo/gmwf-1.webp')).buffer.asUint8List();
      // Use gmwf-1.png (880KB) for small logos (faster & smaller)
      logoJpg   ??= (await rootBundle.load('assets/logo/gmwf-1.webp')).buffer.asUint8List();
      
      qrAnjuman ??= (await rootBundle.load('assets/qr/anjuman.webp')).buffer.asUint8List();
      qrGm      ??= (await rootBundle.load('assets/qr/gm.webp')).buffer.asUint8List();
    } catch (e) {
      debugPrint('[PDF Cache] Preload error: $e');
    }
  }
}

Future<Map<String, dynamic>> injectPdfAssets(Map<String, dynamic> d) async {
  final out = Map<String, dynamic>.from(d);
  
  // Ensure cache is ready
  if (PdfAssetCache.logo == null || PdfAssetCache.logoJpg == null) await PdfAssetCache.preload();

  if (PdfAssetCache.logo != null) out['_logoBytes'] = PdfAssetCache.logo;
  if (PdfAssetCache.logoJpg != null) out['_logoJpgBytes'] = PdfAssetCache.logoJpg;
  if (PdfAssetCache.qrAnjuman != null) out['_qrAnjumanBytes'] = PdfAssetCache.qrAnjuman;
  if (PdfAssetCache.qrGm != null) out['_qrGmBytes'] = PdfAssetCache.qrGm;

  // Inject Donor YTD Total
  try {
    final donorId = d['donorId']?.toString() ?? '';
    out['_ytdTotal'] = DonationsLocalStorage.getDonorYTDTotal(donorId);
  } catch (e) {
    debugPrint('[PDF Assets] YTD calculate error: $e');
  }

  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN PUBLIC PDF ENTRY POINT
// Loads assets on main thread, then hands off to compute() for actual build.
// Non-blocking: asset loading is awaited but is fast (local bundle reads).
// The heavy PDF rendering runs in a background isolate via compute().
// ─────────────────────────────────────────────────────────────────────────────

Future<Uint8List> buildReceiptPdf(
    Map<String, dynamic> d, String receiptNo, PdfPageFormat format) async {
  final enriched = await injectPdfAssets(d);
  // Flutter Web does not support Isolates (compute) — run synchronously there.
  if (kIsWeb) return buildReceiptPdfSync(enriched);
  return compute(_buildReceiptPdfIsolate, enriched);
}

// SYNCHRONOUS PDF BUILD  (runs inside isolate, no async/rootBundle calls)
// ─────────────────────────────────────────────────────────────────────────────

Future<Uint8List> buildReceiptPdfSync(Map<String, dynamic> d) async {
  final categoryId = (d['categoryId'] as String? ?? '').trim();
  final cat = DonationCategory.values.firstWhere(
      (c) => c.name == categoryId, orElse: () => DonationCategory.gmwf);

  final donorName     = (d['donorName']  as String? ?? 'Walk-in Donor').trim();
    final donorPhone    = (d['phone'] as String? ?? '').trim();
  final rawBranchName = (d['branchName'] as String? ?? '').trim();
  final branchId      = (d['branchId']     as String? ?? '').trim();
  final branchName    = rawBranchName.isNotEmpty
      ? _titlize(rawBranchName)
      : resolveBranchName(branchId);

  final recordedBy    = ((d['recordedBy'] as String?)?.trim().isNotEmpty == true
      ? d['recordedBy'] as String : 'Authorized Staff');
  final paymentMethod = (d['paymentMethod'] as String? ?? 'Cash').trim();
  final notes         = (d['notes']        as String? ?? '').trim();
  final subtypeId     = (d['subtypeId']    as String? ?? '').trim();
  final gmwfSubId     = (d['gmwfSubCategoryId'] as String? ?? '').trim();
  final rawDate       = d['date'] as String?;
  final isGoods       = (d['entryType'] as String? ?? '') == 'goods';
  final goodsItem     = (d['goodsItem']    as String? ?? '').trim();

  double amount = 0.0;
  final rawAmt = d['amount'];
  if (rawAmt is num)    amount = rawAmt.toDouble();
  if (rawAmt is String) amount = double.tryParse(rawAmt) ?? 0.0;
  final probableAmount = (d['probableAmount'] as num?)?.toDouble() ?? 0.0;
  final amt = amount > 0 ? amount : probableAmount;

  final ytdTotal = (d['_ytdTotal'] as num?)?.toDouble() ?? 0.0;

  String subtypeLabel = '';
  if (subtypeId.isNotEmpty) {
    try {
      final st = DonationSubtype.values.firstWhere((s) => s.name == subtypeId);
      subtypeLabel = st.label;
    } catch (_) { subtypeLabel = subtypeId; }
  }

  pw.MemoryImage? logo;
  final logoBytes = d['_logoBytes'];
  if (logoBytes is Uint8List) logo = pw.MemoryImage(logoBytes);

  pw.MemoryImage? logoJpg;
  final logoJpgBytes = d['_logoJpgBytes'];
  if (logoJpgBytes is Uint8List) logoJpg = pw.MemoryImage(logoJpgBytes);

  // Use localId as fallback if receiptNo is absent/blank
  final rawReceiptNo   = (d['receiptNo'] as String? ?? '').trim();
  final localIdFallback = (d['localId']  as String? ?? '').trim();
  final receiptNo = rawReceiptNo.isNotEmpty
      ? cleanReceiptNumber(rawReceiptNo)
      : (localIdFallback.isNotEmpty ? localIdFallback : 'DRAFT');
  final dateDisplay = _fmtDate(rawDate);
  final amountDisplay = isGoods
      ? (amt > 0 ? 'PKR ${_fmtNum(amt)}' : '')
      : 'PKR ${_fmtNum(amt)}';

  final PdfColor accent;
  final PdfColor accentDk;
  final PdfColor accentLt;
  if (cat == DonationCategory.gmwf && gmwfSubId.isNotEmpty) {
    final subEnum = GmwfSubCategory.values.firstWhere(
      (s) => s.name == gmwfSubId,
      orElse: () => GmwfSubCategory.general,
    );
    accent   = subEnum.pdfPrimary;
    accentDk = subEnum.pdfDark;
    accentLt = subEnum.pdfLight;
  } else {
    accent   = cat.pdfPrimary;
    accentDk = cat.pdfDark;
    accentLt = cat.pdfLight;
  }

  final PdfColor cWhite   = PdfColors.white;
  final PdfColor cInkDark = PdfColor.fromInt(0xFF0F172A);
  final PdfColor cInkGrey = PdfColor.fromInt(0xFF94A3B8);

  final websiteUrl = cat.websiteUrl;
  final branchPhones = branchPhonesFor(branchId.isNotEmpty ? branchId : branchName.toLowerCase());
  final pdf = pw.Document();

  final fontBold = pw.Font.helveticaBold();

  // 4in x 5.7in receipt — single-column "ticket" layout
  final pageFormat = PdfPageFormat(4 * PdfPageFormat.inch, 5.7 * PdfPageFormat.inch);

  pdf.addPage(pw.Page(
    pageFormat: pageFormat,
    margin: const pw.EdgeInsets.all(12),
    build: (ctx) => pw.Stack(
      children: [
        if (logo != null)
          pw.Center(
            child: pw.Opacity(
              opacity: 0.04,
              child: pw.Image(logo, width: 180),
            ),
          ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // Header: logo + org name
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logoJpg != null)
                  pw.Container(
                    width: 34, height: 34,
                    margin: const pw.EdgeInsets.only(right: 8),
                    child: pw.Image(logoJpg),
                  ),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('GULZAR MADINA',
                          style: pw.TextStyle(font: fontBold, fontSize: 12.5, color: cInkDark)),
                      pw.Text('WELFARE FOUNDATION',
                          style: pw.TextStyle(font: fontBold, fontSize: 7, color: accent, letterSpacing: 0.8)),
                    ],
                  ),
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: pw.BoxDecoration(
                    color: accentLt,
                    borderRadius: pw.BorderRadius.circular(4),
                  ),
                  child: pw.Text(cat.shortLabel.toUpperCase(),
                      style: pw.TextStyle(font: fontBold, fontSize: 8, color: accentDk)),
                ),
              ],
            ),

            pw.SizedBox(height: 6),
            pw.Divider(color: accentLt, thickness: 1),
            pw.SizedBox(height: 6),

            // Receipt # + Date
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFF1E293B),
                    borderRadius: pw.BorderRadius.circular(3),
                  ),
                  child: pw.Text(receiptNo,
                      style: pw.TextStyle(font: fontBold, fontSize: 10, color: cWhite)),
                ),
                pw.Text(dateDisplay,
                    style: pw.TextStyle(font: fontBold, fontSize: 9.5, color: PdfColor.fromInt(0xFF475569))),
              ],
            ),

            pw.SizedBox(height: 10),

            // Donor
            pw.Text('DONOR',
                style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey, letterSpacing: 0.4)),
            pw.SizedBox(height: 2),
            pw.Text(donorName,
                style: pw.TextStyle(font: fontBold, fontSize: 16.5, color: cInkDark)),
                if (donorPhone.isNotEmpty) pw.Text('Phone: $donorPhone',
                style: pw.TextStyle(font: fontBold, fontSize: 12, color: cInkDark)),

            if (ytdTotal > 0) ...[
              pw.SizedBox(height: 4),
              pw.Container(
                alignment: pw.Alignment.centerLeft,
                padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: pw.BoxDecoration(
                  color: accent,
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Text('YTD: PKR ${_fmtNum(ytdTotal)}',
                    style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cWhite)),
              ),
            ],

            pw.SizedBox(height: 4),
            pw.Text('Thank you for your generous contribution.',
                style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey)),

            pw.SizedBox(height: 8),

            // Amount card
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: pw.BoxDecoration(
                gradient: pw.LinearGradient(
                  colors: [accentDk, accent],
                  begin: pw.Alignment.topLeft,
                  end: pw.Alignment.bottomRight,
                ),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(isGoods ? 'GOODS RECEIVED' : 'TOTAL CONTRIBUTION',
                            style: pw.TextStyle(font: fontBold, fontSize: 8, color: cWhite.withOpacity(0.8), letterSpacing: 0.5)),
                        pw.SizedBox(height: 3),
                        if (isGoods && goodsItem.isNotEmpty) ...[
                          pw.Text(goodsItem,
                              style: pw.TextStyle(font: fontBold, fontSize: 18, color: cWhite)),
                          if (amountDisplay.trim().isNotEmpty) ...[
                            pw.SizedBox(height: 1),
                            pw.Text('Est. Value: $amountDisplay',
                                style: pw.TextStyle(font: fontBold, fontSize: 9.5, color: cWhite.withOpacity(0.75))),
                          ],
                        ] else ...[
                          pw.Text(amountDisplay,
                              style: pw.TextStyle(font: fontBold, fontSize: 24, color: cWhite)),
                        ],
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 8),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    mainAxisSize: pw.MainAxisSize.min,
                    children: [
                      pw.Container(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: pw.BoxDecoration(
                          color: accentLt,
                          borderRadius: pw.BorderRadius.circular(3),
                        ),
                        child: pw.Text(cat.shortLabel.toUpperCase(),
                            softWrap: false,
                            style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: accentDk)),
                      ),
                      if (subtypeLabel.isNotEmpty) ...[
                        pw.SizedBox(height: 4),
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: pw.BoxDecoration(
                            color: cWhite,
                            borderRadius: pw.BorderRadius.circular(3),
                          ),
                          child: pw.Text(subtypeLabel.toUpperCase(),
                              softWrap: false,
                              style: pw.TextStyle(font: fontBold, fontSize: 8, color: accentDk)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            pw.SizedBox(height: 10),

            // Branch / Payment row
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('BRANCH', style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey)),
                    pw.SizedBox(height: 1),
                    pw.Text(branchName.toUpperCase(),
                        style: pw.TextStyle(font: fontBold, fontSize: 10.5, color: cInkDark)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(isGoods ? 'TYPE' : 'PAYMENT', style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey)),
                    pw.SizedBox(height: 1),
                    pw.Text(isGoods ? 'GOODS/AJNAS' : paymentMethod.toUpperCase(),
                        style: pw.TextStyle(font: fontBold, fontSize: 10.5, color: cInkDark)),
                  ],
                ),
              ],
            ),

            if (notes.isNotEmpty) ...[
              pw.SizedBox(height: 8),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(6),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFFF8FAFC),
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: PdfColor.fromInt(0xFFE2E8F0), width: 0.5),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('REMARKS / PURPOSE',
                        style: pw.TextStyle(font: fontBold, fontSize: 7, color: cInkGrey, letterSpacing: 0.3)),
                    pw.SizedBox(height: 2),
                    pw.Text(notes,
                        style: pw.TextStyle(font: fontBold, fontSize: 9.5, color: cInkDark)),
                  ],
                ),
              ),
            ],

            pw.Spacer(),

            // Bottom Row: Transacted By & Verification (Left) + QR Code (Right)
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('TRANSACTED BY', style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey)),
                    pw.SizedBox(height: 1),
                    pw.Text(recordedBy.toUpperCase(),
                        style: pw.TextStyle(font: fontBold, fontSize: 10.5, color: cInkDark)),
                    pw.SizedBox(height: 3),
                    pw.Row(
                      children: [
                        pw.Container(
                          width: 3.5, height: 3.5,
                          decoration: const pw.BoxDecoration(color: PdfColors.green, shape: pw.BoxShape.circle),
                        ),
                        pw.SizedBox(width: 3),
                        pw.Text('Verified Transaction', style: pw.TextStyle(fontSize: 7, color: PdfColors.green, font: fontBold)),
                      ],
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text('Verify: $websiteUrl/verify',
                        style: pw.TextStyle(font: fontBold, fontSize: 7, color: accentDk)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Container(
                      padding: const pw.EdgeInsets.all(3),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: accentLt, width: 0.5),
                        borderRadius: pw.BorderRadius.circular(4),
                        color: cWhite,
                      ),
                      child: pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: 'https://$websiteUrl/verify?id=${Uri.encodeComponent(cleanReceiptNumber(receiptNo))}',
                        width: 50,
                        height: 50,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text('SCAN TO VERIFY',
                        style: pw.TextStyle(font: fontBold, fontSize: 6.5, color: cInkGrey, letterSpacing: 0.3)),
                  ],
                ),
              ],
            ),

            pw.SizedBox(height: 8),
            pw.Divider(color: PdfColors.grey200, thickness: 0.5),
            pw.SizedBox(height: 4),

            // Footer
            pw.Center(
              child: pw.Text(branchPhones.join('  |  '),
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: cInkGrey)),
            ),
            pw.SizedBox(height: 3),
            pw.Center(
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Text('gulzarmadina.com', style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: accentDk)),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 5),
                    child: pw.Text('|', style: pw.TextStyle(fontSize: 7.5, color: PdfColors.grey300)),
                  ),
                  pw.Text('gmwf.pk', style: pw.TextStyle(font: fontBold, fontSize: 7.5, color: accentDk)),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  ));

  return pdf.save();
}

pw.Widget _pdfDetailRowSmall(String label, String value, pw.Font font, PdfColor color) {
  final labelColor = PdfColor.fromInt(0xFF64748B); // Slate 500
  final valueColor = PdfColor.fromInt(0xFF1E293B); // Slate 800 (Very Dark)
  
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(label, style: pw.TextStyle(fontSize: 7, color: labelColor, letterSpacing: 0.5)),
      pw.SizedBox(height: 2),
      pw.Text(value, style: pw.TextStyle(font: font, fontSize: 10, color: valueColor)),
    ],
  );
}

extension PdfColorAlpha on PdfColor {
  PdfColor withOpacity(double opacity) => PdfColor(red, green, blue, opacity);
}

extension ColorToPdfColor on Color {
  PdfColor toPdfColor() => PdfColor(red / 255, green / 255, blue / 255, opacity);
}

pw.Widget _pdfDetailRow(String label, String value, pw.Font fontBold, PdfColor labelColor, PdfColor valueColor) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(label, style: pw.TextStyle(font: fontBold, fontSize: 7, color: labelColor, letterSpacing: 1)),
      pw.SizedBox(height: 4),
      pw.Text(value, style: pw.TextStyle(font: fontBold, fontSize: 10, color: valueColor)),
    ],
  );
}

pw.Widget _pdfDetailItem(pw.Font fontBold, String label, String value) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(label.toUpperCase(),
          style: pw.TextStyle(font: fontBold, fontSize: 7, color: const PdfColor.fromInt(0xFF94A3B8), letterSpacing: 0.5)),
      pw.SizedBox(height: 2),
      pw.Text(value,
          style: pw.TextStyle(fontSize: 10, color: const PdfColor.fromInt(0xFF1F2937))),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BANK SLIP PDF  — also uses compute() to avoid blocking
// ─────────────────────────────────────────────────────────────────────────────

class _BankSlipPdfParamsRaw {
  final Map<String, dynamic> slipMap;
  final List<Map<String, dynamic>> itemMaps;
  final Uint8List? logoBytes;
  final Uint8List? qrGmBytes;
  final Uint8List? qrAnjumanBytes;
  const _BankSlipPdfParamsRaw({
    required this.slipMap, required this.itemMaps,
    this.logoBytes, this.qrGmBytes, this.qrAnjumanBytes,
  });
}

Future<Uint8List> buildBankSlipPdf({
  required BankSlip slip,
  required List<DonationRecord> items,
}) async {
  Uint8List? logoBytes, qrGmBytes, qrAnjumanBytes;
  try {
    final b = await rootBundle.load('assets/logo/gmwf-1.webp');
    logoBytes = b.buffer.asUint8List();
  } catch (_) {}
  // Anjuman QR → gulzarmadina.com
  try {
    final b = await rootBundle.load('assets/qr/anjuman.webp');
    qrAnjumanBytes = b.buffer.asUint8List();
  } catch (_) {}
  // GMWF QR → gmwf.pk
  try {
    final b = await rootBundle.load('assets/qr/gm.webp');
    qrGmBytes = b.buffer.asUint8List();
  } catch (_) {}

  return compute(_buildBankSlipIsolate, _BankSlipPdfParamsRaw(
    slipMap:        slip.toMap(),
    itemMaps:       items.map((i) => i.toMap()).toList(),
    logoBytes:      logoBytes,
    qrGmBytes:      qrGmBytes,
    qrAnjumanBytes: qrAnjumanBytes,
  ));
}

Future<Uint8List> _buildBankSlipIsolate(_BankSlipPdfParamsRaw p) async {
  return await _buildBankSlipSync(p);
}

Future<Uint8List> _buildBankSlipSync(_BankSlipPdfParamsRaw p) async {
  final slip = BankSlip.fromMap(p.slipMap);

  final pdf  = pw.Document();
  final fontB = pw.Font.helveticaBold();
  final fontR = pw.Font.helvetica();

  final accent   = PdfColor.fromHex('#92400E');
  final accentLt = PdfColor.fromHex('#FEF3C7');
  final cWhite   = PdfColors.white;
  final cInk     = PdfColor.fromHex('#1F2937');
  final cInkGrey = PdfColor.fromHex('#6B7280');
  final cRule    = PdfColor.fromHex('#E5E7EB');

  pw.MemoryImage? logo, qrGm, qrAnjuman;
  if (p.logoBytes != null)      logo      = pw.MemoryImage(p.logoBytes!);
  if (p.qrGmBytes != null)      qrGm      = pw.MemoryImage(p.qrGmBytes!);
  if (p.qrAnjumanBytes != null) qrAnjuman = pw.MemoryImage(p.qrAnjumanBytes!);

  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    header: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 20),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: cRule, width: 1)),
      ),
      padding: const pw.EdgeInsets.only(bottom: 16),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Row(children: [
            if (logo != null)
              pw.Container(
                width: 44, height: 44,
                margin: const pw.EdgeInsets.only(right: 12),
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('WEEKLY BANK SLIP', style: pw.TextStyle(
                  font: fontB, fontSize: 18, color: accent)),
              pw.Text('Gulzar Madina Welfare Foundation', style: pw.TextStyle(
                  font: fontR, fontSize: 10, color: cInkGrey)),
            ]),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Ref: ${slip.id}', style: pw.TextStyle(
                font: fontB, fontSize: 10, color: cInk)),
            pw.Text('Date: ${_fmtDate(slip.depositDate)}', style: pw.TextStyle(
                font: fontR, fontSize: 10, color: cInkGrey)),
            pw.Text('Week: ${slip.weekLabel}', style: pw.TextStyle(
                font: fontR, fontSize: 9, color: cInkGrey)),
          ]),
        ],
      ),
    ),
    build: (ctx) => [
      // ── Donor + summary box ────────────────────────────────────────────
      pw.Container(
        padding: const pw.EdgeInsets.all(20),
        decoration: pw.BoxDecoration(
          color: accentLt,
          borderRadius: pw.BorderRadius.circular(12),
          border: pw.Border.all(
              color: PdfColor(accent.red, accent.green, accent.blue, 0.3)),
        ),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('DONOR', style: pw.TextStyle(font: fontB, fontSize: 8,
                color: accent, letterSpacing: 1)),
            pw.SizedBox(height: 4),
            pw.Text(slip.donorName, style: pw.TextStyle(font: fontB,
                fontSize: 14, color: cInk)),
            pw.SizedBox(height: 8),
            pw.Text('TOTAL DEPOSIT AMOUNT', style: pw.TextStyle(font: fontB,
                fontSize: 10, color: accent)),
            pw.Text('PKR ${_fmtNum(slip.amount)}', style: pw.TextStyle(font: fontB,
                fontSize: 28, color: accent)),
          ])),
          pw.Container(
              width: 1, height: 80,
              color: PdfColor(accent.red, accent.green, accent.blue, 0.2),
              margin: const pw.EdgeInsets.symmetric(horizontal: 20)),
          pw.Expanded(child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('BANK DETAILS', style: pw.TextStyle(font: fontB,
                fontSize: 8, color: accent, letterSpacing: 1)),
            pw.SizedBox(height: 4),
            pw.Text(slip.bankName, style: pw.TextStyle(font: fontB,
                fontSize: 13, color: cInk)),
            pw.Text('A/C: ${slip.accountNumber}', style: pw.TextStyle(
                font: fontR, fontSize: 10, color: cInkGrey)),
            if (slip.slipNumber.isNotEmpty) ...[
              pw.SizedBox(height: 6),
              pw.Text('Slip #: ${slip.slipNumber}', style: pw.TextStyle(
                  font: fontB, fontSize: 10, color: cInk)),
            ],
          ])),
        ]),
      ),
      pw.SizedBox(height: 30),

      // ── Transactions table ─────────────────────────────────────────────
      pw.Text('VERIFIED DONATIONS SUMMARY', style: pw.TextStyle(font: fontB,
          fontSize: 12, color: cInk, letterSpacing: 0.5)),
      pw.SizedBox(height: 10),

      pw.Table(
        border: pw.TableBorder.all(color: cRule, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(1.2),
          1: const pw.FlexColumnWidth(1.5),
          2: const pw.FlexColumnWidth(2.0),
          3: const pw.FlexColumnWidth(1.8),
          4: const pw.FlexColumnWidth(1.2),
          5: const pw.FlexColumnWidth(1.4),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F3F4F6')),
            children: [
              _cell('Date',       fontB, 9, true),
              _cell('Receipt #',  fontB, 9, true),
              _cell('Donor',      fontB, 9, true),
              _cell('Category',   fontB, 9, true),
              _cell('Type',       fontB, 9, true),
              _cell('Amount',     fontB, 9, true, alignRight: true),
            ],
          ),
          ...p.itemMaps.map((m) {
            final catId     = (m['categoryId'] as String? ?? '');
            final gmwfSubId = (m['gmwfSubCategoryId'] as String? ?? '');
            final subtypeId = (m['subtypeId'] as String? ?? '');
            final isGoods   = (m['entryType'] as String? ?? '') == 'goods';
            final amt       = (m['amount'] as num?)?.toDouble() ?? 0.0;
            final donorName = (m['donorName'] as String? ?? '');
            // Strip -L/-O suffix from receipt numbers in the table
            final receiptNo = cleanReceiptNumber((m['receiptNo'] as String? ?? ''));
            final date      = (m['date'] as String? ?? '');

            final mCat    = DonationCategory.values.firstWhereOrNull((c) => c.name == catId);
            final gmwfSub = GmwfSubCategory.values.firstWhereOrNull((s) => s.name == gmwfSubId);
            final subtype = DonationSubtype.values.firstWhereOrNull((s) => s.name == subtypeId);

            String catLabel = mCat?.label ?? catId;
            if (gmwfSub != null) catLabel += '\n${gmwfSub.label}';
            final typeLabel = isGoods ? 'Goods' : (subtype?.label ?? 'Cash');

            return pw.TableRow(children: [
              _cell(_fmtDate(date), fontR, 8, false),
              _cell(receiptNo,      fontR, 8, false),
              _cell(donorName,      fontR, 8, false),
              _cell(catLabel,       fontR, 8, false),
              _cell(typeLabel,      fontR, 8, false),
              _cell(_fmtNum(amt),   fontB, 8, false, alignRight: true),
            ]);
          }),
          // Total row
          pw.TableRow(
            decoration: pw.BoxDecoration(
                color: PdfColor(accentLt.red, accentLt.green, accentLt.blue, 0.8)),
            children: [
              _cell('', fontB, 9, true),
              _cell('', fontB, 9, true),
              _cell('', fontB, 9, true),
              _cell('', fontB, 9, true),
              _cell('TOTAL', fontB, 9, true),
              _cell('PKR ${_fmtNum(slip.amount)}', fontB, 9, true, alignRight: true),
            ],
          ),
        ],
      ),

      pw.SizedBox(height: 40),

      // ── Signature lines ────────────────────────────────────────────────
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Container(width: 160, height: 0.5, color: cInkGrey),
          pw.SizedBox(height: 6),
          pw.Text('Branch Manager / Uploaded By: ${slip.uploadedBy}',
              style: pw.TextStyle(font: fontR, fontSize: 8, color: cInkGrey)),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Container(width: 160, height: 0.5, color: cInkGrey),
          pw.SizedBox(height: 6),
          pw.Text('Head Office Verification',
              style: pw.TextStyle(font: fontR, fontSize: 8, color: cInkGrey)),
        ]),
      ]),

      if (slip.notes != null && slip.notes!.isNotEmpty) ...[
        pw.SizedBox(height: 20),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: accentLt,
              borderRadius: pw.BorderRadius.circular(8),
              border: pw.Border.all(color: accent, width: 0.5)),
          child: pw.Row(children: [
            pw.Text('Notes: ', style: pw.TextStyle(font: fontB, fontSize: 9, color: accent)),
            pw.Expanded(child: pw.Text(slip.notes!, style: pw.TextStyle(font: fontR, fontSize: 9, color: cInk))),
          ]),
        ),
      ],
    ],
    footer: (ctx) => pw.Container(
      padding: const pw.EdgeInsets.only(top: 10),
      decoration: pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: cRule, width: 0.5))),
      child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
        pw.Row(children: [
          // Anjuman QR → gulzarmadina.com
          if (qrAnjuman != null) ...[
            _qrBlock(qrAnjuman, 'gulzarmadina.com', cWhite, dark: cInkGrey),
            pw.SizedBox(width: 10),
          ],
          // GMWF QR → gmwf.pk  (NOT gmwf.org.pk)
          if (qrGm != null)
            _qrBlock(qrGm, 'gmwf.pk', cWhite, dark: cInkGrey),
        ]),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: pw.TextStyle(font: fontR, fontSize: 8, color: cInkGrey)),
      ]),
    ),
  ));

  return await pdf.save();
}

// ─────────────────────────────────────────────────────────────────────────────
// CSV EXPORT
// ─────────────────────────────────────────────────────────────────────────────

String buildDonationsCsv(List<Map<String, dynamic>> donations) {
  final sb = StringBuffer();
  sb.writeln('Receipt No,Date,Donor Name,Phone,Category,Programme,Sub-Type,'
      'Entry Type,Amount,Unit,Payment Method,Branch,Recorded By,Status,Notes');

  for (final d in donations) {
    String esc(dynamic v) {
      final s = (v ?? '').toString().replaceAll('"', '""');
      return '"$s"';
    }
    final catId     = d['categoryId']        as String? ?? '';
    final gmwfId    = d['gmwfSubCategoryId'] as String? ?? '';
    final subtypeId = d['subtypeId']         as String? ?? '';
    final cat       = DonationCategory.values.firstWhereOrNull((c) => c.name == catId);
    final gmwfSub   = GmwfSubCategory.values.firstWhereOrNull((s) => s.name == gmwfId);
    final subtype   = DonationSubtype.values.firstWhereOrNull((s) => s.name == subtypeId);
    // Clean receipt number in CSV export too
    final cleanRcpt = cleanReceiptNumber(d['receiptNo'] as String? ?? '');

    sb.writeln([
      esc(cleanRcpt),
      esc(d['date']),
      esc(d['donorName']),
      esc(d['phone']),
      esc(cat?.label ?? catId),
      esc(gmwfSub?.label ?? gmwfId),
      esc(subtype?.label ?? subtypeId),
      esc((d['entryType'] as String? ?? '') == 'goods' ? 'Goods' : 'Cash'),
      esc(d['amount']),
      esc(d['unit']),
      esc(d['paymentMethod']),
      esc(d['branchName']),
      esc(d['recordedBy']),
      esc(d['status']),
      esc(d['notes']),
    ].join(','));
  }
  return sb.toString();
}

// ─────────────────────────────────────────────────────────────────────────────
// PDF WIDGET HELPERS
// ─────────────────────────────────────────────────────────────────────────────

pw.Widget _cell(String text, pw.Font font, double size, bool header,
    {bool alignRight = false}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.all(8),
    child: pw.Text(
      text,
      textAlign: alignRight ? pw.TextAlign.right : pw.TextAlign.left,
      style: pw.TextStyle(font: font, fontSize: size),
    ),
  );
}

pw.Widget _qrBlock(pw.MemoryImage img, String label, PdfColor cWhite,
    {PdfColor? dark}) {
  final labelColor = dark ?? const PdfColor(1, 1, 1, 0.7);
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
    pw.Container(
      width: 48, height: 48, padding: const pw.EdgeInsets.all(3),
      decoration: pw.BoxDecoration(color: cWhite,
          borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Image(img, fit: pw.BoxFit.contain),
    ),
    pw.SizedBox(height: 3),
    pw.Text(label, style: pw.TextStyle(fontSize: 6, color: labelColor,
        fontWeight: pw.FontWeight.bold)),
  ]);
}

pw.Widget _pdfRow(String label, String value, PdfColor lc, PdfColor vc) =>
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(width: 100,
          child: pw.Text(label.toUpperCase(), style: pw.TextStyle(fontSize: 7,
              color: lc, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8))),
      pw.Expanded(child: pw.Text(value, style: pw.TextStyle(fontSize: 10,
          color: vc, fontWeight: pw.FontWeight.bold))),
    ]);

pw.TableRow _pdfTableRow(String label, String value) =>
    pw.TableRow(children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Text(label.toUpperCase(), style: pw.TextStyle(fontSize: 7,
            color: const PdfColor.fromInt(0xFF94A3B8),
            fontWeight: pw.FontWeight.bold, letterSpacing: 0.8))),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Text(value, style: pw.TextStyle(fontSize: 9,
            color: const PdfColor.fromInt(0xFF0F172A),
            fontWeight: pw.FontWeight.bold))),
    ]);

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _fmtNum(double v) => NumberFormat('#,##0', 'en_US').format(v);
String _fmtDate(String? raw) {
  try {
    return DateFormat('dd MMM yyyy').format(DateTime.parse(raw ?? ''));
  } catch (_) {
    return raw ?? DateFormat('dd MMM yyyy').format(DateTime.now());
  }
}

String fmtNum(double v) => _fmtNum(v);
String fmtAmt(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

// ─────────────────────────────────────────────────────────────────────────────
// SHARE ACTION SHEET — non-blocking bottom sheet with all share options.
// PDF is built in a background isolate via compute() so the UI never freezes.
// A guard flag (_shareSheetOpen) prevents opening multiple sheets at once.
// ─────────────────────────────────────────────────────────────────────────────

bool _shareSheetOpen = false;

Future<void> directWhatsAppText(Map<String, dynamic> donationData) async {
  final receiptNo = cleanReceiptNumber(donationData['receiptNo'] as String? ?? '');
  String phone    = (donationData['phone'] as String? ?? '').replaceAll(RegExp(r'\D'), '');
  final donorName = donationData['donorName'] as String? ?? 'Donor';
  final amount    = (donationData['amount'] as num?)?.toDouble() ?? 0;
  final isGoods   = (donationData['entryType'] as String? ?? '') == 'goods';
  final goodsItem = donationData['goodsItem'] as String? ?? '';
  final date      = donationData['date'] as String? ?? '';

  final msg = buildThankYouMessage(
    donorName:     donorName,
    receiptNo:     receiptNo,
    category:      DonationCategory.values.firstWhereOrNull((c) => c.name == (donationData['categoryId'] as String? ?? '')) ?? DonationCategory.gmwf,
    amount:        amount,
    unit:          donationData['unit'] as String? ?? 'PKR',
    branchName:    donationData['branchName'] as String? ?? '',
    paymentMethod: donationData['paymentMethod'] as String? ?? 'Cash',
    isGoods:       isGoods,
    date:          date,
    goodsItem:     goodsItem,
  );

  if (phone.startsWith('0')) phone = '92${phone.substring(1)}';
  final waUri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
  if (await canLaunchUrl(waUri)) {
    await launchUrl(waUri, mode: LaunchMode.externalApplication);
  }
}

Future<void> directWhatsAppPdf(BuildContext context, Map<String, dynamic> donationData) async {
  final receiptNo = cleanReceiptNumber(donationData['receiptNo'] as String? ?? '');
  
  // Show a loading dialog since PDF generation takes time
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
  );

  try {
    final enriched = await injectPdfAssets(donationData);
    final bytes = kIsWeb 
        ? await _buildReceiptPdfIsolate(enriched)
        : await compute(_buildReceiptPdfIsolate, enriched);
    
    if (context.mounted) Navigator.pop(context); // Remove loading
    
    await Printing.sharePdf(bytes: bytes, filename: 'Receipt-$receiptNo.pdf');
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF Error: $e'), backgroundColor: Colors.red));
    }
  }
}


void showReceiptShareSheet(
    BuildContext context, Map<String, dynamic> donationData) {
  if (_shareSheetOpen) return;
  _shareSheetOpen = true;

  final receiptNo = cleanReceiptNumber(donationData['receiptNo'] as String? ?? '');
  final phone     = (donationData['phone'] as String? ?? '').replaceAll(RegExp(r'\D'), '');
  final donorName = donationData['donorName'] as String? ?? 'Donor';
  final amount    = (donationData['amount'] as num?)?.toDouble() ?? 0;
  final isGoods   = (donationData['entryType'] as String? ?? '') == 'goods';
  final goodsItem = donationData['goodsItem'] as String? ?? '';
  final date      = donationData['date'] as String? ?? '';

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => StatefulBuilder(
      builder: (context, setModalState) {
        bool generating = false;

        Future<void> shareFile() async {
          setModalState(() => generating = true);
          try {
            final enriched = await injectPdfAssets(donationData);
            final bytes = kIsWeb 
                ? await _buildReceiptPdfIsolate(enriched)
                : await compute(_buildReceiptPdfIsolate, enriched);
            
            // Build the caption message
            final msg = buildThankYouMessage(
              donorName:     donorName,
              receiptNo:     receiptNo,
              category:      DonationCategory.values.firstWhereOrNull((c) => c.name == (donationData['categoryId'] as String? ?? '')) ?? DonationCategory.gmwf,
              amount:        amount,
              unit:          donationData['unit'] as String? ?? 'PKR',
              branchName:    donationData['branchName'] as String? ?? '',
              paymentMethod: donationData['paymentMethod'] as String? ?? 'Cash',
              isGoods:       isGoods,
              date:          date,
              goodsItem:     goodsItem,
            );

            if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
              // MOBILE & WINDOWS: Share using XFiles to support attachments with captions
              await Share.shareXFiles(
                [XFile.fromData(bytes, name: 'Receipt-$receiptNo.pdf', mimeType: 'application/pdf')],
                text: msg,
              );
            } else {
              // WEB: Download PDF + Copy Text to Clipboard
              await Printing.sharePdf(bytes: bytes, filename: 'Receipt-$receiptNo.pdf');
              await Clipboard.setData(ClipboardData(text: msg));
              
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('PDF Saved & Message copied to clipboard!'),
                    backgroundColor: AppColors.primary,
                  )
                );
              }
            }
          } finally {
            setModalState(() => generating = false);
          }
        }

        Future<void> printPdf() async {
          setModalState(() => generating = true);
          try {
            final enriched = await injectPdfAssets(donationData);
            final bytes = kIsWeb 
                ? await _buildReceiptPdfIsolate(enriched)
                : await compute(_buildReceiptPdfIsolate, enriched);
            await Printing.layoutPdf(
              format: kReceiptFormat,
              onLayout: (_) async => bytes,
            );
          } finally {
            setModalState(() => generating = false);
          }
        }

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          padding: EdgeInsets.fromLTRB(24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(color: AppColors.gray200, borderRadius: BorderRadius.circular(2)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Image.asset('assets/logo/gmwf-1.webp', height: 32),
                  const Text('Share Receipt', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.gray900)),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: AppColors.gray400),
                    style: IconButton.styleFrom(backgroundColor: AppColors.gray100),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Amount Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  color: AppColors.gray50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.gray100),
                ),
                child: Column(
                  children: [
                    Text(donorName.toUpperCase(), 
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.gray500, letterSpacing: 1)),
                    const SizedBox(height: 8),
                    if (isGoods)
                      Text(goodsItem.isNotEmpty ? goodsItem : 'Goods Donation',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.gray900))
                    else
                      Text('PKR ${NumberFormat('#,##0').format(amount)}',
                          style: GoogleFonts.dmMono(fontSize: 32, fontWeight: FontWeight.w900, color: AppColors.gray900)),
                    const SizedBox(height: 4),
                    Text('Receipt #$receiptNo', style: GoogleFonts.dmMono(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.gray50.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.gray100),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _premiumShareBtn(
                      label: 'WhatsApp',
                      color: const Color(0xFF25D366),
                      asset: 'assets/icons/WA.webp',
                      onTap: () async {
                        final msg = buildThankYouMessage(
                          donorName:     donorName,
                          receiptNo:     receiptNo,
                          category:      DonationCategory.values.firstWhereOrNull((c) => c.name == (donationData['categoryId'] as String? ?? '')) ?? DonationCategory.gmwf,
                          amount:        amount,
                          unit:          donationData['unit'] as String? ?? 'PKR',
                          branchName:    donationData['branchName'] as String? ?? '',
                          paymentMethod: donationData['paymentMethod'] as String? ?? 'Cash',
                          isGoods:       isGoods,
                          date:          date,
                          goodsItem:     goodsItem,
                        );
                        String cleanPhone = phone;
                        if (cleanPhone.startsWith('0')) cleanPhone = '92${cleanPhone.substring(1)}';
                        final waUri = Uri.parse('https://wa.me/$cleanPhone?text=${Uri.encodeComponent(msg)}');
                        if (await canLaunchUrl(waUri)) await launchUrl(waUri, mode: LaunchMode.externalApplication);
                      },
                    ),
                    _premiumShareBtn(
                      label: 'SMS',
                      color: const Color(0xFF3B82F6),
                      icon: Icons.chat_bubble_rounded,
                      onTap: () async {
                        final body = buildThankYouMessage(
                          donorName:     donorName,
                          receiptNo:     receiptNo,
                          category:      DonationCategory.values.firstWhereOrNull((c) => c.name == (donationData['categoryId'] as String? ?? '')) ?? DonationCategory.gmwf,
                          amount:        amount,
                          unit:          donationData['unit'] as String? ?? 'PKR',
                          branchName:    donationData['branchName'] as String? ?? '',
                          paymentMethod: donationData['paymentMethod'] as String? ?? 'Cash',
                          isGoods:       isGoods,
                          date:          date,
                          goodsItem:     goodsItem,
                          branchId:      donationData['branchId'] as String? ?? '',
                        );
                        final smsUri = Uri(scheme: 'sms', path: phone, queryParameters: {'body': body});
                        if (await canLaunchUrl(smsUri)) await launchUrl(smsUri, mode: LaunchMode.externalApplication);
                      },
                    ),
                    _premiumShareBtn(
                      label: 'Print',
                      color: const Color(0xFF6366F1),
                      icon: Icons.print_rounded,
                      onTap: printPdf,
                      isLoading: generating,
                    ),
                    _premiumShareBtn(
                      label: 'Copy',
                      color: const Color(0xFF64748B),
                      icon: Icons.content_copy_rounded,
                      onTap: () async {
                        final msg = buildThankYouMessage(
                          donorName:     donorName,
                          receiptNo:     receiptNo,
                          category:      DonationCategory.values.firstWhereOrNull((c) => c.name == (donationData['categoryId'] as String? ?? '')) ?? DonationCategory.gmwf,
                          amount:        amount,
                          unit:          donationData['unit'] as String? ?? 'PKR',
                          branchName:    donationData['branchName'] as String? ?? '',
                          paymentMethod: donationData['paymentMethod'] as String? ?? 'Cash',
                          isGoods:       isGoods,
                          date:          date,
                          goodsItem:     goodsItem,
                        );
                        await Clipboard.setData(ClipboardData(text: msg));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), backgroundColor: AppColors.primary));
                        }
                      },
                    ),
                  ],
                ),
              ),
              if (phone.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text('Add a phone number to enable messaging',
                      style: TextStyle(fontSize: 11, color: AppColors.gray400, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        );
      }
    ),
  ).whenComplete(() => _shareSheetOpen = false);
}

Future<void> _handlePdfShare(BuildContext context, Map<String, dynamic> donationData, String receiptNo) async {
  _showLoading(context, 'Generating Receipt PDF...');
  try {
    final enriched = await injectPdfAssets(donationData);
    final bytes = kIsWeb 
        ? await _buildReceiptPdfIsolate(enriched)
        : await compute(_buildReceiptPdfIsolate, enriched);
    if (context.mounted) {
      Navigator.pop(context);
      await Printing.sharePdf(bytes: bytes, filename: 'Receipt-$receiptNo.pdf');
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF Error: $e'), backgroundColor: Colors.red));
    }
  }
}

Future<void> _handlePrint(BuildContext context, Map<String, dynamic> donationData) async {
  _showLoading(context, 'Preparing for Print...');
  try {
    final enriched = await injectPdfAssets(donationData);
    final bytes = kIsWeb 
        ? await _buildReceiptPdfIsolate(enriched)
        : await compute(_buildReceiptPdfIsolate, enriched);
    if (context.mounted) {
      Navigator.pop(context);
      await Printing.layoutPdf(
        format: kReceiptFormat,
        onLayout: (_) async => bytes,
      );
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print Error: $e'), backgroundColor: Colors.red));
    }
  }
}

void _showLoading(BuildContext context, String title) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF047857)),
            const SizedBox(height: 20),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    ),
  );
}

Widget _premiumShareBtn({
  required String label,
  required Color color,
  IconData? icon,
  String? asset,
  required VoidCallback? onTap,
  bool isLoading = false,
}) {
  return InkWell(
    onTap: onTap != null && !isLoading ? onTap : null,
    borderRadius: BorderRadius.circular(20),
    child: Opacity(
      opacity: onTap == null ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.1)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLoading)
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: color))
            else ...[
              if (asset != null)
                Image.asset(asset, height: 26, width: 26, color: color)
              else
                Icon(icon, color: color, size: 26),
            ],
            const SizedBox(height: 10),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    ),
  );
}

// Keep old _ShareOption for compatibility if needed elsewhere, though usually internal
class _ShareOption extends StatelessWidget {
  final IconData? icon;
  final String? assetPath;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback? onTap;
   const _ShareOption({
    this.icon,
    this.assetPath,
    required this.label,
    required this.color, required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final c = enabled ? color : t.textTertiary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: enabled ? color.withValues(alpha: 0.12) : t.bgCardAlt,
            borderRadius: BorderRadius.circular(DS.rLg),
            border: Border.all(
                color: enabled ? color.withValues(alpha: 0.4) : t.bgRule,
                width: 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (assetPath != null)
              Image.asset(assetPath!, width: 24, height: 24, color: c)
            else if (icon != null)
              Icon(icon!, color: c, size: 24),
            const SizedBox(height: 6),
            Text(label, style: DS.label(color: c).copyWith(fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class DSField extends StatelessWidget {
  final TextEditingController      controller;
  final String                     label, hint;
  final IconData                   icon;
  final Color                      accentColor;
  final TextInputType?             keyboardType;
  final List<TextInputFormatter>?  formatters;
  final String? Function(String?)? validator;
  final int                        maxLines;
  final TextCapitalization         textCapitalization;
  final TextInputAction?           textInputAction;
  final FocusNode?                 focusNode;
  final ValueChanged<String>?      onFieldSubmitted;

  const DSField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.accentColor,
    this.keyboardType,
    this.formatters,
    this.validator,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.words,
    this.textInputAction,
    this.focusNode,
    this.onFieldSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (label.isNotEmpty) ...[
        Text(label.toUpperCase(), style: DS.label(color: t.textTertiary)
            .copyWith(fontSize: 10, letterSpacing: 1.0)),
        const SizedBox(height: 6),
      ],
      TextFormField(
        controller:         controller,
        focusNode:          focusNode,
        onFieldSubmitted:   onFieldSubmitted,
        keyboardType:       keyboardType,
        inputFormatters:    formatters,
        validator:          validator,
        maxLines:           maxLines,
        textCapitalization: textCapitalization,
        textInputAction:    textInputAction,
        autocorrect:        false,
        enableSuggestions:
            keyboardType == TextInputType.name || keyboardType == null,
        style: DS.body(color: t.textPrimary)
            .copyWith(fontWeight: FontWeight.w500, fontSize: 15),
        decoration: InputDecoration(
          hintText:   hint,
          hintStyle:  DS.body(color: t.textTertiary).copyWith(fontSize: 14),
          prefixIcon: Icon(icon, color: accentColor, size: 18),
          filled:     true,
          fillColor:  t.bgCardAlt,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: accentColor, width: 1.5)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.rMd),
              borderSide: BorderSide(color: t.danger)),
          errorStyle:     DS.caption(color: t.danger),
          contentPadding: const EdgeInsets.symmetric(
              vertical: 14, horizontal: 16),
        ),
      ),
    ]);
  }
}

class DSSubtypeSelector extends StatelessWidget {
  final List<DonationSubtype>         subtypes;
  final DonationSubtype               selected;
  final ValueChanged<DonationSubtype> onChanged;
  const DSSubtypeSelector({
    super.key,
    required this.subtypes,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Wrap(spacing: 8, runSpacing: 8, children: subtypes.map((st) {
      final sel = st == selected;
      return GestureDetector(
        onTap: () => onChanged(st),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: sel ? st.color.withValues(alpha: 0.12) : t.bgCardAlt,
            borderRadius: BorderRadius.circular(DS.rMd),
            border: Border.all(color: sel ? st.color : t.bgRule,
                width: sel ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(st.icon, size: 13, color: sel ? st.color : t.textTertiary),
            const SizedBox(width: 6),
            Text(st.label, style: DS.label(
                    color: sel ? st.color : t.textTertiary)
                .copyWith(letterSpacing: 0.3, fontSize: 11)),
          ]),
        ),
      );
    }).toList());
  }
}

class DSPaymentMethodSelector extends StatelessWidget {
  final PaymentMethod selected;
  final ValueChanged<PaymentMethod> onChanged;
  final Color accentColor;

  const DSPaymentMethodSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Wrap(spacing: 8, runSpacing: 8, children: PaymentMethod.values.map((pm) {
      final sel = pm == selected;
      return GestureDetector(
        onTap: () => onChanged(pm),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: sel ? accentColor.withValues(alpha: 0.10) : t.bgCardAlt,
            borderRadius: BorderRadius.circular(DS.rMd),
            border: Border.all(color: sel ? accentColor : t.bgRule,
                width: sel ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(pm.icon, size: 13, color: sel ? accentColor : t.textTertiary),
            const SizedBox(width: 6),
            Text(pm.label, style: DS.label(
                    color: sel ? accentColor : t.textTertiary)
                .copyWith(letterSpacing: 0.3, fontSize: 11,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      );
    }).toList());
  }
}

class DSStatusBadge extends StatelessWidget {
  final String status;
  const DSStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final Color fg; final Color bg; final Color border; final String lbl;

    switch (status) {
      case kStatusPending:
        fg = DS.statusPending; bg = DS.statusPendingBg;
        border = DS.statusPendingBorder; lbl = 'PENDING';
        break;
      case kStatusReceived:
        fg = DS.statusReceived; bg = DS.statusReceivedBg;
        border = DS.statusReceivedBorder; lbl = 'RECEIVED';
        break;
      default:
        fg = DS.statusPending; bg = DS.statusPendingBg;
        border = DS.statusPendingBorder; lbl = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DS.rSm),
        border: Border.all(color: border),
      ),
      child: Text(lbl, style: DS.label(color: fg)
          .copyWith(fontSize: 9, letterSpacing: 0.8)),
    );
  }
}

class DSSubtypeBadge extends StatelessWidget {
  final DonationSubtype subtype;
  const DSSubtypeBadge({super.key, required this.subtype});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: subtype.color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(DS.rSm),
      border: Border.all(color: subtype.color.withValues(alpha: 0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(subtype.icon, size: 10, color: subtype.color),
      const SizedBox(width: 4),
      Text(subtype.label, style: DS.label(color: subtype.color)
          .copyWith(fontSize: 9, letterSpacing: 0.3)),
    ]),
  );
}

class DSActionButton extends StatelessWidget {
  final IconData?    icon;
  final String?      assetImage;
  final String       label;
  final Color        color;
  final VoidCallback onTap;
  final bool         disabled;
  const DSActionButton({
    super.key, this.icon, this.assetImage,
    required this.label, required this.color,
    required this.onTap, this.disabled = false,
  }) : assert(icon != null || assetImage != null);

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final c = disabled ? t.textTertiary : color;
    final Widget iconW = assetImage != null
        ? ColorFiltered(
            colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
            child: Image.asset(assetImage!, width: 13, height: 13))
        : Icon(icon!, size: 13, color: c);
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: disabled ? t.bgCardAlt : color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(DS.rSm),
          border: Border.all(
              color: disabled ? t.bgRule : color.withValues(alpha: 0.22)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          iconW, const SizedBox(width: 5),
          Text(label, style: DS.label(color: c)
              .copyWith(letterSpacing: 0.3, fontSize: 11)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INTERACTIVE SCALE WRAPPER (Public)
// ─────────────────────────────────────────────────────────────────────────────

class ScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const ScaleButton({super.key, required this.child, this.onTap});
  @override
  State<ScaleButton> createState() => _ScaleButtonState();
}

class _ScaleButtonState extends State<ScaleButton> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 100), lowerBound: 0.94, upperBound: 1.0, value: 1.0);
    super.initState();
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => _ctrl.animateTo(0.94, curve: Curves.easeOut),
    onTapUp:   (_) { _ctrl.animateTo(1.0, curve: Curves.elasticOut); widget.onTap?.call(); },
    onTapCancel: () => _ctrl.animateTo(1.0),
    child: ScaleTransition(scale: _ctrl, child: widget.child),
  );
}
