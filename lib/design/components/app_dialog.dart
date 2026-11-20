// lib/design/components/app_dialog.dart
//
// ── AppConfirmDialog & showLogoutDialog — Unified Design System Dialogs ──────
// Standardized confirmation and destructive dialogs for the entire application.
// Enforces brand consistency:
//   • Destructive actions (Log Out, Delete) ALWAYS use Warning Red (SoftPalette.vividRed).
//   • Cancel actions ALWAYS use Emerald/Teal brand or neutral secondary styling.
//   • Fully supports dark/light mode with sleek modern geometry and soft shadows.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import '../tokens/soft_palette.dart';
import '../tokens/comfort_colors.dart';

/// Shows a standardized confirmation dialog across the application.
Future<bool> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  IconData? icon,
  bool isDanger = false,
  Widget? extraContent,
  String? warningNotice,
}) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final c = context.comfort;
  final accentColor = isDanger ? c.danger : c.brand;
  final accentSoft = isDanger ? c.dangerBg : c.brandSoft;

  final result = await showDialog<bool>(
    context: context,
    barrierColor: SoftPalette.slate900.withValues(alpha: 0.45),
    builder: (dialogCtx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: isDark ? 0.16 : 0.10),
                blurRadius: 28,
                spreadRadius: -4,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accentColor, accentColor.withValues(alpha: 0.65)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (icon != null) ...[
                          Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accentSoft,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: accentColor.withValues(alpha: isDark ? 0.35 : 0.22),
                              ),
                            ),
                            child: Icon(icon, color: accentColor, size: 22),
                          ),
                          const SizedBox(width: 14),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: c.textPrimary,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(dialogCtx).pop(false),
                          icon: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                          visualDensity: VisualDensity.compact,
                          tooltip: cancelLabel,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: c.textSecondary,
                      ),
                    ),
                    if (warningNotice != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: c.warningBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: c.warning.withValues(alpha: 0.35),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: c.warning,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                warningNotice,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.warning,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (extraContent != null) ...[
                      const SizedBox(height: 14),
                      extraContent,
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                decoration: BoxDecoration(
                  color: c.surfaceSunken.withValues(alpha: isDark ? 0.5 : 0.65),
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: c.surface,
                          foregroundColor: c.textPrimary,
                          side: BorderSide(color: c.borderStrong),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                        ),
                        onPressed: () => Navigator.of(dialogCtx).pop(false),
                        child: Text(
                          cancelLabel,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: isDanger ? Colors.white : c.onBrand,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                        ),
                        onPressed: () => Navigator.of(dialogCtx).pop(true),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[
                              Icon(icon, size: 16),
                              const SizedBox(width: 7),
                            ],
                            Text(
                              confirmLabel,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  return result == true;
}

/// Standardized Log Out confirmation dialog for the entire application.
/// Used everywhere a user attempts to log out:
///   • Warning Red action button (SoftPalette.vividRed)
///   • Brand Teal/Emerald cancel button (SoftPalette.teal600)
///   • Consistent iconography and reassurance
Future<bool> showLogoutDialog(
  BuildContext context, {
  String? subtitle,
  String? warningNotice,
}) {
  return showAppConfirmDialog(
    context: context,
    title: 'Log Out',
    message: subtitle ?? 'Are you sure you want to log out of GMWF?',
    confirmLabel: 'Log Out',
    cancelLabel: 'Cancel',
    icon: Icons.logout_rounded,
    isDanger: true,
    warningNotice: warningNotice,
  );
}
