// lib/pages/dispensary/widgets/desk_theme.dart
//
// ── Shared visual layer for every dispensary desk ────────────────────────────
// Doctor, Dispenser, Receptionist and the Hybrid desk all paint their canvas
// and panels through these two widgets, so the look is changed in ONE place
// and follows the user's theme (GMWF / Nexus / Twilight, light & dark).
//
//   DeskBackdrop — the canvas: theme background washed with soft radial
//                  glows of the theme's brand + accent hue.
//   DeskCard     — a panel: surface, hairline border, brand-tinted soft
//                  shadow, optional brand accent strip on top.
//
// DeskBackdrop is nest-safe: a desk embedded inside another desk (e.g. the
// Doctor tab inside the Hybrid desk) does not paint a second backdrop.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GComfortColors;

/// Theme hues used by the desk visuals.
class DeskHues {
  final Color background;
  final Color surface;
  final Color border;
  final Color brand;
  final Color brandStrong;
  final Color brandSoft;
  final Color onBrand;
  final Color accent;
  final bool isDark;

  const DeskHues._({
    required this.background,
    required this.surface,
    required this.border,
    required this.brand,
    required this.brandStrong,
    required this.brandSoft,
    required this.onBrand,
    required this.accent,
    required this.isDark,
  });

  factory DeskHues.of(BuildContext context) {
    final c = context.comfort;
    final ds = Theme.of(context).extension<ui.GComfortColors>();
    return DeskHues._(
      background: c.background,
      surface: c.surface,
      border: c.border,
      brand: c.brand,
      brandStrong: c.brandStrong,
      brandSoft: c.brandSoft,
      onBrand: c.onBrand,
      // Secondary glow: the theme's accent (gold / jade) when available.
      accent: ds?.accent ?? c.info,
      isDark: Theme.of(context).brightness == Brightness.dark,
    );
  }

  /// Filled brand gradient for selected pills, hero buttons and badges.
  LinearGradient get brandGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [brand, Color.lerp(brand, brandStrong, 0.65)!],
      );
}

class _DeskBackdropScope extends InheritedWidget {
  const _DeskBackdropScope({required super.child});

  @override
  bool updateShouldNotify(_DeskBackdropScope oldWidget) => false;
}

/// Themed canvas for a dispensary desk.
class DeskBackdrop extends StatelessWidget {
  final Widget child;

  const DeskBackdrop({super.key, required this.child});

  static bool _isNested(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DeskBackdropScope>() != null;

  @override
  Widget build(BuildContext context) {
    // Already inside a desk backdrop: stay transparent so the outer one shows.
    if (_isNested(context)) return child;

    final h = DeskHues.of(context);
    final brandGlow = h.brand.withValues(alpha: h.isDark ? 0.16 : 0.10);
    final accentGlow = h.accent.withValues(alpha: h.isDark ? 0.10 : 0.08);

    return _DeskBackdropScope(
      child: DecoratedBox(
        decoration: BoxDecoration(color: h.background),
        child: Stack(
          children: [
            // Brand hue washing in from the top-left.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-1.0, -1.1),
                      radius: 1.25,
                      colors: [brandGlow, brandGlow.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
            // Accent hue glowing from the bottom-right.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(1.1, 1.2),
                      radius: 1.1,
                      colors: [accentGlow, accentGlow.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
            // Thin brand band under the app bar ties the canvas to the header.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 140,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        h.brand.withValues(alpha: h.isDark ? 0.08 : 0.05),
                        h.brand.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

/// Themed panel for a dispensary desk.
class DeskCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry margin;
  final double radius;

  /// Paints a thin brand gradient strip along the top edge.
  final bool accentTop;

  const DeskCard({
    super.key,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.radius = 16,
    this.accentTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = DeskHues.of(context);
    final shape = BorderRadius.circular(radius);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: h.surface,
        gradient: h.isDark
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [h.surface, Color.lerp(h.surface, h.brandSoft, 0.22)!],
              ),
        borderRadius: shape,
        border: Border.all(
          color: h.isDark ? h.border : Color.lerp(h.border, h.brand, 0.08)!,
        ),
        boxShadow: [
          // Brand-tinted ambient lift.
          BoxShadow(
            color: h.brand.withValues(alpha: h.isDark ? 0.10 : 0.07),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
          // Tight contact shadow for crisp edges.
          BoxShadow(
            color: Colors.black.withValues(alpha: h.isDark ? 0.22 : 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: accentTop
            ? Stack(
                fit: StackFit.passthrough,
                children: [
                  child,
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 3,
                    child: IgnorePointer(
                      child: DecoratedBox(decoration: BoxDecoration(gradient: h.brandGradient)),
                    ),
                  ),
                ],
              )
            : child,
      ),
    );
  }
}
