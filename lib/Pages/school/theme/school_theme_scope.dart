// lib/pages/school/theme/school_theme_scope.dart
//
// Applies the user's chosen gmwf_ui theme (GMWF / Nexus / Twilight, light or
// dark) around every School screen (School ERP Phase 6, 2026-11-17).
//
// School no longer pins a fixed Scholar Indigo brandOverride: it follows the
// app theme the user picks in Settings, defaulting to Nexus for school roles
// (Principal, School Admin, Teacher, Librarian, School Accountant).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/user_theme_service.dart';

class SchoolThemeScope extends StatelessWidget {
  const SchoolThemeScope({super.key, this.role, required this.child});

  /// Optional role passed from [SchoolDashboard] so school roles default to
  /// Nexus even when no explicit theme has been saved yet.
  final String? role;
  final Widget child;

  Widget _themed() {
    final choice = UserThemeService.getThemeChoice(null, role);
    final theme = GTheme.forChoice(
      choice,
      darkModeOn: UserThemeService.isDarkMode(),
    );
    return Theme(data: theme, child: child);
  }

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) return _themed();
    return ValueListenableBuilder<bool>(
      valueListenable: UserThemeService.currentThemeNotifier,
      builder: (context, _, _) => ValueListenableBuilder<Box>(
        valueListenable: Hive.box('app_settings').listenable(keys: [
          'is_dark_mode',
          'visual_theme',
          UserThemeService.getStorageKey(),
          UserThemeService.getVisualThemeKey(),
          UserThemeService.getThemeChoiceKey(),
          'theme_choice',
        ]),
        builder: (context, _, _) => _themed(),
      ),
    );
  }
}
