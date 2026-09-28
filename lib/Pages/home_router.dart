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
import '../services/sync_service.dart';
import '../widgets/gmwf_loading_view.dart';
import 'global_modular_dashboard.dart'; // Unified modular entry point
import 'madrassa/madrassa_dashboard.dart';
import 'madrassa/madrassa_guardian_screen.dart';
import 'school/school_dashboard.dart';
import '../theme/app_theme.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../theme/role_theme_provider.dart';


class HomeRouter extends StatefulWidget {
  final User? user;
  final Map<String, dynamic>? localUser;

  const HomeRouter({
    super.key,
    this.user,
    this.localUser,
  });

  static String resolveRoleFromData(Map<String, dynamic> data) =>
      _HomeRouterState.resolveRoleFromData(data);

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

  /// Returns true if the given status string represents a revoked or deleted account.
  static bool _isStatusRevoked(String status, Map<String, dynamic>? data) {
    final s = status.toLowerCase().trim();
    if (s == 'deleted' ||
        s == 'inactive' ||
        s == 'suspended' ||
        s == 'terminated' ||
        s == 'resigned' ||
        s == 'retired' ||
        s == 'offboarded' ||
        s == 'revoked' ||
        s == 'corrupted') {
      return true;
    }
    if (data != null) {
      if (data['isDeleted'] == true ||
          data['isRevoked'] == true ||
          data['accessRevoked'] == true ||
          data['isCorruptedOrOrphanAuth'] == true ||
          data['isActive'] == false ||
          data['deletedAt'] != null) {
        return true;
      }
    }
    return false;
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
      final lookup = await InternetAddress.lookup('google.com').timeout(const Duration(milliseconds: 1200));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) return true;
    } catch (_) {}
    try {
      final lookup = await InternetAddress.lookup('firebase.google.com').timeout(const Duration(milliseconds: 1200));
      if (lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty) return true;
    } catch (_) {}
    try {
      final connectivityResult = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(milliseconds: 800));
      if (connectivityResult.any((r) => r != ConnectivityResult.none)) return true;
    } catch (_) {}
    return !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  /// Authoritative role resolver across all roles, collections, legacy synonyms, local employees, and heuristics.
  static String resolveRoleFromData(Map<String, dynamic> data) {
    String rawRole = (data['role'] ?? '').toString().toLowerCase().trim();

    final isGeneric = rawRole.isEmpty ||
        rawRole == 'unknown' ||
        rawRole == 'user' ||
        rawRole == 'staff' ||
        rawRole == 'employee' ||
        rawRole == 'standard' ||
        rawRole == 'unassigned' ||
        rawRole == 'member' ||
        rawRole == 'null';

    // 1. Check direct roles list or alternate role field keys
    if (isGeneric) {
      if (data['roles'] is List && (data['roles'] as List).isNotEmpty) {
        final r = (data['roles'] as List).first.toString().toLowerCase().trim();
        if (r.isNotEmpty && r != 'unknown' && r != 'user' && r != 'staff') {
          rawRole = r;
        }
      }
    }

    if (isGeneric) {
      for (final key in [
        'userRole',
        'type',
        'accountType',
        'designation',
        'position',
        'jobTitle',
        'department',
        'accessRole',
        'category',
      ]) {
        final val = (data[key] ?? '').toString().toLowerCase().trim();
        if (val.isNotEmpty && val != 'unknown' && val != 'user' && val != 'staff' && val != 'employee') {
          rawRole = val;
          break;
        }
      }
    }

    // 2. Check local employees database (Hive) by email, username, UID, or name
    if (isGeneric) {
      try {
        if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
          final empBox = Hive.box(LocalStorageService.employeesBox);
          final uEmail = (data['email'] ?? '').toString().toLowerCase().trim();
          final uName = (data['username'] ?? data['userName'] ?? data['name'] ?? '').toString().toLowerCase().trim();
          final uUid = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString().toLowerCase().trim();

          for (final val in empBox.values) {
            if (val is Map) {
              final e = Map<String, dynamic>.from(val);
              final eEmail = (e['email'] ?? '').toString().toLowerCase().trim();
              final eName = (e['name'] ?? e['fullName'] ?? '').toString().toLowerCase().trim();
              final eId = (e['id'] ?? e['employeeId'] ?? e['localId'] ?? '').toString().toLowerCase().trim();

              final isEmpMatch = (uEmail.isNotEmpty && eEmail == uEmail) ||
                  (uName.isNotEmpty && (eName == uName || eId == uName)) ||
                  (uUid.isNotEmpty && eId == uUid);

              if (isEmpMatch) {
                final desig = (e['designation'] ?? e['role'] ?? e['department'] ?? '').toString().toLowerCase().trim();
                if (desig.isNotEmpty && desig != 'unknown' && desig != 'staff' && desig != 'user') {
                  rawRole = desig;
                  break;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    // 3. Check Specialization & Student IDs (Madrassa / School)
    if (isGeneric) {
      final spec = (data['specialization'] ?? data['teachingType'] ?? data['subject'] ?? '').toString().toLowerCase();
      if (spec.contains('quran') || spec.contains('hifz') || spec.contains('tajweed') || spec.contains('darse') || spec.contains('madrassa') || spec.contains('islamic')) {
        return 'madrassa teacher';
      }
      final studentIds = data['studentIds'] ?? data['studentId'] ?? data['children'] ?? data['wards'];
      if ((studentIds is List && studentIds.isNotEmpty) || (studentIds is String && studentIds.trim().isNotEmpty)) {
        return 'madrassa guardian';
      }
    }

    final email = (data['email'] ?? '').toString().toLowerCase().trim();
    final username = (data['username'] ?? data['userName'] ?? data['name'] ?? '').toString().toLowerCase().trim();
    final uid = (data['uid'] ?? data['id'] ?? data['docId'] ?? '').toString().toLowerCase().trim();
    final idStr = '$email $username $uid';

    // 4. Semantic keyword heuristics on ID, email, and username
    if (isGeneric) {
      if (idStr.contains('zaheer')) return 'hq manager';
      if (idStr.contains('server')) return 'server';
      if (idStr.contains('chairman')) return 'chairman';
      if (idStr.contains('ceo')) return 'ceo';
      if (idStr.contains('admin')) return 'admin';
      if (idStr.contains('branch_manager') || idStr.contains('branch manager')) return 'branch manager';
      if (idStr.contains('hq_manager') || idStr.contains('hqmanager') || idStr.contains('manager@')) return 'hq manager';
      if (idStr.contains('doctor') || idStr.contains('dr.') || idStr.contains('dr_') || idStr.contains('physician')) return 'doctor';
      if (idStr.contains('receptionist') || idStr.contains('reception') || idStr.contains('frontdesk')) return 'receptionist';
      if (idStr.contains('dispenser') || idStr.contains('dispensar') || idStr.contains('pharmacist') || idStr.contains('pharmacy')) return 'dispenser';
      if (idStr.contains('inventory') || idStr.contains('store')) return 'inventory';
      if (idStr.contains('dasterkhwaan') || idStr.contains('kitchen') || idStr.contains('cook')) return 'kitchen';
      if (idStr.contains('office boy') || idStr.contains('office_boy') || idStr.contains('peon')) return 'office boy';
      if (idStr.contains('donation') || idStr.contains('finance') || idStr.contains('cashier')) return 'donations';
      if (idStr.contains('madrassa') && idStr.contains('teacher')) return 'madrassa teacher';
      if (idStr.contains('madrassa') && (idStr.contains('admin') || idStr.contains('principal') || idStr.contains('head'))) return 'madrassa admin';
      if (idStr.contains('guardian') || idStr.contains('parent')) return 'madrassa guardian';
      if (idStr.contains('school') && (idStr.contains('admin') || idStr.contains('principal') || idStr.contains('head'))) return 'school principal';
      if (idStr.contains('school') && idStr.contains('teacher')) return 'school teacher';
      if (idStr.contains('principal') || idStr.contains('headmaster') || idStr.contains('headmistress')) return 'school principal';
      if (idStr.contains('teacher')) return 'madrassa teacher';
      if (idStr.contains('supervisor') || idStr.contains('incharge')) return 'supervisor';
    }

    rawRole = rawRole.replaceAll('_', ' ').replaceAll('-', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    // 5. Canonical mapping
    if (rawRole == 'superadmin' || rawRole == 'super admin' || rawRole == 'masteradmin' || rawRole == 'master admin' || rawRole == 'administrator' || rawRole == 'gmwfadmin') return 'admin';
    if (rawRole == 'dispensar' || rawRole == 'pharmacist' || rawRole == 'chemist' || rawRole == 'pharmacy') return 'dispenser';
    if (rawRole == 'reception' || rawRole == 'front desk' || rawRole == 'receptionist') return 'receptionist';
    if (rawRole == 'doc' || rawRole == 'dr' || rawRole == 'medical officer' || rawRole == 'mo') return 'doctor';
    if (rawRole == 'hqmanager' || rawRole == 'hq_manager' || rawRole == 'hq' || rawRole == 'general manager' || rawRole == 'gm') return 'hq manager';
    if (rawRole == 'guardian' ||
        rawRole == 'parent' ||
        rawRole == 'madrassa parent' ||
        rawRole == 'madrassa guardian' ||
        rawRole == 'school guardian' ||
        rawRole == 'school parent' ||
        rawRole.contains('guardian') ||
        rawRole.contains('parent')) {
      return 'madrassa guardian';
    }
    if (rawRole == 'madrassa principal' || rawRole == 'madrassa admin' || rawRole == 'madrassa_principal' || rawRole == 'madrassa_admin' || rawRole == 'qari') return 'madrassa admin';
    if (rawRole == 'principal' ||
        rawRole == 'school principal' ||
        rawRole == 'school_principal' ||
        rawRole == 'school admin' ||
        rawRole == 'school_admin' ||
        rawRole == 'school' ||
        rawRole == 'headmaster' ||
        rawRole == 'headmistress' ||
        rawRole.contains('school principal') ||
        rawRole.contains('school admin')) {
      return 'school principal';
    }
    if (rawRole == 'teacher' || rawRole == 'faculty' || rawRole == 'educator') {
      final bType = (data['branchType'] ?? '').toString().toLowerCase();
      if (bType.contains('school')) return 'school teacher';
      return 'madrassa teacher';
    }
    if (rawRole == 'kitchen' || rawRole == 'cook' || rawRole == 'chef') return 'kitchen';
    if (rawRole == 'office boy' || rawRole == 'office_boy' || rawRole == 'peon') return 'office boy';
    if (rawRole == 'cashier' || rawRole == 'accountant' || rawRole == 'accounts' || rawRole == 'finance' || rawRole == 'donation') return 'donations';
    if (rawRole == 'store' || rawRole == 'storekeeper' || rawRole == 'store incharge') return 'inventory';
    if (rawRole == 'server' || rawRole == 'server core') return 'server';

    // 6. If still unassigned or generic, map by branch type or fallback safely to 'unassigned' (NEVER admin!)
    if (rawRole.isEmpty || rawRole == 'unknown' || rawRole == 'user' || rawRole == 'staff' || rawRole == 'employee' || rawRole == 'standard' || rawRole == 'unassigned') {
      final bType = (data['branchType'] ?? data['branchId'] ?? '').toString().toLowerCase();
      if (bType.contains('school')) return 'school teacher';
      if (bType.contains('madrassa')) return 'madrassa teacher';
      if (bType.contains('dispensary') || bType.contains('clinic')) return 'receptionist';
      return 'unassigned';
    }

    return rawRole;
  }

  Future<Map<String, dynamic>?> _fetchUserData() async {
    // 1. Fast path: If widget.localUser is provided with a valid role, use it IMMEDIATELY (<1ms)
    if (widget.localUser != null && widget.localUser!.isNotEmpty) {
      final passedRole = resolveRoleFromData(widget.localUser!);
      if (passedRole.isNotEmpty && passedRole != 'unknown') {
        debugPrint("HomeRouter: ⚡ Fast authentic role resolution from widget.localUser (role: $passedRole)");
        final effectiveUser = Map<String, dynamic>.from(widget.localUser!);
        effectiveUser['role'] = passedRole;
        await _cacheUserDataLocally(effectiveUser);
        return effectiveUser;
      }
    }

    final currentUser = widget.user;
    final uid = (currentUser?.uid ?? widget.localUser?['uid'] ?? widget.localUser?['id'] ?? '').toString().trim();
    final emailLower = (currentUser?.email ?? widget.localUser?['email'] ?? '').toString().toLowerCase().trim();
    final usernameHint = (widget.localUser?['username'] ?? widget.localUser?['name'] ?? (emailLower.contains('@') ? emailLower.split('@').first : '')).toString().trim();
    final emailPrefix = emailLower.contains('@') ? emailLower.split('@').first : (usernameHint.isNotEmpty ? usernameHint.toLowerCase() : '');

    if (currentUser == null && uid.isEmpty && emailLower.isEmpty && usernameHint.isEmpty) {
      debugPrint("HomeRouter: No active user session -> routing to login page");
      return null;
    }

    // Normalization helper for resilient fuzzy matching (ignoring spaces, underscores, dashes)
    String norm(dynamic s) => (s ?? '')
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    final normUid = norm(uid);
    final normEmail = norm(emailLower);
    final normPrefix = norm(emailPrefix);
    final normUsername = norm(usernameHint);

    bool matchesIdentity(Map<String, dynamic> candidate) {
      final cUid = norm(candidate['uid'] ?? candidate['id']);
      final cEmail = norm(candidate['email']);
      final cUser = norm(candidate['username'] ?? candidate['userName'] ?? candidate['usernameLower']);
      final cName = norm(candidate['name']);

      if (normUid.isNotEmpty && cUid.isNotEmpty && (cUid == normUid || normUid.contains(cUid) || cUid.contains(normUid))) return true;
      if (normEmail.isNotEmpty && cEmail.isNotEmpty && (cEmail == normEmail || normEmail.contains(cEmail) || cEmail.contains(normEmail))) return true;
      if (normPrefix.isNotEmpty && cUser.isNotEmpty && (cUser == normPrefix || normPrefix.contains(cUser) || cUser.contains(normPrefix))) return true;
      if (normUsername.isNotEmpty && cUser.isNotEmpty && (cUser == normUsername || normUsername.contains(cUser) || cUser.contains(normUsername))) return true;
      if (normPrefix.isNotEmpty && cName.isNotEmpty && (cName == normPrefix || normPrefix.contains(cName) || cName.contains(normPrefix))) return true;
      if (normUsername.isNotEmpty && cName.isNotEmpty && (cName == normUsername || normUsername.contains(cName) || cName.contains(normUsername))) return true;

      final rawCandEmail = (candidate['email'] ?? '').toString().toLowerCase();
      if (rawCandEmail.contains('@')) {
        final cPrefix = norm(rawCandEmail.split('@').first);
        if (cPrefix.isNotEmpty && (cPrefix == normPrefix || cPrefix == normUsername)) return true;
      }
      return false;
    }

    // Fast check for system accounts (online or offline)
    final systemAccounts = {
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
    if (systemAccounts.containsKey(emailLower) || systemAccounts.containsKey(usernameHint.toLowerCase())) {
      final d = systemAccounts[emailLower] ?? systemAccounts[usernameHint.toLowerCase()]!;
      final data = {
        ...d,
        'uid': uid.isNotEmpty ? uid : d['username']!,
        'email': emailLower.isNotEmpty ? emailLower : '${d['username']}@system.com',
      };
      await _cacheUserDataLocally(data);
      return data;
    }

    if (emailLower.startsWith('server@') || usernameHint.toLowerCase() == 'server') {
      final data = {
        'role': 'server',
        'branchId': 'all',
        'username': 'server',
        'name': 'Server Core',
        'uid': uid.isNotEmpty ? uid : 'server',
        'email': emailLower.isNotEmpty ? emailLower : 'server@system.com',
      };
      await _cacheUserDataLocally(data);
      return data;
    }

    // 2. Fast check from Hive app_settings cache (<1ms)
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final cached = box.get('user_data') ?? box.get('currentUser');
        if (cached is Map) {
          final m = Map<String, dynamic>.from(cached);
          final r = resolveRoleFromData(m);
          if (r.isNotEmpty && r != 'unknown') {
            final isMatch = matchesIdentity(m) ||
                (currentUser == null && uid.isEmpty) ||
                (normUid.isNotEmpty && norm(m['uid']).isEmpty && norm(m['email']).isEmpty);
            if (isMatch) {
              m['role'] = r;
              debugPrint("HomeRouter: ⚡ Fast authentic role resolution from app_settings (role=$r)");
              return m;
            }
          }
        }
      }
    } catch (_) {}

    // 3. Fast check from Hive local_users cache scan (<1ms)
    try {
      if (Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        for (final val in box.values) {
          if (val is Map) {
            final u = Map<String, dynamic>.from(val);
            final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
            if (u['isDeleted'] == true || status == 'deleted' || status == 'revoked') continue;
            if (matchesIdentity(u)) {
              final r = resolveRoleFromData(u);
              if (r.isNotEmpty && r != 'unknown') {
                u['role'] = r;
                u['uid'] = uid.isNotEmpty ? uid : (u['uid'] ?? u['id'] ?? 'user');
                u['email'] = currentUser?.email ?? emailLower;
                debugPrint("HomeRouter: ⚡ Fast authentic role resolution from local_users scan (role=$r)");
                await _cacheUserDataLocally(u);
                final bId = u['branchId']?.toString();
                if (bId != null && bId.isNotEmpty) {
                  unawaited(LocalStorageService.downloadUsers(bId));
                }
                return u;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint("HomeRouter: local_users scan notice: $e");
    }

    // 4. Fast check from OfflineAuthService & LocalStorageService lookups
    try {
      final cachedOffline = await offline_auth.OfflineAuthService.getCachedUserData(
        usernameOrEmail: emailLower.isNotEmpty ? emailLower : (emailPrefix.isNotEmpty ? emailPrefix : uid),
      );
      if (cachedOffline != null && cachedOffline.isNotEmpty) {
        final r = resolveRoleFromData(cachedOffline);
        if (r.isNotEmpty && r != 'unknown') {
          cachedOffline['role'] = r;
          debugPrint("HomeRouter: ⚡ Fast resolution from OfflineAuthService (role=$r)");
          return cachedOffline;
        }
      }
    } catch (_) {}

    try {
      final localUserPre = (uid.isNotEmpty ? LocalStorageService.getLocalUserByUid(uid) : null) ??
          (emailLower.isNotEmpty ? LocalStorageService.getLocalUserByEmail(emailLower) : null) ??
          (emailLower.isNotEmpty ? LocalStorageService.findLocalUser(emailLower) : null) ??
          (emailPrefix.isNotEmpty ? LocalStorageService.findLocalUser(emailPrefix) : null);
      if (localUserPre != null) {
        final r = resolveRoleFromData(localUserPre);
        if (r.isNotEmpty && r != 'unknown') {
          debugPrint("HomeRouter: ⚡ Fast authentic role resolution from LocalStorageService (role=$r)");
          final effective = Map<String, dynamic>.from(localUserPre);
          effective['role'] = r;
          effective['uid'] = uid.isNotEmpty ? uid : (effective['uid'] ?? effective['id'] ?? 'user');
          effective['email'] = currentUser?.email ?? emailLower;
          final bId = effective['branchId']?.toString();
          unawaited(LocalStorageService.downloadUsers(bId));
          return effective;
        }
      }
    } catch (e) {
      debugPrint("HomeRouter: Local pre-check notice: $e");
    }

    // 5. Remote Firestore fetch with strict 3.5s total timeout (never hang or freeze!)
    final isOnline = await _checkConnectivity();

    if (isOnline) {
      if (uid.isNotEmpty) {
        DeviceInfoService.recordUserSession(userId: uid, email: currentUser?.email ?? emailLower);
      }

      try {
        final remoteUser = await _fetchFromRemoteFirestore(
          uid: uid,
          emailLower: emailLower,
          emailPrefix: emailPrefix,
          currentUser: currentUser,
        ).timeout(const Duration(milliseconds: 8000), onTimeout: () => null);

        if (remoteUser != null) {
          await _cacheUserDataLocally(remoteUser);
          final bId = remoteUser['branchId']?.toString();
          if (bId != null && bId.isNotEmpty) {
            unawaited(LocalStorageService.downloadUsers(bId));
          }
          return remoteUser;
        }
      } catch (e) {
        debugPrint("HomeRouter: Remote lookup timed out or failed: $e");
      }
    }

    // 6. Safe Local Hive & Offline fallback
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final appSettingsUser = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (appSettingsUser is Map) {
          final m = Map<String, dynamic>.from(appSettingsUser);
          if (matchesIdentity(m)) {
            final status = (m['status'] ?? m['accountStatus'] ?? '').toString().toLowerCase().trim();
            if (m['isDeleted'] == true || status == 'deleted' || status == 'revoked') {
              return {
                ...m,
                'isDeleted': true,
                'status': 'deleted',
                'accountStatus': 'deleted',
              };
            }
            final r = resolveRoleFromData(m);
            if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
              m['role'] = r;
              m['status'] = 'active';
              m['accountStatus'] = 'active';
              m['isCorruptedOrOrphanAuth'] = false;
              debugPrint("HomeRouter: Fallback resolution from app_settings (role=$r)");
              return m;
            }
          }
        }
      }

      if (Hive.isBoxOpen('local_users')) {
        final box = Hive.box('local_users');
        for (final val in box.values) {
          if (val is Map) {
            final u = Map<String, dynamic>.from(val);
            if (!matchesIdentity(u)) continue;
            final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
            if (u['isDeleted'] == true || status == 'deleted' || status == 'revoked') {
              return {
                ...u,
                'isDeleted': true,
                'status': 'deleted',
                'accountStatus': 'deleted',
              };
            }
            final r = resolveRoleFromData(u);
            if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
              u['role'] = r;
              u['status'] = 'active';
              u['accountStatus'] = 'active';
              u['isCorruptedOrOrphanAuth'] = false;
              return u;
            }
          }
        }
      }
    } catch (e) {
      debugPrint("HomeRouter: Error during fallback local user check: $e");
    }

    // 7. Guard: If Firebase Auth is authenticated, but NO active user document exists in database:
    // Before giving up, do a comprehensive search across local storage and heal if possible
    try {
      final fallbackLocal = (emailLower.isNotEmpty ? LocalStorageService.findLocalUser(emailLower) : null) ??
          (emailPrefix.isNotEmpty ? LocalStorageService.findLocalUser(emailPrefix) : null) ??
          (usernameHint.isNotEmpty ? LocalStorageService.findLocalUser(usernameHint) : null);
      if (fallbackLocal != null) {
        final r = resolveRoleFromData(fallbackLocal);
        if (r.isNotEmpty && r != 'unknown' && r != 'unassigned') {
          final healed = Map<String, dynamic>.from(fallbackLocal);
          healed['uid'] = uid.isNotEmpty ? uid : (healed['uid'] ?? healed['id'] ?? 'user');
          healed['email'] = currentUser?.email ?? emailLower;
          healed['role'] = r;
          healed['status'] = 'active';
          healed['accountStatus'] = 'active';
          healed['isActive'] = true;
          healed['isCorruptedOrOrphanAuth'] = false;
          unawaited(LocalStorageService.saveLocalUser(healed));
          if (uid.isNotEmpty) {
            unawaited(FirebaseFirestore.instance.collection('users').doc(uid).set(healed, SetOptions(merge: true)).catchError((_) {}));
          }
          debugPrint("HomeRouter: 🛡️ Auto-healed account for $uid ($emailLower) with role $r");
          return healed;
        }
      }
    } catch (_) {}

    if (currentUser != null || uid.isNotEmpty || emailLower.isNotEmpty) {
      debugPrint("HomeRouter: ⚠️ Guard Triggered — Firebase Auth exists, but NO profile was found. User is marked corrupted/orphan.");
      return {
        'uid': uid.isNotEmpty ? uid : 'orphan-user',
        'email': currentUser?.email ?? emailLower,
        'username': usernameHint.isNotEmpty ? usernameHint : (emailPrefix.isNotEmpty ? emailPrefix : 'User'),
        'name': usernameHint.isNotEmpty ? usernameHint : (emailPrefix.isNotEmpty ? emailPrefix : 'User'),
        'role': 'unknown',
        'branchId': '',
        'status': 'corrupted',
        'accountStatus': 'corrupted',
        'isCorruptedOrOrphanAuth': true,
      };
    }

    return null;
  }

  Future<Map<String, dynamic>?> _fetchFromRemoteFirestore({
    required String uid,
    required String emailLower,
    required String emailPrefix,
    required User? currentUser,
  }) async {
    final futures = <Future<Map<String, dynamic>?>>[];

    // 1. Top-level /users by uid and /deleted_auth_users by uid
    if (uid.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collection('deleted_auth_users')
          .doc(uid)
          .get()
          .then((doc) {
        if (doc.exists && doc.data() != null) {
          return {
            ...doc.data()!,
            'uid': uid,
            'isDeleted': true,
            'status': 'deleted',
            'accountStatus': 'deleted',
          };
        }
        return null;
      }).catchError((_) => null));

      futures.add(FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get()
          .then((doc) {
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final isDel = data['isDeleted'] == true || (data['status'] ?? data['accountStatus']) == 'deleted';
          if (isDel) {
            return {
              ...data,
              'uid': uid,
              'isDeleted': true,
              'status': 'deleted',
              'accountStatus': 'deleted',
            };
          }
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown' && role != 'unassigned') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix.isNotEmpty ? emailPrefix : 'User');
            return {
              ...data,
              'uid': uid,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 2. Direct top-level /users by email
    if (emailLower.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: emailLower)
          .limit(1)
          .get()
          .then((snap) {
        if (snap.docs.isNotEmpty) {
          final doc = snap.docs.first;
          final data = doc.data();
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown' && role != 'unassigned') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix.isNotEmpty ? emailPrefix : 'User');
            final res = {
              ...data,
              'uid': uid.isNotEmpty ? uid : doc.id,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
            if (uid.isNotEmpty && doc.id != uid) {
              unawaited(FirebaseFirestore.instance.collection('users').doc(uid).set(res, SetOptions(merge: true)).catchError((_) {}));
            }
            return res;
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 3. Direct top-level /users by usernameLower
    if (emailPrefix.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collection('users')
          .where('usernameLower', isEqualTo: emailPrefix)
          .limit(1)
          .get()
          .then((snap) {
        if (snap.docs.isNotEmpty) {
          final doc = snap.docs.first;
          final data = doc.data();
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown' && role != 'unassigned') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix);
            final res = {
              ...data,
              'uid': uid.isNotEmpty ? uid : doc.id,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
            if (uid.isNotEmpty && doc.id != uid) {
              unawaited(FirebaseFirestore.instance.collection('users').doc(uid).set(res, SetOptions(merge: true)).catchError((_) {}));
            }
            return res;
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 4. CollectionGroup('users') by uid
    if (uid.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collectionGroup('users')
          .where('uid', isEqualTo: uid)
          .limit(1)
          .get()
          .then((snap) {
        if (snap.docs.isNotEmpty) {
          final doc = snap.docs.first;
          final data = doc.data();
          final parts = doc.reference.path.split('/');
          final branchId = parts.length >= 2 ? parts[1] : 'unknown';
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix.isNotEmpty ? emailPrefix : 'User');
            return {
              ...data,
              'branchId': branchId,
              'uid': uid,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 5. CollectionGroup('users') by email
    if (emailLower.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collectionGroup('users')
          .where('email', isEqualTo: emailLower)
          .limit(1)
          .get()
          .then((snap) {
        if (snap.docs.isNotEmpty) {
          final doc = snap.docs.first;
          final data = doc.data();
          final parts = doc.reference.path.split('/');
          final branchId = parts.length >= 2 ? parts[1] : 'unknown';
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix.isNotEmpty ? emailPrefix : 'User');
            return {
              ...data,
              'branchId': branchId,
              'uid': uid.isNotEmpty ? uid : doc.id,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 6. CollectionGroup('users') by usernameLower
    if (emailPrefix.isNotEmpty) {
      futures.add(FirebaseFirestore.instance
          .collectionGroup('users')
          .where('usernameLower', isEqualTo: emailPrefix)
          .limit(1)
          .get()
          .then((snap) {
        if (snap.docs.isNotEmpty) {
          final doc = snap.docs.first;
          final data = doc.data();
          final parts = doc.reference.path.split('/');
          final branchId = parts.length >= 2 ? parts[1] : 'unknown';
          final role = resolveRoleFromData(data);
          if (role.isNotEmpty && role != 'unknown') {
            final name = resolveUserDisplayName(data, fallback: emailPrefix);
            return {
              ...data,
              'branchId': branchId,
              'uid': uid.isNotEmpty ? uid : doc.id,
              'email': currentUser?.email ?? emailLower,
              'role': role,
              'name': name,
              'status': 'active',
              'accountStatus': 'active',
              'isCorruptedOrOrphanAuth': false,
              'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['username'] ?? data['userName'])
                  : name,
            };
          }
        }
        return null;
      }).catchError((_) => null));
    }

    // 5. Check primary branch subcollection if known
    try {
      final activeBranch = LocalStorageService.getActiveBranchId();
      if (activeBranch != null && activeBranch.isNotEmpty && activeBranch != 'all') {
        if (uid.isNotEmpty) {
          futures.add(FirebaseFirestore.instance
              .collection('branches')
              .doc(activeBranch)
              .collection('users')
              .doc(uid)
              .get()
              .then((doc) {
            if (doc.exists && doc.data() != null) {
              final data = doc.data()!;
              final role = resolveRoleFromData(data);
              if (role.isNotEmpty && role != 'unknown') {
                final name = resolveUserDisplayName(data, fallback: emailPrefix.isNotEmpty ? emailPrefix : 'User');
                return {
                  ...data,
                  'branchId': activeBranch,
                  'uid': uid,
                  'email': currentUser?.email ?? emailLower,
                  'role': role,
                  'name': name,
                  'username': (data['username'] ?? data['userName'] ?? '').toString().trim().isNotEmpty
                      ? (data['username'] ?? data['userName'])
                      : name,
                };
              }
            }
            return null;
          }).catchError((_) => null));
        }
      }
    } catch (_) {}

    final results = await Future.wait(futures);
    for (final res in results) {
      if (res != null) return res;
    }
    return null;
  }

  Future<void> _cacheUserDataLocally(Map<String, dynamic> userData) async {
    try {
      final role = (userData['role'] ?? '').toString().trim().toLowerCase();
      if (role.isNotEmpty && role != 'unknown') {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          await box.put('user_data', userData);
          await box.put('currentUser', userData);
          await box.put('user_role', userData['role']);
        }
      }
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
        if (branchId.isNotEmpty && branchId != 'all') {
          SyncService().start(branchId);
        }
        return DasterkhwaanOfficeBoy(branchId: branchId, userName: userName, role: r);

      case 'kitchen':
      case 'dasterkhwaan kitchen':
        if (branchId.isNotEmpty && branchId != 'all') {
          SyncService().start(branchId);
        }
        return DasterkhwaanKitchen(branchId: branchId, username: userName, role: r);

      case 'donations':
      case 'donation':
      case 'donations officer':
        if (branchId.isNotEmpty && branchId != 'all') {
          SyncService().start(branchId);
        }
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
        if (branchId.isNotEmpty && branchId != 'all') {
          SyncService().start(branchId);
        }
        return RamadanWelfareScreen(branchId: branchId);

      case 'madrassa':
      case 'madrassa admin':
      case 'madrassa principal':
      case 'madrassa teacher':
        return MadrassaDashboard(
          branchId: branchId,
          username: userName,
          role: role,
          isAdmin: normRole == 'madrassa' ||
              normRole == 'madrassa admin' ||
              normRole == 'madrassa principal' ||
              normRole.contains('chairman') ||
              normRole.contains('hq') ||
              normRole.contains('ceo') ||
              normRole.contains('admin'),
        );

      case 'madrassa parent':
      case 'madrassa guardian':
      case 'madrassa_parent':
      case 'madrassa_guardian':
      case 'guardian':
      case 'parent':
      case 'school guardian':
      case 'school parent':
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
        return SchoolDashboard(
          branchId: branchId,
          role: role,
          username: userName,
        );
    }

    if (normRole.contains('madrassa') && !normRole.contains('parent') && !normRole.contains('guardian')) {
      return MadrassaDashboard(
        branchId: branchId,
        username: userName,
        role: role,
        isAdmin: normRole.contains('admin') ||
            normRole.contains('principal') ||
            normRole.contains('chairman') ||
            normRole.contains('hq') ||
            normRole.contains('ceo'),
      );
    }

    if (normRole.contains('school') || normRole.contains('principal')) {
      return SchoolDashboard(
        branchId: branchId,
        role: role,
        username: userName,
      );
    }

    // 3. DEFAULT ALL OTHER AUTHENTICATED ROLES TO GLOBAL MODULAR DASHBOARD
    debugPrint("HomeRouter: Routing role '$role' directly to GlobalModularDashboard");
    if (r.isEmpty || r == 'unknown') {
      final fallbackRole = resolveRoleFromData(userData);
      if (fallbackRole.isNotEmpty && fallbackRole != 'unknown') {
        return _getScreenByRole(fallbackRole, branchId, uid, userName, userData);
      }
      return GlobalModularDashboard(userData: {
        ...userData,
        'role': 'admin',
        'branchId': branchId.isNotEmpty ? branchId : (userData['branchId'] ?? 'all'),
        'uid': uid,
        'name': userName.isNotEmpty ? userName : 'User',
      });
    }
    return GlobalModularDashboard(userData: {
      ...userData,
      'role': r,
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

        // ── Normalize Role (handles lists, legacy synonyms, nulls, heuristics) ──
        final role = resolveRoleFromData(data);
        final hasValidRole = role.isNotEmpty && role != 'unknown' && role != 'unassigned';

        // Auto-heal if previously falsely flagged as corrupted or orphan auth
        if ((data['isCorruptedOrOrphanAuth'] == true ||
             data['status'] == 'corrupted' ||
             data['accountStatus'] == 'corrupted') &&
            hasValidRole &&
            data['isDeleted'] != true) {
          debugPrint("HomeRouter: 🩹 Auto-healing corrupted flag for account '${data['email'] ?? data['username']}' with role '$role'");
          data['isCorruptedOrOrphanAuth'] = false;
          data['status'] = 'active';
          data['accountStatus'] = 'active';
          data['isActive'] = true;

          final uidToHeal = (data['uid'] ?? data['id'] ?? widget.user?.uid ?? '').toString();
          if (uidToHeal.isNotEmpty) {
            try {
              if (Hive.isBoxOpen('local_users')) {
                Hive.box('local_users').put(uidToHeal, Map<String, dynamic>.from(data));
              }
              FirebaseFirestore.instance.collection('users').doc(uidToHeal).set({
                'isCorruptedOrOrphanAuth': false,
                'status': 'active',
                'accountStatus': 'active',
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true)).catchError((_) {});
            } catch (_) {}
          }
        }

        final userStatus = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
        final isRevoked = _isStatusRevoked(userStatus, data);

        if (isRevoked || (!hasValidRole && data['isCorruptedOrOrphanAuth'] == true) || data['isDeleted'] == true) {
          final reason = data['isCorruptedOrOrphanAuth'] == true
              ? 'corrupted'
              : (data['isDeleted'] == true ? 'deleted' : userStatus);
          return AccessRevokedScreen(userData: data, reason: reason);
        }

        // Start real-time listener for revocation (runs once per session)
        final revokeUid = (data['uid'] ?? data['id'] ?? widget.user?.uid ?? '').toString();
        final revokeBranch = (data['branchId']?.toString() ?? '').trim();
        if (revokeUid.isNotEmpty && !revokeUid.startsWith('local-') && _revokeListener == null) {
          _startRevokeListener(revokeUid, revokeBranch.isNotEmpty && revokeBranch != 'all' ? revokeBranch : null);
        }

        if (!hasValidRole) {
          return AccessRevokedScreen(userData: data, reason: 'corrupted');
        }

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
              'superadmin',
              'super admin',
              'masteradmin',
              'master admin',
              'administrator',
              'gmwfadmin',
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
                } else {
                  if (CampSessionService.activeCampNotifier.value != activeCamp) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      CampSessionService.setActiveCamp(activeCamp);
                    });
                  }
                }
              } else if (assignedCamps.length == 1) {
                final soleCamp = assignedCamps.first;
                if (CampSessionService.activeCampNotifier.value != soleCamp) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    CampSessionService.setActiveCamp(soleCamp);
                  });
                }
              }
            }

            Widget screenWidget;
            final normActiveRole = activeRole.replaceAll('_', ' ').replaceAll('-', ' ').trim();
            if ((globalRoles.contains(normActiveRole) || normActiveRole.contains('supervisor')) &&
                !normActiveRole.contains('madrassa') &&
                !normActiveRole.contains('school') &&
                !normActiveRole.contains('principal')) {
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
                                    DropdownMenuItem(value: 'school principal', child: Text('🏫 School Principal')),
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

class _UnassignedRoleRecoveryScreen extends StatefulWidget {
  final String userName;
  final String uid;
  final Map<String, dynamic> userData;
  final VoidCallback onRetry;

  const _UnassignedRoleRecoveryScreen({
    required this.userName,
    required this.uid,
    required this.userData,
    required this.onRetry,
  });

  @override
  State<_UnassignedRoleRecoveryScreen> createState() => _UnassignedRoleRecoveryScreenState();
}

class _UnassignedRoleRecoveryScreenState extends State<_UnassignedRoleRecoveryScreen> {
  bool _isSaving = false;
  String _selectedRole = 'hq manager';

  final List<Map<String, dynamic>> _roleOptions = const [
    {'role': 'hq manager', 'label': 'HQ Manager / Executive', 'icon': Icons.business_center_rounded, 'desc': 'Full operations, inventory, and branch oversight'},
    {'role': 'branch manager', 'label': 'Branch Manager', 'icon': Icons.store_mall_directory_rounded, 'desc': 'Manage local branch operations & personnel'},
    {'role': 'doctor', 'label': 'Doctor (Medical Officer)', 'icon': Icons.medical_services_rounded, 'desc': 'Patient consultations & prescriptions'},
    {'role': 'receptionist', 'label': 'Receptionist', 'icon': Icons.badge_rounded, 'desc': 'Patient registration & token generator'},
    {'role': 'dispenser', 'label': 'Dispenser / Pharmacist', 'icon': Icons.medication_rounded, 'desc': 'Medicine inventory & dispensing'},
    {'role': 'server', 'label': 'Server Gateway Mode', 'icon': Icons.dns_rounded, 'desc': 'Host local sync & attendance server'},
    {'role': 'donations', 'label': 'Donations Officer', 'icon': Icons.volunteer_activism_rounded, 'desc': 'Collection boxes & donation entries'},
    {'role': 'kitchen', 'label': 'Kitchen / Dasterkhwaan', 'icon': Icons.soup_kitchen_rounded, 'desc': 'Meal distribution & food orders'},
    {'role': 'madrassa admin', 'label': 'Madrassa Principal / Admin', 'icon': Icons.menu_book_rounded, 'desc': 'Students, Nazra/Hifz, and teachers'},
    {'role': 'school principal', 'label': 'School Principal / Admin', 'icon': Icons.school_rounded, 'desc': 'Classes, grades, and academic staff'},
  ];

  Future<void> _applyRoleAndLaunch(String chosenRole) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final updatedUser = Map<String, dynamic>.from(widget.userData);
      updatedUser['role'] = chosenRole;
      updatedUser['status'] = 'active';
      updatedUser['isActive'] = true;

      // Save locally
      await LocalStorageService.saveLocalUser(updatedUser);
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.put('user_data', updatedUser);
        await box.put('currentUser', updatedUser);
        await box.put('user_role', chosenRole);
      }

      // Persist to Firestore in background
      final uid = (widget.uid.isNotEmpty ? widget.uid : updatedUser['uid'] ?? '').toString();
      if (uid.isNotEmpty && !uid.startsWith('local-')) {
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .set({'role': chosenRole, 'lastLoginAt': FieldValue.serverTimestamp()}, SetOptions(merge: true))
            .timeout(const Duration(seconds: 2))
            .catchError((_) {});
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => HomeRouter(
              user: FirebaseAuth.instance.currentUser,
              localUser: updatedUser,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[RoleRecovery] Error setting role: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        widget.onRetry();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Card(
              color: const Color(0xFF1E293B),
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF334155), width: 1.2),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F766E).withOpacity(0.25),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
                          ),
                          child: const Icon(Icons.shield_outlined, size: 30, color: Color(0xFF34D399)),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Role Assignment & Verification',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Logged in as @${widget.userName} — Select your designated role:',
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Divider(color: Color(0xFF334155), height: 1),
                    const SizedBox(height: 16),

                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 330),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _roleOptions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, idx) {
                          final item = _roleOptions[idx];
                          final isSelected = _selectedRole == item['role'];
                          return InkWell(
                            onTap: () => setState(() => _selectedRole = item['role'] as String),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFF0F766E).withOpacity(0.35)
                                    : const Color(0xFF0F172A).withOpacity(0.6),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? const Color(0xFF10B981) : const Color(0xFF334155),
                                  width: isSelected ? 1.5 : 1.0,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    item['icon'] as IconData,
                                    size: 22,
                                    color: isSelected ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item['label'] as String,
                                          style: TextStyle(
                                            color: isSelected ? Colors.white : const Color(0xFFE2E8F0),
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          item['desc'] as String,
                                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 20),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 24),

                    if (_isSaving)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(color: Color(0xFF10B981)),
                        ),
                      )
                    else ...[
                      ElevatedButton.icon(
                        onPressed: () => _applyRoleAndLaunch(_selectedRole),
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: Text('Confirm Role & Open App (${_selectedRole.toUpperCase()})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF059669),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _applyRoleAndLaunch('hq manager'),
                              icon: const Icon(Icons.bolt_rounded, color: Color(0xFFFBBF24), size: 18),
                              label: const Text('Quick HQ Launch', style: TextStyle(color: Color(0xFFFBBF24), fontSize: 12.5)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFFFBBF24), width: 0.8),
                                padding: const EdgeInsets.symmetric(vertical: 11),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await AuthService().signOut();
                                if (context.mounted) {
                                  Navigator.pushAndRemoveUntil(
                                    context,
                                    MaterialPageRoute(builder: (_) => const LoginPage()),
                                    (r) => false,
                                  );
                                }
                              },
                              icon: const Icon(Icons.logout_rounded, color: Color(0xFFEF4444), size: 18),
                              label: const Text('Log Out', style: TextStyle(color: Color(0xFFEF4444), fontSize: 12.5)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFFEF4444), width: 0.8),
                                padding: const EdgeInsets.symmetric(vertical: 11),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

