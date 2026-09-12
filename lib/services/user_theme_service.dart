import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ThemeValueNotifier extends ValueNotifier<bool> {
  ThemeValueNotifier(super.value);
  void notifyTheme() {
    notifyListeners();
  }
}

/// Service to manage Per-User Theme Preferences (Dark / Light mode).
/// Light Mode is ALWAYS the default.
/// Preferences of User A do NOT affect User B on the same device.
class UserThemeService {
  static const String _globalThemeKey = 'is_dark_mode';
  static final ThemeValueNotifier currentThemeNotifier = ThemeValueNotifier(false);

  /// Notifies all active theme listeners that custom accent color or theme settings changed
  static void notifyThemeChanged() {
    currentThemeNotifier.value = isDarkMode();
    currentThemeNotifier.notifyTheme();
  }

  /// Resolved active user key (UID, email, or guest)
  static String getActiveUserKey([String? explicitUserKey]) {
    if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty) {
      return explicitUserKey.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    }

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.uid.isNotEmpty) {
        return user.uid.trim().toLowerCase();
      }
      if (user != null && user.email != null && user.email!.isNotEmpty) {
        return user.email!.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      }
    } catch (_) {}

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final activeUser = box.get('active_user_id') ?? box.get('last_username') ?? box.get('active_login_user');
        if (activeUser != null && activeUser.toString().trim().isNotEmpty) {
          return activeUser.toString().trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        }
      }
    } catch (_) {}

    return 'default_guest';
  }

  /// The Hive storage key for a specific user
  static String getStorageKey([String? explicitUserKey]) {
    final userKey = getActiveUserKey(explicitUserKey);
    return 'is_dark_mode_$userKey';
  }

  /// Whether dark mode is enabled for the specified or active user.
  /// Default is ALWAYS `false` (Light Mode).
  static bool isDarkMode([String? explicitUserKey]) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final userKey = getStorageKey(explicitUserKey);
        final keyedValue = box.get(userKey);
        if (keyedValue != null) {
          return keyedValue == true;
        }
        final globalValue = box.get(_globalThemeKey, defaultValue: false);
        return globalValue == true;
      }
    } catch (_) {}
    return false;
  }

  /// Sets the dark mode setting for the specified or active user.
  static Future<void> setDarkMode(bool isDark, {String? explicitUserKey, String? branchId}) async {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final userKey = getStorageKey(explicitUserKey);
        await box.put(userKey, isDark);
        await box.put(_globalThemeKey, isDark);
      }
      currentThemeNotifier.value = isDark;

      // Sync to Firestore user profile in background if available
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && !user.isAnonymous) {
        FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'isDarkMode': isDark,
          'lastThemeUpdate': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).catchError((_) {});
      }
    } catch (e) {
      debugPrint('[UserThemeService] Error setting dark mode: $e');
    }
  }

  /// Toggles dark mode for the specified or active user and returns the new value.
  static Future<bool> toggleDarkMode({String? explicitUserKey, String? branchId}) async {
    final current = isDarkMode(explicitUserKey);
    final next = !current;
    await setDarkMode(next, explicitUserKey: explicitUserKey, branchId: branchId);
    return next;
  }

  /// Returns a ValueListenable that fires when the user's theme setting changes.
  static ValueListenable<Box> listenable([String? explicitUserKey]) {
    final key = getStorageKey(explicitUserKey);
    return Hive.box('app_settings').listenable(keys: [key, 'is_dark_mode']);
  }
}
