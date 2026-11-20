// lib/design/theme/gmwf_theme.dart
//
// ── GTheme — Material ThemeData for the whole app (Design System v2) ─────────
// "Clean modern": cool slate canvas, near-white cards on a 1px hairline,
// flat buttons, one font (Inter), and the user's accent as the only strong
// colour. Every stock Material widget (AppBar, Card, Dialog, TextField,
// buttons, chips, tabs, menus, tables, snackbars …) is themed here, so screens
// that use plain Material widgets pick up the design system without edits.
//
// Built by main.dart for light and dark:
//   GTheme.build(seedColor: accent, cardRadius: 16, brightness: Brightness.light)
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:gmwf/theme/app_visual_theme.dart';
import 'package:gmwf_ui/gmwf_ui.dart' as ui show GTheme, GThemeChoice;

import '../tokens/colors.dart';
import '../tokens/comfort_colors.dart';
import '../tokens/radius.dart';
import '../tokens/shadows.dart';
import '../tokens/soft_palette.dart';
import '../tokens/typography.dart';

class GTheme {
  GTheme._(); // prevent instantiation

  static ThemeData build({
    required Color seedColor,
    required Brightness brightness,
    double cardRadius = Gr.r4,
    PageTransitionsTheme? pageTransitionsTheme,
    AppVisualTheme? visualTheme,
    Color? customAccent,
    // The user's theme (GMWF / Nexus / Twilight). When set it decides every
    // colour, from the shared design system; [visualTheme] is then ignored.
    ui.GThemeChoice? choice,
  }) {
    final isDark = brightness == Brightness.dark;
    final dsColors = choice == null ? null : ui.GTheme.colors(brightness, family: choice.family, brandOverride: customAccent);
    final c = dsColors != null
        ? GComfortColors.fromDesignSystem(dsColors)
        : visualTheme != null
            ? GComfortColors.fromVisualTheme(visualTheme, overrideAccent: customAccent)
            : (isDark ? GComfortColors.dark : GComfortColors.light);
    final effectiveSeed = customAccent ?? (visualTheme != null || dsColors != null ? c.brand : seedColor);
    // The design-system brand is already readable on dark surfaces.
    final primary = dsColors != null ? c.brand : (isDark ? GColor.accentOnDark(effectiveSeed) : effectiveSeed);
    final onPrimary = GColor.onAccent(primary);
    final error = c.danger;

    // Controls are a little tighter than cards so nested corners look right.
    final controlRadius = BorderRadius.circular((cardRadius * 0.625).clamp(6.0, 14.0));
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cardRadius),
      side: BorderSide(color: c.border),
    );
    final overlayShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cardRadius * 0.75),
      side: BorderSide(color: c.border),
    );

    final scheme = ColorScheme.fromSeed(
      seedColor: effectiveSeed,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: Color.alphaBlend(primary.withValues(alpha: isDark ? 0.22 : 0.12), c.surface),
      onPrimaryContainer: isDark ? c.textPrimary : effectiveSeed,
      secondary: c.textSecondary,
      onSecondary: c.surface,
      error: error,
      onError: GColor.onAccent(error),
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: isDark ? c.background : c.surface,
      surfaceContainerLow: c.surface,
      surfaceContainer: isDark ? c.surface : c.background,
      surfaceContainerHigh: c.surfaceSunken,
      surfaceContainerHighest: c.border,
      outline: c.borderStrong,
      outlineVariant: c.border,
      shadow: SoftPalette.slate900,
      scrim: SoftPalette.slate900,
    );

    final text = GText.textTheme(primary: c.textPrimary, secondary: c.textSecondary);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: color, width: width),
        );

    final buttonShape = RoundedRectangleBorder(borderRadius: controlRadius);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 12);
    const buttonMinSize = Size(64, 40);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: GText.family,
      colorScheme: scheme,
      textTheme: text,
      // Semantic eye-comfort colours for every screen: context.comfort.<role>.
      // Semantic colours for app screens (context.comfort), for gmwf_ui
      // widgets, and the theme choice (context.adapt follows it).
      extensions: [c, ?dsColors, if (choice != null && dsColors != null) GmwfThemeChoice(choice, dsColors)],
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      dividerColor: c.border,
      hoverColor: c.textPrimary.withValues(alpha: 0.04),
      splashColor: primary.withValues(alpha: 0.10),
      highlightColor: primary.withValues(alpha: 0.06),
      focusColor: primary.withValues(alpha: 0.12),
      visualDensity: VisualDensity.standard,

      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: c.textSecondary, size: 22),
        actionsIconTheme: IconThemeData(color: c.textSecondary, size: 22),
        titleTextStyle: GText.h3(c.textPrimary).copyWith(fontSize: 17),
        shape: Border(bottom: BorderSide(color: c.border)),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: SoftPalette.slate900,
        shape: cardShape,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: SoftPalette.slate900.withValues(alpha: isDark ? 0.6 : 0.25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius + 4),
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: GText.h2(c.textPrimary).copyWith(fontSize: 18),
        contentTextStyle: GText.body1(c.textSecondary),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius + 4)),
        ),
        dragHandleColor: c.borderStrong,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceSunken,
        hoverColor: Colors.transparent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: inputBorder(c.borderStrong),
        enabledBorder: inputBorder(c.borderStrong),
        disabledBorder: inputBorder(c.border),
        focusedBorder: inputBorder(primary, 1.6),
        errorBorder: inputBorder(error),
        focusedErrorBorder: inputBorder(error, 1.6),
        labelStyle: GText.body2(c.textSecondary),
        floatingLabelStyle: GText.label(primary),
        hintStyle: GText.body1(c.textMuted),
        helperStyle: GText.caption(c.textMuted),
        errorStyle: GText.caption(error).copyWith(fontWeight: FontWeight.w500),
        prefixIconColor: c.textMuted,
        suffixIconColor: c.textMuted,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: c.border,
          disabledForegroundColor: c.textMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: GText.buttonLg(onPrimary),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: GText.buttonLg(onPrimary),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          backgroundColor: c.surface,
          side: BorderSide(color: c.borderStrong),
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: GText.buttonLg(c.textPrimary),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(48, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: buttonShape,
          textStyle: GText.buttonLg(primary),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: buttonShape),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: onPrimary,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
        extendedTextStyle: GText.buttonLg(onPrimary),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: c.surface,
        selectedColor: scheme.primaryContainer,
        disabledColor: c.border,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
        labelStyle: GText.label(c.textSecondary),
        secondaryLabelStyle: GText.label(primary),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        checkmarkColor: primary,
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: c.textSecondary,
        labelStyle: GText.body2Bold(primary),
        unselectedLabelStyle: GText.body2(c.textSecondary).copyWith(fontWeight: FontWeight.w500),
        indicatorColor: primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: c.border,
        dividerHeight: 1,
      ),

      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),

      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        titleTextStyle: GText.body1(c.textPrimary).copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: GText.body2(c.textSecondary),
        leadingAndTrailingTextStyle: GText.body2(c.textSecondary),
        selectedColor: primary,
        selectedTileColor: scheme.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
      ),

      expansionTileTheme: ExpansionTileThemeData(
        iconColor: c.textSecondary,
        collapsedIconColor: c.textMuted,
        textColor: c.textPrimary,
        collapsedTextColor: c.textPrimary,
        shape: const Border(),
        collapsedShape: const Border(),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: SoftPalette.slate900.withValues(alpha: isDark ? 0.6 : 0.3),
        shape: overlayShape,
        textStyle: GText.body1(c.textPrimary),
        labelTextStyle: WidgetStatePropertyAll(GText.body1(c.textPrimary)),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(overlayShape),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: GText.body1(c.textPrimary),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(overlayShape),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? SoftPalette.slate700 : SoftPalette.slate800,
          borderRadius: BorderRadius.circular(Gr.r2),
          boxShadow: GShadow.s2(isDark),
        ),
        textStyle: GText.caption(SoftPalette.gray150).copyWith(fontWeight: FontWeight.w500, fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 400),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? SoftPalette.slate700 : SoftPalette.slate800,
        contentTextStyle: GText.body2Bold(SoftPalette.gray50).copyWith(fontSize: 13.5),
        actionTextColor: GColor.accentOnDark(seedColor),
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gr.r3)),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: c.border,
        circularTrackColor: Colors.transparent,
      ),

      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gr.r1)),
        side: BorderSide(color: c.borderStrong, width: 1.5),
      ),

      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.transparent : c.borderStrong,
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: primary),
        unselectedIconTheme: IconThemeData(color: c.textMuted),
        selectedLabelTextStyle: GText.label(primary),
        unselectedLabelTextStyle: GText.label(c.textSecondary).copyWith(fontWeight: FontWeight.w500),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(GText.label(c.textSecondary)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: c.surface,
        selectedItemColor: primary,
        unselectedItemColor: c.textMuted,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
      ),

      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(isDark ? SoftPalette.slate750 : SoftPalette.slate100),
        headingTextStyle: GText.label(c.textSecondary),
        dataTextStyle: GText.body2(c.textPrimary),
        dividerThickness: 1,
        headingRowHeight: 44,
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(c.textMuted.withValues(alpha: 0.45)),
        radius: const Radius.circular(Gr.r2),
        thickness: const WidgetStatePropertyAll(6),
      ),

      datePickerTheme: DatePickerThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: primary,
        headerForegroundColor: onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius + 4)),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius + 4)),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: primary.withValues(alpha: 0.24),
        selectionHandleColor: primary,
      ),

      badgeTheme: BadgeThemeData(
        backgroundColor: error,
        textColor: GColor.onAccent(error),
        textStyle: GText.micro(GColor.onAccent(error)),
      ),

      pageTransitionsTheme: pageTransitionsTheme,
    );
  }
}
