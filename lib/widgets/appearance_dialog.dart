// lib/widgets/appearance_dialog.dart
//
// Appearance for screens that open without the main app (Hybrid Desk,
// Dispensar, Receptionist, Doctor…): pick the theme (GMWF / Nexus / Twilight)
// and light / dark. It saves the same per-user setting as Settings ›
// Appearance, so the choice follows the user everywhere.

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GThemeChoice;
import 'package:hive_flutter/hive_flutter.dart';

import '../services/user_theme_service.dart';

abstract final class AppearanceDialog {
  static const Map<ui.GThemeChoice, String> _blurbs = {
    ui.GThemeChoice.gmwf: 'Emerald and gold on warm ivory. The default.',
    ui.GThemeChoice.nexus: 'Graphite and cobalt blue.',
    ui.GThemeChoice.twilight: 'Plum and violet on soft lilac.',
  };

  static const List<({double scale, String label})> _fontScales = [
    (scale: 0.85, label: 'Small'),
    (scale: 1.0, label: 'Default'),
    (scale: 1.15, label: 'Large'),
    (scale: 1.30, label: 'XL'),
  ];

  static Future<void> show(BuildContext context, {String? userKey}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final dark = UserThemeService.isDarkMode(userKey);
        final current = UserThemeService.getThemeChoice(userKey);
        final brightness = dark ? Brightness.dark : Brightness.light;
        final activeColors = ui.GTheme.colors(brightness, family: current.family);
        final strong = dark ? SoftPalette.gray50 : SoftPalette.slate800;
        final muted = dark ? SoftPalette.slate350 : SoftPalette.slate550;
        final rule = dark ? SoftPalette.slate700 : SoftPalette.slate150;
        final double currentScale = Hive.isBoxOpen('app_settings')
            ? ((Hive.box('app_settings').get('font_scale', defaultValue: 1.0) as num).toDouble())
            : 1.0;

        return Dialog(
          backgroundColor: dark ? SoftPalette.slate800 : SoftPalette.gray50,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text('Appearance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: strong)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: Icon(Icons.close_rounded, size: 20, color: muted),
                  ),
                ]),
                const SizedBox(height: 4),
                Text('THEME', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: muted)),
                const SizedBox(height: 6),
                for (final choice in ui.GThemeChoice.values)
                  Builder(builder: (_) {
                    final c = ui.GTheme.colors(brightness, family: choice.family);
                    final selected = choice == current;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          await UserThemeService.setThemeChoice(choice, explicitUserKey: userKey);
                          setState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: selected ? c.brand : rule, width: selected ? 1.6 : 1),
                          ),
                          child: Row(children: [
                            // Swatches: canvas, card, brand, accent.
                            for (final s in [c.background, c.surface, c.brand, c.accent])
                              Container(
                                width: 14,
                                height: 14,
                                margin: const EdgeInsetsDirectional.only(end: 4),
                                decoration: BoxDecoration(shape: BoxShape.circle, color: s, border: Border.all(color: rule)),
                              ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(choice.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: strong)),
                                Text(_blurbs[choice] ?? '',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: muted)),
                              ]),
                            ),
                            if (selected) Icon(Icons.check_circle_rounded, size: 18, color: c.brand),
                          ]),
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: rule)),
                  child: Row(children: [
                    Icon(dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded, size: 18, color: muted),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Dark mode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: strong))),
                    Switch(
                      value: dark,
                      onChanged: (v) async {
                        await UserThemeService.setDarkMode(v, explicitUserKey: userKey);
                        setState(() {});
                      },
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                Text('TEXT SIZE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: muted)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: dark ? SoftPalette.slate900 : SoftPalette.slate50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: rule),
                  ),
                  child: Row(
                    children: _fontScales.map((opt) {
                      final selected = (currentScale - opt.scale).abs() < 0.05;
                      return Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(7),
                          onTap: () async {
                            if (Hive.isBoxOpen('app_settings')) {
                              await Hive.box('app_settings').put('font_scale', opt.scale);
                              UserThemeService.notifyThemeChanged();
                              setState(() {});
                            }
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? activeColors.brand.withValues(alpha: dark ? 0.28 : 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(7),
                              border: selected
                                  ? Border.all(color: activeColors.brand, width: 1.2)
                                  : null,
                            ),
                            child: Text(
                              opt.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected ? (dark ? SoftPalette.gray50 : activeColors.brand) : muted,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }
}
