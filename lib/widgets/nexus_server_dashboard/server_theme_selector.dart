import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';
import 'server_theme.dart';

/// Interactive button to display current theme and open theme switcher modal
class ServerThemeSelectorButton extends StatelessWidget {
  final bool compact;

  const ServerThemeSelectorButton({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ServerThemeController.instance,
      builder: (context, _) {
        final current = ServerThemeController.instance.currentTokens;
        final theme = ServerThemeController.instance.currentTheme;

        final shortLabel = switch (theme) {
          ServerDashboardTheme.midnightPlumHybrid => 'Plum Hybrid',
          ServerDashboardTheme.midnightPlumDark => 'Plum Dark',
          ServerDashboardTheme.nexusCoreHybrid => 'Nexus Hybrid',
          ServerDashboardTheme.nexusCoreDark => 'Nexus Dark',
        };

        return OutlinedButton.icon(
          onPressed: () => ServerThemeSelectorDialog.show(context),
          icon: Icon(
            current.isDark ? Icons.dark_mode_rounded : Icons.palette_outlined,
            size: 15,
            color: NexusColors.primary,
          ),
          label: compact
              ? Text(
                  shortLabel,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: NexusColors.textMain,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      shortLabel,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textMain,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down_rounded, size: 16, color: NexusColors.textSecondary),
                  ],
                ),
          style: OutlinedButton.styleFrom(
            backgroundColor: NexusColors.cardBg,
            foregroundColor: NexusColors.textMain,
            side: BorderSide(color: NexusColors.cardBorder),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      },
    );
  }
}

/// Modal dialog allowing the administrator to switch between Midnight Plum and Nexus Core themes
class ServerThemeSelectorDialog extends StatelessWidget {
  const ServerThemeSelectorDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => const ServerThemeSelectorDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ServerThemeController.instance,
      builder: (context, _) {
        final activeTheme = ServerThemeController.instance.currentTheme;

        return Dialog(
          backgroundColor: NexusColors.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: NexusColors.cardBorder),
          ),
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: NexusColors.primaryMuted,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.palette_rounded, size: 20, color: NexusColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dashboard Visual Theme',
                            style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: NexusColors.textMain,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Choose your preferred visual design and ambient appearance.',
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: NexusColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, size: 18, color: NexusColors.textSecondary),
                      splashRadius: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Theme Options List
                _buildThemeCard(
                  context: context,
                  theme: ServerDashboardTheme.midnightPlumHybrid,
                  tokens: ServerThemeTokens.midnightPlumHybrid,
                  isSelected: activeTheme == ServerDashboardTheme.midnightPlumHybrid,
                  badgeText: 'SPECIFICATION (LIGHT / HYBRID)',
                ),
                const SizedBox(height: 10),
                _buildThemeCard(
                  context: context,
                  theme: ServerDashboardTheme.midnightPlumDark,
                  tokens: ServerThemeTokens.midnightPlumDark,
                  isSelected: activeTheme == ServerDashboardTheme.midnightPlumDark,
                  badgeText: 'SPECIFICATION (DARK MODE)',
                ),
                const SizedBox(height: 10),
                _buildThemeCard(
                  context: context,
                  theme: ServerDashboardTheme.nexusCoreHybrid,
                  tokens: ServerThemeTokens.nexusCoreHybrid,
                  isSelected: activeTheme == ServerDashboardTheme.nexusCoreHybrid,
                  badgeText: 'NEXUS.CORE (LIGHT / HYBRID)',
                ),
                const SizedBox(height: 10),
                _buildThemeCard(
                  context: context,
                  theme: ServerDashboardTheme.nexusCoreDark,
                  tokens: ServerThemeTokens.nexusCoreDark,
                  isSelected: activeTheme == ServerDashboardTheme.nexusCoreDark,
                  badgeText: 'NEXUS.CORE (DARK MODE)',
                ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: NexusColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(
                        'Done',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildThemeCard({
    required BuildContext context,
    required ServerDashboardTheme theme,
    required ServerThemeTokens tokens,
    required bool isSelected,
    required String badgeText,
  }) {
    return InkWell(
      onTap: () {
        ServerThemeController.instance.setTheme(theme);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? NexusColors.primary.withValues(alpha: 0.08)
              : (NexusColors.isDark ? tokens.sidebarBg.withValues(alpha: 0.5) : const Color(0xFFFAFAFC)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? NexusColors.primary : NexusColors.cardBorder,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            // Radio Indicator
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? NexusColors.primary : NexusColors.textSecondary.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: NexusColors.primary,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),

            // Content details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        tokens.name,
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: NexusColors.textMain,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isSelected ? NexusColors.primary : NexusColors.textSecondary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badgeText,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: isSelected ? Colors.white : NexusColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tokens.description,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),

            // Live 4-Color Swatch Preview
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: NexusColors.cardBorder),
              ),
              child: Row(
                children: [
                  _colorDot(tokens.sidebarBg, 'Sidebar'),
                  const SizedBox(width: 4),
                  _colorDot(tokens.mainBg, 'Canvas'),
                  const SizedBox(width: 4),
                  _colorDot(tokens.cardBg, 'Cards'),
                  const SizedBox(width: 4),
                  _colorDot(tokens.primary, 'Accent'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorDot(Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black.withValues(alpha: 0.15), width: 0.8),
        ),
      ),
    );
  }
}

