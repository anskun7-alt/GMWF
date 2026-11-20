// lib/pages/home/home_shell.dart
//
// The redesigned home frame, built on gmwf_ui's AppSidebar:
//
//   ≥ 1280px  full sidebar (collapsible to a rail)
//   600–1280  icon rail (expandable)
//   < 600     top bar with a menu button; the sidebar opens as a drawer
//
// One sidebar for every desk role: Dashboard, the module categories (each a
// group that opens on its overview, then lists its modules), then the
// workspace items. The top bar carries search, sync, theme, notifications and
// the profile menu. Modules still open as their own pages, exactly as before.

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../models/module_registry.dart';
import '../../services/image_upload_service.dart';
import '../../services/user_theme_service.dart';
import '../notification_screen.dart';
import '../settings_page.dart';
import 'home_dashboard.dart';
import 'home_module_host.dart';
import 'home_modules_page.dart';
import 'home_sections.dart';
import 'home_motion.dart';
import 'home_nav.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.userData,
    required this.userName,
    required this.role,
    required this.branchLabel,
    required this.version,
    required this.modules,
    required this.moduleBuilder,
    required this.onLogout,
    required this.onSupport,
    required this.legacyTheme,
    this.photoUrl = '',
    this.showNotifications = true,
    this.onForceSync,
    this.onRoleSimulator,
    this.onDataIntegrity,
    this.onSettingsChanged,
    this.onEditPhoto,
    this.availableBranches,
    this.selectedBranchId,
    this.onBranchChanged,
  });

  /// Opens the profile-photo dialog (view / change photo).
  final VoidCallback? onEditPhoto;
  final List<Map<String, String>>? availableBranches;
  final String? selectedBranchId;
  final ValueChanged<String>? onBranchChanged;

  final Map<String, dynamic> userData;
  final String userName;
  final String photoUrl;
  final String role;

  /// e.g. "All branches" or "Gujrat".
  final String branchLabel;
  final String version;
  final List<AppModule> modules;

  /// Builds a module's page (with or without the branch wrapper), shown
  /// inside the shell's content area. Sectioned modules arrive already
  /// configured for the selected section (see home_sections.dart).
  final Widget Function(AppModule module) moduleBuilder;
  final VoidCallback onLogout;
  final VoidCallback onSupport;
  final bool showNotifications;

  /// Null hides the action (role has no access).
  final VoidCallback? onForceSync;
  final VoidCallback? onRoleSimulator;
  final VoidCallback? onDataIntegrity;
  final VoidCallback? onSettingsChanged;

  /// The app's own theme, for legacy screens shown inside the shell
  /// (notifications, settings) until they move to gmwf_ui.
  final ThemeData legacyTheme;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _selected = HomeDest.home;
  bool? _collapsedOverride;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// The module shown in the content area, and where to return when it closes.
  AppModule? _hosted;
  String? _section;
  String _back = HomeDest.home;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Sidebar tree, rebuilt only when the shell widget (modules / role) changes.
  List<GNavItem>? _navCache;
  HomeShell? _navFor;
  List<GNavItem> get _nav {
    if (_navCache == null || !identical(_navFor, widget)) {
      _navFor = widget;
      _navCache = buildHomeNav(modules: widget.modules, showNotifications: widget.showNotifications);
    }
    return _navCache!;
  }

  /// Shows [m] inside the shell. Used by the sidebar, the dashboard tiles and
  /// the category pages (they may pass a customised copy, e.g. a tab preset).
  void _openModule(AppModule m, {String? section}) {
    // Payroll, Student attendance… open as a section of their parent screen.
    final (id, folded) = homeResolve(m.id, widget.modules.map((x) => x.id));
    if (id != m.id) {
      final parent = widget.modules.where((x) => x.id == id).firstOrNull;
      if (parent != null) {
        m = parent;
        section = folded;
      }
    }
    if (_hosted?.id == m.id && homeSections.containsKey(m.id)) {
      // Already open: just switch section.
      final s = section ?? _section;
      setState(() {
        _section = s;
        _selected = HomeDest.module(m.id, s);
      });
      return;
    }
    setState(() {
      if (HomeDest.moduleIdOf(_selected) == null) _back = _selected;
      _hosted = m;
      _section = section ?? defaultSection(m.id);
      _selected = HomeDest.module(m.id, _section);
      _searchCtrl.clear();
      _query = '';
    });
  }

  /// The hosted screen changed section itself (e.g. an Overview shortcut).
  void _followSection(String section) {
    final m = _hosted;
    if (!mounted || m == null || section == _section) return;
    setState(() {
      _section = section;
      _selected = HomeDest.module(m.id, section);
    });
  }

  void _closeModule() {
    if (!mounted) return;
    setState(() {
      _hosted = null;
      _section = null;
      _selected = _back;
    });
  }

  void _select(String id) {
    final moduleId = HomeDest.moduleIdOf(id);
    if (moduleId != null) {
      final section = HomeDest.sectionOf(id);
      // Same module, another section: keep the page, switch its section.
      if (_hosted?.id == moduleId) {
        if (section != _section) setState(() {
          _section = section;
          _selected = id;
        });
        return;
      }
      final m = widget.modules.where((m) => m.id == moduleId).firstOrNull;
      if (m != null) _openModule(m, section: section);
      return;
    }
    if (id == _selected) return;
    setState(() {
      _hosted = null;
      _section = null;
      _selected = id;
      if (id != HomeDest.search) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  void _onSearch(String q) {
    setState(() {
      _query = q.trim();
      if (_query.isNotEmpty) {
        _selected = HomeDest.search;
      } else if (_selected == HomeDest.search) {
        _selected = HomeDest.home;
      }
    });
  }

  // ── Titles ────────────────────────────────────────────────────────────────

  (String, String) get _titles {
    final m = _hosted;
    if (m != null) {
      final sec = sectionLabel(m.id, _section);
      return (sec == null ? m.title : '${m.title} · $sec', '${m.category.label} · ${m.description}');
    }
    final cat = HomeDest.categoryOf(_selected);
    if (cat != null) {
      final n = widget.modules.where((m) => m.category == cat).length;
      return (cat.label, '$n module${n == 1 ? '' : 's'} · ${cat.blurb}');
    }
    return switch (_selected) {
      HomeDest.notifications => ('Notifications', 'Alerts and requests for ${widget.branchLabel}'),
      HomeDest.settings => ('Account settings', 'Profile, theme, language and devices'),
      HomeDest.search => ('Search', 'Modules matching “$_query”'),
      _ => ('Dashboard', widget.branchLabel),
    };
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  // The hosted module page is built once per (module, section, shell widget).
  // Returning the same widget instance lets Flutter skip rebuilding the whole
  // module when the shell rebuilds for something else (search typing, sidebar
  // collapse, notification badge), which made typing in the top bar lag.
  Widget? _hostedBody;
  Object? _hostedBodyKey;

  Widget _body() {
    final hosted = _hosted;
    if (hosted != null) {
      final key = (identityHashCode(hosted), _section, identityHashCode(widget));
      if (_hostedBody == null || _hostedBodyKey != key) {
        _hostedBodyKey = key;
        _hostedBody = HomeModuleHost(
          // One host per module: switching its sections rebuilds, not remounts.
          key: ValueKey('host:${hosted.id}:${identityHashCode(hosted)}'),
          theme: widget.legacyTheme,
          onClosed: _closeModule,
          child: widget.moduleBuilder(withSection(hosted, _section, onSectionChanged: _followSection)),
        );
      }
      return _hostedBody!;
    }
    _hostedBody = null;
    _hostedBodyKey = null;
    final cat = HomeDest.categoryOf(_selected);
    if (cat != null) {
      return HomeModulesPage(
        key: ValueKey(_selected),
        category: cat,
        userData: widget.userData,
        modules: widget.modules.where((m) => m.category == cat).toList(),
        onOpenModule: _openModule,
        emptyMessage: 'No ${cat.label} modules for your role',
      );
    }
    switch (_selected) {
      case HomeDest.search:
        final q = _query.toLowerCase();
        return HomeModulesPage(
          key: const ValueKey(HomeDest.search),
          userData: widget.userData,
          modules: widget.modules
              .where((m) => m.title.toLowerCase().contains(q) || m.description.toLowerCase().contains(q))
              .toList(),
          onOpenModule: _openModule,
          grouped: true,
          emptyMessage: 'No module matches “$_query”',
        );
      case HomeDest.notifications:
        return Theme(
          data: widget.legacyTheme,
          child: NotificationScreen(
            branchId: (widget.userData['branchId'] ?? 'all').toString(),
            userId: (widget.userData['uid'] ?? widget.userData['id'] ?? 'user').toString(),
            role: (widget.userData['role'] ?? widget.role).toString(),
            embedded: true,
          ),
        );
      case HomeDest.settings:
        return Theme(
          data: widget.legacyTheme,
          child: SettingsPage(userData: widget.userData, embedded: true),
        );
      default:
        return HomeDashboard(
          userData: widget.userData,
          userName: widget.userName,
          modules: widget.modules,
          onOpenModule: _openModule,
        );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final w = GBreakpoint.widthOf(context);
    final drawerMode = w < GBreakpoint.mobile;
    final collapsed = _collapsedOverride ?? w < GBreakpoint.desktop;

    Widget sidebar({required bool inDrawer}) => AppSidebar(
          items: _nav,
          selectedId: _selected == HomeDest.search ? null : _selected,
          expandedWidth: 268,
          header: AppSidebarHeader(brand: GBrand.gmwf, title: 'GMWF', subtitle: 'Gulzar Madina Welfare'),
          footer: _SidebarUserCard(
            name: widget.userName,
            role: widget.role,
            branch: widget.branchLabel,
            photoUrl: widget.photoUrl,
            selected: _selected == HomeDest.settings,
            collapsed: inDrawer ? false : collapsed,
            onToggleCollapse: inDrawer ? null : () => setState(() => _collapsedOverride = !collapsed),
            onOpen: () {
              if (inDrawer) Navigator.of(context).maybePop();
              _select(HomeDest.settings);
            },
          ),
          collapsed: inDrawer ? false : collapsed,
          // Collapse lives in the top bar (leading button), not the sidebar foot.
          onSelect: (id) {
            if (inDrawer) Navigator.of(context).maybePop();
            _select(id);
          },
        );

    final page = Column(children: [
      _TopBar(
        title: _titles.$1,
        subtitle: _titles.$2,
        menuTooltip: 'Menu',
        onMenu: drawerMode
            ? () => _scaffoldKey.currentState?.openDrawer()
            : null,
        searchCtrl: _searchCtrl,
        onSearch: _onSearch,
        compactSearch: w < 900,
        actions: _actions(context),
      ),
      Expanded(
        child: HomePageSwitcher(
          // A hosted module keeps one key across its sections, so switching a
          // section never cross-fades or reloads the module.
          child: KeyedSubtree(
            key: ValueKey(_hosted != null ? 'host:${_hosted!.id}:${identityHashCode(_hosted)}' : _selected),
            child: _body(),
          ),
        ),
      ),
    ]);

    if (drawerMode) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: c.background,
        drawer: Drawer(width: 288, backgroundColor: c.sidebarBg, child: sidebar(inDrawer: true)),
        body: SafeArea(child: page),
      );
    }
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.background,
      body: Row(children: [
        sidebar(inDrawer: false),
        Expanded(child: page),
      ]),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final c = context.comfort;
    final dark = UserThemeService.isDarkMode();
    return [
      if (widget.availableBranches != null && widget.availableBranches!.isNotEmpty) ...[
        _BranchSelectorPill(
          selectedBranchId: widget.selectedBranchId ?? 'all',
          availableBranches: widget.availableBranches!,
          onChanged: widget.onBranchChanged,
        ),
        const SizedBox(width: Gsp.sp2),
      ],
      if (widget.onForceSync != null)
        IconButton(
          tooltip: 'Force global sync',
          onPressed: widget.onForceSync,
          icon: Icon(GIcons.sync, color: c.textSecondary),
        ),
      IconButton(
        tooltip: dark ? 'Light mode' : 'Dark mode',
        onPressed: () => UserThemeService.toggleDarkMode(),
        icon: Icon(dark ? GIcons.lightMode : GIcons.darkMode, color: c.textSecondary),
      ),
      if (widget.showNotifications)
        IconButton(
          tooltip: 'Notifications',
          onPressed: () => _select(HomeDest.notifications),
          icon: Icon(GIcons.notifications, color: _selected == HomeDest.notifications ? c.brand : c.textSecondary),
        ),
      const SizedBox(width: Gsp.sp1),
      _ProfileMenu(
        name: widget.userName,
        role: widget.role,
        version: widget.version,
        photoUrl: widget.photoUrl,
        onEditPhoto: widget.onEditPhoto,
        onSettings: () => _select(HomeDest.settings),
        onSupport: widget.onSupport,
        onRoleSimulator: widget.onRoleSimulator,
        onDataIntegrity: widget.onDataIntegrity,
        onLogout: widget.onLogout,
      ),
    ];
  }
}

// ── Top bar ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.menuTooltip,
    required this.onMenu,
    required this.searchCtrl,
    required this.onSearch,
    required this.compactSearch,
    required this.actions,
  });

  final String title;
  final String subtitle;

  /// Leading button: opens the drawer on phones, collapses/expands the sidebar elsewhere.
  final String menuTooltip;
  final VoidCallback? onMenu;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;
  final bool compactSearch;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final search = SizedBox(
      height: 38,
      child: TextField(
        controller: searchCtrl,
        onChanged: onSearch,
        style: GText.body2(c.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search modules',
          hintStyle: GText.body2(c.textMuted),
          prefixIcon: Icon(GIcons.search, size: GIconSize.md, color: c.textMuted),
          suffixIcon: ListenableBuilder(
            listenable: searchCtrl,
            builder: (context, _) => searchCtrl.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear',
                    icon: Icon(GIcons.close, size: GIconSize.sm, color: c.textMuted),
                    onPressed: () {
                      searchCtrl.clear();
                      onSearch('');
                    },
                  ),
          ),
          filled: true,
          fillColor: c.surfaceSunken,
          contentPadding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
          border: OutlineInputBorder(borderRadius: Gr.input, borderSide: BorderSide(color: c.border)),
          enabledBorder: OutlineInputBorder(borderRadius: Gr.input, borderSide: BorderSide(color: c.border)),
          focusedBorder: OutlineInputBorder(borderRadius: Gr.input, borderSide: BorderSide(color: c.brand, width: 1.5)),
        ),
      ),
    );

    final head = Row(children: [
      if (onMenu != null) ...[
        Tooltip(
          message: menuTooltip,
          child: Material(
            color: c.surfaceSunken,
            shape: RoundedRectangleBorder(borderRadius: Gr.button, side: BorderSide(color: c.border)),
            child: InkWell(
              borderRadius: Gr.button,
              onTap: onMenu,
              child: SizedBox(width: 38, height: 38, child: Icon(GIcons.menu, size: GIconSize.md, color: c.textSecondary)),
            ),
          ),
        ),
        const SizedBox(width: Gsp.sp3),
      ],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: GText.h3(c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(subtitle, style: GText.caption(c.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
      if (!compactSearch) ...[const SizedBox(width: Gsp.sp4), SizedBox(width: 300, child: search)],
      const SizedBox(width: Gsp.sp2),
      ...actions,
    ]);

    return Container(
      padding: const EdgeInsets.fromLTRB(Gsp.sp4, Gsp.sp3, Gsp.sp4, Gsp.sp3),
      decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.border))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        head,
        if (compactSearch) ...[
          const SizedBox(height: Gsp.sp3),
          search,
        ],
      ]),
    );
  }
}

// ── Avatar ──────────────────────────────────────────────────────────────────

// Profile photos are stored as base64, a local file path or a URL. Memoised:
// decoding base64 on every build re-created the MemoryImage and re-decoded it.
String? _photoSrc;
ImageProvider? _photoProvider;

ImageProvider? _resolvePhoto(String raw) {
  final s = raw.trim();
  if (s == _photoSrc) return _photoProvider;
  _photoSrc = s;
  ImageProvider? p;
  if (s.isNotEmpty) {
    final bytes = ImageUploadService.decodeBase64ToBytes(s);
    if (bytes != null) {
      p = MemoryImage(bytes);
    } else if (s.startsWith('http://') || s.startsWith('https://')) {
      p = NetworkImage(s);
    } else if (!kIsWeb && File(s).existsSync()) {
      p = FileImage(File(s));
    }
  }
  _photoProvider = p == null ? null : ResizeImage(p, width: 160, policy: ResizeImagePolicy.fit);
  return _photoProvider;
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.photoUrl, this.size = 36, this.onSidebar = false});

  final String name;
  final String photoUrl;
  final double size;
  final bool onSidebar;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bg = onSidebar ? c.sidebarActiveLine : c.brand;
    final fg = onSidebar ? c.sidebarBg : c.onBrand;
    final photo = _resolvePhoto(photoUrl);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: bg,
      foregroundImage: photo,
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(_initials, style: GText.label(fg)),
    );
  }
}

// ── Sidebar footer: who is signed in ────────────────────────────────────────

class _SidebarUserCard extends StatelessWidget {
  const _SidebarUserCard({
    required this.name,
    required this.role,
    required this.branch,
    required this.photoUrl,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.onOpen,
    this.selected = false,
  });

  final String name;
  final String role;
  final String branch;
  final String photoUrl;
  final bool collapsed;
  final VoidCallback? onToggleCollapse;

  /// Opens Account settings.
  final VoidCallback onOpen;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return LayoutBuilder(builder: (context, box) {
      final avatar = _Avatar(name: name, photoUrl: photoUrl, onSidebar: true);
      final border = selected ? c.sidebarActiveLine : c.sidebarBorder;
      final fill = selected ? c.sidebarActiveBg : c.sidebarTextActive.withValues(alpha: 0.06);

      if (box.maxWidth < 150) {
        // Rail: avatar opens account settings, expand icon sits right under it.
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Tooltip(
            message: 'Account settings · $name',
            child: Material(
              color: Colors.transparent,
              shape: CircleBorder(side: BorderSide(color: border, width: selected ? 2 : 1)),
              child: InkWell(customBorder: const CircleBorder(), onTap: onOpen, child: Padding(padding: const EdgeInsets.all(2), child: avatar)),
            ),
          ),
          if (onToggleCollapse != null) ...[
            const SizedBox(height: Gsp.sp2),
            _SidebarCollapseButton(
              collapsed: collapsed,
              onTap: onToggleCollapse!,
              width: 40,
              height: 36,
            ),
          ],
        ]);
      }

      return Row(children: [
        Expanded(
          child: Tooltip(
            message: 'Account settings',
            waitDuration: GMotion.slow,
            child: Material(
              color: fill,
              shape: RoundedRectangleBorder(borderRadius: Gr.card, side: BorderSide(color: border)),
              child: InkWell(
                borderRadius: Gr.card,
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.all(Gsp.sp3),
                  child: Row(children: [
                    avatar,
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(name, style: GText.body2Bold(c.sidebarTextActive), maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('${_title(role)} · $branch', style: GText.caption(c.sidebarText), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    Icon(GIcons.settings, size: GIconSize.sm, color: selected ? c.sidebarActiveLine : c.sidebarText),
                  ]),
                ),
              ),
            ),
          ),
        ),
        if (onToggleCollapse != null) ...[
          const SizedBox(width: Gsp.sp2),
          _SidebarCollapseButton(
            collapsed: collapsed,
            onTap: onToggleCollapse!,
            width: 44,
            height: 62,
          ),
        ],
      ]);
    });
  }
}

/// Collapse / expand toggle button sitting beside the sidebar user card.
class _SidebarCollapseButton extends StatefulWidget {
  const _SidebarCollapseButton({
    required this.collapsed,
    required this.onTap,
    required this.width,
    required this.height,
  });

  final bool collapsed;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  State<_SidebarCollapseButton> createState() => _SidebarCollapseButtonState();
}

class _SidebarCollapseButtonState extends State<_SidebarCollapseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Tooltip(
      message: widget.collapsed ? 'Expand sidebar' : 'Collapse sidebar',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: GMotion.fast,
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: _hover ? c.sidebarActiveBg : c.sidebarTextActive.withValues(alpha: 0.06),
              borderRadius: Gr.card,
              border: Border.all(
                color: _hover ? c.sidebarActiveLine : c.sidebarBorder,
              ),
            ),
            child: Icon(
              widget.collapsed ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
              size: GIconSize.md,
              color: _hover ? c.sidebarActiveLine : c.sidebarTextActive,
            ),
          ),
        ),
      ),
    );
  }
}

String _title(String role) => role
    .split(RegExp(r'[\s_]+'))
    .where((p) => p.isNotEmpty)
    .map((p) => p.length <= 3 && p == 'ceo' ? 'CEO' : p == 'hq' ? 'HQ' : '${p[0].toUpperCase()}${p.substring(1)}')
    .join(' ');

// ── Profile menu ────────────────────────────────────────────────────────────

enum _ProfileAction { photo, settings, simulator, integrity, support, logout }

class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu({
    required this.name,
    required this.role,
    required this.version,
    required this.photoUrl,
    required this.onSettings,
    required this.onSupport,
    required this.onLogout,
    this.onRoleSimulator,
    this.onDataIntegrity,
    this.onEditPhoto,
  });

  final String name;
  final String role;
  final String version;
  final String photoUrl;
  final VoidCallback? onEditPhoto;
  final VoidCallback onSettings;
  final VoidCallback onSupport;
  final VoidCallback onLogout;
  final VoidCallback? onRoleSimulator;
  final VoidCallback? onDataIntegrity;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    PopupMenuItem<_ProfileAction> item(_ProfileAction v, IconData icon, String label, {bool danger = false}) => PopupMenuItem(
          value: v,
          child: Row(children: [
            Icon(icon, size: GIconSize.md, color: danger ? c.danger : c.textSecondary),
            const SizedBox(width: Gsp.sp3),
            Text(label, style: GText.body2(danger ? c.danger : c.textPrimary)),
          ]),
        );

    return PopupMenuButton<_ProfileAction>(
      tooltip: 'Account',
      position: PopupMenuPosition.under,
      offset: const Offset(0, Gsp.sp2),
      onSelected: (a) => switch (a) {
        _ProfileAction.photo => onEditPhoto?.call(),
        _ProfileAction.settings => onSettings(),
        _ProfileAction.simulator => onRoleSimulator?.call(),
        _ProfileAction.integrity => onDataIntegrity?.call(),
        _ProfileAction.support => onSupport(),
        _ProfileAction.logout => onLogout(),
      },
      itemBuilder: (context) => [
        PopupMenuItem<_ProfileAction>(
          enabled: false,
          child: Row(children: [
            _Avatar(name: name, photoUrl: photoUrl, size: 40),
            const SizedBox(width: Gsp.sp3),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(name, style: GText.body2Bold(c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${_title(role)} · v$version', style: GText.caption(c.textMuted)),
              ]),
            ),
          ]),
        ),
        const PopupMenuDivider(),
        if (onEditPhoto != null) item(_ProfileAction.photo, GIcons.profile, 'Profile photo'),
        item(_ProfileAction.settings, GIcons.settings, 'Account settings'),
        if (onRoleSimulator != null) item(_ProfileAction.simulator, GIcons.visibility, 'Role simulator'),
        if (onDataIntegrity != null) item(_ProfileAction.integrity, GIcons.shield, 'Data integrity'),
        item(_ProfileAction.support, GIcons.info, 'Support'),
        const PopupMenuDivider(),
        item(_ProfileAction.logout, GIcons.logout, 'Sign out', danger: true),
      ],
      child: Padding(
        padding: const EdgeInsets.all(Gsp.sp1),
        child: _Avatar(name: name, photoUrl: photoUrl, size: 34),
      ),
    );
  }
}

// ── Executive Branch Selector Pill ───────────────────────────────────────────

class _BranchSelectorPill extends StatelessWidget {
  final String selectedBranchId;
  final List<Map<String, String>> availableBranches;
  final ValueChanged<String>? onChanged;

  const _BranchSelectorPill({
    required this.selectedBranchId,
    required this.availableBranches,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final current = availableBranches.firstWhere(
      (b) => b['id']?.toLowerCase() == selectedBranchId.toLowerCase(),
      orElse: () => {'id': selectedBranchId, 'name': selectedBranchId == 'all' ? 'All Branches' : selectedBranchId},
    );
    final displayName = current['name'] ?? current['id'] ?? 'All Branches';

    return PopupMenuButton<String>(
      tooltip: 'Switch Branch View',
      position: PopupMenuPosition.under,
      offset: const Offset(0, Gsp.sp2),
      onSelected: (id) => onChanged?.call(id),
      itemBuilder: (context) => availableBranches.map((b) {
        final bId = b['id'] ?? '';
        final bName = b['name'] ?? bId;
        final isSel = bId.toLowerCase() == selectedBranchId.toLowerCase();
        return PopupMenuItem<String>(
          value: bId,
          child: Row(
            children: [
              Icon(
                bId == 'all' ? Icons.public_rounded : Icons.storefront_rounded,
                size: 16,
                color: isSel ? c.brand : c.textSecondary,
              ),
              const SizedBox(width: Gsp.sp3),
              Expanded(
                child: Text(
                  bName,
                  style: GText.body2(isSel ? c.brand : c.textPrimary).copyWith(
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (isSel)
                Icon(Icons.check_rounded, size: 16, color: c.brand),
            ],
          ),
        );
      }).toList(),
      child: Material(
        color: c.surfaceSunken,
        shape: RoundedRectangleBorder(
          borderRadius: Gr.button,
          side: BorderSide(color: c.border),
        ),
        child: InkWell(
          borderRadius: Gr.button,
          onTap: null, // PopupMenuButton handles tap
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selectedBranchId == 'all' ? Icons.public_rounded : Icons.storefront_rounded,
                  size: 16,
                  color: c.brand,
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GText.body2Bold(c.textPrimary),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

