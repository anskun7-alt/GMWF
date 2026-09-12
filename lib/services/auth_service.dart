// lib/services/auth_service.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../realtime/realtime_manager.dart';
import '../realtime/connection_manager.dart';
import '../realtime/lan_host_manager.dart';
import '../services/local_storage_service.dart';
import '../services/finance_local_storage.dart';
import '../services/device_info_service.dart';
import '../services/offline_auth_service.dart';
import '../services/camp_session_service.dart';
import '../services/role_simulator_service.dart';

class AuthService {
  static void Function()? onSignOutCallback;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<void> _cacheUserDataLocally(Map<String, dynamic> userData) async {
    try {
      await LocalStorageService.saveLocalUser(userData);
    } catch (e) {
      debugPrint('[AuthService] Failed to cache user data: $e');
    }
  }

  // ── Sign Up ───────────────────────────────────────────────────────────────
  Future<String> signUp({
    required String email,
    required String password,
    required String username,
    required String role,
    required String branchId,
    required String branchName,
    String? phone,
    String? identification,
    String? address,
    String? bankName,
    String? bankAccount,
    String? degree,
    double? salary,
    XFile? profileImageXFile,
    Uint8List? profileImageBytes,
    PlatformFile? identificationFile,
    PlatformFile? degreeFile,
    String? profilePictureBase64,
    String? identificationBase64,
    String? degreeBase64,
    String? studentId, 
    List<String> studentIds = const [], // NEW — default empty
    String name = '',        // NEW
    String cnic = '',        // NEW
    String? dispensaryId,    // Sub-location dispensary identifier (legacy)
    List<String> dispensaryIds = const [], // Sub-location dispensary identifiers
    List<Map<String, String>> campSchedule = const [], // Time-based camp schedule
    String? biometricPin,
    String? linkedEmployeeId,
  }) async {
    try {
      final lowerUsername = username.trim().toLowerCase();
      final lowerEmail    = email.trim().toLowerCase();

      // Duplicate check uses the lowercase version
      final query = await _firestore
          .collection('users')
          .where('usernameLower', isEqualTo: lowerUsername)
          .get();
      if (query.docs.isNotEmpty) throw Exception('Username taken');

      final currentAdminUser = _auth.currentUser;
      UserCredential cred;
      if (currentAdminUser != null) {
        FirebaseApp secondaryApp;
        try {
          secondaryApp = Firebase.app('SecondaryRegistrationApp');
        } catch (_) {
          secondaryApp = await Firebase.initializeApp(
            name: 'SecondaryRegistrationApp',
            options: Firebase.app().options,
          );
        }
        final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
        cred = await secondaryAuth.createUserWithEmailAndPassword(
          email: lowerEmail,
          password: password,
        );
        await secondaryAuth.signOut();
      } else {
        cred = await _auth.createUserWithEmailAndPassword(
          email: lowerEmail,
          password: password,
        );
      }
      final user = cred.user;
      if (user == null) throw Exception('Sign up failed: User is null');

      final uid = user.uid;

      String creatorEmail = currentAdminUser?.email ?? '';
      String creatorUid   = currentAdminUser?.uid ?? '';
      String creatorName  = '';
      String creatorRole  = '';

      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            creatorName = (uData['username'] ?? uData['name'] ?? '').toString();
            creatorRole = (uData['role'] ?? '').toString();
            if (creatorEmail.isEmpty) creatorEmail = (uData['email'] ?? '').toString();
            if (creatorUid.isEmpty) creatorUid = (uData['uid'] ?? '').toString();
          }
        }
      } catch (_) {}

      final userData = <String, dynamic>{
        'uid': uid,
        'username': username.trim(),        // original casing preserved
        'usernameLower': lowerUsername,      // for case-insensitive lookup
        'email': lowerEmail,
        'role': role.trim(),
        'branchId': branchId.trim(),
        'branchName': branchName.trim(),
        'name': name,
        'cnic': cnic,
        'studentIds': studentIds,
        'dispensaryIds': dispensaryIds.map((d) => d.trim().toLowerCase()).toList(),
        'campSchedule': campSchedule,
        if (biometricPin != null && biometricPin.trim().isNotEmpty) 'biometricPin': biometricPin.trim(),
        'createdBy': creatorEmail.isNotEmpty ? creatorEmail : (creatorName.isNotEmpty ? creatorName : 'Direct Registration'),
        'createdByName': creatorName.isNotEmpty ? creatorName : (creatorEmail.isNotEmpty ? creatorEmail : 'Admin'),
        'createdById': creatorUid,
        'createdByRole': creatorRole,
        'createdAtLocal': DateTime.now().toIso8601String(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (phone?.isNotEmpty ?? false)          userData['phone']          = phone!.trim();
      if (identification?.isNotEmpty ?? false) userData['identification']  = identification!.trim();
      if (address?.isNotEmpty ?? false)        userData['address']         = address!.trim();
      if (bankName?.isNotEmpty ?? false)       userData['bankName']        = bankName!.trim();
      if (bankAccount?.isNotEmpty ?? false)    userData['bankAccount']     = bankAccount!.trim();
      if (degree?.isNotEmpty ?? false)         userData['degree']          = degree!.trim();
      if (salary != null)                      userData['baseSalary']      = salary;
      if (studentId?.isNotEmpty ?? false)      userData['studentId']       = studentId!.trim();
      if (dispensaryId?.isNotEmpty ?? false)   userData['dispensaryId']    = dispensaryId!.trim().toLowerCase();

      // Base64 strings (offline & storage-free) with storage upload fallback
      if (profilePictureBase64 != null && profilePictureBase64.isNotEmpty) {
        userData['profilePictureUrl'] = profilePictureBase64;
      } else if (profileImageXFile != null || profileImageBytes != null) {
        final url = await _uploadFile(
            folder: 'profile', uid: uid,
            xFile: profileImageXFile, webBytes: profileImageBytes);
        if (url != null) userData['profilePictureUrl'] = url;
      }

      if (identificationBase64 != null && identificationBase64.isNotEmpty) {
        userData['identificationUrl'] = identificationBase64;
      } else if (identificationFile != null) {
        final url = await _uploadFile(
            folder: 'identification', uid: uid, platformFile: identificationFile);
        if (url != null) userData['identificationUrl'] = url;
      }

      if (degreeBase64 != null && degreeBase64.isNotEmpty) {
        userData['degreeCertificateUrl'] = degreeBase64;
      } else if (role.toLowerCase() == 'doctor' && degreeFile != null) {
        final url = await _uploadFile(
            folder: 'degree', uid: uid, platformFile: degreeFile);
        if (url != null) userData['degreeCertificateUrl'] = url;
      }

      await _firestore.collection('users').doc(uid).set(userData);

      const globalRoles = ['ceo', 'chairman', 'admin', 'hq manager'];
      if (!globalRoles.contains(role.toLowerCase())) {
        await _firestore
            .collection('branches')
            .doc(branchId)
            .collection('users')
            .doc(uid)
            .set(userData);
      }

      if (currentAdminUser == null) {
        await _cacheUserDataLocally(userData);
      } else {
        try {
          final box = Hive.isBoxOpen('local_users') ? Hive.box('local_users') : await Hive.openBox('local_users');
          await box.put('user:${userData['email']}', userData);
          if (userData['uid'] != null) {
            await box.put('user:${userData['uid']}', userData);
          }
        } catch (_) {}
      }

      await OfflineAuthService.saveCredentials(
        usernameOrEmail: lowerEmail,
        password: password,
        userData: userData,
        setAsLastLoggedIn: currentAdminUser == null,
      );

      // Explicit Employee Link:
      if (linkedEmployeeId != null && linkedEmployeeId.isNotEmpty) {
        await FinanceLocalStorage.linkUserToEmployee(
          userId: uid,
          employeeId: linkedEmployeeId,
        );
      }
      return uid;
    } catch (e) {
      debugPrint('[AuthService] signUp failed: $e');
      rethrow;
    }
  }

  // ── Sign In ───────────────────────────────────────────────────────────────
  /// Signs the user in with Firebase.
  ///
  /// Key fix: if the server IP is missing or the realtime initialisation fails
  /// we log a warning but do NOT throw — the user still gets their session and
  /// the app continues.  The realtime connection will be re-attempted later
  /// by ConnectionManager's auto-discovery.
  Future<User?> signIn({
    required String input,
    required String password,
    String? serverIp,
  }) async {
    try {
      String loginEmail = input.trim().toLowerCase();

      if (!loginEmail.contains('@')) {
        final found = await _findUserByUsername(input);
        if (found == null) throw Exception('User not found');
        loginEmail = found['email'] as String;
      }

      debugPrint('[AuthService] signIn → $loginEmail');
      final cred = await _auth.signInWithEmailAndPassword(
        email: loginEmail,
        password: password,
      );
      final user = cred.user;
      if (user == null) return null;

      final emailLower = loginEmail;

      // Special system accounts
      final systemAccounts = {
        'chairman@system.com': {'role': 'chairman', 'username': 'chairman', 'branchId': 'all'},
        'ceo@system.com':      {'role': 'ceo',      'username': 'ceo',      'branchId': 'all'},
        'server@gmd.com':      {'role': 'server',   'username': 'server',   'branchId': 'sialkot'},
      };
      if (systemAccounts.containsKey(emailLower)) {
        final d = systemAccounts[emailLower]!;
        await _cacheUserDataLocally({...d, 'uid': user.uid, 'email': user.email});
        return user;
      }

      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) throw Exception('User data not found in Firestore');

      final data  = userDoc.data()!;
      final role  = (data['role'] as String?)?.toLowerCase() ?? 'unknown';
      final branchId = data['branchId'] as String? ?? '';

      await _cacheUserDataLocally({...data, 'uid': user.uid, 'email': user.email});

      // ── Role-specific setup ────────────────────────────────────────────────
      // IMPORTANT: none of these throw — failures are logged and swallowed so
      // the caller always gets a valid User back.
      if (role == 'server') {
        try {
          debugPrint('[AuthService] Dedicated Branch Server detected for role=server');
          // ZkTeco biometric listener is started on the server machine
          // (ZkTecoNetworkService.startServer() imported where needed)
        } catch (e) {
          debugPrint('[AuthService] Server engine start notice: $e');
        }
      } else {
        // All client roles (receptionist, doctor, dispenser, supervisor, finance, donations, teacher, madrassa, school, etc.)
        // connect silently to the central Branch Server via ConnectionManager & RealtimeManager.
        try {
          final username = user.displayName ?? user.email?.split('@').first ?? role;
          // Executive roles (chairman, CEO) may have branchId='all'. Resolve to
          // the first known real branch for server discovery.
          String connBranchId = branchId;
          if (connBranchId.isEmpty || connBranchId == 'all' || connBranchId == 'global') {
            try {
              if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
                final box = Hive.box(LocalStorageService.branchesBox);
                for (final val in box.values) {
                  if (val is Map) {
                    final id = (val['id'] ?? '').toString().trim().toLowerCase();
                    final isOff = val['isOffboarded'] == true || val['status'] == 'offboarded';
                    if (id.isNotEmpty && id != 'all' && id != 'global' && !isOff) {
                      connBranchId = id;
                      break;
                    }
                  }
                }
              }
            } catch (_) {}
          }
          ConnectionManager().start(
            role: role,
            branchId: connBranchId,
            username: username,
          );
        } catch (e) {
          debugPrint('[AuthService] ConnectionManager.start failed (non-fatal): $e');
        }
      }

      // Record device & browser session info
      try {
        await DeviceInfoService.recordUserSession(userId: user.uid, email: user.email);
      } catch (e) {
        debugPrint('[AuthService] Non-fatal device info logging failed: $e');
      }

      return user;
    } catch (e) {
      debugPrint('[AuthService] signIn error: $e');
      rethrow;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────
  /// Each step is independently try/caught so a failure in one cannot block
  /// the others.
  Future<void> signOut() async {
    debugPrint('[AuthService] Starting sign out');

    try {
      onSignOutCallback?.call();
    } catch (_) {}

    try {
      RoleSimulatorService.reset();
    } catch (_) {}

    // 1. Instantly clear user session from Hive to prevent auto-login loops
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.delete('user_data');
        await box.delete('currentUser');
        await box.delete('user');
        await box.delete('role');
        await box.delete('auth_token');
        await box.delete('server_authenticated');
        await box.flush();
      }
    } catch (e) {
      debugPrint('[AuthService] Hive app_settings clear error: $e');
    }

    try {
      await OfflineAuthService.clearCachedUserData();
    } catch (e) {
      debugPrint('[AuthService] OfflineAuthService clear error: $e');
    }

    try {
      await CampSessionService.clearActiveCamp();
    } catch (_) {}

    // 2. Sign out from Firebase Auth
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('[AuthService] Firebase signOut error: $e');
    }

    // 3. Fire-and-forget background cleanup tasks
    try {
      final user = _auth.currentUser;
      if (user != null) {
        final uid = user.uid;
        _firestore.collection('users').doc(uid).set({
          'isOnline': false,
          'lastLogoutAt': FieldValue.serverTimestamp(),
          'lastOnlineAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).catchError((_) {});

        DeviceInfoService.markUserOffline(userId: uid).catchError((_) {});
      }
    } catch (_) {}

    try { LanHostManager.stopHost().catchError((_) {}); } catch (_) {}
    try { RealtimeManager().dispose().catchError((_) {}); } catch (_) {}

    debugPrint('[AuthService] Sign out complete');
  }

  User? getCurrentUser() => _auth.currentUser;

  Future<Map<String, dynamic>?> getUserByUid(String uid) async {
    try {
      // 1. Check root collection (Legacy/Admin)
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) return doc.data();

      // 2. Check all branches via collection group
      final querySnap = await _firestore
          .collectionGroup('users')
          .where('uid', isEqualTo: uid)
          .limit(1)
          .get();
      if (querySnap.docs.isNotEmpty) {
        final doc = querySnap.docs.first;
        final data = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        return {
          ...data,
          'branchId': branchId,
        };
      }
    } catch (e) {
      debugPrint('[AuthService] getUserByUid failed: $e');
    }
    return null;
  }

  // ── Username → email lookup ───────────────────────────────────────────────
  Future<Map<String, dynamic>?> _findUserByUsername(String username) async {
    final lower = username.trim().toLowerCase();

    try {
      final q = await _firestore
          .collection('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) {
        final d = q.docs.first;
        return {'email': d['email'], 'username': d['username'],
                'role': d['role'], 'branchId': d['branchId'] ?? 'all', 'uid': d.id};
      }
    } catch (_) {}

    try {
      final querySnap = await _firestore
          .collectionGroup('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get();
      if (querySnap.docs.isNotEmpty) {
        final doc = querySnap.docs.first;
        final d = doc.data();
        final pathParts = doc.reference.path.split('/');
        final branchId = pathParts.length >= 2 ? pathParts[1] : 'unknown';
        return {
          'email': d['email'],
          'username': d['username'],
          'role': d['role'],
          'branchId': branchId,
          'uid': doc.id
        };
      }
    } catch (e) {
      debugPrint('[AuthService] _findUserByUsername branch search failed via collectionGroup: $e');
    }
    return null;
  }

  // ── File upload helper ────────────────────────────────────────────────────
  Future<String?> _uploadFile({
    required String folder,
    required String uid,
    XFile? xFile,
    Uint8List? webBytes,
    PlatformFile? platformFile,
  }) async {
    try {
      Uint8List? bytes;
      String? fileName;

      if (xFile != null) {
        bytes    = webBytes ?? await xFile.readAsBytes();
        fileName = '${DateTime.now().millisecondsSinceEpoch}_${xFile.name}';
      } else if (platformFile != null) {
        bytes = kIsWeb
            ? platformFile.bytes
            : (platformFile.path != null ? await File(platformFile.path!).readAsBytes() : null);
        fileName = '${DateTime.now().millisecondsSinceEpoch}_${platformFile.name}';
      }

      if (bytes == null || fileName == null) return null;

      final ref      = _storage.ref().child('users/$uid/$folder/$fileName');
      final snapshot = kIsWeb
          ? await ref.putData(bytes)
          : await ref.putFile(File(xFile?.path ?? platformFile!.path!));
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      debugPrint('[AuthService] _uploadFile failed: $e');
      return null;
    }
  }
}
