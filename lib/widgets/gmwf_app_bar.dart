// lib/widgets/gmwf_app_bar.dart
// Premium, modular, floating header bar for GMWF client & dispensary desks.

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../realtime/connection_manager.dart';
import '../services/user_theme_service.dart';
import '../services/auto_update_service.dart';
import '../design/components/app_toast.dart';
import '../design/tokens/breakpoints.dart';
import '../services/dispensary_preferences_service.dart';
import '../pages/dispensary/widgets/pharmacy_pane_layout_dialog.dart';
import 'desk_connection_pill.dart';
import 'appearance_dialog.dart';

/// An item a desk adds to the "Desk" group of the shared ⋮ menu
/// (e.g. the Doctor's templates and stock requests).
class GmwfMenuAction {
  const GmwfMenuAction({required this.id, required this.label, required this.icon, required this.onTap, this.badge = 0});
  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Shown on the item and summed on the ⋮ button (e.g. pending requests).
  final int badge;
}

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
  final Widget? customMenuButton;
  final List<Widget>? extraActions;
  final List<Widget>? trailingActions;

  /// Count shown on the header inventory button (e.g. restock alerts).
  final int inventoryBadge;
  final PreferredSizeWidget? bottom;
  final Widget? centerWidget;
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
    this.customMenuButton,
    this.extraActions,
    this.trailingActions,
    this.inventoryBadge = 0,
    this.bottom,
    this.centerWidget,
    this.showThemeToggle = true,
    this.toolbarHeight = 68,
    this.isFloating = true,
    this.showHybridLayoutToggle = false,
    this.showTimingFormatToggle = false,
    this.showPaneOrderToggle = false,
    this.onToggleHybridLayout,
    this.onToggleTimingFormat,
    this.onTogglePaneOrder,
    this.deskActions = const [],
  });

  final bool showPaneOrderToggle;
  final VoidCallback? onTogglePaneOrder;

  /// Desk-specific items for the "Desk" group of the ⋮ menu.
  final List<GmwfMenuAction> deskActions;

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
        final brand = Theme.of(context).colorScheme.primary;

        final barContent = Container(
          height: toolbarHeight,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
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
                    // Left Branded Logo Block
                    _buildLogoBadge(isMobile, brand),

                    SizedBox(width: isMobile ? 8 : 12),

                    // Vertical Accent Divider Line
                    Container(
                      width: 2.5,
                      height: isMobile ? 22 : 26,
                      decoration: BoxDecoration(
                        color: brand,
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
                                  color: isDark ? SoftPalette.gray50 : brand,
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

                    // Centered header widget (e.g. Separate-View tabs pill bar)
                    if (!isMobile && centerWidget != null) ...[
                      const SizedBox(width: 8),
                      centerWidget!,
                      const Spacer(),
                    ],

                    // Extra Actions (e.g. Camp Selector)
                    if (extraActions != null && extraActions!.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ...extraActions!,
                    ],

                    // One connection pill: local server + internet + cloud queue.
                    // Tapping it opens Connection & sync (details, upload, queue doctor).
                    // The version lives once, at the foot of the ⋮ menu.
                    const SizedBox(width: 8),
                    DeskConnectionPill(
                      isDark: isDark,
                      isOnline: isOnline,
                      connectionStatus: connectionStatus,
                      onRetryConnection: onRetryConnection,
                      onForceSync: onSync,
                      isSyncing: isSyncing,
                      compact: isMobile,
                      dense: isCompact && !isMobile,
                    ),
                    // Trailing header actions (between the connection pill and the ⋮ menu)
                    if (trailingActions != null && trailingActions!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ...trailingActions!,
                    ],
                    // Stock / medicine inventory shortcut
                    if (onInventory != null) ...[
                      SizedBox(width: isMobile ? 6 : 8),
                      _buildInventoryButton(isDark: isDark, isMobile: isMobile),
                    ],
                    // Right Action Controls
                    if (customMenuButton != null) ...[
                      const SizedBox(width: 8),
                      customMenuButton!,
                      SizedBox(width: isMobile ? 4 : 8),
                    ] else if (useMenuButton) ...[
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

  Widget _buildLogoBadge(bool isMobile, Color brandColor) {
    return Container(
      width: isMobile ? 44 : 70,
      height: double.infinity,
      decoration: BoxDecoration(
        color: brandColor,
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

  /// Header shortcut to the medicine inventory (same look as the ⋮ button).
  Widget _buildInventoryButton({required bool isDark, required bool isMobile}) {
    final size = isMobile ? 36.0 : 40.0;
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onInventory,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: size,
          width: size,
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? SoftPalette.slate600 : SoftPalette.slate200,
              width: 1,
            ),
          ),
          child: Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: isDark ? SoftPalette.slate350 : SoftPalette.emerald600,
          ),
        ),
      ),
    );
    return Tooltip(
      message: inventoryBadge > 0
          ? 'Medicine inventory ($inventoryBadge restock alert${inventoryBadge == 1 ? '' : 's'})'
          : 'Medicine inventory (Stock)',
      child: Badge(
        isLabelVisible: inventoryBadge > 0,
        offset: const Offset(2, -2),
        backgroundColor: SoftPalette.orange350,
        label: Text(
          inventoryBadge > 99 ? '99+' : '$inventoryBadge',
          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
        ),
        child: button,
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

  /// A small grey group label inside the ⋮ menu.
  PopupMenuItem<String> _menuHeader(String text, bool isDark) => PopupMenuItem<String>(
        enabled: false,
        height: 26,
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: isDark ? SoftPalette.slate400 : SoftPalette.slate400,
          ),
        ),
      );

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
      child: Badge(
        isLabelVisible: deskActions.any((a) => a.badge > 0),
        backgroundColor: SoftPalette.orange350,
        label: Text('${deskActions.fold<int>(0, (s, a) => s + a.badge)}',
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
        child: menuBtn,
      ),
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
          case 'appearance':
            await AppearanceDialog.show(context, userKey: userId);
            break;
          case 'logout':
            onLogout?.call();
            break;
          default:
            for (final a in deskActions) {
              if (val == 'desk:${a.id}') a.onTap();
            }
        }
      },
      itemBuilder: (ctx) => [
        if (showHybridLayoutToggle || showPaneOrderToggle || showTimingFormatToggle)
          _menuHeader('Desk layout', isDark),
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
        if (deskActions.isNotEmpty) _menuHeader('Desk', isDark),
        for (final a in deskActions)
          PopupMenuItem<String>(
            value: 'desk:${a.id}',
            child: Row(
              children: [
                Icon(a.icon, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    a.label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                  ),
                ),
                if (a.badge > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: SoftPalette.orange350, borderRadius: BorderRadius.circular(8)),
                    child: Text('${a.badge}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: SoftPalette.gray50)),
                  ),
              ],
            ),
          ),
        if (deskActions.isNotEmpty) const PopupMenuDivider(height: 8),
        _menuHeader('Account', isDark),
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
        if (showThemeToggle)
          PopupMenuItem(
            value: 'appearance',
            child: Row(
              children: [
                Icon(Icons.palette_outlined, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
                const SizedBox(width: 10),
                Text(
                  'Appearance',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                ),
                const Spacer(),
                Text(
                  isDark ? 'Dark' : 'Light',
                  style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                ),
              ],
            ),
          ),        if (onLogout != null)
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
