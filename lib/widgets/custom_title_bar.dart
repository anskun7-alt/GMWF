import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/services/user_theme_service.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GComfortColors;
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'sync_status_indicator.dart';

class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({super.key});

  /// The bar takes the sidebar colour of the user's theme (GMWF / Nexus /
  /// Twilight) and dark mode, from the shared design system.
  static ui.GComfortColors _colors() {
    final dark = UserThemeService.isDarkMode();
    Color? custom;
    if (Hive.isBoxOpen('app_settings')) {
      final hex = (Hive.box('app_settings').get('custom_accent_color') as String?)?.replaceAll('#', '');
      if (hex != null && hex.isNotEmpty) custom = Color(int.tryParse('FF$hex', radix: 16) ?? 0xFF0B7A5B);
    }
    return ui.GTheme.colors(dark ? Brightness.dark : Brightness.light,
        family: UserThemeService.getThemeChoice().family, brandOverride: custom);
  }

  @override
  Widget build(BuildContext context) {
    Widget bar() {
      final c = _colors();
      return _buildBar(
        barColor: c.sidebarBg,
        borderColor: c.sidebarBorder,
        isDarkBar: c.sidebarBg.computeLuminance() < 0.45,
        textPrimary: c.textPrimary,
      );
    }

    if (!Hive.isBoxOpen('app_settings')) return bar();

    return ValueListenableBuilder<bool>(
      valueListenable: UserThemeService.currentThemeNotifier,
      builder: (context, _, _) => ValueListenableBuilder(
        valueListenable: Hive.box('app_settings').listenable(keys: [
          'custom_accent_color',
          'is_dark_mode',
          'visual_theme',
          'theme_choice',
          UserThemeService.getStorageKey(),
          UserThemeService.getVisualThemeKey(),
          UserThemeService.getThemeChoiceKey(),
        ]),
        builder: (context, Box box, child) => bar(),
      ),
    );
  }
  Widget _buildBar({
    required Color barColor,
    required Color borderColor,
    required bool isDarkBar,
    Color textPrimary = SoftPalette.slate900,
  }) {
    final fgColor = isDarkBar ? SoftPalette.gray50 : textPrimary;
    final mouseOverColor = Color.alphaBlend(
      (isDarkBar ? SoftPalette.gray50 : SoftPalette.slate900).withValues(alpha: 0.12),
      barColor,
    );
    final mouseDownColor = Color.alphaBlend(
      (isDarkBar ? SoftPalette.gray50 : SoftPalette.slate900).withValues(alpha: 0.22),
      barColor,
    );

    return WindowTitleBarBox(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: barColor,
          border: Border(
            bottom: BorderSide(color: borderColor, width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: MoveWindow(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/logo/gmwf-1.webp',
                        height: 20,
                        cacheHeight: 60,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.business, color: fgColor, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        "GMWF",
                        style: TextStyle(
                          color: fgColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SyncStatusIndicator(isDark: isDarkBar),
            ),
            WindowButtons(
              iconColor: fgColor,
              mouseOver: mouseOverColor,
              mouseDown: mouseDownColor,
            ),
          ],
        ),
      ),
    );
  }
}

class WindowButtons extends StatelessWidget {
  final Color iconColor;
  final Color mouseOver;
  final Color mouseDown;

  const WindowButtons({
    super.key,
    this.iconColor = SoftPalette.gray50,
    required this.mouseOver,
    required this.mouseDown,
  });

  @override
  Widget build(BuildContext context) {
    final buttonColors = WindowButtonColors(
      iconNormal: iconColor,
      mouseOver: mouseOver,
      mouseDown: mouseDown,
      iconMouseOver: iconColor,
      iconMouseDown: iconColor,
    );

    final closeButtonColors = WindowButtonColors(
      mouseOver: SoftPalette.red500,
      mouseDown: SoftPalette.red550,
      iconNormal: iconColor,
      iconMouseOver: SoftPalette.gray50,
    );

    return Row(
      children: [
        MinimizeWindowButton(colors: buttonColors),
        MaximizeWindowButton(colors: buttonColors),
        CloseWindowButton(colors: closeButtonColors),
      ],
    );
  }
}
