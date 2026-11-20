import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';
import 'nexus_metric_card.dart';
import 'nexus_performance_chart.dart';
import 'nexus_resource_cards.dart';
import 'nexus_devices_table.dart';
import 'nexus_activity_stream.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Overview Dashboard View
// ─────────────────────────────────────────────────────────────────────────────
class NexusOverviewView extends StatelessWidget {
  final int totalDevices;
  final int onlineDevices;
  final int activeUsers;
  final String branchDisplay;

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
  final List<NexusTelemetryPoint> telemetryHistory;
  final List<NexusDeviceItem> devices;
  final List<String> rawLogs;

  final VoidCallback? onRefresh;
  final VoidCallback? onViewAllDevices;
  final VoidCallback? onViewAllLogs;

  final bool firewallMissing;
  final VoidCallback? onFixFirewall;
  final VoidCallback? onTriggerCatchUp;
  final VoidCallback? onRepairDatabase;
  final VoidCallback? onStressTest;
  final VoidCallback? onOpenQueueDialog;
  final int queuedSyncCount;

  const NexusOverviewView({
    super.key,
    required this.totalDevices,
    required this.onlineDevices,
    required this.activeUsers,
    required this.branchDisplay,
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
    required this.telemetryHistory,
    required this.devices,
    required this.rawLogs,
    this.onRefresh,
    this.onViewAllDevices,
    this.onViewAllLogs,
    this.firewallMissing = false,
    this.onFixFirewall,
    this.onTriggerCatchUp,
    this.onRepairDatabase,
    this.onStressTest,
    this.onOpenQueueDialog,
    this.queuedSyncCount = 0,
  });

  (String, String) _splitLanMetric(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return ('Active', 'Local LAN gateway • Port 53281');
    for (final sep in ['·', '•', ' - ']) {
      if (trimmed.contains(sep)) {
        final parts = trimmed.split(sep).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.length >= 2) {
          return (parts.first, '${parts.sublist(1).join(' · ')} • Port 53281');
        }
      }
    }
    return (trimmed, 'Local LAN gateway • Port 53281');
  }

  @override
  Widget build(BuildContext context) {
    final (lanPrimary, lanSecondary) = _splitLanMetric(lanThroughput);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Page Header + Compact Maintenance Actions ──────────────────
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Server Overview',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: NexusColors.textMain,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: NexusColors.successMuted,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: NexusColors.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Live',
                              style: GoogleFonts.inter(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: NexusColors.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Monitor infrastructure health, connected desks, and cloud sync in real time.',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w400,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ],
              ),

              // Compact Maintenance Tools (non-duplicated with top bar)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onRepairDatabase != null)
                    _CompactToolButton(
                      icon: Icons.healing_rounded,
                      label: 'Repair & Deduplicate',
                      iconColor: NexusColors.success,
                      onTap: onRepairDatabase,
                    ),
                  if (onStressTest != null)
                    _CompactToolButton(
                      icon: Icons.bolt_rounded,
                      label: 'Benchmark',
                      iconColor: NexusColors.warning,
                      onTap: onStressTest,
                    ),
                  if (onOpenQueueDialog != null)
                    _CompactToolButton(
                      icon: Icons.format_list_bulleted_rounded,
                      label: queuedSyncCount > 0 ? 'Outbox ($queuedSyncCount)' : 'Outbox',
                      iconColor: queuedSyncCount > 0 ? NexusColors.warning : NexusColors.primary,
                      highlighted: queuedSyncCount > 0,
                      onTap: onOpenQueueDialog,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── Critical Operational Alert: Firewall Missing Rule ─────────
          if (firewallMissing) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: NexusColors.warningMuted,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexusColors.warningBorder),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: NexusColors.warning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.shield_outlined, color: NexusColors.warning, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Windows Firewall is blocking port 53281',
                          style: GoogleFonts.inter(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: NexusColors.textMain,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Other PCs on this network cannot connect until the port is allowed. '
                          'Click the button and choose "Yes" on the Windows permission prompt.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: onFixFirewall,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
                    label: Text(
                      'Fix Firewall',
                      style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NexusColors.warning,
                      foregroundColor: NexusColors.onWarning,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── 4 Overview Metric Cards (Zero duplication with telemetry below) ──
          LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = constraints.maxWidth >= 900;
              final isTablet = constraints.maxWidth >= 550 && !isDesktop;

              final cards = [
                NexusMetricCard(
                  label: 'Connected Devices',
                  value: totalDevices.toString(),
                  subtext: '$onlineDevices online on local LAN',
                  icon: Icons.devices_rounded,
                  iconColor: NexusColors.primary,
                  iconBgColor: NexusColors.primaryMuted,
                  trendText: onlineDevices > 0 ? '$onlineDevices active' : null,
                  isTrendPositive: onlineDevices > 0,
                  onTap: onViewAllDevices,
                ),
                NexusMetricCard(
                  label: 'Active Users',
                  value: activeUsers.toString(),
                  subtext: 'Staff logged in across $branchDisplay',
                  icon: Icons.people_outline_rounded,
                  iconColor: NexusColors.success,
                  iconBgColor: NexusColors.successMuted,
                ),
                NexusMetricCard(
                  label: 'Sync Outbox',
                  value: queuedSyncCount.toString(),
                  subtext: queuedSyncCount > 0
                      ? 'Pending records waiting for cloud sync'
                      : 'All records synced to cloud',
                  icon: queuedSyncCount > 0 ? Icons.pending_actions_rounded : Icons.cloud_done_rounded,
                  iconColor: queuedSyncCount > 0 ? NexusColors.warning : NexusColors.success,
                  iconBgColor: queuedSyncCount > 0 ? NexusColors.warningMuted : NexusColors.successMuted,
                  trendText: queuedSyncCount > 0 ? 'Inspect' : 'Up to date',
                  isTrendPositive: queuedSyncCount == 0,
                  highlightAccent: queuedSyncCount > 0,
                  onTap: onOpenQueueDialog,
                ),
                NexusMetricCard(
                  label: 'LAN Throughput',
                  value: lanPrimary,
                  subtext: lanSecondary,
                  icon: Icons.wifi_tethering_rounded,
                  iconColor: NexusColors.networkAccent,
                  iconBgColor: NexusColors.networkAccent.withValues(alpha: 0.12),
                ),
              ];

              if (isDesktop) {
                return Row(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 14),
                      Expanded(child: cards[i]),
                    ],
                  ],
                );
              } else if (isTablet) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[1]),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: cards[2]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[3]),
                      ],
                    ),
                  ],
                );
              } else {
                return Column(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      cards[i],
                    ],
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 16),

          // ── Two Column: Server Performance (Left) + System Resources (Right)
          LayoutBuilder(
            builder: (context, constraints) {
              final isTwoColumn = constraints.maxWidth >= 900;

              final leftChart = NexusPerformanceChart(
                telemetryHistory: telemetryHistory,
                currentCpu: cpuPercent,
                currentRam: ramPercent,
              );

              final rightCards = NexusResourceAllocationCards(
                cpuPercent: cpuPercent,
                cpuKnown: cpuKnown,
                cpuStatus: cpuStatus,
                ramPercent: ramPercent,
                ramKnown: ramKnown,
                usedRamGb: usedRamGb,
                totalRamGb: totalRamGb,
                appProcessRamMb: appProcessRamMb,
                diskPercent: diskPercent,
                diskKnown: diskKnown,
                usedDiskGb: usedDiskGb,
                totalDiskGb: totalDiskGb,
                diskDrive: diskDrive,
                lanThroughput: lanThroughput,
                activeNodesCount: totalDevices,
              );

              if (isTwoColumn) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: leftChart),
                    const SizedBox(width: 16),
                    Expanded(flex: 3, child: rightCards),
                  ],
                );
              } else {
                return Column(
                  children: [
                    leftChart,
                    const SizedBox(height: 16),
                    rightCards,
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 16),

          // ── Connected Devices Section ──────────────────────────────────
          NexusDevicesTable(
            devices: devices,
            onViewAll: onViewAllDevices,
          ),
          const SizedBox(height: 16),

          // ── System Activity and Logs Preview ───────────────────────────
          NexusActivityStream(
            rawLogs: rawLogs,
            onViewAllLogs: onViewAllLogs,
            maxItems: 6,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _CompactToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final bool highlighted;
  final VoidCallback? onTap;

  const _CompactToolButton({
    required this.icon,
    required this.label,
    required this.iconColor,
    this.highlighted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: highlighted ? iconColor.withValues(alpha: 0.09) : NexusColors.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: highlighted ? iconColor.withValues(alpha: 0.35) : NexusColors.cardBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: highlighted ? iconColor : NexusColors.textMain,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Connected Devices View (Tab 2)
// ─────────────────────────────────────────────────────────────────────────────
class NexusDevicesView extends StatefulWidget {
  final List<NexusDeviceItem> devices;
  final Widget hardwareStatusWidget;

  const NexusDevicesView({
    super.key,
    required this.devices,
    required this.hardwareStatusWidget,
  });

  @override
  State<NexusDevicesView> createState() => _NexusDevicesViewState();
}

class _NexusDevicesViewState extends State<NexusDevicesView> {
  String _search = '';
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.devices.where((d) {
      if (_filter == 'Online' && DateTime.now().difference(d.lastActive).inMinutes >= 2) return false;
      if (_filter == 'Idle' && (DateTime.now().difference(d.lastActive).inMinutes < 2 || DateTime.now().difference(d.lastActive).inMinutes >= 10)) return false;
      if (_filter == 'Offline' && DateTime.now().difference(d.lastActive).inMinutes < 10) return false;

      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        return d.name.toLowerCase().contains(q) ||
            d.ipAddress.contains(q) ||
            d.role.toLowerCase().contains(q) ||
            d.osName.toLowerCase().contains(q);
      }
      return true;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Text(
            'Connected Devices',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: NexusColors.textMain,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Manage all LAN nodes, workstations, and local network peripherals.',
            style: GoogleFonts.inter(fontSize: 12.5, color: NexusColors.textSecondary),
          ),
          const SizedBox(height: 16),

          // Search & Filter Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textMain),
                    decoration: InputDecoration(
                      hintText: 'Search by device name, IP address, or role…',
                      hintStyle: GoogleFonts.inter(fontSize: 12.5, color: NexusColors.textSecondary),
                      prefixIcon: Icon(Icons.search_rounded, size: 17, color: NexusColors.textSecondary),
                      prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: ['All', 'Online', 'Idle', 'Offline'].map((f) {
                    return _NexusFilterPill(
                      label: f,
                      selected: f == _filter,
                      onTap: () => setState(() => _filter = f),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Main Table
          NexusDevicesTable(devices: filtered),
          const SizedBox(height: 16),

          // Peripheral Hardware Scanner
          widget.hardwareStatusWidget,
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. System Logs View (Tab 7)
// ─────────────────────────────────────────────────────────────────────────────
class NexusLogsView extends StatefulWidget {
  final List<String> rawLogs;
  final VoidCallback? onClearLogs;

  const NexusLogsView({
    super.key,
    required this.rawLogs,
    this.onClearLogs,
  });

  @override
  State<NexusLogsView> createState() => _NexusLogsViewState();
}

class _NexusLogsViewState extends State<NexusLogsView> {
  String _search = '';
  NexusLogSeverity? _severityFilter;

  @override
  Widget build(BuildContext context) {
    final parsed = widget.rawLogs.reversed.toList().asMap().entries.map((entry) {
      return NexusParsedLog.fromRawString(entry.value, entry.key);
    }).where((log) {
      if (_severityFilter != null && log.severity != _severityFilter) return false;
      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        return log.detail.toLowerCase().contains(q) || log.title.toLowerCase().contains(q);
      }
      return true;
    }).toList();

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
                    'System Logs',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: NexusColors.textMain,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Inspect, search, and audit all live server transactions and events.',
                    style: GoogleFonts.inter(fontSize: 12.5, color: NexusColors.textSecondary),
                  ),
                ],
              ),
              Row(
                children: [
                  _CompactToolButton(
                    icon: Icons.copy_rounded,
                    label: 'Export Logs',
                    iconColor: NexusColors.primary,
                    onTap: () {
                      final allText = widget.rawLogs.join('\n');
                      Clipboard.setData(ClipboardData(text: allText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('All logs copied to clipboard'), duration: Duration(seconds: 2)),
                      );
                    },
                  ),
                  if (widget.onClearLogs != null) ...[
                    const SizedBox(width: 8),
                    _CompactToolButton(
                      icon: Icons.clear_all_rounded,
                      label: 'Clear',
                      iconColor: NexusColors.error,
                      onTap: widget.onClearLogs,
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Search & Filter Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textMain),
                    decoration: InputDecoration(
                      hintText: 'Search logs by keywords, serial, IP, or event type…',
                      hintStyle: GoogleFonts.inter(fontSize: 12.5, color: NexusColors.textSecondary),
                      prefixIcon: Icon(Icons.search_rounded, size: 17, color: NexusColors.textSecondary),
                      prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: [
                    _NexusFilterPill(label: 'All', selected: _severityFilter == null, onTap: () => setState(() => _severityFilter = null)),
                    _NexusFilterPill(label: 'INFO', selected: _severityFilter == NexusLogSeverity.info, onTap: () => setState(() => _severityFilter = NexusLogSeverity.info)),
                    _NexusFilterPill(label: 'SYSTEM', selected: _severityFilter == NexusLogSeverity.system, onTap: () => setState(() => _severityFilter = NexusLogSeverity.system)),
                    _NexusFilterPill(label: 'WARN', selected: _severityFilter == NexusLogSeverity.warn, onTap: () => setState(() => _severityFilter = NexusLogSeverity.warn)),
                    _NexusFilterPill(label: 'ERROR', selected: _severityFilter == NexusLogSeverity.error, onTap: () => setState(() => _severityFilter = NexusLogSeverity.error)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Logs Table Card
          Container(
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
            ),
            child: parsed.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text('No log entries match your filter', style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary)),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: parsed.length,
                    separatorBuilder: (context, i) => Divider(
                      color: NexusColors.cardBorder.withValues(alpha: 0.7),
                      height: 1,
                      indent: 18,
                      endIndent: 18,
                    ),
                    itemBuilder: (context, i) {
                      final log = parsed[i];
                      final (badgeBg, badgeColor, badgeLabel) = switch (log.severity) {
                        NexusLogSeverity.system => (NexusColors.successMuted, NexusColors.success, 'SYSTEM'),
                        NexusLogSeverity.warn => (NexusColors.warningMuted, NexusColors.warning, 'WARN'),
                        NexusLogSeverity.error => (NexusColors.errorMuted, NexusColors.error, 'ERROR'),
                        NexusLogSeverity.info => (NexusColors.primaryMuted, NexusColors.primary, 'INFO'),
                      };

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 58,
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(5)),
                                child: Text(
                                  badgeLabel,
                                  style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: badgeColor),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                log.detail,
                                style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w500, color: NexusColors.textMain),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              log.timestamp,
                              style: GoogleFonts.firaCode(fontSize: 11, color: NexusColors.textSecondary),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _NexusFilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NexusFilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? NexusColors.primary : NexusColors.mainBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? NexusColors.primary : NexusColors.cardBorder,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? NexusColors.onPrimary : NexusColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
