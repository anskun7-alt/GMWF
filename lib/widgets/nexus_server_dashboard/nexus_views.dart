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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Heading & Refresh ──────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Server Overview',
                    style: GoogleFonts.inter(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: NexusColors.textMain,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Monitor your infrastructure, devices and system activity in real time.',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    'Updated live',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: Text(
                      'Refresh',
                      style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NexusColors.textMain,
                      side: BorderSide(color: NexusColors.cardBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Critical Operational Alert: Firewall Missing Rule ─────────
          if (firewallMissing) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: NexusColors.warningMuted,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexusColors.warningBorder),
                boxShadow: const [
                  BoxShadow(color: Color(0x08D97706), blurRadius: 8, offset: Offset(0, 2)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: NexusColors.warning.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.shield_outlined, color: NexusColors.warning, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Windows Firewall is blocking port 53281',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: NexusColors.textMain,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Other PCs on this network cannot connect until the port is allowed. '
                          'Click the button and choose "Yes" on the Windows permission prompt.',
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            color: NexusColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: onFixFirewall,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                    label: Text(
                      'Fix Firewall (Open Port)',
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

          // ── Operational Quick Diagnostics & Actions Ribbon ────────────
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.cardBorder),
              boxShadow: const [
                BoxShadow(color: Color(0x05000000), blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.build_circle_outlined, size: 16, color: NexusColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'System Diagnostics & Quick Actions:',
                      style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: NexusColors.textMain),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onTriggerCatchUp,
                      icon: Icon(Icons.cloud_sync_rounded, size: 14, color: NexusColors.primary),
                      label: Text('Force Cloud Sync', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: NexusColors.cardBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: onRepairDatabase,
                      icon: Icon(Icons.healing_rounded, size: 14, color: NexusColors.success),
                      label: Text('Repair & Deduplicate', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: NexusColors.cardBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: onStressTest,
                      icon: Icon(Icons.bolt_rounded, size: 14, color: NexusColors.warning),
                      label: Text('Pressure Benchmark', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: NexusColors.cardBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                    if (onOpenQueueDialog != null)
                      OutlinedButton.icon(
                        onPressed: onOpenQueueDialog,
                        icon: Icon(Icons.format_list_bulleted_rounded, size: 14, color: NexusColors.primary),
                        label: Text('Inspect Outbox ($queuedSyncCount)', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: NexusColors.textMain)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: NexusColors.cardBorder),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // ── 4 Overview Metric Cards ────────────────────────────────────
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
                  label: 'CPU Utilization',
                  value: cpuKnown ? '${(cpuPercent * 100).toStringAsFixed(0)}%' : 'Measuring…',
                  subtext: cpuKnown ? '$cpuStatus load' : 'Querying hardware telemetry…',
                  icon: Icons.memory_rounded,
                  iconColor: NexusColors.primary,
                  iconBgColor: NexusColors.primaryMuted,
                ),
                NexusMetricCard(
                  label: 'Memory Usage',
                  value: ramKnown ? '${usedRamGb.toStringAsFixed(1)} / ${totalRamGb.toStringAsFixed(1)} GB' : '${appProcessRamMb.toStringAsFixed(0)} MB',
                  subtext: ramKnown ? '${(ramPercent * 100).toStringAsFixed(0)}% utilized' : 'GMWF app footprint',
                  icon: Icons.storage_rounded,
                  iconColor: NexusColors.diskAccent,
                  iconBgColor: NexusColors.primaryMuted,
                ),
              ];

              if (isDesktop) {
                return Row(
                  children: cards.map((c) => Expanded(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: c,
                  ))).toList(),
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
                  children: cards.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: c,
                  )).toList(),
                );
              }
            },
          ),
          const SizedBox(height: 20),

          // ── Two Column: Server Performance (Left) + Resource Allocation (Right)
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
          const SizedBox(height: 20),

          // ── Connected Devices Section ──────────────────────────────────
          NexusDevicesTable(
            devices: devices,
            onViewAll: onViewAllDevices,
          ),
          const SizedBox(height: 20),

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

// ─────────────────────────────────────────────────────────────────────────────
// 2. Connected Devices View (Tab 1)
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected Devices',
                    style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Manage all LAN nodes, workstations, and local network peripherals.',
                    style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Search & Filter Toolbar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(10),
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
                      hintStyle: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
                      prefixIcon: Icon(Icons.search_rounded, size: 18, color: NexusColors.textSecondary),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: ['All', 'Online', 'Idle', 'Offline'].map((f) {
                    final sel = f == _filter;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(f),
                        selected: sel,
                        onSelected: (_) => setState(() => _filter = f),
                        selectedColor: NexusColors.primaryMuted,
                        backgroundColor: NexusColors.mainBg,
                        labelStyle: GoogleFonts.inter(
                          fontSize: 11.5,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                          color: sel ? NexusColors.primary : NexusColors.textSecondary,
                        ),
                        side: BorderSide(color: sel ? NexusColors.primary : NexusColors.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Main Table
          NexusDevicesTable(devices: filtered),
          const SizedBox(height: 20),

          // Peripheral Hardware Scanner
          widget.hardwareStatusWidget,
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. System Logs View (Tab 4)
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
                    style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: NexusColors.textMain),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Inspect, search, and audit all live server transactions and events.',
                    style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
                  ),
                ],
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final allText = widget.rawLogs.join('\n');
                      Clipboard.setData(ClipboardData(text: allText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('All logs copied to clipboard'), duration: Duration(seconds: 2)),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: Text('Export Logs', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NexusColors.textMain,
                      side: BorderSide(color: NexusColors.cardBorder),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  if (widget.onClearLogs != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: widget.onClearLogs,
                      icon: const Icon(Icons.clear_all_rounded, size: 14),
                      label: Text('Clear', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: NexusColors.error,
                        side: BorderSide(color: NexusColors.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Search & Filter Toolbar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NexusColors.cardBg,
              borderRadius: BorderRadius.circular(10),
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
                      hintStyle: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary),
                      prefixIcon: Icon(Icons.search_rounded, size: 18, color: NexusColors.textSecondary),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: [
                    _filterChip('All', null),
                    _filterChip('INFO', NexusLogSeverity.info),
                    _filterChip('SYSTEM', NexusLogSeverity.system),
                    _filterChip('WARN', NexusLogSeverity.warn),
                    _filterChip('ERROR', NexusLogSeverity.error),
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
                    itemCount: parsed.length,
                    separatorBuilder: (context, i) => Divider(color: NexusColors.cardBorder, height: 1),
                    itemBuilder: (context, i) {
                      final log = parsed[i];
                      final (badgeBg, badgeColor, badgeLabel) = switch (log.severity) {
                        NexusLogSeverity.system => (NexusColors.successMuted, NexusColors.success, 'SYSTEM'),
                        NexusLogSeverity.warn => (NexusColors.warningMuted, NexusColors.warning, 'WARN'),
                        NexusLogSeverity.error => (NexusColors.errorMuted, NexusColors.error, 'ERROR'),
                        NexusLogSeverity.info => (NexusColors.primaryMuted, NexusColors.primary, 'INFO'),
                      };

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(5)),
                              child: Text(
                                badgeLabel,
                                style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: badgeColor),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                log.detail,
                                style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w500, color: NexusColors.textMain),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              log.timestamp,
                              style: GoogleFonts.inter(fontSize: 11, color: NexusColors.textSecondary),
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

  Widget _filterChip(String label, NexusLogSeverity? severity) {
    final sel = _severityFilter == severity;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: sel,
        onSelected: (_) => setState(() => _severityFilter = severity),
        selectedColor: NexusColors.primaryMuted,
        backgroundColor: NexusColors.mainBg,
        labelStyle: GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
          color: sel ? NexusColors.primary : NexusColors.textSecondary,
        ),
        side: BorderSide(color: sel ? NexusColors.primary : NexusColors.cardBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}
