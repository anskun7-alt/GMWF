// lib/services/cloud_messaging_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';

import '../constants/navigator_key.dart';
import 'local_storage_service.dart';
import '../pages/dispensary/receptionist/receptionist_screen.dart';
import '../pages/dispensary/doctor/doctor_screen.dart';
import '../pages/dispensary/dispensar/inventory.dart';
import '../pages/donations/donations_screen.dart';
import '../pages/madrassa/madrassa_dashboard.dart';
import '../pages/madrassa/madrassa_guardian_screen.dart';
import '../pages/madrassa/student_fee_ledger.dart';
import '../pages/global_modular_dashboard.dart';
import '../pages/notification_screen.dart';
import '../pages/request.dart';
import '../widgets/update_dialog_widget.dart';

const String kAppTitle = 'Gulzar-e-Madina Welfare Foundation';
const String kAppLogoAsset = 'assets/logo/gmwf-1.png';

const AndroidNotificationChannel _kHighImportanceChannel = AndroidNotificationChannel(
  'gmwf_high_importance_channel',
  'Gulzar-e-Madina Welfare Foundation Notifications',
  description: 'Notifications for approvals, donation verification, medical alerts, reports, and payments.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

/// Top-level background message handler for terminated/background FCM delivery (Mobile/Web/macOS).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    final data = message.data;
    if (data.isNotEmpty) {
      if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
        await Hive.openBox(LocalStorageService.notificationsBox);
      }
      final box = Hive.box(LocalStorageService.notificationsBox);
      final id = data['id']?.toString() ??
          data['notificationId']?.toString() ??
          'fcm_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}';

      final isUrdu = data['body_ur'] != null && data['body_ur'].toString().isNotEmpty;
      final rawTitle = (isUrdu ? data['title_ur'] : data['title_en']) ?? data['title'] ?? message.notification?.title ?? 'Notification';
      final rawBody = (isUrdu ? data['body_ur'] : data['body_en']) ?? data['message'] ?? data['body'] ?? message.notification?.body ?? '';
      final category = data['category'] ?? data['type'] ?? 'Alert';

      final notificationDoc = {
        'id': id,
        'title': rawTitle,
        'message': rawBody,
        'title_en': data['title_en'],
        'title_ur': data['title_ur'],
        'body_en': data['body_en'],
        'body_ur': data['body_ur'],
        'category': category,
        'type': data['type'] ?? 'general',
        'targetScreen': data['targetScreen'] ?? data['target_screen'] ?? '',
        'recordId': data['recordId'] ?? data['record_id'] ?? '',
        'branchId': data['branchId'] ?? data['branch_id'] ?? '',
        'targetUserId': data['targetUserId'] ?? data['receiverId'] ?? data['userId'] ?? '',
        'targetRole': data['targetRole'] ?? data['receiverRole'] ?? data['role'] ?? '',
        'role': data['role'] ?? '',
        'seen': false,
        'timestamp': DateTime.now().toIso8601String(),
        'meta': data['meta'] is String
            ? (tryJsonDecode(data['meta']) ?? data['meta'])
            : data['meta'] ?? {},
      };

      await box.put(id, LocalStorageService.sanitize(notificationDoc));

      // Display in device system notification area / status bar on supported platforms
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        final notifId = id.hashCode & 0x7FFFFFFF;
        await _localNotifications.show(
          notifId,
          rawTitle,
          rawBody,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _kHighImportanceChannel.id,
              _kHighImportanceChannel.name,
              channelDescription: _kHighImportanceChannel.description,
              importance: Importance.max,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
              subText: kAppTitle,
              styleInformation: BigTextStyleInformation(
                rawBody,
                htmlFormatBigText: true,
                contentTitle: rawTitle,
                htmlFormatContentTitle: true,
                summaryText: '$kAppTitle • $category',
                htmlFormatSummaryText: true,
              ),
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
              subtitle: kAppTitle,
            ),
          ),
          payload: jsonEncode(notificationDoc),
        );
      }
    }
  } catch (e) {
    debugPrint('[FCM Background] Error saving message: $e');
  }
}

dynamic tryJsonDecode(dynamic value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } catch (_) {
    return value;
  }
}

class CloudMessagingService {
  static final CloudMessagingService _instance = CloudMessagingService._internal();
  factory CloudMessagingService() => _instance;
  CloudMessagingService._internal();

  bool _initialized = false;
  String? _cachedFcmToken;
  String? _currentUserId;
  String? _currentUserRole;
  String? _currentBranchId;
  String? _cachedLogoDiskPath;

  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onMessageOpenedAppSub;
  StreamSubscription<String>? _onTokenRefreshSub;

  final StreamController<Map<String, dynamic>> _notificationStreamController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of new in-app notifications
  Stream<Map<String, dynamic>> get onNotificationReceived =>
      _notificationStreamController.stream;

  /// Check whether FCM native push service is supported on this platform
  static bool get isFcmSupported {
    return kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Check whether local notifications system tray plugin is supported
  static bool get isLocalNotificationsSupported {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  /// Restore and bring app window to front when a notification is clicked on Desktop
  static void bringAppToFront() {
    if (kIsWeb) return;
    try {
      if (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS) {
        appWindow.show();
        appWindow.restore();
      }
    } catch (e) {
      debugPrint('[CloudMessagingService] Window focus notice: $e');
    }
  }

  /// Ensures the GMWF logo PNG is extracted to disk for Windows Toast Notifications
  Future<String?> _getOrCacheLogoPath() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
    if (_cachedLogoDiskPath != null && await io.File(_cachedLogoDiskPath!).exists()) {
      return _cachedLogoDiskPath;
    }
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final logoFile = io.File(p.join(appSupportDir.path, 'gmwf_logo.png'));
      if (!await logoFile.exists()) {
        final byteData = await rootBundle.load(kAppLogoAsset);
        final bytes = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
        await logoFile.writeAsBytes(bytes);
      }
      _cachedLogoDiskPath = logoFile.path.replaceAll(r'\', '/');
      return _cachedLogoDiskPath;
    } catch (e) {
      debugPrint('[CloudMessagingService] Error caching logo image: $e');
      return null;
    }
  }

  /// Initialize FCM engine, system notification channel, lifecycle listeners, and background handlers
  Future<void> initialize({
    String? userId,
    String? userRole,
    String? branchId,
  }) async {
    if (_initialized) {
      if (userId != null) _currentUserId = userId;
      if (userRole != null) _currentUserRole = userRole;
      if (branchId != null) _currentBranchId = branchId;
      return;
    }

    try {
      _currentUserId = userId;
      _currentUserRole = userRole;
      _currentBranchId = branchId;

      // Extract logo for Windows notifications in background
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        unawaited(_getOrCacheLogoPath());
      }

      // Ensure local notifications box is always ready on all platforms (Android, iOS, Desktop, Web)
      if (!Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.notificationsBox);
      }

      // 1. Initialize native device notification tray plugin on supported platforms
      if (isLocalNotificationsSupported) {
        try {
          const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
          const darwinInit = DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          );
          const initSettings = InitializationSettings(
            android: androidInit,
            iOS: darwinInit,
          );

          await _localNotifications.initialize(
            initSettings,
            onDidReceiveNotificationResponse: (NotificationResponse response) {
              bringAppToFront();
              final payload = response.payload;
              if (payload != null && payload.isNotEmpty) {
                final decoded = tryJsonDecode(payload);
                if (decoded is Map) {
                  handleNotificationTap(Map<String, dynamic>.from(decoded));
                }
              }
            },
          );

          if (defaultTargetPlatform == TargetPlatform.android) {
            final androidPlugin = _localNotifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
            await androidPlugin?.createNotificationChannel(_kHighImportanceChannel);
          }
        } catch (e) {
          debugPrint('[LocalNotifications] Tray init warning: $e');
        }
      }

      // 2. Initialize FirebaseMessaging if supported on platform (Android, iOS, Web, macOS)
      if (isFcmSupported) {
        try {
          // Set iOS Foreground Presentation Options so system notifications appear in tray
          if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
            await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
              alert: true,
              badge: true,
              sound: true,
            );
          }

          // Register background handler (Mobile only)
          if (!kIsWeb) {
            FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
          }

          // Foreground message listener
          _onMessageSub?.cancel();
          _onMessageSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
            _handleForegroundMessage(message);
          });

          // Background tap listener
          _onMessageOpenedAppSub?.cancel();
          _onMessageOpenedAppSub =
              FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
            bringAppToFront();
            handleNotificationTap(message.data);
          });

          // Cold start / Terminated state initial message
          final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
          if (initialMessage != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              bringAppToFront();
              handleNotificationTap(initialMessage.data);
            });
          }

          // Token refresh listener
          _onTokenRefreshSub?.cancel();
          _onTokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
            _cachedFcmToken = newToken;
            if (_currentUserId != null && _currentUserId!.isNotEmpty) {
              _syncTokenToServer(_currentUserId!, newToken, _currentUserRole, _currentBranchId);
            }
          });
        } catch (fcmErr) {
          debugPrint('[FCM] Platform FCM init warning: $fcmErr');
        }
      }

      _initialized = true;
      debugPrint('[CloudMessagingService] Initialized across platform (${defaultTargetPlatform.name}, web: $kIsWeb)');
    } catch (e) {
      debugPrint('[CloudMessagingService] Initialization error (gracefully degraded): $e');
    }
  }

  /// Request notification permissions across Android, iOS, and Web
  Future<bool> requestNotificationPermissions({BuildContext? context}) async {
    try {
      if (isFcmSupported) {
        final messaging = FirebaseMessaging.instance;
        final settings = await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
          criticalAlert: false,
        );

        if (defaultTargetPlatform == TargetPlatform.android) {
          final androidPlugin = _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
          await androidPlugin?.requestNotificationsPermission();
        }

        final isGranted = settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
        debugPrint('[CloudMessagingService] FCM Permission status: ${settings.authorizationStatus}');
        return isGranted;
      }
      return true;
    } catch (e) {
      debugPrint('[CloudMessagingService] Permission request error: $e');
      return false;
    }
  }

  /// Retrieve current device FCM token (Web / Android / iOS / macOS)
  Future<String?> getDeviceToken() async {
    try {
      if (!isFcmSupported) return null;
      if (_cachedFcmToken != null) return _cachedFcmToken;
      _cachedFcmToken = await FirebaseMessaging.instance.getToken();
      return _cachedFcmToken;
    } catch (e) {
      debugPrint('[CloudMessagingService] Error getting token: $e');
      return null;
    }
  }

  /// Register FCM token for current logged-in user and persist server-side
  Future<void> registerTokenForUser({
    required String userId,
    required String role,
    required String branchId,
  }) async {
    _currentUserId = userId;
    _currentUserRole = role;
    _currentBranchId = branchId;

    try {
      await requestNotificationPermissions();
      final token = await getDeviceToken();
      if (token == null || token.isEmpty) return;

      await _syncTokenToServer(userId, token, role, branchId);
      await _subscribeToTopicsForRole(role, branchId);
    } catch (e) {
      debugPrint('[CloudMessagingService] registerTokenForUser error: $e');
    }
  }

  /// Auto-subscribe client to role-based and branch-based FCM broadcast topics
  Future<void> _subscribeToTopicsForRole(String role, String branchId) async {
    if (!isFcmSupported || kIsWeb) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.subscribeToTopic('global_announcements');

      final cleanBranch = branchId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
      if (cleanBranch.isNotEmpty && cleanBranch != 'all') {
        await messaging.subscribeToTopic('announcements_$cleanBranch');
      }

      final cleanRole = role.toLowerCase().trim();
      final isMadrassaRole = cleanRole.contains('madrassa') ||
          cleanRole.contains('guardian') ||
          cleanRole.contains('parent') ||
          cleanRole == 'teacher';

      // Madrassa related users do NOT subscribe to notification topics
      if (!isMadrassaRole) {
        if (cleanRole.contains('admin') || cleanRole.contains('finance') || cleanRole.contains('cashier')) {
          await messaging.subscribeToTopic('finance_approvals');
          if (cleanBranch.isNotEmpty && cleanBranch != 'all') {
            await messaging.subscribeToTopic('finance_approvals_$cleanBranch');
          }
        }
      }
    } catch (e) {
      debugPrint('[CloudMessagingService] Topic subscription warning: $e');
    }
  }

  /// Determines whether incoming notification matches the current user's target filters
  bool _isTargetForCurrentUser(Map<String, dynamic> data) {
    final currentRole = (_currentUserRole ?? 'user').toLowerCase().trim();

    // RULE: Madrassa-related users do NOT receive any notifications
    if (currentRole.contains('madrassa') ||
        currentRole.contains('guardian') ||
        currentRole.contains('parent') ||
        currentRole == 'teacher') {
      return false;
    }

    final isSuperOrAdmin = currentRole == 'superadmin' ||
        currentRole == 'admin' ||
        currentRole == 'manager' ||
        currentRole == 'developer';

    // 1. Target User ID filter
    final targetUserId = (data['targetUserId'] ?? data['receiverId'] ?? data['userId'] ?? '').toString().trim();
    if (targetUserId.isNotEmpty && targetUserId.toLowerCase() != 'all') {
      if (_currentUserId != null && _currentUserId!.isNotEmpty) {
        if (_currentUserId!.toLowerCase() != targetUserId.toLowerCase()) {
          return false;
        }
      }
    }

    final targetUserIds = data['targetUserIds'] ?? data['receiverIds'];
    if (targetUserIds is List && targetUserIds.isNotEmpty) {
      if (_currentUserId != null && _currentUserId!.isNotEmpty) {
        final matches = targetUserIds.any((u) => u.toString().toLowerCase() == _currentUserId!.toLowerCase());
        if (!matches) return false;
      }
    }

    // 2. Target Role filter
    final targetRole = (data['targetRole'] ?? data['receiverRole'] ?? data['role'] ?? '').toString().trim().toLowerCase();
    if (targetRole.isNotEmpty && targetRole != 'all') {
      if (!isSuperOrAdmin) {
        if (targetRole != currentRole) {
          final roleMatches = (targetRole == 'guardian' && currentRole.contains('parent')) ||
              (targetRole == 'finance' && (currentRole == 'cashier' || currentRole == 'accountant')) ||
              (targetRole == 'cashier' && currentRole.contains('cashier')) ||
              (targetRole == 'doctor' && currentRole.contains('doctor')) ||
              (targetRole == 'receptionist' && currentRole.contains('reception')) ||
              (targetRole == 'teacher' && currentRole.contains('teacher'));
          if (!roleMatches) return false;
        }
      }
    }

    final targetRoles = data['targetRoles'];
    if (targetRoles is List && targetRoles.isNotEmpty) {
      if (!isSuperOrAdmin) {
        final matches = targetRoles.any((r) {
          final rClean = r.toString().toLowerCase().trim();
          return rClean == currentRole ||
              (rClean == 'finance' && (currentRole == 'cashier' || currentRole == 'accountant')) ||
              (rClean == 'guardian' && currentRole.contains('parent'));
        });
        if (!matches) return false;
      }
    }

    // 3. Branch filter
    final notifBranch = (data['branchId'] ?? data['branch_id'] ?? '').toString().trim().toLowerCase();
    if (notifBranch.isNotEmpty && notifBranch != 'all' && notifBranch != 'global') {
      if (_currentBranchId != null &&
          _currentBranchId!.isNotEmpty &&
          _currentBranchId != 'all' &&
          _currentBranchId != 'global') {
        if (!isSuperOrAdmin && _currentBranchId!.toLowerCase() != notifBranch) {
          return false;
        }
      }
    }

    return true;
  }

  /// Dispatch a system toast notification locally (Windows Toast / Android Notification / In-App Banner)
  Future<void> showLocalOrDesktopNotification({
    required String id,
    required String title,
    required String message,
    String? category,
    String? titleUr,
    String? messageUr,
    String? targetScreen,
    String? recordId,
    String? branchId,
    String? targetUserId,
    String? targetRole,
    List<String>? targetRoles,
    Map<String, dynamic>? meta,
  }) async {
    final notifDoc = {
      'id': id,
      'title': title,
      'message': message,
      'title_en': title,
      'title_ur': titleUr ?? title,
      'body_en': message,
      'body_ur': messageUr ?? message,
      'category': category ?? 'Alert',
      'type': category?.toLowerCase().replaceAll(' ', '_') ?? 'general',
      'targetScreen': targetScreen ?? '',
      'recordId': recordId ?? '',
      'branchId': branchId ?? _currentBranchId ?? 'all',
      'targetUserId': targetUserId ?? '',
      'targetRole': targetRole ?? '',
      'targetRoles': targetRoles ?? [],
      'seen': false,
      'timestamp': DateTime.now().toIso8601String(),
      'meta': meta ?? {},
    };

    // Verify targeting before displaying/saving to prevent unrelated users from seeing
    if (!_isTargetForCurrentUser(notifDoc)) {
      debugPrint('[CloudMessagingService] Notification ignored: current user/role not in target list.');
      return;
    }

    // 1. Save locally to Hive box
    if (Hive.isBoxOpen(LocalStorageService.notificationsBox)) {
      final box = Hive.box(LocalStorageService.notificationsBox);
      await box.put(id, LocalStorageService.sanitize(notifDoc));
    }
    _notificationStreamController.add(notifDoc);

    // 2. Display on Android / iOS system tray
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        await _localNotifications.show(
          id.hashCode & 0x7FFFFFFF,
          title,
          message,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _kHighImportanceChannel.id,
              _kHighImportanceChannel.name,
              channelDescription: _kHighImportanceChannel.description,
              importance: Importance.max,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
              subText: kAppTitle,
              styleInformation: BigTextStyleInformation(
                message,
                htmlFormatBigText: true,
                contentTitle: title,
                htmlFormatContentTitle: true,
                summaryText: '$kAppTitle • ${category ?? "Notification"}',
                htmlFormatSummaryText: true,
              ),
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
              subtitle: kAppTitle,
            ),
          ),
          payload: jsonEncode(notifDoc),
        );
      } catch (e) {
        debugPrint('[CloudMessagingService] Tray notification error: $e');
      }
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final logoPath = await _getOrCacheLogoPath();
      _showWindowsNativeToast(
        title: title,
        body: message,
        category: category,
        logoPath: logoPath,
      );
    }

    // 3. Show in-app banner
    _showInAppBanner(notifDoc);
  }

  /// Dispatch native Windows OS Toast Notification into Windows Action Center with Logo & App Header
  static void _showWindowsNativeToast({
    required String title,
    required String body,
    String? category,
    String? logoPath,
  }) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final safeTitle = title.replaceAll('"', "'").replaceAll('`', '').replaceAll('<', '').replaceAll('>', '');
      final safeBody = body.replaceAll('"', "'").replaceAll('`', '').replaceAll('<', '').replaceAll('>', '');
      final safeCategory = (category ?? 'System Alert').replaceAll('"', "'").replaceAll('`', '').replaceAll('<', '').replaceAll('>', '');
      
      final safeLogo = (logoPath != null && logoPath.isNotEmpty)
          ? 'file:///${logoPath.replaceAll(r'\', '/')}'
          : '';

      final imageNode = safeLogo.isNotEmpty
          ? '<image placement="appLogoOverride" hint-crop="circle" src="$safeLogo"/>'
          : '';

      final xmlString = '''
<toast duration="short">
  <visual>
    <binding template="ToastGeneric">
      $imageNode
      <text hint-maxLines="1">$kAppTitle</text>
      <text>$safeCategory • $safeTitle</text>
      <text>$safeBody</text>
    </binding>
  </visual>
</toast>
''';

      final psScript = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
\$xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]::new()
\$xml.LoadXml(@'
$xmlString
'@)
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("$kAppTitle").Show(\$toast)
''';

      io.Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', psScript]);
    } catch (e) {
      debugPrint('[WindowsNativeToast] error: $e');
    }
  }

  /// Specific Notification Dispatcher: Pending Donation Verification (Targeted to Cashiers, Finance & Admins)
  Future<void> dispatchDonationVerificationAlert({
    required String branchId,
    required String receiptNo,
    required String donorName,
    required num amount,
    String? collectorName,
  }) async {
    final notifId = 'don_verify_${DateTime.now().millisecondsSinceEpoch}_${receiptNo.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
    final collector = collectorName != null && collectorName.isNotEmpty ? ' by $collectorName' : '';
    await showLocalOrDesktopNotification(
      id: notifId,
      title: 'Pending Donation Verification: #$receiptNo',
      message: 'Donation of PKR $amount from $donorName recorded$collector is awaiting verification.',
      category: 'Pending Donations',
      titleUr: 'عطیہ کی تصدیق باقی ہے: #$receiptNo',
      messageUr: '$donorName کی طرف سے $amount روپے کا عطیہ درج کیا گیا ہے۔ برائے مہربانی تصدیق کریں۔',
      targetScreen: 'donations',
      recordId: receiptNo,
      branchId: branchId,
      targetRoles: ['admin', 'superadmin', 'finance', 'cashier'],
      meta: {
        'receiptNo': receiptNo,
        'donorName': donorName,
        'amount': amount,
        'action': 'verify_donation',
      },
    );
  }

  /// Specific Notification Dispatcher: App Update Available (Targeted to All Users)
  Future<void> dispatchAppUpdateAlert({
    required String newVersion,
    required String releaseNotes,
    bool forceUpdate = false,
  }) async {
    final notifId = 'update_${newVersion.replaceAll('.', '_')}';
    await showLocalOrDesktopNotification(
      id: notifId,
      title: 'New Version $newVersion Available',
      message: releaseNotes.isNotEmpty
          ? releaseNotes
          : 'A new version of Gulzar-e-Madina Welfare Foundation application is ready to install.',
      category: 'App Update',
      titleUr: 'نیا ورژن $newVersion دستیاب ہے',
      messageUr: 'جی ایم ڈبلیو ایف کا نیا ورژن اپ ڈیٹ کے لیے دستیاب ہے۔ انسٹال کرنے کے لیے کلک کریں۔',
      targetScreen: 'app_update',
      recordId: newVersion,
      meta: {
        'version': newVersion,
        'forceUpdate': forceUpdate,
      },
    );
  }

  /// Specific Notification Dispatcher: Fee Payment Received (Targeted to Guardian & Cashier)
  Future<void> dispatchFeePaymentAlert({
    required String branchId,
    required String studentId,
    required String studentName,
    required String guardianUserId,
    required num amount,
    required num remainingBalance,
  }) async {
    // Madrassa notifications disabled per organization policy (no notifications to madrassa users)
    debugPrint('[CloudMessagingService] Fee payment alert suppressed for madrassa student $studentName');
    return;
  }

  /// Specific Notification Dispatcher: Daily Report Ready (Targeted to Guardian)
  Future<void> dispatchDailyReportAlert({
    required String branchId,
    required String studentId,
    required String studentName,
    required String guardianUserId,
  }) async {
    // Madrassa notifications disabled per organization policy (no notifications to madrassa users)
    debugPrint('[CloudMessagingService] Daily report alert suppressed for madrassa student $studentName');
    return;
  }

  /// Specific Notification Dispatcher: Medical Token Exception (Targeted to Doctor)
  Future<void> dispatchTokenAlert({
    required String branchId,
    required String tokenNo,
    required String patientName,
    required String doctorId,
    String? reason,
  }) async {
    final notifId = 'token_alert_${DateTime.now().millisecondsSinceEpoch}_$tokenNo';
    await showLocalOrDesktopNotification(
      id: notifId,
      title: 'Medical Camp Alert: Token #$tokenNo',
      message: 'Patient $patientName (Token #$tokenNo) requires attention: ${reason ?? "Patient queued"}.',
      category: 'Dispensary',
      titleUr: 'میڈیکل کیمپ الرٹ: ٹوکن #$tokenNo',
      messageUr: 'مریض $patientName (ٹوکن #$tokenNo) ڈاکٹر کے معائنے کے لیے تیار ہے۔',
      targetScreen: 'doctor',
      recordId: tokenNo,
      branchId: branchId,
      targetUserId: doctorId,
      targetRoles: ['doctor', 'admin'],
      meta: {
        'tokenNo': tokenNo,
        'patientName': patientName,
      },
    );
  }

  /// Broadcast a Holiday or Emergency Announcement to all Guardians
  Future<void> broadcastHolidayAnnouncement({
    required String branchId,
    required String title,
    required String message,
    String? titleUr,
    String? messageUr,
    String? holidayDate,
  }) async {
    final notifId = 'holiday_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}';
    await showLocalOrDesktopNotification(
      id: notifId,
      title: title,
      message: message,
      category: 'Holiday Announcement',
      titleUr: titleUr ?? title,
      messageUr: messageUr ?? message,
      targetScreen: 'parent_report_card',
      branchId: branchId,
      targetRole: 'guardian',
      meta: {
        'holidayDate': holidayDate ?? DateTime.now().toIso8601String().split('T').first,
      },
    );

    // Save to announcements subcollection under branch for persistence
    try {
      final cleanBranch = LocalStorageService.sanitizeBranchId(branchId);
      await FirebaseFirestore.instance.collection('branches').doc(cleanBranch).collection('announcements').doc(notifId).set({
        'id': notifId,
        'title': title,
        'message': message,
        'title_en': title,
        'title_ur': titleUr ?? title,
        'body_en': message,
        'body_ur': messageUr ?? message,
        'category': 'Holiday Announcement',
        'type': 'holiday_announcement',
        'targetScreen': 'parent_report_card',
        'branchId': cleanBranch,
        'role': 'guardian',
        'holidayDate': holidayDate ?? DateTime.now().toIso8601String().split('T').first,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[CloudMessagingService] Cloud announcement write skipped/cached: $e');
    }
  }

  /// Specific Notification Dispatcher: Supervisor Pending Requests Alert
  /// Target role: 'supervisor' (as well as admin/superadmin/manager)
  /// Target screen: 'requests' -> Navigates straight to RequestPage(branchId: ..., isSupervisor: true)
  Future<void> notifySupervisorPendingRequests({
    required String branchId,
    String? campId,
    int? pendingCount,
    String? requestType,
    String? requesterName,
    String? details,
  }) async {
    final countStr = pendingCount != null && pendingCount > 1
        ? '$pendingCount Pending Requests'
        : 'New Pending Request';
    final desc = details != null && details.isNotEmpty
        ? details
        : (requestType != null && requestType.isNotEmpty
            ? 'A new $requestType request from ${requesterName ?? "staff"} is awaiting supervisor approval.'
            : 'You have pending approval requests awaiting review.');

    final notifId = 'req_pending_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}';

    final cleanB = LocalStorageService.sanitizeBranchId(branchId);
    await showLocalOrDesktopNotification(
      id: notifId,
      title: 'Supervisor Alert: $countStr',
      message: desc,
      category: 'Pending Requests',
      titleUr: 'سپروائزر الرٹ: منظوری کی درخواست',
      messageUr: 'نئی درخواستیں سپروائزر کی منظوری کے لیے منتظر ہیں۔ برائے مہربانی چیک کریں۔',
      targetScreen: 'requests',
      recordId: notifId,
      branchId: cleanB,
      targetRoles: ['supervisor', 'admin', 'superadmin', 'manager'],
      meta: {
        'branchId': cleanB,
        'campId': campId ?? '',
        'requestType': requestType ?? '',
        'pendingCount': pendingCount ?? 1,
        'action': 'open_requests',
      },
    );

    // Also persist to branch 'notifications' subcollection for FCM push delivery when app is closed
    try {
      await FirebaseFirestore.instance.collection('branches').doc(cleanB).collection('notifications').doc(notifId).set({
        'id': notifId,
        'notificationId': notifId,
        'title': 'Supervisor Alert: $countStr',
        'title_en': 'Supervisor Alert: $countStr',
        'title_ur': 'سپروائزر الرٹ: منظوری کی درخواست',
        'message': desc,
        'body_en': desc,
        'body_ur': 'نئی درخواستیں سپروائزر کی منظوری کے لیے منتظر ہیں۔',
        'category': 'Pending Requests',
        'type': 'requests',
        'targetScreen': 'requests',
        'target_screen': 'requests',
        'branchId': cleanB,
        'campId': campId ?? '',
        'targetRole': 'supervisor',
        'targetRoles': ['supervisor', 'admin', 'superadmin', 'manager'],
        'role': 'supervisor',
        'seen': false,
        'timestamp': FieldValue.serverTimestamp(),
        'createdAt': DateTime.now().toIso8601String(),
        'meta': {
          'branchId': cleanB,
          'campId': campId ?? '',
          'requestType': requestType ?? '',
          'targetScreen': 'requests',
        },
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[CloudMessagingService] Cloud supervisor notification write skipped/cached: $e');
    }
  }

  /// Instant test notification trigger to verify that the tray, banner, and drawer work properly
  Future<void> triggerTestNotification({
    String? title,
    String? message,
    String? type,
    BuildContext? context,
  }) async {
    final testId = 'test_${DateTime.now().millisecondsSinceEpoch}';
    await showLocalOrDesktopNotification(
      id: testId,
      title: title ?? '🔔 GMWF Notification Test',
      message: message ?? 'Real-time role targeting, app branding, and deep-link routing are fully active!',
      category: 'System Test',
      titleUr: '🔔 جی ایم ڈبلیو ایف نوٹیفکیشن ٹیسٹ',
      messageUr: 'اطلاع: ریئل ٹائم میسجنگ اور خودکار روٹنگ مکمل فعال ہیں۔',
      targetScreen: 'donations',
      branchId: LocalStorageService.sanitizeBranchId(_currentBranchId),
    );
  }

  /// Sync token to Firestore under user document / fcm_tokens collection
  Future<void> _syncTokenToServer(
    String userId,
    String token,
    String? role,
    String? branchId,
  ) async {
    try {
      final tokenData = {
        'token': token,
        'userId': userId,
        'role': role ?? 'user',
        'branchId': LocalStorageService.sanitizeBranchId(branchId),
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'lastUpdated': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'fcmToken': token,
        'fcmTokens': FieldValue.arrayUnion([token]),
        'lastActive': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('fcm_registrations')
          .doc('${userId}_${token.hashCode}')
          .set(tokenData, SetOptions(merge: true));

      debugPrint('[CloudMessagingService] Token registered for user $userId on ${kIsWeb ? "web" : defaultTargetPlatform.name}');
    } catch (e) {
      debugPrint('[CloudMessagingService] _syncTokenToServer error: $e');
    }
  }

  /// Deregister FCM token on user logout
  Future<void> deregisterToken(String userId) async {
    try {
      final token = _cachedFcmToken ?? await getDeviceToken();
      if (token != null && token.isNotEmpty) {
        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'fcmTokens': FieldValue.arrayRemove([token]),
        }, SetOptions(merge: true));

        await FirebaseFirestore.instance
            .collection('fcm_registrations')
            .doc('${userId}_${token.hashCode}')
            .delete();
      }
      _cachedFcmToken = null;
      _currentUserId = null;
      debugPrint('[CloudMessagingService] Token deregistered for user $userId');
    } catch (e) {
      debugPrint('[CloudMessagingService] deregisterToken error: $e');
    }
  }

  /// Handle incoming foreground messages
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    if (data.isEmpty) return;

    if (!_isTargetForCurrentUser(data)) {
      debugPrint('[CloudMessagingService] Foreground message ignored: not targeted to this user/role.');
      return;
    }

    final id = data['id']?.toString() ??
        data['notificationId']?.toString() ??
        'fcm_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 6)}';

    final isUrdu = data['body_ur'] != null && data['body_ur'].toString().isNotEmpty;
    final title = (isUrdu ? data['title_ur'] : data['title_en']) ?? data['title'] ?? message.notification?.title ?? 'Notification';
    final body = (isUrdu ? data['body_ur'] : data['body_en']) ?? data['message'] ?? data['body'] ?? message.notification?.body ?? '';
    final category = data['category'] ?? data['type'] ?? 'Notification';

    await showLocalOrDesktopNotification(
      id: id,
      title: title,
      message: body,
      category: category,
      titleUr: data['title_ur'],
      messageUr: data['body_ur'],
      targetScreen: data['targetScreen'] ?? data['target_screen'],
      recordId: data['recordId'] ?? data['record_id'],
      branchId: data['branchId'] ?? data['branch_id'],
      targetUserId: data['targetUserId'] ?? data['receiverId'] ?? data['userId'],
      targetRole: data['targetRole'] ?? data['receiverRole'] ?? data['role'],
      meta: data['meta'] is String ? (tryJsonDecode(data['meta']) ?? data['meta']) : data['meta'],
    );
  }

  /// Show premium branded in-app banner across all platforms
  void _showInAppBanner(Map<String, dynamic> notification) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    final isUrdu = notification['body_ur'] != null && notification['body_ur'].toString().isNotEmpty;
    final title = (isUrdu ? notification['title_ur'] : notification['title_en']) ?? notification['title'] ?? 'Notification';
    final body = (isUrdu ? notification['body_ur'] : notification['body_en']) ?? notification['message'] ?? '';
    final category = notification['category'] ?? notification['type'] ?? 'Alert';

    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF0D9488), width: 1.2),
        ),
        backgroundColor: const Color(0xFF0F172A),
        duration: const Duration(seconds: 6),
        content: Directionality(
          textDirection: isUrdu ? TextDirection.rtl : TextDirection.ltr,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // GMWF App Logo
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withAlpha(20),
                  border: Border.all(color: const Color(0xFF14B8A6), width: 1.5),
                ),
                padding: const EdgeInsets.all(4),
                child: Image.asset(
                  kAppLogoAsset,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.notifications_active, color: Color(0xFF14B8A6), size: 22),
                ),
              ),
              const SizedBox(width: 12),
              // App Title, Category & Message Body
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          kAppTitle,
                          style: TextStyle(
                            color: Color(0xFF2DD4BF),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: Text(
                            category.toString().toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      title.toString(),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontSize: 13.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body.toString(),
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        action: SnackBarAction(
          label: isUrdu ? 'دیکھیں' : 'VIEW',
          textColor: const Color(0xFF38BDF8),
          onPressed: () {
            bringAppToFront();
            handleNotificationTap(notification);
          },
        ),
      ),
    );
  }

  /// Resolve notification tap to target deep-link destination with window focus
  Future<void> handleNotificationTap(Map<String, dynamic> data) async {
    bringAppToFront();

    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint('[CloudMessagingService] Context null, postponing navigation');
      return;
    }

    final targetScreen = (data['targetScreen'] ?? data['target_screen'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    final recordId = (data['recordId'] ?? data['record_id'] ?? data['id'] ?? '').toString().trim();
    final branchId = (data['branchId'] ?? data['branch_id'] ?? _currentBranchId ?? 'all').toString().trim();
    final role = _currentUserRole ?? 'user';

    // ── Permission & Scoping Re-validation ──────────────────────────────────
    if (_currentBranchId != null &&
        _currentBranchId != 'all' &&
        branchId.isNotEmpty &&
        branchId != 'all' &&
        branchId.toLowerCase() != _currentBranchId!.toLowerCase()) {
      final currentRole = role.toLowerCase().trim();
      final isSuperOrAdmin = currentRole == 'superadmin' || currentRole == 'admin' || currentRole == 'manager';
      if (!isSuperOrAdmin) {
        _showStaleOrRevokedDialog(
          context,
          title: 'Access Restricted',
          message: 'This notification belongs to branch "$branchId", but your active session is assigned to "$_currentBranchId".',
        );
        return;
      }
    }

    // ── Deep Link Resolver Navigation Matrix ────────────────────────────────
    try {
      switch (targetScreen) {
        case 'donations':
        case 'pending_donations':
        case 'donation_verification':
        case 'donations_view':
        case 'donation_approval':
          await _navigateToDonations(context, branchId, recordId, data);
          break;

        case 'app_update':
        case 'app_updates':
        case 'update':
          await _navigateToAppUpdate(context, data);
          break;

        case 'token_screen':
        case 'token_exception':
        case 'token_reversal':
        case 'doctor':
          await _navigateToTokenException(context, branchId, recordId, data);
          break;

        case 'patient_list':
        case 'patient_profile_edit':
        case 'receptionist':
          await _navigateToPatientProfile(context, branchId, recordId, data);
          break;

        case 'inventory':
        case 'inventory_stock_edit':
        case 'dispensar':
        case 'dispenser':
          await _navigateToInventory(context, branchId, recordId, data);
          break;

        case 'finance_view':
        case 'finance':
        case 'salary_advance':
        case 'expense_voucher':
          await _navigateToFinance(context, branchId, recordId, data);
          break;

        case 'madrassa':
        case 'madrassa_students_view':
        case 'madrassa_enrollment':
          await _navigateToMadrassaStudents(context, branchId, recordId, data);
          break;

        case 'parent_report_card':
        case 'madrassa_guardian':
        case 'madrassa_daily_report':
        case 'madrassa_leave':
          await _navigateToParentReportCard(context, branchId, recordId, data);
          break;

        case 'student_fee_ledger':
        case 'fee_payment':
        case 'fee_payment_received':
        case 'dues_cleared':
          await _navigateToStudentFeeLedger(context, branchId, recordId, data);
          break;

        case 'requests':
        case 'request':
        case 'edit_requests':
        case 'edit_request':
        case 'pending_requests':
        case 'supervisor_requests':
        case 'supervisor':
        case 'local_edit_requests':
        case 'stock_request':
        case 'dispense_request':
        case 'reversal_request':
          await _navigateToRequests(context, branchId, data);
          break;

        default:
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NotificationScreen(
                branchId: branchId,
                userId: _currentUserId ?? 'user',
                role: role,
              ),
            ),
          );
      }
    } catch (e) {
      debugPrint('[CloudMessagingService] Deep link error: $e');
      if (context.mounted) {
        _showStaleOrRevokedDialog(
          context,
          title: 'Navigation Error',
          message: 'Unable to open target record. It may have been modified or deleted.',
        );
      }
    }
  }

  // ── Deep Link Target Navigators ──────────────────────────────────────────

  Future<void> _navigateToDonations(
    BuildContext context,
    String branchId,
    String receiptNo,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DonationsScreen.withStringRole(
          branchId: branchId,
          username: _currentUserId ?? 'user',
          userId: _currentUserId ?? 'user',
          branchName: branchId,
          role: _currentUserRole ?? 'staff',
        ),
      ),
    );
  }

  Future<void> _navigateToAppUpdate(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    await UpdateDialogWidget.showUpdateDialogIfNeeded(context, manualCheck: true);
  }

  Future<void> _navigateToTokenException(
    BuildContext context,
    String branchId,
    String serial,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DoctorScreen(
          branchId: branchId,
          doctorName: 'Doctor',
          doctorId: _currentUserId ?? 'doc',
        ),
      ),
    );
  }

  Future<void> _navigateToPatientProfile(
    BuildContext context,
    String branchId,
    String patientId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReceptionistScreen(
          branchId: branchId,
          receptionistName: 'Receptionist',
          receptionistId: _currentUserId ?? 'rec',
        ),
      ),
    );
  }

  Future<void> _navigateToInventory(
    BuildContext context,
    String branchId,
    String batchId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InventoryPage(branchId: branchId),
      ),
    );
  }

  Future<void> _navigateToFinance(
    BuildContext context,
    String branchId,
    String voucherId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlobalModularDashboard(
          userData: {
            'uid': _currentUserId,
            'role': _currentUserRole ?? 'admin',
            'branchId': branchId,
          },
        ),
      ),
    );
  }

  Future<void> _navigateToMadrassaStudents(
    BuildContext context,
    String branchId,
    String studentId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MadrassaDashboard(
          branchId: branchId,
          username: _currentUserId ?? 'user',
          role: _currentUserRole ?? 'admin',
        ),
      ),
    );
  }

  Future<void> _navigateToParentReportCard(
    BuildContext context,
    String branchId,
    String studentId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MadrassaGuardianScreen(
          userData: {
            'uid': _currentUserId,
            'role': 'guardian',
            'branchId': branchId,
            'studentId': studentId,
          },
        ),
      ),
    );
  }

  Future<void> _navigateToStudentFeeLedger(
    BuildContext context,
    String branchId,
    String studentId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudentFeeLedgerScreen(
          branchId: branchId,
          studentId: studentId,
          studentName: data['studentName']?.toString(),
          fatherName: data['fatherName']?.toString(),
          monthlyFee: double.tryParse(data['monthlyFee']?.toString() ?? ''),
        ),
      ),
    );
  }

  Future<void> _navigateToRequests(
    BuildContext context,
    String branchId,
    Map<String, dynamic> data,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RequestPage(
          branchId: branchId,
          isSupervisor: true,
        ),
      ),
    );
  }

  /// Stale Target / Access Revoked User Dialog
  void _showStaleOrRevokedDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFF59E0B)),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── Bilingual Madrassa & Fee Notification Scenario Builders ────────────────

  static Map<String, String> buildDailyReportNotification(String studentName) {
    return {
      'title_en': 'Daily Report Available',
      'body_en': '$studentName\'s daily report is ready. Tap to view and reply.',
      'title_ur': 'روزانہ رپورٹ دستیاب ہے',
      'body_ur': '$studentName کی روزانہ رپورٹ درج کر دی گئی ہے۔ تفصیلات دیکھنے اور جواب دینے کے لیے ٹیپ کریں۔',
    };
  }

  static Map<String, String> buildAbsenceAlertNotification(String studentName, String date) {
    return {
      'title_en': 'Attendance Alert',
      'body_en': '$studentName was marked absent on $date.',
      'title_ur': 'غیر حاضری کی اطلاع',
      'body_ur': '$studentName کو آج ($date) غیر حاضر مارک کیا گیا ہے۔',
    };
  }

  static Map<String, String> buildReplyReminderNotification(String studentName) {
    return {
      'title_en': 'Reply Pending',
      'body_en': 'Please submit your reply for $studentName\'s daily report.',
      'title_ur': 'جواب باقی ہے',
      'body_ur': 'برائے مہربانی $studentName کی روزانہ رپورٹ کا جواب ارسال کریں۔',
    };
  }

  static Map<String, String> buildFeePaymentNotification(
    String studentName,
    num amount,
    num remainingBalance,
  ) {
    return {
      'title_en': 'Payment Received',
      'body_en': 'Rs. $amount received for $studentName. Remaining balance: Rs. $remainingBalance.',
      'title_ur': 'ادائیگی موصول ہو گئی',
      'body_ur': '$studentName کے لیے رقم $amount روپے موصول ہو گئی ہے۔ باقی واجبات: $remainingBalance روپے۔',
    };
  }

  static Map<String, String> buildDuesClearedNotification(String studentName) {
    return {
      'title_en': 'All Dues Cleared!',
      'body_en': 'All dues for $studentName are fully cleared. JazakAllah Khair.',
      'title_ur': 'تمام واجبات ادا ہو گئے!',
      'body_ur': '$studentName کے تمام واجبات مکمل ادا ہو چکے ہیں۔ جزاک اللہ خیراً۔',
    };
  }

  static Map<String, String> buildLeaveRequestNotification({
    required String studentName,
    required String reason,
    required String startDate,
    String? endDate,
  }) {
    final period = (endDate != null && endDate.isNotEmpty && endDate != startDate)
        ? '$startDate to $endDate'
        : startDate;
    return {
      'title_en': 'New Leave Request: $studentName',
      'body_en': 'Leave applied for $period. Reason: $reason. Tap to review & approve.',
      'title_ur': 'چھٹی کی نئی درخواست: $studentName',
      'body_ur': '$studentName نے $period کے لیے چھٹی کی درخواست دی ہے۔ وجہ: $reason۔ منظوری کے لیے ٹیپ کریں۔',
    };
  }

  static Map<String, String> buildGuardianReplyNotification({
    required String studentName,
    required String guardianName,
    required String replySnippet,
  }) {
    return {
      'title_en': 'Parent Replied: $studentName',
      'body_en': '$guardianName replied: "$replySnippet". Tap to view details.',
      'title_ur': 'والدین کا جواب: $studentName',
      'body_ur': '$guardianName نے جواب دیا ہے: "$replySnippet"۔ تفصیلات دیکھنے کے لیے ٹیپ کریں۔',
    };
  }

  /// Check-and-send idempotency flag guard (prevents repeated notifications)
  static Future<bool> shouldSendNotification({
    required String flagKey,
    required String entityId,
  }) async {
    try {
      if (!Hive.isBoxOpen('app_settings')) {
        await Hive.openBox('app_settings');
      }
      final box = Hive.box('app_settings');
      final compositeKey = 'notif_sent_${flagKey}_$entityId';
      if (box.get(compositeKey) == true) {
        return false;
      }
      await box.put(compositeKey, true);
      return true;
    } catch (_) {
      return true;
    }
  }
}
