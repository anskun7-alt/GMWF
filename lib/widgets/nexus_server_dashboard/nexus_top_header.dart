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
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        border: Border(
          bottom: BorderSide(color: NexusColors.cardBorder, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // ── Breadcrumbs ──────────────────────────────────────────────
          Row(
            children: [
              Text(
                breadcrumbSection,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: NexusColors.textSecondary,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.chevron_right_rounded, size: 16, color: NexusColors.textSecondary),
              ),
              Text(
                breadcrumbPage,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: NexusColors.textMain,
                ),
              ),
            ],
          ),

          const Spacer(),

          // ── Status & Telemetry Indicators ────────────────────────────
          Row(
            children: [
              // Operational Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isRunning ? NexusColors.successMuted : NexusColors.warningMuted,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isRunning ? NexusColors.successBorder : NexusColors.warningBorder,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isRunning ? NexusColors.success : NexusColors.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      isRunning ? 'System Operational' : 'Gateway Standby',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isRunning ? NexusColors.success : NexusColors.warning,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Synced Today Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: NexusColors.mainBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: NexusColors.cardBorder),
                ),
                child: Row(
                  children: [
                    Icon(
                      isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                      size: 14,
                      color: isOnline ? NexusColors.success : NexusColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$syncedToday Synced',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textMain,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Queue Size (if > 0)
              if (queueSize > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: NexusColors.warningMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: NexusColors.warningBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.pending_actions_rounded, size: 14, color: NexusColors.warning),
                      const SizedBox(width: 6),
                      Text(
                        '$queueSize Queued',
                        style: GoogleFonts.inter(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: NexusColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
              ],

              // Catch-Up & Reconcile Button
              if (onCatchUp != null) ...[
                OutlinedButton.icon(
                  onPressed: isCatchingUp ? null : onCatchUp,
                  icon: isCatchingUp
                      ? SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.primary),
                        )
                      : Icon(Icons.sync_rounded, size: 14, color: NexusColors.primary),
                  label: Text(
                    isCatchingUp ? 'Catching up...' : 'Catch-Up & Reconcile',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.primary,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexusColors.primary,
                    side: BorderSide(color: NexusColors.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                const SizedBox(width: 8),
              ],

              // Manual Cloud Sync Button
              if (onCloudSync != null) ...[
                OutlinedButton.icon(
                  onPressed: isSyncing ? null : onCloudSync,
                  icon: isSyncing
                      ? SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.success),
                        )
                      : Icon(Icons.cloud_upload_rounded, size: 14, color: NexusColors.success),
                  label: Text(
                    isSyncing ? 'Syncing...' : 'Cloud Sync',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.success,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexusColors.success,
                    side: BorderSide(color: NexusColors.success),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                const SizedBox(width: 8),
              ],

              // Refresh Button
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  tooltip: 'Refresh telemetry & sync status',
                  icon: Icon(Icons.refresh_rounded, size: 18, color: NexusColors.textSecondary),
                  splashRadius: 18,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  padding: EdgeInsets.zero,
                ),

              const SizedBox(width: 8),

              // Theme Switcher Button
              const ServerThemeSelectorButton(),

              const SizedBox(width: 8),
              SizedBox(
                height: 20,
                child: VerticalDivider(color: NexusColors.cardBorder, width: 1),
              ),
              const SizedBox(width: 12),

              // Server identity & location (click to change the location)
              Tooltip(
                message: locationWarning ?? 'Server location — click to change',
                child: InkWell(
                  onTap: onLocationTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: locationWarning != null ? NexusColors.warningMuted : NexusColors.primaryMuted,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (locationWarning != null ? NexusColors.warning : NexusColors.primary)
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          child: Icon(
                            locationWarning != null ? Icons.warning_amber_rounded : Icons.dns_rounded,
                            size: 16,
                            color: locationWarning != null ? NexusColors.warning : NexusColors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              adminName.isNotEmpty ? adminName : 'Server Control Panel',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: NexusColors.textMain,
                              ),
                            ),
                            Text(
                              branchDisplay.isNotEmpty ? branchDisplay : 'Location not set',
                              style: GoogleFonts.inter(
                                fontSize: 10.5,
                                fontWeight: locationWarning != null ? FontWeight.w600 : FontWeight.w400,
                                color: locationWarning != null ? NexusColors.warning : NexusColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        if (onLocationTap != null) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.expand_more_rounded, size: 16, color: NexusColors.textMuted),
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
                  child: OutlinedButton.icon(
                    onPressed: onLogout,
                    icon: Icon(Icons.logout_rounded, size: 15, color: NexusColors.error),
                    label: Text(
                      'Logout',
                      style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: NexusColors.error),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: NexusColors.errorBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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

