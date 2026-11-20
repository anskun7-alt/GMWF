// lib/widgets/app_back_button.dart

import 'package:flutter/material.dart';
import '../pages/home/home_module_host.dart';

/// A modern, colorful, rounded back button for GMWF app headers and AppBars.
/// Automatically hides if there is no route to pop unless an explicit [onPressed] is provided.
class AppBackButton extends StatelessWidget {
  final Color? color;
  final Color? bgColor;
  final VoidCallback? onPressed;

  const AppBackButton({
    super.key,
    this.color,
    this.bgColor,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.canPop(context);
    if ((!canPop || HomeModuleHost.isModuleRoot(context)) && onPressed == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final iconColor = color ?? theme.colorScheme.onSurface;
    final buttonBg = bgColor ?? iconColor.withValues(alpha: 0.10);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed ?? () => Navigator.maybePop(context),
          borderRadius: BorderRadius.circular(10),
          hoverColor: iconColor.withValues(alpha: 0.15),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: buttonBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: iconColor.withValues(alpha: 0.20),
                width: 1,
              ),
            ),
            child: Icon(
              Icons.arrow_back_rounded,
              color: iconColor,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}
