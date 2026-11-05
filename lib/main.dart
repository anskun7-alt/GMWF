// lib/main.dart
import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:gmwf/design/theme/gmwf_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'constants/colors.dart';

import 'firebase_options.dart';

import 'pages/login_page.dart';
import 'pages/home_router.dart';
import 'pages/overview.dart';
import 'pages/dispensary/dispensar/dispensar_screen.dart';
import 'pages/dispensary/dispensar/inventory.dart';
import 'pages/donations/donations_screen.dart';

import 'services/local_storage_service.dart';
import 'services/donations_local_storage.dart';
import 'services/camp_session_service.dart';
import 'services/offline_auth_service.dart' as offline_auth;
import 'services/zkteco_network_service.dart';
import 'services/python_runner_service.dart';
import 'realtime/realtime_router.dart';
import 'services/cloud_messaging_service.dart';
import 'services/user_theme_service.dart';
import 'services/auth_service.dart';
import 'widgets/gmwf_loading_view.dart';
import 'widgets/custom_title_bar.dart';
import 'tools/finance_v2_migration.dart';
import 'services/auto_update_service.dart';
import 'services/hidden_force_uploader.dart';
import 'services/quota_service.dart';
import 'services/sync_service.dart';
import 'services/background_sync_service.dart';
import 'package:workmanager/workmanager.dart';
import 'widgets/self_healing_error_boundary.dart';
import 'widgets/blurred_dialog_observer.dart';
import 'utils/ui_stall_monitor.dart';
import 'widgets/busy_status_host.dart';
import 'constants/navigator_key.dart';

class TimestampAdapter extends TypeAdapter<Timestamp> {
  @override
  final int typeId = 100;

  @override
  Timestamp read(BinaryReader reader) {
    final seconds = reader.readInt();
    final nanoseconds = reader.readInt();
    return Timestamp(seconds, nanoseconds);
  }

  @override
  void write(BinaryWriter writer, Timestamp obj) {
    writer.writeInt(obj.seconds);
    writer.writeInt(obj.nanoseconds);
  }
}

/// WorkManager entry point for the Android background upload (BackgroundSyncService).
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) => BackgroundSyncService.runJob(
        registerHiveAdapters: () {
          if (!Hive.isAdapterRegistered(100)) Hive.registerAdapter(TimestampAdapter());
        },
      ));
}

int _errorLogCountInWindow = 0;
DateTime? _errorLogWindowStart;

Future<void> _logError(String message, [String? stack]) async {
  if (kIsWeb) return;
  try {
    // Rate-limit error writes: max 5 writes per 10 seconds to protect CPU/Disk
    final now = DateTime.now();
    if (_errorLogWindowStart == null || now.difference(_errorLogWindowStart!).inSeconds > 10) {
      _errorLogWindowStart = now;
      _errorLogCountInWindow = 0;
    }
    _errorLogCountInWindow++;
    if (_errorLogCountInWindow > 5) return;

    final dir = await getApplicationSupportDirectory();
    final logFile = File(path.join(dir.path, 'gmwf_crash.log'));

    // Rotate/truncate if log file exceeds 2 MB to prevent massive disk bloat
    if (await logFile.exists()) {
      final len = await logFile.length();
      if (len > 2 * 1024 * 1024) {
        await logFile.writeAsString('[${now.toIso8601String()}] --- Log Rotated (Previous log exceeded 2MB) ---\n');
      }
    }

    final timestamp = now.toIso8601String();
    final entry = '[$timestamp] ERROR: $message\nSTACK: ${stack ?? ''}\n\n';
    await logFile.writeAsString(entry, mode: FileMode.append);
  } catch (_) {}
}

Future<void> _markLastCrash() async {
  if (kIsWeb) return;
  try {
    final dir = await getApplicationSupportDirectory();
    final crashMarker = File(path.join(dir.path, '.last_crash'));
    await crashMarker.writeAsString(DateTime.now().toIso8601String());
  } catch (e) {
    debugPrint("Failed to write crash marker: $e");
  }
}

Future<void> _clearCrashMarkerOnSuccess() async {
  if (kIsWeb) return;
  try {
    final dir = await getApplicationSupportDirectory();
    final crashMarker = File(path.join(dir.path, '.last_crash'));
    if (await crashMarker.exists()) {
      await crashMarker.delete();
      debugPrint("Crash marker cleared — normal startup confirmed.");
    }
  } catch (e) {
    debugPrint("Failed to clear crash marker: $e");
  }
}

bool _isIgnoredTransientError(String errStr) {
  final lower = errStr.toLowerCase();
  return lower.contains('overflowed') ||
      lower.contains('renderbox was not laid out') ||
      lower.contains('hassize') ||
      lower.contains('_needslayout') ||
      lower.contains('needs-paint') ||
      lower.contains('_debugdoingthislayout') ||
      lower.contains('parentdatadirty') ||
      lower.contains('childsemantics') ||
      lower.contains('deactivated widget') ||
      lower.contains('ancestor is unsafe') ||
      lower.contains('rawkeydownevent') ||
      lower.contains('keyspressed') ||
      lower.contains('networkmanager::startlisten') ||
      lower.contains('widgetinspector') ||
      lower.contains('websocketchannelexception') ||
      lower.contains('socketexception') ||
      lower.contains('refused the network connection') ||
      lower.contains('connection refused') ||
      lower.contains('errno = 1225');
}

void _installGlobalErrorHandlers() {
  // Self-Healing ErrorWidget: replaces Flutter's default blank grey/white screen with auto-recovery UI
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return SelfHealingErrorView(details: details);
  };

  FlutterError.onError = (FlutterErrorDetails details) {
    final exStr = details.exceptionAsString();
    if (_isIgnoredTransientError(exStr)) return;

    FlutterError.presentError(details);
    _logError(exStr, details.stack?.toString());
    _markLastCrash();
    try {
      Sentry.captureException(details.exception, stackTrace: details.stack);
    } catch (_) {}
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    final errStr = error.toString();
    if (_isIgnoredTransientError(errStr)) return true;

    _logError(errStr, stack.toString());
    _markLastCrash();
    try {
      Sentry.captureException(error, stackTrace: stack);
    } catch (_) {}
    return true;
  };
}

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  // Clamp image cache memory limits to avoid holding massive uncompressed bitmaps in RAM
  PaintingBinding.instance.imageCache.maximumSizeBytes = 35 * 1024 * 1024; // 35 MB max decoded image cache
  PaintingBinding.instance.imageCache.maximumSize = 100; // max 100 images
  // Release builds have no console to read: the ~1,600 debugPrint calls only fed Flutter's
  // throttled print queue (timers and string work on the UI thread). What matters at a
  // clinic is written to gmwf_sync.log / gmwf_perf.log / gmwf_crash.log instead.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // Native splash screens only exist on Android & iOS.
  // Calling preserve on Desktop causes widgetsBinding.deferFirstFrame() to block
  // rasterization, turning the desktop window into a frozen white box.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    try {
      FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
    } catch (_) {}
  }
  _installGlobalErrorHandlers();

  // Configure desktop window properties but defer appWindow.show() until
  // the first frame is actually painted in MyApp to prevent the blank white window.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    try {
      doWhenWindowReady(() {
        appWindow.minSize = const Size(1280, 720);
        appWindow.alignment = Alignment.center;
        appWindow.title = "Gulzar Madina Welfare Foundation";
        _MyAppState.onWindowReady();
      });
    } catch (e) {
      debugPrint('[Main] Window ready error: $e');
    }
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = 'https://1decf155927c0b93fcbc40447bb21a12@o4511376159014912.ingest.de.sentry.io/4511376169631824';
      // 5% of transactions: tracing every one cost CPU and network on every navigation.
      options.tracesSampleRate = 0.05;
      options.environment = 'production';
    },
    appRunner: () async {
      // Firebase starts in parallel with Hive and never gates it. It used to run first with a
      // 1.5 s timeout whose fallback called Firebase.app(), which throws while the app is still
      // initialising: on a slow cold start that skipped every Hive/storage init below and the
      // app ran with no local data ("You need to initialize Hive" on login, endless loading).
      final firebaseInit = Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
          .then<bool>((_) => true)
          .catchError((Object e) {
        debugPrint('[Main] Firebase init warning: $e');
        _logError('Firebase init failed: $e');
        return false;
      });
      try {
        if (kIsWeb) {
          await Hive.initFlutter();
        } else if (Platform.isWindows) {
          final appSupportDir = await getApplicationSupportDirectory();
          final hiveDir = path.join(appSupportDir.path, 'gmwf_hive');
          LocalStorageService.setHiveDirectoryPath(hiveDir);
          await Hive.initFlutter(hiveDir);
        } else {
          // A background upload job may hold the boxes right now (app was closed); let it finish.
          await BackgroundSyncService.waitForBackgroundJob();
          final appSupportDir = await getApplicationSupportDirectory();
          LocalStorageService.setHiveDirectoryPath(appSupportDir.path);
          await Hive.initFlutter();
        }
        Hive.registerAdapter(TimestampAdapter());
        // Before any box opens: a LAN queue file that grew huge is rebuilt in the background
        // instead of being decoded on the UI thread (35–70 s frozen at start on a Karachi PC).
        LocalStorageService.startOversizedQueueRepairs();

        try {
          await Hive.openBox('app_settings');
          UserThemeService.init();
        } catch (hiveErr) {
          debugPrint('[Main] Hive app_settings box error: $hiveErr');
        }

        await Future.wait<dynamic>([
          LocalStorageService.init(),
          DonationsLocalStorage.init(),
          RealtimeRouter.init(),
        ]).timeout(const Duration(seconds: 2), onTimeout: () {
          debugPrint('[Main] Core storage init reached 2s safety limit — proceeding to launch UI');
          return <dynamic>[];
        }).catchError((e) {
          debugPrint('[Main] Non-critical service init warning: $e');
          return <dynamic>[];
        });

        // Firebase set-up is local (no network). Services below use it; if it is still not
        // done the app opens anyway and Firebase finishes in the background.
        await firebaseInit.timeout(const Duration(seconds: 6), onTimeout: () {
          _logError('Firebase init still running after startup wait — opening the app anyway');
          return false;
        });

        await CampSessionService.clearServerOffset();
        CampSessionService.checkClockSkew();
        unawaited(CampSessionService.syncInternetTime());

        // Opens local_users (can be tens of MB): bounded so a slow decode never holds the window.
        await LocalStorageService.seedLocalAdmins().timeout(const Duration(seconds: 3), onTimeout: () {
          debugPrint('[Main] Local admin seeding still running — continuing in background');
        }).catchError((Object e) => debugPrint('[Main] Local admin seeding warning: $e'));
        await _clearCrashMarkerOnSuccess();
        AuthService.onSignOutCallback = AuthHomeWrapper.clearSession;

        // Load dynamic version from pubspec via package_info (max 400ms)
        await AutoUpdateService.getAppVersion().timeout(const Duration(milliseconds: 400), onTimeout: () => '1.6.4');
        unawaited(CloudMessagingService().initialize().catchError((e) {
          debugPrint('[Init] CloudMessagingService init warning: $e');
        }));
        // Android: keep uploading queued records about every 15 min, also when the app is closed.
        unawaited(BackgroundSyncService.init(backgroundSyncDispatcher));

        if (!kIsWeb) {
          unawaited(ZkTecoNetworkService.startServer().catchError((e) {
            debugPrint('[Init] ZKTeco background server start error: $e');
            return false;
          }));

          unawaited(PythonRunnerService.instance.initAutoStart().catchError((e) {
            debugPrint('[Init] Python background sync auto-start warning: $e');
            return false;
          }));
        }

        unawaited(_runBackgroundCleanups());
      } catch (e, st) {
        debugPrint('[Main] Pre-init error caught safely: $e');
        _logError('Pre-init error: $e', st.toString());
      }

      // Memory optimization: clamp image cache to 25MB to prevent unbounded RAM bloat
      try {
        PaintingBinding.instance.imageCache.maximumSize = 100;
        PaintingBinding.instance.imageCache.maximumSizeBytes = 25 * 1024 * 1024;
      } catch (_) {}

      try {
        FlutterNativeSplash.remove();
      } catch (_) {}

      runApp(const ProviderScope(child: MyApp()));
      UiStallMonitor.start();
    },
  );
}

Future<void> _runBackgroundCleanups() async {
  try {
    // 💡 Defer background cleanups until 30 seconds after launch.
    // This ensures login, initial screen painting, navigation, and animations complete
    // with zero main-thread contention, eliminating the "(Not Responding)" startup hang.
    await Future.delayed(const Duration(seconds: 30));

    // Each clean-up runs only where this PC's role uses the boxes it goes through: on a
    // madrassa or kitchen PC they would open (decode) the dispensary's and finance's files.
    if (LocalStorageService.roleUsesBox(LocalStorageService.salaryLedgerBox)) {
      await FinanceV2Migration.runMigration();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final clinical = LocalStorageService.roleUsesBox(LocalStorageService.entriesBox);
    if (clinical) {
      await LocalStorageService.forceDeduplicatePatients();
      await Future.delayed(const Duration(milliseconds: 300));

      await LocalStorageService.repairMisassignedShiftSessions();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    await LocalStorageService.repairAndSanitizeLocalAccounts();
    await Future.delayed(const Duration(milliseconds: 300));

    if (clinical) {
      await LocalStorageService.purgePhantomUnknownTokens();
      await Future.delayed(const Duration(milliseconds: 300));

      await LocalStorageService.healAndRestorePatientCnics();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    await LocalStorageService.purgeBloatedSyncQueue();
    await Future.delayed(const Duration(milliseconds: 300));

    // Corrupted-box backups are full copies of a box; keep the newest two per box.
    await LocalStorageService.pruneAllBoxBackups();
    await Future.delayed(const Duration(milliseconds: 300));

    // Tokens carried prescriptions nested inside prescriptions (the bulk of local_entries);
    // flatten them, then compact boxes that are mostly dead space.
    await LocalStorageService.healNestedPrescriptions();
    await Future.delayed(const Duration(milliseconds: 300));
    await LocalStorageService.compactBloatedBoxes();
    await Future.delayed(const Duration(milliseconds: 300));

    if (Hive.isBoxOpen(DonationsLocalStorage.donationsBox)) {
      final box = Hive.box(DonationsLocalStorage.donationsBox);
      final nestedKeys = box.keys.where((k) => k.toString().split('__').length > 3).toList();
      if (nestedKeys.isNotEmpty) {
        await box.deleteAll(nestedKeys);
        await box.flush();
      }
    }
  } catch (cleanupErr) {
    debugPrint('[CLEANUP] Error during background cleanup: $cleanupErr');
  }
}

// ── Main App ──────────────────────────────────────────────────────────────────

/// Global controller for hard-refreshing the application instance (Ctrl+Shift+R / Ctrl+R / F5 on desktop).
class AppRestartController {
  static final ValueNotifier<int> restartNotifier = ValueNotifier<int>(0);

  static void refreshApp() {
    debugPrint('[Main] 🔄 Hard Refresh (Ctrl+Shift+R / Ctrl+R / F5) triggered!');
    QuotaService.resetState();
    unawaited(SyncService().broadcastUniversalForceUpload());
    AuthHomeWrapper.clearSession();
    // Non-blocking background sync of authoritative users from cloud/server
    unawaited(LocalStorageService.downloadUsers().catchError((e) {
      debugPrint('[Main] Refresh user sync notice: $e');
    }));
    restartNotifier.value++;
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/home', (r) => false);
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  AppLifecycleListener? _lifecycleListener;
  static bool _windowReady = false;
  static bool _firstFrameRendered = false;
  static bool _desktopWindowRevealed = false;

  static void onWindowReady() {
    _windowReady = true;
    _tryRevealDesktopWindow();
  }

  static void _tryRevealDesktopWindow() {
    if (_desktopWindowRevealed) return;
    if (!_windowReady || !_firstFrameRendered) return;
    _desktopWindowRevealed = true;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        appWindow.show();
        debugPrint('[Main] 🪟 Desktop window revealed smoothly on first paint');
      } catch (e) {
        debugPrint('[Main] Desktop window reveal warning: $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    if (!kIsWeb) {
      _lifecycleListener = AppLifecycleListener(
        onDetach: () {
          PythonRunnerService.instance.stopProcess();
        },
        onExitRequested: () async {
          await PythonRunnerService.instance.stopProcess();
          return AppExitResponse.exit;
        },
      );
    }

    // Reveal the desktop window as soon as Flutter renders the first painted frame!
    // This completely eliminates the blank white window and startup freezes on Windows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _firstFrameRendered = true;
      _tryRevealDesktopWindow();
    });

    // Safety fallback: Ensure window is revealed even if first frame callback takes longer
    Timer(const Duration(milliseconds: 1200), () {
      _firstFrameRendered = true;
      _tryRevealDesktopWindow();
    });

    // Desktop maximize fallback: Ensure window maximizes even if router transition is delayed
    if (!kIsWeb && Platform.isWindows) {
      Timer(const Duration(milliseconds: 2500), () {
        try {
          if (!appWindow.isMaximized) appWindow.maximize();
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    if (!kIsWeb) {
      _lifecycleListener?.dispose();
      PythonRunnerService.instance.stopProcess();
    }
    super.dispose();
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      final isR = event.logicalKey == LogicalKeyboardKey.keyR;
      final isU = event.logicalKey == LogicalKeyboardKey.keyU;
      final isF5 = event.logicalKey == LogicalKeyboardKey.f5;

      // Hidden silent upload trigger: Ctrl + Shift + U
      if (isCtrl && isShift && isU) {
        QuotaService.resetState();
        HiddenForceUploader.instance.runSilentForceUpload();
        return true;
      }

      // Intercept Ctrl+Shift+R, Ctrl+R, or F5 on desktop
      if ((isCtrl && isR) || isF5) {
        final shortcutName = isCtrl && isShift && isR
            ? 'Ctrl+Shift+R'
            : isCtrl && isR
                ? 'Ctrl+R'
                : 'F5';
        debugPrint('[MyApp] 🔄 Keyboard shortcut $shortcutName detected. Triggering hard app refresh.');
        AppRestartController.refreshApp();
        return true;
      }
    }
    return false;
  }

  // The whole Material theme lives in the design system (GTheme); main only
  // supplies the user's accent, card roundness and the blur-aware transitions.
  ThemeData _buildThemeData({
    required Color seedColor,
    required double cardRadius,
    required Brightness brightness,
  }) {
    return GTheme.build(
      seedColor: seedColor,
      cardRadius: cardRadius,
      brightness: brightness,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: BlurOnDialogPageTransitionsBuilder(CupertinoPageTransitionsBuilder()),
          TargetPlatform.iOS: BlurOnDialogPageTransitionsBuilder(CupertinoPageTransitionsBuilder()),
          TargetPlatform.windows: BlurOnDialogPageTransitionsBuilder(FadeUpwardsPageTransitionsBuilder()),
          TargetPlatform.linux: BlurOnDialogPageTransitionsBuilder(FadeUpwardsPageTransitionsBuilder()),
          TargetPlatform.macOS: BlurOnDialogPageTransitionsBuilder(FadeUpwardsPageTransitionsBuilder()),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppRestartController.restartNotifier,
      builder: (context, restartIndex, _) {
        return KeyedSubtree(
          key: ValueKey('gmwf_root_instance_$restartIndex'),
          child: !Hive.isBoxOpen('app_settings')
              ? MaterialApp(
                  navigatorKey: navigatorKey,
                  navigatorObservers: [DialogBlurManager.instance],
                  title: 'GMWF',
                  debugShowCheckedModeBanner: false,
                  theme: _buildThemeData(
                    seedColor: AppColors.primary,
                    cardRadius: 16.0,
                    brightness: Brightness.light,
                  ),
                  routes: {
                    '/home': (context) => const AuthHomeWrapper(),
                    '/login': (context) => const LoginPage(),
                  },
                  builder: (context, child) => Stack(
                    fit: StackFit.expand,
                    children: [child ?? const SizedBox.shrink(), const BusyStatusHost(), const AppToastHost()],
                  ),
                  home: const AuthHomeWrapper(),
                )
              : ValueListenableBuilder(
                  valueListenable: Hive.box('app_settings').listenable(keys: [
                    'custom_accent_color',
                    'card_radius',
                    'is_dark_mode',
                    'language',
                    'font_scale',
                  ]),
                  builder: (context, Box box, _) {
                    final colorHex = box.get('custom_accent_color') as String?;

                    Color seedColor = AppColors.primary;
                    if (colorHex != null && colorHex.isNotEmpty) {
                      try {
                        final hex = colorHex.replaceAll('#', '');
                        seedColor = Color(int.parse('FF$hex', radix: 16));
                      } catch (_) {}
                    }

                    final cardRadius = (box.get('card_radius', defaultValue: 16.0) as num).toDouble();
                    final isDarkMode = UserThemeService.isDarkMode();
                    final language = box.get('language', defaultValue: 'en') as String;
                    final isUrdu = language == 'ur';

                    return MaterialApp(
                      navigatorKey: navigatorKey,
                      navigatorObservers: [DialogBlurManager.instance],
                      title: 'GMWF',
                      debugShowCheckedModeBanner: false,
                      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
                      locale: Locale(language),
                      theme: _buildThemeData(
                        seedColor: seedColor,
                        cardRadius: cardRadius,
                        brightness: Brightness.light,
                      ),
                      darkTheme: _buildThemeData(
                        seedColor: seedColor,
                        cardRadius: cardRadius,
                        brightness: Brightness.dark,
                      ),
                      builder: (context, child) {
                        final mediaQuery = MediaQuery.of(context);
                        final scale = (box.get('font_scale', defaultValue: 1.0) as num).toDouble();

                        final appDirection = isUrdu ? TextDirection.rtl : TextDirection.ltr;
                        final appMediaQuery = mediaQuery.copyWith(
                          textScaler: TextScaler.linear(scale),
                        );

                        final adjustedChild = CallbackShortcuts(
                          bindings: <ShortcutActivator, VoidCallback>{
                            const SingleActivator(LogicalKeyboardKey.keyU, control: true, shift: true): () {
                              QuotaService.resetState();
                              HiddenForceUploader.instance.runSilentForceUpload();
                            },
                            const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true): () {
                              AppRestartController.refreshApp();
                            },
                            // Preview every notification style (works on any screen).
                            const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): AppToast.demo,
                            const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
                              AppRestartController.refreshApp();
                            },
                            const SingleActivator(LogicalKeyboardKey.f5): () {
                              AppRestartController.refreshApp();
                            },
                          },
                          child: Focus(
                            autofocus: true,
                            child: MediaQuery(
                              data: appMediaQuery,
                              child: Directionality(
                                textDirection: appDirection,
                                // App-wide toasts sit above every route and dialog.
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    child ?? const SizedBox.shrink(),
                                    // "What is the app doing" status, so busy moments are explained.
                                    const BusyStatusHost(),
                                    const AppToastHost(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );

                        if (!kIsWeb && Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST')) {
                          return Material(
                            color: isDarkMode ? SoftPalette.slate900 : SoftPalette.slate100,
                            child: Column(
                              children: [
                                const CustomTitleBar(),
                                Expanded(child: ClipRect(child: adjustedChild)),
                              ],
                            ),
                          );
                        }
                        return adjustedChild;
                      },
                      home: const AuthHomeWrapper(),
                      onUnknownRoute: (settings) {
                        return MaterialPageRoute(
                          builder: (context) => const AuthHomeWrapper(),
                        );
                      },
                      routes: {
                        '/home': (context) => const AuthHomeWrapper(),
                        '/login': (context) => const LoginPage(),
                        '/admin': (context) => const OverviewScreen(),
                        '/chairman': (context) => const OverviewScreen(),
                        '/donations': (context) => const DonationsScreen.embedded(),
                        '/dispensar': (context) {
                          final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
                          return DispensarScreen(
                            branchId: args?['branchId'] ?? 'unknown',
                            dispenserId: args?['dispenserId'] ?? args?['uid'],
                            dispenserName: args?['dispenserName'] ?? args?['name'],
                          );
                        },
                        '/inventory': (context) {
                          final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
                          return InventoryPage(branchId: args?['branchId'] ?? 'unknown');
                        },
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}

class AuthHomeWrapper extends StatefulWidget {
  const AuthHomeWrapper({super.key});

  static void clearSession() {
    _AuthHomeWrapperState._cachedSession = null;
  }

  @override
  State<AuthHomeWrapper> createState() => _AuthHomeWrapperState();
}

class _SessionData {
  final User? user;
  final Map<String, dynamic>? localUser;
  _SessionData({this.user, this.localUser});
}

class _AuthHomeWrapperState extends State<AuthHomeWrapper> {
  static _SessionData? _cachedSession;
  late final Future<_SessionData> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture = _determineSession();
    try {
      FlutterNativeSplash.remove();
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        FlutterNativeSplash.remove();
      } catch (_) {}
    });
  }

  Future<_SessionData> _determineSession() async {
    if (_cachedSession != null && (_cachedSession!.user != null || _cachedSession!.localUser != null)) {
      return _cachedSession!;
    }

    try {
      if (!Hive.isBoxOpen('app_settings')) {
        try {
          await Hive.openBox('app_settings');
        } catch (_) {}
      }

      // 0. Primary Check: Fast local user data cached in Hive app_settings
      // This preserves active session across Hot Restart and launches instantly without timeout
      Map<String, dynamic>? localUserData;
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final raw = box.get('user_data') ?? box.get('currentUser');
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          final r = (m['role'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown') {
            localUserData = m;
          }
        }
      }

      // 1. Fast local user session return (instant 0ms launch)
      // Firebase may still be starting (main no longer waits for it without limit); reading
      // FirebaseAuth then throws, which used to drop a valid local session to the login page.
      final firebaseReady = Firebase.apps.isNotEmpty;
      User? currentUser;
      if (firebaseReady) {
        try {
          currentUser = FirebaseAuth.instance.currentUser;
        } catch (_) {}
      }
      if (localUserData != null) {
        final isMaster = localUserData['isMasterAdmin'] == true ||
            localUserData['uid'] == 'master-local-admin' ||
            localUserData['id'] == 'master-local-admin';
        if (isMaster) {
          debugPrint('[AuthHomeWrapper] Master admin will not be logged in automatically; requiring manual login');
          try {
            if (Hive.isBoxOpen('app_settings')) {
              final box = Hive.box('app_settings');
              await box.delete('user_data');
              await box.delete('currentUser');
              await box.delete('user_role');
            }
          } catch (_) {}
          localUserData = null;
        } else {
          _cachedSession = _SessionData(user: currentUser, localUser: localUserData);
          return _cachedSession!;
        }
      } else if (currentUser != null) {
        final localData = _getLocalUserData(currentUser);
        _cachedSession = _SessionData(user: currentUser, localUser: localData);
        return _cachedSession!;
      }

      // 2. Wait at most 400ms for authStateChanges event (fast resolution)
      final streamUser = !firebaseReady
          ? null
          : await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((u) => u != null, orElse: () => null)
              .timeout(const Duration(milliseconds: 400), onTimeout: () => null);

      if (streamUser != null) {
        final localData = _getLocalUserData(streamUser);
        _cachedSession = _SessionData(user: streamUser, localUser: localData);
        return _cachedSession!;
      }

      // 3. Fallback to cached offline user credentials (fast 400ms timeout)
      final offlineUser = await offline_auth.OfflineAuthService.getCachedUserData()
          .timeout(const Duration(milliseconds: 400), onTimeout: () => null);

      if (offlineUser != null &&
          (offlineUser['uid'] != null ||
           offlineUser['username'] != null ||
           offlineUser['email'] != null)) {
        final isMaster = offlineUser['isMasterAdmin'] == true ||
            offlineUser['uid'] == 'master-local-admin' ||
            offlineUser['id'] == 'master-local-admin';
        if (!isMaster) {
          _cachedSession = _SessionData(user: null, localUser: offlineUser);
          return _cachedSession!;
        }
      }
    } catch (e) {
      debugPrint('[AuthHomeWrapper] Session resolution warning: $e');
    }
    _cachedSession = _SessionData(user: null, localUser: null);
    return _cachedSession!;
  }

  Map<String, dynamic>? _getLocalUserData(User user) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final cached = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (cached is Map) {
          final m = Map<String, dynamic>.from(cached);
          final r = (m['role'] ?? '').toString().toLowerCase().trim();
          final uUid = (m['uid'] ?? m['id'] ?? '').toString();
          final uEmail = (m['email'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown') {
            final targetEmail = (user.email ?? '').trim().toLowerCase();
            final uidMatch = uUid.isNotEmpty && uUid == user.uid;
            final emailMatch = uEmail.isNotEmpty && targetEmail.isNotEmpty && uEmail == targetEmail;
            final legacyUnbound = uUid.isEmpty && uEmail.isEmpty;
            if (uidMatch || emailMatch || legacyUnbound) {
              return m;
            }
          }
        }
      }

      final email = (user.email ?? '').trim().toLowerCase();
      final prefix = email.contains('@') ? email.split('@').first : email;
      final local = (email.isNotEmpty ? LocalStorageService.findLocalUser(email) : null) ??
          (prefix.isNotEmpty ? LocalStorageService.findLocalUser(prefix) : null) ??
          LocalStorageService.findLocalUser(user.uid);
      if (local != null) {
        return local;
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_SessionData>(
      future: _sessionFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && _cachedSession == null) {
          return const GmwfLoadingView(
            message: 'Verifying Session...',
            subMessage: 'Connecting to GMWF Security Core',
          );
        }

        final data = snapshot.data ?? _cachedSession;
        if (data != null && (data.user != null || data.localUser != null)) {
          return HomeRouter(user: data.user, localUser: data.localUser);
        }

        return const LoginPage();
      },
    );
  }
}