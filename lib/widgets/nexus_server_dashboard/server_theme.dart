import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Available themes for the Server Management Dashboard
enum ServerDashboardTheme {
  midnightPlumHybrid,
  midnightPlumDark,
  nexusCoreHybrid,
  nexusCoreDark,
}

/// Token collection defining every color used across the Server Control Center
class ServerThemeTokens {
  final String name;
  final String description;
  final bool isDark;

  // Sidebar
  final Color sidebarBg;
  final Color sidebarSecondary;
  final Color sidebarBorder;
  final Color sidebarText;
  final Color sidebarTextActive;
  final Color sidebarActiveLine;
  final Color sidebarActiveBg;

  // Main Canvas & Cards
  final Color mainBg;
  final Color cardBg;
  final Color cardBorder;
  final Color mutedBg;

  // Accents
  final Color primary;
  final Color primaryHover;
  final Color primaryMuted;
  final Color secondaryAccent;

  // Typography
  final Color textMain;
  final Color textSecondary;
  final Color textMuted;
  /// Text / icons drawn ON a primary-filled surface (button, selected chip).
  final Color onPrimary;
  /// Text / icons drawn ON a warning-filled surface.
  final Color onWarning;

  // Semantic
  final Color success;
  final Color successMuted;
  final Color successBorder;

  final Color warning;
  final Color warningMuted;
  final Color warningBorder;

  final Color error;
  final Color errorMuted;
  final Color errorBorder;

  // Dedicated Resource Accents
  final Color cpuAccent;
  final Color ramAccent;
  final Color diskAccent;
  final Color networkAccent;

  const ServerThemeTokens({
    required this.name,
    required this.description,
    required this.isDark,
    required this.sidebarBg,
    required this.sidebarSecondary,
    required this.sidebarBorder,
    required this.sidebarText,
    required this.sidebarTextActive,
    required this.sidebarActiveLine,
    required this.sidebarActiveBg,
    required this.mainBg,
    required this.cardBg,
    required this.cardBorder,
    required this.mutedBg,
    required this.primary,
    required this.primaryHover,
    required this.primaryMuted,
    required this.secondaryAccent,
    required this.textMain,
    required this.textSecondary,
    required this.textMuted,
    required this.onPrimary,
    required this.onWarning,
    required this.success,
    required this.successMuted,
    required this.successBorder,
    required this.warning,
    required this.warningMuted,
    required this.warningBorder,
    required this.error,
    required this.errorMuted,
    required this.errorBorder,
    required this.cpuAccent,
    required this.ramAccent,
    required this.diskAccent,
    required this.networkAccent,
  });

  // ── 1. Midnight Plum — Hybrid (Default / New Specification) ───────────────
  static const ServerThemeTokens midnightPlumHybrid = ServerThemeTokens(
    name: 'Midnight Plum (Hybrid)',
    description: 'Dark plum sidebar, cloud lilac workspace, pure white cards, soft lavender accents',
    isDark: false,
    sidebarBg: Color(0xFF211B2B),          // Midnight Plum
    sidebarSecondary: Color(0xFF34283F),   // Aubergine
    sidebarBorder: Color(0xFF2D233A),
    sidebarText: Color(0xFF9E92AC),        // Muted Lavender-Slate
    sidebarTextActive: Color(0xFFFFFFFF),
    sidebarActiveLine: Color(0xFFB7A2F2),  // Soft Lavender
    sidebarActiveBg: Color(0xFF493753),    // Muted Plum
    mainBg: Color(0xFFF6F4F8),             // Cloud White
    cardBg: Color(0xFFFFFFFF),             // Pure White
    cardBorder: Color(0xFFE8E2EC),         // Lavender Grey
    mutedBg: Color(0xFFEFEBF5),
    primary: Color(0xFF7650CC),            // Accessible Violet / Lavender
    primaryHover: Color(0xFF6542B8),
    primaryMuted: Color(0xFFF0EAFC),
    secondaryAccent: Color(0xFFE9E3F1),    // Pale Lilac
    textMain: Color(0xFF292231),           // Deep Charcoal
    textSecondary: Color(0xFF655E6E),      // Muted Slate
    textMuted: Color(0xFF8A8296),
    onWarning: Color(0xFFFFFFFF),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF299D72),            // Restrained Emerald
    successMuted: Color(0xFFE8F6F0),
    successBorder: Color(0xFFB8E6D3),
    warning: Color(0xFFB06F12),            // Warm Amber
    warningMuted: Color(0xFFFDF6EC),
    warningBorder: Color(0xFFF6D9AF),
    error: Color(0xFFD65B69),              // Rose Red
    errorMuted: Color(0xFFFDF0F1),
    errorBorder: Color(0xFFF3BEC4),
    cpuAccent: Color(0xFF8E6BD9),
    ramAccent: Color(0xFF299D72),
    diskAccent: Color(0xFFD65B69),
    networkAccent: Color(0xFFD69A3A),
  );

  // ── 2. Midnight Plum — Dark Mode ──────────────────────────────────────────
  static const ServerThemeTokens midnightPlumDark = ServerThemeTokens(
    name: 'Midnight Plum (Dark)',
    description: 'Deep aubergine night surfaces with luminous lavender and violet highlights',
    isDark: true,
    sidebarBg: Color(0xFF16111D),
    sidebarSecondary: Color(0xFF221A2C),
    sidebarBorder: Color(0xFF2A2036),
    sidebarText: Color(0xFF9D92AB),
    sidebarTextActive: Color(0xFFF4EFF9),
    sidebarActiveLine: Color(0xFFB7A2F2),
    sidebarActiveBg: Color(0xFF382A48),
    mainBg: Color(0xFF1B1524),             // Deep Night Plum
    cardBg: Color(0xFF241C2E),             // Dark Plum Card
    cardBorder: Color(0xFF382B47),
    mutedBg: Color(0xFF2E233C),
    primary: Color(0xFFB7A2F2),            // Bright Lavender Accent
    primaryHover: Color(0xFFA48BE9),
    primaryMuted: Color(0xFF362847),
    secondaryAccent: Color(0xFF48365E),
    textMain: Color(0xFFF6F3FA),           // Crisp Lilac-White
    textSecondary: Color(0xFFADA5BA),
    textMuted: Color(0xFF827891),
    onPrimary: Color(0xFF1B1524),
    onWarning: Color(0xFF1B1524),
    success: Color(0xFF299D72),
    successMuted: Color(0xFF1A382C),
    successBorder: Color(0xFF245F45),
    warning: Color(0xFFD69A3A),
    warningMuted: Color(0xFF382914),
    warningBorder: Color(0xFF6E4F1F),
    error: Color(0xFFD65B69),
    errorMuted: Color(0xFF3B1D22),
    errorBorder: Color(0xFF6E2833),
    cpuAccent: Color(0xFFB7A2F2),
    ramAccent: Color(0xFF34D399),
    diskAccent: Color(0xFFF472B6),
    networkAccent: Color(0xFFFBBF24),
  );

  // ── 3. Nexus Core — Hybrid (Graphite + Slate Blue) ────────────────────────
  static const ServerThemeTokens nexusCoreHybrid = ServerThemeTokens(
    name: 'Nexus Core (Hybrid)',
    description: 'Dark graphite sidebar, light grey workspace, white cards, electric-blue accents',
    isDark: false,
    sidebarBg: Color(0xFF111827),
    sidebarSecondary: Color(0xFF1B2638),
    sidebarBorder: Color(0xFF1F2937),
    sidebarText: Color(0xFF8993A5),
    sidebarTextActive: Color(0xFFFFFFFF),
    sidebarActiveLine: Color(0xFF5577EF),
    sidebarActiveBg: Color(0xFF1F2B42),
    mainBg: Color(0xFFF4F6FA),
    cardBg: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE9EDF3),
    mutedBg: Color(0xFFEDF2FF),
    primary: Color(0xFF3D60DD),
    primaryHover: Color(0xFF3352C4),
    primaryMuted: Color(0xFFEDF2FF),
    secondaryAccent: Color(0xFFDCE6FF),
    textMain: Color(0xFF172235),
    textSecondary: Color(0xFF5A6476),
    textMuted: Color(0xFF7D8798),
    onWarning: Color(0xFFFFFFFF),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF0B8A63),
    successMuted: Color(0xFFE6F7F2),
    successBorder: Color(0xFFB4EBD8),
    warning: Color(0xFFAC6D12),
    warningMuted: Color(0xFFFDF6EC),
    warningBorder: Color(0xFFF6D9AF),
    error: Color(0xFFD15B5B),
    errorMuted: Color(0xFFFDF0F0),
    errorBorder: Color(0xFFF3BFBF),
    cpuAccent: Color(0xFF5577EF),
    ramAccent: Color(0xFF23B58B),
    diskAccent: Color(0xFFA17BE7),
    networkAccent: Color(0xFFE8A34D),
  );

  // ── 4. Nexus Core — Dark Mode ─────────────────────────────────────────────
  static const ServerThemeTokens nexusCoreDark = ServerThemeTokens(
    name: 'Nexus Core (Dark)',
    description: 'Deep obsidian and graphite surfaces with vivid indigo and cyan highlights',
    isDark: true,
    sidebarBg: Color(0xFF0B0F19),
    sidebarSecondary: Color(0xFF111827),
    sidebarBorder: Color(0xFF1F2937),
    sidebarText: Color(0xFF9CA3AF),
    sidebarTextActive: Color(0xFFFFFFFF),
    sidebarActiveLine: Color(0xFF6366F1),
    sidebarActiveBg: Color(0xFF1E293B),
    mainBg: Color(0xFF0F172A),
    cardBg: Color(0xFF1E293B),
    cardBorder: Color(0xFF334155),
    mutedBg: Color(0xFF1E293B),
    primary: Color(0xFF6366F1),
    primaryHover: Color(0xFF4F46E5),
    primaryMuted: Color(0xFF1F2742),
    secondaryAccent: Color(0xFF312E81),
    textMain: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF64748B),
    onWarning: Color(0xFF0F172A),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF10B981),
    successMuted: Color(0xFF064E3B),
    successBorder: Color(0xFF047857),
    warning: Color(0xFFF59E0B),
    warningMuted: Color(0xFF451A03),
    warningBorder: Color(0xFFB45309),
    error: Color(0xFFEF4444),
    errorMuted: Color(0xFF450A0A),
    errorBorder: Color(0xFFB91C1C),
    cpuAccent: Color(0xFF6366F1),
    ramAccent: Color(0xFF10B981),
    diskAccent: Color(0xFFA855F7),
    networkAccent: Color(0xFFF59E0B),
  );
}

/// Central controller managing the current Server Management Dashboard theme
class ServerThemeController extends ChangeNotifier {
  static final ServerThemeController instance = ServerThemeController._();

  ServerDashboardTheme _currentTheme = ServerDashboardTheme.midnightPlumHybrid;

  ServerThemeController._() {
    _loadFromStorage();
  }

  ServerDashboardTheme get currentTheme => _currentTheme;

  ServerThemeTokens get currentTokens {
    switch (_currentTheme) {
      case ServerDashboardTheme.midnightPlumHybrid:
        return ServerThemeTokens.midnightPlumHybrid;
      case ServerDashboardTheme.midnightPlumDark:
        return ServerThemeTokens.midnightPlumDark;
      case ServerDashboardTheme.nexusCoreHybrid:
        return ServerThemeTokens.nexusCoreHybrid;
      case ServerDashboardTheme.nexusCoreDark:
        return ServerThemeTokens.nexusCoreDark;
    }
  }

  void setTheme(ServerDashboardTheme theme) {
    if (_currentTheme == theme) return;
    _currentTheme = theme;
    _saveToStorage();
    notifyListeners();
  }

  void _loadFromStorage() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final raw = box.get('server_dashboard_theme')?.toString();
        if (raw != null) {
          switch (raw) {
            case 'midnight_plum_dark':
              _currentTheme = ServerDashboardTheme.midnightPlumDark;
              break;
            case 'nexus_core_hybrid':
              _currentTheme = ServerDashboardTheme.nexusCoreHybrid;
              break;
            case 'nexus_core_dark':
              _currentTheme = ServerDashboardTheme.nexusCoreDark;
              break;
            case 'midnight_plum_hybrid':
            default:
              _currentTheme = ServerDashboardTheme.midnightPlumHybrid;
              break;
          }
        }
      }
    } catch (_) {}
  }

  void _saveToStorage() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        String key = 'midnight_plum_hybrid';
        switch (_currentTheme) {
          case ServerDashboardTheme.midnightPlumDark:
            key = 'midnight_plum_dark';
            break;
          case ServerDashboardTheme.nexusCoreHybrid:
            key = 'nexus_core_hybrid';
            break;
          case ServerDashboardTheme.nexusCoreDark:
            key = 'nexus_core_dark';
            break;
          case ServerDashboardTheme.midnightPlumHybrid:
          default:
            key = 'midnight_plum_hybrid';
            break;
        }
        box.put('server_dashboard_theme', key);
      }
    } catch (_) {}
  }
}

