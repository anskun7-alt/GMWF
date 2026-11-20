import 'dart:async';
import 'cloud/lan_firestore_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GThemeChoice;
import '../theme/app_visual_theme.dart';

class ThemeValueNotifier extends ValueNotifier<bool> {
  ThemeValueNotifier(super.value);
  void notifyTheme() {
    notifyListeners();
  }
}

/// Service to manage Per-User Theme Preferences (theme + Dark / Light mode).
/// Light mode is ALWAYS the default.
/// Preferences of User A do NOT affect User B on the same device.
///
/// One setting decides the colours everywhere (2026-11-17): [GThemeChoice] —
/// GMWF, Nexus or Twilight — plus the separate dark-mode switch. The older
/// four presets (AppVisualTheme) are derived from it for code that still reads
/// them; saved older choices are converted (Classic / Emerald → GMWF,
/// Nexus Core → Nexus, Midnight Plum → Twilight).
class UserThemeService {
  static final ThemeValueNotifier currentThemeNotifier = ThemeValueNotifier(false);
  static const AppVisualTheme defaultVisualTheme = AppVisualTheme.emeraldMeridianHybrid;
  static const GThemeChoice defaultThemeChoice = GThemeChoice.gmwf;

  /// School-specific roles default to the Nexus theme until the user picks
  /// another theme in Settings (School ERP Phase 6, 2026-11-17).
  static bool isSchoolDefaultRole(String? role) {
    final r = (role ?? '').toLowerCase().replaceAll(RegExp(r'[_\-]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (r.isEmpty) return false;
    bool word(String w) => RegExp('(^| )${RegExp.escape(w)}( |\$)').hasMatch(r);
    if (word('chairman') || word('ceo') || r.contains('hq manager') || r == 'admin' || r == 'super admin' || r == 'superadmin') {
      return false;
    }
    return word('principal') ||
        word('headmaster') ||
        word('headmistress') ||
        r == 'school' ||
        r == 'school admin' ||
        r == 'school administrator' ||
        word('teacher') ||
        word('librarian') ||
        (word('school') && word('accountant'));
  }

  static GThemeChoice defaultThemeChoiceForRole(String? role) =>
      isSchoolDefaultRole(role) ? GThemeChoice.nexus : defaultThemeChoice;

  static String? _activeUserRole() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final data = box.get('user_data') ?? box.get('currentUser') ?? box.get('user');
        if (data is Map) {
          final role = data['role']?.toString().trim();
          if (role != null && role.isNotEmpty) return role;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Hive key for a user's theme choice.
  static String getThemeChoiceKey([String? explicitUserKey]) => 'theme_choice_${getActiveUserKey(explicitUserKey)}';

  /// The user's theme (GMWF / Nexus / Twilight). Falls back to an older saved
  /// preset, then to the role default (Nexus for school roles, GMWF otherwise).
  static GThemeChoice getThemeChoice([String? explicitUserKey, String? role]) {
    final effectiveRole = (role != null && role.trim().isNotEmpty) ? role : _activeUserRole();
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        // 1. Per-user explicit choice always wins.
        for (final key in [
          getThemeChoiceKey(explicitUserKey),
          getVisualThemeKey(explicitUserKey),
        ]) {
          final raw = box.get(key)?.toString();
          if (raw != null && raw.trim().isNotEmpty) return GThemeChoice.fromStorageKey(raw);
        }
        // 2. Fresh school users default to Nexus rather than inheriting another
        //    non-school user's global fallback key on the same device.
        if (isSchoolDefaultRole(effectiveRole)) {
          return GThemeChoice.nexus;
        }
        // 3. Global fallback for non-school / guest sessions.
        for (final key in const ['theme_choice', 'visual_theme']) {
          final raw = box.get(key)?.toString();
          if (raw != null && raw.trim().isNotEmpty) return GThemeChoice.fromStorageKey(raw);
        }
      }
    } catch (_) {}
    return defaultThemeChoiceForRole(effectiveRole);
  }

  /// The older preset that matches a theme choice (for code that still reads presets).
  static AppVisualTheme legacyPresetFor(GThemeChoice choice, bool isDark) => switch (choice) {
        GThemeChoice.gmwf => AppVisualTheme.emeraldMeridianHybrid,
        GThemeChoice.nexus => AppVisualTheme.nexusCoreHybrid,
        GThemeChoice.twilight => AppVisualTheme.midnightPlumHybrid,
      }.pairedForDarkMode(isDark);

  /// Saves the user's theme choice (dark mode is unchanged).
  static Future<void> setThemeChoice(GThemeChoice choice, {String? explicitUserKey}) async {
    try {
      final isDark = isDarkMode(explicitUserKey);
      final legacy = legacyPresetFor(choice, isDark);
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.putAll({
          if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty)
            'active_user_id': explicitUserKey.trim(),
          getThemeChoiceKey(explicitUserKey): choice.storageKey,
          'theme_choice': choice.storageKey,
          getVisualThemeKey(explicitUserKey): legacy.storageKey,
          'visual_theme': legacy.storageKey,
        });
      }
      currentThemeNotifier.notifyTheme();
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && !user.isAnonymous) {
        unawaited(LanFirestoreGate.mergeDoc('users/${user.uid}', {
          'themeChoice': choice.storageKey,
          'visualTheme': legacy.storageKey,
          'lastThemeUpdate': FieldValue.serverTimestamp(),
        }));
      }
    } catch (e) {
      debugPrint('[UserThemeService] Error setting theme choice: $e');
    }
  }

  /// Initializes and synchronizes current theme notifier and Hive box keys.
  static void init([String? explicitUserKey]) {
    try {
      final isDark = isDarkMode(explicitUserKey);
      final theme = getVisualTheme(explicitUserKey);
      currentThemeNotifier.value = isDark;
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        box.put('is_dark_mode', isDark);
        box.put('visual_theme', theme.storageKey);
      }
    } catch (_) {}
  }

  /// Notifies all active theme listeners that custom accent color or theme settings changed
  static void notifyThemeChanged() {
    final isDark = isDarkMode();
    currentThemeNotifier.value = isDark;
    if (Hive.isBoxOpen('app_settings')) {
      try {
        Hive.box('app_settings').put('is_dark_mode', isDark);
      } catch (_) {}
    }
    currentThemeNotifier.notifyTheme();
  }

  /// Resolved active user key (UID, email, or guest)
  static String getActiveUserKey([String? explicitUserKey]) {
    if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty) {
      return explicitUserKey.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final data = box.get('user_data') ?? box.get('currentUser') ?? box.get('user');
        if (data is Map) {
          final id = data['uid'] ?? data['id'] ?? data['username'] ?? data['userName'] ?? data['email'];
          if (id != null && id.toString().trim().isNotEmpty) {
            return id.toString().trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
          }
        }
        final activeUser = box.get('active_user_id') ?? box.get('last_username') ?? box.get('active_login_user');
        if (activeUser != null && activeUser.toString().trim().isNotEmpty) {
          return activeUser.toString().trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        }
      }
    } catch (_) {}

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.uid.isNotEmpty) {
        return user.uid.trim().toLowerCase();
      }
      if (user != null && user.email != null && user.email!.isNotEmpty) {
        return user.email!.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      }
    } catch (_) {}

    return 'default_guest';
  }

  /// The Hive storage key for a specific user's dark mode setting
  static String getStorageKey([String? explicitUserKey]) {
    final userKey = getActiveUserKey(explicitUserKey);
    return 'is_dark_mode_$userKey';
  }

  /// The Hive storage key for a specific user's visual theme preset
  static String getVisualThemeKey([String? explicitUserKey]) {
    final userKey = getActiveUserKey(explicitUserKey);
    return 'visual_theme_$userKey';
  }

  /// Whether dark mode is enabled for the specified or active user.
  /// Default is ALWAYS `false` (Light / Hybrid Mode).
  static bool isDarkMode([String? explicitUserKey]) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final userKey = getStorageKey(explicitUserKey);
        final keyedValue = box.get(userKey);
        if (keyedValue is bool) {
          return keyedValue;
        }
        final fallback = box.get('is_dark_mode');
        if (fallback is bool) {
          return fallback;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Resolves the active [AppVisualTheme] for the specified or active user,
  /// always consistent with [isDarkMode].
  static AppVisualTheme getVisualTheme([String? explicitUserKey]) =>
      legacyPresetFor(getThemeChoice(explicitUserKey), isDarkMode(explicitUserKey));
  /// Sets the dark mode setting for the specified or active user, preserving
  /// their active theme family by switching to its light/dark twin.
  static Future<void> setDarkMode(bool isDark, {String? explicitUserKey, String? branchId}) async {
    try {
      final pairedTheme = getVisualTheme(explicitUserKey).pairedForDarkMode(isDark);
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final userKey = getStorageKey(explicitUserKey);
        final visualKey = getVisualThemeKey(explicitUserKey);
        await box.putAll({
          if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty)
            'active_user_id': explicitUserKey.trim(),
          userKey: isDark,
          'is_dark_mode': isDark,
          visualKey: pairedTheme.storageKey,
          'visual_theme': pairedTheme.storageKey,
        });
      }
      currentThemeNotifier.value = isDark;
      currentThemeNotifier.notifyTheme();

      // Sync to Firestore user profile in background if available
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && !user.isAnonymous) {
        unawaited(LanFirestoreGate.mergeDoc('users/${user.uid}', {
          'isDarkMode': isDark,
          'visualTheme': pairedTheme.storageKey,
          'lastThemeUpdate': FieldValue.serverTimestamp(),
        }));
      }
    } catch (e) {
      debugPrint('[UserThemeService] Error setting dark mode: $e');
    }
  }

  /// Selects a visual theme preset for the specified or active user and
  /// synchronizes light/dark mode automatically.
  static Future<void> setVisualTheme(
    AppVisualTheme theme, {
    String? explicitUserKey,
    String? branchId,
    bool clearCustomAccent = true,
  }) async {
    try {
      final isDark = theme.isDark;
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final userKey = getStorageKey(explicitUserKey);
        final visualKey = getVisualThemeKey(explicitUserKey);
        final choice = GThemeChoice.fromStorageKey(theme.storageKey);
        await box.putAll({
          if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty)
            'active_user_id': explicitUserKey.trim(),
          visualKey: theme.storageKey,
          'visual_theme': theme.storageKey,
          getThemeChoiceKey(explicitUserKey): choice.storageKey,
          'theme_choice': choice.storageKey,
          userKey: isDark,
          'is_dark_mode': isDark,
        });
        if (clearCustomAccent && box.containsKey('custom_accent_color')) {
          await box.delete('custom_accent_color');
        }
      }
      currentThemeNotifier.value = isDark;
      currentThemeNotifier.notifyTheme();

      final user = FirebaseAuth.instance.currentUser;
      if (user != null && !user.isAnonymous) {
        unawaited(LanFirestoreGate.mergeDoc('users/${user.uid}', {
          'isDarkMode': isDark,
          'visualTheme': theme.storageKey,
          'lastThemeUpdate': FieldValue.serverTimestamp(),
        }));
      }
    } catch (e) {
      debugPrint('[UserThemeService] Error setting visual theme: $e');
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
    final visualKey = getVisualThemeKey(explicitUserKey);
    return Hive.box('app_settings').listenable(
      keys: [key, 'is_dark_mode', visualKey, 'visual_theme', getThemeChoiceKey(explicitUserKey), 'theme_choice'],
    );
  }
}
