// lib/services/pre_login_security_service.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'device_info_service.dart';

class PreLoginSecurityService {
  static const String _deviceIdKey = 'gmwf_secure_device_id';

  /// Generates or retrieves a persistent unique device ID for hardware identification.
  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString(_deviceIdKey);
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = 'dev_${const Uuid().v4()}';
        await prefs.setString(_deviceIdKey, deviceId);
      }
      return deviceId;
    } catch (e) {
      return 'dev_unknown';
    }
  }

  /// Attempts to fetch the current public IP address of the device.
  static Future<String> fetchPublicIp() async {
    try {
      final res = await http.get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['ip']?.toString() ?? 'Unknown IP';
      }
    } catch (e) {
      debugPrint('[PreLoginSecurity] Could not fetch public IP: $e');
    }
    return 'Unavailable / Offline';
  }

  /// Logs pre-login app launches to Firestore security_access_logs.
  static Future<void> logAppLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastLogMs = prefs.getInt('pre_login_last_logged_at') ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastLogMs < 2 * 60 * 60 * 1000) {
        // Logged within the last 2 hours; skip writing to Firestore to conserve quota
        return;
      }
      await prefs.setInt('pre_login_last_logged_at', nowMs);

      final deviceId = await getDeviceId();
      final publicIp = await fetchPublicIp();
      final deviceInfo = await DeviceInfoService.getDeviceInfo();

      final accessLogData = {
        'eventType': 'APP_LAUNCH_UNAUTHENTICATED',
        'deviceId': deviceId,
        'publicIp': publicIp,
        'platform': deviceInfo['platform'],
        'browser': deviceInfo['browser'],
        'os': deviceInfo['os'],
        'deviceModel': deviceInfo['deviceModel'],
        'deviceSummary': deviceInfo['deviceSummary'],
        'timestamp': FieldValue.serverTimestamp(),
        'createdAt': DateTime.now().toIso8601String(),
      };

      // 1. Record launch in security_access_logs collection
      final docRef = FirebaseFirestore.instance.collection('security_access_logs').doc();
      await docRef.set(accessLogData);

      // 2. Also track/update active device registry in app_visitors collection
      await FirebaseFirestore.instance.collection('app_visitors').doc(deviceId).set({
        'deviceId': deviceId,
        'lastPublicIp': publicIp,
        'lastDeviceInfo': deviceInfo,
        'lastLaunchAt': FieldValue.serverTimestamp(),
        'totalLaunches': FieldValue.increment(1),
      }, SetOptions(merge: true));

      debugPrint('[PreLoginSecurity] Logged app launch: IP=$publicIp | Device=$deviceId | ${deviceInfo['deviceSummary']}');
    } catch (e) {
      debugPrint('[PreLoginSecurity] Failed to log pre-login launch: $e');
    }
  }
}
