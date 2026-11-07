import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';

class NexusSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelectTab;
  final bool isRunning;
  final String serverIp;
  final int port;
  final int connectedDevicesCount;
  final int activeUsersCount;
  final int pendingEventsCount;
  final double cpuLoadPercent;
  final String adminName;
  final VoidCallback? onToggleServer;
  final VoidCallback? onCatchUp;
  final VoidCallback? onCloudSync;
  final bool isCatchingUp;
  final bool isSyncing;

  const NexusSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelectTab,
    required this.isRunning,
    required this.serverIp,
    required this.port,
    required this.connectedDevicesCount,
    required this.activeUsersCount,
    required this.pendingEventsCount,
    required this.cpuLoadPercent,
    required this.adminName,
    this.onToggleServer,
    this.onCatchUp,
    this.onCloudSync,
    this.isCatchingUp = false,
    this.isSyncing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: NexusColors.sidebarBg,
        border: Border(
          right: BorderSide(color: NexusColors.sidebarBorder, width: 1.0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 1. Branding Header ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: NexusColors.sidebarSecondary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: NexusColors.sidebarBorder),
                  ),
                  child: Image.asset(
                    'assets/logo/gmwf-1.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.dns_rounded,
                      color: NexusColors.primary,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GMWF SERVER',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: NexusColors.sidebarTextActive,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'SERVER CONTROL CENTER',
                        style: GoogleFonts.inter(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: NexusColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(color: NexusColors.sidebarBorder, height: 1),

          // ── 2. Navigation Items ─────────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              children: [
                _buildSectionHeader('WORKSPACE'),
                _buildNavItem(0, 'Overview', Icons.dashboard_outlined),
                _buildNavItem(
                  1,
                  'Department Activity',
                  Icons.domain_rounded,
                ),
                _buildNavItem(
                  2,
                  'Connected Devices',
                  Icons.devices_outlined,
                  counter: connectedDevicesCount > 0 ? connectedDevicesCount : null,
                ),
                _buildNavItem(
                  3,
                  'Users & Sessions',
                  Icons.people_alt_outlined,
                  counter: activeUsersCount > 0 ? activeUsersCount : null,
                ),

                const SizedBox(height: 16),
                _buildSectionHeader('ENGINES & HARDWARE'),
                _buildNavItem(4, 'Biometric Devices', Icons.fingerprint_rounded),
                _buildNavItem(5, 'Python Sync Engine', Icons.terminal_rounded),

                const SizedBox(height: 16),
                _buildSectionHeader('OBSERVABILITY'),
                _buildNavItem(6, 'Resource Monitoring', Icons.analytics_outlined),
                _buildNavItem(
                  7,
                  'System Logs',
                  Icons.receipt_long_outlined,
                  counter: pendingEventsCount > 0 ? pendingEventsCount : null,
                ),
                _buildNavItem(8, 'Network & Interfaces', Icons.wifi_tethering_outlined),

                const SizedBox(height: 16),
                _buildSectionHeader('SYSTEM'),
                _buildNavItem(9, 'Multi-Server Mesh', Icons.hub_rounded),
                _buildNavItem(10, 'Data Vault', Icons.storage_rounded),
                _buildNavItem(11, 'Settings & Firewall', Icons.tune_outlined),

                if (onCatchUp != null || onCloudSync != null) ...[
                  const SizedBox(height: 16),
                  _buildSectionHeader('QUICK OPERATIONS'),
                  if (onCatchUp != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SizedBox(
                        width: double.infinity,
                        height: 32,
                        child: OutlinedButton.icon(
                          onPressed: isCatchingUp ? null : onCatchUp,
                          icon: isCatchingUp
                              ? SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.primary),
                                )
                              : Icon(Icons.sync_rounded, size: 14, color: NexusColors.primary),
                          label: Text(
                            isCatchingUp ? 'Catching up...' : 'Catch-Up & Reconcile',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: NexusColors.primary),
                            backgroundColor: NexusColors.primary.withValues(alpha: 0.15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                    ),
                  if (onCloudSync != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SizedBox(
                        width: double.infinity,
                        height: 32,
                        child: OutlinedButton.icon(
                          onPressed: isSyncing ? null : onCloudSync,
                          icon: isSyncing
                              ? SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: NexusColors.success),
                                )
                              : Icon(Icons.cloud_upload_rounded, size: 14, color: NexusColors.success),
                          label: Text(
                            isSyncing ? 'Syncing...' : 'Cloud Sync Now',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: NexusColors.success),
                            backgroundColor: NexusColors.success.withValues(alpha: 0.15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),

          Divider(color: NexusColors.sidebarBorder, height: 1),

          // ── 3. Bottom Server Status & Host Info ─────────────────────────
          Padding(
            padding: const EdgeInsets.all(14),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NexusColors.sidebarSecondary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: NexusColors.sidebarBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
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
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                isRunning ? 'ONLINE' : 'STANDBY',
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: isRunning ? NexusColors.success : NexusColors.warning,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${(cpuLoadPercent * 100).toStringAsFixed(0)}% Load',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: NexusColors.sidebarText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () {
                      final endpoint = '$serverIp:$port';
                      Clipboard.setData(ClipboardData(text: endpoint));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Endpoint $endpoint copied'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: NexusColors.sidebarBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.dns_rounded, size: 12, color: NexusColors.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '$serverIp:$port',
                              style: GoogleFonts.firaCode(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: NexusColors.sidebarTextActive,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(Icons.copy_rounded, size: 11, color: NexusColors.sidebarText),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Power Button
                  SizedBox(
                    width: double.infinity,
                    height: 32,
                    child: ElevatedButton.icon(
                      onPressed: onToggleServer,
                      icon: Icon(
                        isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        size: 15,
                      ),
                      label: Text(
                        isRunning ? 'Stop Server' : 'Launch Server',
                        style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isRunning ? NexusColors.error : NexusColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: const Color(0xFF4B5565),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    String label,
    IconData icon, {
    int? counter,
  }) {
    final isSelected = selectedIndex == index;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: InkWell(
        onTap: () => onSelectTab(index),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: isSelected ? NexusColors.sidebarActiveBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              // Active Indicator Line
              Container(
                width: 3,
                height: 20,
                decoration: BoxDecoration(
                  color: isSelected ? NexusColors.sidebarActiveLine : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(2)),
                ),
              ),
              const SizedBox(width: 9),
              Icon(
                icon,
                size: 17,
                color: isSelected ? NexusColors.sidebarTextActive : NexusColors.sidebarText,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? NexusColors.sidebarTextActive : NexusColors.sidebarText,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (counter != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSelected ? NexusColors.primary : NexusColors.sidebarSecondary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    counter.toString(),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? Colors.white : NexusColors.sidebarText,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
