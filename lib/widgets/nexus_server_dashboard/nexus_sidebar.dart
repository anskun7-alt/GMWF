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
  /// Kept optional for backwards-compatibility; sync actions now live in the top header.
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
      width: 244,
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
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: NexusColors.sidebarSecondary,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: NexusColors.sidebarBorder),
                  ),
                  child: Image.asset(
                    'assets/logo/gmwf-1.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.dns_rounded,
                      color: NexusColors.primary,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GMWF SERVER',
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: NexusColors.sidebarTextActive,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'CONTROL CENTER',
                        style: GoogleFonts.inter(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.9,
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              children: [
                _buildSectionHeader('WORKSPACE'),
                _buildNavItem(0, 'Overview', Icons.dashboard_outlined),
                _buildNavItem(1, 'Department Activity', Icons.domain_rounded),
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

                const SizedBox(height: 14),
                _buildSectionHeader('ENGINES & HARDWARE'),
                _buildNavItem(4, 'Biometric Devices', Icons.fingerprint_rounded),
                _buildNavItem(5, 'Python Sync Engine', Icons.terminal_rounded),

                const SizedBox(height: 14),
                _buildSectionHeader('OBSERVABILITY'),
                _buildNavItem(6, 'Resource Monitoring', Icons.analytics_outlined),
                _buildNavItem(
                  7,
                  'System Logs',
                  Icons.receipt_long_outlined,
                  counter: pendingEventsCount > 0 ? pendingEventsCount : null,
                ),
                _buildNavItem(8, 'Network & Interfaces', Icons.wifi_tethering_outlined),

                const SizedBox(height: 14),
                _buildSectionHeader('SYSTEM'),
                _buildNavItem(9, 'Multi-Server Mesh', Icons.hub_rounded),
                _buildNavItem(10, 'Data Vault', Icons.storage_rounded),
                _buildNavItem(11, 'Settings & Firewall', Icons.tune_outlined),
              ],
            ),
          ),

          Divider(color: NexusColors.sidebarBorder, height: 1),

          // ── 3. Bottom Server Status & Host Info ─────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
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
                                isRunning ? 'GATEWAY ONLINE' : 'STANDBY',
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
                        'LAN',
                        style: GoogleFonts.inter(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: NexusColors.sidebarText.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Tooltip(
                    message: 'Click to copy LAN server endpoint',
                    child: InkWell(
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
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: NexusColors.sidebarBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: NexusColors.sidebarBorder.withValues(alpha: 0.7)),
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
                  ),
                  const SizedBox(height: 10),
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
                        foregroundColor: isRunning ? Colors.white : NexusColors.onPrimary,
                        elevation: 0,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
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
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 5),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: NexusColors.sidebarText.withValues(alpha: 0.65),
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: isSelected ? NexusColors.sidebarActiveBg : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Active Indicator Line
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: isSelected ? NexusColors.sidebarActiveLine : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(2)),
                ),
              ),
              const SizedBox(width: 9),
              Icon(
                icon,
                size: 16.5,
                color: isSelected ? NexusColors.sidebarTextActive : NexusColors.sidebarText,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? NexusColors.sidebarTextActive : NexusColors.sidebarText,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (counter != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSelected ? NexusColors.primary : NexusColors.sidebarSecondary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    counter.toString(),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? NexusColors.onPrimary : NexusColors.sidebarText,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
