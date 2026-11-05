// lib/widgets/gmwf_app_bar.dart
// Premium, modular, floating header bar for GMWF client & dispensary desks.

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../realtime/connection_manager.dart';
import '../realtime/realtime_manager.dart';
import '../services/user_theme_service.dart';
import '../services/auto_update_service.dart';
import '../design/components/app_toast.dart';
import '../design/tokens/breakpoints.dart';
import '../services/dispensary_preferences_service.dart';
import '../pages/dispensary/widgets/pharmacy_pane_layout_dialog.dart';
import 'lan_server_config_dialog.dart';
import 'sync_status_indicator.dart';
import 'queue_doctor_dialog.dart';
import '../services/hidden_force_uploader.dart';

class GmwfAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String? subtitle;
  final String? userId;
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
  final bool showHybridLayoutToggle;
  final bool showTimingFormatToggle;
  final VoidCallback? onToggleHybridLayout;
  final VoidCallback? onToggleTimingFormat;

  const GmwfAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.userId,
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
    this.showHybridLayoutToggle = false,
    this.showTimingFormatToggle = false,
    this.showPaneOrderToggle = false,
    this.onToggleHybridLayout,
    this.onToggleTimingFormat,
    this.onTogglePaneOrder,
  });

  final bool showPaneOrderToggle;
  final VoidCallback? onTogglePaneOrder;

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
            color: isDark ? SoftPalette.slate800 : SoftPalette.slate50,
            borderRadius: isFloating ? BorderRadius.circular(18) : BorderRadius.zero,
            border: isFloating
                ? Border.all(
                    color: isDark
                        ? SoftPalette.slate700
                        : SoftPalette.slate150,
                    width: 1.2,
                  )
                : Border(
                    bottom: BorderSide(
                      color: isDark
                          ? SoftPalette.slate700
                          : SoftPalette.slate150,
                      width: 1.2,
                    ),
                  ),
            boxShadow: [
              BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: isDark ? 0.25 : 0.04),
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
                        color: SoftPalette.emerald350,
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
                                      ? SoftPalette.gray50
                                      : SoftPalette.teal750,
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
                                      ? SoftPalette.slate350
                                      : SoftPalette.slate550,
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
                                          ? SoftPalette.slate350
                                          : SoftPalette.slate550,
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

                    // Sync Status Indicator Pill (Queue Doctor trigger)
                    const SizedBox(width: 6),
                    SyncStatusIndicator(isDark: isDark),

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
                                    color: SoftPalette.emerald600,
                                  ),
                                )
                              : Icon(
                                  Icons.sync_rounded,
                                  size: isMobile ? 17 : 20,
                                  color: isDark
                                      ? SoftPalette.sky350
                                      : SoftPalette.emerald600,
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
                                ? SoftPalette.amber200
                                : SoftPalette.emerald600,
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
            color: isDark ? SoftPalette.slate800 : SoftPalette.slate50,
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
          color: isDark ? SoftPalette.slate900 : SoftPalette.emerald100t,
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
        color: SoftPalette.emerald600,
      ),
      child: Center(
        child: Image.asset(
          'assets/logo/gmwf-1.webp',
          height: isMobile ? 26 : 42,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.local_hospital_rounded,
            color: SoftPalette.gray50,
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
    // Re-evaluate every 2 s so the pill follows the real link state without waiting for a rebuild.
    return StreamBuilder<int>(
      stream: Stream<int>.periodic(const Duration(seconds: 2), (i) => i),
      builder: (context, snapshot) => _buildLanStatusPillNow(context: context, isDark: isDark, status: status, isCompact: isCompact),
    );
  }

  Widget _buildLanStatusPillNow({
    required BuildContext context,
    required bool isDark,
    required ConnectionStatus status,
    required bool isCompact,
  }) {
    final rm = RealtimeManager();
    // Liveness, not a cached snapshot: stays accurate when the server disappears or changes.
    final isConnected = rm.isLinkAlive;
    final isSearching = !isConnected && (status.isSearching || status.isConnecting);

    Color badgeBg = SoftPalette.emerald100;
    Color dotColor = SoftPalette.emerald350;
    String statusLabel = 'Connected';

    // Desk health: is anything written here not yet confirmed by the server, and is this
    // desk missing tokens the server already has? Staff see at a glance if a screen is behind.
    final unsent = rm.unsentCount;
    final missing = RealtimeManager.unconfirmedTokensNotifier.value;
    if (isConnected) {
      if (rm.isBehindServer && missing > 0) {
        badgeBg = isDark ? SoftPalette.orange700 : SoftPalette.amber100;
        dotColor = SoftPalette.orange350;
        statusLabel = 'Catching up ($missing)';
      } else if (unsent > 0) {
        badgeBg = isDark ? SoftPalette.orange700 : SoftPalette.amber100;
        dotColor = SoftPalette.orange350;
        statusLabel = 'Sending ($unsent)';
      } else {
        badgeBg = isDark ? SoftPalette.emerald700 : SoftPalette.emerald100;
        dotColor = SoftPalette.emerald350;
        statusLabel = 'Live';
      }
    } else if (isSearching) {
      badgeBg = isDark ? SoftPalette.orange700 : SoftPalette.amber100;
      dotColor = SoftPalette.orange350;
      statusLabel = status.isConnecting ? 'Connecting…' : 'Searching…';
      if (unsent > 0) statusLabel = '$statusLabel $unsent unsent';
    } else {
      badgeBg = isDark ? SoftPalette.red700 : SoftPalette.red150m;
      dotColor = SoftPalette.red400;
      statusLabel = RealtimeManager.versionRejectedNotifier.value != null
          ? 'Update required'
          : (unsent > 0 ? 'Offline – $unsent unsent' : 'Offline');
    }

    final displayIp = status.ip ?? rm.serverIp;
    final displayPort = status.port ?? rm.port;

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
          color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
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
                    displayIp != null
                        ? '$displayIp:$displayPort'
                        : 'LAN Local',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: isDark
                          ? SoftPalette.slate350
                          : SoftPalette.slate550,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(width: 6),
            if (isConnected)
              const Icon(
                Icons.check_circle_rounded,
                color: SoftPalette.emerald350,
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
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
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
                      ? SoftPalette.sky700
                      : SoftPalette.slate100)
                  : (isDark
                      ? SoftPalette.slate700
                      : SoftPalette.slate100),
            ),
            child: Center(
              child: Icon(
                isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 14,
                color: isOnline
                    ? SoftPalette.sky500
                    : SoftPalette.slate350,
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
                  color: isDark ? SoftPalette.gray50 : SoftPalette.teal750,
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
                            ? SoftPalette.slate350
                            : SoftPalette.slate550)
                        : SoftPalette.red400,
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
      color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
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
              color: isDark ? SoftPalette.slate800 : SoftPalette.slate50,
              borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
              border: Border.all(
                color:
                    isDark ? SoftPalette.slate700 : SoftPalette.slate150,
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
          color: SoftPalette.emerald600,
          borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
        ),
        child: Center(
          child: SizedBox(
            width: isMobile ? 13 : 15,
            height: isMobile ? 13 : 15,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: SoftPalette.gray50,
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
            color: SoftPalette.emerald600,
            borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.logout_rounded,
                size: isMobile ? 14 : 15,
                color: SoftPalette.gray50,
              ),
              if (!isMobile) ...[
                const SizedBox(width: 5),
                const Text(
                  'Logout',
                  style: TextStyle(
                    color: SoftPalette.gray50,
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
        color: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? SoftPalette.slate600 : SoftPalette.slate200,
          width: 1,
        ),
      ),
      child: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: isDark ? SoftPalette.slate350 : SoftPalette.emerald600,
      ),
    );

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
      elevation: 8,
      offset: const Offset(0, 46),
      child: menuBtn,
      onSelected: (val) async {
        switch (val) {
          case 'toggle_hybrid_layout':
            final next = await DispensaryPreferencesService.toggleHybridAllInOne(explicitUserKey: userId);
            AppToast.show(
              message: next
                  ? 'Switched to Single-Screen Hybrid Preview'
                  : 'Switched to Separate Tabs (Receptionist & Dispenser)',
              kind: GToastKind.success,
            );
            onToggleHybridLayout?.call();
            break;
          case 'toggle_timing_format':
            final next = await DispensaryPreferencesService.toggleShowUrduTiming(explicitUserKey: userId);
            AppToast.show(
              message: next
                  ? 'Medicine Timing: Urdu Text (صبح / شام)'
                  : 'Medicine Timing: Compact 1+1+1 Format',
              kind: GToastKind.success,
            );
            onToggleTimingFormat?.call();
            break;
          case 'toggle_pane_order':
            PharmacyPaneLayoutDialog.show(
              context,
              userId: userId,
              onSelected: (_) => onTogglePaneOrder?.call(),
            );
            break;
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
            if (onSync != null && !isSyncing) {
              onSync!.call();
            } else {
              HiddenForceUploader.instance.runSilentForceUpload();
            }
            break;
          case 'queue_doctor':
            QueueDoctorDialog.show(context);
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
        if (showHybridLayoutToggle)
          PopupMenuItem<String>(
            value: 'toggle_hybrid_layout',
            child: ValueListenableBuilder<Box>(
              valueListenable: DispensaryPreferencesService.hybridAllInOneListenable(userId),
              builder: (context, box, _) {
                final isAllInOne = DispensaryPreferencesService.isHybridAllInOne(userId);
                return Row(
                  children: [
                    Icon(
                      isAllInOne ? Icons.view_quilt_rounded : Icons.tab_rounded,
                      size: 18,
                      color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isAllInOne ? 'Hybrid: Single Screen' : 'Hybrid: Separate Tabs',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.gray50 : SoftPalette.slate800,
                            ),
                          ),
                          Text(
                            isAllInOne ? 'Switch to separate tabs' : 'Switch to single screen',
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      isAllInOne ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: isAllInOne ? SoftPalette.emerald500 : (isDark ? SoftPalette.slate500 : SoftPalette.slate400),
                    ),
                  ],
                );
              },
            ),
          ),
        if (showPaneOrderToggle)
          PopupMenuItem<String>(
            value: 'toggle_pane_order',
            child: ValueListenableBuilder<Box>(
              valueListenable: DispensaryPreferencesService.pharmacyPaneOrderListenable(userId),
              builder: (context, box, _) {
                final current = DispensaryPreferencesService.getPharmacyPaneOrder(userId);
                final layoutInfo = DispensaryPreferencesService.availablePaneLayouts
                    .firstWhere((l) => l['id'] == current, orElse: () => {
                      'id': current,
                      'title': 'List · Token · Dispense',
                      'subtitle': 'Tokens on left, Register/Vitals in middle, Dispense on right',
                    });
                return Row(
                  children: [
                    Icon(
                      Icons.view_column_rounded,
                      size: 18,
                      color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Columns: ${layoutInfo['title']}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.gray50 : SoftPalette.slate800,
                            ),
                          ),
                          Text(
                            layoutInfo['subtitle'] ?? 'Tap to choose column order',
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600,
                    ),
                  ],
                );
              },
            ),
          ),
        if (showTimingFormatToggle)
          PopupMenuItem<String>(
            value: 'toggle_timing_format',
            child: ValueListenableBuilder<Box>(
              valueListenable: DispensaryPreferencesService.showUrduTimingListenable(userId),
              builder: (context, box, _) {
                final isUrdu = DispensaryPreferencesService.isShowUrduTiming(userId);
                return Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 18,
                      color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isUrdu ? 'Timing: Urdu Text' : 'Timing: 1+1+1 Format',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.gray50 : SoftPalette.slate800,
                            ),
                          ),
                          Text(
                            isUrdu ? 'Switch to 1+1+1 format' : 'Switch to Urdu text',
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      isUrdu ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: isUrdu ? SoftPalette.emerald500 : (isDark ? SoftPalette.slate500 : SoftPalette.slate400),
                    ),
                  ],
                );
              },
            ),
          ),
        if (showHybridLayoutToggle || showPaneOrderToggle || showTimingFormatToggle)
          const PopupMenuDivider(height: 8),
        if (onInventory != null)
          PopupMenuItem(
            value: 'inventory',
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
                const SizedBox(width: 10),
                Text(
                  'Medicine Inventory',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                ),
              ],
            ),
          ),
        if (onUserSettings != null || onTitleLongPress != null)
          PopupMenuItem(
            value: 'settings',
            child: Row(
              children: [
                Icon(Icons.manage_accounts_outlined, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
                const SizedBox(width: 10),
                Text(
                  'User Settings',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                ),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'sync',
          child: Row(
            children: [
              Icon(Icons.cloud_upload_outlined, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
              const SizedBox(width: 10),
              Text(
                isSyncing ? 'Syncing...' : 'Force Cloud Sync (Upload All)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'queue_doctor',
          child: Row(
            children: [
              Icon(Icons.medical_services_outlined, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
              const SizedBox(width: 10),
              Text(
                'Queue Doctor (Offline Sync)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
              ),
            ],
          ),
        ),
        if (showThemeToggle)
          PopupMenuItem(
            value: 'theme',
            child: Row(
              children: [
                Icon(isDark ? Icons.wb_sunny_outlined : Icons.dark_mode_outlined, size: 18, color: isDark ? SoftPalette.amber200 : SoftPalette.emerald600),
                const SizedBox(width: 10),
                Text(
                  isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                ),
              ],
            ),
          ),
        if (onLogout != null)
          PopupMenuItem(
            value: 'logout',
            child: Row(
              children: const [
                Icon(Icons.logout_rounded, size: 18, color: SoftPalette.red400),
                SizedBox(width: 10),
                Text(
                  'Logout',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SoftPalette.red400),
                ),
              ],
            ),
          ),
        // App version (read from the running build), informational only.
        const PopupMenuDivider(height: 8),
        PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: isDark ? SoftPalette.slate550 : SoftPalette.slate350),
              const SizedBox(width: 10),
              Text(
                'Version ${AutoUpdateService.currentVersion}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
