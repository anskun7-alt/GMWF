// lib/widgets/connection_status_widget.dart
// Drop-in widget showing live LAN connection state with the modern pill aesthetic.

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../realtime/connection_manager.dart';
import 'lan_server_config_dialog.dart';

class ConnectionStatusBadge extends StatelessWidget {
  final ConnectionStatus status;
  final VoidCallback? onRetry;

  const ConnectionStatusBadge({
    super.key,
    required this.status,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = status.isConnected;
    final isSearching = status.isSearching || status.isConnecting;

    return ValueListenableBuilder<Box>(
      valueListenable:
          Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;

        Color badgeBg = const Color(0xFFD1FAE5);
        Color dotColor = const Color(0xFF10B981);
        String statusLabel = 'Connected';

        if (isConnected) {
          badgeBg = isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5);
          dotColor = const Color(0xFF10B981);
          statusLabel = 'Connected';
        } else if (isSearching) {
          badgeBg = isDark ? const Color(0xFF78350F) : const Color(0xFFFFEDD5);
          dotColor = const Color(0xFFF97316);
          statusLabel = status.isConnecting ? 'Connecting…' : 'Searching…';
        } else {
          badgeBg = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2);
          dotColor = const Color(0xFFEF4444);
          statusLabel = 'Disconnected';
        }

        return InkWell(
          onTap: () {
            LanServerConfigDialog.show(context);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFE2E8F0),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: badgeBg,
                  ),
                  child: Center(
                    child: isSearching
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: dotColor,
                            ),
                          )
                        : Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: dotColor,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: dotColor,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      status.ip != null
                          ? '${status.ip}:${status.port}'
                          : 'LAN Local',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                if (isConnected)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF10B981),
                    size: 18,
                  )
                else if (onRetry != null)
                  Icon(
                    Icons.refresh_rounded,
                    color: dotColor,
                    size: 18,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
