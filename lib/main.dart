// lib/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:google_fonts/google_fonts.dart';
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
import 'realtime/server_sync_manager.dart';
import 'realtime/realtime_router.dart';
import 'services/cloud_messaging_service.dart';
import 'services/auth_service.dart';
import 'widgets/gmwf_loading_view.dart';
import 'widgets/custom_title_bar.dart';
import 'tools/finance_v2_migration.dart';

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

Future<void> _logError(String message, [String? stack]) async {
  if (kIsWeb) return;
  try {
    final dir = await getApplicationSupportDirectory();
    final logFile = File(path.join(dir.path, 'gmwf_crash.log'));
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] ERROR: $message\nSTACK: ${stack ?? ''}\n\n';
    await logFile.writeAsString(entry, mode: FileMode.append);
    debugPrint("Error logged to file: $message");
  } catch (e) {
    debugPrint("Unable to write crash log: $e");
  }
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

void _installGlobalErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!kIsWeb && Platform.isWindows) {
      try {
        appWindow.show();
      } catch (_) {}
    }
    FlutterError.presentError(details);

    final exStr = details.exceptionAsString().toLowerCase();
    final isTransientLayout = exStr.contains('overflowed') ||
        exStr.contains('renderbox was not laid out') ||
        exStr.contains('hassize') ||
        exStr.contains('_needslayout') ||
        exStr.contains('needs-paint') ||
        exStr.contains('_debugdoingthislayout') ||
        exStr.contains('parentdatadirty') ||
        exStr.contains('childsemantics');

    if (!isTransientLayout) {
      _logError(details.exceptionAsString(), details.stack?.toString());
      _markLastCrash();
      Sentry.captureException(details.exception, stackTrace: details.stack);
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (!kIsWeb && Platform.isWindows) {
      try {
        appWindow.show();
      } catch (_) {}
    }
    final errStr = error.toString().toLowerCase();
    final isTransientLayout = errStr.contains('overflowed') ||
        errStr.contains('renderbox was not laid out') ||
        errStr.contains('hassize') ||
        errStr.contains('_needslayout') ||
        errStr.contains('needs-paint') ||
        errStr.contains('_debugdoingthislayout') ||
        errStr.contains('parentdatadirty') ||
        errStr.contains('childsemantics');

    if (!isTransientLayout) {
      _logError(error.toString(), stack.toString());
      _markLastCrash();
      Sentry.captureException(error, stackTrace: stack);
    }
    return true;
  };
}

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  _installGlobalErrorHandlers();

  // Show window immediately on Desktop so app is NEVER hidden on launch
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    try {
      doWhenWindowReady(() {
        appWindow.minSize = const Size(1280, 720);
        appWindow.alignment = Alignment.center;
        appWindow.title = "Gulzar-e-Madina Welfare Foundation";
        appWindow.show();
        appWindow.maximize();
      });
    } catch (e) {
      debugPrint('[Main] Window ready error: $e');
    }
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = 'https://1decf155927c0b93fcbc40447bb21a12@o4511376159014912.ingest.de.sentry.io/4511376169631824';
      options.tracesSampleRate = 1.0;
      options.environment = 'production';
    },
    appRunner: () async {
      try {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
            .timeout(const Duration(seconds: 5))
            .catchError((e) {
              debugPrint('[Main] Firebase init warning: $e');
              return Firebase.app();
            });

        if (kIsWeb) {
          await Hive.initFlutter();
        } else if (Platform.isWindows) {
          final appSupportDir = await getApplicationSupportDirectory();
          final hiveDir = path.join(appSupportDir.path, 'gmwf_hive');
          LocalStorageService.setHiveDirectoryPath(hiveDir);
          await Hive.initFlutter(hiveDir);
        } else {
          final appSupportDir = await getApplicationSupportDirectory();
          LocalStorageService.setHiveDirectoryPath(appSupportDir.path);
          await Hive.initFlutter();
        }
        Hive.registerAdapter(TimestampAdapter());

        try {
          await Hive.openBox('app_settings');
        } catch (hiveErr) {
          debugPrint('[Main] Hive app_settings box error: $hiveErr');
        }

        await Future.wait<dynamic>([
          LocalStorageService.init(),
          DonationsLocalStorage.init(),
          ServerSyncManager.initHive(),
          RealtimeRouter.init(),
        ]).catchError((e) {
          debugPrint('[Main] Non-critical service init warning: $e');
          return <dynamic>[];
        });

        await CampSessionService.clearServerOffset();
        CampSessionService.checkClockSkew();
        unawaited(CampSessionService.syncInternetTime());

        await LocalStorageService.seedLocalAdmins();
        await _clearCrashMarkerOnSuccess();
        AuthService.onSignOutCallback = AuthHomeWrapper.clearSession;

        // Start background daemons & services
        unawaited(CloudMessagingService().initialize().catchError((e) {
          debugPrint('[Init] CloudMessagingService init warning: $e');
        }));

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

      runApp(const ProviderScope(child: MyApp()));
    },
  );
}

Future<void> _runBackgroundCleanups() async {
  try {
    await FinanceV2Migration.runMigration();
    await LocalStorageService.forceDeduplicatePatients();
    await LocalStorageService.repairMisassignedShiftSessions();

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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      _lifecycleListener?.dispose();
      PythonRunnerService.instance.stopProcess();
    }
    super.dispose();
  }

  ThemeData _buildThemeData({
    required Color seedColor,
    required double cardRadius,
    required String? fontFamily,
    required Brightness brightness,
  }) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        primary: seedColor,
        secondary: AppColors.navy,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: isDark ? const Color(0xFF090C10) : const Color(0xFFEAEFF5),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF161B22) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? const Color(0xFF161B22) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF21262D) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: isDark ? const Color(0xFF30363D) : AppColors.gray200, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: isDark ? const Color(0xFF30363D) : AppColors.gray200, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: seedColor, width: 2.0),
        ),
        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF8B949E) : AppColors.gray600),
        hintStyle: TextStyle(fontSize: 14, color: isDark ? const Color(0xFF6E7681) : AppColors.gray400),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: seedColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          elevation: 3,
          shadowColor: seedColor.withValues(alpha: isDark ? 0.4 : 0.35),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('app_settings')) {
      return MaterialApp(
        navigatorKey: navigatorKey,
        title: 'GMWF',
        debugShowCheckedModeBanner: false,
        routes: {
          '/home': (context) => const AuthHomeWrapper(),
          '/login': (context) => const LoginPage(),
        },
        home: const AuthHomeWrapper(),
      );
    }

    return ValueListenableBuilder(
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
        final isDarkMode = box.get('is_dark_mode', defaultValue: false) as bool;
        final language = box.get('language', defaultValue: 'en') as String;
        final fontFamily = GoogleFonts.dmSans().fontFamily;
        final isUrdu = language == 'ur';

        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'GMWF',
          debugShowCheckedModeBanner: false,
          themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
          locale: Locale(language),
          theme: _buildThemeData(
            seedColor: seedColor,
            cardRadius: cardRadius,
            fontFamily: fontFamily,
            brightness: Brightness.light,
          ),
          darkTheme: _buildThemeData(
            seedColor: seedColor,
            cardRadius: cardRadius,
            fontFamily: fontFamily,
            brightness: Brightness.dark,
          ),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            final scale = (box.get('font_scale', defaultValue: 1.0) as num).toDouble();

            final appDirection = isUrdu ? TextDirection.rtl : TextDirection.ltr;
            final appMediaQuery = mediaQuery.copyWith(
              textScaler: TextScaler.linear(scale),
            );

            final adjustedChild = MediaQuery(
              data: appMediaQuery,
              child: Directionality(
                textDirection: appDirection,
                child: child ?? const SizedBox.shrink(),
              ),
            );

            if (!kIsWeb && Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST')) {
              return Material(
                color: isDarkMode ? const Color(0xFF090C10) : const Color(0xFFEAEFF5),
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
              return DispensarScreen(branchId: args?['branchId'] ?? 'unknown');
            },
            '/inventory': (context) {
              final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
              return InventoryPage(branchId: args?['branchId'] ?? 'unknown');
            },
          },
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

      // 1. Check if Firebase currentUser is available immediately
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        final localData = _getLocalUserData(currentUser);
        _cachedSession = _SessionData(user: currentUser, localUser: localData);
        return _cachedSession!;
      }

      // 2. Wait at most 1.5 seconds for authStateChanges event
      final streamUser = await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere((u) => u != null, orElse: () => null)
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => null);

      if (streamUser != null) {
        final localData = _getLocalUserData(streamUser);
        _cachedSession = _SessionData(user: streamUser, localUser: localData);
        return _cachedSession!;
      }

      // 3. Fallback to cached offline user credentials
      final offlineUser = await offline_auth.OfflineAuthService.getCachedUserData()
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => null);

      if (offlineUser != null &&
          (offlineUser['uid'] != null ||
           offlineUser['username'] != null ||
           offlineUser['email'] != null)) {
        _cachedSession = _SessionData(user: null, localUser: offlineUser);
        return _cachedSession!;
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
        final cached = Hive.box('app_settings').get('user_data');
        if (cached is Map) {
          final m = Map<String, dynamic>.from(cached);
          final r = (m['role'] ?? '').toString().toLowerCase().trim();
          final uUid = (m['uid'] ?? '').toString();
          final uEmail = (m['email'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown' && (uUid == user.uid || uEmail == (user.email ?? '').toLowerCase())) {
            return m;
          }
        }
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