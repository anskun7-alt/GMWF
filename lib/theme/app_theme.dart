// lib/theme/app_theme.dart
//
// ── THEME OVERVIEW ────────────────────────────────────────────────────────────
//  Rank 1  Chairman     → Soft Brass Gold + Charcoal Navy — institutional authority
//  Rank 2  CEO          → Muted Steel Blue + Navy         — executive leadership
//  Rank 3  HQ Manager   → Deep Teal                       — corporate strategic
//  Rank 4  Branch Mgr   → Sapphire Indigo                 — strong local leadership
//  Rank 5  Admin        → Cool Grey-Blue / Slate          — system administration
//  Rank 6  Supervisor   → Forest / Sage Green             — floor / ops control
//  Rank 7  Doctor       → Deep Teal-Cyan clinical
//  Rank 8  Dispenser    → Muted Slate-Plum pharmacy
//  Rank 9  Receptionist → Dusty Rose reception
//
// Palette philosophy: muted, low-saturation, HR/corporate-friendly tones —
// legible on both light and dark canvases, no neon/candy colors. Rank is
// communicated through hue family and canvas (dark for top exec tier, light
// for operational tiers) rather than brightness or saturation.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

enum RoleTheme {
  chairman,
  ceo,
  globalUser,     // cross-branch viewer – dark canvas, teal-emerald accent
  admin,
  manager,        // generic manager / light-surface indigo
  hqManager,      // HQ Manager – same palette as manager, distinct label
  branchManager,  // Branch Manager – sapphire indigo, field authority
  doctor,
  supervisor,
  dispenser,
  receptionist,
  madrassa,
}

class RoleThemeData {
  final String roleLabel;

  final Color bg;
  final Color bgCard;
  final Color bgCardAlt;
  final Color bgRule;

  final Color accent;
  final Color accentLight;
  final Color accentMuted;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color danger;
  final Color zakat;
  final Color nonZakat;
  final Color gmwf;

  final Color cardFillTokens;
  final Color cardFillPrescriptions;
  final Color cardFillDispensary;

  final Color chartBar1;
  final Color chartBar2;
  final Color chartBar3;
  final Color chartGrid;

  final LinearGradient accentGradient;
  final Color glassTint;
  final bool isDarkCanvas;

  const RoleThemeData({
    required this.roleLabel,
    required this.bg,
    required this.bgCard,
    required this.bgCardAlt,
    required this.bgRule,
    required this.accent,
    required this.accentLight,
    required this.accentMuted,
    required this.accentGradient,
    required this.glassTint,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.danger,
    required this.zakat,
    required this.nonZakat,
    required this.gmwf,
    required this.cardFillTokens,
    required this.cardFillPrescriptions,
    required this.cardFillDispensary,
    required this.chartBar1,
    required this.chartBar2,
    required this.chartBar3,
    required this.chartGrid,
    this.isDarkCanvas = false,
  });

  RoleThemeData toDarkMode() {
    return RoleThemeData(
      roleLabel: roleLabel,
      bg: const Color(0xFF0B0F19),
      bgCard: const Color(0xFF161B22),
      bgCardAlt: const Color(0xFF21262D),
      bgRule: const Color(0xFF30363D),
      accent: accent,
      accentLight: accentLight,
      accentMuted: accentMuted,
      accentGradient: accentGradient,
      glassTint: glassTint,
      textPrimary: const Color(0xFFF8FAFC),
      textSecondary: const Color(0xFFCBD5E1),
      textTertiary: const Color(0xFF94A3B8),
      danger: danger,
      zakat: zakat,
      nonZakat: nonZakat,
      gmwf: gmwf,
      cardFillTokens: cardFillTokens,
      cardFillPrescriptions: cardFillPrescriptions,
      cardFillDispensary: cardFillDispensary,
      chartBar1: chartBar1,
      chartBar2: chartBar2,
      chartBar3: chartBar3,
      chartGrid: const Color(0xFF30363D),
      isDarkCanvas: true,
    );
  }

  RoleThemeData toLightMode() {
    return RoleThemeData(
      roleLabel: roleLabel,
      bg: const Color(0xFFF8FAFC),
      bgCard: const Color(0xFFFFFFFF),
      bgCardAlt: const Color(0xFFF1F5F9),
      bgRule: const Color(0xFFE2E8F0),
      accent: accent,
      accentLight: accentLight,
      accentMuted: accentMuted,
      accentGradient: accentGradient,
      glassTint: glassTint,
      textPrimary: const Color(0xFF0F172A),
      textSecondary: const Color(0xFF475569),
      textTertiary: const Color(0xFF94A3B8),
      danger: danger,
      zakat: zakat,
      nonZakat: nonZakat,
      gmwf: gmwf,
      cardFillTokens: cardFillTokens,
      cardFillPrescriptions: cardFillPrescriptions,
      cardFillDispensary: cardFillDispensary,
      chartBar1: chartBar1,
      chartBar2: chartBar2,
      chartBar3: chartBar3,
      chartGrid: const Color(0xFFE2E8F0),
      isDarkCanvas: false,
    );
  }

  // ── Chairman – warm light canvas in light mode, soft brass-gold accent ─────
  static const RoleThemeData _chairman = RoleThemeData(
    roleLabel:             'CHAIRMAN',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF8FAFC),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFF1F5F9),
    bgRule:                Color(0xFFE2E8F0),
    accent:                Color(0xFFC6A15B),
    accentLight:           Color(0xFFDDC088),
    accentMuted:           Color(0xFFFDF7E7),
    accentGradient:        LinearGradient(colors: [Color(0xFFC6A15B), Color(0xFF9C7C3C)]),
    glassTint:             Color(0x1AC6A15B),
    textPrimary:           Color(0xFF0F172A),
    textSecondary:         Color(0xFF475569),
    textTertiary:          Color(0xFF94A3B8),
    danger:                Color(0xFFDC2626),
    zakat:                 Color(0xFF16A34A),
    nonZakat:              Color(0xFF2563EB),
    gmwf:                  Color(0xFFC6A15B),
    cardFillTokens:        Color(0xFFC6A15B),
    cardFillPrescriptions: Color(0xFFA98A4A),
    cardFillDispensary:    Color(0xFF8A6E38),
    chartBar1:             Color(0xFFC6A15B),
    chartBar2:             Color(0xFF16A34A),
    chartBar3:             Color(0xFF2563EB),
    chartGrid:             Color(0xFFE2E8F0),
  );

  // ── CEO – crisp steel-blue accent ──────────────────────────────────────────
  static const RoleThemeData _ceo = RoleThemeData(
    roleLabel:             'CEO',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF8FAFC),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFF1F5F9),
    bgRule:                Color(0xFFE2E8F0),
    accent:                Color(0xFF4A7FB5),
    accentLight:           Color(0xFF6D9BC7),
    accentMuted:           Color(0xFFEDF4FA),
    accentGradient:        LinearGradient(colors: [Color(0xFF4A7FB5), Color(0xFF335E8C)]),
    glassTint:             Color(0x1A4A7FB5),
    textPrimary:           Color(0xFF0F172A),
    textSecondary:         Color(0xFF475569),
    textTertiary:          Color(0xFF94A3B8),
    danger:                Color(0xFFDC2626),
    zakat:                 Color(0xFF16A34A),
    nonZakat:              Color(0xFF2563EB),
    gmwf:                  Color(0xFFC6A15B),
    cardFillTokens:        Color(0xFF4A7FB5),
    cardFillPrescriptions: Color(0xFF335E8C),
    cardFillDispensary:    Color(0xFF23456A),
    chartBar1:             Color(0xFF4A7FB5),
    chartBar2:             Color(0xFF16A34A),
    chartBar3:             Color(0xFFC6A15B),
    chartGrid:             Color(0xFFE2E8F0),
  );

  // ── Global User – distinct teal-emerald accent ────────────────────────────
  static const RoleThemeData _globalUser = RoleThemeData(
    roleLabel:             'GLOBAL USER',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF8FAFC),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFF1F5F9),
    bgRule:                Color(0xFFE2E8F0),
    accent:                Color(0xFF3E9C8A),
    accentLight:           Color(0xFF63B8A7),
    accentMuted:           Color(0xFFE6F5F2),
    accentGradient:        LinearGradient(colors: [Color(0xFF3E9C8A), Color(0xFF2A7566)]),
    glassTint:             Color(0x1A3E9C8A),
    textPrimary:           Color(0xFF0F172A),
    textSecondary:         Color(0xFF475569),
    textTertiary:          Color(0xFF94A3B8),
    danger:                Color(0xFFDC2626),
    zakat:                 Color(0xFF16A34A),
    nonZakat:              Color(0xFF2563EB),
    gmwf:                  Color(0xFFC6A15B),
    cardFillTokens:        Color(0xFF3E9C8A),
    cardFillPrescriptions: Color(0xFF2A7566),
    cardFillDispensary:    Color(0xFF1B4E45),
    chartBar1:             Color(0xFF3E9C8A),
    chartBar2:             Color(0xFF16A34A),
    chartBar3:             Color(0xFF60A5FA),
    chartGrid:             Color(0xFFE2E8F0),
  );

  // ── Manager / HQ Manager – slate-indigo, light surface ───────────────────
  // Professional and clean — clearly different from the dark global-exec look.
  static const RoleThemeData _manager = RoleThemeData(
    roleLabel:             'MANAGER',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF1F3F8),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFE8ECF5),
    bgRule:                Color(0xFFD0D7E8),
    accent:                Color(0xFF3F5487),
    accentLight:           Color(0xFF5B71AC),
    accentMuted:           Color(0xFFE1E5F4),
    accentGradient:        LinearGradient(colors: [Color(0xFF3F5487), Color(0xFF5B71AC)]),
    glassTint:             Color(0x1A3F5487),
    textPrimary:           Color(0xFF0E1526),
    textSecondary:         Color(0xFF2E3D6B),
    textTertiary:          Color(0xFF7080AC),
    danger:                Color(0xFFC0392B),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB07C2C),
    cardFillTokens:        Color(0xFF3F5487),
    cardFillPrescriptions: Color(0xFF2C3C63),
    cardFillDispensary:    Color(0xFF1D2A47),
    chartBar1:             Color(0xFF3F5487),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFD0D7E8),
  );

  // ── HQ Manager – deep teal / executive ───────────────────────────────────
  // Rank 3: corporate strategic authority — premium teal, calming confidence.
  static const RoleThemeData _hqManager = RoleThemeData(
    roleLabel:             'MANAGER',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF0FAFA),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFE0F5F5),
    bgRule:                Color(0xFFB2E0E0),
    accent:                Color(0xFF0E6E63),
    accentLight:           Color(0xFF16897A),
    accentMuted:           Color(0xFFD3EDEA),
    accentGradient:        LinearGradient(colors: [Color(0xFF0E6E63), Color(0xFF16897A)]),
    glassTint:             Color(0x1A0E6E63),
    textPrimary:           Color(0xFF00251A),
    textSecondary:         Color(0xFF004D40),
    textTertiary:          Color(0xFF4DB6AC),
    danger:                Color(0xFFC0392B),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB07C2C),
    cardFillTokens:        Color(0xFF0E6E63),
    cardFillPrescriptions: Color(0xFF0A4F47),
    cardFillDispensary:    Color(0xFF073B35),
    chartBar1:             Color(0xFF0E6E63),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFB2E0E0),
  );

  // ── Branch Manager – sapphire indigo ─────────────────────────────────────
  // Rank 4: strong local leadership — trustworthy, professional, below HQ teal.
  static const RoleThemeData _branchManager = RoleThemeData(
    roleLabel:             'BRANCH MANAGER',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF2F5FC),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFE4EBFA),
    bgRule:                Color(0xFFC8D4EE),
    accent:                Color(0xFF2C4A8F),
    accentLight:           Color(0xFF4864AD),
    accentMuted:           Color(0xFFDDE3F5),
    accentGradient:        LinearGradient(colors: [Color(0xFF2C4A8F), Color(0xFF4864AD)]),
    glassTint:             Color(0x1A2C4A8F),
    textPrimary:           Color(0xFF0E1838),
    textSecondary:         Color(0xFF253570),
    textTertiary:          Color(0xFF6878B0),
    danger:                Color(0xFFC0392B),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB07C2C),
    cardFillTokens:        Color(0xFF2C4A8F),
    cardFillPrescriptions: Color(0xFF1B2F5E),
    cardFillDispensary:    Color(0xFF4864AD),
    chartBar1:             Color(0xFF2C4A8F),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFC8D4EE),
  );

  // ── Admin / Global Admin – cool grey-blue ─────────────────────────────────
  static const RoleThemeData _admin = RoleThemeData(
    roleLabel:             'ADMIN',
    isDarkCanvas:          false,
    bg:                    Color(0xFFF4F5F8),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFEEF0F5),
    bgRule:                Color(0xFFDCE0EC),
    accent:                Color(0xFF3A5178),
    accentLight:           Color(0xFF56719E),
    accentMuted:           Color(0xFFDEE3EE),
    accentGradient:        LinearGradient(colors: [Color(0xFF3A5178), Color(0xFF56719E)]),
    glassTint:             Color(0x1A3A5178),
    textPrimary:           Color(0xFF131824),
    textSecondary:         Color(0xFF3A4A68),
    textTertiary:          Color(0xFF8090B8),
    danger:                Color(0xFFB91C1C),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB0762A),
    cardFillTokens:        Color(0xFF2A3B5C),
    cardFillPrescriptions: Color(0xFF3A5178),
    cardFillDispensary:    Color(0xFF1C2740),
    chartBar1:             Color(0xFF3A5178),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFDCE0EC),
  );

  // ── Doctor – deep teal-cyan clinical ──────────────────────────────────────
  static const RoleThemeData _doctor = RoleThemeData(
    roleLabel:             'DOCTOR',
    bg:                    Color(0xFFF0FDFD),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFE2F9F9),
    bgRule:                Color(0xFFB7E4E4),
    accent:                Color(0xFF0E7C90),
    accentLight:           Color(0xFF1D9DB4),
    accentMuted:           Color(0xFFD6F0F0),
    accentGradient:        LinearGradient(colors: [Color(0xFF0E7C90), Color(0xFF1D9DB4)]),
    glassTint:             Color(0x1A0E7C90),
    textPrimary:           Color(0xFF083344),
    textSecondary:         Color(0xFF155E75),
    textTertiary:          Color(0xFF67A8B8),
    danger:                Color(0xFFC0392B),
    zakat:                 Color(0xFF166534),
    nonZakat:              Color(0xFF1D4ED8),
    gmwf:                  Color(0xFFB0762A),
    cardFillTokens:        Color(0xFF105F70),
    cardFillPrescriptions: Color(0xFF0E7C90),
    cardFillDispensary:    Color(0xFF0B4A57),
    chartBar1:             Color(0xFF0E7C90),
    chartBar2:             Color(0xFF166534),
    chartBar3:             Color(0xFF1D4ED8),
    chartGrid:             Color(0xFFB7E4E4),
  );

  // ── Supervisor – forest / sage green ──────────────────────────────────────
  // Rank 6: floor / ops control — a muted, grounded green instead of a neon
  // emerald reads as steady operational competence rather than "alert."
  static const RoleThemeData _supervisor = RoleThemeData(
    roleLabel:             'SUPERVISOR',
    bg:                    Color(0xFFF1F8F4),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFE2F0E8),
    bgRule:                Color(0xFFC0DBCB),
    accent:                Color(0xFF2E7D5B),
    accentLight:           Color(0xFF469C77),
    accentMuted:           Color(0xFFDCEEE4),
    accentGradient:        LinearGradient(colors: [Color(0xFF2E7D5B), Color(0xFF469C77)]),
    glassTint:             Color(0x1A2E7D5B),
    textPrimary:           Color(0xFF15291F),
    textSecondary:         Color(0xFF2A4C3B),
    textTertiary:          Color(0xFF6B9680),
    danger:                Color(0xFFB91C1C),
    zakat:                 Color(0xFF388E3C),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB0762A),
    cardFillTokens:        Color(0xFF2E7D5B),
    cardFillPrescriptions: Color(0xFF1F5D43),
    cardFillDispensary:    Color(0xFF469C77),
    chartBar1:             Color(0xFF2E7D5B),
    chartBar2:             Color(0xFF388E3C),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFC0DBCB),
  );

  // ── Dispenser – muted slate-plum pharmacy ─────────────────────────────────
  // Previously a vivid violet (#7C3AED) — softened to a muted slate-plum so
  // it reads as a professional accent rather than a bright "candy" purple.
  static const RoleThemeData _dispenser = RoleThemeData(
    roleLabel:             'DISPENSER',
    bg:                    Color(0xFFF7F6FA),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFEDEBF5),
    bgRule:                Color(0xFFDAD6E8),
    accent:                Color(0xFF5E5490),
    accentLight:           Color(0xFF7C71AC),
    accentMuted:           Color(0xFFE6E3F3),
    accentGradient:        LinearGradient(colors: [Color(0xFF5E5490), Color(0xFF7C71AC)]),
    glassTint:             Color(0x1A5E5490),
    textPrimary:           Color(0xFF262138),
    textSecondary:         Color(0xFF473F63),
    textTertiary:          Color(0xFF7C71AC),
    danger:                Color(0xFFB91C1C),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB0762A),
    cardFillTokens:        Color(0xFF4E4578),
    cardFillPrescriptions: Color(0xFF382F5C),
    cardFillDispensary:    Color(0xFF5E5490),
    chartBar1:             Color(0xFF4E4578),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFDAD6E8),
  );

  // ── Receptionist – dusty rose ──────────────────────────────────────────────
  // Previously a bright pink-red (#E11D48) — softened to a dusty, muted rose
  // so the front-desk role still reads warm and welcoming without looking
  // like an alert/error color.
  static const RoleThemeData _receptionist = RoleThemeData(
    roleLabel:             'RECEPTIONIST',
    bg:                    Color(0xFFFAF6F6),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFF3E9EA),
    bgRule:                Color(0xFFE6D5D8),
    accent:                Color(0xFFB05C6B),
    accentLight:           Color(0xFFC47A87),
    accentMuted:           Color(0xFFF3E4E6),
    accentGradient:        LinearGradient(colors: [Color(0xFFB05C6B), Color(0xFFC47A87)]),
    glassTint:             Color(0x1AB05C6B),
    textPrimary:           Color(0xFF3A2327),
    textSecondary:         Color(0xFF5C3A40),
    textTertiary:          Color(0xFFB08088),
    danger:                Color(0xFFB91C1C),
    zakat:                 Color(0xFF2E7D32),
    nonZakat:              Color(0xFF1565C0),
    gmwf:                  Color(0xFFB0762A),
    cardFillTokens:        Color(0xFF8F4B58),
    cardFillPrescriptions: Color(0xFF6E3841),
    cardFillDispensary:    Color(0xFFB05C6B),
    chartBar1:             Color(0xFF8F4B58),
    chartBar2:             Color(0xFF2E7D32),
    chartBar3:             Color(0xFF1565C0),
    chartGrid:             Color(0xFFE6D5D8),
  );

  // ── Madrassa – indigo & soft brass gold ───────────────────────────────────
  // A scholarly, premium theme for the educational wing — deepened slightly
  // from the original bright indigo/amber pairing for a calmer, more
  // "reading room" feel; gold now matches the chairman's brass tone.
  static const RoleThemeData _madrassa = RoleThemeData(
    roleLabel:             'MADRASSA',
    isDarkCanvas:          false,
    bg:                    Color(0xFFFFFFFF),
    bgCard:                Color(0xFFFFFFFF),
    bgCardAlt:             Color(0xFFF8FAFF),
    bgRule:                Color(0xFFD8DEED),
    accent:                Color(0xFF3B3699),
    accentLight:           Color(0xFF5A54B8),
    accentMuted:           Color(0xFFE2E0F5),
    accentGradient:        LinearGradient(colors: [Color(0xFF3B3699), Color(0xFF5A54B8)]),
    glassTint:             Color(0x1A3B3699),
    textPrimary:           Color(0xFF1E1B4B),
    textSecondary:         Color(0xFF3730A3),
    textTertiary:          Color(0xFF6366F1),
    danger:                Color(0xFFEF4444),
    zakat:                 Color(0xFF10B981),
    nonZakat:              Color(0xFF3B82F6),
    gmwf:                  Color(0xFFC9A046), // Soft brass gold
    cardFillTokens:        Color(0xFF3B3699),
    cardFillPrescriptions: Color(0xFF2B2775),
    cardFillDispensary:    Color(0xFF211F57),
    chartBar1:             Color(0xFF3B3699),
    chartBar2:             Color(0xFF10B981),
    chartBar3:             Color(0xFFC9A046),
    chartGrid:             Color(0xFFD8DEED),
  );

  // ── Factory ───────────────────────────────────────────────────────────────

  factory RoleThemeData.of(RoleTheme role, [Color? customAccent]) {
    RoleThemeData base;
    switch (role) {
      case RoleTheme.chairman:      base = _chairman; break;
      case RoleTheme.ceo:           base = _ceo; break;
      case RoleTheme.globalUser:    base = _globalUser; break;
      case RoleTheme.admin:         base = _admin; break;
      case RoleTheme.manager:       base = _manager; break;
      case RoleTheme.hqManager:     base = _hqManager; break;
      case RoleTheme.branchManager: base = _branchManager; break;
      case RoleTheme.doctor:        base = _doctor; break;
      case RoleTheme.supervisor:    base = _supervisor; break;
      case RoleTheme.dispenser:     base = _dispenser; break;
      case RoleTheme.receptionist:  base = _receptionist; break;
      case RoleTheme.madrassa:      base = _madrassa; break;
    }

    if (customAccent == null) return base;

    // Derived colors from custom accent
    final hsv = HSVColor.fromColor(customAccent);
    final light = hsv.withValue((hsv.value + 0.2).clamp(0.0, 1.0)).withSaturation((hsv.saturation - 0.1).clamp(0.0, 1.0)).toColor();
    final muted = base.isDarkCanvas
        ? hsv.withSaturation((hsv.saturation * 0.4).clamp(0.1, 0.4)).withValue(0.15).toColor()
        : hsv.withSaturation(0.1).withValue(0.95).toColor();
    final dark = hsv.withValue((hsv.value - 0.2).clamp(0.0, 1.0)).toColor();
    final darker = hsv.withValue((hsv.value - 0.35).clamp(0.0, 1.0)).toColor();

    return RoleThemeData(
      roleLabel:             base.roleLabel,
      isDarkCanvas:          base.isDarkCanvas,
      bg:                    base.bg,
      bgCard:                base.bgCard,
      bgCardAlt:             base.bgCardAlt,
      bgRule:                base.bgRule,
      accent:                customAccent,
      accentLight:           light,
      accentMuted:           muted,
      accentGradient:        LinearGradient(colors: [customAccent, dark]),
      glassTint:             customAccent.withValues(alpha: 0.12),
      textPrimary:           base.textPrimary,
      textSecondary:         base.textSecondary,
      textTertiary:          base.textTertiary,
      danger:                base.danger,
      zakat:                 base.zakat,
      nonZakat:              base.nonZakat,
      gmwf:                  base.gmwf,
      cardFillTokens:        customAccent,
      cardFillPrescriptions: dark,
      cardFillDispensary:    darker,
      chartBar1:             customAccent,
      chartBar2:             base.chartBar2,
      chartBar3:             base.chartBar3,
      chartGrid:             base.chartGrid,
    );
  }

  static RoleTheme fromString(String role) {
    switch (role.toLowerCase().trim()) {
      case 'chairman':        return RoleTheme.chairman;
      case 'ceo':             return RoleTheme.ceo;
      case 'global user':     return RoleTheme.globalUser;
      case 'manager':
      case 'hq manager':      return RoleTheme.hqManager;
      case 'branch manager':  return RoleTheme.branchManager;
      case 'doctor':
      case 'doc+rec':
      case 'doc+dis':
      case 'doc+rec+dis':     return RoleTheme.doctor;
      case 'supervisor':      return RoleTheme.supervisor;
      case 'dispenser':
      case 'rec+dis':         return RoleTheme.dispenser;
      case 'receptionist':    return RoleTheme.receptionist;
      case 'madrassa admin':
      case 'madrassa principal':
      case 'madrassa teacher':
      case 'madrassa guardian':
      case 'madrassa':        return RoleTheme.madrassa;
      case 'admin':
      case 'global admin':
      default:                return RoleTheme.admin;
    }
  }

  RoleThemeData withLabel(String label) => RoleThemeData(
    roleLabel:             label,
    isDarkCanvas:          isDarkCanvas,
    bg:                    bg,
    bgCard:                bgCard,
    bgCardAlt:             bgCardAlt,
    bgRule:                bgRule,
    accent:                accent,
    accentLight:           accentLight,
    accentMuted:           accentMuted,
    accentGradient:        accentGradient,
    glassTint:             glassTint,
    textPrimary:           textPrimary,
    textSecondary:         textSecondary,
    textTertiary:          textTertiary,
    danger:                danger,
    zakat:                 zakat,
    nonZakat:              nonZakat,
    gmwf:                  gmwf,
    cardFillTokens:        cardFillTokens,
    cardFillPrescriptions: cardFillPrescriptions,
    cardFillDispensary:    cardFillDispensary,
    chartBar1:             chartBar1,
    chartBar2:             chartBar2,
    chartBar3:             chartBar3,
    chartGrid:             chartGrid,
  );
}

// ── Shared luxury decoration helpers ─────────────────────────────────────────

class LuxuryDeco {
  static BoxDecoration heroDecoration(Color from, Color to, Color accent) {
    return BoxDecoration(
      gradient: LinearGradient(
        colors: [from, to],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: accent.withValues(alpha: 0.20), width: 1),
      boxShadow: [
        BoxShadow(
            color: accent.withValues(alpha: 0.06),
            blurRadius: 32,
            offset: const Offset(0, 8)),
      ],
    );
  }

  static BoxDecoration cardDecoration(Color bg, Color accent) {
    return BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: accent.withValues(alpha: 0.12), width: 1.2),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.04),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.02),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  static Widget label(String text, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
                color: accent, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 10),
        Text(text,
            style: TextStyle(
                color: accent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5)),
      ]),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class LuxuryLoader extends StatelessWidget {
  final Color color;
  final Color bg;
  const LuxuryLoader({super.key, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: bg,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(color: color, strokeWidth: 2.5),
            ),
            const SizedBox(height: 20),
            Text('Loading…',
                style: TextStyle(
                    color: color.withValues(alpha: 0.6),
                    fontSize: 14,
                    letterSpacing: 1)),
          ]),
        ),
      );
}

class LuxuryLoadCard extends StatelessWidget {
  final Color color;
  final double height;
  const LuxuryLoadCard({super.key, required this.color, required this.height});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child:
            Center(child: CircularProgressIndicator(color: color, strokeWidth: 2)),
      );
}

class RevenueBanner extends StatelessWidget {
  final RoleThemeData t;
  final int revenue;
  final int tokens;
  final int dispensed;
  final String? subtitle;

  const RevenueBanner({
    super.key,
    required this.t,
    required this.revenue,
    required this.tokens,
    required this.dispensed,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            t.accent.withValues(alpha: 0.15),
            t.accent.withValues(alpha: 0.05)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.accent.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Revenue',
                    style: TextStyle(
                        color: t.textTertiary,
                        fontSize: 13,
                        letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Text('PKR ${_fmt(revenue)}',
                    style: TextStyle(
                        color: t.accent,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      style:
                          TextStyle(color: t.textTertiary, fontSize: 11)),
                ],
              ]),
        ),
        _statPill(t, Icons.confirmation_number_outlined, '$tokens', 'Tokens'),
        const SizedBox(width: 12),
        _statPill(
            t, Icons.local_pharmacy_outlined, '$dispensed', 'Dispensed'),
      ]),
    );
  }

  Widget _statPill(
      RoleThemeData t, IconData icon, String val, String lbl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accentMuted.withValues(alpha: 0.4)),
      ),
      child: Column(children: [
        Icon(icon, color: t.accentLight, size: 18),
        const SizedBox(height: 6),
        Text(val,
            style: TextStyle(
                color: t.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(lbl,
            style: TextStyle(color: t.textTertiary, fontSize: 11)),
      ]),
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }
}

class PatientTypeCard extends StatelessWidget {
  final RoleThemeData t;
  final String label;
  final int count;
  final int feePerPatient;
  final Color color;
  final IconData? icon;

  const PatientTypeCard({
    super.key,
    required this.t,
    required this.label,
    required this.count,
    required this.feePerPatient,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon ?? Icons.local_hospital_rounded,
              color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: t.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 3),
                Text('$count',
                    style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ]),
        ),
        if (feePerPatient > 0)
          Text('PKR ${count * feePerPatient}',
              style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class RatioBar extends StatelessWidget {
  final int zakat;
  final int nonZakat;
  final int gmwf;
  final int total;
  final RoleThemeData t;

  const RatioBar({
    super.key,
    required this.zakat,
    required this.nonZakat,
    required this.gmwf,
    required this.total,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final zp = total > 0 ? (zakat / total * 100).round() : 0;
    final np = total > 0 ? (nonZakat / total * 100).round() : 0;
    final gp = total > 0 ? (gmwf / total * 100).round() : 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.accentMuted.withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Row(children: [
            if (zakat > 0)
              Expanded(
                  flex: zakat,
                  child: Container(height: 10, color: t.zakat)),
            if (nonZakat > 0)
              Expanded(
                  flex: nonZakat,
                  child: Container(height: 10, color: t.nonZakat)),
            if (gmwf > 0)
              Expanded(
                  flex: gmwf,
                  child: Container(height: 10, color: t.gmwf)),
          ]),
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _leg(t.zakat, 'Zakat', '$zp%'),
          _leg(t.nonZakat, 'Non-Zakat', '$np%'),
          _leg(t.gmwf, 'GMWF', '$gp%'),
        ]),
      ]),
    );
  }

  Widget _leg(Color c, String label, String pct) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text('$label ',
            style: TextStyle(color: t.textTertiary, fontSize: 12)),
        Text(pct,
            style: TextStyle(
                color: t.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
      ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Soft UI (Neumorphism 2.0) 3D Shadow Helper
// ─────────────────────────────────────────────────────────────────────────────

class Neumorphic3DStyle {
  static List<BoxShadow> raisedShadows({
    required bool isDark,
    Color? accentColor,
    double depth = 1.0,
    bool showGlow = false,
  }) {
    if (isDark) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.65),
          blurRadius: (18 * depth).clamp(4.0, 36.0),
          spreadRadius: 1,
          offset: Offset(6 * depth, 8 * depth),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.08),
          blurRadius: (12 * depth).clamp(3.0, 24.0),
          spreadRadius: -1,
          offset: Offset(-4 * depth, -4 * depth),
        ),
        if (showGlow && accentColor != null)
          BoxShadow(
            color: accentColor.withValues(alpha: 0.28),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 6),
          ),
      ];
    } else {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: (18 * depth).clamp(4.0, 36.0),
          spreadRadius: 1,
          offset: Offset(7 * depth, 8 * depth),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.95),
          blurRadius: (14 * depth).clamp(3.0, 28.0),
          spreadRadius: -1,
          offset: Offset(-6 * depth, -6 * depth),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
        if (showGlow && accentColor != null)
          BoxShadow(
            color: accentColor.withValues(alpha: 0.20),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
      ];
    }
  }

  static BoxDecoration raisedDecoration({
    required bool isDark,
    required Color backgroundColor,
    required double borderRadius,
    Color? borderColor,
    Color? accentColor,
    double depth = 1.0,
    bool showGlow = false,
  }) {
    return BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? (isDark ? const Color(0xFF30363D) : const Color(0xFFE2E8F0)),
        width: 1.2,
      ),
      boxShadow: raisedShadows(
        isDark: isDark,
        accentColor: accentColor,
        depth: depth,
        showGlow: showGlow,
      ),
    );
  }
}