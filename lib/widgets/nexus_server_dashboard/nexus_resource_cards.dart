import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'nexus_colors.dart';

class NexusResourceAllocationCards extends StatelessWidget {
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
  final int activeNodesCount;

  const NexusResourceAllocationCards({
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
    required this.activeNodesCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.cardBorder, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'System Resources',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textMain,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Host hardware & LAN telemetry',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: NexusColors.mainBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: NexusColors.cardBorder),
                  ),
                  child: Text(
                    diskDrive.isNotEmpty ? 'Host $diskDrive' : 'Host PC',
                    style: GoogleFonts.inter(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: NexusColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: NexusColors.cardBorder, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              children: [
                _buildRow(
                  title: 'CPU',
                  accentColor: NexusColors.cpuAccent,
                  icon: Icons.memory_rounded,
                  valueText: cpuKnown ? '${(cpuPercent * 100).toStringAsFixed(0)}%' : 'Measuring…',
                  percentage: cpuKnown ? cpuPercent : 0.0,
                  secondaryText: cpuKnown ? '$cpuStatus load' : 'Querying host telemetry…',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Divider(color: NexusColors.cardBorder.withValues(alpha: 0.7), height: 1),
                ),
                _buildRow(
                  title: 'RAM',
                  accentColor: NexusColors.ramAccent,
                  icon: Icons.storage_rounded,
                  valueText: ramKnown ? '${(ramPercent * 100).toStringAsFixed(0)}%' : '${appProcessRamMb.toStringAsFixed(0)} MB',
                  percentage: ramKnown ? ramPercent : 0.2,
                  secondaryText: ramKnown
                      ? '${usedRamGb.toStringAsFixed(1)} GB of ${totalRamGb.toStringAsFixed(1)} GB used'
                      : 'App process memory footprint',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Divider(color: NexusColors.cardBorder.withValues(alpha: 0.7), height: 1),
                ),
                _buildRow(
                  title: 'Disk',
                  accentColor: NexusColors.diskAccent,
                  icon: Icons.album_rounded,
                  valueText: diskKnown ? '${(diskPercent * 100).toStringAsFixed(0)}%' : 'Available',
                  percentage: diskKnown ? diskPercent : 0.45,
                  secondaryText: diskKnown
                      ? '${usedDiskGb.toStringAsFixed(0)} GB / ${totalDiskGb.toStringAsFixed(0)} GB (${diskDrive.isNotEmpty ? diskDrive : "C:"})'
                      : 'Host storage available',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Divider(color: NexusColors.cardBorder.withValues(alpha: 0.7), height: 1),
                ),
                _buildRow(
                  title: 'Network',
                  accentColor: NexusColors.networkAccent,
                  icon: Icons.wifi_tethering_rounded,
                  valueText: lanThroughput.isNotEmpty ? lanThroughput : 'Active',
                  percentage: (activeNodesCount / 10).clamp(0.1, 1.0),
                  secondaryText: '$activeNodesCount active nodes • Port 53281',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow({
    required String title,
    required Color accentColor,
    required IconData icon,
    required String valueText,
    required double percentage,
    required String secondaryText,
  }) {
    final clamped = percentage.clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 13.5, color: accentColor),
            ),
            const SizedBox(width: 9),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: NexusColors.textMain,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                secondaryText,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: NexusColors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              valueText,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: NexusColors.textMain,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 6,
            color: NexusColors.mainBg,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: clamped,
              child: Container(
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
