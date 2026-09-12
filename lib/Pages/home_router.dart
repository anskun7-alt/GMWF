// lib/pages/home_router.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:rxdart/rxdart.dart';
import '../realtime/connection_manager.dart';
import '../realtime/realtime_manager.dart';
import '../services/local_storage_service.dart';
import '../services/firestore_service.dart';
import '../services/device_info_service.dart';
import '../services/role_simulator_service.dart';
import '../widgets/update_dialog_widget.dart';

import '../utils/formatters.dart';
import '../services/auth_service.dart';
import '../services/cloud_messaging_service.dart';
import '../services/offline_auth_service.dart' as offline_auth;
import '../models/patient.dart';
import '../models/token.dart';

import '../services/camp_session_service.dart';
import '../widgets/camp_selection_dialog.dart';
import 'dispensary/receptionist/receptionist_screen.dart';
import 'dispensary/doctor/doctor_screen.dart';
import 'dispensary/dispensar/inventory.dart';
import 'dispensary/dispensar/dispensar_screen.dart';
import 'dispensary/hybrid_dispensary_screen.dart';
import 'login_page.dart';
import 'access_revoked_screen.dart';
import 'server.dart';

import 'dasterkhwaan/office_boy.dart';
import 'dasterkhwaan/kitchen.dart';
import 'donations/donations_screen.dart';
import 'welfare/ramadan_welfare_screen.dart';
import 'donations/donations_shared.dart';
import '../widgets/gmwf_loading_view.dart';
import 'global_modular_dashboard.dart'; // Unified modular entry point
import 'madrassa/madrassa_dashboard.dart';
import 'madrassa/madrassa_guardian_screen.dart';
import 'school/school_dashboard.dart';
import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';


class HomeRouter extends StatefulWidget {
  final User? user;
  final Map<String, dynamic>? localUser;

  const HomeRouter({
    super.key,
    this.user,
    this.localUser,
  });

  @override
  State<HomeRouter> createState() => _HomeRouterState();
}

class _HomeRouterState extends State<HomeRouter> {
  late Future<Map<String, dynamic>?> _userDataFuture;
  StreamSubscription? _revokeListener;
  Timer? _periodicUpdateTimer;
  Map<String, dynamic>? _accessRevokedData;

  @override
  void initState() {
    super.initState();
    _userDataFuture = _fetchUserData();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final userData = await _userDataFuture;
      if (mounted && userData != null) {
        final role = (userData['role'] ?? '').toString().toLowerCase();
        final isServerMode = role == 'server';
        UpdateDialogWidget.showUpdateDialogIfNeeded(context, isServerMode: isServerMode);

        if (!isServerMode) {
          final rawBranchId = (userData['branchId'] ?? '').toString().trim();
          // Executive roles (chairman, CEO) have branchId='all' — resolve to the
          // first known real branch so ConnectionManager can find the server IP.
          String branchId = rawBranchId;
          if (branchId.isEmpty || branchId == 'all' || branchId == 'global') {
            try {
              if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
                final box = Hive.box(LocalStorageService.branchesBox);
                for (final val in box.values) {
                  if (val is Map) {
                    final id = (val['id'] ?? '').toString().trim().toLowerCase();
                    final isOff = val['isOffboarded'] == true || val['status'] == 'offboarded';
                    if (id.isNotEmpty && id != 'all' && id != 'global' && !isOff) {
                      branchId = id;
                      break;
                    }
                  }
                }
              }
            } catch (_) {}
          }
          final username = (userData['username'] ?? userData['name'] ?? userData['email'] ?? '').toString();
          final uid = (userData['uid'] ?? userData['id'] ?? username).toString();
          ConnectionManager().start(
            role: role,
            branchId: branchId,
            username: username,
          );
          unawaited(CloudMessagingService().registerTokenForUser(
            userId: uid,
            role: role,
            branchId: rawBranchId.isEmpty ? 'all' : rawBranchId,
          ));
        }

        // Periodically check for updates every 2 hours so users who never log out stay updated
        _periodicUpdateTimer?.cancel();
        _periodicUpdateTimer = Timer.periodic(const Duration(hours: 2), (_) {
          if (mounted) {
            UpdateDialogWidget.showUpdateDialogIfNeeded(context, isServerMode: isServerMode);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _periodicUpdateTimer?.cancel();
    _revokeListener?.cancel();
    super.dispose();
  }

  /// Returns true if the given status string represents a revoked account.
  static bool _isStatusRevoked(String status, Map<String, dynamic>? data) {
    return status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        (data != null && data['isActive'] == false);
  }

  /// Start listening to local Hive storage and LAN RealtimeManager for revocation events (zero Firestore snapshots).
  void _startRevokeListener(String uid, String? branchId) {
    _revokeListener?.cancel();

    final streams = <Stream<dynamic>>[];
    try {
      if (Hive.isBoxOpen('local_users')) {
        streams.add(Hive.box('local_users').watch());
      }
    } catch (_) {}
    try {
      streams.add(RealtimeManager().messageStream);
    } catch (_) {}

    void checkRevokeStatus() {
      if (!mounted) return;
      try {
        if (Hive.isBoxOpen('local_users')) {
          final box = Hive.box('local_users');
          for (final val in box.values) {
            if (val is Map) {
              final id = (val['uid'] ?? val['id'] ?? '').toString();
              if (id == uid) {
                final status = (val['status'] ?? val['accountStatus'] ?? 'active')
                    .toString()
                    .toLowerCase()
                    .trim();
                final data = Map<String, dynamic>.from(val);
                if (_isStatusRevoked(status, data)) {
                  debugPrint('[HomeRouter] Local revoke detected for UID: $uid');
                  setState(() {
                    _accessRevokedData = {...data, 'uid': uid};
                  });
                }
                break;
              }
            }
          }
        }
      } catch (_) {}
    }

    if (streams.isNotEmpty) {
      _revokeListener = Rx.merge(streams).listen((event) {
        if (event is Map) {
          final type = (event['type'] ?? event['action'] ?? '').toString().toLowerCase();
          final targetUid = (event['uid'] ?? event['userId'] ?? '').toString();
          if (targetUid == uid && (type == 'user_revoked' || type == 'revoke_user' || type == 'account_status_changed')) {
            debugPrint('[HomeRouter] LAN real-time revoke message received for UID: $uid');
            setState(() {
              _accessRevokedData = {'uid': uid, 'status': 'revoked', ...event};
            });
            return;
          }
        }
        checkRevokeStatus();
      }, onError: (e) {
        debugPrint('[HomeRouter] Local revoke listener notice: $e');
      });
    }
  }

  @override
  void didUpdateWidget(HomeRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldUid = (oldWidget.user?.uid ?? oldWidget.localUser?['uid'] ?? oldWidget.localUser?['email'] ?? '').toString();
    final newUid = (widget.user?.uid ?? widget.localUser?['uid'] ?? widget.localUser?['email'] ?? '').toString();
    if (oldUid != newUid && newUid.isNotEmpty) {
      setState(() {
        _userDataFuture = _fetchUserData();
      });
    }
  }

  Future<bool> _checkConnectivity() async {
    try {
      final connectivityResult = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint("HomeRouter: Connectivity check timed out");
        return [ConnectivityResult.none];
      });
      return connectivityResult
          .any((result) => result != ConnectivityResult.none);
    } catch (e) {
      debugPrint("Connectivity check error: $e");
      return false;
    }
  }

  Future<Map<String, dynamic>?> _fetchUserData() async {
    if (widget.localUser != null && widget.localUser!.isNotEmpty) {
      debugPrint("HomeRouter: Using passed localUser data");
      return widget.localUser;
    }

    final currentUser = widget.user;
    if (currentUser == null) {
      debugPrint("HomeRouter: No active user session -> routing to login page");
      return null;
    }

    final uid = currentUser.uid;
    final emailLower = currentUser.email?.toLowerCase() ?? '';

    // Fast resolution: Check local caches first to avoid race conditions on sign-in
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final appSettingsUser = Hive.box('app_settings').get('user_data');
        if (appSettingsUser is Map) {
          final m = Map<String, dynamic>.from(appSettingsUser);
          final r = (m['role'] ?? '').toString().toLowerCase().trim();
          final mUid = (m['uid'] ?? '').toString();
          final mEmail = (m['email'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty && r != 'unknown' && (mUid == uid || mEmail == emailLower)) {
            debugPrint("HomeRouter: Fast resolution from app_settings user_data (role=$r)");
            return m;
          }
        }
      }
      final cachedData = await offline_auth.OfflineAuthService.getCachedUserData();
      if (cachedData != null && cachedData.isNotEmpty) {
        final r = (cachedData['role'] ?? '').toString().toLowerCase().trim();
        if (r.isNotEmpty && r != 'unknown') {
          debugPrint("HomeRouter: Fast resolution from OfflineAuthService (role=$r)");
          return cachedData;
        }
      }
      final localByUid = LocalStorageService.getLocalUserByUid(uid);
      if (localByUid != null) {
        final r = (localByUid['role'] ?? '').toString().toLowerCase().trim();
        if (r.isNotEmpty && r != 'unknown') {
          debugPrint("HomeRouter: Fast resolution from LocalStorageService (role=$r)");
          return {...localByUid, 'uid': uid, 'email': currentUser.email};
        }
      }
    } catch (e) {
      debugPrint("HomeRouter: Error during fast local user check: $e");
    }

    final isOnline = await _checkConnectivity();

    if (isOnline) {
      // Record device session info for current active user on app startup
      DeviceInfoService.recordUserSession(userId: uid, email: currentUser.email);
    } else {
      debugPrint("HomeRouter: Device is offline, using local storage");
      try {
        final cachedData =
            await offline_auth.OfflineAuthService.getCachedUserData();
        if (cachedData != null) {
          debugPrint(
              "HomeRouter: Using cached user data from OfflineAuthService");
          return cachedData;
        }
      } catch (e) {
        debugPrint("HomeRouter: Error retrieving cached data: $e");
      }
      final localByUid = LocalStorageService.getLocalUserByUid(uid);
      if (localByUid != null) {
        return {...localByUid, 'uid': uid, 'email': currentUser.email};
      }
      final localByEmail =
          LocalStorageService.getLocalUserByEmail(emailLower);
      if (localByEmail != null) {
        return {...localByEmail, 'uid': uid, 'email': currentUser.email};
      }
      debugPrint("HomeRouter: No local user data found for offline mode");
      return null;
    }

    // System accounts
    final systemAccounts = {
      'admin@system.com': {
        'role': 'admin',
        'branchId': 'all',
        'username': 'admin',
        'name': 'Admin'
      },
      'chairman@system.com': {
        'role': 'chairman',
        'branchId': 'all',
        'username': 'chairman',
        'name': 'Chairman'
      },
      'ceo@system.com': {
        'role': 'ceo',
        'branchId': 'all',
        'username': 'ceo',
        'name': 'CEO'
      },
    };

    if (systemAccounts.containsKey(emailLower)) {
      final d = systemAccounts[emailLower]!;
      final data = {...d, 'uid': uid, 'email': currentUser.email};
      await _cacheUserDataLocally(data);
      return data;
    }

    // Top-level /users
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 10));

      if (userDoc.exists) {
        final data = userDoc.data()!;
        final resolvedName = resolveUserDisplayName(data, fallback: currentUser.email?.split('@').first ?? 'User');
        final userData = {
          ...data,
          'uid': uid,
          'email': currentUser.email,
          'name': resolvedName,
          'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
              ? (data['username'] ?? data['userName'])
              : resolvedName,
        };
        await _cacheUserDataLocally(userData);
        return userData;
      }
    } catch (e) {
      debugPrint("HomeRouter: Top-level /users fetch failed: $e");
    }

    // Branch /users
    try {
      // 1. Try direct path query using cached branchId if available from local DB to avoid collectionGroup
      final localUser = LocalStorageService.getLocalUserByUid(uid);
      final cachedBranchId = localUser?['branchId'] as String?;
      
      if (cachedBranchId != null && cachedBranchId.isNotEmpty && cachedBranchId != 'all' && cachedBranchId != 'unknown') {
        final docSnap = await FirebaseFirestore.instance
            .collection('branches')
            .doc(cachedBranchId)
            .collection('users')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 10));
            
        if (docSnap.exists) {
          final data = docSnap.data()!;
          final resolvedName = resolveUserDisplayName(data, fallback: currentUser.email?.split('@').first ?? 'User');
          final userData = {
            ...data,
            "branchId": cachedBranchId,
            "uid": uid,
            "email": currentUser.email,
            "name": resolvedName,
            "username": (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                ? (data['username'] ?? data['userName'])
                : resolvedName,
          };
          await _cacheUserDataLocally(userData);
          return userData;
        }
      }

      // 2. Fallback to collectionGroup by field 'uid' instead of 'FieldPath.documentId'
      // (which crashes the Firebase C++ SDK on Windows)
      final querySnap = await FirebaseFirestore.instance
          .collectionGroup('users')
          .where('uid', isEqualTo: uid)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 10));

      if (querySnap.docs.isNotEmpty) {
        final doc = querySnap.docs.first;
        final data = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        final resolvedName = resolveUserDisplayName(data, fallback: currentUser.email?.split('@').first ?? 'User');
        final userData = {
          ...data,
          "branchId": branchId,
          "uid": uid,
          "email": currentUser.email,
          "name": resolvedName,
          "username": (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
              ? (data['username'] ?? data['userName'])
              : resolvedName,
        };
        await _cacheUserDataLocally(userData);
        return userData;
      }
    } catch (e) {
      debugPrint('HomeRouter: Error fetching user from Firestore branches: $e');
    }

    // Hive fallback
    final emailPrefix = emailLower.contains('@') ? emailLower.split('@').first : emailLower;
    final localUser = LocalStorageService.findLocalUser(uid) ??
                      LocalStorageService.findLocalUser(emailLower) ??
                      LocalStorageService.findLocalUser(emailPrefix);
    if (localUser != null) {
      return {...localUser, 'uid': uid, 'email': currentUser.email};
    }

    // Final attempt from OfflineAuthService
    try {
      final cachedData = await offline_auth.OfflineAuthService.getCachedUserData();
      if (cachedData != null && cachedData.isNotEmpty) {
        return cachedData;
      }
    } catch (_) {}

    debugPrint("HomeRouter: Could not resolve user profile for UID: $uid");
    return null;
  }

  Future<void> _cacheUserDataLocally(Map<String, dynamic> userData) async {
    try {
      await LocalStorageService.saveLocalUser(userData);
    } catch (e) {
      debugPrint("Warning: Error caching user data locally: $e");
    }
  }

  Future<void> _bootstrapReceptionistData(String branchId) async {
    final isOnline = await _checkConnectivity();
    if (!isOnline) return;

    final firestoreService = FirestoreService();
    try {
      // Only do a bulk patient download if local storage is fresh/empty (< 5 patients)
      final localCount = LocalStorageService.getAllLocalPatients(branchId: branchId).length;
      if (localCount < 5) {
        final List<Patient> patients = await firestoreService
            .getAllPatientsForBranch(branchId)
            .timeout(const Duration(seconds: 3), onTimeout: () => []);
        if (patients.isNotEmpty) {
          final patientsList = patients.map((p) => p.toMap()).toList();
          await LocalStorageService.saveAllLocalPatients(patientsList);
        }
      }

      final existingSerials = LocalStorageService.getLocalEntries(branchId)
          .map((m) => m['serial'] as String?)
          .whereType<String>()
          .toSet();

      final List<Token> tokens = await firestoreService
          .getTodayTokensForBranch(branchId)
          .timeout(const Duration(seconds: 3), onTimeout: () => []);
      for (final token in tokens) {
        final map = token.toMap();
        final serial = map['serial'] as String?;
        if (serial != null && !existingSerials.contains(serial)) {
          await LocalStorageService.saveEntryLocal(branchId, serial, map);
        }
      }
    } catch (e) {
      debugPrint("Warning: Error bootstrapping receptionist data: $e");
    }
  }

  Widget _getScreenByRole(
    String role,
    String branchId,
    String uid,
    String userName,
    Map<String, dynamic> userData,
  ) {
    final r = role.toLowerCase().trim();

    // 1. HYBRID DISPENSARY ROLES (Highest precedence to prevent hybrid roles routing to manager dashboard)
    if (r == 'rec+dis' ||
        r == 'doc+rec' ||
        r == 'doc+dis' ||
        r == 'doc+rec+dis' ||
        r.contains('hybrid') ||
        (r.contains('rec') && r.contains('dis')) ||
        (r.contains('doc') && r.contains('rec')) ||
        (r.contains('doc') && r.contains('dis')) ||
        r.contains('receptionist+dispenser') ||
        r.contains('receptionist + dispenser') ||
        r.contains('doctor+receptionist') ||
        r.contains('doctor + receptionist')) {
      debugPrint("HomeRouter: Routing Hybrid Role '$role' to HybridDispensaryScreen");
      LocalStorageService.ensureDoctorBoxesOpen();
      return HybridDispensaryScreen(
        branchId: branchId,
        userId: uid,
        userName: userName,
        role: r,
      );
    }

    final normRole = r.replaceAll('_', ' ').replaceAll('-', ' ').trim();

    // 2. SPECIFIC SINGLE CLINIC & DISPENSARY ROLES
    if (normRole == 'doctor' ||
        normRole == 'receptionist' ||
        normRole == 'dispenser' ||
        normRole == 'dispensar' ||
        normRole == 'pharmacist' ||
        normRole == 'inventory') {
      LocalStorageService.ensureDoctorBoxesOpen();
    }

    switch (normRole) {
      case 'server':
        return ServerDashboardWithSync(branchId: branchId);

      case 'doctor':
        return DoctorScreen(
          branchId: branchId,
          doctorId: uid,
          doctorName: userName,
        );

      case 'receptionist':
        return ReceptionistBootstrapWrapper(
          branchId: branchId,
          receptionistId: uid,
          receptionistName: userName,
          bootstrapFunction: _bootstrapReceptionistData,
        );

      case 'dispenser':
      case 'dispensar':
      case 'pharmacist':
        return DispensarScreen(branchId: branchId);

      case 'inventory':
        return InventoryPage(branchId: branchId);

      case 'office boy':
      case 'dasterkhwaan office boy':
      case 'food token generator':
      case 'dasterkhwaan token generator':
      case 'token generator':
      case 'dasterkhwaan':
        return DasterkhwaanOfficeBoy(branchId: branchId, userName: userName, role: r);

      case 'kitchen':
      case 'dasterkhwaan kitchen':
        return DasterkhwaanKitchen(branchId: branchId, username: userName, role: r);

      case 'donations':
      case 'donation':
      case 'donations officer':
        return DonationsScreen.embedded(
          branchId:   branchId.isNotEmpty ? branchId : 'all',
          username:   userName,
          userId:     uid,
          role:       UserRole.staff,
        );

      case 'ramadan':
      case 'welfare':
      case 'ramadan welfare':
      case 'rations':
      case 'libaas':
        return RamadanWelfareScreen(branchId: branchId);

      case 'madrassa':
      case 'madrassa admin':
      case 'madrassa principal':
      case 'madrassa teacher':
        return MadrassaDashboard(
          branchId: branchId,
          username: userName,
          role: role,
          isAdmin: normRole == 'madrassa' || normRole == 'madrassa admin' || normRole == 'madrassa principal',
        );

      case 'madrassa parent':
      case 'madrassa guardian':
        return MadrassaGuardianScreen(userData: userData);

      case 'supervisor':
      case 'branch supervisor':
      case 'dispensary supervisor':
        return GlobalModularDashboard(userData: {
          ...userData,
          'role': 'supervisor',
          'branchId': branchId.isNotEmpty && branchId != 'all' ? branchId : (userData['branchId'] ?? 'all'),
          'uid': uid,
          'name': userName.isNotEmpty ? userName : 'Supervisor',
        });

      case 'school':
      case 'school admin':
      case 'school teacher':
      case 'school principal':
      case 'principal':
        return SchoolDashboard(branchId: branchId);
    }

    if (normRole.contains('madrassa') && !normRole.contains('parent') && !normRole.contains('guardian')) {
      return MadrassaDashboard(
        branchId: branchId,
        username: userName,
        role: role,
        isAdmin: normRole.contains('admin') || normRole.contains('principal'),
      );
    }

    if (normRole.contains('school')) {
      return SchoolDashboard(branchId: branchId);
    }

    // 3. DEFAULT ALL OTHER AUTHENTICATED ROLES TO GLOBAL MODULAR DASHBOARD
    debugPrint("HomeRouter: Routing role '$role' directly to GlobalModularDashboard");
    return GlobalModularDashboard(userData: {
      ...userData,
      'role': r.isNotEmpty ? r : 'admin',
      'branchId': branchId.isNotEmpty ? branchId : (userData['branchId'] ?? 'all'),
      'uid': uid,
      'name': userName.isNotEmpty ? userName : 'User',
    });
  }

  @override
  Widget build(BuildContext context) {
    // 💡 FIX: We use a multi-stage loading to prevent the "Double Login" flicker.
    // We only redirect to login if we are CERTAIN there is no user.
    return FutureBuilder<Map<String, dynamic>?>(
      future: _userDataFuture,
      builder: (context, snapshot) {
        // While we are fetching, show the loading view.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const GmwfLoadingView(
            message: 'Initializing...',
            subMessage: 'Securely verifying your credentials',
          );
        }

        // Only redirect if snapshot is done AND we definitely have no data.
        if (snapshot.hasError || !snapshot.hasData || snapshot.data == null) {
          debugPrint("HomeRouter: No user data found.");
          
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 64, color: Colors.orange),
                    const SizedBox(height: 20),
                    const Text(
                      "Profile Retrieval Failed",
                      style: TextStyle(
                        fontSize: 20, 
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "We couldn't retrieve your user profile role or branch details.\nThis could be due to a missing collectionGroup database index or lack of local cache.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pushReplacementNamed(context, '/home');
                          },
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text("Retry"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00695C),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        OutlinedButton.icon(
                          onPressed: () async {
                            try {
                              await AuthService().signOut();
                            } catch (e) {
                              debugPrint("Error signing out: $e");
                            }
                            if (context.mounted) {
                              Navigator.pushAndRemoveUntil(
                                context,
                                MaterialPageRoute(builder: (_) => const LoginPage()),
                                (route) => false,
                              );
                            }
                          },
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text("Log Out"),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // ── Auth validation ──────────────────────────────────────────────────
        // Only kick to login if there is definitely NO user (snapshot null AND
        // Firebase currentUser null AND no offline creds).
        if (!snapshot.hasData || snapshot.data == null) {
          debugPrint("HomeRouter: No user data found — redirecting to LoginPage");
          return const LoginPage();
        }

        final data = snapshot.data!;

        try {
          if (Hive.isBoxOpen('app_settings')) {
            final box = Hive.box('app_settings');
            box.put('user_data', data);
            box.put('currentUser', data);
          }
        } catch (_) {}

        // Check real-time revocation first (fires instantly when admin revokes)
        if (_accessRevokedData != null) {
          return AccessRevokedScreen(
            userData: _accessRevokedData!,
            reason: (_accessRevokedData!['status'] ?? 'revoked').toString().toLowerCase(),
          );
        }

        final userStatus = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
        final isRevoked = _isStatusRevoked(userStatus, data);

        if (isRevoked) {
          return AccessRevokedScreen(userData: data, reason: userStatus);
        }

        // Start real-time listener for revocation (runs once per session)
        final revokeUid = (data['uid'] ?? data['id'] ?? widget.user?.uid ?? '').toString();
        final revokeBranch = (data['branchId']?.toString() ?? '').trim();
        if (revokeUid.isNotEmpty && !revokeUid.startsWith('local-') && _revokeListener == null) {
          _startRevokeListener(revokeUid, revokeBranch.isNotEmpty && revokeBranch != 'all' ? revokeBranch : null);
        }

        // ── Normalize Role (handles lists, legacy synonyms, nulls) ──
        String rawRole = '';
        if (data['role'] != null && data['role'].toString().trim().isNotEmpty) {
          rawRole = data['role'].toString().toLowerCase().trim()
              .replaceAll('_', ' ')
              .replaceAll('-', ' ')
              .replaceAll(RegExp(r'\s+'), ' ');
        } else if (data['type'] != null && data['type'].toString().trim().isNotEmpty) {
          rawRole = data['type'].toString();
        } else if (data['accountType'] != null && data['accountType'].toString().trim().isNotEmpty) {
          rawRole = data['accountType'].toString();
        } else if (data['userRole'] != null && data['userRole'].toString().trim().isNotEmpty) {
          rawRole = data['userRole'].toString();
        } else if (data['designation'] != null && data['designation'].toString().trim().isNotEmpty) {
          rawRole = data['designation'].toString();
        } else if (data['position'] != null && data['position'].toString().trim().isNotEmpty) {
          rawRole = data['position'].toString();
        } else if (data['jobTitle'] != null && data['jobTitle'].toString().trim().isNotEmpty) {
          rawRole = data['jobTitle'].toString();
        } else if (data['accessRole'] != null && data['accessRole'].toString().trim().isNotEmpty) {
          rawRole = data['accessRole'].toString();
        } else {
          try {
            if (Hive.isBoxOpen('local_users')) {
              final email = data['email']?.toString();
              final uid = data['uid']?.toString();
              final uObj = (email != null ? Hive.box('local_users').get('user:${email.toLowerCase()}') : null) ??
                          (uid != null ? Hive.box('local_users').get('user:$uid') : null);
              if (uObj is Map) {
                final cachedRole = uObj['role'] ?? uObj['type'] ?? uObj['accountType'] ?? uObj['designation'];
                if (cachedRole != null) rawRole = cachedRole.toString();
              }
            }
          } catch (_) {}
        }

        rawRole = rawRole.toLowerCase().trim();
        if (rawRole == 'dispensar' || rawRole == 'pharmacist' || rawRole == 'chemist') {
          rawRole = 'dispenser';
        } else if (rawRole == 'reception' || rawRole == 'front desk') {
          rawRole = 'receptionist';
        } else if (rawRole == 'doc') {
          rawRole = 'doctor';
        } else if (rawRole == 'rec + dispenser' || rawRole == 'rec_dis') {
          rawRole = 'rec+dis';
        } else if (rawRole == 'hqmanager' || rawRole == 'hq_manager' || rawRole == 'hq') {
          rawRole = 'hq manager';
        } else if (rawRole == 'madrassa principal' || rawRole == 'madrassa admin' || rawRole == 'madrassa_principal' || rawRole == 'madrassa_admin') {
          rawRole = 'madrassa admin';
        } else if (rawRole == 'principal' || rawRole == 'school principal' || rawRole == 'school_principal') {
          rawRole = 'school principal';
        }

        final role = rawRole.isEmpty ? 'unknown' : rawRole;

        // ── Normalize Branch ID (handles null, 'null', empty strings) ──
        String rawBranch = (data['branchId']?.toString() ?? '').trim();
        if (rawBranch.isEmpty || rawBranch == 'null' || rawBranch == 'unknown') {
          rawBranch = 'all';
        }
        final branchId = rawBranch;

        // ── Normalize UID & User Name ──
        final uid = (data['uid'] ?? data['id'] ?? data['docId'] ?? widget.user?.uid ?? '').toString();
        final userName = resolveUserDisplayName(data);

        debugPrint(
            "HomeRouter -> Role: $role | Branch: $branchId | UID: $uid | Name: $userName");

        // ✅ DevOps: Tag the Sentry session for remote debugging
        try {
          Sentry.configureScope((scope) {
            scope.setTag("branch", branchId);
            scope.setTag("role", role);
            scope.setUser(SentryUser(
              id: uid,
              username: userName,
              email: data['email'],
            ));
            scope.setContexts("user_data", data);
          });
        } catch (e) {
          debugPrint("Sentry tagging error: $e");
        }

        // Hybrid Routing Logic:
        // 1. High-level "Global" users get the Modular Dashboard hub.
        // 2. Operational users (Doctor, Dispenser, etc.) go directly to their legacy screens.
        
        return ValueListenableBuilder<String?>(
          valueListenable: RoleSimulatorService.activeSimulationRole,
          builder: (simCtx, simRole, _) {
            final activeRole = (simRole != null && simRole.isNotEmpty) ? simRole : role;
            final isSimulating = simRole != null && simRole.isNotEmpty;
            final roleTheme = RoleThemeData.fromString(activeRole);

            const globalRoles = [
              'chairman',
              'admin',
              'ceo',
              'manager',
              'hq manager',
              'global',
              'global admin',
              'branch manager',
              'supervisor',
              'branch supervisor',
              'dispensary supervisor',
            ];

            const dispensaryRoles = [
              'doctor',
              'receptionist',
              'dispenser',
              'rec+dis',
              'doc+rec',
              'doc+dis',
              'doc+rec+dis',
            ];

            // ── Multi-Camp Gate Check ──
            if (dispensaryRoles.contains(activeRole) && CampSessionService.hasCampsForBranch(branchId)) {
              final assignedCamps = CampSessionService.getAssignedCamps(data);
              if (assignedCamps.length >= 2) {
                final activeCamp = CampSessionService.resolveActiveCamp(data);
                if (activeCamp == null) {
                  return CampSelectionDialog(
                    assignedCamps: assignedCamps,
                    onSelected: (selectedCampId) async {
                      await CampSessionService.setActiveCamp(selectedCampId);
                      setState(() {});
                    },
                  );
                }
              }
            }

            Widget screenWidget;
            final normActiveRole = activeRole.replaceAll('_', ' ').replaceAll('-', ' ').trim();
            if ((globalRoles.contains(normActiveRole) || normActiveRole.contains('supervisor')) && !normActiveRole.contains('madrassa') && !normActiveRole.contains('school')) {
              screenWidget = GlobalModularDashboard(userData: {
                ...data,
                'role': activeRole,
                'branchId': branchId.isNotEmpty && branchId != 'all' ? branchId : (data['branchId'] ?? 'all'),
              });
            } else {
              screenWidget = _getScreenByRole(activeRole, branchId, uid, userName, data);
            }

            final content = KeyedSubtree(
              key: ValueKey('sim_role_$activeRole'),
              child: RoleThemeScope(
                role: roleTheme,
                child: screenWidget,
              ),
            );


            if (!isSimulating) return content;

            return Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  Material(
                    color: const Color(0xFF0F172A),
                    elevation: 4,
                    child: SafeArea(
                      bottom: false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.preview_rounded, color: Colors.amberAccent, size: 18),
                            const SizedBox(width: 8),
                            const Text(
                              'SIMULATOR MODE:',
                              style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: activeRole,
                                  dropdownColor: const Color(0xFF1E293B),
                                  isDense: true,
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  items: const [
                                    DropdownMenuItem(value: 'chairman', child: Text('👑 Chairman (God Mode)')),
                                    DropdownMenuItem(value: 'ceo', child: Text('💼 CEO / HQ Executive')),
                                    DropdownMenuItem(value: 'branch manager', child: Text('🏢 Branch Manager')),
                                    DropdownMenuItem(value: 'supervisor', child: Text('👔 Supervisor')),
                                    DropdownMenuItem(value: 'doctor', child: Text('🩺 Doctor')),
                                    DropdownMenuItem(value: 'receptionist', child: Text('📋 Receptionist')),
                                    DropdownMenuItem(value: 'dispenser', child: Text('💊 Dispensary / Pharmacist')),
                                    DropdownMenuItem(value: 'donations', child: Text('🤝 Donations Officer')),
                                    DropdownMenuItem(value: 'office boy', child: Text('🍲 Dasterkhwaan (Food Tokens)')),
                                    DropdownMenuItem(value: 'kitchen', child: Text('🍳 Dasterkhwaan (Kitchen)')),
                                    DropdownMenuItem(value: 'madrassa admin', child: Text('📖 Madrassa Principal / Admin')),
                                    DropdownMenuItem(value: 'madrassa teacher', child: Text('📖 Madrassa Teacher')),
                                    DropdownMenuItem(value: 'madrassa parent', child: Text('👪 Madrassa Guardian')),
                                    DropdownMenuItem(value: 'school admin', child: Text('🏫 School Principal')),
                                    DropdownMenuItem(value: 'school teacher', child: Text('👩‍🏫 School Teacher')),
                                  ],

                                  onChanged: (val) {
                                    if (val != null) RoleSimulatorService.simulate(val);
                                  },
                                ),
                              ),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              onPressed: () => RoleSimulatorService.reset(),
                              icon: const Icon(Icons.close_rounded, size: 14),
                              label: const Text('Exit Preview', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: content),
                ],
              ),
            );
          },
        );
      },
    );

  }
}

/// Stateful wrapper to ensure receptionist synchronization only runs once
/// and doesn't loop infinitely whenever receptionist view rebuilds.
class ReceptionistBootstrapWrapper extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String receptionistName;
  final Future<void> Function(String) bootstrapFunction;

  const ReceptionistBootstrapWrapper({
    super.key,
    required this.branchId,
    required this.receptionistId,
    required this.receptionistName,
    required this.bootstrapFunction,
  });

  @override
  State<ReceptionistBootstrapWrapper> createState() => _ReceptionistBootstrapWrapperState();
}

class _ReceptionistBootstrapWrapperState extends State<ReceptionistBootstrapWrapper> {
  @override
  void initState() {
    super.initState();
    if (!RoleSimulatorService.isSimulating) {
      unawaited(
        widget.bootstrapFunction(widget.branchId).timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        ).catchError((e) {
          debugPrint('[ReceptionistBootstrap] Background bootstrap notice: $e');
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ReceptionistScreen(
      branchId: widget.branchId,
      receptionistId: widget.receptionistId,
      receptionistName: widget.receptionistName,
    );
  }
}
