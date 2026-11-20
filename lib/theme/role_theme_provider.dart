// lib/theme/role_theme_provider.dart

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:hive/hive.dart';
import 'app_theme.dart';
import '../design/tokens/shadows.dart';
import '../design/tokens/typography.dart';
import '../services/user_theme_service.dart';


class RoleThemeScope extends InheritedNotifier<ValueNotifier<bool>> {
  final RoleTheme role;

  RoleThemeScope({
    super.key,
    required this.role,
    required Widget child,
  }) : super(notifier: UserThemeService.currentThemeNotifier, child: child);

  static RoleTheme of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RoleThemeScope>();
    return scope?.role ?? RoleTheme.admin;
  }

  static RoleTheme roleOf(BuildContext context) => of(context);


  static RoleThemeData dataOf(BuildContext context, [Color? customColor, String? explicitUserKey]) {
    Color? resolvedColor = customColor;
    if (resolvedColor == null && Hive.isBoxOpen('app_settings')) {
      final prefColorStr = Hive.box('app_settings').get('custom_accent_color') as String?;
      if (prefColorStr != null && prefColorStr.isNotEmpty) {
        try {
          final hex = prefColorStr.replaceAll('#', '');
          resolvedColor = Color(int.parse('FF$hex', radix: 16));
        } catch (_) {}
      }
    }
    final isDarkMode = UserThemeService.isDarkMode(explicitUserKey);
    final visualTheme = UserThemeService.getVisualTheme(explicitUserKey);
    return RoleThemeData.of(of(context)).withVisualTheme(
      visualTheme,
      customAccent: resolvedColor,
      isDark: isDarkMode,
    );
  }

  @override
  bool updateShouldNotify(RoleThemeScope oldWidget) => role != oldWidget.role || notifier != oldWidget.notifier;
}

// ─────────────────────────────────────────────────────────────────────────────
// Themed scaffold helper shared across all role-aware pages
// ─────────────────────────────────────────────────────────────────────────────

class RolePageScaffold extends StatelessWidget {
  final Widget child;
  final String? title;
  final List<Widget>? actions;
  final bool showBack;

  const RolePageScaffold({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: title != null
          ? AppBar(
              backgroundColor: t.bgCard,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              leading: showBack
                  ? IconButton(
                      icon: Icon(Icons.arrow_back_rounded, color: t.textSecondary, size: 22),
                      onPressed: () => Navigator.maybePop(context),
                    )
                  : null,
              title: Text(
                title!,
                style: GText.h3(t.textPrimary).copyWith(fontSize: 17),
              ),
              actions: actions,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(height: 1, color: t.bgRule),
              ),
            )
          : null,
      body: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Role card — flat surface, 1px hairline, soft shadow (Design System v2)
// ─────────────────────────────────────────────────────────────────────────────

class RoleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool showGlow;
  final VoidCallback? onTap;
  final Gradient? gradient;

  const RoleCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 16,
    this.showGlow = false,
    this.onTap,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    double resolvedRadius = radius;
    if (radius == 16 && Hive.isBoxOpen('app_settings')) {
      resolvedRadius = Hive.box('app_settings').get('card_radius', defaultValue: 16.0) as double;
    }

    final isDark = t.isDarkCanvas;

    // v2: flat surface on a 1px hairline; the shadow only hints at depth.
    final List<BoxShadow> neumorphicShadows = showGlow
        ? GShadow.s3(isDark, t.accent)
        : GShadow.s1(isDark);

    final cardContent = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: margin,
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: gradient == null ? t.bgCard : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(resolvedRadius),
        border: Border.all(
          color: t.bgRule,
          width: 1,
        ),
        boxShadow: neumorphicShadows,
      ),
      child: child,
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(resolvedRadius),
        child: cardContent,
      );
    }

    return cardContent;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable Neumorphic 3D Container
// ─────────────────────────────────────────────────────────────────────────────

class NeumorphicContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool showGlow;
  final VoidCallback? onTap;
  final Color? color;

  const NeumorphicContainer({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 16,
    this.showGlow = false,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isDark = t.isDarkCanvas;
    double resolvedRadius = radius;
    if (radius == 16 && Hive.isBoxOpen('app_settings')) {
      resolvedRadius = Hive.box('app_settings').get('card_radius', defaultValue: 16.0) as double;
    }

    final dec = Neumorphic3DStyle.raisedDecoration(
      isDark: isDark,
      backgroundColor: color ?? t.bgCard,
      borderRadius: resolvedRadius,
      accentColor: t.accent,
      showGlow: showGlow,
    );

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: dec,
      child: child,
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(resolvedRadius),
        child: content,
      );
    }
    return content;
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Themed text field decoration
// ─────────────────────────────────────────────────────────────────────────────

InputDecoration roleInputDecoration(
  BuildContext context, {
  required String label,
  required IconData icon,
  bool required = false,
}) {
  final t = RoleThemeScope.dataOf(context);
  final radius = Hive.isBoxOpen('app_settings')
      ? ((Hive.box('app_settings').get('card_radius', defaultValue: 16.0) as num) * 0.625).clamp(6.0, 14.0).toDouble()
      : 10.0;
  // v2: a visible-but-quiet resting border; the accent only on focus.
  final rest = t.isDarkCanvas ? t.bgRule : SoftPalette.slate200;

  return InputDecoration(
    labelText: required ? '$label *' : label,
    labelStyle: TextStyle(fontSize: 13.5, color: t.textSecondary),
    floatingLabelStyle: TextStyle(fontSize: 12, color: t.accent, fontWeight: FontWeight.w600),
    prefixIcon: Icon(icon, color: t.textTertiary, size: 20),
    filled: true,
    fillColor: t.bgCardAlt,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: rest, width: 1),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: rest, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: t.accent, width: 1.6),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: t.danger, width: 1.5),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: t.danger, width: 2),
    ),
    errorStyle: const TextStyle(fontSize: 11.5),
    counterText: '',
  );
}
