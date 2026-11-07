import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';
import 'nexus_devices_table.dart';
import 'server_theme_selector.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 4. Users and Sessions View (Tab 2)
// ─────────────────────────────────────────────────────────────────────────────
class NexusUsersView extends StatelessWidget {
  final List<NexusDeviceItem> devices;
  final Widget departmentActivityWidget;
  final String branchDisplay;

  const NexusUsersView({
    super.key,
    required this.devices,
    required this.departmentActivityWidget,
    required this.branchDisplay,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Users & Sessions',
                    style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Active clinic personnel, departmental queues, and staff sessions in $branchDisplay.',
                    style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Active Staff Sessions Grid
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
              boxShadow: const [BoxShadow(color: Color(0x06000000), blurRadius: 10, offset: Offset(0, 3))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 18, color: NexusColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Authenticated Staff Workstations',
                      style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: NexusColors.textMain),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: NexusColors.mutedBg, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        '${devices.length} Active',
                        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: NexusColors.primary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('No staff sessions logged in yet', style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary)),
                    ),
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: devices.map((d) {
                      return Container(
                        width: 250,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: NexusColors.mainBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: NexusColors.cardBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 14,
                                  backgroundColor: NexusColors.primaryMuted,
                                  child: Text(
                                    d.name.isNotEmpty ? d.name[0].toUpperCase() : 'U',
                                    style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: NexusColors.primary),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        d.name,
                                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: NexusColors.textMain),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        d.role.toUpperCase(),
                                        style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: NexusColors.primary),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Divider(color: NexusColors.cardBorder, height: 1),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('IP Address:', style: GoogleFonts.inter(fontSize: 11, color: NexusColors.textSecondary)),
                                Text(d.ipAddress, style: GoogleFonts.firaCode(fontSize: 11, color: NexusColors.textMain)),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Department Queuing & Dispensing Activity
          departmentActivityWidget,
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Resource Monitoring View (Tab 3)
// ─────────────────────────────────────────────────────────────────────────────
class NexusResourcesView extends StatelessWidget {
  final double cpuPercent;
  final bool cpuKnown;
  final String cpuStatus;

  final double ramPercent;
  final bool ramKnown;
  final double usedRamGb;
  final double totalRamGb;
  final double appProcessRamMb;

  final double diskPercent;
  final bool diskKnown;
  final double usedDiskGb;
  final double totalDiskGb;
  final String diskDrive;

  final String lanThroughput;

  const NexusResourcesView({
    super.key,
    required this.cpuPercent,
    required this.cpuKnown,
    required this.cpuStatus,
    required this.ramPercent,
    required this.ramKnown,
    required this.usedRamGb,
    required this.totalRamGb,
    required this.appProcessRamMb,
    required this.diskPercent,
    required this.diskKnown,
    required this.usedDiskGb,
    required this.totalDiskGb,
    required this.diskDrive,
    required this.lanThroughput,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Resource Monitoring',
            style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
          ),
          const SizedBox(height: 3),
          Text(
            'In-depth hardware metrics, memory allocation, and storage diagnostics.',
            style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
          ),
          const SizedBox(height: 20),

          // Metric Cards Row
          Row(
            children: [
              Expanded(
                child: _buildTelemetryCard(
                  title: 'Processor (CPU)',
                  accentColor: NexusColors.cpuAccent,
                  value: cpuKnown ? '${(cpuPercent * 100).toStringAsFixed(0)}%' : 'Measuring…',
                  subtitle: cpuKnown ? '$cpuStatus load' : 'Querying host…',
                  progress: cpuKnown ? cpuPercent : 0.0,
                  details: [
                    ('Load Status', cpuStatus),
                    ('Hardware Metric', cpuKnown ? 'Measured live' : 'Offline query'),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _buildTelemetryCard(
                  title: 'Memory (RAM)',
                  accentColor: NexusColors.ramAccent,
                  value: ramKnown ? '${usedRamGb.toStringAsFixed(1)} GB' : '${appProcessRamMb.toStringAsFixed(0)} MB',
                  subtitle: ramKnown ? '${totalRamGb.toStringAsFixed(1)} GB Total (${(ramPercent * 100).toStringAsFixed(0)}%)' : 'App RSS footprint',
                  progress: ramKnown ? ramPercent : 0.25,
                  details: [
                    ('Total Physical RAM', ramKnown ? '${totalRamGb.toStringAsFixed(1)} GB' : 'Measuring…'),
                    ('GMWF Process RSS', '${appProcessRamMb.toStringAsFixed(0)} MB'),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _buildTelemetryCard(
                  title: 'Storage (Disk)',
                  accentColor: NexusColors.diskAccent,
                  value: diskKnown ? '${usedDiskGb.toStringAsFixed(0)} GB' : 'Available',
                  subtitle: diskKnown ? '${totalDiskGb.toStringAsFixed(0)} GB Total (${(diskPercent * 100).toStringAsFixed(0)}%)' : 'Host Storage',
                  progress: diskKnown ? diskPercent : 0.4,
                  details: [
                    ('Primary Drive', diskDrive.isNotEmpty ? diskDrive : 'C:'),
                    ('Total Capacity', diskKnown ? '${totalDiskGb.toStringAsFixed(0)} GB' : 'Measuring…'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildTelemetryCard({
    required String title,
    required Color accentColor,
    required String value,
    required String subtitle,
    required double progress,
    required List<(String, String)> details,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.cardBorder),
        boxShadow: const [BoxShadow(color: Color(0x06000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: NexusColors.textMain)),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(value, style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w700, color: NexusColors.textMain)),
          const SizedBox(height: 4),
          Text(subtitle, style: GoogleFonts.inter(fontSize: 12, color: NexusColors.textSecondary)),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Container(
              height: 6,
              color: NexusColors.mainBg,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress.clamp(0.0, 1.0),
                child: Container(color: accentColor),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Divider(color: NexusColors.cardBorder, height: 1),
          const SizedBox(height: 10),
          ...details.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(d.$1, style: GoogleFonts.inter(fontSize: 11.5, color: NexusColors.textSecondary)),
                    Text(d.$2, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Network Monitoring View (Tab 5)
// ─────────────────────────────────────────────────────────────────────────────
class NexusNetworkView extends StatelessWidget {
  final String serverIp;
  final int port;
  final String lanThroughput;
  final int connectedClientsCount;
  final List<String> otherServers;
  final bool firewallMissing;
  final VoidCallback onFixFirewall;

  const NexusNetworkView({
    super.key,
    required this.serverIp,
    required this.port,
    required this.lanThroughput,
    required this.connectedClientsCount,
    required this.otherServers,
    required this.firewallMissing,
    required this.onFixFirewall,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Network & Interfaces',
            style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
          ),
          const SizedBox(height: 3),
          Text(
            'LAN traffic telemetry, firewall port configuration, and multi-server network topology.',
            style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
          ),
          const SizedBox(height: 20),

          // Firewall Alert Banner (if missing)
          if (firewallMissing) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: NexusColors.warningMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: NexusColors.warningBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: NexusColors.warning, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Windows Firewall Inbound Rules Missing', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: NexusColors.textMain)),
                        Text('Ports 53281 (WebSocket) and 8088 / 4370 (ZKTeco Biometrics) need to be permitted.', style: GoogleFonts.inter(fontSize: 12, color: NexusColors.textSecondary)),
                      ],
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: onFixFirewall,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
                    label: Text('Open Ports Automatically', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NexusColors.warning,
                      foregroundColor: NexusColors.onWarning,
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Active Ports & Interfaces Grid
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
              boxShadow: const [BoxShadow(color: Color(0x06000000), blurRadius: 10, offset: Offset(0, 3))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Active Network Services', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: NexusColors.textMain)),
                const SizedBox(height: 16),
                _buildPortRow('LAN Realtime Gateway', '$serverIp:$port', 'TCP / WebSocket', NexusColors.success, 'Serving $connectedClientsCount workstations'),
                Divider(color: NexusColors.cardBorder, height: 24),
                _buildPortRow('ZKTeco Biometric Daemon', '0.0.0.0:8088 / 4370', 'UDP / Push Protocol', NexusColors.primary, 'Listening for attendance punch packets'),
                Divider(color: NexusColors.cardBorder, height: 24),
                _buildPortRow('UDP Server Discovery Beacon', '255.255.255.255:53280', 'UDP Broadcast', NexusColors.success, 'Broadcasting $serverIp every 5s'),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildPortRow(String service, String endpoint, String protocol, Color dotColor, String note) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(service, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
              Text(note, style: GoogleFonts.inter(fontSize: 11.5, color: NexusColors.textSecondary)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: NexusColors.mainBg, borderRadius: BorderRadius.circular(6)),
          child: Text(protocol, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: NexusColors.textSecondary)),
        ),
        const SizedBox(width: 12),
        Text(endpoint, style: GoogleFonts.firaCode(fontSize: 12.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Settings View (Tab 6)
// ─────────────────────────────────────────────────────────────────────────────
class NexusSettingsView extends StatefulWidget {
  final Widget multiServerControl;
  final Widget biometricDeviceManager;
  final Widget pythonTerminal;
  final Widget dataVaultViewer;

  const NexusSettingsView({
    super.key,
    required this.multiServerControl,
    required this.biometricDeviceManager,
    required this.pythonTerminal,
    required this.dataVaultViewer,
  });

  @override
  State<NexusSettingsView> createState() => _NexusSettingsViewState();
}

class _NexusSettingsViewState extends State<NexusSettingsView> {
  int _activeSubTab = 0;
  final List<String> _subTabs = const [
    'Multi-Server Mesh',
    'Biometric Devices',
    'Python Engine',
    'Local Data Vault',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Server Settings & Infrastructure',
            style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
          ),
          const SizedBox(height: 3),
          Text(
            'Configure multi-node replication, biometric timeclocks, python daemons, and database vaults.',
            style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
          ),
          const SizedBox(height: 16),

          // Theme Appearance Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: NexusColors.cardBorder),
            ),
            child: Row(
              children: [
                Icon(Icons.palette_rounded, size: 20, color: NexusColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Visual Appearance & Theme',
                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: NexusColors.textMain),
                      ),
                      Text(
                        'Select between Midnight Plum and Nexus Core in Light/Hybrid or Dark mode.',
                        style: GoogleFonts.inter(fontSize: 11.5, color: NexusColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const ServerThemeSelectorButton(),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Sub-Tab Switcher
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: NexusColors.cardBorder),
            ),
            child: Row(
              children: _subTabs.asMap().entries.map((entry) {
                final idx = entry.key;
                final label = entry.value;
                final isSel = idx == _activeSubTab;

                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _activeSubTab = idx),
                    borderRadius: BorderRadius.circular(7),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: isSel ? NexusColors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Center(
                        child: Text(
                          label,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                            color: isSel ? NexusColors.onPrimary : NexusColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 18),

          // Active Sub-Tab View
          IndexedStack(
            index: _activeSubTab,
            children: [
              widget.multiServerControl,
              widget.biometricDeviceManager,
              widget.pythonTerminal,
              widget.dataVaultViewer,
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

