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
    return Column(
      children: [
        _buildItem(
          title: 'CPU',
          accentColor: NexusColors.cpuAccent,
          icon: Icons.memory_rounded,
          valueText: cpuKnown ? '${(cpuPercent * 100).toStringAsFixed(0)}%' : 'Measuring…',
          percentage: cpuKnown ? cpuPercent : 0.0,
          secondaryText: cpuKnown ? '$cpuStatus load' : 'Querying host telemetry…',
        ),
        const SizedBox(height: 12),
        _buildItem(
          title: 'RAM',
          accentColor: NexusColors.ramAccent,
          icon: Icons.storage_rounded,
          valueText: ramKnown ? '${(ramPercent * 100).toStringAsFixed(0)}%' : '${appProcessRamMb.toStringAsFixed(0)} MB',
          percentage: ramKnown ? ramPercent : 0.2,
          secondaryText: ramKnown
              ? '${usedRamGb.toStringAsFixed(1)} GB of ${totalRamGb.toStringAsFixed(1)} GB used'
              : 'App process memory footprint',
        ),
        const SizedBox(height: 12),
        _buildItem(
          title: 'Disk',
          accentColor: NexusColors.diskAccent,
          icon: Icons.album_rounded,
          valueText: diskKnown ? '${(diskPercent * 100).toStringAsFixed(0)}%' : 'Available',
          percentage: diskKnown ? diskPercent : 0.45,
          secondaryText: diskKnown
              ? '${usedDiskGb.toStringAsFixed(0)} GB / ${totalDiskGb.toStringAsFixed(0)} GB (${diskDrive.isNotEmpty ? diskDrive : "C:"})'
              : 'Host storage available',
        ),
        const SizedBox(height: 12),
        _buildItem(
          title: 'Network',
          accentColor: NexusColors.networkAccent,
          icon: Icons.wifi_tethering_rounded,
          valueText: lanThroughput.isNotEmpty ? lanThroughput : 'Active',
          percentage: (activeNodesCount / 10).clamp(0.1, 1.0),
          secondaryText: '$activeNodesCount active nodes • Port 53281',
        ),
      ],
    );
  }

  Widget _buildItem({
    required String title,
    required Color accentColor,
    required IconData icon,
    required String valueText,
    required double percentage,
    required String secondaryText,
  }) {
    final clamped = percentage.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: NexusColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.cardBorder, width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(icon, size: 15, color: accentColor),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: NexusColors.textMain,
                    ),
                  ),
                ],
              ),
              Text(
                valueText,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: NexusColors.textMain,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Horizontal progress indicator
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Container(
              height: 6,
              color: NexusColors.mainBg,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: clamped,
                child: Container(
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            secondaryText,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: NexusColors.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

