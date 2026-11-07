import 'package:flutter/material.dart';
import 'server_theme.dart';

/// Design tokens for the Server Control Center.
/// Dynamically resolves against [ServerThemeController.instance.currentTokens]
/// allowing the entire dashboard to instantly toggle between:
///   1. Midnight Plum (Hybrid) [Default]
///   2. Midnight Plum (Dark)
///   3. Nexus Core (Hybrid)
///   4. Nexus Core (Dark)
class NexusColors {
  static ServerThemeTokens get current => ServerThemeController.instance.currentTokens;

  // Sidebar
  static Color get sidebarBg => current.sidebarBg;
  static Color get sidebarSecondary => current.sidebarSecondary;
  static Color get sidebarBorder => current.sidebarBorder;
  static Color get sidebarText => current.sidebarText;
  static Color get sidebarTextActive => current.sidebarTextActive;
  static Color get sidebarActiveLine => current.sidebarActiveLine;
  static Color get sidebarActiveBg => current.sidebarActiveBg;

  // Main Canvas & Cards
  static Color get mainBg => current.mainBg;
  static Color get cardBg => current.cardBg;
  static Color get cardBorder => current.cardBorder;
  static Color get mutedBg => current.mutedBg;

  // Accents
  static Color get primary => current.primary;
  static Color get primaryHover => current.primaryHover;
  static Color get primaryMuted => current.primaryMuted;
  static Color get secondaryAccent => current.secondaryAccent;

  // Typography
  static Color get textMain => current.textMain;
  static Color get textSecondary => current.textSecondary;
  static Color get textMuted => current.textMuted;

  // Semantic
  static Color get success => current.success;
  static Color get successMuted => current.successMuted;
  static Color get successBorder => current.successBorder;

  static Color get warning => current.warning;
  static Color get warningMuted => current.warningMuted;
  static Color get warningBorder => current.warningBorder;

  static Color get error => current.error;
  static Color get errorMuted => current.errorMuted;
  static Color get errorBorder => current.errorBorder;

  // Dedicated Resource Accents
  static Color get cpuAccent => current.cpuAccent;
  static Color get ramAccent => current.ramAccent;
  static Color get diskAccent => current.diskAccent;
  static Color get networkAccent => current.networkAccent;

  // Helper boolean
  static bool get isDark => current.isDark;
}
