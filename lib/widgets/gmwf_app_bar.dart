// lib/widgets/gmwf_app_bar.dart
// Premium, modular, floating header bar for GMWF client & dispensary desks.

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../realtime/connection_manager.dart';
import '../services/user_theme_service.dart';
import '../design/tokens/breakpoints.dart';
import 'lan_server_config_dialog.dart';

class GmwfAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onTitleLongPress;
  final String? titleTooltip;
  final ConnectionStatus? connectionStatus;
  final VoidCallback? onRetryConnection;
  final bool isOnline;
  final bool isSyncing;
  final VoidCallback? onSync;
  final VoidCallback? onLogout;
  final bool isLoggingOut;
  final VoidCallback? onInventory;
  final VoidCallback? onUserSettings;
  final bool useMenuButton;
  final List<Widget>? extraActions;
  final PreferredSizeWidget? bottom;
  final bool showThemeToggle;
  final double toolbarHeight;
  final bool isFloating;

  const GmwfAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onTitleLongPress,
    this.titleTooltip,
    this.connectionStatus,
    this.onRetryConnection,
    this.isOnline = true,
    this.isSyncing = false,
    this.onSync,
    this.onLogout,
    this.isLoggingOut = false,
    this.onInventory,
    this.onUserSettings,
    this.useMenuButton = true,
    this.extraActions,
    this.bottom,
    this.showThemeToggle = true,
    this.toolbarHeight = 68,
    this.isFloating = true,
  });

  @override
  Size get preferredSize {
    final bottomHeight = bottom != null ? (bottom!.preferredSize.height + (isFloating ? 6 : 0)) : 0.0;
    return Size.fromHeight(toolbarHeight + (isFloating ? 14 : 0) + bottomHeight);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile  = GBreakpoint.isMobile(context);   // < 600
    final isCompact = !GBreakpoint.isDesktop(context);  // < 900 (hides status pills on tablet/mobile)

    return ValueListenableBuilder<Box>(
      valueListenable:
          Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;

        final barContent = Container(
          height: toolbarHeight,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: isFloating ? BorderRadius.circular(18) : BorderRadius.zero,
            border: isFloating
                ? Border.all(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                    width: 1.2,
                  )
                : Border(
                    bottom: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                      width: 1.2,
                    ),
                  ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
                blurRadius: isFloating ? 12 : 4,
                offset: Offset(0, isFloating ? 3 : 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
                  children: [
                    // Left Green Logo Block
                    _buildLogoBadge(isMobile),

                    SizedBox(width: isMobile ? 8 : 12),

                    // Vertical Green Accent Divider Line
                    Container(
                      width: 2.5,
                      height: isMobile ? 22 : 26,
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),

                    SizedBox(width: isMobile ? 8 : 12),

                    // Title & Subtitle
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onLongPress: onTitleLongPress,
                            child: Tooltip(
                              message: titleTooltip ?? '',
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: isMobile ? 14 : 17,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF0F3E34),
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                          ),
                          if (subtitle != null && subtitle!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 13,
                                  color: isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    subtitle!.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: isMobile ? 10.5 : 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      letterSpacing: 0.7,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    // LAN Status Pill
                    if (connectionStatus != null && !isMobile) ...[
                      const SizedBox(width: 8),
                      _buildLanStatusPill(
                        context: context,
                        isDark: isDark,
                        status: connectionStatus!,
                        isCompact: isCompact,
                      ),
                    ],

                    // Internet Status Pill (no fake dropdown arrow)
                    if (!isMobile) ...[
                      const SizedBox(width: 8),
                      _buildInternetStatusPill(
                        isDark: isDark,
                        isCompact: isCompact,
                      ),
                    ],

                    // Extra Actions (e.g. Camp Selector, Inventory)
                    if (extraActions != null && extraActions!.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ...extraActions!,
                    ],

                    // Right Action Controls
                    if (useMenuButton) ...[
                      const SizedBox(width: 8),
                      _buildMenuButton(
                        context: context,
                        isDark: isDark,
                        isMobile: isMobile,
                      ),
                      SizedBox(width: isMobile ? 4 : 8),
                    ] else ...[
                      if (!isMobile) ...[
                        const SizedBox(width: 6),
                        _buildDivider(isDark),
                        const SizedBox(width: 6),
                      ] else
                        const SizedBox(width: 4),

                      // Sync Button (with standard circular sync icon)
                      if (onSync != null) ...[
                        _buildIconButton(
                          isDark: isDark,
                          tooltip: 'Force full sync',
                          onTap: isSyncing ? null : onSync,
                          isMobile: isMobile,
                          child: isSyncing
                              ? SizedBox(
                                  width: isMobile ? 14 : 16,
                                  height: isMobile ? 14 : 16,
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF0F5B46),
                                  ),
                                )
                              : Icon(
                                  Icons.sync_rounded,
                                  size: isMobile ? 17 : 20,
                                  color: isDark
                                      ? const Color(0xFF38BDF8)
                                      : const Color(0xFF0F5B46),
                                ),
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                      ],

                      // Theme Toggle Button
                      if (showThemeToggle) ...[
                        _buildIconButton(
                          isDark: isDark,
                          tooltip: isDark
                              ? 'Switch to Light Mode'
                              : 'Switch to Dark Mode',
                          isMobile: isMobile,
                          onTap: () async {
                            await UserThemeService.setDarkMode(!isDark);
                          },
                          child: Icon(
                            isDark
                                ? Icons.dark_mode_outlined
                                : Icons.wb_sunny_outlined,
                            size: isMobile ? 16 : 18,
                            color: isDark
                                ? const Color(0xFFFBBF24)
                                : const Color(0xFF0F5B46),
                          ),
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                      ],

                      // Logout Button (for Dispensary screens)
                      if (onLogout != null) ...[
                        _buildLogoutButton(isDark, isMobile),
                        SizedBox(width: isMobile ? 4 : 8),
                      ],
                    ],
                  ],
                ),
              );

        if (!isFloating) {
          return Container(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                barContent,
                if (bottom != null) bottom!,
              ],
            ),
          );
        }

        return Container(
          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F5),
          padding: EdgeInsets.fromLTRB(isMobile ? 8 : 14, 6, isMobile ? 8 : 14, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              barContent,
              if (bottom != null) ...[
                const SizedBox(height: 6),
                bottom!,
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildLogoBadge(bool isMobile) {
    return Container(
      width: isMobile ? 44 : 70,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF0F5B46),
      ),
      child: Center(
        child: Image.asset(
          'assets/logo/gmwf-1.webp',
          height: isMobile ? 26 : 42,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.local_hospital_rounded,
            color: Colors.white,
            size: isMobile ? 20 : 26,
          ),
        ),
      ),
    );
  }

  Widget _buildLanStatusPill({
    required BuildContext context,
    required bool isDark,
    required ConnectionStatus status,
    required bool isCompact,
  }) {
    final isConnected = status.isConnected;
    final isSearching = status.isSearching || status.isConnecting;

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
        // When disconnected and retry callback exists, retry immediately
        // instead of opening the config dialog.
        if (!isConnected && onRetryConnection != null) {
          onRetryConnection!();
          return;
        }
        LanServerConfigDialog.show(context);
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: badgeBg,
              ),
              child: Center(
                child: isSearching
                    ? SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: dotColor,
                        ),
                      )
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dotColor,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 7),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: dotColor,
                  ),
                ),
                if (!isCompact) ...[
                  Text(
                    status.ip != null
                        ? '${status.ip}:${status.port}'
                        : 'LAN Local',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(width: 6),
            if (isConnected)
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF10B981),
                size: 16,
              )
            else if (onRetryConnection != null)
              Icon(
                Icons.refresh_rounded,
                color: dotColor,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInternetStatusPill({
    required bool isDark,
    required bool isCompact,
  }) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOnline
                  ? (isDark
                      ? const Color(0xFF0C4A6E)
                      : const Color(0xFFE0F2FE))
                  : (isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFF1F5F9)),
            ),
            child: Center(
              child: Icon(
                isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 14,
                color: isOnline
                    ? const Color(0xFF0284C7)
                    : const Color(0xFF94A3B8),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Internet',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F3E34),
                ),
              ),
              if (!isCompact) ...[
                Text(
                  isOnline ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w500,
                    color: isOnline
                        ? (isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B))
                        : const Color(0xFFEF4444),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Container(
      height: 24,
      width: 1,
      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
    );
  }

  Widget _buildIconButton({
    required bool isDark,
    required String tooltip,
    required Widget child,
    VoidCallback? onTap,
    bool isMobile = false,
  }) {
    final btnSize = isMobile ? 32.0 : 36.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
          child: Container(
            width: btnSize,
            height: btnSize,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
              border: Border.all(
                color:
                    isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                width: 1,
              ),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  Widget _buildLogoutButton(bool isDark, bool isMobile) {
    final btnHeight = isMobile ? 32.0 : 36.0;
    if (isLoggingOut) {
      return Container(
        height: btnHeight,
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
        decoration: BoxDecoration(
          color: const Color(0xFF0F5B46),
          borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
        ),
        child: Center(
          child: SizedBox(
            width: isMobile ? 13 : 15,
            height: isMobile ? 13 : 15,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onLogout,
        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
        child: Container(
          height: btnHeight,
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F5B46),
            borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.logout_rounded,
                size: isMobile ? 14 : 15,
                color: Colors.white,
              ),
              if (!isMobile) ...[
                const SizedBox(width: 5),
                const Text(
                  'Logout',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuButton({
    required BuildContext context,
    required bool isDark,
    required bool isMobile,
  }) {
    final menuBtn = Container(
      height: isMobile ? 36 : 40,
      width: isMobile ? 36 : 40,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
          width: 1,
        ),
      ),
      child: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF0F5B46),
      ),
    );

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      elevation: 8,
      offset: const Offset(0, 46),
      child: menuBtn,
      onSelected: (val) async {
        switch (val) {
          case 'inventory':
            onInventory?.call();
            break;
          case 'settings':
            if (onUserSettings != null) {
              onUserSettings!.call();
            } else if (onTitleLongPress != null) {
              onTitleLongPress!.call();
            }
            break;
          case 'sync':
            if (onSync != null && !isSyncing) onSync!.call();
            break;
          case 'theme':
            await UserThemeService.setDarkMode(!isDark);
            break;
          case 'logout':
            onLogout?.call();
            break;
        }
      },
      itemBuilder: (ctx) => [
        if (onInventory != null)
          PopupMenuItem(
            value: 'inventory',
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 18, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F5B46)),
                const SizedBox(width: 10),
                Text(
                  'Medicine Inventory',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
              ],
            ),
          ),
        if (onUserSettings != null || onTitleLongPress != null)
          PopupMenuItem(
            value: 'settings',
            child: Row(
              children: [
                Icon(Icons.manage_accounts_outlined, size: 18, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F5B46)),
                const SizedBox(width: 10),
                Text(
                  'User Settings',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
              ],
            ),
          ),
        if (onSync != null)
          PopupMenuItem(
            value: 'sync',
            child: Row(
              children: [
                Icon(Icons.sync_rounded, size: 18, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F5B46)),
                const SizedBox(width: 10),
                Text(
                  isSyncing ? 'Syncing...' : 'Force Sync',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
              ],
            ),
          ),
        if (showThemeToggle)
          PopupMenuItem(
            value: 'theme',
            child: Row(
              children: [
                Icon(isDark ? Icons.wb_sunny_outlined : Icons.dark_mode_outlined, size: 18, color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF0F5B46)),
                const SizedBox(width: 10),
                Text(
                  isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
              ],
            ),
          ),
        if (onLogout != null)
          PopupMenuItem(
            value: 'logout',
            child: Row(
              children: const [
                Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                SizedBox(width: 10),
                Text(
                  'Logout',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.redAccent),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
