import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'nexus_colors.dart';

class NexusDeviceItem {
  final String id;
  final String name;
  final String role;
  final String ipAddress;
  final String osName;
  final String appVersion;
  final DateTime lastActive;
  final int messagesCount;

  const NexusDeviceItem({
    required this.id,
    required this.name,
    required this.role,
    required this.ipAddress,
    required this.osName,
    required this.appVersion,
    required this.lastActive,
    this.messagesCount = 0,
  });
}

class NexusDevicesTable extends StatelessWidget {
  final List<NexusDeviceItem> devices;
  final VoidCallback? onViewAll;
  final void Function(NexusDeviceItem device)? onPingDevice;
  final void Function(NexusDeviceItem device)? onDisconnectDevice;

  const NexusDevicesTable({
    super.key,
    required this.devices,
    this.onViewAll,
    this.onPingDevice,
    this.onDisconnectDevice,
  });

  static String _formatAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 15) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('HH:mm').format(t);
  }

  static (Color, String) _statusInfo(DateTime lastActive) {
    final diff = DateTime.now().difference(lastActive);
    if (diff.inMinutes < 2) {
      return (NexusColors.success, 'Online');
    } else if (diff.inMinutes < 10) {
      return (NexusColors.warning, 'Idle');
    } else {
      return (NexusColors.error, 'Offline');
    }
  }

  IconData _deviceIcon(String os, String role) {
    final r = role.toLowerCase();
    final o = os.toLowerCase();
    if (o.contains('android') || o.contains('apk') || r.contains('mobile')) {
      return Icons.smartphone_rounded;
    }
    if (r.contains('doctor') || r.contains('reception')) {
      return Icons.desktop_windows_rounded;
    }
    if (r.contains('printer')) {
      return Icons.print_rounded;
    }
    return Icons.laptop_windows_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
          // Table Card Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'Connected Infrastructure Nodes',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NexusColors.textMain,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: NexusColors.mutedBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${devices.length} Active',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: NexusColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (onViewAll != null)
                  InkWell(
                    onTap: onViewAll,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            'View All Nodes',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: NexusColors.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward_rounded, size: 13, color: NexusColors.primary),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(color: NexusColors.cardBorder, height: 1),

          // Devices Table Content
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: NexusColors.mainBg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.devices_other_rounded, size: 20, color: NexusColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No client devices connected',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: NexusColors.textMain,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Workstations will appear here once they connect to this LAN server',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: NexusColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 700),
                child: DataTable(
                  horizontalMargin: 20,
                  columnSpacing: 24,
                  headingRowHeight: 38,
                  dataRowMinHeight: 48,
                  dataRowMaxHeight: 52,
                  headingTextStyle: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: NexusColors.textSecondary,
                  ),
                  dataTextStyle: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: NexusColors.textMain,
                  ),
                  columns: const [
                    DataColumn(label: Text('NODE / DEVICE')),
                    DataColumn(label: Text('ROLE / DESK')),
                    DataColumn(label: Text('IP ADDRESS')),
                    DataColumn(label: Text('STATUS')),
                    DataColumn(label: Text('LAST ACTIVE')),
                  ],
                  rows: devices.map((d) {
                    final (statusColor, statusLabel) = _statusInfo(d.lastActive);
                    final icon = _deviceIcon(d.osName, d.role);

                    return DataRow(
                      cells: [
                        // Device Name & OS
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: NexusColors.mainBg,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Icon(icon, size: 15, color: NexusColors.textMain),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    d.name,
                                    style: GoogleFonts.inter(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: NexusColors.textMain,
                                    ),
                                  ),
                                  Text(
                                    d.osName.isNotEmpty ? d.osName : 'Native App',
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: NexusColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Role
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: NexusColors.mutedBg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              d.role.toUpperCase(),
                              style: GoogleFonts.inter(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: NexusColors.primary,
                              ),
                            ),
                          ),
                        ),
                        // IP Address
                        DataCell(
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: d.ipAddress));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('IP ${d.ipAddress} copied'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    d.ipAddress,
                                    style: GoogleFonts.firaCode(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: NexusColors.textMain,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(Icons.copy_rounded, size: 11, color: NexusColors.textSecondary),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Status
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                statusLabel,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: statusColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Last Active
                        DataCell(
                          Text(
                            _formatAgo(d.lastActive),
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: NexusColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

