// lib/theme/app_visual_theme.dart
//
// Curated app-wide visual themes inspired by the Nexus Server Control Center,
// adapted strictly onto SoftPalette eye-comfort & high-clarity tokens.

import 'package:flutter/painting.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';

/// Named visual theme presets selectable in Settings and synchronized with
/// light/dark mode toggles across the entire application.
enum AppVisualTheme {
  emeraldMeridianHybrid,
  midnightPlumHybrid,
  nexusCoreHybrid,
  classicRoleLight,
  emeraldMeridianDark,
  midnightPlumDark,
  nexusCoreDark,
  classicRoleDark,
}

class AppVisualThemeTokens {
  final AppVisualTheme theme;
  final String storageKey;
  final String name;
  final String badge;
  final String description;
  final bool isDark;
  final bool isDarkSidebar;
  final bool usesRoleAccent;

  // Sidebar surface & ink tokens
  final Color sidebarBg;
  final Color sidebarBgSecondary;
  final Color sidebarBorder;
  final Color sidebarText;
  final Color sidebarTextActive;
  final Color sidebarActiveBg;
  final Color sidebarActiveLine;

  // Main workspace & card surfaces
  final Color mainBg;
  final Color cardBg;
  final Color cardBgAlt;
  final Color cardBorder;

  // Typography
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  // Primary & semantic accents
  final Color primary;
  final Color primaryHover;
  final Color primaryLight;
  final Color secondary;

  const AppVisualThemeTokens({
    required this.theme,
    required this.storageKey,
    required this.name,
    required this.badge,
    required this.description,
    required this.isDark,
    required this.isDarkSidebar,
    required this.usesRoleAccent,
    required this.sidebarBg,
    required this.sidebarBgSecondary,
    required this.sidebarBorder,
    required this.sidebarText,
    required this.sidebarTextActive,
    required this.sidebarActiveBg,
    required this.sidebarActiveLine,
    required this.mainBg,
    required this.cardBg,
    required this.cardBgAlt,
    required this.cardBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.primary,
    required this.primaryHover,
    required this.primaryLight,
    required this.secondary,
  });

  static const AppVisualThemeTokens emeraldMeridianHybrid = AppVisualThemeTokens(
    theme: AppVisualTheme.emeraldMeridianHybrid,
    storageKey: 'emerald_meridian_hybrid',
    name: 'Emerald Meridian',
    badge: 'HYBRID',
    description: 'Deep jade sidebar, airy mint workspace & crisp white cards',
    isDark: false,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.meridianSidebar,
    sidebarBgSecondary: SoftPalette.meridianSidebarAlt,
    sidebarBorder: SoftPalette.meridianSidebarBorder,
    sidebarText: SoftPalette.meridianSidebarText,
    sidebarTextActive: SoftPalette.meridianCard,
    sidebarActiveBg: SoftPalette.meridianSidebarActive,
    sidebarActiveLine: SoftPalette.meridianSidebarLine,
    mainBg: SoftPalette.meridianCanvas,
    cardBg: SoftPalette.meridianCard,
    cardBgAlt: SoftPalette.meridianCardAlt,
    cardBorder: SoftPalette.meridianBorder,
    textPrimary: SoftPalette.meridianText,
    textSecondary: SoftPalette.meridianTextSecondary,
    textTertiary: SoftPalette.meridianTextMuted,
    primary: SoftPalette.jadeEmerald,
    primaryHover: SoftPalette.teal600,
    primaryLight: SoftPalette.brightMint,
    secondary: SoftPalette.cobaltBlue,
  );

  static const AppVisualThemeTokens midnightPlumHybrid = AppVisualThemeTokens(
    theme: AppVisualTheme.midnightPlumHybrid,
    storageKey: 'midnight_plum_hybrid',
    name: 'Midnight Plum',
    badge: 'HYBRID',
    description: 'Dark aubergine sidebar, cloud lilac canvas & violet accents',
    isDark: false,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.plumSidebar,
    sidebarBgSecondary: SoftPalette.plumSidebarAlt,
    sidebarBorder: SoftPalette.plumSidebarBorder,
    sidebarText: SoftPalette.plumSidebarText,
    sidebarTextActive: SoftPalette.plumCard,
    sidebarActiveBg: SoftPalette.plumSidebarActive,
    sidebarActiveLine: SoftPalette.plumSidebarLine,
    mainBg: SoftPalette.plumCanvas,
    cardBg: SoftPalette.plumCard,
    cardBgAlt: SoftPalette.plumCardAlt,
    cardBorder: SoftPalette.plumBorder,
    textPrimary: SoftPalette.plumText,
    textSecondary: SoftPalette.plumTextSecondary,
    textTertiary: SoftPalette.plumTextMuted,
    primary: SoftPalette.royalViolet,
    primaryHover: SoftPalette.violet600,
    primaryLight: SoftPalette.softLavender,
    secondary: SoftPalette.jadeEmerald,
  );

  static const AppVisualThemeTokens nexusCoreHybrid = AppVisualThemeTokens(
    theme: AppVisualTheme.nexusCoreHybrid,
    storageKey: 'nexus_core_hybrid',
    name: 'Nexus Core',
    badge: 'HYBRID',
    description: 'Graphite dark sidebar, cool slate canvas & cobalt blue accents',
    isDark: false,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.nexusSidebar,
    sidebarBgSecondary: SoftPalette.nexusSidebarAlt,
    sidebarBorder: SoftPalette.nexusSidebarBorder,
    sidebarText: SoftPalette.nexusSidebarText,
    sidebarTextActive: SoftPalette.nexusCard,
    sidebarActiveBg: SoftPalette.nexusSidebarActive,
    sidebarActiveLine: SoftPalette.nexusSidebarLine,
    mainBg: SoftPalette.nexusCanvas,
    cardBg: SoftPalette.nexusCard,
    cardBgAlt: SoftPalette.nexusCardAlt,
    cardBorder: SoftPalette.nexusBorder,
    textPrimary: SoftPalette.nexusText,
    textSecondary: SoftPalette.nexusTextSecondary,
    textTertiary: SoftPalette.nexusTextMuted,
    primary: SoftPalette.cobaltBlue,
    primaryHover: SoftPalette.blue600,
    primaryLight: SoftPalette.brightCobalt,
    secondary: SoftPalette.jadeEmerald,
  );

  static const AppVisualThemeTokens classicRoleLight = AppVisualThemeTokens(
    theme: AppVisualTheme.classicRoleLight,
    storageKey: 'classic_role_light',
    name: 'Classic Role',
    badge: 'LIGHT',
    description: 'Pearl light sidebar, elevated white cards & role accent colors',
    isDark: false,
    isDarkSidebar: false,
    usesRoleAccent: true,
    sidebarBg: SoftPalette.pureWhiteSoft,
    sidebarBgSecondary: SoftPalette.slate100,
    sidebarBorder: SoftPalette.slate200,
    sidebarText: SoftPalette.slate600,
    sidebarTextActive: SoftPalette.slate900,
    sidebarActiveBg: SoftPalette.indigo100,
    sidebarActiveLine: SoftPalette.cobaltBlue,
    mainBg: SoftPalette.slate100,
    cardBg: SoftPalette.pureWhiteSoft,
    cardBgAlt: SoftPalette.slate50,
    cardBorder: SoftPalette.slate200,
    textPrimary: SoftPalette.slate900,
    textSecondary: SoftPalette.slate600,
    textTertiary: SoftPalette.slate500,
    primary: SoftPalette.cobaltBlue,
    primaryHover: SoftPalette.blue600,
    primaryLight: SoftPalette.brightCobalt,
    secondary: SoftPalette.jadeEmerald,
  );

  static const AppVisualThemeTokens emeraldMeridianDark = AppVisualThemeTokens(
    theme: AppVisualTheme.emeraldMeridianDark,
    storageKey: 'emerald_meridian_dark',
    name: 'Emerald Night',
    badge: 'DARK',
    description: 'Deep forest night surfaces with luminous mint highlights',
    isDark: true,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.meridianNightSidebar,
    sidebarBgSecondary: SoftPalette.meridianNightSidebarAlt,
    sidebarBorder: SoftPalette.meridianNightBorder,
    sidebarText: SoftPalette.meridianNightSubtext,
    sidebarTextActive: SoftPalette.meridianNightText,
    sidebarActiveBg: SoftPalette.meridianSidebarActive,
    sidebarActiveLine: SoftPalette.brightMint,
    mainBg: SoftPalette.meridianNightBg,
    cardBg: SoftPalette.meridianNightCard,
    cardBgAlt: SoftPalette.meridianNightCardAlt,
    cardBorder: SoftPalette.meridianNightBorder,
    textPrimary: SoftPalette.meridianNightText,
    textSecondary: SoftPalette.meridianNightSubtext,
    textTertiary: SoftPalette.meridianTextMuted,
    primary: SoftPalette.brightMint,
    primaryHover: SoftPalette.jadeEmerald,
    primaryLight: SoftPalette.emerald200,
    secondary: SoftPalette.brightCyan,
  );

  static const AppVisualThemeTokens midnightPlumDark = AppVisualThemeTokens(
    theme: AppVisualTheme.midnightPlumDark,
    storageKey: 'midnight_plum_dark',
    name: 'Midnight Plum Dark',
    badge: 'DARK',
    description: 'Deep aubergine night surfaces with soft lavender accents',
    isDark: true,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.plumNightSidebar,
    sidebarBgSecondary: SoftPalette.plumNightSidebarAlt,
    sidebarBorder: SoftPalette.plumNightBorder,
    sidebarText: SoftPalette.plumNightSubtext,
    sidebarTextActive: SoftPalette.plumNightText,
    sidebarActiveBg: SoftPalette.plumSidebarActive,
    sidebarActiveLine: SoftPalette.softLavender,
    mainBg: SoftPalette.plumNightBg,
    cardBg: SoftPalette.plumNightCard,
    cardBgAlt: SoftPalette.plumNightCardAlt,
    cardBorder: SoftPalette.plumNightBorder,
    textPrimary: SoftPalette.plumNightText,
    textSecondary: SoftPalette.plumNightSubtext,
    textTertiary: SoftPalette.plumTextMuted,
    primary: SoftPalette.softLavender,
    primaryHover: SoftPalette.royalViolet,
    primaryLight: SoftPalette.violet200,
    secondary: SoftPalette.brightMint,
  );

  static const AppVisualThemeTokens nexusCoreDark = AppVisualThemeTokens(
    theme: AppVisualTheme.nexusCoreDark,
    storageKey: 'nexus_core_dark',
    name: 'Nexus Core Dark',
    badge: 'DARK',
    description: 'Deep obsidian slate surfaces with electric indigo highlights',
    isDark: true,
    isDarkSidebar: true,
    usesRoleAccent: false,
    sidebarBg: SoftPalette.nexusNightSidebar,
    sidebarBgSecondary: SoftPalette.nexusNightSidebarAlt,
    sidebarBorder: SoftPalette.nexusNightBorder,
    sidebarText: SoftPalette.nexusNightSubtext,
    sidebarTextActive: SoftPalette.nexusNightText,
    sidebarActiveBg: SoftPalette.nexusSidebarActive,
    sidebarActiveLine: SoftPalette.softIndigo,
    mainBg: SoftPalette.nexusNightBg,
    cardBg: SoftPalette.nexusNightCard,
    cardBgAlt: SoftPalette.nexusNightCardAlt,
    cardBorder: SoftPalette.nexusNightBorder,
    textPrimary: SoftPalette.nexusNightText,
    textSecondary: SoftPalette.nexusNightSubtext,
    textTertiary: SoftPalette.nexusTextMuted,
    primary: SoftPalette.brightCobalt,
    primaryHover: SoftPalette.luminousIndigo,
    primaryLight: SoftPalette.indigo200,
    secondary: SoftPalette.brightMint,
  );

  static const AppVisualThemeTokens classicRoleDark = AppVisualThemeTokens(
    theme: AppVisualTheme.classicRoleDark,
    storageKey: 'classic_role_dark',
    name: 'Classic Role Dark',
    badge: 'DARK',
    description: 'Charcoal slate dark surfaces with role-adaptive highlights',
    isDark: true,
    isDarkSidebar: true,
    usesRoleAccent: true,
    sidebarBg: SoftPalette.slate900,
    sidebarBgSecondary: SoftPalette.slate800,
    sidebarBorder: SoftPalette.slate700,
    sidebarText: SoftPalette.slate350,
    sidebarTextActive: SoftPalette.gray150,
    sidebarActiveBg: SoftPalette.slate750,
    sidebarActiveLine: SoftPalette.brightCyan,
    mainBg: SoftPalette.slate900,
    cardBg: SoftPalette.slate800,
    cardBgAlt: SoftPalette.slate750,
    cardBorder: SoftPalette.slate700,
    textPrimary: SoftPalette.gray150,
    textSecondary: SoftPalette.slate300,
    textTertiary: SoftPalette.slate400,
    primary: SoftPalette.brightCobalt,
    primaryHover: SoftPalette.cobaltBlue,
    primaryLight: SoftPalette.blue300,
    secondary: SoftPalette.brightMint,
  );

  static const List<AppVisualThemeTokens> all = [
    emeraldMeridianHybrid,
    midnightPlumHybrid,
    nexusCoreHybrid,
    classicRoleLight,
    emeraldMeridianDark,
    midnightPlumDark,
    nexusCoreDark,
    classicRoleDark,
  ];
}

extension AppVisualThemeX on AppVisualTheme {
  AppVisualThemeTokens get tokens => switch (this) {
        AppVisualTheme.emeraldMeridianHybrid =>
          AppVisualThemeTokens.emeraldMeridianHybrid,
        AppVisualTheme.midnightPlumHybrid =>
          AppVisualThemeTokens.midnightPlumHybrid,
        AppVisualTheme.nexusCoreHybrid => AppVisualThemeTokens.nexusCoreHybrid,
        AppVisualTheme.classicRoleLight =>
          AppVisualThemeTokens.classicRoleLight,
        AppVisualTheme.emeraldMeridianDark =>
          AppVisualThemeTokens.emeraldMeridianDark,
        AppVisualTheme.midnightPlumDark =>
          AppVisualThemeTokens.midnightPlumDark,
        AppVisualTheme.nexusCoreDark => AppVisualThemeTokens.nexusCoreDark,
        AppVisualTheme.classicRoleDark => AppVisualThemeTokens.classicRoleDark,
      };

  String get storageKey => tokens.storageKey;
  bool get isDark => tokens.isDark;

  AppVisualTheme pairedForDarkMode(bool wantDark) {
    if (wantDark == isDark) return this;
    return switch (this) {
      AppVisualTheme.emeraldMeridianHybrid =>
        AppVisualTheme.emeraldMeridianDark,
      AppVisualTheme.emeraldMeridianDark =>
        AppVisualTheme.emeraldMeridianHybrid,
      AppVisualTheme.midnightPlumHybrid => AppVisualTheme.midnightPlumDark,
      AppVisualTheme.midnightPlumDark => AppVisualTheme.midnightPlumHybrid,
      AppVisualTheme.nexusCoreHybrid => AppVisualTheme.nexusCoreDark,
      AppVisualTheme.nexusCoreDark => AppVisualTheme.nexusCoreHybrid,
      AppVisualTheme.classicRoleLight => AppVisualTheme.classicRoleDark,
      AppVisualTheme.classicRoleDark => AppVisualTheme.classicRoleLight,
    };
  }

  static AppVisualTheme fromStorageKey(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final t in AppVisualThemeTokens.all) {
      if (t.storageKey == normalized) return t.theme;
    }
    return AppVisualTheme.emeraldMeridianHybrid;
  }
}

