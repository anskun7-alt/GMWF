// lib/pages/school/theme/school_theme.dart

import 'package:flutter/material.dart';
import '../../../theme/role_theme_provider.dart';

class SchoolTheme {
  // ── Brand Colors ──────────────────────────────────────────────────────────
  static const Color primary       = Color(0xFF6366F1); // Indigo 500
  static const Color primaryDark   = Color(0xFF4338CA); // Indigo 700
  static const Color primaryLight  = Color(0xFFEEF2FF); // Indigo 50

  static const Color accent        = Color(0xFF10B981); // Emerald 500
  static const Color accentDark    = Color(0xFF059669); // Emerald 600
  static const Color accentLight   = Color(0xFFECFDF5); // Emerald 50

  static const Color sidebarBg     = Color(0xFF0F172A); // Slate 900
  static const Color sidebarBorder = Color(0xFF1E293B); // Slate 800
  static const Color sidebarText   = Color(0xFFCBD5E1); // Slate 300
  static const Color sidebarMuted  = Color(0xFF94A3B8); // Slate 400 (High contrast WCAG AA)

  // ── Documented Status Palette ─────────────────────────────────────────────
  /// Present / Active / Success -> Emerald
  static const Color statusPresent = Color(0xFF10B981);
  static const Color statusPresentBg = Color(0xFFECFDF5);

  /// Absent / Suspended / Error / Dropped -> Red
  static const Color statusAbsent  = Color(0xFFEF4444);
  static const Color statusAbsentBg  = Color(0xFFFEF2F2);

  /// On Leave / Warning / Overdue -> Amber
  static const Color statusLeave   = Color(0xFFF59E0B);
  static const Color statusLeaveBg   = Color(0xFFFFFBEB);

  /// Late / Info / Registered -> Purple / Violet
  static const Color statusLate    = Color(0xFF8B5CF6);
  static const Color statusLateBg    = Color(0xFFF5F3FF);

  /// Graduated / Transferred -> Blue
  static const Color statusGraduated   = Color(0xFF3B82F6);
  static const Color statusGraduatedBg = Color(0xFFEFF6FF);

  // ── Grade Band Visual Colors ──────────────────────────────────────────────
  static Color getGradeColor(String grade) {
    final g = grade.trim().toLowerCase();
    if (g.contains('pre'))  return const Color(0xFF0D9488); // Teal
    if (g.contains('9th') || g == '9')  return const Color(0xFF6366F1); // Indigo
    if (g.contains('10th') || g == '10') return const Color(0xFF2563EB); // Royal Blue
    if (g.contains('nursery') || g.contains('kg')) return const Color(0xFFEC4899); // Pink
    return const Color(0xFF4B5563); // Slate
  }

  // ── Letter Grade Spectrum Scale (A+ down to F) ────────────────────────────
  static Color getLetterGradeColor(String letterGrade) {
    final lg = letterGrade.trim().toUpperCase();
    if (lg == 'A+') return const Color(0xFF10B981); // Emerald
    if (lg == 'A')  return const Color(0xFF059669); // Dark Emerald
    if (lg == 'B')  return const Color(0xFF3B82F6); // Blue
    if (lg == 'C')  return const Color(0xFFF59E0B); // Amber
    if (lg == 'D')  return const Color(0xFFF97316); // Orange
    return const Color(0xFFEF4444); // Red (F)
  }

  // ── Surface & Neutral Light Tokens ─────────────────────────────────────────
  static const Color bgLight        = Color(0xFFF8FAFC); // Slate 50
  static const Color cardLight      = Colors.white;
  static const Color borderLight    = Color(0xFFE2E8F0); // Slate 200
  static const Color textDark       = Color(0xFF0F172A); // Slate 900
  static const Color textMid        = Color(0xFF475569); // Slate 600
  static const Color textMuted      = Color(0xFF64748B); // Slate 500

  // ── Surface & Neutral Dark Tokens ──────────────────────────────────────────
  static const Color bgDark         = Color(0xFF0B0F19);
  static const Color cardDark       = Color(0xFF151D2A);
  static const Color borderDark     = Color(0xFF232E42);
  static const Color textDarkTheme  = Color(0xFFF1F5F9);
  static const Color textMidDark    = Color(0xFF94A3B8);

  // ── Radii Constants ───────────────────────────────────────────────────────
  static const double r8  = 8.0;
  static const double r12 = 12.0;
  static const double r14 = 14.0;
  static const double r16 = 16.0;
  static const double r20 = 20.0;
  static const double r24 = 24.0;

  static BorderRadius radius8  = BorderRadius.circular(r8);
  static BorderRadius radius12 = BorderRadius.circular(r12);
  static BorderRadius radius14 = BorderRadius.circular(r14);
  static BorderRadius radius16 = BorderRadius.circular(r16);
  static BorderRadius radius20 = BorderRadius.circular(r20);
  static BorderRadius radius24 = BorderRadius.circular(r24);

  // ── Card Shadows ──────────────────────────────────────────────────────────
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: const Color(0xFF0F172A).withValues(alpha: 0.05),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  // ── Typography Scale ──────────────────────────────────────────────────────
  static const TextStyle titleStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: textDark,
  );

  static const TextStyle subtitleStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: textMid,
  );

  static const TextStyle bodyStyle = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.normal,
    color: textDark,
  );

  static const TextStyle captionStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textMuted,
  );

  static const TextStyle labelStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.1,
    color: textMuted,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable School UI Components (Themed with original app design system)
// ─────────────────────────────────────────────────────────────────────────────

/// Status badge with soft background and subtle border.
class SchoolBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color? backgroundColor;
  final IconData? icon;
  final double fontSize;

  const SchoolBadge({
    super.key,
    required this.label,
    required this.color,
    this.backgroundColor,
    this.icon,
    this.fontSize = 11.5,
  });

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? color.withValues(alpha: 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stat Card aligned with the app design system and RoleThemeData.
class SchoolMetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String? subtitle;
  final IconData icon;
  final Color accentColor;
  final Color? bgColor;
  final VoidCallback? onTap;

  const SchoolMetricCard({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    required this.icon,
    this.accentColor = SchoolTheme.primary,
    this.bgColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor ?? t.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.bgRule),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: accentColor),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: t.textPrimary,
                letterSpacing: -0.4,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: t.textTertiary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Access Restricted / Data Isolation view shown when a user (e.g. teacher) attempts
/// to access restricted modules like fee management or audit trails.
class SchoolAccessDenied extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onBack;

  const SchoolAccessDenied({
    super.key,
    this.title = 'Access Restricted / رسائی ممنوع',
    this.message = 'This school module is restricted to School Administration and Principal. Contact system administration if you require access.',
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.bgRule),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.lock_rounded, size: 36, color: Colors.redAccent),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: t.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: t.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onBack ?? () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('Return Back', style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
