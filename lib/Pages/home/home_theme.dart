// lib/pages/home/home_theme.dart
//
// Puts the gmwf_ui theme (GMWF / Nexus / Twilight, light or dark) around the
// redesigned home, read from the user's saved settings. Every widget under it
// reads colours through gmwf_ui's `context.comfort`.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../services/user_theme_service.dart';

/// The user's theme choice in gmwf_ui terms.
GThemeChoice homeThemeChoice() =>
    UserThemeService.getThemeChoice();

/// Rebuilds [builder] with gmwf_ui's ThemeData whenever the user's theme,
/// dark mode or custom accent changes.
class HomeThemeScope extends StatelessWidget {
  const HomeThemeScope({super.key, required this.userData, required this.child});

  final Map<String, dynamic> userData;
  final Widget child;

  Color? _accent(Box? box) {
    Color? parse(String? raw) {
      final hex = (raw ?? '').replaceAll('#', '').trim();
      if (hex.length != 6) return null;
      final v = int.tryParse(hex, radix: 16);
      return v == null ? null : Color(0xFF000000 | v);
    }

    return parse(box?.get('custom_accent_color') as String?) ?? parse(userData['preferredColor']?.toString());
  }

  Widget _themed(BuildContext context, Box? box) {
    final theme = GTheme.forChoice(
      homeThemeChoice(),
      darkModeOn: UserThemeService.isDarkMode(),
      brandOverride: _accent(box),
    );
    return Theme(data: theme, child: child);
  }

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) return _themed(context, null);
    return ValueListenableBuilder<bool>(
      valueListenable: UserThemeService.currentThemeNotifier,
      builder: (context, _, _) => ValueListenableBuilder<Box>(
        valueListenable: Hive.box('app_settings').listenable(keys: [
          'custom_accent_color',
          'is_dark_mode',
          'visual_theme',
          UserThemeService.getStorageKey(),
          UserThemeService.getVisualThemeKey(),
          UserThemeService.getThemeChoiceKey(),
          'theme_choice',
        ]),
        builder: (context, box, _) => _themed(context, box),
      ),
    );
  }
}
