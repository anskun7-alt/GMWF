// lib/widgets/desk_connection_pill.dart
//
// One connection pill for the desk header (Hybrid, Dispensar, Receptionist…),
// replacing three separate chips (local server, internet, cloud queue) and the
// version chip. Line 1 is the local server, line 2 the cloud. Tapping it opens
// the Connection & sync panel with the details and the repair tools that used
// to sit in the ⋮ menu (force upload, queue doctor, server settings).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../realtime/connection_manager.dart';
import '../realtime/realtime_manager.dart';
import '../services/cloud/cloud_db.dart';
import '../services/hidden_force_uploader.dart';
import '../services/local_storage_service.dart';
import '../services/quota_service.dart';
import 'lan_server_config_dialog.dart';
import 'queue_doctor_dialog.dart';

enum _Tone { good, busy, bad }

/// A snapshot of the desk's connection, recomputed every 2 s and on queue changes.
class _DeskState {
  _DeskState({required this.status, required this.isOnline});

  final ConnectionStatus? status;
  final bool isOnline;

  final rm = RealtimeManager();

  bool get hasLan => status != null;
  bool get lanConnected => rm.isLinkAlive;
  bool get lanSearching => hasLan && !lanConnected && (status!.isSearching || status!.isConnecting);
  int get unsent => rm.unsentCount;
  int get missing => RealtimeManager.unconfirmedTokensNotifier.value;

  int get cloudPending => Hive.isBoxOpen(LocalStorageService.syncBox) ? Hive.box(LocalStorageService.syncBox).length : 0;
  DateTime? get pausedUntil => QuotaService.dailyResetPauseUntil;

  String? get serverAddress {
    final ip = status?.ip ?? rm.serverIp;
    return ip == null ? null : '$ip:${status?.port ?? rm.port}';
  }

  (String, _Tone) get lan {
    if (!hasLan) return ('', _Tone.good);
    if (lanConnected) {
      if (rm.isBehindServer && missing > 0) return ('Catching up ($missing)', _Tone.busy);
      if (unsent > 0) return ('Sending ($unsent)', _Tone.busy);
      return ('Server live', _Tone.good);
    }
    if (lanSearching) {
      final s = status!.isConnecting ? 'Connecting…' : 'Searching…';
      return (unsent > 0 ? '$s $unsent unsent' : s, _Tone.busy);
    }
    if (RealtimeManager.versionRejectedNotifier.value != null) return ('Update required', _Tone.bad);
    return (unsent > 0 ? 'Server offline · $unsent unsent' : 'Server offline', _Tone.bad);
  }

  /// Always starts with the internet state, so staff can see it at a glance.
  (String, _Tone) get cloud {
    final n = cloudPending;
    final net = isOnline ? 'Online' : 'Offline';
    if (!isOnline) return (n > 0 ? '$net · ${_count(n)} to upload' : '$net · no internet', _Tone.bad);
    if (pausedUntil != null) return ('$net · uploads paused · ${_count(n)} waiting', _Tone.bad);
    if (n > 0) return ('$net · ${_count(n)} to upload', _Tone.busy);
    return ('$net · all uploaded', _Tone.good);
  }

  _Tone get worst {
    final tones = [if (hasLan) lan.$2, cloud.$2];
    return tones.contains(_Tone.bad) ? _Tone.bad : (tones.contains(_Tone.busy) ? _Tone.busy : _Tone.good);
  }

  static String _count(int n) => NumberFormat.decimalPattern('en_PK').format(n);
}

Color _toneColor(_Tone t) => switch (t) {
      _Tone.good => SoftPalette.emerald500,
      _Tone.busy => SoftPalette.amber500,
      _Tone.bad => SoftPalette.red400,
    };

/// Rebuilds [builder] every 2 s and whenever the cloud queue or quota changes.
class _Live extends StatelessWidget {
  const _Live({required this.builder});
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final Listenable queue = Hive.isBoxOpen(LocalStorageService.syncBox)
        ? DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox))
        : const _NoChange();
    return StreamBuilder<int>(
      stream: Stream<int>.periodic(const Duration(seconds: 2), (i) => i),
      builder: (context, _) => ListenableBuilder(
        listenable: Listenable.merge([QuotaService.isQuotaExhaustedNotifier, queue]),
        builder: (context, _) => builder(context),
      ),
    );
  }
}

/// A Listenable that never fires (the sync box is not open yet).
class _NoChange implements Listenable {
  const _NoChange();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class DeskConnectionPill extends StatelessWidget {
  const DeskConnectionPill({
    super.key,
    required this.isDark,
    required this.isOnline,
    this.connectionStatus,
    this.onRetryConnection,
    this.onForceSync,
    this.isSyncing = false,
    this.compact = false,
    this.dense = false,
  });

  final bool isDark;
  final bool isOnline;
  final ConnectionStatus? connectionStatus;
  final VoidCallback? onRetryConnection;
  final VoidCallback? onForceSync;
  final bool isSyncing;

  /// Phones: a dot and the waiting count only.
  final bool compact;

  /// Tablets: one line.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return _Live(builder: (context) {
      final s = _DeskState(status: connectionStatus, isOnline: isOnline);
      final (lanLabel, lanTone) = s.lan;
      final (cloudLabel, cloudTone) = s.cloud;
      final dot = _toneColor(s.worst);
      final muted = isDark ? SoftPalette.slate350 : SoftPalette.slate550;
      final strong = isDark ? SoftPalette.gray50 : SoftPalette.slate800;

      final searching = s.lanSearching;
      final indicator = SizedBox(
        width: 10,
        height: 10,
        child: searching
            ? CircularProgressIndicator(strokeWidth: 2, color: dot)
            : DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
      );

      // Internet: always visible as a wifi icon (green online, red offline).
      final net = Icon(isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
          size: 14, color: isOnline ? SoftPalette.emerald500 : SoftPalette.red400);

      final Widget content;
      if (compact) {
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          indicator,
          const SizedBox(width: 6),
          net,
          if (s.cloudPending > 0) ...[
            const SizedBox(width: 6),
            Text('${s.cloudPending}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: strong)),
          ],
        ]);
      } else {
        final line1 = s.hasLan ? lanLabel : cloudLabel;
        final line1Tone = s.hasLan ? lanTone : cloudTone;
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          indicator,
          const SizedBox(width: 8),
          Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line1,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: line1Tone == _Tone.good ? strong : _toneColor(line1Tone))),
            if (s.hasLan && !dense)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                    size: 11, color: isOnline ? SoftPalette.emerald500 : SoftPalette.red400),
                const SizedBox(width: 3),
                Text(cloudLabel,
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: cloudTone == _Tone.good ? muted : _toneColor(cloudTone))),
              ]),
          ]),
          // Narrow (one line): never hide the internet / cloud state; icons + count.
          if (s.hasLan && dense) ...[
            const SizedBox(width: 8),
            net,
            if (s.cloudPending > 0) ...[
              const SizedBox(width: 3),
              Text(_DeskState._count(s.cloudPending),
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _toneColor(cloudTone))),
            ],
          ],
          const SizedBox(width: 6),
          Icon(Icons.expand_more_rounded, size: 16, color: muted),
        ]);
      }

      return Semantics(
        button: true,
        label: 'Connection and sync: $lanLabel. $cloudLabel',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => DeskSyncPanel.show(
              context,
              isOnline: isOnline,
              connectionStatus: connectionStatus,
              onRetryConnection: onRetryConnection,
              onForceSync: onForceSync,
            ),
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
              ),
              child: content,
            ),
          ),
        ),
      );
    });
  }
}

/// The Connection & sync panel: local server, cloud, and the repair tools.
abstract final class DeskSyncPanel {
  static Future<void> show(
    BuildContext context, {
    required bool isOnline,
    ConnectionStatus? connectionStatus,
    VoidCallback? onRetryConnection,
    VoidCallback? onForceSync,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark ||
            (Hive.isBoxOpen('app_settings') && Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true);
        final strong = isDark ? SoftPalette.gray50 : SoftPalette.slate800;
        final muted = isDark ? SoftPalette.slate350 : SoftPalette.slate550;
        final rule = isDark ? SoftPalette.slate700 : SoftPalette.slate150;
        final accent = isDark ? SoftPalette.emerald400 : SoftPalette.emerald600;

        Widget section(String title, IconData icon, (String, _Tone) state, List<String> lines, List<Widget> actions) => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: rule)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: strong)),
                  const Spacer(),
                  Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: _toneColor(state.$2))),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(state.$1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: state.$2 == _Tone.good ? strong : _toneColor(state.$2))),
                  ),
                ]),
                for (final l in lines) ...[
                  const SizedBox(height: 4),
                  Text(l, style: TextStyle(fontSize: 12, color: muted)),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ]),
            );

        Widget action(String label, IconData icon, VoidCallback? onTap) => OutlinedButton.icon(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: accent,
                side: BorderSide(color: rule),
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              icon: Icon(icon, size: 16),
              label: Text(label),
            );

        final time = DateFormat('h:mm a');
        return Dialog(
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: _Live(builder: (context) {
                final s = _DeskState(status: connectionStatus, isOnline: isOnline);
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Text('Connection & sync', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: strong)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: Icon(Icons.close_rounded, size: 20, color: muted),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (s.hasLan) ...[
                    section(
                      'Local server',
                      Icons.lan_rounded,
                      s.lan,
                      [
                        if (s.serverAddress != null) 'Address: ${s.serverAddress}',
                        s.unsent > 0 ? '${s.unsent} change(s) on this desk not yet confirmed by the server.' : 'Everything on this desk is confirmed.',
                      ],
                      [
                        if (!s.lanConnected && onRetryConnection != null) action('Reconnect', Icons.refresh_rounded, onRetryConnection),
                        action('Server settings', Icons.settings_ethernet_rounded, () => LanServerConfigDialog.show(ctx)),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  section(
                    'Cloud',
                    Icons.cloud_queue_rounded,
                    s.cloud,
                    [
                      'Internet: ${isOnline ? 'online' : 'offline'}',
                      if (s.pausedUntil != null)
                        'Daily cloud limit reached. Uploads resume at ${time.format(s.pausedUntil!.toLocal())}; all data is safe on this device.',
                      if (CloudDb.lastSuccessAt.value != null) 'Last upload: ${time.format(CloudDb.lastSuccessAt.value!)}',
                      'Cloud writes from this device today: ${QuotaService.dailyWriteCount}',
                    ],
                    [
                      action('Upload everything now', Icons.cloud_upload_outlined, () {
                        if (onForceSync != null) {
                          onForceSync();
                        } else {
                          unawaited(HiddenForceUploader.instance.runSilentForceUpload());
                        }
                      }),
                      action('Queue doctor', Icons.medical_services_outlined, () => QueueDoctorDialog.show(ctx)),
                    ],
                  ),
                ]);
              }),
            ),
          ),
        );
      },
    );
  }
}
