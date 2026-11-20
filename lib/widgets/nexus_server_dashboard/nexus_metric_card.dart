import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';

class NexusMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtext;
  final IconData icon;
  /// null = the current theme's primary / muted colour (theme colours are not constants).
  final Color? iconColor;
  final Color? iconBgColor;
  final String? trendText;
  final bool? isTrendPositive;
  final VoidCallback? onTap;
  /// Optional subtle accent border/tint highlight (e.g. warning when queue > 0).
  final bool highlightAccent;

  const NexusMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.subtext,
    required this.icon,
    this.iconColor,
    this.iconBgColor,
    this.trendText,
    this.isTrendPositive,
    this.onTap,
    this.highlightAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = iconColor ?? NexusColors.primary;
    final badgeBg = iconBgColor ?? accent.withValues(alpha: 0.12);
    final cardSurface = highlightAccent
        ? Color.alphaBlend(accent.withValues(alpha: 0.05), NexusColors.cardBg)
        : Color.alphaBlend(accent.withValues(alpha: 0.025), NexusColors.cardBg);
    final borderColor = highlightAccent
        ? accent.withValues(alpha: 0.35)
        : NexusColors.cardBorder;

    final cardContent = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: NexusColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trendText != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: isTrendPositive == true
                        ? NexusColors.successMuted
                        : (isTrendPositive == false
                            ? NexusColors.warningMuted
                            : NexusColors.mutedBg),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    trendText!,
                    style: GoogleFonts.inter(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: isTrendPositive == true
                          ? NexusColors.success
                          : (isTrendPositive == false
                              ? NexusColors.warning
                              : accent),
                    ),
                  ),
                ),
              ] else if (onTap != null) ...[
                Icon(Icons.arrow_outward_rounded, size: 14, color: NexusColors.textMuted),
              ],
            ],
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: NexusColors.textMain,
                letterSpacing: -0.5,
                height: 1.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtext,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w400,
              color: NexusColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: cardContent,
        ),
      );
    }

    return cardContent;
  }
}
