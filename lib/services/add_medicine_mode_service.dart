// lib/services/add_medicine_mode_service.dart
//
// Per-user preferred mode ("Guided" vs "Express") for the Add Medicine screen.
//
// Storage rules:
// - Reads ONLY from local Hive (`app_settings`), keyed by active user ID, so opening
//   Add Medicine works offline and costs ZERO Firestore reads.
// - Falls back to `user_data['addMedicineMode']` (already cached locally on login) so
//   a user's preference follows them to other devices without an extra read.
// - Default for any user who has never chosen is Guided.
// - Only when the preference actually changes, enqueues ONE tiny write through the
//   existing sync queue (`sync_box` / `SyncService`, type `save_user_preference`).

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'local_storage_service.dart';

enum AddMedicineMode {
  guided('guided', 'Guided'),
  express('express', 'Express');

  final String storageKey;
  final String label;

  const AddMedicineMode(this.storageKey, this.label);

  static AddMedicineMode? tryParse(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v == 'guided') return AddMedicineMode.guided;
    if (v == 'express') return AddMedicineMode.express;
    return null;
  }

  static AddMedicineMode fromStorageKey(String? raw) =>
      tryParse(raw) ?? AddMedicineMode.guided;
}

class AddMedicineModeService {
  AddMedicineModeService._();

  static const String _settingsBox = 'app_settings';
  static const String _modePrefix = 'add_medicine_mode_';
  static const String _promptSeenPrefix = 'add_medicine_mode_chosen_';

  /// Resolves a stable, normalized per-user key matching UserThemeService / UserLanguageService.
  static String getActiveUserKey([String? explicitUserKey]) {
    if (explicitUserKey != null && explicitUserKey.trim().isNotEmpty) {
      return _normalizeKey(explicitUserKey);
    }

    try {
      if (Hive.isBoxOpen(_settingsBox)) {
        final box = Hive.box(_settingsBox);
        final data = box.get('user_data') ?? box.get('currentUser') ?? box.get('user');
        if (data is Map) {
          final id = data['uid'] ?? data['id'] ?? data['username'] ?? data['userName'] ?? data['email'];
          if (id != null && id.toString().trim().isNotEmpty) {
            return _normalizeKey(id.toString());
          }
        }
        final activeUser = box.get('active_user_id') ?? box.get('last_username') ?? box.get('active_login_user');
        if (activeUser != null && activeUser.toString().trim().isNotEmpty) {
          return _normalizeKey(activeUser.toString());
        }
      }
    } catch (_) {}

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.uid.isNotEmpty) {
        return _normalizeKey(user.uid);
      }
      if (user != null && user.email != null && user.email!.isNotEmpty) {
        return _normalizeKey(user.email!);
      }
    } catch (_) {}

    return 'default_guest';
  }

  static String _normalizeKey(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  static String _resolveRawUid([String? explicitUid]) {
    if (explicitUid != null && explicitUid.trim().isNotEmpty) {
      return explicitUid.trim();
    }
    try {
      if (Hive.isBoxOpen(_settingsBox)) {
        final box = Hive.box(_settingsBox);
        final data = box.get('user_data') ?? box.get('currentUser');
        if (data is Map) {
          final id = (data['uid'] ?? data['id'] ?? '').toString().trim();
          if (id.isNotEmpty) return id;
        }
      }
    } catch (_) {}
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      if (uid.isNotEmpty) return uid;
    } catch (_) {}
    return '';
  }

  static String modeKey([String? explicitUserKey]) =>
      '$_modePrefix${getActiveUserKey(explicitUserKey)}';

  static String promptSeenKey([String? explicitUserKey]) =>
      '$_promptSeenPrefix${getActiveUserKey(explicitUserKey)}';

  /// Reads the user's preferred mode strictly from local Hive (zero Firestore reads).
  /// Defaults to [AddMedicineMode.guided] if never chosen.
  static AddMedicineMode getPreferredMode([String? explicitUserKey]) {
    try {
      if (Hive.isBoxOpen(_settingsBox)) {
        final box = Hive.box(_settingsBox);
        final localVal = AddMedicineMode.tryParse(box.get(modeKey(explicitUserKey))?.toString());
        if (localVal != null) return localVal;

        // Fallback to profile field already cached on login (still zero Firestore reads).
        final data = box.get('user_data') ?? box.get('currentUser');
        if (data is Map) {
          final syncedVal = AddMedicineMode.tryParse(data['addMedicineMode']?.toString());
          if (syncedVal != null) {
            // Cache locally under the per-user key so future reads hit directly.
            box.put(modeKey(explicitUserKey), syncedVal.storageKey);
            box.put(promptSeenKey(explicitUserKey), true);
            return syncedVal;
          }
        }
      }
    } catch (e) {
      debugPrint('[AddMedicineModeService] read error: $e');
    }
    return AddMedicineMode.guided;
  }

  /// True on a user's first visit before they choose or dismiss the mode intro.
  static bool shouldShowFirstRunPrompt([String? explicitUserKey]) {
    try {
      if (!Hive.isBoxOpen(_settingsBox)) return false;
      final box = Hive.box(_settingsBox);
      if (box.get(promptSeenKey(explicitUserKey)) == true) return false;
      if (AddMedicineMode.tryParse(box.get(modeKey(explicitUserKey))?.toString()) != null) {
        return false;
      }
      final data = box.get('user_data') ?? box.get('currentUser');
      if (data is Map && AddMedicineMode.tryParse(data['addMedicineMode']?.toString()) != null) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Marks the first-run prompt dismissed (keeping Guided as default without writing cloud).
  static Future<void> dismissFirstRunPrompt({String? explicitUserKey}) async {
    try {
      final box = Hive.isBoxOpen(_settingsBox)
          ? Hive.box(_settingsBox)
          : await LocalStorageService.ensureBoxOpen(_settingsBox);
      await box.put(promptSeenKey(explicitUserKey), true);
      if (AddMedicineMode.tryParse(box.get(modeKey(explicitUserKey))?.toString()) == null) {
        await box.put(modeKey(explicitUserKey), AddMedicineMode.guided.storageKey);
      }
    } catch (e) {
      debugPrint('[AddMedicineModeService] dismissFirstRunPrompt error: $e');
    }
  }

  /// Saves [mode] locally in Hive immediately. Only when the stored value changes,
  /// pushes one tiny preference update through `sync_box` / `SyncService` so it
  /// follows the user to other devices.
  static Future<void> setPreferredMode(
    AddMedicineMode mode, {
    String? explicitUserKey,
    String? explicitUid,
    String? branchId,
  }) async {
    try {
      final box = Hive.isBoxOpen(_settingsBox)
          ? Hive.box(_settingsBox)
          : await LocalStorageService.ensureBoxOpen(_settingsBox);

      final mKey = modeKey(explicitUserKey);
      final sKey = promptSeenKey(explicitUserKey);
      final previous = AddMedicineMode.tryParse(box.get(mKey)?.toString());
      final changed = previous != mode;

      await box.put(mKey, mode.storageKey);
      await box.put(sKey, true);

      // Keep cached user profile maps in sync locally.
      for (final profileKey in const ['user_data', 'currentUser']) {
        final existing = box.get(profileKey);
        if (existing is Map) {
          final updated = Map<String, dynamic>.from(existing);
          updated['addMedicineMode'] = mode.storageKey;
          await box.put(profileKey, updated);
        }
      }

      if (!changed) return;

      final uid = _resolveRawUid(explicitUid);
      if (uid.isEmpty || uid == 'master-local-admin') return;

      final resolvedBranch = (branchId != null && branchId.trim().isNotEmpty)
          ? branchId.trim()
          : (LocalStorageService.getActiveBranchId() ?? 'karachi');

      await LocalStorageService.enqueueSync({
        'type': 'save_user_preference',
        'uid': uid,
        'branchId': resolvedBranch,
        'entityId': 'user_pref_${uid}_addMedicineMode',
        'data': {
          'addMedicineMode': mode.storageKey,
        },
      });
    } catch (e) {
      debugPrint('[AddMedicineModeService] setPreferredMode error: $e');
    }
  }
}
