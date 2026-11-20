// lib/pages/home/home_motion.dart
//
// The home's motion, from two small libraries instead of hand-built
// controllers:
//   • flutter_animate — one-shot staggered fade + rise for cards and tiles
//   • animations      — Material "fade through" when the page changes
//
// Everything runs once on entry (no loops), uses opacity/transform only (cheap
// on low-end GPUs), and is switched off when the OS asks for reduced motion.

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

bool homeMotionOff(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

extension HomeEnter on Widget {
  /// Fades and lifts this widget in, [index] steps after the first.
  Widget enter(BuildContext context, {int index = 0}) {
    if (homeMotionOff(context)) return this;
    return animate(delay: Duration(milliseconds: 45 * index.clamp(0, 12)))
        .fadeIn(duration: 320.ms, curve: Curves.easeOut)
        .moveY(begin: 10, end: 0, duration: 380.ms, curve: Curves.easeOutCubic);
  }
}

extension HomeShimmer on Widget {
  /// Soft sweep over loading placeholders (only while loading).
  Widget loadingShimmer(BuildContext context) {
    if (homeMotionOff(context)) return this;
    return animate(onPlay: (c) => c.repeat())
        .shimmer(duration: 1400.ms, color: context.comfort.surface.withValues(alpha: 0.6));
  }
}

/// Swaps the shell's page with a Material fade-through.
class HomePageSwitcher extends StatelessWidget {
  const HomePageSwitcher({super.key, required this.child});

  /// Must carry a key that changes with the page.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (homeMotionOff(context)) return child;
    return PageTransitionSwitcher(
      duration: GMotion.slow,
      transitionBuilder: (child, primary, secondary) => FadeThroughTransition(
        animation: primary,
        secondaryAnimation: secondary,
        fillColor: Colors.transparent,
        child: child,
      ),
      child: child,
    );
  }
}
