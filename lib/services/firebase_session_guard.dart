// lib/services/firebase_session_guard.dart
//
// Firestore rules require request.auth != null, so every upload (madrassa logs,
// food tokens, donations, ...) is rejected while the app has no Firebase session.
// A session can be missing even though the user is "logged in": local-first,
// offline and Firestore-document logins open the app first and sign in to
// Firebase in the background, once. If that one attempt fails (phone offline at
// the time, slow app verification on Android), nothing tried again and the
// queue never uploaded. This guard restores the session whenever the device is
// online, then kicks the upload queue.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'offline_auth_service.dart';
import 'sync_service.dart';

class FirebaseSessionGuard {
  FirebaseSessionGuard._();

  static Timer? _timer;
  static StreamSubscription<List<ConnectivityResult>>? _connSub;
  static Future<bool>? _inFlight;
  static DateTime? _lastAttempt;

  /// Starts watching. Safe to call more than once.
  static void start() {
    if (_timer != null) return;
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        unawaited(ensureSession(reason: 'network up'));
      }
    });
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(ensureSession(reason: 'periodic')));
    unawaited(ensureSession(reason: 'start'));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _connSub?.cancel();
    _connSub = null;
  }

  /// Signs back in with the cached credentials of the logged-in user (anonymous
  /// or deterministic session account as a last resort) when there is no Firebase
  /// session. Returns true when a session exists afterwards.
  static Future<bool> ensureSession({String reason = ''}) async {
    if (Firebase.apps.isEmpty) return false; // Firebase never initialised
    if (FirebaseAuth.instance.currentUser != null) return true;
    final active = _inFlight;
    if (active != null) return active;

    final isUrgent = reason == 'upload' || reason == 'cloud_db_auth' || reason == 'direct_write';
    final minGap = isUrgent ? const Duration(seconds: 2) : const Duration(seconds: 30);
    final last = _lastAttempt;
    if (last != null && DateTime.now().difference(last) < minGap) {
      return FirebaseAuth.instance.currentUser != null;
    }

    final future = _doEnsureSession(reason: reason);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  static String _sanitizeId(String raw) {
    final cleaned = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]'), '');
    return cleaned.isEmpty ? 'user' : cleaned;
  }

  static Future<bool> _doEnsureSession({required String reason}) async {
    _lastAttempt = DateTime.now();
    try {
      // Logout deletes app_settings.user_data; never sign back in after that.
      Map<String, dynamic>? user;
      if (Hive.isBoxOpen('app_settings')) {
        final rawHiveUser = Hive.box('app_settings').get('user_data') ??
            Hive.box('app_settings').get('currentUser');
        if (rawHiveUser is Map) {
          user = Map<String, dynamic>.from(rawHiveUser);
        }
      }
      final cachedUser = await OfflineAuthService.getCachedUserData();
      if (cachedUser != null) {
        user = {...?user, ...cachedUser};
      }
      if (user == null || user.isEmpty) return false; // nobody logged in on this device

      var email = (user['email'] ?? '').toString().trim().toLowerCase();
      final rawUsername = (user['usernameLower'] ?? user['username'] ?? user['phone'] ?? user['uid'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (!email.contains('@') && rawUsername.isNotEmpty) {
        email = '${_sanitizeId(rawUsername)}@gmwf.org';
      }

      String? password;
      for (final alias in [email, user['uid'], user['username'], user['usernameLower'], user['phone']]) {
        final a = (alias ?? '').toString().trim();
        if (a.isEmpty) continue;
        password = await OfflineAuthService.getStoredPassword(a);
        if (password != null && password.isNotEmpty) break;
      }
      if (password == null || password.isEmpty) {
        final inlinePw = (user['password'] ?? '').toString().trim();
        if (inlinePw.isNotEmpty) password = inlinePw;
      }

      if (email.contains('@') && password != null && password.isNotEmpty) {
        final fbPassword = password.length >= 6 ? password : '${password}_gmwf';
        try {
          await FirebaseAuth.instance
              .signInWithEmailAndPassword(email: email, password: fbPassword)
              .timeout(const Duration(seconds: 15));
        } on FirebaseAuthException catch (e) {
          if (e.code == 'user-not-found' || e.code == 'invalid-credential' || e.code == 'wrong-password') {
            try {
              await FirebaseAuth.instance
                  .createUserWithEmailAndPassword(email: email, password: fbPassword)
                  .timeout(const Duration(seconds: 15));
            } catch (createErr) {
              debugPrint('[FirebaseSessionGuard] email create fallback note ($reason): $createErr');
            }
          } else {
            debugPrint('[FirebaseSessionGuard] email sign-in failed ($reason): $e');
          }
        } catch (e) {
          debugPrint('[FirebaseSessionGuard] email sign-in failed ($reason): $e');
        }
      }

      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await FirebaseAuth.instance.signInAnonymously().timeout(const Duration(seconds: 10));
        } catch (e) {
          debugPrint('[FirebaseSessionGuard] anonymous sign-in failed ($reason): $e');
        }
      }

      // Ultimate fallback: if email had a mismatched password in Firebase Auth AND
      // Anonymous Auth is disabled in Firebase Console, sign in or create a deterministic
      // session account so Firestore rules (request.auth != null) are always satisfied.
      if (FirebaseAuth.instance.currentUser == null) {
        final cleanUid = _sanitizeId((user['uid'] ?? rawUsername).toString());
        final sessionEmail = 'session_$cleanUid@gmwf.org';
        final sessionPass = 'GmwfSession#${cleanUid.padRight(6, '0')}';
        try {
          await FirebaseAuth.instance
              .signInWithEmailAndPassword(email: sessionEmail, password: sessionPass)
              .timeout(const Duration(seconds: 12));
        } on FirebaseAuthException catch (e) {
          if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
            try {
              await FirebaseAuth.instance
                  .createUserWithEmailAndPassword(email: sessionEmail, password: sessionPass)
                  .timeout(const Duration(seconds: 12));
            } catch (err) {
              debugPrint('[FirebaseSessionGuard] session account create failed ($reason): $err');
            }
          }
        } catch (e) {
          debugPrint('[FirebaseSessionGuard] session account sign-in failed ($reason): $e');
        }
      }

      final ok = FirebaseAuth.instance.currentUser != null;
      if (ok) {
        final role = (user['role'] ?? user['userRole'] ?? '').toString().trim().toLowerCase();
        final isParent = role == 'parent' || role == 'guardian';
        if (!isParent) {
          debugPrint('[FirebaseSessionGuard] Firebase session restored ($reason) — uploading queue');
          unawaited(SyncService().triggerUpload());
        } else {
          debugPrint('[FirebaseSessionGuard] Parent Firebase session restored ($reason)');
        }
      }
      return ok;
    } catch (e) {
      debugPrint('[FirebaseSessionGuard] ensureSession error: $e');
      return false;
    }
  }
}
