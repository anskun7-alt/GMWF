// lib/widgets/server_overview_panel.dart
//
// Calm, honest overview for the server dashboard:
//   1. one overall health state with the reason and a single action,
//   2. three numbers that matter (clients, uptime/last sync, items waiting for the cloud),
//   3. connected devices,
//   4. alerts, most urgent first, each with one fix button.
//
// It only receives plain values and callbacks, so it can be reused and tested in isolation.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'nexus_server_dashboard/nexus_colors.dart';

class ServerClientRow {
  final String name;
  final String role;
  final String ip;
  final DateTime lastActive;
  final int messages;
  const ServerClientRow({
    required this.name,
    required this.role,
    required this.ip,
    required this.lastActive,
    required this.messages,
  });
}

enum ServerHealth { healthy, attention, down }

class ServerAlert {
  final bool critical;
  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  const ServerAlert({
    required this.critical,
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });
}

class ServerOverviewPanel extends StatelessWidget {
  final bool isDark;
  final bool isRunning;
  final bool hasInternet;
  final String branchName;
  final String address;
  final DateTime? startedAt;
  final DateTime? lastCloudSync;
  final int queueSize;
  final List<ServerClientRow> clients;
  final String lanNote;
  final Map<String, int> roleCounts;
  final VoidCallback? onViewAll;
  final List<String> otherServers;
  final bool firewallMissing;
  final bool isSyncing;
  final VoidCallback onRetrySync;
  final VoidCallback onCopyAddress;
  final VoidCallback onFixFirewall;
  final VoidCallback? onOpenQueue;

  const ServerOverviewPanel({
    super.key,
    required this.isDark,
    required this.isRunning,
    required this.hasInternet,
    required this.branchName,
    required this.address,
    required this.startedAt,
    required this.lastCloudSync,
    required this.queueSize,
    required this.clients,
    this.lanNote = '',
    this.roleCounts = const {},
    this.onViewAll,
    required this.otherServers,
    required this.firewallMissing,
    required this.isSyncing,
    required this.onRetrySync,
    required this.onCopyAddress,
    required this.onFixFirewall,
    this.onOpenQueue,
  });

  // ── palette (NEXUS.CORE design tokens) ──────────────────────────────────
  Color get _surface => NexusColors.cardBg;
  Color get _subtle => NexusColors.mainBg;
  Color get _line => NexusColors.cardBorder;
  Color get _text => NexusColors.textMain;
  Color get _muted => NexusColors.textSecondary;
  static Color get _accent => NexusColors.primary;
  static Color get _ok => NexusColors.success;
  static Color get _warn => NexusColors.warning;
  static Color get _bad => NexusColors.error;

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 10) return 'just now';
    if (d.inSeconds < 60) return '${d.inSeconds} s ago';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return DateFormat('d MMM, HH:mm').format(t);
  }

  static String _uptime(DateTime? t) {
    if (t == null) return '—';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} h ${d.inMinutes % 60} min';
    return '${d.inDays} d ${d.inHours % 24} h';
  }

  /// Cloud sync is "stalled" when items are waiting and nothing has uploaded recently.
  bool get _cloudStalled {
    if (queueSize == 0) return false;
    final last = lastCloudSync;
    if (last == null) return true;
    return DateTime.now().difference(last).inMinutes >= 10;
  }

  List<ServerAlert> _alerts() {
    final list = <ServerAlert>[];
    if (otherServers.isNotEmpty) {
      list.add(ServerAlert(
        critical: true,
        icon: Icons.warning_amber_rounded,
        title: 'Another server is on this network',
        detail: '${otherServers.join(", ")} is also acting as a server. Devices may connect to the wrong one '
            'and tokens would not reach each other.',
      ));
    }
    if (!hasInternet && queueSize > 0) {
      list.add(ServerAlert(
        critical: false,
        icon: Icons.cloud_off_rounded,
        title: 'No internet connection',
        detail: '$queueSize items are saved here and will upload when the connection returns.',
      ));
    } else if (_cloudStalled) {
      list.add(ServerAlert(
        critical: false,
        icon: Icons.cloud_off_rounded,
        title: 'Cloud uploads are not completing',
        detail: '$queueSize items saved locally. '
            '${lastCloudSync == null ? "Nothing has uploaded since this server started." : "Last upload ${_ago(lastCloudSync!)}."}',
        actionLabel: 'Retry now',
        onAction: onRetrySync,
      ));
    }
    if (firewallMissing) {
      list.add(ServerAlert(
        critical: false,
        icon: Icons.shield_outlined,
        title: 'Firewall rules may be missing',
        detail: 'Ports 53281 (devices), 8088 and 4370 (fingerprint scanners) need to be open.',
        actionLabel: 'Fix automatically',
        onAction: onFixFirewall,
      ));
    }
    return list;
  }

  ServerHealth _health(List<ServerAlert> alerts) {
    if (!isRunning) return ServerHealth.down;
    if (alerts.isNotEmpty) return ServerHealth.attention;
    return ServerHealth.healthy;
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts();
    final health = _health(alerts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusBar(health, alerts),
        const SizedBox(height: 12),
        _keyNumbers(),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 860;
          final devices = _devicesCard();
          final alertCard = _alertsCard(alerts);
          if (!wide) {
            return Column(children: [devices, const SizedBox(height: 12), alertCard]);
          }
          // Same height for both cards, so there is no empty gap beside the shorter one.
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: devices),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: alertCard),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _line),
        ),
        child: child,
      );

  Widget _statusBar(ServerHealth health, List<ServerAlert> alerts) {
    final (Color c, String title, String sub) = switch (health) {
      ServerHealth.healthy => (_ok, 'Healthy', '$branchName server is running normally.'),
      ServerHealth.attention => (
          _warn,
          'Needs attention',
          alerts.first.title,
        ),
      ServerHealth.down => (_bad, 'Server stopped', 'Devices cannot connect until the server is started.'),
    };
    return _card(
      child: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 13, color: _muted)),
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onCopyAddress,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(color: _subtle, borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(address,
                      style: TextStyle(fontSize: 12.5, fontFamily: 'monospace', color: _text)),
                  const SizedBox(width: 8),
                  Icon(Icons.copy_rounded, size: 14, color: _muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyNumbers() {
    Widget tile(String label, String value, String note, {Color? color, VoidCallback? onTap}) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12.5, color: _muted)),
                const SizedBox(height: 6),
                Text(value,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: color ?? _text)),
                const SizedBox(height: 2),
                Text(note, style: TextStyle(fontSize: 12, color: _muted)),
              ],
            ),
          ),
        ),
      );
    }

    final online = clients.where((c) => DateTime.now().difference(c.lastActive).inSeconds < 90).length;
    return Row(
      children: [
        tile('Devices connected', '$online',
            lanNote.isNotEmpty
                ? lanNote
                : (clients.isEmpty ? 'Waiting for devices to connect' : '${clients.length} seen since start')),
        const SizedBox(width: 12),
        tile('Running for', _uptime(startedAt),
            lastCloudSync == null ? 'No cloud upload yet' : 'Last upload ${_ago(lastCloudSync!)}'),
        const SizedBox(width: 12),
        tile('Waiting for cloud', '$queueSize',
            queueSize == 0 ? 'Everything is uploaded' : (hasInternet ? 'Tap to review' : 'Offline — will upload later'),
            color: queueSize == 0 ? _ok : (_cloudStalled ? _warn : _text),
            onTap: onOpenQueue),
      ],
    );
  }

  Widget _devicesCard() {
    final sorted = [...clients]..sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Connected devices', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 10),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'No devices yet. Receptionist, doctor and dispenser PCs on this network connect automatically.',
                style: TextStyle(fontSize: 13, color: _muted, height: 1.4),
              ),
            )
          else ...[
            Row(children: [
              _hdr('Device', 3),
              _hdr('Role', 2),
              _hdr('Address', 2),
              _hdr('Last seen', 2),
              _hdr('Status', 1),
            ]),
            Divider(height: 14, color: _line),
            for (final c in sorted) _clientRow(c),
            if (roleCounts.values.any((v) => v > 0)) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e in roleCounts.entries.where((e) => e.value > 0))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(color: _subtle, borderRadius: BorderRadius.circular(10)),
                            child: Text('${e.key} ${e.value}',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _text)),
                          ),
                      ],
                    ),
                  ),
                  if (onViewAll != null)
                    TextButton(
                      onPressed: onViewAll,
                      style: TextButton.styleFrom(foregroundColor: _accent, minimumSize: const Size(0, 28)),
                      child: const Text('View all', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _hdr(String t, int flex) => Expanded(
        flex: flex,
        child: Text(t, style: TextStyle(fontSize: 11.5, color: _muted)),
      );

  Widget _clientRow(ServerClientRow c) {
    final live = DateTime.now().difference(c.lastActive).inSeconds < 90;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Text(c.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _text))),
          Expanded(
              flex: 2,
              child: Text(c.role, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: _muted))),
          Expanded(
              flex: 2,
              child: Text(c.ip,
                  style: TextStyle(fontSize: 12.5, fontFamily: 'monospace', color: _muted))),
          Expanded(flex: 2, child: Text(_ago(c.lastActive), style: TextStyle(fontSize: 13, color: _muted))),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (live ? _ok : _muted).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(live ? 'Online' : 'Idle',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: live ? _ok : _muted)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _alertsCard(List<ServerAlert> alerts) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Alerts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 10),
          if (alerts.isEmpty)
            Row(children: [
              Icon(Icons.check_circle_outline_rounded, size: 18, color: _ok),
              const SizedBox(width: 8),
              Text('Nothing needs your attention.', style: TextStyle(fontSize: 13, color: _muted)),
            ])
          else
            for (final a in alerts)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(a.icon, size: 18, color: a.critical ? _bad : _warn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                          const SizedBox(height: 2),
                          Text(a.detail, style: TextStyle(fontSize: 12.5, color: _muted, height: 1.35)),
                          if (a.actionLabel != null) ...[
                            const SizedBox(height: 6),
                            TextButton(
                              onPressed: a.onAction,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 28),
                                foregroundColor: _accent,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(a.actionLabel!,
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
