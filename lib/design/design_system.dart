// lib/design/design_system.dart
//
// ── GMWF Design System — Barrel Export ───────────────────────────────────────
// Single import for the entire design system:
//   import 'package:gmwf/design/design_system.dart';
//
// Provides: Gsp, Gr, GText, GShadow, GColor, GMotion, GBreakpoint, GTheme,
//           SoftPalette, GComfortColors (context.comfort),
//           AppButton, AppCard, AppChip, StatusBadge,
//           AppSectionHeader, AppSegmentedControl,
//           StatCard, HeroStatCard,
//           AppEmptyState, AppFeedback, AppToast,
//           AppDivider, AppVerticalDivider,
//           AppResponsiveLayout, AppResponsivePadding, AppResponsiveGrid
//
// ── Design System v2 — "clean modern" (2026-10) ──────────────────────────────
//   • One neutral canvas per mode for every role (RoleThemeData.toLight/
//     toDarkMode): slate100 canvas, slate50 cards, slate150 1px hairline.
//     Dark: slate900 canvas, slate800 cards. Role identity = the accent only.
//   • Surfaces are separated by a 1px border; shadows (GShadow s1–s4) are soft
//     and layered. The old neumorphic dual shadows are retired —
//     Neumorphic3DStyle / RoleCard / GShadow.raised now return the flat scale.
//   • One UI font: Inter (GText). Stat styles use tabular figures.
//   • The whole Material theme (inputs, buttons, dialogs, chips, tabs, menus,
//     tables, snackbars…) is built in theme/gmwf_theme.dart (GTheme.build).
//   • Accents are deepened in light mode for contrast and lifted just enough in
//     dark mode (GColor.accentOnDark) that light text on accent stays readable.
//   • Live reference: flutter run -t lib/design/gallery/design_gallery.dart
//
// ── Colour rules (eye comfort) ───────────────────────────────────────────────
//   • Every colour comes from SoftPalette (tokens/soft_palette.dart): no pure
//     white/black, no neon. test/no_hardcoded_colors_test.dart enforces this.
//   • Prefer semantic colours that follow light/dark automatically:
//       context.comfort.surface / .textPrimary / .border / .danger / .dangerBg …
//   • Need a shade that isn't there? Add it to the palette by regenerating it
//     with tool/soft_palette/ — never add Color(0x…) or Colors.* in a screen.
//   • Notifications: AppFeedback / AppToast (bottom-right, theme-aware, max 3).
// ─────────────────────────────────────────────────────────────────────────────

// ── Tokens ────────────────────────────────────────────────────────────────────
export 'tokens/breakpoints.dart';
export 'tokens/colors.dart';
export 'tokens/motion.dart';
export 'tokens/comfort_colors.dart';
export 'tokens/soft_palette.dart';
export 'tokens/radius.dart';
export 'tokens/shadows.dart';
export 'tokens/spacing.dart';
export 'tokens/typography.dart';

// ── Theme ─────────────────────────────────────────────────────────────────────
export 'theme/gmwf_theme.dart';

// ── Components ────────────────────────────────────────────────────────────────
export 'components/app_button.dart';
export 'components/app_card.dart';
export 'components/app_chip.dart';
export 'components/app_divider.dart';
export 'components/app_empty_state.dart';
export 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
export 'components/app_feedback.dart';
export 'components/app_toast.dart';
export 'components/decorative_image.dart';
export 'components/app_responsive_layout.dart';
export 'components/app_section_header.dart';
export 'components/app_segmented_control.dart';
export 'components/app_dialog.dart';
export 'components/stat_card.dart';
