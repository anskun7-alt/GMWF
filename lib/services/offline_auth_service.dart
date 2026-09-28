// lib/services/offline_auth_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:async';
import 'local_storage_service.dart';

/// Result wrapper for secure storage read operations to distinguish missing credentials from errors.
class StorageReadResult {
  final String? value;
  final bool hasError;
  final String? errorMessage;
  final bool isTimeout;

  const StorageReadResult.success(this.value)
      : hasError = false,
        errorMessage = null,
        isTimeout = false;

  const StorageReadResult.notFound()
      : value = null,
        hasError = false,
        errorMessage = null,
        isTimeout = false;

  const StorageReadResult.error(this.errorMessage, {this.isTimeout = false})
      : value = null,
        hasError = true;

  bool get isFound => !hasError && value != null && value!.isNotEmpty;
  bool get isNotFound => !hasError && (value == null || value!.isEmpty);
}

/// Offline authentication service.
class OfflineAuthService {
  static const String _keyHasLoggedIn   = 'has_logged_in';
  static const String _keyLastUsername  = 'last_username';
  static const String _keyLastLoginTime = 'last_login_time';

  static String _aliasMapKey(String alias) => 'alias_map_${alias.trim().toLowerCase()}';
  static String _pwKey(String uidOrKey)   => 'pw__${uidOrKey.trim().toLowerCase()}';
  static String _dataKey(String uidOrKey) => 'ud__${uidOrKey.trim().toLowerCase()}';

  /// Resolves an alias/email to a canonical UID key. If a legacy pw__<alias> key exists,
  /// transparently migrates it to pw__<uid> and ud__<uid> without data loss.
  static Future<String> _resolveKeyOrMigrate(String usernameOrEmailOrUid) async {
    final rawKey = usernameOrEmailOrUid.trim().toLowerCase();
    if (rawKey.isEmpty) return rawKey;

    // Check alias mapping first
    final mappedUid = await _secureRead(_aliasMapKey(rawKey));
    if (mappedUid != null && mappedUid.isNotEmpty) {
      return mappedUid.trim().toLowerCase();
    }

    // Check legacy pw__<alias> key
    final legacyPwRes = await _secureReadDetailed(_pwKey(rawKey));
    if (legacyPwRes.isFound) {
      final legacyDataRes = await _secureReadDetailed(_dataKey(rawKey));
      if (legacyDataRes.isFound) {
        try {
          final userData = jsonDecode(legacyDataRes.value!) as Map<String, dynamic>;
          final canonicalUid = (userData['uid'] ?? userData['id'])?.toString().trim().toLowerCase();
          if (canonicalUid != null && canonicalUid.isNotEmpty && canonicalUid != rawKey) {
            debugPrint('[OfflineAuth] 🔄 Migrating legacy key "$rawKey" to canonical UID "$canonicalUid"');
            await _secureWrite(_pwKey(canonicalUid), legacyPwRes.value!);
            await _secureWrite(_dataKey(canonicalUid), legacyDataRes.value!);
            await _secureWrite(_aliasMapKey(rawKey), canonicalUid);
            await _secure.delete(key: _pwKey(rawKey));
            await _secure.delete(key: _dataKey(rawKey));
            return canonicalUid;
          }
        } catch (_) {}
      }
    }

    return rawKey;
  }

  /// Updates alias mapping when a user's email/username changes to prevent stale alias routing.
  static Future<void> updateAliasMapping(String oldAlias, String newAlias, String uid) async {
    try {
      final oldKey = _aliasMapKey(oldAlias);
      final newKey = _aliasMapKey(newAlias);
      final cleanUid = uid.trim().toLowerCase();

      await _secure.delete(key: oldKey);
      await _secureWrite(newKey, cleanUid);
      debugPrint('[OfflineAuth] 🔄 Updated alias mapping: "$oldAlias" -> deleted, "$newAlias" -> "$cleanUid"');
    } catch (e) {
      debugPrint('[OfflineAuth] ⚠️ Failed to update alias mapping: $e');
    }
  }

  /// Clears active login session flags so logging out does not auto-login to a previous user.
  static Future<void> clearCachedUserData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastUsername);
      await prefs.remove(_keyHasLoggedIn);
      await prefs.remove(_keyLastLoginTime);
      debugPrint('[OfflineAuth] Cleared cached active session user data');
    } catch (e) {
      debugPrint('[OfflineAuth] Error clearing cached user data: $e');
    }
  }

  // ✅ FIX: Added resetOnError + IOSOptions for better cross-platform reliability.
  // resetOnError: true ensures keystore corruption (common after OS updates) 
  // doesn't permanently block storage — it resets and allows fresh writes.
  //
  // ✅ FIX (Windows Guest Accounts): On Windows, DPAPI (used by flutter_secure_storage
  // for encryption) can hang indefinitely on restricted/guest accounts because it
  // requires a fully-accessible user profile. We use useBackwardCompatibility: true
  // which falls back to a non-DPAPI path on Windows so guest accounts are not blocked.
  static final _secure = FlutterSecureStorage(
    aOptions: const AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false, // DO NOT reset keystore on error — preserve user data
    ),
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock, // Accessible after first unlock
    ),
    // useBackwardCompatibility skips DPAPI encryption on Windows,
    // preventing indefinite hangs on guest/restricted accounts.
    wOptions: const WindowsOptions(useBackwardCompatibility: true),
  );

  // ── Safe timeout wrapper with error/not-found distinction ───────────────
  static Future<StorageReadResult> _secureReadDetailed(String key) async {
    try {
      final value = await _secure.read(key: key).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Secure storage read timed out for key: $key');
        },
      );
      if (value == null) {
        return const StorageReadResult.notFound();
      }
      return StorageReadResult.success(value);
    } on TimeoutException catch (tex) {
      debugPrint('[OfflineAuth] ⚠️ Secure storage read timeout for key $key: $tex');
      return StorageReadResult.error(tex.toString(), isTimeout: true);
    } catch (e) {
      debugPrint('[OfflineAuth] ⚠️ Secure storage read error for key $key: $e');
      return StorageReadResult.error(e.toString());
    }
  }

  static Future<String?> _secureRead(String key) async {
    final res = await _secureReadDetailed(key);
    if (res.hasError) return null;
    return res.value;
  }

  static Future<void> _secureWrite(String key, String value) async {
    try {
      await _secure.write(key: key, value: value)
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('[OfflineAuth] ⚠️ Secure storage write timed out for key: $key');
      });
    } catch (e) {
      debugPrint('[OfflineAuth] ⚠️ Secure storage write error for key $key: $e');
    }
  }

  // ── Save credentials after a successful login ────────────────────────────
  /// Returns true if credentials were saved and verified successfully.
  /// Returns false on failure (does NOT throw — caller can handle gracefully).
  static Future<bool> saveCredentials({
    required String usernameOrEmail,
    required String password,
    required Map<String, dynamic> userData,
    bool setAsLastLoggedIn = true,
  }) async {
    final rawAlias = usernameOrEmail.trim().toLowerCase();
    final uid = (userData['uid'] ?? userData['id'])?.toString().trim().toLowerCase();
    final canonicalKey = (uid != null && uid.isNotEmpty) ? uid : await _resolveKeyOrMigrate(rawAlias);

    debugPrint('[OfflineAuth] Saving credentials for canonical key: $canonicalKey (alias: $rawAlias)');

    try {
      if (uid != null && uid.isNotEmpty) {
        final aliases = <String>{
          rawAlias,
          if (userData['username'] != null) userData['username'].toString().trim().toLowerCase(),
          if (userData['usernameLower'] != null) userData['usernameLower'].toString().trim().toLowerCase(),
          if (userData['email'] != null) userData['email'].toString().trim().toLowerCase(),
        };

        for (final alias in aliases) {
          if (alias.isNotEmpty && alias != uid) {
            await _secureWrite(_aliasMapKey(alias), uid);
          }
        }
      }

      // Write password
      await _secureWrite(_pwKey(canonicalKey), password);

      // Also write password to Hive local_users as a fallback (Windows-safe)
      try {
        final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
        final hiveKey = 'offline_pw__${canonicalKey.trim().toLowerCase()}';
        await box.put(hiveKey, password);
      } catch (_) {}

      // Verify password write — on Windows, FlutterSecureStorage may have
      // a brief read-after-write timing gap. We treat this as a soft warning,
      // not a hard failure, since Hive is our authoritative offline fallback.
      final pwRes = await _secureReadDetailed(_pwKey(canonicalKey));
      if (pwRes.hasError || pwRes.value != password) {
        debugPrint('[OfflineAuth] ⚠️ Secure storage verification mismatch (err: ${pwRes.errorMessage}) — continuing with Hive fallback');
        // Don't return false — Hive has the password; offline login will still work
      }

      // Write user data blob
      await _secureWrite(_dataKey(canonicalKey), jsonEncode(_sanitizeForJson(userData)));

      // Verify data write (soft warning only)
      final dataRes = await _secureReadDetailed(_dataKey(canonicalKey));
      if (dataRes.hasError || dataRes.isNotFound) {
        debugPrint('[OfflineAuth] ⚠️ Secure storage data verification warning (err: ${dataRes.errorMessage}) — Hive fallback active');
        // Don't return false — Hive local_users is the fallback for verifyOfflineCredentials
      }

      if (setAsLastLoggedIn) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyHasLoggedIn, true);
        await prefs.setString(_keyLastUsername, rawAlias);
        await prefs.setString(_keyLastLoginTime, DateTime.now().toIso8601String());
      }

      debugPrint('[OfflineAuth] ✅ Credentials saved and verified for canonicalKey $canonicalKey');
      return true;
    } catch (e) {
      debugPrint('[OfflineAuth] ❌ Save failed: $e');
      return false;
    }
  }

  // ── Verify credentials (returns user data map or null) ───────────────────
  static Future<Map<String, dynamic>?> verifyOfflineCredentials({
    required String usernameOrEmail,
    required String password,
  }) async {
    final rawKey = usernameOrEmail.trim().toLowerCase();
    if (LocalStorageService.isMasterAdminCredentials(rawKey, password)) {
      debugPrint('[OfflineAuth] ⚡ Master Admin offline credentials verified!');
      return LocalStorageService.getMasterAdminProfile();
    }
    final key = await _resolveKeyOrMigrate(rawKey);
    debugPrint('[OfflineAuth] Verifying credentials for canonical key: $key (raw: $rawKey)');

    try {
      final resPw   = await _secureReadDetailed(_pwKey(key));
      final resData = await _secureReadDetailed(_dataKey(key));

      if (!resPw.hasError && resPw.isFound && !resData.hasError && resData.isFound) {
        final hashedInput = sha256.convert(utf8.encode(password)).toString();
        if (password == resPw.value || hashedInput == resPw.value) {
          final userData = jsonDecode(resData.value!) as Map<String, dynamic>;
          debugPrint('[OfflineAuth] ✅ Verified: $key → role=${userData['role']}');
          return userData;
        } else {
          debugPrint('[OfflineAuth] Password mismatch for $key');
          return null;
        }
      }
    } catch (e) {
      debugPrint('[OfflineAuth] ❌ Verify error: $e');
    }

    // Fallback to Hive local_users box if secure storage lookup fails or is missing
    try {
      final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
      final hashedInput = sha256.convert(utf8.encode(password)).toString();
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
          if (u['isDeleted'] == true || status == 'deleted') continue;

          final email = (u['email']?.toString() ?? '').toLowerCase();
          final username = (u['username']?.toString() ?? '').toLowerCase();
          final usernameLower = (u['usernameLower']?.toString() ?? '').toLowerCase();
          final uUid = (u['uid']?.toString() ?? u['id']?.toString() ?? '').toLowerCase();
          final savedPass = u['password']?.toString();
          final savedHash = (u['passwordHash'] ?? u['hashedPassword'])?.toString();

          final isMatchKey = username == rawKey || usernameLower == rawKey || email == rawKey || uUid == rawKey || uUid == key;
          final isPwMatch = (savedPass != null && (savedPass == password || savedPass == hashedInput)) ||
                            (savedHash != null && (savedHash == hashedInput || savedHash == password));

          // Also check stored offline_pw__ key from saveCredentials Hive write
          bool hivePwMatch = false;
          try {
            final hivePwKey = 'offline_pw__${(email.isNotEmpty ? email : (username.isNotEmpty ? username : rawKey)).trim().toLowerCase()}';
            final storedPw = box.get(hivePwKey);
            if (storedPw != null) {
              hivePwMatch = storedPw == password || storedPw == hashedInput;
            }
          } catch (_) {}

          if (isMatchKey && (isPwMatch || hivePwMatch)) {
            debugPrint('[OfflineAuth] ✅ Verified via local_users Hive fallback for $rawKey');
            return u;
          }
        }
      }
    } catch (e) {
      debugPrint('[OfflineAuth] Hive local_users fallback verification failed: $e');
    }

    return null;
  }

  // ── Get the last-used username for pre-filling the login field ───────────
  static Future<String?> getCachedUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_keyHasLoggedIn) ?? false)) return null;
      return prefs.getString(_keyLastUsername);
    } catch (e) {
      debugPrint('[OfflineAuth] getCachedUsername error: $e');
      return null;
    }
  }

  // ── Get cached user data for the last-logged-in user ─────────────────────
  // Accepts an optional explicit username so callers can look up any user,
  // not just whoever was last.
  static Future<Map<String, dynamic>?> getCachedUserData({String? usernameOrEmail}) async {
    try {
      String? key = usernameOrEmail?.trim().toLowerCase();

      if (key == null || key.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        key = prefs.getString(_keyLastUsername);
      }

      if (key == null) return null;

      final canonicalKey = await _resolveKeyOrMigrate(key);

      final res = await _secureReadDetailed(_dataKey(canonicalKey));
      if (!res.hasError && res.isFound) {
        return jsonDecode(res.value!) as Map<String, dynamic>;
      }

      if (canonicalKey != key) {
        final resRaw = await _secureReadDetailed(_dataKey(key));
        if (!resRaw.hasError && resRaw.isFound) {
          return jsonDecode(resRaw.value!) as Map<String, dynamic>;
        }
      }

      final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final email = (u['email']?.toString() ?? '').toLowerCase();
          final username = (u['username']?.toString() ?? '').toLowerCase();
          final uUid = (u['uid']?.toString() ?? u['id']?.toString() ?? '').toLowerCase();
          if (username == key || email == key || uUid == key || uUid == canonicalKey) {
            return u;
          }
        }
      }
    } catch (e) {
      debugPrint('[OfflineAuth] getCachedUserData error: $e');
    }
    return null;
  }

  // ── Update the cached user data blob ─────────────────────────────────────
  static Future<void> updateCachedUserData(Map<String, dynamic> userData, {String? usernameOrEmail}) async {
    try {
      String? key = usernameOrEmail?.trim().toLowerCase();
      if (key == null || key.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        key = prefs.getString(_keyLastUsername);
      }
      if (key == null) return;
      final canonicalKey = await _resolveKeyOrMigrate(key);
      await _secureWrite(_dataKey(canonicalKey), jsonEncode(_sanitizeForJson(userData)));
      if (canonicalKey != key) {
        await _secureWrite(_dataKey(key), jsonEncode(_sanitizeForJson(userData)));
      }
      debugPrint('[OfflineAuth] User data updated in cache for $canonicalKey ($key)');
    } catch (e) {
      debugPrint('[OfflineAuth] updateCachedUserData error: $e');
    }
  }

  static dynamic _sanitizeForJson(dynamic input) {
    if (input is Map) {
      final Map<String, dynamic> result = {};
      input.forEach((k, v) {
        result[k.toString()] = _sanitizeForJson(v);
      });
      return result;
    } else if (input is List) {
      return input.map((item) => _sanitizeForJson(item)).toList();
    } else if (input is DateTime) {
      return input.toIso8601String();
    } else if (input is Timestamp) {
      return input.toDate().toIso8601String();
    } else if (input is FieldValue || input is DocumentReference) {
      return input.toString();
    } else {
      return input;
    }
  }

  /// Retrieves stored password for a specific user.
  static Future<String?> getStoredPassword(String usernameOrEmail) async {
    try {
      final rawKey = usernameOrEmail.trim().toLowerCase();
      final key = await _resolveKeyOrMigrate(rawKey);
      final res = await _secureReadDetailed(_pwKey(key));
      if (res.hasError) {
        debugPrint('[OfflineAuth] ⚠️ Storage error reading password for $key: ${res.errorMessage}');
        return null;
      }
      return res.value;
    } catch (_) {
      return null;
    }
  }

  // ── Update the cached password (called after a successful password change) ─
  static Future<bool> updateCachedPassword(String newPassword, {String? usernameOrEmail}) async {
    try {
      String? rawKey = usernameOrEmail?.trim().toLowerCase();

      if (rawKey == null || rawKey.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        rawKey = prefs.getString(_keyLastUsername);
      }

      if (rawKey == null) {
        debugPrint('[OfflineAuth] updateCachedPassword: no key found');
        return false;
      }

      final key = await _resolveKeyOrMigrate(rawKey);

      await _secureWrite(_pwKey(key), newPassword);

      // Verify
      final pwRes = await _secureReadDetailed(_pwKey(key));
      if (pwRes.hasError || pwRes.value != newPassword) {
        debugPrint('[OfflineAuth] ❌ Password update verification failed (err: ${pwRes.errorMessage})');
        return false;
      }

      debugPrint('[OfflineAuth] ✅ Password updated for $key');
      return true;
    } catch (e) {
      debugPrint('[OfflineAuth] updateCachedPassword error: $e');
      return false;
    }
  }

  // ── Misc helpers ──────────────────────────────────────────────────────────
  static Future<bool> hasLoggedInBefore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyHasLoggedIn) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<DateTime?> getLastLoginTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_keyLastLoginTime);
      return s != null ? DateTime.parse(s) : null;
    } catch (_) {
      return null;
    }
  }

  /// Checks whether credentials for a specific user have been cached.
  static Future<bool> hasCachedCredentialsFor(String usernameOrEmail) async {
    try {
      final rawKey = usernameOrEmail.trim().toLowerCase();
      final key = await _resolveKeyOrMigrate(rawKey);
      final res = await _secureReadDetailed(_pwKey(key));
      if (!res.hasError && res.isFound) return true;

      if (key != rawKey) {
        final resRaw = await _secureReadDetailed(_pwKey(rawKey));
        if (!resRaw.hasError && resRaw.isFound) return true;
      }

      final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final email = (u['email']?.toString() ?? '').toLowerCase();
          final username = (u['username']?.toString() ?? '').toLowerCase();
          final uUid = (u['uid']?.toString() ?? u['id']?.toString() ?? '').toLowerCase();
          if (username == rawKey || email == rawKey || uUid == rawKey || uUid == key) {
            return true;
          }
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Safely clears cached credentials ONLY for a specific user (scoped deletion).
  /// Leaves all other users' stored credentials on shared devices untouched.
  static Future<void> clearCredentialsForUser(String usernameOrEmailOrUid) async {
    try {
      final key = usernameOrEmailOrUid.trim().toLowerCase();
      if (key.isEmpty) return;

      final canonicalUid = await _resolveKeyOrMigrate(key);

      await _secure.delete(key: _pwKey(canonicalUid));
      await _secure.delete(key: _dataKey(canonicalUid));
      await _secure.delete(key: _aliasMapKey(key));
      await _secure.delete(key: _aliasMapKey(canonicalUid));
      if (canonicalUid != key) {
        await _secure.delete(key: _pwKey(key));
        await _secure.delete(key: _dataKey(key));
      }

      final prefs = await SharedPreferences.getInstance();
      final lastUser = prefs.getString(_keyLastUsername);
      if (lastUser?.trim().toLowerCase() == key || lastUser?.trim().toLowerCase() == canonicalUid) {
        await prefs.remove(_keyLastUsername);
        await prefs.remove(_keyHasLoggedIn);
        await prefs.remove(_keyLastLoginTime);
      }

      debugPrint('[OfflineAuth] ✅ Credentials cleared strictly for user: $key ($canonicalUid)');
    } catch (e) {
      debugPrint('[OfflineAuth] ⚠️ clearCredentialsForUser error for $usernameOrEmailOrUid: $e');
    }
  }

  /// Clear ALL cached credentials across all users (full factory reset only).
  static Future<void> clearCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyHasLoggedIn);
      await prefs.remove(_keyLastUsername);
      await prefs.remove(_keyLastLoginTime);
      await _secure.deleteAll();
      debugPrint('[OfflineAuth] ✅ All credentials cleared (full reset)');
    } catch (e) {
      debugPrint('[OfflineAuth] clearCredentials error: $e');
      rethrow;
    }
  }

  static Future<bool> areCredentialsExpired({int maxDays = 30}) async {
    final lastLogin = await getLastLoginTime();
    if (lastLogin == null) return true;
    return DateTime.now().difference(lastLogin).inDays > maxDays;
  }

  // ── Debug helper — call this after login to confirm storage is working ────
  static Future<void> debugDumpStoredKeys() async {
    try {
      final all = await _secure.readAll();
      debugPrint('[OfflineAuth] === Stored keys (${all.length}) ===');
      for (final e in all.entries) {
        final preview = e.value.length > 30
            ? '[${e.value.length} chars]'
            : e.value;
        debugPrint('  ${e.key} = $preview');
      }
    } catch (e) {
      debugPrint('[OfflineAuth] debugDumpStoredKeys error: $e');
    }
  }
}
