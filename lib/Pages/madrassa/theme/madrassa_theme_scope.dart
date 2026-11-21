// lib/pages/madrassa/theme/madrassa_theme_scope.dart
//
// Applies the user's chosen gmwf_ui theme (GMWF / Nexus / Twilight, light or
// dark) around the Madrassa hub and its screens (2026-11-21). Adapted from the
// School theme scope (copied, not imported: madrassa never imports school code).
//
// Madrassa roles get the GMWF theme until the user picks another one in
// Settings; changing theme or dark mode there updates the screens at once.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/user_theme_service.dart';
import '../../../design/tokens/comfort_colors.dart' as app show GComfortColors;

class MadrassaThemeScope extends StatelessWidget {
  const MadrassaThemeScope({super.key, this.userKey, this.role, required this.child});

  /// The signed-in user whose theme settings apply (null = the active user).
  final String? userKey;
  final String? role;
  final Widget child;

  Widget _themed() {
    final choice = UserThemeService.getThemeChoice(userKey, role);
    final theme = GTheme.forChoice(choice, darkModeOn: UserThemeService.isDarkMode(userKey));
    // The app keeps its own copy of the colour tokens (same fields). Feed it from
    // the chosen theme too, so every madrassa screen and card follows GMWF /
    // Nexus / Twilight, not only light/dark.
    final ds = theme.extension<GComfortColors>();
    final data = ds == null
        ? theme
        : theme.copyWith(extensions: [
            ...theme.extensions.values,
            app.GComfortColors(
              background: ds.background,
              surface: ds.surface,
              surfaceRaised: ds.surfaceRaised,
              surfaceSunken: ds.surfaceSunken,
              border: ds.border,
              borderStrong: ds.borderStrong,
              textPrimary: ds.textPrimary,
              textSecondary: ds.textSecondary,
              textMuted: ds.textMuted,
              brand: ds.brand,
              brandStrong: ds.brandStrong,
              brandSoft: ds.brandSoft,
              onBrand: ds.onBrand,
              success: ds.success,
              successBg: ds.successBg,
              warning: ds.warning,
              warningBg: ds.warningBg,
              danger: ds.danger,
              dangerBg: ds.dangerBg,
              info: ds.info,
              infoBg: ds.infoBg,
            ),
          ]);
    return Theme(data: data, child: child);
  }

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) return _themed();
    return ValueListenableBuilder<Box>(
      valueListenable: UserThemeService.listenable(userKey),
      builder: (context, _, _) => _themed(),
    );
  }
}
