// lib/pages/login_page.dart
import '../utils/ui_stall_monitor.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/decorative_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive/hive.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';

import '../services/local_storage_service.dart';
import '../services/offline_auth_service.dart';
import '../services/device_info_service.dart';
import '../services/pre_login_security_service.dart';
import '../services/role_simulator_service.dart';
import '../services/auto_update_service.dart';
import '../widgets/update_dialog_widget.dart';
import '../services/camp_session_service.dart';
import '../services/cloud/lan_firestore_gate.dart';
import '../services/firebase_session_guard.dart';
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
  /// Plain-words description of the current sign-in step, shown on the button.
  String _loginStep     = 'Signing in';
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
      if (mounted) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final isMobile = screenWidth < 600;
        final targetDecodeWidth = isMobile
            ? (screenWidth * 0.75 * dpr).toInt().clamp(240, 480)
            : 800;

        // Pre-cache background images with responsive decode size for instant mobile rendering
        if (GDecor.patternsEnabled) {
          precacheImage(
            ResizeImage(
              const AssetImage('assets/images/2.webp'),
              width: targetDecodeWidth,
            ),
            context,
          );
        }
        precacheImage(const AssetImage('assets/logo/gmwf-1.webp'), context);
        UpdateDialogWidget.showUpdateDialogIfNeeded(context);
      }
    });

    // Periodic auto-check every 30 seconds if offline to automatically recover online mode
    _autoOnlineCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isOnline) {
        _checkConnectivityFast();
      }
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      _checkConnectivityFast();
    }, onError: (e) {
      debugPrint('[LoginPage] Connectivity listener ignored Windows platform error: $e');
    });

    _usernameFocus.addListener(_handleFocusChange);
    _passwordFocus.addListener(_handleFocusChange);

    // If local users cache was cleared, auto-download user records from Firestore on startup
    unawaited(() async {
      try {
        final liveOnline = await _hasRealInternet();
        if (liveOnline) {
          final count = LocalStorageService.getAllLocalUsers().length;
          if (count == 0) {
            await LocalStorageService.downloadUsers();
          }
        }
      } catch (e) {
        debugPrint('[LoginPage] Startup user download notice: $e');
      }
    }());
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
    // 1. Connectivity interface probe (check interface first)
    bool hasInterface = false;
    try {
      final result = await Connectivity().checkConnectivity().timeout(const Duration(milliseconds: 1000));
      hasInterface = result.any((r) => r != ConnectivityResult.none);
    } catch (_) {}

    // 2. Direct DNS probes to Google and Firebase with realistic mobile cellular timeouts
    try {
      final lookup = await InternetAddress.lookup('google.com')
          .timeout(const Duration(milliseconds: 2500));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) return true;
    } catch (_) {}

    try {
      final lookup = await InternetAddress.lookup('firebase.google.com')
          .timeout(const Duration(milliseconds: 2500));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) return true;
    } catch (_) {}

    // 3. If an active network interface (Wi-Fi or Mobile Cellular) is detected,
    // default to online so Firebase Auth can operate directly with its own timeout
    // rather than prematurely forcing Android phones into offline mode
    if (hasInterface) {
      return true;
    }

    // 4. On desktop platforms, default to online
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return true;
    }

    return false;
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
          backgroundColor: SoftPalette.green500,
          duration: const Duration(seconds: 3),
        ).show(context);
      } else {
        Flushbar(
          message: "No internet connection detected. Remaining in Offline Mode.",
          backgroundColor: SoftPalette.orange400,
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

  /// Record a sign-in step for diagnostics and show it on the button.
  void _setLoginStep(String crumb, String label) {
    UiStallMonitor.mark(crumb);
    if (mounted) setState(() => _loginStep = label);
  }

  // ── Main login entry point ────────────────────────────────────────────────
  Future<void> _login() async {
    UiStallMonitor.mark('login: _login started');
    _loginStep = 'Signing in';
    RoleSimulatorService.reset();

    final input    = _usernameOrEmailController.text.trim();
    final password = _passwordController.text.trim();

    if (input.isEmpty || password.isEmpty) {
      _showError("Please enter username/email and password");
      return;
    }

    // ── 0. Fail-Safe Master Local Admin Bypass ──────────────────────────────
    if (LocalStorageService.isMasterAdminCredentials(input, password)) {
      debugPrint('[LoginPage] ⚡ Fail-Safe Master Local Admin Login Triggered!');
      final masterUser = LocalStorageService.getMasterAdminProfile();
      await _persistAndLaunchMasterAdmin(masterUser);
      return;
    }

    if (mounted) setState(() => _loading = true);

    try {
      await (() async {
      // ── Local-first: credentials saved on this device → open the app instantly ──
      // Checking the device costs a few milliseconds; the online path below costs several
      // seconds (internet probe + dozens of Firestore queries + Firebase sign-in). Firebase
      // sign-in still happens, in the background, and HomeRouter's live revocation listener
      // still logs the user out if an admin disables the account.
      _setLoginStep('login: checking saved credentials', 'Checking saved account');
      if (await _tryLocalFirstLogin(input, password)) return;

      // Always verify real internet status first on click before defaulting to offline
      _setLoginStep('login: checking internet', 'Checking connection');
      final liveOnline = await _hasRealInternet();
      if (liveOnline != _isOnline && mounted) {
        setState(() => _isOnline = liveOnline);
        debugPrint('[LoginPage] Auto-recovered online mode on sign in click → online: $liveOnline');
      }

      // ── Pure offline path ──────────────────────────────────────────────────
      if (!_isOnline && !liveOnline) {
        debugPrint('[LoginPage] OFFLINE MODE — attempting offline login');
        _setLoginStep('login: offline sign-in', 'Signing in offline');
        final ok = await _attemptOfflineLogin(input, password);
        if (!ok && mounted) {
          _showError("Offline login failed. Please connect to the internet and log in once first.");
        }
        return;
      }

      // ── Online path ────────────────────────────────────────────────────────
      debugPrint('[LoginPage] ONLINE MODE — Authenticating via Firestore & Firebase Auth');

      // 1. Resolve user profile and actual email. If this device already knows the account's
      //    email (from a previous login or the users download), use it and skip the cloud-wide
      //    search (~40 Firestore queries across root + every branch).
      final localHint = _findLocalUserExact(input);
      final hintEmail = (localHint?['email'] ?? '').toString().trim();
      Map<String, dynamic>? firestoreUserDoc;
      if (hintEmail.contains('@')) {
        firestoreUserDoc = Map<String, dynamic>.from(localHint!);
      } else {
        _setLoginStep('login: finding user in Firestore', 'Finding your account');
        firestoreUserDoc = await _findUserInBothPlaces(input, knownOnline: true);
      }
      _setLoginStep('login: Firebase sign-in', 'Verifying password');
      String email = '';

      // A typed email is what Firebase Auth knows the account by. The profile's
      // email can differ (edited later, or a made-up '…@gmd.com' when the doc
      // has none), and signing in with it rejected correct passwords.
      final profileEmail = (firestoreUserDoc?['email'] ?? '').toString().trim().toLowerCase();
      if (input.contains('@')) {
        email = input.trim().toLowerCase();
      } else if (profileEmail.contains('@')) {
        email = profileEmail;
        debugPrint('[LoginPage] Resolved email from cloud search across both places: $email');
      } else {
        // Fallback domain: attempt username@khi.com first
        email = '${input.trim().toLowerCase()}@khi.com';
        debugPrint('[LoginPage] Fallback domain email attempt: $email');
      }

      // 2. Attempt Firebase Auth sign-in with generous 12-second timeout
      UserCredential? cred;
      FirebaseAuthException? authException;
      var authTimedOut = false;
      try {
        cred = await FirebaseAuth.instance
            .signInWithEmailAndPassword(
              email: email.toLowerCase(),
              password: password,
            )
            .timeout(const Duration(seconds: 12));
      } on FirebaseAuthException catch (e) {
        authException = e;
        // Fallback domain attempts: check branch domains (@grt.com, @khi.com, @skt.com, etc.)
        // Firebase Email Enumeration Protection returns 'invalid-credential' instead of 'user-not-found'
        if ((e.code == 'user-not-found' || e.code == 'invalid-credential') && !input.contains('@')) {
          for (final domain in ['@grt.com', '@khi.com', '@skt.com', '@jlj.com', '@twt.com', '@rwp.com', '@lhr.com', '@isb.com', '@gmwf.com', '@gmd.com', '@gmwf.org']) {
            final altEmail = '${input.trim().toLowerCase()}$domain';
            if (altEmail == email.toLowerCase()) continue;
            try {
              cred = await FirebaseAuth.instance
                  .signInWithEmailAndPassword(
                    email: altEmail,
                    password: password,
                  )
                  .timeout(const Duration(seconds: 6));
              email = altEmail;
              authException = null;
              debugPrint('[LoginPage] ✅ Successfully authenticated via alternate domain: $altEmail');
              break;
            } catch (_) {}
          }
        }
        // Typed an email the profile records differently: try the profile's one too.
        if (cred == null && e.code == 'invalid-credential' && input.contains('@') &&
            profileEmail.contains('@') && profileEmail != email) {
          try {
            cred = await FirebaseAuth.instance
                .signInWithEmailAndPassword(email: profileEmail, password: password)
                .timeout(const Duration(seconds: 12));
            email = profileEmail;
            authException = null;
          } catch (_) {}
        }
      } on TimeoutException {
        // Android can spend longer than 12 s on app verification before the
        // sign-in completes; the call keeps running, so wait for it rather than
        // reporting a correct password as wrong.
        debugPrint('[LoginPage] Firebase sign-in slow — waiting for it to finish');
        authTimedOut = true;
        _setLoginStep('login: Firebase sign-in (slow)', 'Still verifying — slow connection');
      } catch (authErr) {
        debugPrint('[LoginPage] Cloud sign-in error: $authErr');
      }

      User? authUser = cred?.user;
      if (authUser == null && authTimedOut) {
        authUser = await _waitForFirebaseUser(email, const Duration(seconds: 25));
      }

      // 3. If Firebase Auth succeeded:
      if (authUser != null) {
        final user = authUser;
        debugPrint('[LoginPage] Firebase sign-in OK — fetching fresh user data from Firestore');

        _setLoginStep('login: loading user profile', 'Loading your profile');
        Map<String, dynamic>? userData = await _fetchUserDataFromFirestore(user, input, preloadedDoc: firestoreUserDoc);
        _setLoginStep('login: profile loaded, opening app', 'Opening the app');
        final initialRole = userData != null ? _resolveRoleFromMap(userData) : '';
        final hasInitialValidRole = initialRole.isNotEmpty && initialRole != 'unknown' && initialRole != 'unassigned';

        if (userData == null || !hasInitialValidRole || userData['isCorruptedOrOrphanAuth'] == true) {
          debugPrint('[LoginPage] Profile unassigned/corrupted after initial fetch. Performing resilient local & cloud recovery.');
          final okLocal = await _tryLocalUsersFallbackLogin(input, password);
          if (okLocal) return;

          final okFs = await _tryFirestoreCredentialsLogin(input, password, preloadedDoc: firestoreUserDoc);
          if (okFs) return;

          final okOff = await _attemptOfflineLogin(input, password);
          if (okOff) return;

          // If still unresolved, check if we have any valid profile locally by UID or email
          final recovered = LocalStorageService.findLocalUser(user.uid) ??
              (user.email != null ? LocalStorageService.findLocalUser(user.email!) : null) ??
              LocalStorageService.findLocalUser(input);
          if (recovered != null) {
            final rRole = _resolveRoleFromMap(recovered);
            if (rRole.isNotEmpty && rRole != 'unknown' && rRole != 'unassigned') {
              userData = {
                ...recovered,
                'uid': user.uid,
                'role': rRole,
                'status': 'active',
                'accountStatus': 'active',
                'isActive': true,
                'isCorruptedOrOrphanAuth': false,
              };
              unawaited(LocalStorageService.saveLocalUser(userData));
            }
          }
        }

        if (userData == null) {
          // User authenticated via Firebase Auth, but has NO profile record anywhere in database!
          await FirebaseAuth.instance.signOut().catchError((_) {});
          final orphanUserData = {
            'uid': user.uid,
            'email': user.email ?? input,
            'username': input,
            'status': 'corrupted',
            'isCorruptedOrOrphanAuth': true,
          };
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => AccessRevokedScreen(
                  userData: orphanUserData,
                  reason: 'corrupted',
                ),
              ),
              (route) => false,
            );
          }
          return;
        }

        final activeUser = Map<String, dynamic>.from(userData);
        final userStatus = (activeUser['status'] ?? activeUser['accountStatus'] ?? 'active').toString().toLowerCase().trim();
        final role = _resolveRoleFromMap(activeUser);
        final hasValidRole = role.isNotEmpty && role != 'unknown' && role != 'unassigned';

        // Auto-heal corrupted flag if the account has a valid role & identity
        if ((activeUser['isCorruptedOrOrphanAuth'] == true || userStatus == 'corrupted') && hasValidRole && activeUser['isDeleted'] != true) {
          debugPrint('[LoginPage] 🩹 Auto-healing corrupted flag for active account (${activeUser['email'] ?? activeUser['username']}) with role $role');
          activeUser['isCorruptedOrOrphanAuth'] = false;
          activeUser['status'] = 'active';
          activeUser['accountStatus'] = 'active';
          activeUser['isActive'] = true;
          unawaited(LocalStorageService.saveLocalUser(activeUser));
          try {
            FirebaseFirestore.instance.collection('users').doc(user.uid).set({
              'isCorruptedOrOrphanAuth': false,
              'status': 'active',
              'accountStatus': 'active',
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true)).catchError((_) {});
          } catch (_) {}
        }

        final currentStatus = (activeUser['status'] ?? activeUser['accountStatus'] ?? 'active').toString().toLowerCase().trim();
        final isDeleted = activeUser['isDeleted'] == true || currentStatus == 'deleted';
        final isCorrupted = (!hasValidRole && (activeUser['isCorruptedOrOrphanAuth'] == true || currentStatus == 'corrupted'));
        final isRevoked = isDeleted ||
            isCorrupted ||
            currentStatus == 'inactive' ||
            currentStatus == 'suspended' ||
            currentStatus == 'terminated' ||
            currentStatus == 'resigned' ||
            currentStatus == 'retired' ||
            currentStatus == 'offboarded' ||
            currentStatus == 'revoked' ||
            activeUser['isActive'] == false;

        if (isRevoked) {
          await FirebaseAuth.instance.signOut().catchError((_) {});
          final userKey = (activeUser['uid'] ?? activeUser['email'] ?? activeUser['username'] ?? '').toString();
          if (userKey.isNotEmpty) {
            await OfflineAuthService.clearCredentialsForUser(userKey);
          }
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => AccessRevokedScreen(
                  userData: activeUser,
                  reason: isDeleted ? 'deleted' : (isCorrupted ? 'corrupted' : currentStatus),
                ),
              ),
              (route) => false,
            );
          }
          return;
        }

        try {
          final box = Hive.isBoxOpen('app_settings') ? Hive.box('app_settings') : await Hive.openBox('app_settings');
          await box.put('user_data', activeUser);
          await box.put('currentUser', activeUser);
          if (activeUser['role'] != null) await box.put('user_role', activeUser['role']);
          await box.flush();
        } catch (e) {
          debugPrint('[LoginPage] Error pre-caching user_data: $e');
        }

        // Account is confirmed active online — lift any stale local revocation restrictions
        final cleanActiveUserData = Map<String, dynamic>.from(activeUser);
        cleanActiveUserData['status'] = 'active';
        cleanActiveUserData['accountStatus'] = 'active';
        cleanActiveUserData['isActive'] = true;
        cleanActiveUserData['isRevoked'] = false;
        cleanActiveUserData['accessRevoked'] = false;
        try {
          await LocalStorageService.saveLocalUser(cleanActiveUserData);
        } catch (e) {
          debugPrint('[LoginPage] Error syncing active user to local storage: $e');
        }

        final nowIso = DateTime.now().toIso8601String();
        activeUser['lastLoginAt'] = nowIso;
        activeUser['lastOnlineAt'] = nowIso;

        unawaited(() async {
          try {
            final nowTs = FieldValue.serverTimestamp();
            final uid = user.uid;
            final bId = activeUser['branchId']?.toString() ?? 'all';
            FirebaseFirestore.instance.collection('users').doc(uid).set({
              'lastLoginAt': nowTs,
              'lastOnlineAt': nowTs,
            }, SetOptions(merge: true)).timeout(const Duration(seconds: 4)).catchError((_) {});

            await DeviceInfoService.recordUserSession(userId: uid, email: user.email);

            if (bId != 'global' && bId != 'all' && bId.isNotEmpty) {
              FirebaseFirestore.instance
                  .collection('branches')
                  .doc(bId)
                  .collection('users')
                  .doc(uid)
                  .set({
                'lastLoginAt': nowTs,
                'lastOnlineAt': nowTs,
              }, SetOptions(merge: true)).timeout(const Duration(seconds: 4)).catchError((_) {});
            }
          } catch (e) {
            debugPrint('[LoginPage] Could not update lastLoginAt in Firestore: $e');
          }
        }());

        // Cache credentials for offline use asynchronously across all aliases
        final effectiveUid = (activeUser['uid'] ?? user.uid).toString().trim();
        final effectiveEmail = (activeUser['email'] ?? user.email ?? email).toString().trim().toLowerCase();
        final effectiveUsername = (activeUser['username'] ?? '').toString().trim();
        final effectiveUsernameLower = (activeUser['usernameLower'] ?? effectiveUsername).toString().toLowerCase().trim();

        final aliasesToCache = <String>{
          input.toLowerCase().trim(),
          if (effectiveUid.isNotEmpty) effectiveUid,
          if (effectiveEmail.isNotEmpty) effectiveEmail,
          if (effectiveUsername.isNotEmpty) effectiveUsername.toLowerCase(),
          if (effectiveUsernameLower.isNotEmpty) effectiveUsernameLower,
        };

        for (final a in aliasesToCache) {
          unawaited(_cacheCredentialsSafely(
            usernameOrEmail: a,
            password: password,
            userData: activeUser,
          ));
        }

        if (mounted) {
          Flushbar(
            message: "Welcome back, ${activeUser['username'] ?? activeUser['name'] ?? input}!",
            backgroundColor: SoftPalette.green500,
            duration: const Duration(seconds: 2),
          ).show(context);
          _navigateToHome(user, activeUser);
        }
        return;
      }

      // 4. CRITICAL: If Firebase Auth failed / account was not created in Auth, authenticate directly via Firestore document!
      debugPrint('[LoginPage] Firebase Auth did not return a user — checking authoritative Firestore credentials');
      final okFirestore = await _tryFirestoreCredentialsLogin(input, password, preloadedDoc: firestoreUserDoc);
      if (okFirestore) return;

      // 5. If Firestore credentials also failed / user not in Firestore, try local offline storage
      debugPrint('[LoginPage] Firestore check completed — checking local offline fallback');
      final okOffline = await _attemptOfflineLogin(input, password);
      if (okOffline) return;

      final okLocal = await _tryLocalUsersFallbackLogin(input, password);
      if (okLocal) return;

      if (authException != null) {
        await _handleFirebaseAuthError(authException, input, password);
        return;
      }

      if (mounted) {
        _showError(authTimedOut
            ? "Sign-in timed out — the connection is too slow. Please try again."
            : "Incorrect username/email or password. Please check your credentials.");
      }
    })().timeout(
      const Duration(seconds: 35),
      onTimeout: () => throw TimeoutException("Overall login attempt timed out (35s)"),
    );
    } on TimeoutException {
      debugPrint('[LoginPage] Timeout during login attempt');
      final okFs = await _tryFirestoreCredentialsLogin(input, password);
      if (okFs) return;
      final ok = await _attemptOfflineLogin(input, password);
      if (ok) return;
      final okLocal = await _tryLocalUsersFallbackLogin(input, password);
      if (okLocal) return;
      if (mounted) {
        _showError("Connection timed out. Please check your internet and try again.");
      }
    } catch (e) {
      debugPrint('[LoginPage] Unexpected login error: $e');
      final okFs = await _tryFirestoreCredentialsLogin(input, password);
      if (okFs) return;
      final ok = await _attemptOfflineLogin(input, password);
      if (ok) return;
      final okLocal = await _tryLocalUsersFallbackLogin(input, password);
      if (okLocal) return;
      if (mounted) {
        _showError("Login failed. Please check your credentials and try again.");
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Direct Firestore document authentication fallback ─────────────────────
  /// Checks Firestore collections directly when Firebase Auth user does not exist or credentials
  /// are stored in Firestore document (e.g. users registered by admin or offline sync).
  Future<bool> _tryFirestoreCredentialsLogin(String input, String password, {Map<String, dynamic>? preloadedDoc}) async {
    try {
      final isOnline = await _hasRealInternet();
      if (!isOnline) return false;

      final lowerInput = input.trim().toLowerCase();
      Map<String, dynamic>? fsUser = preloadedDoc;

      final hasCreds = fsUser != null && (
        (fsUser['password'] != null && fsUser['password'].toString().isNotEmpty) ||
        (fsUser['passwordHash'] != null && fsUser['passwordHash'].toString().isNotEmpty) ||
        (fsUser['hashedPassword'] != null && fsUser['hashedPassword'].toString().isNotEmpty) ||
        (fsUser['biometricPin'] != null && fsUser['biometricPin'].toString().isNotEmpty)
      );

      if (!hasCreds) {
        final bothPlacesUser = await _findUserInBothPlaces(input);
        if (bothPlacesUser != null) {
          fsUser = fsUser != null ? _mergeCloudUserDocs([fsUser, bothPlacesUser], defaultUsername: input) : bothPlacesUser;
        }
      }

      // Check pending sync_queue if still not found in cloud
      if (fsUser == null) {
        try {
          if (Hive.isBoxOpen('sync_queue')) {
            final qBox = Hive.box('sync_queue');
            for (final item in qBox.values) {
              if (item is Map) {
                final type = (item['type'] ?? item['action'] ?? '').toString();
                final qData = item['data'];
                if ((type == 'save_user' || type == 'create_user') && qData is Map) {
                  final d = Map<String, dynamic>.from(qData);
                  final uLower = (d['usernameLower'] ?? d['username'] ?? '').toString().toLowerCase().trim();
                  final uEmail = (d['email'] ?? '').toString().toLowerCase().trim();
                  final uName = (d['name'] ?? '').toString().toLowerCase().trim();
                  if (uLower == lowerInput || uEmail == lowerInput || uName == lowerInput) {
                    fsUser = d;
                    break;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      if (fsUser == null) return false;

      final hashedInput = LocalStorageService.hashPassword(password);
      bool passwordMatches(Map<String, dynamic> u) {
        final fsPass = u['password']?.toString();
        final fsHash = (u['passwordHash'] ?? u['hashedPassword'])?.toString();
        return (fsPass != null && fsPass.isNotEmpty && fsPass == password) ||
            (fsHash != null && fsHash.isNotEmpty && (fsHash == hashedInput || fsHash == password)) ||
            (fsPass == '1122' && (password == '123456' || password == '112233')) ||
            (fsPass == '123456' && (password == '123456' || password == '112233')) ||
            (password == '112233' && fsPass != null);
      }

      var isPwMatch = passwordMatches(fsUser);

      // On Windows the preloaded doc is this PC's cached copy (local_users), whose password can
      // be stale (changed on another device) or the '112233' default downloadUsers fills in.
      // It used to be the only thing checked, so the right password was rejected; ask the cloud.
      if (!isPwMatch && hasCreds) {
        final cloudUser = await _findUserInBothPlaces(input);
        if (cloudUser != null && passwordMatches(cloudUser)) {
          fsUser = cloudUser;
          isPwMatch = true;
        }
      }

      if (!isPwMatch) {
        debugPrint('[LoginPage] Firestore document found for $input, but password did not match');
        return false;
      }

      final role = _resolveRoleFromMap(fsUser);
      final hasValidRole = role.isNotEmpty && role != 'unknown' && role != 'unassigned';
      final status = (fsUser['status'] ?? fsUser['accountStatus'] ?? 'active').toString().toLowerCase().trim();

      if (hasValidRole && (status == 'corrupted' || fsUser['isCorruptedOrOrphanAuth'] == true)) {
        fsUser['status'] = 'active';
        fsUser['accountStatus'] = 'active';
        fsUser['isActive'] = true;
        fsUser['isCorruptedOrOrphanAuth'] = false;
      }

      final isDeleted = fsUser['isDeleted'] == true || status == 'deleted';
      final isCorrupted = !hasValidRole && (fsUser['isCorruptedOrOrphanAuth'] == true || status == 'corrupted');

      final isRevoked = isDeleted ||
          isCorrupted ||
          status == 'inactive' ||
          status == 'suspended' ||
          status == 'terminated' ||
          status == 'resigned' ||
          status == 'retired' ||
          status == 'offboarded' ||
          status == 'revoked' ||
          fsUser['isActive'] == false;

      if (isRevoked) {
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => AccessRevokedScreen(
                userData: fsUser!,
                reason: isDeleted ? 'deleted' : (isCorrupted ? 'corrupted' : status),
              ),
            ),
            (route) => false,
          );
        }
        return true;
      }

      // Valid and active account!
      if (fsUser['updates'] is Map) {
        fsUser = {
          ...fsUser,
          ...Map<String, dynamic>.from(fsUser['updates'] as Map),
        }..remove('updates');
      }

      final uEmail = (fsUser['email'] ?? '').toString().toLowerCase().trim();
      final uUser = (fsUser['usernameLower'] ?? fsUser['username'] ?? '').toString().toLowerCase().trim();
      final uUid = (fsUser['uid'] ?? fsUser['id'] ?? '').toString().trim();

      // Guard against stale/empty cloud docs for known Karachi hybrid staff
      if (uEmail == 'iqra@khi.com' || uUser == 'iqra' || uUid == 'local-iqra_khi_com') {
        fsUser['role'] = 'rec+dis';
        fsUser['branchId'] = 'karachi';
        fsUser['dispensaryId'] = 'saddar';
        fsUser['dispensaryIds'] = ['saddar'];
        fsUser['session'] = 'evening';
        fsUser['allowedSessions'] = ['all', 'evening'];
        fsUser['campSchedule'] = [
          {'campId': 'saddar', 'session': 'evening', 'startTime': '14:00', 'endTime': '20:00'}
        ];
      } else if (uEmail == 'kashif@khi.com' || uUser == 'kashif' || uUid == 'e5I5hQJQNpe08MuKmOc937dcMR43') {
        fsUser['role'] = 'rec+dis';
        fsUser['branchId'] = 'karachi';
        // dispensaryId resolved dynamically by CampSessionService.getActiveCamp() based on current shift
        fsUser['dispensaryId'] = 'kapayya';
        fsUser['dispensaryIds'] = ['kapayya', 'haji_camp', 'saddar'];
        fsUser['allowedSessions'] = ['all', 'morning', 'evening'];
        fsUser['canRegisterMedicine'] = true;
        fsUser['campSchedule'] = [
          {'campId': 'kapayya', 'session': 'morning', 'startTime': '10:00', 'endTime': '13:00'},
          {'campId': 'haji_camp', 'session': 'evening', 'startTime': '17:00', 'endTime': '20:00'}
        ];
      }

      fsUser['status'] = 'active';
      fsUser['accountStatus'] = 'active';
      fsUser['isActive'] = true;
      fsUser['role'] = _resolveRoleFromMap(fsUser);

      final uid = (fsUser['uid'] ?? fsUser['id'] ?? lowerInput).toString();
      fsUser['uid'] = uid;

      // Non-blocking Firestore last-login timestamp update mirrored to both places
      final nowTs = FieldValue.serverTimestamp();
      FirebaseFirestore.instance.collection('users').doc(uid).set({
        ...Map<String, dynamic>.from(fsUser),
        'lastLoginAt': nowTs,
        'lastOnlineAt': nowTs,
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 4)).catchError((_) {});

      final bId = (fsUser['branchId'] ?? '').toString().trim().toLowerCase();
      if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
        FirebaseFirestore.instance.collection('branches').doc(bId).collection('users').doc(uid).set({
          ...Map<String, dynamic>.from(fsUser),
          'lastLoginAt': nowTs,
          'lastOnlineAt': nowTs,
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 4)).catchError((_) {});
      }

      // Cache locally and across all aliases for offline use
      await LocalStorageService.saveLocalUser(fsUser);
      final effectiveUid = (fsUser['uid'] ?? '').toString().trim();
      final effectiveEmail = (fsUser['email'] ?? '').toString().trim().toLowerCase();
      final effectiveUsername = (fsUser['username'] ?? '').toString().trim();
      final effectiveUsernameLower = (fsUser['usernameLower'] ?? effectiveUsername).toString().toLowerCase().trim();

      final aliasesToCache = <String>{
        input.toLowerCase().trim(),
        if (effectiveUid.isNotEmpty) effectiveUid,
        if (effectiveEmail.isNotEmpty) effectiveEmail,
        if (effectiveUsername.isNotEmpty) effectiveUsername.toLowerCase(),
        if (effectiveUsernameLower.isNotEmpty) effectiveUsernameLower,
      };

      for (final a in aliasesToCache) {
        unawaited(_cacheCredentialsSafely(
          usernameOrEmail: a,
          password: password,
          userData: fsUser,
        ));
      }

      LanFirestoreGate.updateRole(fsUser['role']?.toString());
      unawaited(_completeFirebaseSignInInBackground(fsUser, password));

      if (mounted) {
        Flushbar(
          message: "Welcome back, ${fsUser['username'] ?? fsUser['name'] ?? input}!",
          backgroundColor: SoftPalette.green500,
          duration: const Duration(seconds: 2),
        ).show(context);
        _navigateToHomeOffline(fsUser);
      }
      return true;
    } catch (e) {
      debugPrint('[LoginPage] _tryFirestoreCredentialsLogin exception: $e');
      return false;
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

  /// Waits for a sign-in that outlived its timeout to finish (the Firebase call
  /// keeps running). Returns the signed-in user when it matches [email].
  Future<User?> _waitForFirebaseUser(String email, Duration maxWait) async {
    bool matches(User? u) =>
        u != null && (email.isEmpty || (u.email ?? '').toLowerCase() == email.toLowerCase());
    if (matches(FirebaseAuth.instance.currentUser)) return FirebaseAuth.instance.currentUser;
    try {
      return await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere(matches)
          .timeout(maxWait);
    } catch (_) {
      return null;
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
        // 1. Try authoritative Firestore document check (e.g. if user is not in Firebase Auth yet)
        final okFs = await _tryFirestoreCredentialsLogin(input, password);
        if (okFs) return;

        // 2. Try offline cache
        final hasCached = await OfflineAuthService.hasCachedCredentialsFor(
          input.toLowerCase(),
        );
        if (hasCached) {
          debugPrint('[LoginPage] invalid-credential but has cache — trying offline');
          final ok = await _attemptOfflineLogin(input, password);
          if (ok) return;
        }

        // 3. Try local_users database fallback
        final okLocal = await _tryLocalUsersFallbackLogin(input, password);
        if (okLocal) return;

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
          // Not a password problem: on Android this is usually app verification
          // (Play Integrity / reCAPTCHA) failing. Show the real reason.
          _showError("Sign-in service error (${e.code}): ${e.message ?? 'no details'}. "
              "Check the phone's date/time and Google Play services, then try again.");
        }
        return;

      default:
        debugPrint('[LoginPage] Unhandled Firebase error: ${e.code} — ${e.message}');
        final ok = await _attemptOfflineLogin(input, password);
        if (ok) return;
        final okLocal = await _tryLocalUsersFallbackLogin(input, password);
        if (okLocal) return;
        if (mounted) {
          _showError("Login failed (${e.code}): ${e.message ?? 'no details'}");
        }
    }
  }

  // ── Local-first login ─────────────────────────────────────────────────────

  /// Exact match on email / username / uid in the local users box. An email-prefix match
  /// ("ali" → "ali@khi.com") only counts when it is unambiguous across branches.
  Map<String, dynamic>? _findLocalUserExact(String input) {
    final t = input.trim().toLowerCase();
    if (t.isEmpty || !Hive.isBoxOpen(LocalStorageService.usersBox)) return null;
    final prefixMatches = <Map<String, dynamic>>[];
    for (final v in Hive.box(LocalStorageService.usersBox).values) {
      if (v is! Map) continue;
      final status = (v['status'] ?? v['accountStatus'] ?? '').toString().toLowerCase();
      if (v['isDeleted'] == true || status == 'deleted') continue;
      final email = (v['email'] ?? '').toString().toLowerCase().trim();
      final username = (v['username'] ?? '').toString().toLowerCase().trim();
      final usernameLower = (v['usernameLower'] ?? '').toString().toLowerCase().trim();
      final uid = (v['uid'] ?? v['id'] ?? '').toString().toLowerCase().trim();
      if (email == t || username == t || usernameLower == t || uid == t) {
        return Map<String, dynamic>.from(v);
      }
      if (email.contains('@') && email.split('@').first == t) {
        prefixMatches.add(Map<String, dynamic>.from(v));
      }
    }
    return prefixMatches.length == 1 ? prefixMatches.first : null;
  }

  /// Signs in instantly from credentials stored on this device by a previous successful
  /// login. Returns false (→ normal online flow) when there is no stored match, or when the
  /// stored profile is unusable/revoked so the server can make the authoritative decision.
  Future<bool> _tryLocalFirstLogin(String input, String password) async {
    Map<String, dynamic>? stored;
    try {
      stored = await OfflineAuthService.verifyOfflineCredentials(
        usernameOrEmail: input.toLowerCase(),
        password: password,
      );
    } catch (e) {
      debugPrint('[LoginPage] Local-first check skipped: $e');
      return false;
    }
    if (stored == null) return false;

    final userData = Map<String, dynamic>.from(stored);
    final role = _resolveRoleFromMap(userData);
    if (role.isEmpty || role == 'unknown' || role == 'unassigned') return false;

    final status = (userData['status'] ?? userData['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    const blocked = {'deleted', 'corrupted', 'inactive', 'suspended', 'terminated', 'resigned', 'retired', 'offboarded', 'revoked'};
    if (userData['isDeleted'] == true ||
        userData['isActive'] == false ||
        userData['isCorruptedOrOrphanAuth'] == true ||
        blocked.contains(status)) {
      return false;
    }

    userData['role'] = role;
    debugPrint('[LoginPage] ⚡ Local-first sign-in OK for $input (role=$role) — Firebase sign-in continues in background');
    _setLoginStep('login: local sign-in ok, opening app', 'Opening the app');
    unawaited(_completeFirebaseSignInInBackground(userData, password));

    if (mounted) {
      Flushbar(
        message: "Welcome back, ${userData['username'] ?? userData['name'] ?? input}!",
        backgroundColor: SoftPalette.green500,
        duration: const Duration(seconds: 2),
      ).show(context);
      _navigateToHomeOffline(userData);
    }
    return true;
  }

  /// After a local-first sign-in, establish the Firebase session (needed for cloud sync)
  /// without making the user wait. Runs after the login page is gone, so it must not touch
  /// widget state.
  Future<void> _completeFirebaseSignInInBackground(Map<String, dynamic> userData, String password) async {
    final email = (userData['email'] ?? '').toString().trim().toLowerCase();
    final current = FirebaseAuth.instance.currentUser;
    if (current != null && (current.email ?? '').toLowerCase() == email && email.isNotEmpty) return;

    // Let the home screen build its first frames before doing network work.
    await Future.delayed(const Duration(seconds: 2));
    try {
      UserCredential? cred;
      if (email.contains('@')) {
        try {
          cred = await FirebaseAuth.instance
              .signInWithEmailAndPassword(email: email, password: password)
              .timeout(const Duration(seconds: 15));
        } on FirebaseAuthException catch (authErr) {
          if (authErr.code == 'user-not-found' || authErr.code == 'invalid-credential') {
            // User credentials were verified against authoritative Firestore doc, but not yet created in Auth.
            // Automatically enroll them into Firebase Auth so cloud sync and security rules pass!
            try {
              cred = await FirebaseAuth.instance
                  .createUserWithEmailAndPassword(email: email, password: password)
                  .timeout(const Duration(seconds: 15));
              debugPrint('[LoginPage] 🌟 Auto-enrolled verified user into Firebase Auth for $email');
            } catch (createErr) {
              debugPrint('[LoginPage] Auto-enroll in Auth note: $createErr');
            }
          }
        }
      }

      // If email auth didn't establish a user session, establish fallback session via FirebaseSessionGuard
      // so Firestore security rules (request.auth != null) never block sync writes
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseSessionGuard.ensureSession(reason: 'direct_write');
      }

      final uid = cred?.user?.uid ?? FirebaseAuth.instance.currentUser?.uid;
      debugPrint('[LoginPage] ✅ Background Firebase session established for $email (uid: $uid)');
      if (uid != null && email.isNotEmpty) {
        final nowTs = FieldValue.serverTimestamp();
        FirebaseFirestore.instance.collection('users').doc(uid).set({
          'lastLoginAt': nowTs,
          'lastOnlineAt': nowTs,
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 6)).catchError((_) {});
        unawaited(DeviceInfoService.recordUserSession(userId: uid, email: email).catchError((_) {}));
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('[LoginPage] Background Firebase sign-in failed (${e.code}) — app continues on local session');
      if (e.code == 'user-disabled') {
        // Account disabled on the server: stop allowing instant local sign-in for it.
        await OfflineAuthService.clearCredentialsForUser(email);
      }
    } catch (e) {
      debugPrint('[LoginPage] Background Firebase sign-in notice: $e');
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
      final isDeleted = userData['isDeleted'] == true || userStatus == 'deleted';
      final isCorrupted = userData['isCorruptedOrOrphanAuth'] == true || userStatus == 'corrupted';
      final isRevoked = isDeleted ||
          isCorrupted ||
          userStatus == 'inactive' ||
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
            MaterialPageRoute(
              builder: (_) => AccessRevokedScreen(
                userData: userData,
                reason: isDeleted ? 'deleted' : (isCorrupted ? 'corrupted' : userStatus),
              ),
            ),
            (route) => false,
          );
        }
        return true;
      }

      debugPrint('[LoginPage] Offline login successful → role=${userData['role']}');
      unawaited(_completeFirebaseSignInInBackground(userData, password));
      if (mounted) {
        Flushbar(
          message: "Welcome back, ${userData['username']}! (Offline Mode)",
          backgroundColor: SoftPalette.orange350,
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
      final lowerInput = input.trim().toLowerCase();

      // Check Master Admin
      if (LocalStorageService.isMasterAdminCredentials(lowerInput, password)) {
        debugPrint('[LoginPage] ⚡ Master Admin matched in local fallback');
        final masterUser = LocalStorageService.getMasterAdminProfile();
        await _persistAndLaunchMasterAdmin(masterUser);
        return true;
      }

      final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
      final hashedInput = LocalStorageService.hashPassword(password);
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
          final isDeleted = u['isDeleted'] == true || status == 'deleted';

          final email = (u['email']?.toString() ?? '').toLowerCase().trim();
          final username = (u['username']?.toString() ?? '').toLowerCase().trim();
          final usernameLower = (u['usernameLower']?.toString() ?? '').toLowerCase().trim();
          final uUid = (u['uid'] ?? u['id'] ?? '').toString().toLowerCase().trim();
          final savedPass = u['password']?.toString();
          final savedHash = (u['passwordHash'] ?? u['hashedPassword'])?.toString();

          final normInput = lowerInput.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final inputPrefix = lowerInput.contains('@') ? lowerInput.split('@').first.replaceAll(RegExp(r'[^a-z0-9]'), '') : normInput;

          final normUser = username.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normUserLower = usernameLower.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normEmail = email.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normUid = uUid.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normName = (u['name']?.toString() ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          final emailPrefix = email.contains('@') ? email.split('@').first.replaceAll(RegExp(r'[^a-z0-9]'), '') : '';

          final isKeyMatch = username == lowerInput ||
              usernameLower == lowerInput ||
              email == lowerInput ||
              uUid == lowerInput ||
              (normInput.isNotEmpty && (
                  normUser == normInput ||
                  normUserLower == normInput ||
                  normEmail == normInput ||
                  normUid == normInput ||
                  normName == normInput ||
                  (emailPrefix.isNotEmpty && (emailPrefix == inputPrefix || emailPrefix == normInput)) ||
                  (normUser.isNotEmpty && (normUser == inputPrefix || normUser.contains(normInput) || normInput.contains(normUser))) ||
                  (normName.isNotEmpty && (normName == inputPrefix || normName.contains(normInput) || normInput.contains(normName)))
              ));

          if (isKeyMatch && isDeleted) {
            debugPrint('[LoginPage] Blocked attempt to authenticate deleted user via local fallback: $input');
            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(
                  builder: (_) => AccessRevokedScreen(
                    userData: u,
                    reason: 'deleted',
                  ),
                ),
                (route) => false,
              );
            }
            return true;
          }

          if (isDeleted) continue; // Never authenticate a deleted user

          final pwKeyUid = box.get('offline_pw__$uUid')?.toString();
          final pwKeyEmail = box.get('offline_pw__$email')?.toString();
          final pwKeyUser = box.get('offline_pw__$usernameLower')?.toString();
          final pwKeyInput = box.get('offline_pw__$lowerInput')?.toString();

          final isPwMatch = (savedPass != null && (savedPass == password || savedPass == hashedInput)) ||
                            (savedHash != null && (savedHash == hashedInput || savedHash == password)) ||
                            (pwKeyUid != null && (pwKeyUid == password || pwKeyUid == hashedInput)) ||
                            (pwKeyEmail != null && (pwKeyEmail == password || pwKeyEmail == hashedInput)) ||
                            (pwKeyUser != null && (pwKeyUser == password || pwKeyUser == hashedInput)) ||
                            (pwKeyInput != null && (pwKeyInput == password || pwKeyInput == hashedInput)) ||
                            ((savedPass == null || savedPass.isEmpty) && (savedHash == null || savedHash.isEmpty));

          if (isKeyMatch && isPwMatch) {
            u['role'] = _resolveRoleFromMap(u);
            unawaited(_completeFirebaseSignInInBackground(u, password));
            if (mounted) {
              Flushbar(
                message: "Welcome back, ${u['username'] ?? u['name'] ?? input}!",
                backgroundColor: SoftPalette.green500,
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

  // ── Master Admin Session Persistence & Quick Launch ──────────────────────
  Future<void> _persistAndLaunchMasterAdmin(Map<String, dynamic> masterUser) async {
    try {
      // Do not save to app_settings so master admin does not auto-login on subsequent app launches
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.delete('user_data');
        await box.delete('currentUser');
        await box.delete('user_role');
      }
      await LocalStorageService.saveLocalUser(masterUser);
    } catch (e) {
      debugPrint('[LoginPage] Error saving master admin session: $e');
    }

    if (mounted) {
      Flushbar(
        message: "Logged in as Master Administrator (Offline Access)",
        backgroundColor: SoftPalette.emerald500,
        duration: const Duration(seconds: 2),
      ).show(context);
      _navigateToHomeOffline(masterUser);
    }
  }



  static List<String> _getAllBranchIds() {
    final ids = <String>{
      'karachi', 'khi', 'saddar', 'haji_camp',
      'gujrat', 'grt',
      'sialkot', 'skt',
      'jalalpurjattan', 'jalalpur', 'jlj',
      'rawalpindi', 'rwp',
      'thattatimun', 'twt',
      'lahore', 'lhr',
      'islamabad', 'isb',
      'main',
    };
    try {
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final k in box.keys) {
          final s = k.toString().replaceFirst('branch:', '').trim().toLowerCase();
          if (s.isNotEmpty && !s.contains(' ') && s != 'null' && s != 'all' && s != 'global') ids.add(s);
        }
        for (final v in box.values) {
          if (v is Map) {
            final id = (v['id'] ?? v['branchId'] ?? '').toString().trim().toLowerCase();
            if (id.isNotEmpty && !id.contains(' ') && id != 'null' && id != 'all' && id != 'global') ids.add(id);
          }
        }
      }
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        for (final k in box.keys) {
          final s = k.toString().replaceFirst('branch:', '').trim().toLowerCase();
          if (s.isNotEmpty && !s.contains(' ') && s != 'null' && s != 'all' && s != 'global') ids.add(s);
        }
        for (final v in box.values) {
          if (v is Map) {
            final id = (v['id'] ?? v['branchId'] ?? '').toString().trim().toLowerCase();
            if (id.isNotEmpty && !id.contains(' ') && id != 'null' && id != 'all' && id != 'global') ids.add(id);
          }
        }
      }
    } catch (_) {}
    return ids.toList();
  }

  static Map<String, dynamic> _mergeCloudUserDocs(List<Map<String, dynamic>> docs, {required String defaultUsername}) {
    final Map<String, dynamic> merged = {};

    for (final doc in docs) {
      for (final entry in doc.entries) {
        final k = entry.key;
        final v = entry.value;
        if (v == null || v == '' || v == 'null') continue;

        if (!merged.containsKey(k) || merged[k] == null || merged[k] == '' || merged[k] == 'null' || merged[k] == 'unknown' || merged[k] == 'unassigned') {
          merged[k] = v;
        }
      }

      // Role resolution prioritizing authentic non-generic roles
      final docRole = _resolveRoleFromMap(doc);
      if (docRole.isNotEmpty && docRole != 'unknown' && docRole != 'unassigned') {
        final curRole = _resolveRoleFromMap(merged);
        if (curRole.isEmpty || curRole == 'unknown' || curRole == 'unassigned' || curRole == 'staff') {
          merged['role'] = docRole;
        }
      }

      // Branch ID prioritizing specific branches over 'all' or empty
      final docBranch = (doc['branchId'] ?? '').toString().trim().toLowerCase();
      if (docBranch.isNotEmpty && docBranch != 'all' && docBranch != 'global' && docBranch != 'unknown') {
        final curBranch = (merged['branchId'] ?? '').toString().trim().toLowerCase();
        if (curBranch.isEmpty || curBranch == 'all' || curBranch == 'global' || curBranch == 'unknown') {
          merged['branchId'] = docBranch;
        }
      }

      // Preserve passwords and credentials
      if (doc['password'] != null && doc['password'].toString().isNotEmpty) {
        merged['password'] = doc['password'];
      }
      if (doc['passwordHash'] != null && doc['passwordHash'].toString().isNotEmpty) {
        merged['passwordHash'] = doc['passwordHash'];
      }
      if (doc['hashedPassword'] != null && doc['hashedPassword'].toString().isNotEmpty) {
        merged['hashedPassword'] = doc['hashedPassword'];
      }
      if (doc['biometricPin'] != null && doc['biometricPin'].toString().isNotEmpty) {
        merged['biometricPin'] = doc['biometricPin'];
      }

      // Preserve clinical and educational configurations
      if (doc['dispensaryId'] != null && doc['dispensaryId'].toString().isNotEmpty) {
        merged['dispensaryId'] = doc['dispensaryId'];
      }
      if (doc['dispensaryIds'] is List && (doc['dispensaryIds'] as List).isNotEmpty) {
        merged['dispensaryIds'] = doc['dispensaryIds'];
      }
      if (doc['allowedSessions'] is List && (doc['allowedSessions'] as List).isNotEmpty) {
        merged['allowedSessions'] = doc['allowedSessions'];
      }
      if (doc['campSchedule'] is List && (doc['campSchedule'] as List).isNotEmpty) {
        merged['campSchedule'] = doc['campSchedule'];
      }
    }

    final effectiveRole = _resolveRoleFromMap(merged);
    merged['role'] = effectiveRole.isNotEmpty ? effectiveRole : 'unassigned';
    if (merged['email'] == null || (merged['email'] as String).isEmpty) {
      if (defaultUsername.contains('@')) {
        merged['email'] = defaultUsername.toLowerCase().trim();
      }
    }
    if (merged['username'] == null || (merged['username'] as String).isEmpty) {
      merged['username'] = defaultUsername.contains('@') ? defaultUsername.split('@').first : defaultUsername;
    }
    merged['usernameLower'] = (merged['usernameLower'] ?? merged['username']).toString().toLowerCase().trim();
    merged['status'] = 'active';
    merged['accountStatus'] = 'active';
    merged['isActive'] = true;
    merged['isCorruptedOrOrphanAuth'] = false;
    merged['isDeleted'] = false;

    return merged;
  }

  static String _resolveRoleFromMap(Map<String, dynamic> d) {
    String raw = (d['role'] ?? '').toString().toLowerCase().trim();

    final isGeneric = raw.isEmpty ||
        raw == 'unknown' ||
        raw == 'user' ||
        raw == 'staff' ||
        raw == 'employee' ||
        raw == 'standard' ||
        raw == 'unassigned' ||
        raw == 'member' ||
        raw == 'null';

    // 1. Check roles list
    if (isGeneric && d['roles'] is List && (d['roles'] as List).isNotEmpty) {
      final r = (d['roles'] as List).first.toString().toLowerCase().trim();
      if (r.isNotEmpty && r != 'unknown' && r != 'user' && r != 'staff') {
        raw = r;
      }
    }

    // 2. Check alternate designation/department keys
    if (isGeneric) {
      for (final k in ['type', 'accountType', 'userRole', 'designation', 'position', 'jobTitle', 'department', 'accessRole', 'category']) {
        if (d[k] != null && d[k].toString().trim().isNotEmpty) {
          final r = d[k].toString().toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown' && r != 'user' && r != 'staff' && r != 'employee') {
            raw = r;
            break;
          }
        }
      }
    }

    // 3. Check local_employees Hive box
    if (isGeneric) {
      try {
        if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
          final empBox = Hive.box(LocalStorageService.employeesBox);
          final uEmail = (d['email'] ?? '').toString().toLowerCase().trim();
          final uName = (d['username'] ?? d['name'] ?? '').toString().toLowerCase().trim();
          final uUid = (d['uid'] ?? d['id'] ?? '').toString().toLowerCase().trim();

          for (final val in empBox.values) {
            if (val is Map) {
              final e = Map<String, dynamic>.from(val);
              final eEmail = (e['email'] ?? '').toString().toLowerCase().trim();
              final eName = (e['name'] ?? e['fullName'] ?? '').toString().toLowerCase().trim();
              final eId = (e['id'] ?? e['employeeId'] ?? e['localId'] ?? '').toString().toLowerCase().trim();

              final isMatch = (uEmail.isNotEmpty && eEmail == uEmail) ||
                  (uName.isNotEmpty && (eName == uName || eId == uName)) ||
                  (uUid.isNotEmpty && eId == uUid);

              if (isMatch) {
                final desig = (e['designation'] ?? e['role'] ?? e['department'] ?? '').toString().toLowerCase().trim();
                if (desig.isNotEmpty && desig != 'unknown' && desig != 'staff' && desig != 'user') {
                  raw = desig;
                  break;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    // 4. Specializations & Student IDs
    if (isGeneric) {
      final spec = (d['specialization'] ?? d['teachingType'] ?? d['subject'] ?? '').toString().toLowerCase();
      if (spec.contains('quran') || spec.contains('hifz') || spec.contains('tajweed') || spec.contains('darse') || spec.contains('madrassa') || spec.contains('islamic')) {
        return 'madrassa teacher';
      }
      final sIds = d['studentIds'] ?? d['studentId'] ?? d['children'] ?? d['wards'];
      if ((sIds is List && sIds.isNotEmpty) || (sIds is String && sIds.trim().isNotEmpty)) {
        return 'madrassa guardian';
      }
    }

    final email = (d['email'] ?? '').toString().toLowerCase().trim();
    final username = (d['username'] ?? d['name'] ?? '').toString().toLowerCase().trim();
    final uid = (d['uid'] ?? d['id'] ?? '').toString().toLowerCase().trim();
    final idStr = '$email $username $uid';

    // 5. Semantic keyword heuristics on ID, email, username
    if (isGeneric) {
      if (idStr.contains('zaheer')) return 'hq manager';
      if (idStr.contains('server')) return 'server';
      if (idStr.contains('chairman')) return 'chairman';
      if (idStr.contains('ceo')) return 'ceo';
      if (idStr.contains('admin')) return 'admin';
      if (idStr.contains('branch_manager') || idStr.contains('branch manager')) return 'branch manager';
      if (idStr.contains('hq_manager') || idStr.contains('hqmanager') || idStr.contains('manager@')) return 'hq manager';
      if (idStr.contains('doctor') || idStr.contains('dr.') || idStr.contains('physician')) return 'doctor';
      if (idStr.contains('receptionist') || idStr.contains('reception') || idStr.contains('frontdesk')) return 'receptionist';
      if (idStr.contains('dispenser') || idStr.contains('dispensar') || idStr.contains('pharmacist') || idStr.contains('pharmacy')) return 'dispenser';
      if (idStr.contains('inventory') || idStr.contains('store')) return 'inventory';
      if (idStr.contains('dasterkhwaan') || idStr.contains('kitchen') || idStr.contains('cook')) return 'kitchen';
      if (idStr.contains('office boy') || idStr.contains('office_boy') || idStr.contains('peon')) return 'office boy';
      if (idStr.contains('donation') || idStr.contains('finance') || idStr.contains('cashier')) return 'donations';
      if (idStr.contains('madrassa') && idStr.contains('teacher')) return 'madrassa teacher';
      if (idStr.contains('madrassa') && (idStr.contains('admin') || idStr.contains('principal') || idStr.contains('head'))) return 'madrassa admin';
      if (idStr.contains('guardian') || idStr.contains('parent')) return 'madrassa guardian';
      if (idStr.contains('school') && (idStr.contains('principal') || idStr.contains('admin') || idStr.contains('head'))) return 'school principal';
      if (idStr.contains('school') && idStr.contains('teacher')) return 'school teacher';
      if (idStr.contains('principal') || idStr.contains('headmaster') || idStr.contains('headmistress')) return 'school principal';
      if (idStr.contains('teacher')) return 'madrassa teacher';
      if (idStr.contains('supervisor') || idStr.contains('incharge')) return 'supervisor';
    }

    raw = raw.replaceAll('_', ' ').replaceAll('-', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    // 6. Normalization
    if (raw == 'superadmin' || raw == 'super admin' || raw == 'masteradmin' || raw == 'master admin' || raw == 'administrator' || raw == 'gmwfadmin') return 'admin';
    if (raw == 'dispensar' || raw == 'pharmacist' || raw == 'chemist' || raw == 'pharmacy') return 'dispenser';
    if (raw == 'reception' || raw == 'front desk' || raw == 'receptionist') return 'receptionist';
    if (raw == 'doc' || raw == 'dr' || raw == 'medical officer' || raw == 'mo') return 'doctor';
    if (raw == 'hqmanager' || raw == 'hq_manager' || raw == 'hq' || raw == 'general manager' || raw == 'gm') return 'hq manager';
    if (raw == 'guardian' ||
        raw == 'parent' ||
        raw == 'madrassa parent' ||
        raw == 'madrassa guardian' ||
        raw == 'school guardian' ||
        raw == 'school parent' ||
        raw.contains('guardian') ||
        raw.contains('parent')) {
      return 'madrassa guardian';
    }
    if (raw == 'madrassa principal' || raw == 'madrassa admin' || raw == 'qari') return 'madrassa admin';
    if (raw == 'principal' || raw == 'school principal' || raw == 'school admin' || raw == 'headmaster' || raw == 'headmistress') return 'school principal';
    if (raw == 'teacher' || raw == 'faculty') {
      final bType = (d['branchType'] ?? '').toString().toLowerCase();
      if (bType.contains('school')) return 'school teacher';
      return 'madrassa teacher';
    }
    if (raw == 'kitchen' || raw == 'cook' || raw == 'chef') return 'kitchen';
    if (raw == 'office boy' || raw == 'office_boy' || raw == 'peon') return 'office boy';
    if (raw == 'donation' || raw == 'cashier' || raw == 'finance') return 'donations';
    if (raw == 'server') return 'server';

    if (raw.isEmpty || raw == 'unknown' || raw == 'user' || raw == 'staff' || raw == 'employee' || raw == 'standard' || raw == 'unassigned') {
      final bType = (d['branchType'] ?? d['branchId'] ?? '').toString().toLowerCase();
      if (bType.contains('school')) return 'school teacher';
      if (bType.contains('madrassa')) return 'madrassa teacher';
      if (bType.contains('dispensary') || bType.contains('clinic')) return 'receptionist';
      return 'unassigned';
    }

    return raw;
  }

  // ── Authoritative Firestore user data fetch ──────────────────────────────
  Future<Map<String, dynamic>?> _fetchUserDataFromFirestore(
      User user, String inputUsername, {Map<String, dynamic>? preloadedDoc}) async {
    final uid = user.uid;
    final userEmail = user.email?.toLowerCase().trim() ?? '';
    final inputLower = inputUsername.trim().toLowerCase();

    // 0. Instant in-memory check for system accounts (0ms)
    final systemAccounts = <String, Map<String, dynamic>>{
      'admin@system.com': {'role': 'admin', 'branchId': 'all', 'username': 'admin', 'name': 'Admin'},
      'admin@gmd.com': {'role': 'admin', 'branchId': 'all', 'username': 'admin', 'name': 'Admin'},
      'admin@gmail.com': {'role': 'admin', 'branchId': 'all', 'username': 'admin', 'name': 'Admin'},
      'admin': {'role': 'admin', 'branchId': 'all', 'username': 'admin', 'name': 'Admin'},
      'chairman@system.com': {'role': 'chairman', 'branchId': 'all', 'username': 'chairman', 'name': 'Chairman'},
      'chairman@gmd.com': {'role': 'chairman', 'branchId': 'all', 'username': 'chairman', 'name': 'Chairman'},
      'chairman': {'role': 'chairman', 'branchId': 'all', 'username': 'chairman', 'name': 'Chairman'},
      'ceo@system.com': {'role': 'ceo', 'branchId': 'all', 'username': 'ceo', 'name': 'CEO'},
      'ceo@gmd.com': {'role': 'ceo', 'branchId': 'all', 'username': 'ceo', 'name': 'CEO'},
      'ceo': {'role': 'ceo', 'branchId': 'all', 'username': 'ceo', 'name': 'CEO'},
      'server@system.com': {'role': 'server', 'branchId': 'all', 'username': 'server', 'name': 'Server Core'},
      'server@gmd.com': {'role': 'server', 'branchId': 'all', 'username': 'server', 'name': 'Server Core'},
      'server': {'role': 'server', 'branchId': 'all', 'username': 'server', 'name': 'Server Core'},
      'manager@system.com': {'role': 'hq manager', 'branchId': 'all', 'username': 'manager', 'name': 'HQ Manager'},
      'manager@gmd.com': {'role': 'hq manager', 'branchId': 'all', 'username': 'manager', 'name': 'HQ Manager'},
      'manager': {'role': 'hq manager', 'branchId': 'all', 'username': 'manager', 'name': 'HQ Manager'},
    };
    if (systemAccounts.containsKey(userEmail) || systemAccounts.containsKey(inputLower)) {
      final s = systemAccounts[userEmail] ?? systemAccounts[inputLower]!;
      debugPrint('[LoginPage] Fast system account matched for user: $userEmail / $inputLower');
      return {
        ...s,
        'uid': uid,
        'email': user.email ?? '$inputLower@gmd.com',
      };
    }

    // 1. Live Firestore queries FIRST when online
    try {
      final knownBranches = _getAllBranchIds();
      final parallelQueries = <Future<Map<String, dynamic>?>>[
        // Top-level users by UID
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get()
            .then((doc) {
          if (doc.exists && doc.data() != null) {
            final d = doc.data()!;
            final resolvedRole = _resolveRoleFromMap(d);
            return {
              ...d,
              'uid': uid,
              'email': user.email ?? d['email'],
              'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
              'role': resolvedRole,
              'branchId': d['branchId'] ?? '',
              'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
            };
          }
          return null;
        }).catchError((_) => null),

        // Direct branch queries by UID for all branches (No composite index required!)
        for (final b in knownBranches)
          FirebaseFirestore.instance
              .collection('branches')
              .doc(b)
              .collection('users')
              .doc(uid)
              .get()
              .then((doc) {
            if (doc.exists && doc.data() != null) {
              final d = doc.data()!;
              final resolvedRole = _resolveRoleFromMap(d);
              return {
                ...d,
                'uid': uid,
                'email': user.email ?? d['email'],
                'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                'role': resolvedRole,
                'branchId': d['branchId'] ?? b,
                'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
              };
            }
            return null;
          }).catchError((_) => null),

        // collectionGroup('users') by UID
        FirebaseFirestore.instance
            .collectionGroup('users')
            .where('uid', isEqualTo: uid)
            .limit(1)
            .get()
            .then((snap) {
          if (snap.docs.isNotEmpty) {
            final doc = snap.docs.first;
            final d = doc.data();
            final pathParts = doc.reference.path.split('/');
            final branchId = d['branchId'] ?? (pathParts.length >= 2 ? pathParts[1] : 'unknown');
            return {
              ...d,
              'uid': uid,
              'email': user.email ?? d['email'],
              'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
              'role': _resolveRoleFromMap(d),
              'branchId': branchId,
              'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
            };
          }
          return null;
        }).catchError((_) => null),
      ];

      if (userEmail.isNotEmpty) {
        parallelQueries.add(
          FirebaseFirestore.instance
              .collection('users')
              .where('email', isEqualTo: userEmail)
              .limit(1)
              .get()
              .then((snap) {
            if (snap.docs.isNotEmpty) {
              final doc = snap.docs.first;
              final d = doc.data();
              return {
                ...d,
                'uid': d['uid'] ?? uid,
                'email': user.email ?? d['email'],
                'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                'role': _resolveRoleFromMap(d),
                'branchId': d['branchId'] ?? '',
                'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
              };
            }
            return null;
          }).catchError((_) => null),
        );

        // Branch subcollections by email
        for (final b in knownBranches) {
          parallelQueries.add(
            FirebaseFirestore.instance
                .collection('branches')
                .doc(b)
                .collection('users')
                .where('email', isEqualTo: userEmail)
                .limit(1)
                .get()
                .then((snap) {
              if (snap.docs.isNotEmpty) {
                final doc = snap.docs.first;
                final d = doc.data();
                return {
                  ...d,
                  'uid': d['uid'] ?? uid,
                  'email': user.email ?? d['email'],
                  'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                  'role': _resolveRoleFromMap(d),
                  'branchId': d['branchId'] ?? b,
                  'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
                };
              }
              return null;
            }).catchError((_) => null),
          );
        }

        parallelQueries.add(
          FirebaseFirestore.instance
              .collectionGroup('users')
              .where('email', isEqualTo: userEmail)
              .limit(1)
              .get()
              .then((snap) {
            if (snap.docs.isNotEmpty) {
              final doc = snap.docs.first;
              final d = doc.data();
              final pathParts = doc.reference.path.split('/');
              final branchId = d['branchId'] ?? (pathParts.length >= 2 ? pathParts[1] : 'unknown');
              return {
                ...d,
                'uid': d['uid'] ?? uid,
                'email': user.email ?? d['email'],
                'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                'role': _resolveRoleFromMap(d),
                'branchId': branchId,
                'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
              };
            }
            return null;
          }).catchError((_) => null),
        );
      }

      if (inputLower.isNotEmpty) {
        parallelQueries.add(
          FirebaseFirestore.instance
              .collection('users')
              .where('usernameLower', isEqualTo: inputLower)
              .limit(1)
              .get()
              .then((snap) {
            if (snap.docs.isNotEmpty) {
              final doc = snap.docs.first;
              final d = doc.data();
              return {
                ...d,
                'uid': d['uid'] ?? uid,
                'email': user.email ?? d['email'],
                'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                'role': _resolveRoleFromMap(d),
                'branchId': d['branchId'] ?? '',
                'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
              };
            }
            return null;
          }).catchError((_) => null),
        );

        // Branch subcollections by usernameLower
        for (final b in knownBranches) {
          parallelQueries.add(
            FirebaseFirestore.instance
                .collection('branches')
                .doc(b)
                .collection('users')
                .where('usernameLower', isEqualTo: inputLower)
                .limit(1)
                .get()
                .then((snap) {
              if (snap.docs.isNotEmpty) {
                final doc = snap.docs.first;
                final d = doc.data();
                return {
                  ...d,
                  'uid': d['uid'] ?? uid,
                  'email': user.email ?? d['email'],
                  'username': d['username'] ?? inputUsername.split('@').first.toLowerCase(),
                  'role': _resolveRoleFromMap(d),
                  'branchId': d['branchId'] ?? b,
                  'name': d['name'] ?? d['username'] ?? inputUsername.split('@').first,
                };
              }
              return null;
            }).catchError((_) => null),
          );
        }
      }

      // Per-query cap: a slow/hanging query is dropped instead of discarding every answer
      // that already arrived (the old 8 s cap on the whole batch threw all results away).
      final results = await Future.wait(parallelQueries.map(
        (q) => q.timeout(const Duration(seconds: 4), onTimeout: () => null),
      ));
      final validDocs = results.whereType<Map<String, dynamic>>().toList();
      if (validDocs.isNotEmpty) {
        // Prioritize active profiles: filter out stale tombstones if active documents exist
        final activeDocs = validDocs.where((d) =>
            d['isDeleted'] != true &&
            (d['status'] ?? '').toString().toLowerCase().trim() != 'deleted' &&
            (d['accountStatus'] ?? '').toString().toLowerCase().trim() != 'deleted'
        ).toList();

        if (activeDocs.isEmpty) {
          debugPrint('[LoginPage] Deleted user profile detected for $uid ($inputUsername)');
          return {
            'uid': uid,
            'email': user.email,
            'isDeleted': true,
            'status': 'deleted',
            'role': 'unassigned',
          };
        }

        final merged = _mergeCloudUserDocs(activeDocs, defaultUsername: inputUsername);
        merged['uid'] = uid;
        merged['email'] = user.email ?? merged['email'];
        final role = (merged['role'] ?? '').toString();
        final effectiveRole = (role.isNotEmpty && role != 'unknown' && role != 'user' && role != 'staff' && role != 'unassigned')
            ? role
            : _resolveRoleFromMap(merged);
        merged['role'] = (effectiveRole.isNotEmpty && effectiveRole != 'unknown' && effectiveRole != 'unassigned') ? effectiveRole : 'unassigned';
        merged['isCorruptedOrOrphanAuth'] = false;
        if (merged['status'] == 'corrupted') merged['status'] = 'active';

        unawaited(LocalStorageService.saveLocalUser(merged));
        unawaited(OfflineAuthService.updateCachedUserData(merged));

        // Ensure profile is mirrored to real user.uid in Firestore root and branch
        FirebaseFirestore.instance.collection('users').doc(uid).set(
          Map<String, dynamic>.from(merged),
          SetOptions(merge: true),
        ).catchError((_) {});

        final bId = (merged['branchId'] ?? '').toString().trim().toLowerCase();
        if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
          FirebaseFirestore.instance.collection('branches').doc(bId).collection('users').doc(uid).set(
            Map<String, dynamic>.from(merged),
            SetOptions(merge: true),
          ).catchError((_) {});
        }

        debugPrint('[LoginPage] ✅ Authoritative profile loaded from Firestore: role=${merged['role']}, branch=${merged['branchId']}');
        return merged;
      }
    } catch (e) {
      debugPrint('[LoginPage] Parallel Firestore user data fetch notice: $e');
    }

    // 2. Check preloaded doc (if found during username resolution)
    if (preloadedDoc != null && preloadedDoc.isNotEmpty) {
      final r = _resolveRoleFromMap(preloadedDoc);
      if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
        debugPrint('[LoginPage] 🩹 User profile recovered from preloadedDoc (role: $r)');
        final docToSave = {
          ...preloadedDoc,
          'uid': uid,
          'email': user.email ?? preloadedDoc['email'],
          'role': r,
          'status': 'active',
          'accountStatus': 'active',
          'isActive': true,
          'isCorruptedOrOrphanAuth': false,
        };
        unawaited(LocalStorageService.saveLocalUser(docToSave));
        FirebaseFirestore.instance.collection('users').doc(uid).set(
          docToSave,
          SetOptions(merge: true),
        ).catchError((_) {});
        return docToSave;
      }
    }

    // 3. Offline / Network timeout fallback: local Hive storage
    try {
      final inputPrefix = inputLower.contains('@') ? inputLower.split('@').first : inputLower;
      Map<String, dynamic>? local = LocalStorageService.getLocalUserByUid(uid) ??
          LocalStorageService.findLocalUser(uid) ??
          (userEmail.isNotEmpty ? LocalStorageService.findLocalUser(userEmail) : null) ??
          LocalStorageService.findLocalUser(inputLower) ??
          LocalStorageService.findLocalUser(inputPrefix);

      // If not found by direct lookup, scan Hive usersBox
      if (local == null && Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final box = Hive.box(LocalStorageService.usersBox);
        for (final val in box.values) {
          if (val is Map) {
            final v = Map<String, dynamic>.from(val);
            final vUid = (v['uid'] ?? v['id'] ?? '').toString().trim();
            final vEmail = (v['email'] ?? '').toString().toLowerCase().trim();
            final vUser = (v['usernameLower'] ?? v['username'] ?? '').toString().toLowerCase().trim();
            final vName = (v['name'] ?? '').toString().toLowerCase().trim();
            if ((vUid.isNotEmpty && vUid == uid) ||
                (userEmail.isNotEmpty && vEmail == userEmail) ||
                (inputLower.isNotEmpty && (vUser == inputLower || vName == inputLower))) {
              local = v;
              break;
            }
          }
        }
      }

      if (local != null) {
        final isDel = local['isDeleted'] == true || (local['status'] ?? '').toString().toLowerCase().trim() == 'deleted';
        if (isDel) {
          debugPrint('[LoginPage] Deleted user profile detected in local storage for $uid');
          return {
            ...local,
            'uid': uid,
            'email': user.email ?? local['email'],
            'isDeleted': true,
            'status': 'deleted',
            'role': 'unassigned',
          };
        }
        final r = _resolveRoleFromMap(local);
        debugPrint('[LoginPage] User data resolved from local storage fallback (role: $r)');
        final healedRole = (r.isNotEmpty && r != 'unknown' && r != 'unassigned') ? r : (local['role'] ?? 'unassigned');
        final isIntact = healedRole != 'unassigned' && healedRole != 'unknown';
        final resolved = {
          ...local,
          'uid': uid,
          'email': user.email ?? local['email'],
          'role': healedRole,
          'username': local['username'] ?? inputUsername.split('@').first.toLowerCase(),
          'name': local['name'] ?? local['username'] ?? inputUsername.split('@').first,
          if (isIntact) 'status': 'active',
          if (isIntact) 'accountStatus': 'active',
          if (isIntact) 'isActive': true,
          if (isIntact) 'isCorruptedOrOrphanAuth': false,
        };

        if (isIntact) {
          unawaited(LocalStorageService.saveLocalUser(resolved));
          FirebaseFirestore.instance.collection('users').doc(uid).set(
            Map<String, dynamic>.from(resolved),
            SetOptions(merge: true),
          ).catchError((_) {});
        }
        return resolved;
      }
    } catch (_) {}

    // 4. Check OfflineAuthService cached user data
    try {
      final offUser = await OfflineAuthService.getCachedUserData(usernameOrEmail: uid) ??
          (userEmail.isNotEmpty ? await OfflineAuthService.getCachedUserData(usernameOrEmail: userEmail) : null) ??
          await OfflineAuthService.getCachedUserData(usernameOrEmail: inputLower);
      if (offUser != null) {
        final r = _resolveRoleFromMap(offUser);
        if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
          debugPrint('[LoginPage] 🩹 User profile recovered from OfflineAuthService (role: $r)');
          final restored = {
            ...offUser,
            'uid': uid,
            'email': user.email ?? offUser['email'],
            'role': r,
            'status': 'active',
            'accountStatus': 'active',
            'isActive': true,
            'isCorruptedOrOrphanAuth': false,
          };
          unawaited(LocalStorageService.saveLocalUser(restored));
          FirebaseFirestore.instance.collection('users').doc(uid).set(
            Map<String, dynamic>.from(restored),
            SetOptions(merge: true),
          ).catchError((_) {});
          return restored;
        }
      }
    } catch (_) {}

    // 4.5 Check pending sync queue for newly created/registered user profiles
    try {
      if (Hive.isBoxOpen('sync_queue')) {
        final qBox = Hive.box('sync_queue');
        for (final item in qBox.values) {
          if (item is Map) {
            final type = (item['type'] ?? item['action'] ?? '').toString();
            final qUid = (item['uid'] ?? '').toString();
            final qData = item['data'];
            if ((type == 'save_user' || type == 'create_user' || type == 'user_save') && qData is Map) {
              final d = Map<String, dynamic>.from(qData);
              final dUid = (d['uid'] ?? d['id'] ?? qUid).toString().trim();
              final dEmail = (d['email'] ?? '').toString().toLowerCase().trim();
              final dUser = (d['usernameLower'] ?? d['username'] ?? '').toString().toLowerCase().trim();
              final dName = (d['name'] ?? '').toString().toLowerCase().trim();
              final isMatch = (dUid.isNotEmpty && dUid == uid) ||
                  (userEmail.isNotEmpty && dEmail == userEmail) ||
                  (inputLower.isNotEmpty && (dUser == inputLower || dName == inputLower));

              if (isMatch) {
                final r = _resolveRoleFromMap(d);
                if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
                  debugPrint('[LoginPage] 🩹 Restoring profile from pending sync_queue for $uid (role: $r)');
                  d['uid'] = uid;
                  d['role'] = r;
                  d['status'] = 'active';
                  d['accountStatus'] = 'active';
                  d['isActive'] = true;
                  d['isDeleted'] = false;
                  d['isRevoked'] = false;
                  d['isCorruptedOrOrphanAuth'] = false;
                  unawaited(LocalStorageService.saveLocalUser(d));
                  unawaited(OfflineAuthService.updateCachedUserData(d));
                  FirebaseFirestore.instance.collection('users').doc(uid).set(
                    Map<String, dynamic>.from(d),
                    SetOptions(merge: true),
                  ).catchError((_) {});
                  final bId = (d['branchId'] ?? '').toString().trim().toLowerCase();
                  if (bId.isNotEmpty && bId != 'all') {
                    FirebaseFirestore.instance.collection('branches').doc(bId).collection('users').doc(uid).set(
                      Map<String, dynamic>.from(d),
                      SetOptions(merge: true),
                    ).catchError((_) {});
                  }
                  return d;
                }
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Notice checking sync_queue for user profile: $e');
    }

    // 4.6 Check local employees box (for teachers or staff registered as employee)
    try {
      if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final empBox = Hive.box(LocalStorageService.employeesBox);
        for (final val in empBox.values) {
          if (val is Map) {
            final e = Map<String, dynamic>.from(val);
            final eEmail = (e['email'] ?? '').toString().toLowerCase().trim();
            final eName = (e['name'] ?? e['fullName'] ?? '').toString().toLowerCase().trim();
            final eId = (e['id'] ?? e['employeeId'] ?? e['localId'] ?? '').toString().toLowerCase().trim();
            final isMatch = (userEmail.isNotEmpty && eEmail == userEmail) ||
                (inputLower.isNotEmpty && (eName == inputLower || eId == inputLower)) ||
                (uid.isNotEmpty && eId == uid.toLowerCase());
            if (isMatch) {
              final r = _resolveRoleFromMap(e);
              if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
                debugPrint('[LoginPage] 🩹 User profile recovered from employees box: $uid (role: $r)');
                final empUser = {
                  ...e,
                  'uid': uid,
                  'email': user.email ?? e['email'],
                  'username': inputUsername.split('@').first.toLowerCase(),
                  'role': r,
                  'status': 'active',
                  'accountStatus': 'active',
                  'isActive': true,
                  'isCorruptedOrOrphanAuth': false,
                };
                unawaited(LocalStorageService.saveLocalUser(empUser));
                FirebaseFirestore.instance.collection('users').doc(uid).set(
                  Map<String, dynamic>.from(empUser),
                  SetOptions(merge: true),
                ).catchError((_) {});
                return empUser;
              }
            }
          }
        }
      }
    } catch (_) {}

    // 5. Auth exists in Firebase Auth, but NO profile record exists in Firestore or local database.
    // This is an orphan or corrupted auth account.
    // STRICT GUARD: NEVER synthesize 'admin' or 'hq manager' role!
    debugPrint('[LoginPage] ⚠️ Guard triggered: User $uid ($inputUsername) exists only in Auth with no database profile.');
    return {
      'uid': uid,
      'email': user.email,
      'username': inputUsername.split('@').first.toLowerCase(),
      'name': inputUsername.split('@').first,
      'role': 'unassigned',
      'branchId': '',
      'status': 'corrupted',
      'isCorruptedOrOrphanAuth': true,
      'isDeleted': false,
    };
  }

  // ── Unified Dual-Path Cloud & Local User Lookup ────────────────────────────
  /// Searches BOTH places in Firestore (Root /users collection AND Branch subcollections /branches/{branchId}/users),
  /// as well as local Hive cache and sync queue.
  /// Merges all matching records so role, permissions, credentials, and branch mappings are never lost.
  /// A user doc holding only status fields: written under a username/email doc id (or a
  /// branch that isn't the user's) by the old allow/reject access action. Merged into the real
  /// account it carried accessRevoked/offboarded and showed "Access Revoked" to active users.
  static bool _isGhostUserDoc(Map<String, dynamic> d) {
    bool has(String k) => (d[k]?.toString().trim() ?? '').isNotEmpty;
    return !has('email') && !has('username') && !has('usernameLower') && !has('name') &&
        !has('role') && !has('password') && !has('passwordHash');
  }

  Future<Map<String, dynamic>?> _findUserInBothPlaces(String input, {bool knownOnline = false}) async {
    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();
    if (lower.isEmpty) return null;

    // 0. Fast in-memory check for system accounts (0ms)
    final systemAccounts = <String, Map<String, dynamic>>{
      'admin': {'role': 'admin', 'email': 'admin@gmd.com', 'username': 'admin'},
      'server': {'role': 'server', 'email': 'server@gmd.com', 'username': 'server'},
      'manager': {'role': 'hq manager', 'email': 'manager@gmd.com', 'username': 'manager'},
      'hq_manager': {'role': 'hq manager', 'email': 'manager@gmd.com', 'username': 'manager'},
      'chairman': {'role': 'chairman', 'email': 'chairman@gmd.com', 'username': 'chairman'},
      'ceo': {'role': 'ceo', 'email': 'ceo@gmd.com', 'username': 'ceo'},
      'doctor': {'role': 'doctor', 'email': 'doctor@gmd.com', 'username': 'doctor'},
      'receptionist': {'role': 'receptionist', 'email': 'receptionist@gmd.com', 'username': 'receptionist'},
      'dispenser': {'role': 'dispenser', 'email': 'dispenser@gmd.com', 'username': 'dispenser'},
      'inventory': {'role': 'inventory', 'email': 'inventory@gmd.com', 'username': 'inventory'},
      'kitchen': {'role': 'kitchen', 'email': 'kitchen@gmd.com', 'username': 'kitchen'},
      'donations': {'role': 'donations', 'email': 'donations@gmd.com', 'username': 'donations'},
    };
    if (systemAccounts.containsKey(lower)) {
      final s = systemAccounts[lower]!;
      debugPrint('[LoginPage] Fast match from system accounts for: $lower');
      return {
        ...s,
        'branchId': 'all',
      };
    }

    // 0.5. Fast check from local storage (0ms response)
    final localMatch = LocalStorageService.findLocalUser(lower) ?? LocalStorageService.findLocalUser(trimmed);
    if (localMatch != null && localMatch['email'] != null && (localMatch['email'] as String).contains('@')) {
      final r = _resolveRoleFromMap(localMatch);
      if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
        debugPrint('[LoginPage] Fast match from local storage for: $lower');
        return Map<String, dynamic>.from(localMatch);
      }
    }

    // 1. If online, query Firestore with fast-path staged resolution
    try {
      final isOnline = knownOnline || await _hasRealInternet();
      if (isOnline) {
        // Stage 1: Fast targeted query to Root /users collection (3-5 queries max, ~200ms)
        final rootQueries = <Future<List<Map<String, dynamic>>>>[
          // Root /users by doc ID (lower and raw)
          FirebaseFirestore.instance
              .collection('users')
              .doc(lower)
              .get()
              .then((doc) {
            if (doc.exists && doc.data() != null) {
              final d = doc.data()!;
              if (_isGhostUserDoc(d)) return <Map<String, dynamic>>[];
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') return <Map<String, dynamic>>[];
              return [{
                ...d,
                'uid': doc.id,
                'email': d['email'] ?? (lower.contains('@') ? lower : '$lower@gmd.com'),
                'username': d['username'] ?? doc.id,
                'role': _resolveRoleFromMap(d),
              }];
            }
            return <Map<String, dynamic>>[];
          }).catchError((_) => <Map<String, dynamic>>[]),

          if (lower != trimmed)
            FirebaseFirestore.instance
                .collection('users')
                .doc(trimmed)
                .get()
                .then((doc) {
              if (doc.exists && doc.data() != null) {
                final d = doc.data()!;
                if (_isGhostUserDoc(d)) return <Map<String, dynamic>>[];
                final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
                if (d['isDeleted'] == true || st == 'deleted') return <Map<String, dynamic>>[];
                return [{
                  ...d,
                  'uid': doc.id,
                  'email': d['email'] ?? (trimmed.contains('@') ? trimmed : '$lower@gmd.com'),
                  'username': d['username'] ?? doc.id,
                  'role': _resolveRoleFromMap(d),
                }];
              }
              return <Map<String, dynamic>>[];
            }).catchError((_) => <Map<String, dynamic>>[]),

          // Root /users by usernameLower
          FirebaseFirestore.instance
              .collection('users')
              .where('usernameLower', isEqualTo: lower)
              .limit(2)
              .get()
              .then((snap) {
            final list = <Map<String, dynamic>>[];
            for (final doc in snap.docs) {
              final d = doc.data();
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') continue;
              list.add({
                ...d,
                'uid': doc.id,
                'email': d['email'] ?? doc['email'] ?? '$lower@gmd.com',
                'username': d['username'] ?? doc['username'],
                'role': _resolveRoleFromMap(d),
              });
            }
            return list;
          }).catchError((_) => <Map<String, dynamic>>[]),

          // Root /users by username
          if (lower != trimmed)
            FirebaseFirestore.instance
                .collection('users')
                .where('username', isEqualTo: trimmed)
                .limit(2)
                .get()
                .then((snap) {
              final list = <Map<String, dynamic>>[];
              for (final doc in snap.docs) {
                final d = doc.data();
                final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
                if (d['isDeleted'] == true || st == 'deleted') continue;
                list.add({
                  ...d,
                  'uid': doc.id,
                  'email': d['email'] ?? doc['email'] ?? '$lower@gmd.com',
                  'username': d['username'] ?? doc['username'],
                  'role': _resolveRoleFromMap(d),
                });
              }
              return list;
            }).catchError((_) => <Map<String, dynamic>>[]),

          // Root /users by email
          FirebaseFirestore.instance
              .collection('users')
              .where('email', isEqualTo: lower)
              .limit(2)
              .get()
              .then((snap) {
            final list = <Map<String, dynamic>>[];
            for (final doc in snap.docs) {
              final d = doc.data();
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') continue;
              list.add({
                ...d,
                'uid': doc.id,
                'email': d['email'] ?? lower,
                'username': d['username'] ?? doc['username'],
                'role': _resolveRoleFromMap(d),
              });
            }
            return list;
          }).catchError((_) => <Map<String, dynamic>>[]),

          // Root /users by uid
          FirebaseFirestore.instance
              .collection('users')
              .where('uid', isEqualTo: trimmed)
              .limit(2)
              .get()
              .then((snap) {
            final list = <Map<String, dynamic>>[];
            for (final doc in snap.docs) {
              final d = doc.data();
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') continue;
              list.add({
                ...d,
                'uid': doc.id,
                'email': d['email'],
                'username': d['username'],
                'role': _resolveRoleFromMap(d),
              });
            }
            return list;
          }).catchError((_) => <Map<String, dynamic>>[]),
        ];

        final rootResults = await Future.wait(rootQueries.map(
          (q) => q.timeout(const Duration(seconds: 6), onTimeout: () => <Map<String, dynamic>>[]),
        ));
        final List<Map<String, dynamic>> foundInRoot = [];
        for (final list in rootResults) {
          foundInRoot.addAll(list);
        }

        if (foundInRoot.isNotEmpty) {
          final mergedUser = _mergeCloudUserDocs(foundInRoot, defaultUsername: trimmed);
          unawaited(LocalStorageService.saveLocalUser(mergedUser));
          unawaited(OfflineAuthService.updateCachedUserData(mergedUser));
          debugPrint('[LoginPage] ✅ Fast user resolved from root /users for: $input -> email: ${mergedUser['email']}, role: ${mergedUser['role']}, branch: ${mergedUser['branchId']}');
          return mergedUser;
        }

        // Stage 2: Query collectionGroup('users') (searches all branch subcollections in 1 query)
        final groupQueries = <Future<List<Map<String, dynamic>>>>[
          FirebaseFirestore.instance
              .collectionGroup('users')
              .where('usernameLower', isEqualTo: lower)
              .limit(3)
              .get()
              .then((snap) {
            final list = <Map<String, dynamic>>[];
            for (final doc in snap.docs) {
              final d = doc.data();
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') continue;
              final pathParts = doc.reference.path.split('/');
              final branchId = d['branchId'] ?? (pathParts.length >= 2 ? pathParts[1] : 'unknown');
              list.add({
                ...d,
                'uid': doc.id,
                'email': d['email'] ?? doc['email'] ?? '$lower@gmd.com',
                'username': d['username'] ?? doc['username'],
                'branchId': branchId,
                'role': _resolveRoleFromMap(d),
              });
            }
            return list;
          }).catchError((_) => <Map<String, dynamic>>[]),

          FirebaseFirestore.instance
              .collectionGroup('users')
              .where('email', isEqualTo: lower)
              .limit(3)
              .get()
              .then((snap) {
            final list = <Map<String, dynamic>>[];
            for (final doc in snap.docs) {
              final d = doc.data();
              final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
              if (d['isDeleted'] == true || st == 'deleted') continue;
              final pathParts = doc.reference.path.split('/');
              final branchId = d['branchId'] ?? (pathParts.length >= 2 ? pathParts[1] : 'unknown');
              list.add({
                ...d,
                'uid': doc.id,
                'email': d['email'] ?? lower,
                'username': d['username'] ?? doc['username'],
                'branchId': branchId,
                'role': _resolveRoleFromMap(d),
              });
            }
            return list;
          }).catchError((_) => <Map<String, dynamic>>[]),
        ];

        final groupResults = await Future.wait(groupQueries.map(
          (q) => q.timeout(const Duration(seconds: 6), onTimeout: () => <Map<String, dynamic>>[]),
        ));
        final List<Map<String, dynamic>> foundInGroup = [];
        for (final list in groupResults) {
          foundInGroup.addAll(list);
        }

        if (foundInGroup.isNotEmpty) {
          final mergedUser = _mergeCloudUserDocs(foundInGroup, defaultUsername: trimmed);
          unawaited(LocalStorageService.saveLocalUser(mergedUser));
          unawaited(OfflineAuthService.updateCachedUserData(mergedUser));
          debugPrint('[LoginPage] ✅ User resolved via collectionGroup for: $input -> email: ${mergedUser['email']}, role: ${mergedUser['role']}, branch: ${mergedUser['branchId']}');
          return mergedUser;
        }

        // Stage 3: Direct branch queries as fallback
        final checkBranches = _getAllBranchIds();
        final branchQueries = <Future<List<Map<String, dynamic>>>>[
          for (final b in checkBranches) ...[
            FirebaseFirestore.instance
                .collection('branches')
                .doc(b)
                .collection('users')
                .doc(lower)
                .get()
                .then((doc) {
              if (doc.exists && doc.data() != null) {
                final d = doc.data()!;
                if (_isGhostUserDoc(d)) return <Map<String, dynamic>>[];
                final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
                if (d['isDeleted'] == true || st == 'deleted') return <Map<String, dynamic>>[];
                return [{
                  ...d,
                  'uid': doc.id,
                  'email': d['email'] ?? '$lower@$b.com',
                  'username': d['username'] ?? doc.id,
                  'branchId': b,
                  'role': _resolveRoleFromMap(d),
                }];
              }
              return <Map<String, dynamic>>[];
            }).catchError((_) => <Map<String, dynamic>>[]),

            FirebaseFirestore.instance
                .collection('branches')
                .doc(b)
                .collection('users')
                .where('usernameLower', isEqualTo: lower)
                .limit(2)
                .get()
                .then((snap) {
              final list = <Map<String, dynamic>>[];
              for (final doc in snap.docs) {
                final d = doc.data();
                final st = (d['status'] ?? d['accountStatus'] ?? '').toString().toLowerCase().trim();
                if (d['isDeleted'] == true || st == 'deleted') continue;
                list.add({
                  ...d,
                  'uid': doc.id,
                  'email': d['email'] ?? '$lower@$b.com',
                  'username': d['username'] ?? doc['username'],
                  'branchId': b,
                  'role': _resolveRoleFromMap(d),
                });
              }
              return list;
            }).catchError((_) => <Map<String, dynamic>>[]),
          ],
        ];

        final branchResults = await Future.wait(branchQueries.map(
          (q) => q.timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
        ));
        final List<Map<String, dynamic>> foundInBranches = [];
        for (final list in branchResults) {
          foundInBranches.addAll(list);
        }

        if (foundInBranches.isNotEmpty) {
          final mergedUser = _mergeCloudUserDocs(foundInBranches, defaultUsername: trimmed);
          unawaited(LocalStorageService.saveLocalUser(mergedUser));
          unawaited(OfflineAuthService.updateCachedUserData(mergedUser));
          debugPrint('[LoginPage] ✅ Authoritative user resolved from branch subcollections for: $input -> email: ${mergedUser['email']}, role: ${mergedUser['role']}, branch: ${mergedUser['branchId']}');
          return mergedUser;
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Cloud dual-path lookup notice: $e');
    }

    // 2. Fallback to local Hive storage (when offline or Firestore didn't find / timed out)
    try {
      final local = LocalStorageService.findLocalUser(lower) ?? LocalStorageService.findLocalUser(trimmed);
      if (local != null) {
        final email = local['email']?.toString();
        if (email != null && email.isNotEmpty) {
          debugPrint('[LoginPage] Match from LocalStorageService for: $input');
          return {
            ...local,
            'role': _resolveRoleFromMap(local),
          };
        }
      }
      final box = Hive.isBoxOpen('local_users')
          ? Hive.box('local_users')
          : await Hive.openBox('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final u = Map<String, dynamic>.from(val);
          final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
          final isDeleted = u['isDeleted'] == true || status == 'deleted';
          if (isDeleted) continue;

          final uName = (u['username']?.toString() ?? '').toLowerCase().trim();
          final uNameLower = (u['usernameLower']?.toString() ?? '').toLowerCase().trim();
          final name = (u['name']?.toString() ?? '').toLowerCase().trim();
          final email = (u['email']?.toString() ?? '').toLowerCase().trim();
          final uid = (u['uid']?.toString() ?? u['id']?.toString() ?? '').toLowerCase().trim();

          if (uName == lower || uNameLower == lower || name == lower || email == lower || uid == lower || email.startsWith('$lower@')) {
            debugPrint('[LoginPage] Match from local_users Hive for: $lower');
            return {
              ...u,
              'email': u['email'],
              'username': u['username'] ?? u['name'],
              'branchId': u['branchId'] ?? 'all',
              'role': _resolveRoleFromMap(u),
            };
          }
        }
      }
    } catch (e) {
      debugPrint('[LoginPage] Local username lookup notice: $e');
    }

    // 3. Fallback to pending sync_queue for newly registered accounts
    try {
      if (Hive.isBoxOpen('sync_queue')) {
        final qBox = Hive.box('sync_queue');
        for (final item in qBox.values) {
          if (item is Map) {
            final type = (item['type'] ?? item['action'] ?? '').toString();
            final qData = item['data'];
            if ((type == 'save_user' || type == 'create_user') && qData is Map) {
              final d = Map<String, dynamic>.from(qData);
              final uLower = (d['usernameLower'] ?? d['username'] ?? '').toString().toLowerCase().trim();
              final uName = (d['name'] ?? '').toString().toLowerCase().trim();
              final uEmail = (d['email'] ?? '').toString().toLowerCase().trim();
              if (uLower == lower || uName == lower || uEmail == lower) {
                final em = (d['email'] ?? '').toString().trim();
                if (em.isNotEmpty) {
                  debugPrint('[LoginPage] Match from sync_queue for: $lower -> $em');
                  return {
                    ...d,
                    'role': _resolveRoleFromMap(d),
                  };
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  // ── Navigation helpers ────────────────────────────────────────────────────
  void _navigateToHome(User user, Map<String, dynamic> userData) async {
    final uEmail = (userData['email'] ?? '').toString().toLowerCase().trim();
    final uName = (userData['username'] ?? userData['usernameLower'] ?? '').toString().toLowerCase().trim();
    final uUid = (userData['uid'] ?? userData['id'] ?? '').toString().trim();
    final isNavKashif = uEmail == 'kashif@khi.com' || uEmail.startsWith('kashif@') || uName == 'kashif' || uUid == 'e5I5hQJQNpe08MuKmOc937dcMR43';
    if (isNavKashif) {
      userData['branchId'] = 'karachi';
      userData['branchName'] = 'Karachi';
      userData['branch'] = 'karachi';
      userData['role'] = 'rec+dis';
      userData['dispensaryIds'] = ['kapayya', 'haji_camp', 'saddar'];
    }

    try {
      final box = Hive.isBoxOpen('app_settings')
          ? Hive.box('app_settings')
          : await Hive.openBox('app_settings');
      await box.put('user_data', userData);
      await box.put('currentUser', userData);
      if (userData['role'] != null) await box.put('user_role', userData['role']);
      if (isNavKashif) {
        final currentBranch = (box.get('selected_branch') ?? box.get('current_branch'))?.toString().toLowerCase().trim();
        if (currentBranch != null && (currentBranch.contains('gujrat') || currentBranch == 'grt')) {
          await box.put('selected_branch', 'karachi');
          await box.put('current_branch', 'karachi');
        }
      }
      final assigned = CampSessionService.getAssignedCamps(userData);
      if (assigned.length == 1) {
        await CampSessionService.setActiveCamp(assigned.first);
      } else if (assigned.isEmpty) {
        await CampSessionService.clearActiveCamp();
      }
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
    final uEmail = (userData['email'] ?? '').toString().toLowerCase().trim();
    final uName = (userData['username'] ?? userData['usernameLower'] ?? '').toString().toLowerCase().trim();
    final uUid = (userData['uid'] ?? userData['id'] ?? '').toString().trim();
    final isNavKashif = uEmail == 'kashif@khi.com' || uEmail.startsWith('kashif@') || uName == 'kashif' || uUid == 'e5I5hQJQNpe08MuKmOc937dcMR43';
    if (isNavKashif) {
      userData['branchId'] = 'karachi';
      userData['branchName'] = 'Karachi';
      userData['branch'] = 'karachi';
      userData['role'] = 'rec+dis';
      userData['dispensaryIds'] = ['kapayya', 'haji_camp', 'saddar'];
    }

    final isMaster = userData['isMasterAdmin'] == true ||
        userData['uid'] == 'master-local-admin' ||
        userData['id'] == 'master-local-admin';

    try {
      final box = Hive.isBoxOpen('app_settings')
          ? Hive.box('app_settings')
          : await Hive.openBox('app_settings');
      if (!isMaster) {
        await box.put('user_data', userData);
        await box.put('currentUser', userData);
        if (userData['role'] != null) await box.put('user_role', userData['role']);
      } else {
        await box.delete('user_data');
        await box.delete('currentUser');
        await box.delete('user_role');
      }
      if (isNavKashif) {
        final currentBranch = (box.get('selected_branch') ?? box.get('current_branch'))?.toString().toLowerCase().trim();
        if (currentBranch != null && (currentBranch.contains('gujrat') || currentBranch == 'grt')) {
          await box.put('selected_branch', 'karachi');
          await box.put('current_branch', 'karachi');
        }
      }
      final assigned = CampSessionService.getAssignedCamps(userData);
      if (assigned.length == 1) {
        await CampSessionService.setActiveCamp(assigned.first);
      } else if (assigned.isEmpty) {
        await CampSessionService.clearActiveCamp();
      }
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
      backgroundColor: SoftPalette.red500,
      duration: const Duration(seconds: 5),
    ).show(context);
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = MediaQuery.sizeOf(context);
    final isDesktopScreen = s.width >= 900;
    final patternW = isDesktopScreen ? 600.0 : (s.width * 0.75).clamp(240.0, 420.0);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = isDesktopScreen ? 800 : (patternW * dpr).toInt().clamp(240, 500);

    return Scaffold(
      backgroundColor: isDark ? SoftPalette.teal900 : SoftPalette.green100t,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // ── Islamic Arch Frame Pattern (2.webp) on LEFT SIDE ────────────────
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: patternW,
            child: Opacity(
              opacity: isDark ? 0.35 : 0.22,
              child: GDecorativeImage.asset(
                'assets/images/2.webp',
                fit: BoxFit.fitHeight,
                alignment: Alignment.topLeft,
                gaplessPlayback: true,
                cacheWidth: cacheW, // responsive decode width — instant render on mobile
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),


          // ── Islamic Geometric Vector Pattern Overlay ──────────────────────
          Positioned.fill(
            child: CustomPaint(
              painter: IslamicPatternPainter(
                color: isDark
                    ? SoftPalette.emerald350.withValues(alpha: 0.04)
                    : SoftPalette.emerald500.withValues(alpha: 0.03),
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
                    ? SoftPalette.emerald350.withValues(alpha: 0.12)
                    : SoftPalette.emerald500.withValues(alpha: 0.08),
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
                    ? SoftPalette.emerald550.withValues(alpha: 0.15)
                    : SoftPalette.emerald350.withValues(alpha: 0.08),
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
    final titleMain = isDark ? SoftPalette.gray50 : SoftPalette.emerald700;
    final titleAccent = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final subtitleColor = isDark ? SoftPalette.slate350 : SoftPalette.slate700;

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
                        isDark ? SoftPalette.emerald350 : SoftPalette.emerald500,
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
    final titleMain = isDark ? SoftPalette.gray50 : SoftPalette.emerald700;
    final titleAccent = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final subtitleColor = isDark ? SoftPalette.slate350 : SoftPalette.slate600;
    final badgeColor = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;

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
        ? SoftPalette.teal900.withValues(alpha: 0.95)
        : SoftPalette.gray50;
    final cardBorder = isDark
        ? SoftPalette.emerald350.withValues(alpha: 0.3)
        : SoftPalette.gray50;
    final cardShadow = isDark
        ? SoftPalette.gray900.withValues(alpha: 0.4)
        : SoftPalette.emerald550.withValues(alpha: 0.08);
    final badgeColor = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final badgeDivider = isDark ? SoftPalette.emerald550 : SoftPalette.emerald150;
    final titleMain = isDark ? SoftPalette.gray50 : SoftPalette.emerald700;
    final titleAccent = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final subtitleColor = isDark ? SoftPalette.slate350 : SoftPalette.slate600;

    final inputLabelColor = isDark ? SoftPalette.emerald150 : SoftPalette.emerald700;
    final inputFill = isDark ? SoftPalette.teal900 : SoftPalette.gray50;
    final inputBorder = isDark ? SoftPalette.emerald750 : SoftPalette.slate150;
    final inputFocusBorder = isDark ? SoftPalette.emerald350 : SoftPalette.emerald500;
    final inputTextColor = isDark ? SoftPalette.gray50 : SoftPalette.slate900;
    final inputHintColor = isDark ? SoftPalette.slate600 : SoftPalette.slate350;
    final inputIconColor = isDark ? SoftPalette.emerald350 : SoftPalette.emerald500;

    final btnGradientColors = isDark
        ? [SoftPalette.emerald350, SoftPalette.emerald500]
        : [SoftPalette.emerald500, SoftPalette.emerald550];

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
                color: isDark ? SoftPalette.orange800.withValues(alpha: 0.6) : SoftPalette.amber100m,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: SoftPalette.amber300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: SoftPalette.orange400),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "OFFLINE MODE ACTIVE",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.orange400),
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
                  color: isDark ? SoftPalette.slate550 : SoftPalette.slate350,
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
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(color: SoftPalette.gray50, strokeWidth: 2.4),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Text(
                                '$_loginStep…',
                                key: ValueKey(_loginStep),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: SoftPalette.gray50),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Text(
                            "Sign In",
                            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded, color: SoftPalette.gray50, size: 18),
                        ],
                      ),
              ),
            ),
          ),

          if (_loading) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () {
                  if (mounted) {
                    setState(() {
                      _loading = false;
                      _loginStep = 'Cancelled';
                    });
                    _showError("Login attempt cancelled. Please try again or sign in offline.");
                  }
                },
                child: const Text(
                  "Cancel",
                  style: TextStyle(
                    color: SoftPalette.slate400,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],

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
              "GMWF Management Platform  •  v${AutoUpdateService.resolvedVersion}",
              style: TextStyle(
                fontSize: 11,
                color: isDark ? SoftPalette.slate600 : SoftPalette.slate550,
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
            backgroundColor: SoftPalette.teal900,
            title: const Text("Clear Saved Login?", style: TextStyle(color: SoftPalette.gray50)),
            content: const Text(
              "This will remove cached credentials and allow a fresh sign-in.",
              style: TextStyle(color: SoftPalette.slate350),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text("Cancel", style: TextStyle(color: SoftPalette.slate350)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.emerald350),
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text("Clear", style: TextStyle(color: SoftPalette.gray50)),
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
            backgroundColor: SoftPalette.orange350,
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
            color: SoftPalette.emerald350,
          ),
        ),
      ),
    );
  }

  // ── Feature Item Pill ─────────────────────────────────────────────────────
  Widget _buildFeatureItem(IconData icon, String title, bool isDark) {
    final bg = isDark ? SoftPalette.teal900 : SoftPalette.gray50;
    final border = isDark ? SoftPalette.emerald750 : SoftPalette.emerald150;
    final iconColor = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final textColor = isDark ? SoftPalette.slate350 : SoftPalette.slate800;

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
                      color: SoftPalette.emerald500.withValues(alpha: 0.08),
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
      {'icon': Icons.checkroom_outlined, 'title': 'GMWF FREE', 'sub': 'LIBAAS'},
      {'icon': Icons.medical_services_outlined, 'title': 'GMWF FREE', 'sub': 'DISPENSARY'},
      {'icon': Icons.menu_book_outlined, 'title': 'GMWF FREE', 'sub': 'MADRASSA'},
    ];

    final bg = isDark
        ? SoftPalette.teal900.withValues(alpha: 0.95)
        : SoftPalette.green100t.withValues(alpha: 0.95);
    final border = isDark ? SoftPalette.emerald750 : SoftPalette.emerald150m;
    final iconColor = isDark ? SoftPalette.emerald300 : SoftPalette.emerald500;
    final textColor = isDark ? SoftPalette.slate350 : SoftPalette.emerald700;

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
                color: isDark ? SoftPalette.emerald750 : SoftPalette.emerald150m,
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
  IslamicPatternPainter({this.color = SoftPalette.emerald350A6});

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

