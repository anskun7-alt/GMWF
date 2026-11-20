import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../services/cloud/cloud_db.dart';
import '../services/local_storage_service.dart';
import '../services/quota_service.dart';
import '../services/sync_service.dart';

import '../constants/navigator_key.dart';
import 'queue_doctor_dialog.dart';

class SyncStatusIndicator extends StatelessWidget {
  final bool? isDark;
  const SyncStatusIndicator({super.key, this.isDark});

  @override
  Widget build(BuildContext context) {
    // Guard: box may not be open yet during app initialization
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<bool>(
      valueListenable: QuotaService.isQuotaExhaustedNotifier,
      builder: (context, _, _) => ValueListenableBuilder(
        valueListenable: DebouncedBoxListenable.shared(Hive.box(LocalStorageService.syncBox)),
        builder: (context, box, widget) {
          final pendingCount = box.length;
          final isSynced = pendingCount == 0;
          // Firestore refused writes for the daily quota: data waits safely on this device.
          final pausedUntil = QuotaService.dailyResetPauseUntil;
          final isPaused = pausedUntil != null;

          final effectiveDark = isDark ??
              (Hive.isBoxOpen('app_settings')
                  ? Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true
                  : false);

          final Color bgColor;
          final Color borderColor;
          final Color iconColor;
          final Color textColor;

          if (effectiveDark) {
            if (isPaused) {
              bgColor = SoftPalette.red400.withValues(alpha: 0.2);
              borderColor = SoftPalette.red400.withValues(alpha: 0.5);
              iconColor = SoftPalette.red350;
              textColor = SoftPalette.gray50;
            } else if (!isSynced) {
              bgColor = SoftPalette.amber400.withValues(alpha: 0.2);
              borderColor = SoftPalette.amber400.withValues(alpha: 0.5);
              iconColor = SoftPalette.amber300;
              textColor = SoftPalette.gray50;
            } else {
              bgColor = SoftPalette.gray50.withValues(alpha: 0.1);
              borderColor = Colors.transparent;
              iconColor = SoftPalette.emerald200;
              textColor = SoftPalette.gray50;
            }
          } else {
            if (isPaused) {
              bgColor = SoftPalette.red100;
              borderColor = SoftPalette.red300;
              iconColor = SoftPalette.red600;
              textColor = SoftPalette.red700;
            } else if (!isSynced) {
              bgColor = SoftPalette.amber100;
              borderColor = SoftPalette.amber300;
              iconColor = SoftPalette.amber700;
              textColor = SoftPalette.amber900;
            } else {
              bgColor = SoftPalette.emerald100;
              borderColor = SoftPalette.emerald200;
              iconColor = SoftPalette.emerald600;
              textColor = SoftPalette.emerald700;
            }
          }

          // Not a Tooltip: this icon sits in the title bar above the Navigator, where there is
          // no Overlay, and a Tooltip threw "No Overlay widget found" on every rebuild.
          return Semantics(
            label: _tooltip(pendingCount, pausedUntil),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  final navContext = navigatorKey.currentContext;
                  if (navContext != null) {
                    QueueDoctorDialog.show(navContext);
                  } else {
                    SyncService().broadcastUniversalForceUpload();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: borderColor,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isPaused
                            ? Icons.cloud_off
                            : (isSynced ? Icons.cloud_done : Icons.sync),
                        size: 14,
                        color: iconColor,
                      ),
                      if (!isSynced) ...[
                        const SizedBox(width: 6),
                        Text(
                          pendingCount.toString(),
                          style: TextStyle(
                            color: textColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _tooltip(int pending, DateTime? pausedUntil) {
    final time = DateFormat('h:mm a');
    final lines = <String>[
      if (pausedUntil != null)
        'Daily cloud limit reached — uploads resume at ${time.format(pausedUntil.toLocal())}. All data is safe on this device.',
      pending == 0
          ? 'Everything is uploaded'
          : '$pending item(s) waiting to upload',
      if (CloudDb.lastSuccessAt.value != null)
        'Last upload: ${time.format(CloudDb.lastSuccessAt.value!)}',
      'Cloud writes from this device today: ${QuotaService.dailyWriteCount}',
    ];
    return lines.join('\n');
  }
}
