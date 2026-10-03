import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/local_storage_service.dart';
import '../services/sync_service.dart';

import '../constants/navigator_key.dart';
import 'queue_doctor_dialog.dart';

class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    // Guard: box may not be open yet during app initialization
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder(
      valueListenable: Hive.box(LocalStorageService.syncBox).listenable(),
      builder: (context, box, widget) {
        final pendingCount = box.length;
        final isSynced = pendingCount == 0;

        return MouseRegion(
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSynced
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.orange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSynced
                      ? Colors.transparent
                      : Colors.orange.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.sync,
                    size: 14,
                    color: isSynced ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  if (!isSynced) ...[
                    const SizedBox(width: 6),
                    Text(
                      pendingCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
