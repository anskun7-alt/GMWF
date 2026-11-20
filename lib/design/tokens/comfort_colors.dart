// lib/design/tokens/comfort_colors.dart
//
// ── GComfortColors — semantic, theme-aware colours ───────────────────────────
// Ask for what a colour is FOR, not which shade:
//
//   final c = context.comfort;
//   Container(color: c.surface, child: Text('Hi', style: TextStyle(color: c.textPrimary)));
//
// Light and dark sets are both built from the eye-comfort SoftPalette
// (soft_palette.dart): no pure white/black, no neon, muted accents. Registered
// on ThemeData.extensions in lib/main.dart, so it follows the user's theme.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:gmwf/theme/app_visual_theme.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GThemeChoice, GComfortColors;

import 'colors.dart';
import 'soft_palette.dart';

@immutable
class GComfortColors extends ThemeExtension<GComfortColors> {
  // Canvas & surfaces
  final Color background; // screen / scaffold
  final Color surface; // cards, sheets, dialogs
  final Color surfaceRaised; // menus, popovers, hovered cards
  final Color surfaceSunken; // inputs, wells, table stripes
  final Color border;
  final Color borderStrong;
  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  // Brand
  final Color brand;
  final Color brandStrong;
  final Color brandSoft; // tinted brand background
  final Color onBrand; // text/icons on brand
  // Status (foreground + tinted background)
  final Color success, successBg;
  final Color warning, warningBg;
  final Color danger, dangerBg;
  final Color info, infoBg;

  const GComfortColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.brand,
    required this.brandStrong,
    required this.brandSoft,
    required this.onBrand,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.danger,
    required this.dangerBg,
    required this.info,
    required this.infoBg,
  });

  // v2: cool slate canvas, near-white cards separated by a 1px hairline.
  static const light = GComfortColors(
    background: SoftPalette.slate100,
    surface: SoftPalette.slate50,
    surfaceRaised: SoftPalette.slate50,
    surfaceSunken: SoftPalette.slate100,
    border: SoftPalette.slate150,
    borderStrong: SoftPalette.slate200,
    textPrimary: SoftPalette.slate900,
    textSecondary: SoftPalette.slate600,
    textMuted: SoftPalette.slate500,
    brand: SoftPalette.teal600,
    brandStrong: SoftPalette.teal700,
    brandSoft: SoftPalette.teal100t,
    onBrand: SoftPalette.slate50,
    success: SoftPalette.emerald550,
    successBg: SoftPalette.emerald100t,
    warning: SoftPalette.amber750,
    warningBg: SoftPalette.amber100,
    danger: SoftPalette.red550,
    dangerBg: SoftPalette.red100t,
    info: SoftPalette.blue550,
    infoBg: SoftPalette.slate50,
  );

  // v2: cards sit one step above the canvas instead of matching it.
  static const dark = GComfortColors(
    background: SoftPalette.slate900,
    surface: SoftPalette.slate800,
    surfaceRaised: SoftPalette.slate750,
    surfaceSunken: SoftPalette.slate900,
    border: SoftPalette.slate750,
    borderStrong: SoftPalette.slate700,
    textPrimary: SoftPalette.gray150,
    textSecondary: SoftPalette.slate300,
    textMuted: SoftPalette.slate400,
    brand: SoftPalette.teal350,
    brandStrong: SoftPalette.teal300,
    brandSoft: SoftPalette.teal800,
    onBrand: SoftPalette.gray900,
    success: SoftPalette.emerald350,
    successBg: SoftPalette.emerald800,
    warning: SoftPalette.amber300,
    warningBg: SoftPalette.amber800,
    danger: SoftPalette.red350,
    dangerBg: SoftPalette.red800,
    info: SoftPalette.blue350,
    infoBg: SoftPalette.blue800,
  );

  /// Builds a semantic comfort palette directly from an [AppVisualTheme]
  /// preset (and optional custom brand [overrideAccent]).
  factory GComfortColors.fromVisualTheme(
    AppVisualTheme visualTheme, {
    Color? overrideAccent,
  }) {
    final vt = visualTheme.tokens;
    final brandColor = overrideAccent ?? vt.primary;
    final primary = vt.isDark ? GColor.accentOnDark(brandColor) : brandColor;
    final success = vt.isDark ? SoftPalette.brightMint : SoftPalette.jadeEmerald;
    final warning = vt.isDark ? SoftPalette.brightGold : SoftPalette.warmMarigold;
    final danger = vt.isDark ? SoftPalette.brightCoral : SoftPalette.roseCoral;
    final info = vt.isDark ? SoftPalette.brightCobalt : SoftPalette.cobaltBlue;

    return GComfortColors(
      background: vt.mainBg,
      surface: vt.cardBg,
      surfaceRaised: vt.cardBg,
      surfaceSunken: vt.cardBgAlt,
      border: vt.cardBorder,
      borderStrong: Color.alphaBlend(
        vt.textTertiary.withValues(alpha: vt.isDark ? 0.25 : 0.20),
        vt.cardBorder,
      ),
      textPrimary: vt.textPrimary,
      textSecondary: vt.textSecondary,
      textMuted: vt.textTertiary,
      brand: primary,
      brandStrong: overrideAccent ?? vt.primaryHover,
      brandSoft: Color.alphaBlend(
        primary.withValues(alpha: vt.isDark ? 0.20 : 0.11),
        vt.cardBg,
      ),
      onBrand: GColor.onAccent(primary),
      success: success,
      successBg: Color.alphaBlend(
        success.withValues(alpha: vt.isDark ? 0.18 : 0.12),
        vt.cardBg,
      ),
      warning: warning,
      warningBg: Color.alphaBlend(
        warning.withValues(alpha: vt.isDark ? 0.18 : 0.12),
        vt.cardBg,
      ),
      danger: danger,
      dangerBg: Color.alphaBlend(
        danger.withValues(alpha: vt.isDark ? 0.18 : 0.12),
        vt.cardBg,
      ),
      info: info,
      infoBg: Color.alphaBlend(
        info.withValues(alpha: vt.isDark ? 0.18 : 0.11),
        vt.cardBg,
      ),
    );
  }

  /// The set for the user's theme [choice] (GMWF / Nexus / Twilight), taken
  /// from the shared design system (gmwf_ui) so the app, School and the
  /// websites use the same colours.
  factory GComfortColors.fromChoice(ui.GThemeChoice choice, Brightness brightness, {Color? overrideAccent}) =>
      GComfortColors.fromDesignSystem(ui.GTheme.colors(brightness, family: choice.family, brandOverride: overrideAccent));

  factory GComfortColors.fromDesignSystem(ui.GComfortColors c) => GComfortColors(
        background: c.background,
        surface: c.surface,
        surfaceRaised: c.surfaceRaised,
        surfaceSunken: c.surfaceSunken,
        border: c.border,
        borderStrong: c.borderStrong,
        textPrimary: c.textPrimary,
        textSecondary: c.textSecondary,
        textMuted: c.textMuted,
        brand: c.brand,
        brandStrong: c.brandStrong,
        brandSoft: c.brandSoft,
        onBrand: c.onBrand,
        success: c.success,
        successBg: c.successBg,
        warning: c.warning,
        warningBg: c.warningBg,
        danger: c.danger,
        dangerBg: c.dangerBg,
        info: c.info,
        infoBg: c.infoBg,
      );

  /// The set for [context]'s theme (falls back to brightness if not registered).
  static GComfortColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<GComfortColors>() ?? (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  GComfortColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? brand,
    Color? brandStrong,
    Color? brandSoft,
    Color? onBrand,
    Color? success,
    Color? successBg,
    Color? warning,
    Color? warningBg,
    Color? danger,
    Color? dangerBg,
    Color? info,
    Color? infoBg,
  }) =>
      GComfortColors(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        surfaceSunken: surfaceSunken ?? this.surfaceSunken,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textMuted: textMuted ?? this.textMuted,
        brand: brand ?? this.brand,
        brandStrong: brandStrong ?? this.brandStrong,
        brandSoft: brandSoft ?? this.brandSoft,
        onBrand: onBrand ?? this.onBrand,
        success: success ?? this.success,
        successBg: successBg ?? this.successBg,
        warning: warning ?? this.warning,
        warningBg: warningBg ?? this.warningBg,
        danger: danger ?? this.danger,
        dangerBg: dangerBg ?? this.dangerBg,
        info: info ?? this.info,
        infoBg: infoBg ?? this.infoBg,
      );

  @override
  GComfortColors lerp(ThemeExtension<GComfortColors>? other, double t) {
    if (other is! GComfortColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return GComfortColors(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      surfaceSunken: l(surfaceSunken, other.surfaceSunken),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      brand: l(brand, other.brand),
      brandStrong: l(brandStrong, other.brandStrong),
      brandSoft: l(brandSoft, other.brandSoft),
      onBrand: l(onBrand, other.onBrand),
      success: l(success, other.success),
      successBg: l(successBg, other.successBg),
      warning: l(warning, other.warning),
      warningBg: l(warningBg, other.warningBg),
      danger: l(danger, other.danger),
      dangerBg: l(dangerBg, other.dangerBg),
      info: l(info, other.info),
      infoBg: l(infoBg, other.infoBg),
    );
  }
}

extension GComfortColorsContext on BuildContext {
  /// Theme-aware eye-comfort colours: `context.comfort.textPrimary`.
  GComfortColors get comfort => GComfortColors.of(this);

  /// Any palette colour, made theme-aware: its dark partner in dark mode, then
  /// moved onto the user's theme (GMWF / Nexus / Twilight): greys take the
  /// theme's neutral tint and the old teal/emerald brand takes the theme's
  /// brand hue. Status colours (red, amber, blue, green) are left alone.
  /// `context.adapt(SoftPalette.gray100)`.
  Color adapt(Color light) {
    final theme = Theme.of(this);
    final isDark = theme.brightness == Brightness.dark;
    final base = SoftPalette.adaptive(light, isDark);
    final choice = theme.extension<GmwfThemeChoice>();
    return choice == null ? base : choice.remap(base);
  }
}

/// The user's theme, carried on ThemeData so palette colours can follow it.
@immutable
class GmwfThemeChoice extends ThemeExtension<GmwfThemeChoice> {
  GmwfThemeChoice(this.choice, this.colors)
      : _neutral = HSLColor.fromColor(colors.surfaceSunken),
        _brand = HSLColor.fromColor(colors.brand);

  final ui.GThemeChoice choice;

  /// The design-system colours for this theme and mode.
  final ui.GComfortColors colors;

  final HSLColor _neutral;
  final HSLColor _brand;
  final Map<int, Color> _cache = {};

  /// Hue range of the app's old brand colours (teal / emerald / jade).
  static const double _brandHueFrom = 150, _brandHueTo = 200;

  Color remap(Color c) {
    final key = c.toARGB32();
    final hit = _cache[key];
    if (hit != null) return hit;
    final hsl = HSLColor.fromColor(c.withValues(alpha: 1));
    Color out;
    if (hsl.saturation < 0.18 && hsl.lightness > 0.03 && hsl.lightness < 0.985) {
      // Greys / slates / stones → the theme's neutral tint, same lightness.
      out = hsl.withHue(_neutral.hue).withSaturation((_neutral.saturation).clamp(0.0, 0.22)).toColor();
    } else if (hsl.saturation >= 0.18 && hsl.hue >= _brandHueFrom && hsl.hue <= _brandHueTo) {
      // Old brand teal / emerald → the theme's brand hue, same lightness and strength.
      out = hsl.withHue(_brand.hue).withSaturation((hsl.saturation * 0.6 + _brand.saturation * 0.4).clamp(0.0, 1.0)).toColor();
    } else {
      out = c.withValues(alpha: 1);
    }
    out = out.withValues(alpha: c.a);
    _cache[key] = out;
    return out;
  }

  @override
  GmwfThemeChoice copyWith({ui.GThemeChoice? choice, ui.GComfortColors? colors}) =>
      GmwfThemeChoice(choice ?? this.choice, colors ?? this.colors);

  @override
  GmwfThemeChoice lerp(ThemeExtension<GmwfThemeChoice>? other, double t) =>
      other is GmwfThemeChoice && t >= 0.5 ? other : this;
}
