// lib/pages/login_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive/hive.dart';
import 'package:another_flushbar/flushbar.dart';

import '../services/offline_auth_service.dart';
import '../services/device_info_service.dart';
import '../services/pre_login_security_service.dart';
import '../services/role_simulator_service.dart';
import '../services/auto_update_service.dart';
import '../widgets/update_dialog_widget.dart';
import 'home_router.dart';
import 'access_revoked_screen.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameOrEmailController = TextEditingController();
  final _passwordController        = TextEditingController();
  final _scrollController          = ScrollController();
  final _usernameFocus             = FocusNode();
  final _passwordFocus             = FocusNode();

  bool _loading         = false;
  bool _obscurePassword = true;
  bool _loginHover      = false;
  bool _isOnline        = true;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _autoOnlineCheckTimer;

  @override
  void initState() {
    super.initState();
    _checkConnectivityFast();
    _loadCachedCredentials();

    // Pre-authentication security logging & Auto-update check
    PreLoginSecurityService.logAppLaunch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateDialogWidget.showUpdateDialogIfNeeded(context);
    });

    // Periodic auto-check every 3 seconds to automatically recover online mode
    _autoOnlineCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkConnectivityFast();
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      _checkConnectivityFast();
    }, onError: (e) {
      debugPrint('[LoginPage] Connectivity listener ignored Windows platform error: $e');
    });

    _usernameFocus.addListener(_handleFocusChange);
    _passwordFocus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _autoOnlineCheckTimer?.cancel();
    _connectivitySub?.cancel();
    _usernameFocus.removeListener(_handleFocusChange);
    _passwordFocus.removeListener(_handleFocusChange);
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _scrollController.dispose();
    _usernameOrEmailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final node = _usernameFocus.hasFocus ? _usernameFocus : _passwordFocus;
    if (node.hasFocus) _scrollToField(node);
  }

  void _scrollToField(FocusNode node) {
    if (!mounted || node.context == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Scrollable.ensureVisible(
        node.context!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    });
  }

  Future<bool> _hasRealInternet() async {
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    try {
      final lookup = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 2));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) {
        return true;
      }
    } catch (_) {
      try {
        final lookup2 = await InternetAddress.lookup('firebase.google.com').timeout(const Duration(seconds: 2));
        if (lookup2.isNotEmpty && lookup2[0].rawAddress.isNotEmpty) {
          return true;
        }
      } catch (_) {}
    }

    try {
      final result = await Connectivity().checkConnectivity();
      return result.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  bool _hasCheckedUpdate = false;

  Future<void> _checkConnectivityFast() async {
    final online = await _hasRealInternet();
    if (mounted && online != _isOnline) {
      setState(() => _isOnline = online);
      debugPrint('[LoginPage] Automatic connectivity check → online: $online');
      if (online && !_hasCheckedUpdate) {
        _hasCheckedUpdate = true;
        UpdateDialogWidget.showUpdateDialogIfNeeded(context);
      }
    }
  }

  Future<void> _recheckOnlineMode() async {
    if (mounted) setState(() => _loading = true);
    try {
      final online = await _hasRealInternet();
      if (!mounted) return;

      setState(() => _isOnline = online);
      if (online) {
        Flushbar(
          message: "Connected to internet! Switched to Online Mode.",
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 3),
        ).show(context);
      } else {
        Flushbar(
          message: "No internet connection detected. Remaining in Offline Mode.",
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 3),
        ).show(context);
      }
    } catch (e) {
      debugPrint('[LoginPage] _recheckOnlineMode error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadCachedCredentials() async {
    try {
      final cached = await OfflineAuthService.getCachedUsername();
      if (cached != null && cached.isNotEmpty && mounted) {
        _usernameOrEmailController.text = cached;
      }
    } catch (e) {
      debugPrint('[LoginPage] Error loading cached credentials: $e');
    }
  }

  // ── Main login entry point ────────────────────────────────────────────────
  Future<void> _login() async {
    RoleSimulatorService.reset();

    final input    = _usernameOrEmailController.text.trim();
    final password = _passwordController.text.trim();

    if (input.isEmpty || password.isEmpty) {
      _showError("Please enter username/email and password");
      return;
    }

    if (mounted) setState(() => _loading = true);

    try {
      // Always verify real internet status first on click before defaulting to offline
      final liveOnline = await _hasRealInternet();
      if (liveOnline != _isOnline && mounted) {
        setState(() => _isOnline = liveOnline);
        debugPrint('[LoginPage] Auto-recovered online mode on sign in click → online: $liveOnline');
      }

      // ── Pure offline path ──────────────────────────────────────────────────
      if (!_isOnline && !liveOnline) {
        debugPrint('[LoginPage] OFFLINE MODE — attempting offline login');
        final ok = await _attemptOfflineLogin(input, password);
        if (!ok && mounted) {
          _showError("Offline login failed. Please connect to the internet and log in once first.");
        }
        return;
      }

      // ── Online path ────────────────────────────────────────────────────────
      debugPrint('[LoginPage] ONLINE MODE — Firebase login');

      // Resolve username → email if needed
      String email = input.contains('@') ? input.trim().toLowerCase() : '';
      if (email.isEmpty) {
        debugPrint('[LoginPage] Looking up email for username: $input');
        final found = await _findUserByUsername(input);
        if (found != null && found['email'] != null && (found['email'] as String).isNotEmpty) {
          email = (found['email'] as String).trim().toLowerCase();
          debugPrint('[LoginPage] Resolved email: $email');
        } else {
          // Fallback domain: attempt username@gmwf.org
          email = '${input.trim().toLowerCase()}@gmwf.org';
          debugPrint('[LoginPage] Fallback domain email attempt: $email');
        }
      }

      // Firebase sign-in — single attempt
      UserCredential cred;
      try {
        cred = await FirebaseAuth.instance
            .signInWithEmailAndPassword(
              email: email.toLowerCase(),
              password: password,
            )
            .timeout(const Duration(seconds: 15));
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
          // Attempt offline fallback before failing
          final ok = await _attemptOfflineLogin(input, password);
          if (ok) return;
        }
        rethrow;
      }

      final user = cred.user;
      if (user == null) {
        _showError("Login failed: no user returned");
        return;
      }

      debugPrint('[LoginPage] Firebase sign-in OK — fetching user data');

      final userData = await _fetchUserDataFromFirestore(user, input);
      if (userData == null) {
        _showError("User account data not found. Contact admin.");
        return;
      }

      try {
        final box = Hive.isBoxOpen('app_settings') ? Hive.box('app_settings') : await Hive.openBox('app_settings');
        await box.put('user_data', userData);
        await box.put('currentUser', userData);
        if (userData['role'] != null) await box.put('user_role', userData['role']);
        await box.flush();
      } catch (e) {
        debugPrint('[LoginPage] Error pre-caching user_data: $e');
      }

      final userStatus = (userData['status'] ?? userData['accountStatus'] ?? 'active').toString().toLowerCase().trim();
      final isRevoked = userStatus == 'inactive' ||
          userStatus == 'suspended' ||
          userStatus == 'terminated' ||
          userStatus == 'resigned' ||
          userStatus == 'retired' ||
          userStatus == 'offboarded' ||
          userStatus == 'revoked' ||
          userData['isActive'] == false;

      if (isRevoked) {
        await FirebaseAuth.instance.signOut();
        final userKey = (userData['uid'] ?? userData['email'] ?? userData['username'] ?? '').toString();
        if (userKey.isNotEmpty) {
          await OfflineAuthService.clearCredentialsForUser(userKey);
        }
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => AccessRevokedScreen(userData: userData, reason: userStatus)),
            (route) => false,
          );
        }
        return;
      }

      // Record last login timestamp
      final nowIso = DateTime.now().toIso8601String();
      userData['lastLoginAt'] = nowIso;
      userData['lastOnlineAt'] = nowIso;

      try {
        final nowTs = FieldValue.serverTimestamp();
        final uid = user.uid;
        final bId = userData['branchId']?.toString() ?? 'all';
        FirebaseFirestore.instance.collection('users').doc(uid).set({
          'lastLoginAt': nowTs,
          'lastOnlineAt': nowTs,
        }, SetOptions(merge: true));

        DeviceInfoService.recordUserSession(userId: uid, email: user.email);

        if (bId != 'global' && bId != 'all' && bId.isNotEmpty) {
          FirebaseFirestore.instance
              .collection('branches')
              .doc(bId)
              .collection('users')
              .doc(uid)
              .set({
            'lastLoginAt': nowTs,
            'lastOnlineAt': nowTs,
          }, SetOptions(merge: true));
        }
      } catch (e) {
        debugPrint('[LoginPage] Could not update lastLoginAt in Firestore: $e');
      }

      // ── Cache credentials for offline use ─────────────────────────────────
      // ✅ FIX: saveCredentials now returns bool instead of throwing.
      // We attempt to save under both the typed input AND the resolved email
      // so offline lookup works with either key.
      await _cacheCredentialsSafely(
        usernameOrEmail: input.toLowerCase(),
        password: password,
        userData: userData,
      );

      // Also cache by email so either key works offline
      if (!input.contains('@') && email.isNotEmpty) {
        await _cacheCredentialsSafely(
          usernameOrEmail: email.toLowerCase(),
          password: password,
          userData: userData,
        );
      }

      // Debug: confirm what was stored
      await OfflineAuthService.debugDumpStoredKeys();

      if (mounted) {
        Flushbar(
          message: "Welcome back, ${userData['username']}!",
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ).show(context);
        _navigateToHome(user, userData);
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('[LoginPage] FirebaseAuthException: ${e.code}');
      await _handleFirebaseAuthError(e, input, password);
    } on TimeoutException {
      debugPrint('[LoginPage] Timeout');
      final ok = await _attemptOfflineLogin(input, password);
      if (!ok && mounted) {
        _showError("Connection timed out. Please check your internet and try again.");
      }
    } catch (e) {
      debugPrint('[LoginPage] Unexpected error: $e');
      final ok = await _attemptOfflineLogin(input, password);
      if (!ok && mounted) {
        _showError("An unexpected error occurred. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Safe credential caching wrapper ──────────────────────────────────────
  /// Wraps saveCredentials so a failure is logged but never interrupts login.
  Future<void> _cacheCredentialsSafely({
    required String usernameOrEmail,
    required String password,
    required Map<String, dynamic> userData,
  }) async {
    final saved = await OfflineAuthService.saveCredentials(
      usernameOrEmail: usernameOrEmail,
      password: password,
      userData: userData,
    );
    if (saved) {
      debugPrint('[LoginPage] ✅ Offline credentials cached for $usernameOrEmail');
    } else {
      // Non-fatal: user is logged in online; offline just won't work until storage recovers.
      debugPrint('[LoginPage] ⚠️ Could not cache offline credentials for $usernameOrEmail');
    }
  }

  // ── Firebase error handler ────────────────────────────────────────────────
  Future<void> _handleFirebaseAuthError(
      FirebaseAuthException e, String input, String password) async {

    switch (e.code) {

      // ── Network errors → try offline ──────────────────────────────────────
      case 'network-request-failed':
      case 'unavailable':
      case 'deadline-exceeded':
        debugPrint('[LoginPage] Network error — trying offline');
        final ok = await _attemptOfflineLogin(input, password);
        if (!ok && mounted) {
          _showError("Network error. Connect to the internet and try again.");
        }
        return;

      // ── Rate-limited — DO NOT retry Firebase or offline, just tell the user ─
      case 'too-many-requests':
        if (mounted) {
          _showError(
            "Too many failed attempts. Your account is temporarily locked. "
            "Please wait a few minutes and try again, or reset your password.",
          );
        }
        return;

      // ── Invalid credential (wrong password or non-existent user) ──────────
      // Firebase returns 'invalid-credential' as the unified code to prevent
      // user enumeration. Only fall through to offline if cached creds exist.
      case 'wrong-password':
      case 'invalid-credential':
        final hasCached = await OfflineAuthService.hasCachedCredentialsFor(
          input.toLowerCase(),
        );
        if (hasCached) {
          debugPrint('[LoginPage] invalid-credential but has cache — trying offline');
          final ok = await _attemptOfflineLogin(input, password);
          if (ok) return;
        }
        if (mounted) {
          _showError("Incorrect username or password. Please check and try again.");
        }
        return;

      case 'user-not-found':
        final ok = await _attemptOfflineLogin(input, password);
        if (!ok && mounted) {
          _showError("No account found for '$input'.");
        }
        return;

      case 'user-disabled':
        if (mounted) _showError("This account has been disabled. Contact admin.");
        return;

      // ── Firebase internal / transient error — NOT a credential problem ────
      case 'unknown-error':
      case 'internal-error':
        debugPrint('[LoginPage] Firebase internal error (${e.code}) — trying offline/local fallback');
        final okUnknown = await _attemptOfflineLogin(input, password);
        if (okUnknown) return;
        final okLocal = await _tryLocalUsersFallbackLogin(input, password);
        if (okLocal) return;
        if (mounted) {
          _showError("Incorrect username/email or password. Please check your credentials.");
        }
        return;

      default:
        debugPrint('[LoginPage] Unhandled Firebase error: ${e.code} — ${e.message}');
        final ok = await _attemptOfflineLogin(input, password);
        if (ok) return;
        final okLocal = await _tryLocalUsersFallbackLogin(input, password);
        if (okLocal) return;
        if (mounted) {
          _showError("Login failed (${e.code}). Please check your credentials.");
        }
    }
  }

  // ── Offline login ─────────────────────────────────────────────────────────
  Future<bool> _attemptOfflineLogin(String input, String password) async {
    try {
      debugPrint('[LoginPage] Attempting offline login for: $input');
      final userData = await OfflineAuthService.verifyOfflineCredentials(
        usernameOrEmail: input.toLowerCase(),
        password: password,
      );

      if (userData == null) {
        debugPrint('[LoginPage] OfflineAuthService verification returned null, checking local_users fallback');
        final localOk = await _tryLocalUsersFallbackLogin(input, password);
        if (localOk) return true;
        debugPrint('[LoginPage] Offline login failed — no matching credentials');
        return false;
      }

      final userStatus = (userData['status'] ?? userData['accountStatus'] ?? 'active').toString().toLowerCase().trim();
      final isRevoked = userStatus == 'inactive' ||
          userStatus == 'suspended' ||
          userStatus == 'terminated' ||
          userStatus == 'resigned' ||
          userStatus == 'retired' ||
          userStatus == 'offboarded' ||
          userStatus == 'revoked' ||
          userData['isActive'] == false;

      if (isRevoked) {
        final userKey = (userData['uid'] ?? userData['email'] ?? userData['username'] ?? '').toString();
        if (userKey.isNotEmpty) {
          await OfflineAuthService.clearCredentialsForUser(userKey);
        }
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => AccessRevokedScreen(userData: userData, reason: userStatus)),
            (route) => false,
          );
        }
        return true;
      }

      debugPrint('[LoginPage] Offline login successful → role=${userData['role']}');
      if (mounted) {
        Flushbar(
          message: "Welcome back, ${userData['username']}! (Offline Mode)",
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 2),
        ).show(context);
        _navigateToHomeOffline(userData);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _tryLocalUsersFallbackLogin(String input, String password) async {
    try {
      final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
      final lowerInput = input.trim().toLowerCase();
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final email = (u['email']?.toString() ?? '').toLowerCase();
          final username = (u['username']?.toString() ?? '').toLowerCase();
          final usernameLower = (u['usernameLower']?.toString() ?? '').toLowerCase();
          final savedPass = u['password']?.toString() ?? '1122';
          if ((username == lowerInput || usernameLower == lowerInput || email == lowerInput) && savedPass == password) {
            if (mounted) {
              Flushbar(
                message: "Welcome back, ${u['username']}!",
                backgroundColor: Colors.green.shade700,
                duration: const Duration(seconds: 2),
              ).show(context);
              _navigateToHomeOffline(u);
            }
            return true;
          }
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Fallback local_users login exception: $e');
    }
    return false;
  }

  static String _resolveRoleFromMap(Map<String, dynamic> d) {
    if (d['role'] != null && d['role'].toString().trim().isNotEmpty) {
      return d['role'].toString();
    }
    if (d['roles'] is List && (d['roles'] as List).isNotEmpty) {
      return (d['roles'] as List).first.toString();
    }
    if (d['type'] != null && d['type'].toString().trim().isNotEmpty) {
      return d['type'].toString();
    }
    if (d['accountType'] != null && d['accountType'].toString().trim().isNotEmpty) {
      return d['accountType'].toString();
    }
    if (d['userRole'] != null && d['userRole'].toString().trim().isNotEmpty) {
      return d['userRole'].toString();
    }
    if (d['designation'] != null && d['designation'].toString().trim().isNotEmpty) {
      return d['designation'].toString();
    }
    if (d['position'] != null && d['position'].toString().trim().isNotEmpty) {
      return d['position'].toString();
    }
    if (d['jobTitle'] != null && d['jobTitle'].toString().trim().isNotEmpty) {
      return d['jobTitle'].toString();
    }
    if (d['accessRole'] != null && d['accessRole'].toString().trim().isNotEmpty) {
      return d['accessRole'].toString();
    }
    return 'unknown';
  }

  // ── Firestore user data fetch ─────────────────────────────────────────────
  Future<Map<String, dynamic>?> _fetchUserDataFromFirestore(
      User user, String inputUsername) async {
    final uid = user.uid;
    final userEmail = user.email?.toLowerCase().trim() ?? '';

    // 1. Top-level users collection by UID
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 8));
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        final resolvedRole = _resolveRoleFromMap(d);
        return {
          ...d,
          'uid': uid,
          'email': user.email,
          'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
          'role': resolvedRole,
          'branchId': d['branchId'] ?? '',
          'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
        };
      }
    } catch (e) {
      debugPrint('[LoginPage] Top-level /users fetch failed: $e');
    }

    // 2. Branch users subcollections by UID
    try {
      final querySnap = await FirebaseFirestore.instance
          .collectionGroup('users')
          .where('uid', isEqualTo: uid)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 8));
      if (querySnap.docs.isNotEmpty) {
        final doc = querySnap.docs.first;
        final d = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        final resolvedRole = _resolveRoleFromMap(d);
        return {
          ...d,
          'uid': uid,
          'email': user.email,
          'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
          'role': resolvedRole,
          'branchId': branchId,
          'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
        };
      }
    } catch (e) {
      debugPrint('[LoginPage] Branch /users fetch failed via collectionGroup: $e');
    }

    // 3. Fallback: Search by email in collectionGroup('users')
    if (userEmail.isNotEmpty) {
      try {
        final queryByEmail = await FirebaseFirestore.instance
            .collectionGroup('users')
            .where('email', isEqualTo: userEmail)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 8));
        if (queryByEmail.docs.isNotEmpty) {
          final doc = queryByEmail.docs.first;
          final d = doc.data();
          final pathParts = doc.reference.path.split('/');
          final branchId = d['branchId'] ?? (pathParts.length >= 2 ? pathParts[1] : 'unknown');
          final resolvedRole = _resolveRoleFromMap(d);
          return {
            ...d,
            'uid': d['uid'] ?? uid,
            'email': user.email,
            'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
            'role': resolvedRole,
            'branchId': branchId,
            'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
          };
        }
      } catch (e) {
        debugPrint('[LoginPage] Search by email failed: $e');
      }
    }

    // 4. Fallback: Search in Hive local_users
    try {
      final box = Hive.isBoxOpen('local_users')
          ? Hive.box('local_users')
          : await Hive.openBox('local_users');
      final inputLower = inputUsername.trim().toLowerCase();
      for (final val in box.values) {
        if (val is Map) {
          final Map<String, dynamic> u = Map<String, dynamic>.from(val);
          final email = (u['email']?.toString() ?? '').toLowerCase();
          final username = (u['username']?.toString() ?? '').toLowerCase();
          final uUid = u['uid']?.toString() ?? '';
          if ((userEmail.isNotEmpty && email == userEmail) || username == inputLower || uUid == uid) {
            u['role'] = _resolveRoleFromMap(u);
            return u;
          }
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Search local_users failed: $e');
    }

    return null;
  }

  // ── Username → email lookup ───────────────────────────────────────────────
  Future<Map<String, dynamic>?> _findUserByUsername(String username) async {
    final lower = username.trim().toLowerCase();
    try {
      final box = Hive.isBoxOpen('local_users')
          ? Hive.box('local_users')
          : await Hive.openBox('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final uName = (val['username']?.toString() ?? '').toLowerCase();
          final uNameLower = (val['usernameLower']?.toString() ?? '').toLowerCase();
          final name = (val['name']?.toString() ?? '').toLowerCase();
          final email = (val['email']?.toString() ?? '').toLowerCase();

          if (uName == lower || uNameLower == lower || name == lower || email.startsWith('$lower@')) {
            final m = Map<String, dynamic>.from(val);
            return {
              ...m,
              'email': val['email'],
              'username': val['username'] ?? val['name'],
              'branchId': val['branchId'] ?? 'all',
              'role': _resolveRoleFromMap(m),
            };
          }
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Local username lookup failed: $e');
    }

    try {
      final qLower = await FirebaseFirestore.instance
          .collection('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (qLower.docs.isNotEmpty) {
        final doc = qLower.docs.first;
        final d = doc.data();
        return {
          ...d,
          'email': doc['email'],
          'username': doc['username'],
          'role': _resolveRoleFromMap(d),
        };
      }

      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isEqualTo: username.trim())
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (q.docs.isNotEmpty) {
        final doc = q.docs.first;
        final d = doc.data();
        return {
          ...d,
          'email': doc['email'],
          'username': doc['username'],
          'role': _resolveRoleFromMap(d),
        };
      }

      final qName = await FirebaseFirestore.instance
          .collection('users')
          .where('name', isEqualTo: username.trim())
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (qName.docs.isNotEmpty) {
        final doc = qName.docs.first;
        final d = doc.data();
        return {
          ...d,
          'email': doc['email'],
          'username': doc['name'] ?? doc['username'],
          'role': _resolveRoleFromMap(d),
        };
      }

      final querySnapLower = await FirebaseFirestore.instance
          .collectionGroup('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (querySnapLower.docs.isNotEmpty) {
        final doc = querySnapLower.docs.first;
        final d = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        return {
          ...d,
          'email': doc['email'],
          'username': doc['username'],
          'branchId': branchId,
          'role': _resolveRoleFromMap(d),
        };
      }

      final querySnap = await FirebaseFirestore.instance
          .collectionGroup('users')
          .where('username', isEqualTo: username.trim())
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));
      if (querySnap.docs.isNotEmpty) {
        final doc = querySnap.docs.first;
        final d = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        return {
          ...d,
          'email': doc['email'],
          'username': doc['username'],
          'branchId': branchId,
          'role': _resolveRoleFromMap(d),
        };
      }
    } catch (e) {
      debugPrint('[LoginPage] Username lookup error: $e');
    }
    return null;
  }

  // ── Navigation helpers ────────────────────────────────────────────────────
  void _navigateToHome(User user, Map<String, dynamic> userData) async {
    try {
      final box = Hive.isBoxOpen('app_settings')
          ? Hive.box('app_settings')
          : await Hive.openBox('app_settings');
      await box.put('user_data', userData);
      await box.put('currentUser', userData);
      if (userData['role'] != null) await box.put('user_role', userData['role']);
    } catch (e) {
      debugPrint('[LoginPage] Error caching user_data to app_settings: $e');
    }

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomeRouter(user: user, localUser: userData),
      ),
      (r) => false,
    );
  }

  void _navigateToHomeOffline(Map<String, dynamic> userData) async {
    try {
      final box = Hive.isBoxOpen('app_settings')
          ? Hive.box('app_settings')
          : await Hive.openBox('app_settings');
      await box.put('user_data', userData);
      await box.put('currentUser', userData);
      if (userData['role'] != null) await box.put('user_role', userData['role']);
    } catch (e) {
      debugPrint('[LoginPage] Error caching user_data to app_settings: $e');
    }

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomeRouter(user: null, localUser: userData),
      ),
      (r) => false,
    );
  }



  void _showError(String msg) {
    if (!mounted) return;
    Flushbar(
      message: msg,
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 5),
    ).show(context);
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF031611) : const Color(0xFFEFF6F0),
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // ── Islamic Arch Frame Pattern (2.webp) on LEFT SIDE ────────────────
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: 600,
            child: Opacity(
              opacity: isDark ? 0.35 : 0.22,
              child: Image.asset(
                'assets/images/2.webp',
                fit: BoxFit.fitHeight,
                alignment: Alignment.topLeft,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),


          // ── Islamic Geometric Vector Pattern Overlay ──────────────────────
          Positioned.fill(
            child: CustomPaint(
              painter: IslamicPatternPainter(
                color: isDark
                    ? const Color(0xFF10B981).withValues(alpha: 0.04)
                    : const Color(0xFF059669).withValues(alpha: 0.03),
              ),
            ),
          ),

          // ── Ambient Background Glows ────────────────────────────────────────
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark
                    ? const Color(0xFF10B981).withValues(alpha: 0.12)
                    : const Color(0xFF059669).withValues(alpha: 0.08),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            right: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark
                    ? const Color(0xFF047857).withValues(alpha: 0.15)
                    : const Color(0xFF10B981).withValues(alpha: 0.08),
              ),
            ),
          ),

          // ── Main Content Container ──────────────────────────────────────────
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isDesktop = constraints.maxWidth >= 900;

                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isDesktop ? 1040 : 460,
                            ),
                            child: isDesktop
                                ? _buildDesktopLayout(context, isDark)
                                : _buildMobileLayout(context, isDark),
                          ),
                        ),
                      ),
                    ),

                    // ── Bottom Programs Bar ─────────────────────────────────
                    _buildBottomProgramsBar(isDesktop, isDark),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Desktop 2-Column Layout ───────────────────────────────────────────────
  Widget _buildDesktopLayout(BuildContext context, bool isDark) {
    final titleMain = isDark ? Colors.white : const Color(0xFF064E3B);
    final titleAccent = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF374151);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── Left Hero Side (Displays Logo ONCE) ─────────────────────────────
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.only(right: 48.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLogoWidget(height: 110),
                const SizedBox(height: 36),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold, height: 1.2, fontFamily: 'Roboto'),
                    children: [
                      TextSpan(text: "One Platform.\n", style: TextStyle(color: titleMain)),
                      TextSpan(text: "All Operation.", style: TextStyle(color: titleAccent)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "A unified digital system to manage welfare, education, healthcare and more.",
                  style: TextStyle(
                    fontSize: 15,
                    color: subtitleColor,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  height: 2,
                  width: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: LinearGradient(
                      colors: [
                        isDark ? const Color(0xFF10B981) : const Color(0xFF059669),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    _buildFeatureItem(Icons.shield_outlined, "Secure Access", isDark),
                    const SizedBox(width: 24),
                    _buildFeatureItem(Icons.people_outline, "Role Based", isDark),
                    const SizedBox(width: 24),
                    _buildFeatureItem(Icons.bar_chart_rounded, "Real-time Sync", isDark),
                  ],
                ),
              ],
            ),
          ),
        ),

        // ── Right Glass Form Card ───────────────────────────────────────────
        Expanded(
          flex: 5,
          child: _buildFormCard(context, showHeader: true, isDark: isDark),
        ),
      ],
    );
  }

  // ── Mobile Single-Column Layout ───────────────────────────────────────────
  Widget _buildMobileLayout(BuildContext context, bool isDark) {
    final titleMain = isDark ? Colors.white : const Color(0xFF064E3B);
    final titleAccent = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF4B5563);
    final badgeColor = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        // Top Logo
        Center(child: _buildLogoWidget(height: 72)),
        const SizedBox(height: 10),

        // Tagline Badge
        Text(
          "GMWF EMPLOYEE PORTAL",
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
            color: badgeColor,
          ),
        ),
        const SizedBox(height: 4),

        // Header Title
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, fontFamily: 'Roboto'),
            children: [
              TextSpan(text: "Welcome ", style: TextStyle(color: titleMain)),
              TextSpan(text: "Back", style: TextStyle(color: titleAccent)),
            ],
          ),
        ),
        const SizedBox(height: 4),

        // Subtitle
        Text(
          "Sign in to access your employee account",
          style: TextStyle(fontSize: 12.5, color: subtitleColor),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),

        // White Form Card
        _buildFormCard(context, showHeader: false, isDark: isDark),
      ],
    );
  }

  // ── Form Glass Card ───────────────────────────────────────────────────────
  Widget _buildFormCard(BuildContext context, {required bool showHeader, required bool isDark}) {
    final cardBg = isDark
        ? const Color(0xFF041C16).withValues(alpha: 0.95)
        : Colors.white;
    final cardBorder = isDark
        ? const Color(0xFF10B981).withValues(alpha: 0.3)
        : Colors.white;
    final cardShadow = isDark
        ? const Color(0xFF000000).withValues(alpha: 0.4)
        : const Color(0xFF047857).withValues(alpha: 0.08);
    final badgeColor = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final badgeDivider = isDark ? const Color(0xFF047857) : const Color(0xFFA7F3D0);
    final titleMain = isDark ? Colors.white : const Color(0xFF064E3B);
    final titleAccent = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF4B5563);

    final inputLabelColor = isDark ? const Color(0xFFA7F3D0) : const Color(0xFF064E3B);
    final inputFill = isDark ? const Color(0xFF02140F) : const Color(0xFFF8FAFC);
    final inputBorder = isDark ? const Color(0xFF0D382B) : const Color(0xFFE2E8F0);
    final inputFocusBorder = isDark ? const Color(0xFF10B981) : const Color(0xFF059669);
    final inputTextColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final inputHintColor = isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8);
    final inputIconColor = isDark ? const Color(0xFF10B981) : const Color(0xFF059669);

    final btnGradientColors = isDark
        ? [const Color(0xFF10B981), const Color(0xFF059669)]
        : [const Color(0xFF059669), const Color(0xFF047857)];

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showHeader ? 36 : 20,
        vertical: showHeader ? 36 : 20,
      ),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cardBorder,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: cardShadow,
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader) ...[
            // Tagline Badge
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 20, child: Divider(color: badgeDivider, thickness: 1.5)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      "GMWF EMPLOYEE PORTAL",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        color: badgeColor,
                      ),
                    ),
                  ),
                  SizedBox(width: 20, child: Divider(color: badgeDivider, thickness: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Header Title
            Center(
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, fontFamily: 'Roboto'),
                  children: [
                    TextSpan(text: "Welcome ", style: TextStyle(color: titleMain)),
                    TextSpan(text: "Back", style: TextStyle(color: titleAccent)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                "Sign in to access your employee account",
                style: TextStyle(fontSize: 13, color: subtitleColor),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Offline mode banner if active
          if (!_isOnline) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF451A03).withValues(alpha: 0.6) : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade400),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "OFFLINE MODE ACTIVE",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange.shade900),
                    ),
                  ),
                  InkWell(
                    onTap: _recheckOnlineMode,
                    child: Text("Go Online", style: TextStyle(fontSize: 11, color: badgeColor, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],

          // Username or Email Field
          Text(
            "Username or Email",
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: inputLabelColor),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _usernameOrEmailController,
            focusNode: _usernameFocus,
            textInputAction: TextInputAction.next,
            style: TextStyle(color: inputTextColor, fontSize: 14, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: "Enter username or email",
              hintStyle: TextStyle(color: inputHintColor, fontSize: 13.5),
              prefixIcon: Icon(Icons.person_outline_rounded, color: inputIconColor, size: 18),
              filled: true,
              fillColor: inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputFocusBorder, width: 1.5),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Password Field
          Text(
            "Password",
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: inputLabelColor),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _passwordController,
            focusNode: _passwordFocus,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            style: TextStyle(color: inputTextColor, fontSize: 14, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: "••••••••••••",
              hintStyle: TextStyle(color: inputHintColor, fontSize: 13.5),
              prefixIcon: Icon(Icons.lock_outline_rounded, color: inputIconColor, size: 18),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  size: 18,
                ),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
              filled: true,
              fillColor: inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: inputFocusBorder, width: 1.5),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Sign In Button
          MouseRegion(
            onEnter: (_) => setState(() => _loginHover = true),
            onExit:  (_) => setState(() => _loginHover = false),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  colors: btnGradientColors,
                ),
                boxShadow: [
                  BoxShadow(
                    color: btnGradientColors.first.withValues(alpha: _loginHover ? 0.4 : 0.25),
                    blurRadius: _loginHover ? 16 : 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Text(
                            "Sign In",
                            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
                        ],
                      ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Footer Notice
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.contact_support_outlined, size: 14, color: badgeColor),
              const SizedBox(width: 5),
              Text(
                "Need an account? ",
                style: TextStyle(fontSize: 12, color: subtitleColor),
              ),
              Text(
                "Contact your administrator.",
                style: TextStyle(fontSize: 12, color: badgeColor, fontWeight: FontWeight.bold),
              ),
            ],
          ),

          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: Divider(color: inputBorder)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.shield_outlined, size: 13, color: badgeColor),
              ),
              Expanded(child: Divider(color: inputBorder)),
            ],
          ),
          const SizedBox(height: 10),

          // Platform Version
          Center(
            child: Text(
              "GMWF Management Platform  •  v${AutoUpdateService.currentVersion}",
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFF475569) : const Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Logo Widget Helper (With long-press reset) ────────────────────────────
  Widget _buildLogoWidget({required double height}) {
    return GestureDetector(
      onLongPress: () async {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            backgroundColor: const Color(0xFF041C16),
            title: const Text("Clear Saved Login?", style: TextStyle(color: Colors.white)),
            content: const Text(
              "This will remove cached credentials and allow a fresh sign-in.",
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text("Cancel", style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text("Clear", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (confirm == true) {
          final targetUser = _usernameOrEmailController.text.trim().isNotEmpty
              ? _usernameOrEmailController.text.trim()
              : (await OfflineAuthService.getCachedUsername() ?? '');
          if (targetUser.isNotEmpty) {
            await OfflineAuthService.clearCredentialsForUser(targetUser);
          } else {
            await OfflineAuthService.clearCachedUserData();
          }
          if (!mounted) return;
          _usernameOrEmailController.clear();
          _passwordController.clear();
          Flushbar(
            message: targetUser.isNotEmpty ? "Saved login for '$targetUser' cleared." : "Saved login session cleared.",
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 3),
          ).show(context);
        }
      },
      child: Hero(
        tag: 'gmwf_app_logo',
        child: Image.asset(
          "assets/logo/gmwf-1.webp",
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(
            Icons.local_pharmacy_rounded,
            size: 80,
            color: Color(0xFF10B981),
          ),
        ),
      ),
    );
  }

  // ── Feature Item Pill ─────────────────────────────────────────────────────
  Widget _buildFeatureItem(IconData icon, String title, bool isDark) {
    final bg = isDark ? const Color(0xFF041C16) : Colors.white;
    final border = isDark ? const Color(0xFF0D382B) : const Color(0xFFA7F3D0);
    final iconColor = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final textColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF1F2937);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFF059669).withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Icon(icon, color: iconColor, size: 22),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: TextStyle(fontSize: 12, color: textColor, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // ── Bottom Programs Bar ───────────────────────────────────────────────────
  Widget _buildBottomProgramsBar(bool isDesktop, bool isDark) {
    final items = [
      {'icon': Icons.soup_kitchen_outlined, 'title': 'GMWF FREE', 'sub': 'DASTERKHAWAAN'},
      {'icon': Icons.shopping_bag_outlined, 'title': 'GMWF FREE', 'sub': 'RATION'},
      {'icon': Icons.checkroom_outlined, 'title': 'GMWF EID', 'sub': 'LIBAAS'},
      {'icon': Icons.medical_services_outlined, 'title': 'GMWF FREE', 'sub': 'DISPENSARY'},
      {'icon': Icons.menu_book_outlined, 'title': 'GMWF FREE', 'sub': 'MADRASSA'},
    ];

    final bg = isDark
        ? const Color(0xFF02100C).withValues(alpha: 0.95)
        : const Color(0xFFEFF6F0).withValues(alpha: 0.95);
    final border = isDark ? const Color(0xFF0D382B) : const Color(0xFFD1E7D7);
    final iconColor = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
    final textColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF064E3B);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(items.length * 2 - 1, (index) {
            if (index.isOdd) {
              return VerticalDivider(
                color: isDark ? const Color(0xFF0D382B) : const Color(0xFFD1E7D7),
                width: 1,
                thickness: 1,
                indent: 2,
                endIndent: 2,
              );
            }
            final itemIndex = index ~/ 2;
            final item = items[itemIndex];
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(item['icon'] as IconData, size: 20, color: iconColor),
                    const SizedBox(height: 3),
                    Text(
                      '${item['title']}\n${item['sub']}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        height: 1.15,
                        letterSpacing: 0.1,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Islamic Geometric Pattern Custom Painter ─────────────────────────────────
class IslamicPatternPainter extends CustomPainter {
  final Color color;
  IslamicPatternPainter({this.color = const Color(0x0F10B981)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    const tileSize = 90.0;
    for (double x = -tileSize; x < size.width + tileSize; x += tileSize) {
      for (double y = -tileSize; y < size.height + tileSize; y += tileSize) {
        _drawEightStarTile(canvas, Offset(x, y), tileSize * 0.45, paint);
      }
    }
  }

  void _drawEightStarTile(Canvas canvas, Offset center, double radius, Paint paint) {
    final s1 = radius * 1.3;
    canvas.drawRect(Rect.fromCenter(center: center, width: s1, height: s1), paint);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(0.785398); // 45 degrees
    canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: s1, height: s1), paint);
    canvas.restore();

    canvas.drawCircle(center, radius * 0.55, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

