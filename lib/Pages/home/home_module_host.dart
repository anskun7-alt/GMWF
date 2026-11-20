// lib/pages/home/home_module_host.dart
//
// Shows a module INSIDE the home shell (sidebar and top bar stay), instead of
// pushing it as a full-screen route.
//
// The module gets its own nested Navigator:
//   • pages it pushes (details, forms) open inside the content area too;
//   • when it pops its first page (its own back button), the host reports
//     [onClosed] and the shell goes back to where the user was, instead of
//     popping the whole app.
// Dialogs and sheets still use the root navigator, as before.

import 'package:flutter/material.dart';

class HomeModuleHost extends StatefulWidget {
  const HomeModuleHost({
    super.key,
    required this.child,
    required this.theme,
    required this.onClosed,
  });

  /// The module page, already built (wrapper or plain builder).
  final Widget child;

  /// The app's own theme: modules are not on gmwf_ui yet.
  final ThemeData theme;
  final VoidCallback onClosed;

  /// True when [context] is on the root route of a module hosted inside
  /// HomeShell (where the sidebar handles navigation, so a back button is
  /// redundant—unlike pushed sub-pages inside the module).
  static bool isModuleRoot(BuildContext context) =>
      ModalRoute.of(context)?.settings.name == 'module';

  @override
  State<HomeModuleHost> createState() => _HomeModuleHostState();
}

class _HomeModuleHostState extends State<HomeModuleHost> {
  final _navKey = GlobalKey<NavigatorState>();
  late final _watcher = _PopWatcher(onBaseReached: () => widget.onClosed());

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: widget.theme,
      // Android back / Esc-style system pops go to the module first.
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _navKey.currentState?.maybePop();
        },
        child: ClipRect(
          child: Navigator(
            key: _navKey,
            observers: [_watcher, HeroController()],
            onGenerateInitialRoutes: (_, _) => [
              // Invisible base: popping the module lands here, which closes it.
              PageRouteBuilder<void>(
                settings: const RouteSettings(name: _PopWatcher.base),
                pageBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              PageRouteBuilder<void>(
                settings: const RouteSettings(name: 'module'),
                transitionDuration: Duration.zero,
                pageBuilder: (_, _, _) => widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopWatcher extends NavigatorObserver {
  _PopWatcher({required this.onBaseReached});

  static const base = '__home_base__';
  final VoidCallback onBaseReached;

  void _check(Route<dynamic>? top) {
    if (top?.settings.name == base) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onBaseReached());
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _check(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _check(previousRoute);
}
