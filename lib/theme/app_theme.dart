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
import 'package:gmwf/design/tokens/colors.dart';
import 'package:gmwf/design/tokens/shadows.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/theme/app_visual_theme.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GThemeChoice, GComfortColors;

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
  school,
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

  // Sidebar & active preset surface tokens
  final Color sidebarBg;
  final Color sidebarBgSecondary;
  final Color sidebarBorder;
  final Color sidebarText;
  final Color sidebarTextActive;
  final Color sidebarActiveBg;
  final Color sidebarActiveLine;
  final bool isDarkSidebar;
  final AppVisualTheme visualTheme;

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
    this.sidebarBg = SoftPalette.pureWhiteSoft,
    this.sidebarBgSecondary = SoftPalette.slate100,
    this.sidebarBorder = SoftPalette.slate200,
    this.sidebarText = SoftPalette.slate600,
    this.sidebarTextActive = SoftPalette.slate900,
    this.sidebarActiveBg = SoftPalette.indigo100,
    this.sidebarActiveLine = SoftPalette.cobaltBlue,
    this.isDarkSidebar = false,
    this.visualTheme = AppVisualTheme.classicRoleLight,
  });

  // Design System v2 surfaces. Every role shares one neutral canvas per mode;
  // the role identity lives in the accent. Cards sit clearly above the canvas
  // separated by crisp 1px hairlines and deliberate categorical color contrast.
  RoleThemeData toDarkMode() {
    final darkAccent = _liftForDark(accent);
    return RoleThemeData(
      roleLabel: roleLabel,
      bg: SoftPalette.slate900,
      bgCard: SoftPalette.slate800,
      bgCardAlt: SoftPalette.slate750,
      bgRule: SoftPalette.slate700,
      accent: darkAccent,
      accentLight: _liftForDark(accentLight),
      // Light tints glare on a dark canvas: use the accent washed over the card.
      accentMuted: Color.alphaBlend(darkAccent.withValues(alpha: 0.18), SoftPalette.slate800),
      accentGradient: LinearGradient(colors: [darkAccent, _liftForDark(accentLight)]),
      glassTint: darkAccent.withValues(alpha: 0.14),
      textPrimary: SoftPalette.gray150,
      textSecondary: SoftPalette.slate300,
      textTertiary: SoftPalette.slate400,
      danger: SoftPalette.brightCoral,
      zakat: SoftPalette.brightMint,
      nonZakat: SoftPalette.brightCobalt,
      gmwf: SoftPalette.brightGold,
      cardFillTokens: darkAccent,
      cardFillPrescriptions: _liftForDark(cardFillPrescriptions),
      cardFillDispensary: _liftForDark(cardFillDispensary),
      chartBar1: darkAccent,
      chartBar2: SoftPalette.brightMint,
      chartBar3: SoftPalette.brightCobalt,
      chartGrid: SoftPalette.slate750,
      isDarkCanvas: true,
      sidebarBg: SoftPalette.slate900,
      sidebarBgSecondary: SoftPalette.slate800,
      sidebarBorder: SoftPalette.slate700,
      sidebarText: SoftPalette.slate350,
      sidebarTextActive: SoftPalette.gray150,
      sidebarActiveBg: Color.alphaBlend(darkAccent.withValues(alpha: 0.22), SoftPalette.slate800),
      sidebarActiveLine: darkAccent,
      isDarkSidebar: true,
      visualTheme: AppVisualTheme.classicRoleDark,
    );
  }

  static Color _liftForDark(Color c) => GColor.accentOnDark(c);

  RoleThemeData toLightMode() {
    return RoleThemeData(
      roleLabel: roleLabel,
      bg: SoftPalette.slate100,
      bgCard: SoftPalette.pureWhiteSoft,
      bgCardAlt: SoftPalette.slate50,
      bgRule: SoftPalette.slate200,
      accent: accent,
      accentLight: accentLight,
      accentMuted: Color.alphaBlend(accent.withValues(alpha: 0.10), SoftPalette.pureWhiteSoft),
      accentGradient: accentGradient,
      glassTint: accent.withValues(alpha: 0.12),
      textPrimary: SoftPalette.slate900,
      textSecondary: SoftPalette.slate600,
      textTertiary: SoftPalette.slate500,
      danger: SoftPalette.roseCoral,
      zakat: SoftPalette.jadeEmerald,
      nonZakat: SoftPalette.cobaltBlue,
      gmwf: SoftPalette.warmMarigold,
      cardFillTokens: cardFillTokens,
      cardFillPrescriptions: cardFillPrescriptions,
      cardFillDispensary: cardFillDispensary,
      chartBar1: accent,
      chartBar2: SoftPalette.jadeEmerald,
      chartBar3: SoftPalette.cobaltBlue,
      chartGrid: SoftPalette.slate200,
      isDarkCanvas: false,
      sidebarBg: SoftPalette.pureWhiteSoft,
      sidebarBgSecondary: SoftPalette.slate100,
      sidebarBorder: SoftPalette.slate200,
      sidebarText: SoftPalette.slate600,
      sidebarTextActive: accent,
      sidebarActiveBg: Color.alphaBlend(accent.withValues(alpha: 0.11), SoftPalette.pureWhiteSoft),
      sidebarActiveLine: accent,
      isDarkSidebar: false,
      visualTheme: AppVisualTheme.classicRoleLight,
    );
  }

  /// The role's colours for a theme. Since 2026-11-17 the preset only says
  /// which of the three themes (GMWF / Nexus / Twilight) and which mode; every
  /// colour comes from the shared design system (gmwf_ui), the same palette
  /// as the root theme, School and the websites.
  RoleThemeData withVisualTheme(
    AppVisualTheme theme, {
    Color? customAccent,
    bool? isDark,
  }) {
    final effective = isDark == null ? theme : theme.pairedForDarkMode(isDark);
    final choice = ui.GThemeChoice.fromStorageKey(effective.storageKey);
    final colors = ui.GTheme.colors(
      effective.isDark ? Brightness.dark : Brightness.light,
      family: choice.family,
      brandOverride: customAccent,
    );
    return withDesignSystem(colors, isDark: effective.isDark, legacyPreset: effective);
  }

  /// Builds the role colours from design-system colours [c]. Domain colours
  /// (zakat / non-zakat / GMWF fund) keep their fixed meaning.
  RoleThemeData withDesignSystem(ui.GComfortColors c, {required bool isDark, AppVisualTheme? legacyPreset}) {
    final hsv = HSVColor.fromColor(c.brand);
    final darkShade = hsv.withValue((hsv.value - 0.16).clamp(0.0, 1.0)).toColor();
    final darkerShade = hsv.withValue((hsv.value - 0.28).clamp(0.0, 1.0)).toColor();
    final lightAccent = hsv
        .withValue((hsv.value + (isDark ? 0.12 : 0.18)).clamp(0.0, 1.0))
        .withSaturation((hsv.saturation - 0.12).clamp(0.0, 1.0))
        .toColor();
    return RoleThemeData(
      roleLabel: roleLabel,
      bg: c.background,
      bgCard: c.surface,
      bgCardAlt: c.surfaceSunken,
      bgRule: c.border,
      accent: c.brand,
      accentLight: lightAccent,
      accentMuted: c.brandSoft,
      accentGradient: LinearGradient(colors: isDark ? [c.brand, lightAccent] : [c.brand, c.brandStrong]),
      glassTint: c.brand.withValues(alpha: isDark ? 0.16 : 0.12),
      textPrimary: c.textPrimary,
      textSecondary: c.textSecondary,
      textTertiary: c.textMuted,
      danger: c.danger,
      zakat: isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald,
      nonZakat: isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue,
      gmwf: isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold,
      cardFillTokens: c.brand,
      cardFillPrescriptions: darkShade,
      cardFillDispensary: darkerShade,
      chartBar1: c.chart1,
      chartBar2: c.chart2,
      chartBar3: c.chart3,
      chartGrid: c.border,
      isDarkCanvas: isDark,
      sidebarBg: c.sidebarBg,
      sidebarBgSecondary: c.sidebarBgAlt,
      sidebarBorder: c.sidebarBorder,
      sidebarText: c.sidebarText,
      sidebarTextActive: c.sidebarTextActive,
      sidebarActiveBg: c.sidebarActiveBg,
      sidebarActiveLine: c.sidebarActiveLine,
      isDarkSidebar: c.sidebarBg.computeLuminance() < 0.35,
      visualTheme: legacyPreset ?? (isDark ? AppVisualTheme.emeraldMeridianDark : AppVisualTheme.emeraldMeridianHybrid),
    );
  }
  // ── Chairman – warm light canvas in light mode, soft brass-gold accent ─────
  static const RoleThemeData _chairman = RoleThemeData(
    roleLabel:             'CHAIRMAN',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate100,
    bgRule:                SoftPalette.slate150,
    accent:                SoftPalette.amber500,
    accentLight:           SoftPalette.amber400,
    accentMuted:           SoftPalette.yellow50m,
    accentGradient:        LinearGradient(colors: [SoftPalette.amber500, SoftPalette.amber400]),
    glassTint:             SoftPalette.amber350A10,
    textPrimary:           SoftPalette.slate900,
    textSecondary:         SoftPalette.slate600,
    textTertiary:          SoftPalette.slate350,
    danger:                SoftPalette.red500,
    zakat:                 SoftPalette.green400,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber350,
    cardFillTokens:        SoftPalette.amber500,
    cardFillPrescriptions: SoftPalette.amber400,
    cardFillDispensary:    SoftPalette.amber550m,
    chartBar1:             SoftPalette.amber500,
    chartBar2:             SoftPalette.green400,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.slate150,
  );

  // ── CEO – crisp steel-blue accent ──────────────────────────────────────────
  static const RoleThemeData _ceo = RoleThemeData(
    roleLabel:             'CEO',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate100,
    bgRule:                SoftPalette.slate150,
    accent:                SoftPalette.blue550,
    accentLight:           SoftPalette.blue500,
    accentMuted:           SoftPalette.indigo100,
    accentGradient:        LinearGradient(colors: [SoftPalette.blue550, SoftPalette.blue600]),
    glassTint:             SoftPalette.blue500A10,
    textPrimary:           SoftPalette.slate900,
    textSecondary:         SoftPalette.slate600,
    textTertiary:          SoftPalette.slate350,
    danger:                SoftPalette.red500,
    zakat:                 SoftPalette.green400,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber350,
    cardFillTokens:        SoftPalette.blue550,
    cardFillPrescriptions: SoftPalette.blue600,
    cardFillDispensary:    SoftPalette.blue700,
    chartBar1:             SoftPalette.blue550,
    chartBar2:             SoftPalette.green400,
    chartBar3:             SoftPalette.amber350,
    chartGrid:             SoftPalette.slate150,
  );

  // ── Global User – distinct teal-emerald accent ────────────────────────────
  static const RoleThemeData _globalUser = RoleThemeData(
    roleLabel:             'GLOBAL USER',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate100,
    bgRule:                SoftPalette.slate150,
    accent:                SoftPalette.teal550,
    accentLight:           SoftPalette.teal400,
    accentMuted:           SoftPalette.teal100m,
    accentGradient:        LinearGradient(colors: [SoftPalette.teal550, SoftPalette.teal600]),
    glassTint:             SoftPalette.teal400A10,
    textPrimary:           SoftPalette.slate900,
    textSecondary:         SoftPalette.slate600,
    textTertiary:          SoftPalette.slate350,
    danger:                SoftPalette.red500,
    zakat:                 SoftPalette.green400,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber350,
    cardFillTokens:        SoftPalette.teal550,
    cardFillPrescriptions: SoftPalette.teal600,
    cardFillDispensary:    SoftPalette.teal700,
    chartBar1:             SoftPalette.teal550,
    chartBar2:             SoftPalette.green400,
    chartBar3:             SoftPalette.blue350,
    chartGrid:             SoftPalette.slate150,
  );

  // ── Manager / HQ Manager – slate-indigo, light surface ───────────────────
  // Professional and clean — clearly different from the dark global-exec look.
  static const RoleThemeData _manager = RoleThemeData(
    roleLabel:             'MANAGER',
    isDarkCanvas:          false,
    bg:                    SoftPalette.slate100,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate150,
    bgRule:                SoftPalette.slate200,
    accent:                SoftPalette.blue600,
    accentLight:           SoftPalette.blue500,
    accentMuted:           SoftPalette.slate150,
    accentGradient:        LinearGradient(colors: [SoftPalette.blue600, SoftPalette.blue500]),
    glassTint:             SoftPalette.blue600A10,
    textPrimary:           SoftPalette.slate900,
    textSecondary:         SoftPalette.blue700,
    textTertiary:          SoftPalette.blue500,
    danger:                SoftPalette.red550,
    zakat:                 SoftPalette.green550,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber500,
    cardFillTokens:        SoftPalette.blue600,
    cardFillPrescriptions: SoftPalette.blue700,
    cardFillDispensary:    SoftPalette.slate800,
    chartBar1:             SoftPalette.blue600,
    chartBar2:             SoftPalette.green550,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.slate200,
  );

  // ── HQ Manager – deep teal / executive ───────────────────────────────────
  // Rank 3: corporate strategic authority — premium teal, calming confidence.
  static const RoleThemeData _hqManager = RoleThemeData(
    roleLabel:             'MANAGER',
    isDarkCanvas:          false,
    bg:                    SoftPalette.cyan50t,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.cyan100m,
    bgRule:                SoftPalette.cyan200,
    accent:                SoftPalette.teal600,
    accentLight:           SoftPalette.teal500,
    accentMuted:           SoftPalette.teal150m,
    accentGradient:        LinearGradient(colors: [SoftPalette.teal600, SoftPalette.teal500]),
    glassTint:             SoftPalette.teal600A10,
    textPrimary:           SoftPalette.emerald900,
    textSecondary:         SoftPalette.teal700,
    textTertiary:          SoftPalette.teal350,
    danger:                SoftPalette.red550,
    zakat:                 SoftPalette.green550,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber500,
    cardFillTokens:        SoftPalette.teal600,
    cardFillPrescriptions: SoftPalette.teal700,
    cardFillDispensary:    SoftPalette.teal750,
    chartBar1:             SoftPalette.teal600,
    chartBar2:             SoftPalette.green550,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.cyan200,
  );

  // ── Branch Manager – sapphire indigo ─────────────────────────────────────
  // Rank 4: strong local leadership — trustworthy, professional, below HQ teal.
  static const RoleThemeData _branchManager = RoleThemeData(
    roleLabel:             'BRANCH MANAGER',
    isDarkCanvas:          false,
    bg:                    SoftPalette.slate100,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate150,
    bgRule:                SoftPalette.slate200,
    accent:                SoftPalette.blue600,
    accentLight:           SoftPalette.blue550,
    accentMuted:           SoftPalette.slate150,
    accentGradient:        LinearGradient(colors: [SoftPalette.blue600, SoftPalette.blue550]),
    glassTint:             SoftPalette.blue600A10,
    textPrimary:           SoftPalette.blue900,
    textSecondary:         SoftPalette.indigo700,
    textTertiary:          SoftPalette.indigo500,
    danger:                SoftPalette.red550,
    zakat:                 SoftPalette.green550,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber500,
    cardFillTokens:        SoftPalette.blue600,
    cardFillPrescriptions: SoftPalette.blue750,
    cardFillDispensary:    SoftPalette.blue550,
    chartBar1:             SoftPalette.blue600,
    chartBar2:             SoftPalette.green550,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.slate200,
  );

  // ── Admin / Global Admin – cool grey-blue ─────────────────────────────────
  static const RoleThemeData _admin = RoleThemeData(
    roleLabel:             'ADMIN',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray100,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate100,
    bgRule:                SoftPalette.slate150,
    accent:                SoftPalette.blue600,
    accentLight:           SoftPalette.blue550,
    accentMuted:           SoftPalette.slate150,
    accentGradient:        LinearGradient(colors: [SoftPalette.blue600, SoftPalette.blue550]),
    glassTint:             SoftPalette.blue600A10,
    textPrimary:           SoftPalette.slate900,
    textSecondary:         SoftPalette.slate700,
    textTertiary:          SoftPalette.blue400m,
    danger:                SoftPalette.red550,
    zakat:                 SoftPalette.green550,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber500,
    cardFillTokens:        SoftPalette.blue700,
    cardFillPrescriptions: SoftPalette.blue600,
    cardFillDispensary:    SoftPalette.slate800,
    chartBar1:             SoftPalette.blue600,
    chartBar2:             SoftPalette.green550,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.slate150,
  );

  // ── Doctor – deep teal-cyan clinical ──────────────────────────────────────
  static const RoleThemeData _doctor = RoleThemeData(
    roleLabel:             'DOCTOR',
    bg:                    SoftPalette.cyan50t,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.cyan100m,
    bgRule:                SoftPalette.cyan200,
    accent:                SoftPalette.cyan550,
    accentLight:           SoftPalette.cyan400,
    accentMuted:           SoftPalette.cyan150m,
    accentGradient:        LinearGradient(colors: [SoftPalette.cyan550, SoftPalette.cyan600]),
    glassTint:             SoftPalette.cyan550A10,
    textPrimary:           SoftPalette.slate750,
    textSecondary:         SoftPalette.sky600,
    textTertiary:          SoftPalette.cyan400,
    danger:                SoftPalette.vividRed,
    zakat:                 SoftPalette.vividGreen,
    nonZakat:              SoftPalette.vividBlue,
    gmwf:                  SoftPalette.amber350,
    cardFillTokens:        SoftPalette.cyan550,
    cardFillPrescriptions: SoftPalette.cyan500,
    cardFillDispensary:    SoftPalette.cyan600,
    chartBar1:             SoftPalette.cyan550,
    chartBar2:             SoftPalette.vividGreen,
    chartBar3:             SoftPalette.vividBlue,
    chartGrid:             SoftPalette.cyan200,
  );

  // ── Supervisor – forest / sage green ──────────────────────────────────────
  // Rank 6: floor / ops control — brightened emerald so the accent reads as
  // confident and energetic rather than grey-green.
  static const RoleThemeData _supervisor = RoleThemeData(
    roleLabel:             'SUPERVISOR',
    bg:                    SoftPalette.emerald100t,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.emerald150m,
    bgRule:                SoftPalette.emerald200m,
    accent:                SoftPalette.emerald550,
    accentLight:           SoftPalette.emerald400,
    accentMuted:           SoftPalette.emerald150m,
    accentGradient:        LinearGradient(colors: [SoftPalette.emerald550, SoftPalette.emerald600]),
    glassTint:             SoftPalette.emerald550A10,
    textPrimary:           SoftPalette.emerald800m,
    textSecondary:         SoftPalette.emerald700m,
    textTertiary:          SoftPalette.emerald400m,
    danger:                SoftPalette.vividRed,
    zakat:                 SoftPalette.vividGreen,
    nonZakat:              SoftPalette.vividBlue,
    gmwf:                  SoftPalette.amber350,
    cardFillTokens:        SoftPalette.emerald500,
    cardFillPrescriptions: SoftPalette.emerald600,
    cardFillDispensary:    SoftPalette.emerald400,
    chartBar1:             SoftPalette.emerald550,
    chartBar2:             SoftPalette.vividBlue,
    chartBar3:             SoftPalette.vividAmber,
    chartGrid:             SoftPalette.emerald200m,
  );

  // ── Dispenser – clinical teal pharmacy ─────────────────────────────────────
  // Uses healthcare teal so dispensing actions and pharmacy views align
  // with the clinic dispensary theme (green/emerald/teal) rather than purple/red.
  static const RoleThemeData _dispenser = RoleThemeData(
    roleLabel:             'DISPENSER',
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.teal150t,
    bgRule:                SoftPalette.teal200m,
    accent:                SoftPalette.teal600,
    accentLight:           SoftPalette.teal550,
    accentMuted:           SoftPalette.teal150m,
    accentGradient:        LinearGradient(colors: [SoftPalette.teal600, SoftPalette.teal500]),
    glassTint:             SoftPalette.teal600A10,
    textPrimary:           SoftPalette.teal800,
    textSecondary:         SoftPalette.teal700,
    textTertiary:          SoftPalette.teal500,
    danger:                SoftPalette.red550,
    zakat:                 SoftPalette.green550,
    nonZakat:              SoftPalette.blue550,
    gmwf:                  SoftPalette.amber500,
    cardFillTokens:        SoftPalette.teal600,
    cardFillPrescriptions: SoftPalette.teal750,
    cardFillDispensary:    SoftPalette.teal600,
    chartBar1:             SoftPalette.teal600,
    chartBar2:             SoftPalette.green550,
    chartBar3:             SoftPalette.blue550,
    chartGrid:             SoftPalette.teal200m,
  );

  // ── Receptionist – warm rose ──────────────────────────────────────────────
  // Uses vivid red for the accent so the front-desk role is clearly recognisable
  // at a glance; backgrounds remain soft so it doesn't feel like an error state.
  static const RoleThemeData _receptionist = RoleThemeData(
    roleLabel:             'RECEPTIONIST',
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.red150t,
    bgRule:                SoftPalette.pink200m,
    // v2: dusty rose instead of alarm red, so the whole reception UI no
    // longer reads as an error state.
    accent:                SoftPalette.pink550,
    accentLight:           SoftPalette.pink400,
    accentMuted:           SoftPalette.pink100m,
    accentGradient:        LinearGradient(colors: [SoftPalette.pink550, SoftPalette.pink600]),
    glassTint:             SoftPalette.red500A10,
    textPrimary:           SoftPalette.red800,
    textSecondary:         SoftPalette.red700m,
    textTertiary:          SoftPalette.red400m,
    danger:                SoftPalette.vividRed,
    zakat:                 SoftPalette.vividGreen,
    nonZakat:              SoftPalette.vividBlue,
    gmwf:                  SoftPalette.vividAmber,
    cardFillTokens:        SoftPalette.pink550,
    cardFillPrescriptions: SoftPalette.pink600,
    cardFillDispensary:    SoftPalette.pink500,
    chartBar1:             SoftPalette.pink550,
    chartBar2:             SoftPalette.vividGreen,
    chartBar3:             SoftPalette.vividBlue,
    chartGrid:             SoftPalette.pink200m,
  );

  // ── Madrassa – indigo & soft brass gold ───────────────────────────────────
  // A scholarly, premium theme for the educational wing — deepened slightly
  // from the original bright indigo/amber pairing for a calmer, more
  // "reading room" feel; gold now matches the chairman's brass tone.
  static const RoleThemeData _madrassa = RoleThemeData(
    roleLabel:             'MADRASSA',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray50,
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate50,
    bgRule:                SoftPalette.slate150,
    accent:                SoftPalette.indigo700,
    accentLight:           SoftPalette.indigo550,
    accentMuted:           SoftPalette.violet150m,
    accentGradient:        LinearGradient(colors: [SoftPalette.indigo700, SoftPalette.indigo550]),
    glassTint:             SoftPalette.indigo700A10,
    textPrimary:           SoftPalette.indigo800,
    textSecondary:         SoftPalette.indigo700,
    textTertiary:          SoftPalette.indigo500,
    danger:                SoftPalette.red400,
    zakat:                 SoftPalette.emerald350,
    nonZakat:              SoftPalette.blue500,
    gmwf:                  SoftPalette.amber350, // Soft brass gold
    cardFillTokens:        SoftPalette.indigo700,
    cardFillPrescriptions: SoftPalette.indigo750,
    cardFillDispensary:    SoftPalette.indigo800,
    chartBar1:             SoftPalette.indigo700,
    chartBar2:             SoftPalette.emerald350,
    chartBar3:             SoftPalette.amber350,
    chartGrid:             SoftPalette.slate150,
  );

  // ── School – sophisticated navy-teal academic palette ──────────────────────
  // A refined, professional educational theme — deep ocean teal conveys
  // institutional trust and academic excellence, paired with warm slate
  // neutrals and soft sage accents for data visualization.
  static const RoleThemeData _school = RoleThemeData(
    roleLabel:             'SCHOOL',
    isDarkCanvas:          false,
    bg:                    SoftPalette.gray50, // Cool off-white
    bgCard:                SoftPalette.gray50,
    bgCardAlt:             SoftPalette.slate100, // Slate-tinted alt card
    bgRule:                SoftPalette.slate200, // Soft slate border
    accent:                SoftPalette.sky700, // Deep Ocean Teal
    accentLight:           SoftPalette.sky550, // Medium Ocean
    accentMuted:           SoftPalette.slate150, // Pale ocean wash
    accentGradient:        LinearGradient(colors: [SoftPalette.sky700, SoftPalette.sky550]),
    glassTint:             SoftPalette.sky700A10,
    textPrimary:           SoftPalette.slate900, // Deep navy text
    textSecondary:         SoftPalette.blue600, // Muted navy-blue
    textTertiary:          SoftPalette.sky400m, // Soft steel-blue
    danger:                SoftPalette.red500, // Warm red (not neon)
    zakat:                 SoftPalette.teal500, // Teal-sage green
    nonZakat:              SoftPalette.blue500, // Academic blue
    gmwf:                  SoftPalette.yellow400, // Warm antique gold
    cardFillTokens:        SoftPalette.sky700,
    cardFillPrescriptions: SoftPalette.slate750,
    cardFillDispensary:    SoftPalette.slate800,
    chartBar1:             SoftPalette.sky700,
    chartBar2:             SoftPalette.teal500,
    chartBar3:             SoftPalette.yellow400,
    chartGrid:             SoftPalette.slate200,
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
      case RoleTheme.school:        base = _school; break;
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
      sidebarBg:             base.sidebarBg,
      sidebarBgSecondary:    base.sidebarBgSecondary,
      sidebarBorder:         base.sidebarBorder,
      sidebarText:           base.sidebarText,
      sidebarTextActive:     base.sidebarTextActive,
      sidebarActiveBg:       base.sidebarActiveBg,
      sidebarActiveLine:     base.sidebarActiveLine,
      isDarkSidebar:         base.isDarkSidebar,
      visualTheme:           base.visualTheme,
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
      case 'school principal':
      case 'principal':
      case 'school admin':
      case 'school teacher':
      case 'school':          return RoleTheme.school;
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
    sidebarBg:             sidebarBg,
    sidebarBgSecondary:    sidebarBgSecondary,
    sidebarBorder:         sidebarBorder,
    sidebarText:           sidebarText,
    sidebarTextActive:     sidebarTextActive,
    sidebarActiveBg:       sidebarActiveBg,
    sidebarActiveLine:     sidebarActiveLine,
    isDarkSidebar:         isDarkSidebar,
    visualTheme:           visualTheme,
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
          color: SoftPalette.gray900.withValues(alpha: 0.02),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
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
                const SizedBox(height: 4),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.accentMuted.withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
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
// Raised surface helper (Design System v2)
// Formerly neumorphic dual shadows; now delegates to the flat GShadow scale so
// every legacy caller picks up the clean border + soft shadow look.
// ─────────────────────────────────────────────────────────────────────────────

class Neumorphic3DStyle {
  static List<BoxShadow> raisedShadows({
    required bool isDark,
    Color? accentColor,
    double depth = 1.0,
    bool showGlow = false,
  }) =>
      GShadow.raised(isDark: isDark, accent: accentColor, depth: depth, showGlow: showGlow);

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
        color: borderColor ?? (isDark ? SoftPalette.slate700 : SoftPalette.slate150),
        width: 1,
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
