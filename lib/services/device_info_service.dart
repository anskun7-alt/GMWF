// lib/services/device_info_service.dart

import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auto_update_service.dart';

class DeviceInfoService {
  static final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();

  /// Collects platform, browser, OS, and device model information.
  static Future<Map<String, dynamic>> getDeviceInfo() async {
    String platform = 'Unknown';
    String browser = 'Native App';
    String os = 'Unknown OS';
    String deviceName = 'Unknown Device';
    String deviceModel = 'Unknown Model';
    String deviceSummary = 'Device';
    String iconType = 'unknown';

    try {
      if (kIsWeb) {
        platform = 'Web';
        final webInfo = await _deviceInfoPlugin.webBrowserInfo;
        final ua = webInfo.userAgent?.toLowerCase() ?? '';

        // Browser Detection
        if (ua.contains('edg/') || ua.contains('edge')) {
          browser = 'Edge';
          iconType = 'edge';
        } else if (ua.contains('chrome') || ua.contains('crios')) {
          browser = 'Chrome';
          iconType = 'chrome';
        } else if (ua.contains('firefox') || ua.contains('fxios')) {
          browser = 'Firefox';
          iconType = 'firefox';
        } else if (ua.contains('safari') && !ua.contains('chrome')) {
          browser = 'Safari';
          iconType = 'safari';
        } else if (ua.contains('opr') || ua.contains('opera')) {
          browser = 'Opera';
          iconType = 'opera';
        } else {
          browser = webInfo.browserName.name.toUpperCase();
          iconType = 'web';
        }

        // OS Detection from Web UserAgent / Platform
        final platformStr = webInfo.platform?.toLowerCase() ?? '';
        if (ua.contains('win') || platformStr.contains('win')) {
          os = 'Windows (Web)';
        } else if (ua.contains('mac') || platformStr.contains('mac')) {
          os = 'macOS (Web)';
        } else if (ua.contains('android')) {
          os = 'Android (Web)';
        } else if (ua.contains('iphone') || ua.contains('ipad')) {
          os = 'iOS (Web)';
        } else if (ua.contains('linux') || platformStr.contains('linux')) {
          os = 'Linux (Web)';
        } else {
          os = webInfo.platform ?? 'Web Platform';
        }

        deviceName = '$browser Browser';
        deviceModel = '$browser on ${os.replaceAll(' (Web)', '')}';
        deviceSummary = '🌐 $browser ($os)';
      } else {
        // Native Platforms
        switch (defaultTargetPlatform) {
          case TargetPlatform.windows:
            platform = 'Windows';
            browser = 'Desktop App';
            iconType = 'windows';
            final windowsInfo = await _deviceInfoPlugin.windowsInfo;
            final computerName = windowsInfo.computerName;
            final displayVer = windowsInfo.displayVersion;
            final prodName = windowsInfo.productName;

            deviceName = computerName.isNotEmpty ? computerName : 'Windows PC';
            os = displayVer.isNotEmpty ? 'Windows $displayVer' : 'Windows PC';
            deviceModel = prodName.isNotEmpty ? prodName : 'Windows x64 PC';
            deviceSummary = '🖥️ $deviceName ($os)';
            break;

          case TargetPlatform.android:
            platform = 'Android';
            browser = 'Mobile App';
            iconType = 'android';
            final androidInfo = await _deviceInfoPlugin.androidInfo;
            final brand = androidInfo.brand;
            final model = androidInfo.model;
            final release = androidInfo.version.release;
            deviceName = androidInfo.device.isNotEmpty ? androidInfo.device : '$brand Phone';
            os = 'Android $release';
            deviceModel = '$brand $model';
            deviceSummary = '📱 $deviceModel ($os)';
            break;

          case TargetPlatform.iOS:
            platform = 'iOS';
            browser = 'Mobile App';
            iconType = 'ios';
            final iosInfo = await _deviceInfoPlugin.iosInfo;
            final name = iosInfo.name;
            final sysVersion = iosInfo.systemVersion;
            final model = iosInfo.model;
            deviceName = name.isNotEmpty ? name : 'iPhone';
            os = 'iOS $sysVersion';
            deviceModel = model;
            deviceSummary = '🍎 $model ($os)';
            break;

          case TargetPlatform.macOS:
            platform = 'macOS';
            browser = 'Desktop App';
            iconType = 'macos';
            final macInfo = await _deviceInfoPlugin.macOsInfo;
            deviceName = macInfo.computerName;
            os = 'macOS ${macInfo.osRelease}';
            deviceModel = macInfo.model;
            deviceSummary = '💻 $deviceName ($os)';
            break;

          case TargetPlatform.linux:
            platform = 'Linux';
            browser = 'Desktop App';
            iconType = 'linux';
            final linuxInfo = await _deviceInfoPlugin.linuxInfo;
            deviceName = linuxInfo.name;
            os = linuxInfo.name;
            deviceModel = linuxInfo.versionId ?? 'Linux PC';
            deviceSummary = '🐧 $os';
            break;

          default:
            platform = defaultTargetPlatform.name;
            browser = 'App';
            iconType = 'unknown';
            deviceName = platform;
            os = platform;
            deviceModel = 'Device';
            deviceSummary = '📱 $platform';
        }
      }
    } catch (e) {
      debugPrint('[DeviceInfoService] Failed to gather device info: $e');
    }

    return {
      'platform': platform,
      'browser': browser,
      'os': os,
      'deviceName': deviceName,
      'deviceModel': deviceModel,
      'deviceSummary': deviceSummary,
      'appVersion': AutoUpdateService.currentVersion,
      'iconType': iconType,
      'isWeb': kIsWeb,
    };
  }

  static Timer? _presenceTimer;

  /// Starts a 2-minute periodic presence heartbeat loop for active user (Disabled to save Firestore quota)
  static void startPresenceHeartbeat() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  /// Stops presence heartbeat loop
  static void stopPresenceHeartbeat() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  /// Records active session details for the given user in Firestore.
  static Future<void> recordUserSession({String? userId, String? email}) async {
    try {
      final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return;

      final info = await getDeviceInfo();
      final sessionData = {
        'platform': info['platform'],
        'browser': info['browser'],
        'os': info['os'],
        'deviceName': info['deviceName'],
        'deviceModel': info['deviceModel'],
        'deviceSummary': info['deviceSummary'],
        'appVersion': info['appVersion'],
        'iconType': info['iconType'],
        'isWeb': info['isWeb'],
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final deviceKey = (info['isWeb'] == true)
          ? 'web_${info['browser']?.toString().toLowerCase().replaceAll(RegExp(r'\s+'), '_')}'
          : '${info['platform']?.toString().toLowerCase()}_${info['deviceName']?.toString().toLowerCase().replaceAll(RegExp(r'\s+'), '_')}';

      final firestore = FirebaseFirestore.instance;

      // 1. Update primary user document with last device info & multi-device map
      await firestore.collection('users').doc(uid).set({
        'lastDeviceInfo': sessionData,
        'devices.$deviceKey': sessionData,
        'appVersion': AutoUpdateService.currentVersion,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': true,
      }, SetOptions(merge: true));

      // 2. Also keep a user session record in user_sessions collection
      await firestore.collection('user_sessions').doc(uid).set({
        'userId': uid,
        if (email != null && email.isNotEmpty) 'email': email,
        'appVersion': AutoUpdateService.currentVersion,
        ...sessionData,
      }, SetOptions(merge: true));

      // 3. Also sync to branch collection doc if branchId is present
      try {
        final uDoc = await firestore.collection('users').doc(uid).get();
        if (uDoc.exists && uDoc.data() != null) {
          final bId = uDoc.data()!['branchId']?.toString();
          if (bId != null && bId.isNotEmpty && bId != 'all' && bId != 'global') {
            await firestore.collection('branches').doc(bId).collection('users').doc(uid).set({
              'lastDeviceInfo': sessionData,
              'devices.$deviceKey': sessionData,
              'appVersion': AutoUpdateService.currentVersion,
              'lastSeen': FieldValue.serverTimestamp(),
              'isOnline': true,
            }, SetOptions(merge: true));
          }
        }
      } catch (e) {
        debugPrint('[DeviceInfoService] Branch sync warning: $e');
      }

      startPresenceHeartbeat();
      debugPrint('[DeviceInfoService] Recorded session for user $uid: ${info['deviceSummary']}');
    } catch (e) {
      debugPrint('[DeviceInfoService] Failed to record user session: $e');
    }
  }

  /// Sets user status to offline on logout
  static Future<void> markUserOffline({String? userId}) async {
    stopPresenceHeartbeat();
    try {
      final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return;

      final firestore = FirebaseFirestore.instance;
      await firestore.collection('users').doc(uid).set({
        'isOnline': false,
        'lastSeen': FieldValue.serverTimestamp(),
        'lastDeviceInfo.isOnline': false,
      }, SetOptions(merge: true));

      await firestore.collection('user_sessions').doc(uid).set({
        'isOnline': false,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[DeviceInfoService] Failed to mark user offline: $e');
    }
  }

  /// Periodically touches user presence timestamp in Firestore (No-op to save Firestore quota)
  static Future<void> touchPresence() async {
    // Disabled to save Firestore quota
  }

  /// Returns whether a user document or session map represents an active online user.
  /// Strictly checks lastSeen/lastHeartbeat/updatedAt within [thresholdMinutes] (default 5 min).
  static bool isUserOnline(Map<String, dynamic>? userData, {int thresholdMinutes = 5}) {
    if (userData == null) return false;
    if (userData['isOnline'] == false) return false;

    dynamic rawTs = userData['lastSeen'] ??
        userData['lastOnlineAt'] ??
        userData['lastHeartbeat'] ??
        userData['lastActive'] ??
        userData['updatedAt'];

    if (rawTs == null && userData['lastDeviceInfo'] is Map) {
      final devMap = userData['lastDeviceInfo'] as Map;
      rawTs = devMap['lastSeen'] ?? devMap['updatedAt'];
    }

    DateTime? lastActiveDt;
    if (rawTs is Timestamp) {
      lastActiveDt = rawTs.toDate();
    } else if (rawTs is String && rawTs.isNotEmpty) {
      lastActiveDt = DateTime.tryParse(rawTs);
    }

    if (lastActiveDt != null) {
      final diffMinutes = DateTime.now().difference(lastActiveDt).inMinutes.abs();
      return diffMinutes <= thresholdMinutes;
    }

    return false;
  }
}
