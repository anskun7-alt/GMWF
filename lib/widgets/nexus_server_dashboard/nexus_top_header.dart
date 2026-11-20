import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';
import 'server_theme_selector.dart';

class NexusTopHeader extends StatelessWidget {
  final String breadcrumbSection;
  final String breadcrumbPage;
  final bool isRunning;
  final bool isOnline;
  final int syncedToday;
  final int queueSize;
  final bool isCatchingUp;
  final bool isSyncing;
  final VoidCallback? onRefresh;
  final VoidCallback? onCatchUp;
  final VoidCallback? onCloudSync;
  final VoidCallback? onOpenQueueDialog;
  final String adminName;
  final String branchDisplay;
  /// Opens the "Server location" dialog (branch + camp this server serves).
  final VoidCallback? onLocationTap;
  /// Shown (amber) when the location looks wrong, e.g. desks are from another branch.
  final String? locationWarning;
  /// Log out of the server PC (asks for confirmation; stops the server first).
  final VoidCallback? onLogout;

  const NexusTopHeader({
    this.onLogout,
    this.onLocationTap,
    this.locationWarning,
    this.onOpenQueueDialog,
    super.key,
    required this.breadcrumbSection,
    required this.breadcrumbPage,
    required this.isRunning,
    required this.isOnline,
    required this.syncedToday,
    required this.queueSize,
    required this.isCatchingUp,
    this.isSyncing = false,
    this.onRefresh,
    this.onCatchUp,
    this.onCloudSync,
    required this.adminName,
    required this.branchDisplay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        border: Border(
          bottom: BorderSide(color: NexusColors.cardBorder, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // ── Breadcrumbs & Live Status ────────────────────────────────
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                breadcrumbSection,
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: NexusColors.textSecondary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Icon(Icons.chevron_right_rounded, size: 15, color: NexusColors.textMuted),
              ),
              Text(
                breadcrumbPage,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: NexusColors.textMain,
                ),
              ),
              const SizedBox(width: 12),
              // Operational Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: isRunning ? NexusColors.successMuted : NexusColors.warningMuted,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: isRunning ? NexusColors.successBorder : NexusColors.warningBorder,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6.5,
                      height: 6.5,
                      decoration: BoxDecoration(
                        color: isRunning ? NexusColors.success : NexusColors.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isRunning ? 'Operational' : 'Standby',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isRunning ? NexusColors.success : NexusColors.warning,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const Spacer(),

          // ── Sync Status, Actions & Account ───────────────────────────
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Sync Status / Outbox Pill (single unified indicator)
              if (queueSize > 0)
                Tooltip(
                  message: '$syncedToday synced today • Click to inspect $queueSize queued items',
                  child: InkWell(
                    onTap: onOpenQueueDialog,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: NexusColors.warningMuted,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NexusColors.warningBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.pending_actions_rounded, size: 13.5, color: NexusColors.warning),
                          const SizedBox(width: 6),
                          Text(
                            '$queueSize Queued',
                            style: GoogleFonts.inter(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.warning,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                Tooltip(
                  message: isOnline ? 'Cloud sync connected ($syncedToday synced today)' : 'Offline mode',
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: NexusColors.mainBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: NexusColors.cardBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                          size: 13.5,
                          color: isOnline ? NexusColors.success : NexusColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isOnline ? '$syncedToday Synced' : 'Offline',
                          style: GoogleFonts.inter(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: NexusColors.textMain,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Reconcile / Catch-Up Action
              if (onCatchUp != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Catch-Up & Reconcile desks and cloud records',
                  child: _HeaderActionButton(
                    label: isCatchingUp ? 'Reconciling…' : 'Reconcile',
                    icon: Icons.sync_rounded,
                    color: NexusColors.primary,
                    isLoading: isCatchingUp,
                    onTap: isCatchingUp ? null : onCatchUp,
                  ),
                ),
              ],

              // Manual Cloud Sync Action
              if (onCloudSync != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Push pending queue & pull updates from cloud',
                  child: _HeaderActionButton(
                    label: isSyncing ? 'Syncing…' : 'Cloud Sync',
                    icon: Icons.cloud_upload_outlined,
                    color: NexusColors.success,
                    isLoading: isSyncing,
                    onTap: isSyncing ? null : onCloudSync,
                  ),
                ),
              ],

              // Refresh Icon
              if (onRefresh != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  onPressed: onRefresh,
                  tooltip: 'Refresh telemetry & sync status',
                  icon: Icon(Icons.refresh_rounded, size: 17, color: NexusColors.textSecondary),
                  splashRadius: 16,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],

              const SizedBox(width: 6),
              const ServerThemeSelectorButton(),

              const SizedBox(width: 10),
              SizedBox(
                height: 20,
                child: VerticalDivider(color: NexusColors.cardBorder, width: 1),
              ),
              const SizedBox(width: 10),

              // Server Location Selector
              Tooltip(
                message: locationWarning ?? 'Server location — click to change',
                child: InkWell(
                  onTap: onLocationTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    decoration: BoxDecoration(
                      color: locationWarning != null ? NexusColors.warningMuted : NexusColors.mainBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: locationWarning != null ? NexusColors.warningBorder : NexusColors.cardBorder,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          locationWarning != null ? Icons.warning_amber_rounded : Icons.location_on_outlined,
                          size: 14,
                          color: locationWarning != null ? NexusColors.warning : NexusColors.primary,
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            branchDisplay.isNotEmpty ? branchDisplay : 'Set location',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: locationWarning != null ? NexusColors.warning : NexusColors.textMain,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (onLocationTap != null) ...[
                          const SizedBox(width: 3),
                          Icon(Icons.expand_more_rounded, size: 15, color: NexusColors.textMuted),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

              if (onLogout != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Log out (stops the server)',
                  child: InkWell(
                    onTap: onLogout,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: NexusColors.errorMuted,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NexusColors.errorBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.logout_rounded, size: 14, color: NexusColors.error),
                          const SizedBox(width: 5),
                          Text(
                            'Logout',
                            style: GoogleFonts.inter(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isLoading;
  final VoidCallback? onTap;

  const _HeaderActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
              )
            else
              Icon(icon, size: 13.5, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
