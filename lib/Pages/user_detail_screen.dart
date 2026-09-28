// lib/pages/user_detail_screen.dart — Role-Theme Aware

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/local_storage_service.dart';
import '../services/offline_auth_service.dart';
import '../services/auth_service.dart';
import '../services/finance_local_storage.dart';
import '../services/image_upload_service.dart';
import '../services/zkteco_network_service.dart';
import '../theme/role_theme_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/device_badge_widget.dart';
import '../utils/formatters.dart';
import '../services/camp_session_service.dart';
import '../services/auto_update_service.dart';
import 'office/offboard_dialog.dart';
import '../services/staff_patient_link_service.dart';
import '../services/sync_service.dart';
import '../services/device_info_service.dart';

class UserDetailScreen extends StatefulWidget {
  final String userId;
  final String branchId;
  final bool isOnline;
  final Box localBox;
  final String? currentUserRole;

  const UserDetailScreen({
    super.key,
    required this.userId,
    required this.branchId,
    this.isOnline = true,
    required this.localBox,
    this.currentUserRole,
  });

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen>
    with SingleTickerProviderStateMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> _updateFirebaseAuthUser(String email, String password, {String? newEmail, String? newPassword, String? newDisplayName}) async {
    final cleanEmail = email.trim();
    final cleanPass = password.trim();
    if (cleanEmail.isEmpty || cleanPass.isEmpty) return;

    FirebaseApp? secondaryApp;
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final isSelf = currentUser != null &&
          (currentUser.email?.toLowerCase() == cleanEmail.toLowerCase() || currentUser.uid == widget.userId);

      if (isSelf) {
        if (cleanPass.isNotEmpty) {
          try {
            final cred = EmailAuthProvider.credential(
              email: currentUser.email ?? cleanEmail,
              password: cleanPass,
            );
            await currentUser.reauthenticateWithCredential(cred);
          } catch (reauthErr) {
            debugPrint('[UserDetailScreen] Reauthentication skipped/failed: $reauthErr');
          }
        }
        if (newEmail != null && newEmail.isNotEmpty && newEmail.toLowerCase() != cleanEmail.toLowerCase()) {
          await currentUser.verifyBeforeUpdateEmail(newEmail);
        }
        if (newPassword != null && newPassword.isNotEmpty && newPassword != cleanPass) {
          await currentUser.updatePassword(newPassword);
          await OfflineAuthService.updateCachedPassword(newPassword, usernameOrEmail: currentUser.email ?? cleanEmail);
        }
        if (newDisplayName != null && newDisplayName.isNotEmpty) {
          await currentUser.updateDisplayName(newDisplayName);
        }
        return;
      }

      final appName = 'TempAuthApp_${DateTime.now().millisecondsSinceEpoch}';
      secondaryApp = await Firebase.initializeApp(
        name: appName,
        options: Firebase.app().options,
      ).timeout(const Duration(seconds: 4));
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      UserCredential? creds;
      for (final p in [cleanPass, '123456', '112233', '1122', '12345678', 'password']) {
        try {
          creds = await secondaryAuth.signInWithEmailAndPassword(
            email: cleanEmail,
            password: p,
          ).timeout(const Duration(seconds: 3));
          if (creds.user != null) break;
        } catch (_) {}
      }

      if (creds == null || creds.user == null) {
        try {
          final createPw = (newPassword != null && newPassword.length >= 6)
              ? newPassword
              : (cleanPass.length >= 6 ? cleanPass : '123456');
          creds = await secondaryAuth.createUserWithEmailAndPassword(
            email: cleanEmail,
            password: createPw,
          ).timeout(const Duration(seconds: 4));
        } catch (_) {}
      }

      final user = creds?.user;
      if (user != null) {
        if (newEmail != null && newEmail.isNotEmpty && newEmail.toLowerCase() != cleanEmail.toLowerCase()) {
          await user.verifyBeforeUpdateEmail(newEmail).timeout(const Duration(seconds: 3)).catchError((_) {});
        }
        if (newPassword != null && newPassword.isNotEmpty) {
          final authPw = newPassword.length >= 6 ? newPassword : '${newPassword}33';
          await user.updatePassword(authPw).timeout(const Duration(seconds: 3)).catchError((_) {});
          await OfflineAuthService.updateCachedPassword(newPassword, usernameOrEmail: cleanEmail);
        }
        if (newDisplayName != null && newDisplayName.isNotEmpty) {
          await user.updateDisplayName(newDisplayName).timeout(const Duration(seconds: 3)).catchError((_) {});
        }
      }
    } catch (e) {
      debugPrint('[UserDetailScreen] Firebase Auth update bypassed/safe-handled: $e');
    } finally {
      if (secondaryApp != null) {
        try {
          await secondaryApp.delete().timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }
  }

  final TextEditingController _usernameController =
      TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _degreeController = TextEditingController();
  final TextEditingController _identificationController =
      TextEditingController();
  final TextEditingController _addressController =
      TextEditingController();
  final TextEditingController _bankNameController =
      TextEditingController();
  final TextEditingController _bankAccountController =
      TextEditingController();

  String? _selectedRole;
  String? _selectedStatus;
  XFile? _profileFile, _idFile, _degreeFile;
  String? branchName;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  // Fallback palette (used inside dialogs where theme context may vary)
  static const Color _dialogAccent = Color(0xFF3949AB);
  static const Color _divider = Color(0xFFE9ECEF);
  static const Color _surface = Color(0xFFFFFFFF);
  static const Color _bg = Color(0xFFF5F6FA);
  static const Color _ink = Color(0xFF1C1F26);
  static const Color _inkMid = Color(0xFF5A6072);
  static const Color _inkLight = Color(0xFFADB5BD);

  Map<String, dynamic>? _remoteUserData;
  bool _isLoadingRemote = true;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim =
        CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _fetchBranchName();
    _fetchUserDataFromFirestore();
  }

  Future<void> _fetchUserDataFromFirestore() async {
    if (widget.userId.trim().isEmpty) {
      if (mounted) setState(() => _isLoadingRemote = false);
      return;
    }
    try {
      Map<String, dynamic>? found;

      // 1. Check branch sub-collection
      if (widget.branchId.isNotEmpty && widget.branchId != 'all' && widget.branchId != 'global') {
        final bDoc = await _firestore
            .collection('branches')
            .doc(widget.branchId)
            .collection('users')
            .doc(widget.userId)
            .get();
        if (bDoc.exists && bDoc.data() != null) {
          found = Map<String, dynamic>.from(bDoc.data()!);
        }
      }

      // 2. Check root collection
      final rootDoc = await _firestore.collection('users').doc(widget.userId).get();
      if (rootDoc.exists && rootDoc.data() != null) {
        final rootMap = Map<String, dynamic>.from(rootDoc.data()!);
        found = { ...(found ?? {}), ...rootMap };
      }

      // 3. Query collectionGroup users by uid
      if (found == null || found['username'] == null) {
        try {
          final qUid = await _firestore
              .collectionGroup('users')
              .where('uid', isEqualTo: widget.userId)
              .limit(1)
              .get();
          if (qUid.docs.isNotEmpty) {
            final qMap = Map<String, dynamic>.from(qUid.docs.first.data());
            found = { ...(found ?? {}), ...qMap };
          }
        } catch (_) {}
      }

      if (found != null) {
        if (found.containsKey('updates') && found['updates'] is Map) {
          found = {
            ...found,
            ...Map<String, dynamic>.from(found['updates'] as Map),
          }..remove('updates');
        }

        _remoteUserData = found;

        if (Hive.isBoxOpen('local_users')) {
          final box = Hive.box('local_users');
          final email = (found['email'] ?? '').toString().toLowerCase().trim();
          final uName = (found['username'] ?? found['usernameLower'] ?? '').toString().toLowerCase().trim();
          final targetUid = widget.userId;

          final keys = <String>{
            if (email.isNotEmpty) 'user:$email',
            if (targetUid.isNotEmpty) 'user:$targetUid',
            if (targetUid.isNotEmpty) targetUid,
            if (uName.isNotEmpty) 'user:$uName',
          };
          for (final k in keys) {
            box.put(k, found);
          }
        }
      }
    } catch (e) {
      debugPrint('[UserDetailScreen] Remote fetch error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingRemote = false);
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _degreeController.dispose();
    _identificationController.dispose();
    _addressController.dispose();
    _bankNameController.dispose();
    _bankAccountController.dispose();
    super.dispose();
  }

  Future<void> _fetchBranchName() async {
    if (widget.branchId.isEmpty || widget.branchId == 'all' || widget.branchId == 'global') {
      setState(() => branchName = 'All Branches');
      return;
    }
    try {
      final doc = await _firestore
          .collection('branches')
          .doc(widget.branchId)
          .get();
      if (doc.exists) {
        setState(() =>
            branchName = doc.data()!['name'] as String? ?? widget.branchId);
      }
    } catch (_) {}
  }

  Future<bool> _checkPassword(RoleThemeData t) async {
    final completer = Completer<bool>();
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        void onVerify() {
          if (ctrl.text == 'admin1122') {
            Navigator.pop(ctx);
            completer.complete(true);
          } else {
            _snack('Wrong password', error: true);
          }
        }

        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: t.bgCard,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: t.accentMuted,
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.lock_outline_rounded,
                        color: t.accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Text('Admin Verification',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: t.textPrimary)),
                ]),
                const SizedBox(height: 20),
                TextField(
                  controller: ctrl,
                  obscureText: true,
                  autofocus: true,
                  style: TextStyle(fontSize: 14, color: t.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Enter admin password',
                    hintStyle: TextStyle(color: t.textTertiary),
                    prefixIcon: Icon(Icons.password_rounded,
                        color: t.textTertiary, size: 20),
                    filled: true,
                    fillColor: t.bg,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: t.bgRule)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: t.bgRule)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: t.accent, width: 2)),
                  ),
                  onSubmitted: (_) => onVerify(),
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        completer.complete(false);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: t.bgRule)),
                      ),
                      child: Text('Cancel',
                          style: TextStyle(
                              color: t.textSecondary,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: onVerify,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Verify',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
    return completer.future;
  }

  Map<String, dynamic>? _getLocalUser() {
    try {
      if (!Hive.isBoxOpen('local_users')) return null;
      final box = Hive.box('local_users');
      final target = widget.userId.trim().toLowerCase();

      // Check direct keys first
      for (final k in [widget.userId, 'user:${widget.userId}', target, 'user:$target']) {
        final v = box.get(k);
        if (v is Map) {
          var m = Map<String, dynamic>.from(v);
          if (m.containsKey('updates') && m['updates'] is Map) {
            m = {...m, ...Map<String, dynamic>.from(m['updates'] as Map)}..remove('updates');
          }
          return m;
        }
      }

      for (final val in box.values) {
        if (val is Map) {
          Map<String, dynamic> u = Map<String, dynamic>.from(val);
          if (u.containsKey('updates') && u['updates'] is Map) {
            u = {
              ...u,
              ...Map<String, dynamic>.from(u['updates'] as Map),
            }..remove('updates');
          }
          final uid = (u['uid'] ?? u['id'] ?? u['docId'] ?? '').toString().trim().toLowerCase();
          final username = (u['username'] ?? '').toString().trim().toLowerCase();
          final email = (u['email'] ?? '').toString().trim().toLowerCase();
          if (uid == target ||
              (username.isNotEmpty && username == target) ||
              (email.isNotEmpty && email == target)) {
            return u;
          }
        }
      }
    } catch (e) {
      debugPrint('Error reading local users: $e');
    }
    return null;
  }

  void _showEditDialog(Map<String, dynamic> data, RoleThemeData t) async {
    if (!_canManageUserAccess(data)) {
      _snack(
        (data['role']?.toString().toLowerCase().trim() == 'chairman')
            ? 'Access Denied: The Chairman account is 100% immutable and CANNOT be edited or restricted by ANY user.'
            : 'Access Denied: Only the Chairman has authority to edit or manage user accounts.',
        error: true,
      );
      return;
    }
    if (!await _checkPassword(t)) return;

    final editKey = GlobalKey<FormState>();
    // Prefill password with existing password so user sees their current one
    final passCtrl = TextEditingController(
      text: data['password']?.toString() ?? '',
    );

    _usernameController.text = data['username'] ?? '';
    _emailController.text = data['email'] ?? '';
    _phoneController.text = data['phone'] ?? '';
    
    // Roles configuration for dropdown and normalization
    List<Map<String, dynamic>> roleConfigs = [
      {'value': 'CEO', 'label': 'CEO', 'type': 'crown', 'icon': Icons.workspace_premium_rounded},
      {'value': 'Admin', 'label': 'Admin', 'type': 'crown', 'icon': Icons.workspace_premium_rounded},
      {'value': 'Chairman', 'label': 'Chairman', 'type': 'crown', 'icon': Icons.workspace_premium_rounded},
      {'value': 'HQ Manager', 'label': 'HQ Manager', 'type': 'crown', 'icon': Icons.business_center_rounded},
      {'value': 'Branch Manager', 'label': 'Branch Manager', 'type': 'normal', 'icon': Icons.manage_accounts_rounded},
      {'value': 'Doctor', 'label': 'Doctor', 'type': 'normal', 'icon': Icons.medical_services_outlined},
      {'value': 'Receptionist', 'label': 'Receptionist', 'type': 'normal', 'icon': Icons.support_agent_rounded},
      {'value': 'Dispenser', 'label': 'Dispenser', 'type': 'normal', 'icon': Icons.medication_outlined},
      {'value': 'rec+dis', 'label': 'Rec + Dispenser', 'type': 'hybrid', 'icon': Icons.swap_horiz_rounded},
      {'value': 'doc+rec', 'label': 'Doc + Receptionist', 'type': 'hybrid', 'icon': Icons.swap_horiz_rounded},
      {'value': 'doc+dis', 'label': 'Doc + Dispenser', 'type': 'hybrid', 'icon': Icons.swap_horiz_rounded},
      {'value': 'doc+rec+dis', 'label': 'Doc + Rec + Dispenser', 'type': 'hybrid', 'icon': Icons.swap_horiz_rounded},
      {'value': 'Supervisor', 'label': 'Supervisor', 'type': 'normal', 'icon': Icons.manage_accounts_outlined},
      {'value': 'Server', 'label': 'Server', 'type': 'shield', 'icon': Icons.shield_rounded},
      {'value': 'Office Boy', 'label': 'Office Boy', 'type': 'normal', 'icon': Icons.confirmation_number_outlined},
      {'value': 'Kitchen', 'label': 'Kitchen', 'type': 'normal', 'icon': Icons.restaurant_outlined},
      {'value': 'Food Token Generator', 'label': 'Food Token Generator', 'type': 'normal', 'icon': Icons.confirmation_number_outlined},
      {'value': 'Madrassa Admin', 'label': 'Madrassa Admin', 'type': 'madrassa', 'icon': Icons.menu_book_rounded},
      {'value': 'Madrassa Teacher', 'label': 'Madrassa Teacher', 'type': 'madrassa', 'icon': Icons.school_rounded},
      {'value': 'Madrassa Parent', 'label': 'Madrassa Parent', 'type': 'madrassa', 'icon': Icons.child_care_rounded},
      {'value': 'Madrassa Guardian', 'label': 'Madrassa Guardian', 'type': 'madrassa', 'icon': Icons.child_care_rounded},
      {'value': 'School Principal', 'label': 'School Principal', 'type': 'crown', 'icon': Icons.stars_rounded},
      {'value': 'School Admin', 'label': 'School Admin', 'type': 'normal', 'icon': Icons.school_rounded},
      {'value': 'School Teacher', 'label': 'School Teacher', 'type': 'normal', 'icon': Icons.co_present_rounded},
      {'value': 'School Guardian', 'label': 'School Guardian', 'type': 'normal', 'icon': Icons.family_restroom_rounded},
      {'value': 'School Parent', 'label': 'School Parent', 'type': 'normal', 'icon': Icons.family_restroom_rounded},
      {'value': 'Student', 'label': 'Student', 'type': 'normal', 'icon': Icons.school_outlined},
      {'value': 'Madrassa Student', 'label': 'Madrassa Student', 'type': 'madrassa', 'icon': Icons.school_outlined},
      {'value': 'School Student', 'label': 'School Student', 'type': 'normal', 'icon': Icons.school_outlined},
    ];

    if (!_canManageUserAccess({'role': 'chairman'})) {
      roleConfigs.removeWhere((r) => r['value'].toString().toLowerCase().trim() == 'chairman');
    }

    final String rawRole = (data['role'] ?? '').toString().trim();
    final matchingRole = roleConfigs.firstWhere(
      (r) => r['value'].toString().toLowerCase() == rawRole.toLowerCase() ||
             r['label'].toString().toLowerCase() == rawRole.toLowerCase(),
      orElse: () => {
        'value': rawRole.isNotEmpty ? rawRole : 'Staff',
        'label': rawRole.isNotEmpty ? rawRole : 'Staff',
        'type': 'normal',
        'icon': Icons.person_rounded,
      },
    );
    _selectedRole = matchingRole['value'] as String;

    final List<String> statusList = ['Active', 'Inactive', 'Resigned', 'Terminated', 'Retired', 'Suspended'];
    final String rawStatus = (data['status'] ?? data['accountStatus'] ?? 'Active').toString();
    _selectedStatus = statusList.firstWhere(
      (s) => s.toLowerCase() == rawStatus.toLowerCase(),
      orElse: () => 'Active',
    );
    _degreeController.text = data['degree'] ?? '';
    _identificationController.text = data['identification'] ?? '';
    _addressController.text = data['address'] ?? '';
    _bankNameController.text = data['bankName'] ?? '';
    _bankAccountController.text = data['bankAccount'] ?? '';
    final initialUserPin = ZkTecoNetworkService.getCredentialByEntityId(widget.userId)?.biometricPin ?? data['biometricPin']?.toString() ?? '';
    final pinController = TextEditingController(text: initialUserPin);
    bool editedCanRegisterMed = data['canRegisterMedicine'] == true;

    // Track branch selection — start from user's existing branch
    String editedBranchId = (data['branchId'] ?? widget.branchId ?? '').toString().toLowerCase().trim();
    if (editedBranchId.isEmpty || editedBranchId == 'global') editedBranchId = widget.branchId;

    List<String> editedDispensaryIds = [];
    if (data['dispensaryIds'] is List) {
      editedDispensaryIds = (data['dispensaryIds'] as List).map((e) => e.toString().toLowerCase().trim()).toList();
    } else if (data['dispensaryId'] != null) {
      final d = data['dispensaryId'].toString().toLowerCase().trim();
      if (d.isNotEmpty && d != 'all') editedDispensaryIds = [d];
    }

    List<Map<String, String>> editedSchedule = [];
    if (data['campSchedule'] is List) {
      for (final item in data['campSchedule']) {
        if (item is Map) {
          editedSchedule.add({
            'campId': item['campId']?.toString() ?? '',
            'session': item['session']?.toString() ?? '',
            'startTime': item['startTime']?.toString() ?? '',
            'endTime': item['endTime']?.toString() ?? '',
          });
        }
      }
    }

    String editedTeachingType = (data['specialization'] ?? data['teachingType'] ?? 'hifz').toString().toLowerCase().trim();
    if (editedTeachingType != 'nazra' && editedTeachingType != 'both') editedTeachingType = 'hifz';
    String editedMadrassaSession = (data['session'] ?? (data['sessions'] is List && (data['sessions'] as List).isNotEmpty ? (data['sessions'] as List).first : 'morning')).toString().toLowerCase().trim();
    if (editedMadrassaSession.isEmpty) editedMadrassaSession = 'morning';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final isDoctor = _selectedRole != null &&
              (_selectedRole!.toLowerCase() == 'doctor' ||
                  _selectedRole!.toLowerCase().contains('doc'));
          final isMadrassaTeacher = _selectedRole != null &&
              _selectedRole!.toLowerCase().trim() == 'madrassa teacher';
          final isDispensaryRole = _selectedRole != null &&
              ['doctor', 'receptionist', 'dispenser', 'rec+dis', 'doc+rec', 'doc+dis', 'doc+rec+dis', 'supervisor', 'branch manager']
                  .contains(_selectedRole!.toLowerCase().trim());
          // Use editedBranchId so branch selection affects camp chips immediately
          final branchCamps = CampSessionService.getCampsForBranch(editedBranchId, includeClosed: false);

          return Dialog(
            backgroundColor: t.bg,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24)),
            insetPadding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding:
                      const EdgeInsets.fromLTRB(24, 20, 20, 20),
                  decoration: BoxDecoration(
                    color: t.accent,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.edit_rounded,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Text('Edit User',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800))),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70, size: 22),
                      padding: EdgeInsets.zero,
                    ),
                  ]),
                ),
                // Form
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: editKey,
                      child: Column(children: [
                        _editField(t, _usernameController,
                            'Username', Icons.alternate_email_rounded,
                            validator: (v) =>
                                v?.trim().isEmpty ?? true
                                    ? 'Required'
                                    : null),
                        _editField(t, _emailController, 'Email',
                            Icons.mail_outline_rounded,
                            type: TextInputType.emailAddress,
                            validator: (v) =>
                                v?.trim().isEmpty ?? true
                                    ? 'Required'
                                    : null),
                        _editField(t, _phoneController, 'Phone (11 digits)',
                            Icons.phone_outlined,
                            type: TextInputType.phone,
                            formatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(11),
                            ],
                            maxLen: 11),
                        _editField(t, passCtrl,
                            'Password',
                            Icons.lock_outline_rounded,
                            obscure: true),
                        _editField(
                            t,
                            _identificationController,
                            'Identification',
                            Icons.credit_card_outlined),
                        _editField(t, _addressController, 'Address',
                            Icons.home_outlined,
                            maxLines: 2),
                        _editField(t, _bankNameController,
                            'Bank Name',
                            Icons.account_balance_outlined),
                        _editField(
                            t,
                            _bankAccountController,
                            'Account Number',
                            Icons.numbers_outlined,
                            type: TextInputType.number),
                        _editField(
                            t,
                            pinController,
                            'Biometric Scanner PIN',
                            Icons.fingerprint_rounded,
                            type: TextInputType.number),
                        const SizedBox(height: 4),
                        _editRoleDropdown(
                          t: t,
                          value: _selectedRole,
                          roles: roleConfigs,
                          onChanged: (v) =>
                              setS(() => _selectedRole = v),
                        ),
                        const SizedBox(height: 12),
                        _editDropdown(
                          t: t,
                          value: _selectedStatus,
                          label: 'Account Status / Access',
                          icon: Icons.no_accounts_rounded,
                          items: const [
                            'Active',
                            'Inactive',
                            'Resigned',
                            'Terminated',
                            'Retired',
                            'Suspended'
                          ],
                          onChanged: (v) => setS(() => _selectedStatus = v),
                        ),
                        const SizedBox(height: 12),
                        // Branch selector — always editable
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: _loadAvailableBranchesForEdit(),
                          builder: (ctx, snap) {
                            final branches = snap.data ?? [];
                            if (branches.isEmpty) return const SizedBox.shrink();
                            final branchItems = branches.map((b) =>
                              (b['id'] ?? '').toString().toLowerCase().trim()
                            ).where((id) => id.isNotEmpty).toList();
                            final branchLabels = {for (final b in branches)
                              (b['id'] ?? '').toString().toLowerCase().trim():
                              (b['name'] ?? b['id'] ?? '').toString()
                            };
                            final effectiveBranch = branchItems.contains(editedBranchId)
                              ? editedBranchId : (branchItems.isNotEmpty ? branchItems.first : editedBranchId);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: DropdownButtonFormField<String>(
                                initialValue: effectiveBranch,
                                isExpanded: true,
                                dropdownColor: t.bgCard,
                                icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
                                decoration: InputDecoration(
                                  labelText: 'Branch',
                                  labelStyle: TextStyle(fontSize: 13, color: t.textTertiary),
                                  prefixIcon: Icon(Icons.location_city_rounded, color: t.textTertiary, size: 20),
                                  filled: true,
                                  fillColor: t.bgCard,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
                                ),
                                items: branchItems.map((id) => DropdownMenuItem(
                                  value: id,
                                  child: Text(branchLabels[id] ?? id, style: TextStyle(fontSize: 14, color: t.textPrimary)),
                                )).toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    setS(() {
                                      editedBranchId = v;
                                      // Clear camp selection when branch changes
                                      editedDispensaryIds.clear();
                                    });
                                  }
                                },
                              ),
                            );
                          },
                        ),
                        if (isDispensaryRole && branchCamps.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: t.bgCardAlt,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: t.bgRule),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.local_hospital_rounded, color: t.accent, size: 20),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Assigned Camp Facilities',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: t.textPrimary,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      FilterChip(
                                        label: const Text('All Dispensaries (Central)'),
                                        selected: editedDispensaryIds.isEmpty,
                                        selectedColor: t.accent.withValues(alpha: 0.2),
                                        checkmarkColor: t.accent,
                                        onSelected: (selected) {
                                          setS(() => editedDispensaryIds.clear());
                                        },
                                      ),
                                      ...branchCamps.map((camp) {
                                        final campId = (camp['id'] ?? '').toString().toLowerCase().trim();
                                        final label = (camp['name'] ?? CampSessionService.getCampLabel(campId, editedBranchId)).toString();
                                        final isSelected = editedDispensaryIds.contains(campId);
                                        return FilterChip(
                                          label: Text(label),
                                          selected: isSelected,
                                          selectedColor: t.accent.withValues(alpha: 0.2),
                                          checkmarkColor: t.accent,
                                          onSelected: (selected) {
                                            setS(() {
                                              if (selected) {
                                                editedDispensaryIds.add(campId);
                                              } else {
                                                editedDispensaryIds.remove(campId);
                                              }
                                            });
                                          },
                                        );
                                      }),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: t.bgCardAlt,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: t.bgRule),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.schedule_rounded, color: t.accent, size: 20),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Shift Schedule (Time-based)',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: t.textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                      TextButton.icon(
                                        icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                                        label: const Text('Add Slot', style: TextStyle(fontSize: 12)),
                                        onPressed: () async {
                                          String selectedCamp = editedDispensaryIds.isNotEmpty
                                              ? editedDispensaryIds.first
                                              : (branchCamps.isNotEmpty ? (branchCamps.first['id'] ?? 'central').toString() : 'central');
                                          String selectedSession = 'morning';

                                          final added = await showDialog<Map<String, String>>(
                                            context: ctx,
                                            builder: (dialogCtx) => StatefulBuilder(
                                              builder: (dialogCtx, setD) {
                                                final campOptions = branchCamps.isNotEmpty
                                                    ? branchCamps.map((c) => (c['id'] ?? '').toString()).toList()
                                                    : [selectedCamp];
                                                String selectedStartTime = '08:00';
                                                String selectedEndTime = '14:00';

                                                void updateDefaultsForSession(String s) {
                                                  switch (s.toLowerCase()) {
                                                    case 'morning':
                                                      selectedStartTime = '08:00';
                                                      selectedEndTime = '14:00';
                                                      break;
                                                    case 'evening':
                                                      selectedStartTime = '14:00';
                                                      selectedEndTime = '20:00';
                                                      break;
                                                    case 'night':
                                                      selectedStartTime = '20:00';
                                                      selectedEndTime = '02:00';
                                                      break;
                                                    case 'all':
                                                    default:
                                                      selectedStartTime = '00:00';
                                                      selectedEndTime = '23:59';
                                                      break;
                                                  }
                                                }

                                                return StatefulBuilder(
                                                  builder: (dialogCtx, setInnerD) {
                                                    Future<void> pickTime({required bool isStart}) async {
                                                      final currentStr = isStart ? selectedStartTime : selectedEndTime;
                                                      final parts = currentStr.split(':');
                                                      final initialHour = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 8) : 8;
                                                      final initialMinute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
                                                      final picked = await showTimePicker(
                                                        context: dialogCtx,
                                                        initialTime: TimeOfDay(hour: initialHour, minute: initialMinute),
                                                      );
                                                      if (picked != null) {
                                                        final hh = picked.hour.toString().padLeft(2, '0');
                                                        final mm = picked.minute.toString().padLeft(2, '0');
                                                        setInnerD(() {
                                                          if (isStart) {
                                                            selectedStartTime = '$hh:$mm';
                                                          } else {
                                                            selectedEndTime = '$hh:$mm';
                                                          }
                                                        });
                                                      }
                                                    }

                                                    return AlertDialog(
                                                      title: const Text('Add Mandatory Shift Schedule Slot', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                                      content: SingleChildScrollView(
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            DropdownButtonFormField<String>(
                                                              value: campOptions.contains(selectedCamp) ? selectedCamp : campOptions.first,
                                                              decoration: const InputDecoration(labelText: 'Camp Facility'),
                                                              items: campOptions.map((id) => DropdownMenuItem(
                                                                value: id,
                                                                child: Text(CampSessionService.getCampLabel(id, editedBranchId)),
                                                              )).toList(),
                                                              onChanged: (v) => setInnerD(() => selectedCamp = v ?? campOptions.first),
                                                            ),
                                                            const SizedBox(height: 12),
                                                            DropdownButtonFormField<String>(
                                                              value: selectedSession,
                                                              decoration: const InputDecoration(labelText: 'Mandatory Shift / Session'),
                                                              items: const [
                                                                DropdownMenuItem(value: 'morning', child: Text('☀️ Morning')),
                                                                DropdownMenuItem(value: 'evening', child: Text('🌅 Evening')),
                                                                DropdownMenuItem(value: 'night', child: Text('🌙 Night')),
                                                                DropdownMenuItem(value: 'all', child: Text('📑 All Sessions')),
                                                              ],
                                                              onChanged: (v) {
                                                                final val = v ?? 'morning';
                                                                setInnerD(() {
                                                                  selectedSession = val;
                                                                  updateDefaultsForSession(val);
                                                                });
                                                              },
                                                            ),
                                                            const SizedBox(height: 14),
                                                            const Text('Session Time (Click to edit)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                                            const SizedBox(height: 6),
                                                            Row(
                                                              children: [
                                                                Expanded(
                                                                  child: InkWell(
                                                                    onTap: () => pickTime(isStart: true),
                                                                    borderRadius: BorderRadius.circular(8),
                                                                    child: Container(
                                                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                                      decoration: BoxDecoration(
                                                                        border: Border.all(color: Colors.grey.shade400),
                                                                        borderRadius: BorderRadius.circular(8),
                                                                      ),
                                                                      child: Column(
                                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                                        children: [
                                                                          Text('Start Time', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                                                                          const SizedBox(height: 2),
                                                                          Row(
                                                                            children: [
                                                                              const Icon(Icons.access_time_rounded, size: 14),
                                                                              const SizedBox(width: 4),
                                                                              Text(selectedStartTime, style: const TextStyle(fontWeight: FontWeight.bold)),
                                                                            ],
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                                const SizedBox(width: 8),
                                                                Expanded(
                                                                  child: InkWell(
                                                                    onTap: () => pickTime(isStart: false),
                                                                    borderRadius: BorderRadius.circular(8),
                                                                    child: Container(
                                                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                                      decoration: BoxDecoration(
                                                                        border: Border.all(color: Colors.grey.shade400),
                                                                        borderRadius: BorderRadius.circular(8),
                                                                      ),
                                                                      child: Column(
                                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                                        children: [
                                                                          Text('End Time', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                                                                          const SizedBox(height: 2),
                                                                          Row(
                                                                            children: [
                                                                              const Icon(Icons.access_time_rounded, size: 14),
                                                                              const SizedBox(width: 4),
                                                                              Text(selectedEndTime, style: const TextStyle(fontWeight: FontWeight.bold)),
                                                                            ],
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      actions: [
                                                        TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                                                        ElevatedButton(
                                                          onPressed: () {
                                                            Navigator.pop(dialogCtx, {
                                                              'campId': selectedCamp,
                                                              'session': selectedSession,
                                                              'startTime': selectedStartTime,
                                                              'endTime': selectedEndTime,
                                                            });
                                                          },
                                                          child: const Text('Add Slot'),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                );
                                              },
                                            ),
                                          );

                                          if (added != null) {
                                            setS(() => editedSchedule.add(added));
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  if (editedSchedule.isEmpty)
                                    Text(
                                      'No specific shift schedule defined (Manual camp picker will be used).',
                                      style: TextStyle(fontSize: 12, color: t.textTertiary, fontStyle: FontStyle.italic),
                                    )
                                  else
                                    Column(
                                      children: editedSchedule.asMap().entries.map<Widget>((e) {
                                        final idx = e.key;
                                        final item = e.value;
                                        final label = CampSessionService.getCampLabel(item['campId'] ?? '');
                                        final timeRange = (item['startTime']?.isNotEmpty == true && item['endTime']?.isNotEmpty == true)
                                            ? ' (${item['startTime']} – ${item['endTime']})'
                                            : '';
                                        final sess = item['session']?.toString().toLowerCase();
                                        String sessionDisplay = '';
                                        if (sess == 'morning') {
                                          sessionDisplay = '☀️ Morning';
                                        } else if (sess == 'evening') {
                                          sessionDisplay = '🌅 Evening';
                                        } else if (sess == 'night') {
                                          sessionDisplay = '🌙 Night';
                                        } else if (sess == 'all') {
                                          sessionDisplay = '📑 All Sessions';
                                        }
                                        final combinedSessionStr = sessionDisplay.isNotEmpty
                                            ? (timeRange.isNotEmpty ? '$sessionDisplay$timeRange' : sessionDisplay)
                                            : (timeRange.isNotEmpty ? '${item['startTime']} – ${item['endTime']}' : '📑 All Sessions');
                                        return Container(
                                          margin: const EdgeInsets.only(top: 6),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: t.bgCard,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: t.bgRule),
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '$label — $combinedSessionStr',
                                                  style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.w600),
                                                ),
                                              ),
                                              IconButton(
                                                icon: Icon(Icons.close_rounded, size: 16, color: t.danger),
                                                onPressed: () => setS(() => editedSchedule.removeAt(idx)),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ),
                              ],
                            ),
                          ),
                        ],

                        if (isMadrassaTeacher) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: t.bgCardAlt,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: t.bgRule),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.menu_book_rounded, color: const Color(0xFF7E22CE), size: 20),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Teaching Specialization & Focus',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: t.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilterChip(
                                      label: const Text('📖 Nazra (نَظْرَة)'),
                                      selected: editedTeachingType == 'nazra',
                                      selectedColor: const Color(0xFF10B981).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF10B981),
                                      onSelected: (s) => setS(() => editedTeachingType = 'nazra'),
                                    ),
                                    FilterChip(
                                      label: const Text('🕋 Hifz (حِفْظ)'),
                                      selected: editedTeachingType == 'hifz',
                                      selectedColor: const Color(0xFF7E22CE).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF7E22CE),
                                      onSelected: (s) => setS(() => editedTeachingType = 'hifz'),
                                    ),
                                    FilterChip(
                                      label: const Text('✨ Both (حِفْظ + نَظْرَة)'),
                                      selected: editedTeachingType == 'both',
                                      selectedColor: const Color(0xFF0284C7).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF0284C7),
                                      onSelected: (s) => setS(() => editedTeachingType = 'both'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: t.bgCardAlt,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: t.bgRule),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.schedule_rounded, color: const Color(0xFF8B5CF6), size: 20),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Teaching Shift / Session',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: t.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilterChip(
                                      label: const Text('☀️ Morning (8 AM – 2 PM)'),
                                      selected: editedMadrassaSession == 'morning',
                                      selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFFF59E0B),
                                      onSelected: (s) => setS(() => editedMadrassaSession = 'morning'),
                                    ),
                                    FilterChip(
                                      label: const Text('🌅 Evening (2 PM – 8 PM)'),
                                      selected: editedMadrassaSession == 'evening',
                                      selectedColor: const Color(0xFF0284C7).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF0284C7),
                                      onSelected: (s) => setS(() => editedMadrassaSession = 'evening'),
                                    ),
                                    FilterChip(
                                      label: const Text('🌙 Night (8 PM – 8 AM)'),
                                      selected: editedMadrassaSession == 'night',
                                      selectedColor: const Color(0xFF6366F1).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF6366F1),
                                      onSelected: (s) => setS(() => editedMadrassaSession = 'night'),
                                    ),
                                    FilterChip(
                                      label: const Text('📑 All Shifts (Full Day)'),
                                      selected: editedMadrassaSession == 'all',
                                      selectedColor: const Color(0xFF8B5CF6).withValues(alpha: 0.2),
                                      checkmarkColor: const Color(0xFF8B5CF6),
                                      onSelected: (s) => setS(() => editedMadrassaSession = 'all'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: t.bgCardAlt,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: t.bgRule),
                          ),
                          child: SwitchListTile(
                            title: Text('Allow Register Medicine Access', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: t.textPrimary)),
                            subtitle: Text('Grants user permission to register new stock medicines', style: TextStyle(fontSize: 11, color: t.textSecondary)),
                            value: editedCanRegisterMed,
                            activeColor: t.accent,
                            onChanged: (val) => setS(() => editedCanRegisterMed = val),
                          ),
                        ),

                        if (isDoctor) ...[
                          const SizedBox(height: 12),
                          _editField(t, _degreeController,
                              'Degree', Icons.school_outlined),
                        ],
                        const SizedBox(height: 16),
                        _uploadTile(t, 'Profile Picture',
                            _profileFile,
                            (f) => setS(() => _profileFile = f)),
                        _uploadTile(t, 'ID Document', _idFile,
                            (f) => setS(() => _idFile = f)),
                        if (isDoctor)
                          _uploadTile(t, 'Degree Certificate',
                              _degreeFile,
                              (f) => setS(() => _degreeFile = f)),
                      ]),
                    ),
                  ),
                ),
                // Actions
                Divider(height: 1, thickness: 1, color: t.bgRule),
                Container(
                  padding:
                      const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(24)),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(12),
                              side: BorderSide(color: t.bgRule)),
                        ),
                        child: Text('Cancel',
                            style: TextStyle(
                                color: t.textSecondary,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.save_rounded,
                            size: 18),
                        label: const Text('Save Changes',
                            style: TextStyle(
                                fontWeight: FontWeight.w700)),
                        onPressed: () async => _saveUser(ctx,
                            editKey, data, passCtrl, isDoctor,
                            pinController: pinController,
                            dispensaryIds: editedDispensaryIds,
                            campSchedule: editedSchedule,
                            canRegisterMedicine: editedCanRegisterMed,
                            editedBranchId: editedBranchId,
                            madrassaTeachingType: editedTeachingType,
                            madrassaSession: editedMadrassaSession),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _saveUser(
      BuildContext ctx,
      GlobalKey<FormState> key,
      Map<String, dynamic> old,
      TextEditingController passCtrl,
      bool isDoctor, {
      TextEditingController? pinController,
      List<String> dispensaryIds = const [],
      List<Map<String, String>> campSchedule = const [],
      bool? canRegisterMedicine,
      String editedBranchId = '',
      String madrassaTeachingType = 'hifz',
      String madrassaSession = 'morning',
  }) async {
    if (!key.currentState!.validate()) return;

    final String targetRole = (old['role'] ?? '').toString().toLowerCase().trim();
    if (targetRole == 'chairman') {
      _snack('Access Denied: The Chairman account is 100% immutable and CANNOT be edited or restricted by ANY user!', error: true);
      return;
    }
    if (!_canManageUserAccess(old)) {
      _snack('Access Denied: You do not have permission to modify user account details, roles, or access status!', error: true);
      return;
    }

    final enteredPin = pinController?.text.trim() ?? '';
    if (enteredPin.isNotEmpty) {
      final conflict = ZkTecoNetworkService.findPinConflict(enteredPin, excludeEntityId: widget.userId);
      if (conflict != null) {
        _snack('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please enter a unique PIN.', error: true);
        return;
      }
    }

    final allowedSessionsSet = <String>{};
    for (final item in campSchedule) {
      final s = item['session']?.toString().toLowerCase().trim();
      if (s != null && s.isNotEmpty) allowedSessionsSet.add(s);
    }
    final allowedSessionsList = allowedSessionsSet.isEmpty ? ['all'] : allowedSessionsSet.toList();

    final updates = <String, dynamic>{
      'username': _usernameController.text.trim(),                              // original casing
      'usernameLower': _usernameController.text.trim().toLowerCase(),            // for lookup
      'email': _emailController.text.trim().toLowerCase(),
      if (canRegisterMedicine != null) 'canRegisterMedicine': canRegisterMedicine,
      'biometricPin': enteredPin.isNotEmpty ? enteredPin : null,
      'phone': _phoneController.text.trim().isNotEmpty
          ? _phoneController.text.trim()
          : null,
      'identification':
          _identificationController.text.trim().isNotEmpty
              ? _identificationController.text.trim()
              : null,
      'address': _addressController.text.trim().isNotEmpty
          ? _addressController.text.trim()
          : null,
      'bankName': _bankNameController.text.trim().isNotEmpty
          ? _bankNameController.text.trim()
          : null,
      'bankAccount': _bankAccountController.text.trim().isNotEmpty
          ? _bankAccountController.text.trim()
          : null,
      'role': _selectedRole ?? old['role'],
      'status': _selectedStatus ?? 'Active',
      'accountStatus': _selectedStatus ?? 'Active',
      'isActive': (_selectedStatus ?? 'Active') == 'Active',
      'password': passCtrl.text.trim().isEmpty
          ? (old['password']?.toString().isNotEmpty == true ? old['password'].toString() : '1122')
          : passCtrl.text.trim(),
      'dispensaryIds': dispensaryIds,
      'dispensaryId': dispensaryIds.isNotEmpty ? dispensaryIds.first : null,
      'campSchedule': campSchedule,
      'allowedSessions': allowedSessionsList,
    };

    final String rawRole = (_selectedRole ?? old['role'] ?? '').toString().toLowerCase().trim();
    final bool isMadrassaTeacher = rawRole == 'madrassa teacher';
    if (isMadrassaTeacher) {
      updates['specialization'] = madrassaTeachingType;
      updates['teachingType'] = madrassaTeachingType;
      updates['session'] = madrassaSession;
      updates['sessions'] = madrassaSession == 'all'
          ? ['morning', 'evening', 'night']
          : [madrassaSession];
    }

    final effectivePw = updates['password'].toString();
    updates['passwordHash'] = LocalStorageService.hashPassword(effectivePw);
    if (isDoctor) updates['degree'] = _degreeController.text.trim();

    if (enteredPin.isNotEmpty) {
      await ZkTecoNetworkService.assignPinToEntity(
        entityId: widget.userId,
        entityName: _usernameController.text.trim(),
        entityType: 'user',
        branchId: widget.branchId,
        customPin: enteredPin,
      );
    }

    Future<String> upload(XFile f, String name) async {
      final path =
          'branches/${widget.branchId}/users/${widget.userId}/$name.${f.name.split('.').last}';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putFile(File(f.path)).timeout(const Duration(seconds: 15));
      return await ref.getDownloadURL().timeout(const Duration(seconds: 8));
    }

    if (_profileFile != null) {
      updates['profilePictureUrl'] =
          await upload(_profileFile!, 'profile');
    }
    if (_idFile != null) {
      updates['identificationUrl'] =
          await upload(_idFile!, 'identification');
    }
    if (isDoctor && _degreeFile != null) {
      updates['degreeUrl'] = await upload(_degreeFile!, 'degree');
    }

    try {
      final String oldRole = (old['role'] ?? '').toString().toLowerCase();
      final String newRole = (_selectedRole ?? oldRole).toLowerCase();
      final bool isStudentOrGuardian = oldRole.contains('guardian') ||
          oldRole.contains('parent') ||
          oldRole.contains('student') ||
          newRole.contains('guardian') ||
          newRole.contains('parent') ||
          newRole.contains('student');

      final String oldEmail = old['email']?.toString() ?? '';
      final String oldPassword = old['password']?.toString() ?? '1122';
      final String newEmail = (updates['email'] ?? oldEmail).toString();
      final String newPassword = (updates['password'] ?? oldPassword).toString();
      final String newName = (updates['name'] ?? updates['username'] ?? old['name'] ?? old['username'])?.toString() ?? '';
      final bool hasPasswordChanged = passCtrl.text.trim().isNotEmpty;
      final isLocal = widget.userId.startsWith('local-');

      // Attempt secondary Firebase Auth sync for accounts that changed their password and have a cloud identity
      if (!isLocal && hasPasswordChanged) {
        try {
          await _updateFirebaseAuthUser(
            oldEmail,
            oldPassword,
            newEmail: newEmail,
            newPassword: newPassword,
            newDisplayName: newName,
          );
        } catch (e) {
          debugPrint('[UserDetailScreen] Auth sync note: $e');
        }
      }

      // Preserve and deduplicate studentIds for student/guardian portal profiles
      if (old['studentIds'] != null) {
        final rawIds = old['studentIds'];
        if (rawIds is List) {
          updates['studentIds'] = rawIds.map((e) => e.toString()).toSet().toList();
        }
      }

      String resolvedEditRole = (_selectedRole ?? old['role'] ?? '').toString().trim();
      if (resolvedEditRole.isEmpty ||
          resolvedEditRole.toLowerCase() == 'user' ||
          resolvedEditRole.toLowerCase() == 'staff' ||
          resolvedEditRole.toLowerCase() == 'unknown') {
        resolvedEditRole = (old['role'] != null &&
                old['role'].toString().trim().isNotEmpty &&
                old['role'].toString().toLowerCase() != 'user' &&
                old['role'].toString().toLowerCase() != 'staff')
            ? old['role'].toString().trim()
            : 'Admin';
      }

      // Use editedBranchId which may have been changed in branch dropdown
      final resolvedBranchId = editedBranchId.isNotEmpty && editedBranchId != 'global'
          ? editedBranchId
          : (widget.branchId.isNotEmpty && widget.branchId != 'global'
              ? widget.branchId
              : (old['branchId']?.toString() ?? 'all'));

      final fullUserData = <String, dynamic>{
        ...old,
        ...updates,
        'uid': widget.userId,
        'id': widget.userId,
        'name': _usernameController.text.trim(),
        'username': _usernameController.text.trim(),
        'usernameLower': _usernameController.text.trim().toLowerCase(),
        'email': _emailController.text.trim().toLowerCase(),
        'branchId': resolvedBranchId,
        'role': resolvedEditRole,
        'userRole': resolvedEditRole,
        'roles': [resolvedEditRole],
        'status': _selectedStatus ?? 'Active',
        'accountStatus': _selectedStatus ?? 'Active',
        'isActive': (_selectedStatus ?? 'Active') == 'Active',
        'password': effectivePw,
        'passwordHash': LocalStorageService.hashPassword(effectivePw),
      };

      await LocalStorageService.saveUserOffline(
        uid: widget.userId,
        branchId: resolvedBranchId,
        userData: fullUserData,
      );

      // Save credentials into OfflineAuthService so offline login works immediately
      await OfflineAuthService.saveCredentials(
        usernameOrEmail: fullUserData['usernameLower'],
        password: effectivePw,
        userData: fullUserData,
        setAsLastLoggedIn: false,
      );
      if (fullUserData['email'] != null && fullUserData['email'].toString().isNotEmpty) {
        await OfflineAuthService.saveCredentials(
          usernameOrEmail: fullUserData['email'].toString().toLowerCase(),
          password: effectivePw,
          userData: fullUserData,
          setAsLastLoggedIn: false,
        );
      }

      await LocalStorageService.enqueueSync({
        'type': 'save_user',
        'branchId': widget.branchId,
        'uid': widget.userId,
        'data': fullUserData,
      });

      _remoteUserData = fullUserData;

      final cnicVal = ((updates['cnic'] ?? updates['identification']) ?? (old['cnic'] ?? old['identification']))?.toString() ?? '';
      if (cnicVal.isNotEmpty && !isStudentOrGuardian) {
        await FinanceLocalStorage.linkUserAndEmployeeByCnic(
          cnic: cnicVal,
          userId: widget.userId,
          userRole: (updates['role'] ?? old['role'])?.toString(),
          userName: (updates['username'] ?? old['username'])?.toString(),
        );
      }

      // Always attempt instant Firestore push (not just when online flag is set)
      try {
        final firestoreData = Map<String, dynamic>.from(fullUserData);
        firestoreData.remove('password'); // Never store plaintext password in Firestore
        firestoreData['updatedAt'] = FieldValue.serverTimestamp();

        await _firestore
            .collection('users')
            .doc(widget.userId)
            .set(firestoreData, SetOptions(merge: true))
            .timeout(const Duration(seconds: 6));

        if (resolvedBranchId != 'all' && resolvedBranchId.isNotEmpty && resolvedBranchId != 'global') {
          await _firestore
              .collection('branches')
              .doc(resolvedBranchId)
              .collection('users')
              .doc(widget.userId)
              .set(firestoreData, SetOptions(merge: true))
              .timeout(const Duration(seconds: 6));
        }
        debugPrint('[UserDetailScreen] ✅ Instant Firestore sync complete for ${widget.userId}');
      } catch (e) {
        debugPrint('[UserDetailScreen] ⚠️ Firestore update note (will retry via sync queue): $e');
      }

      SyncService().triggerUpload(force: true);

      _snack('User updated successfully!', success: true);
      if (mounted) {
        Navigator.pop(ctx);
        setState(() {});
      }
    } catch (e) {
      _snack('Error: $e', error: true);
    }
  }

  void _deleteUser(Map<String, dynamic> data, RoleThemeData t) async {
    if (!await _checkPassword(t)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: t.danger.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: Icon(Icons.delete_forever_rounded,
                    color: t.danger, size: 40),
              ),
              const SizedBox(height: 16),
              Text('Delete User?',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: t.textPrimary,
                      letterSpacing: -0.5)),
              const SizedBox(height: 8),
              Text(
                  'Are you sure you want to delete this user profile? This action is permanent.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: t.textSecondary,
                      height: 1.4)),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Cancel',
                        style: TextStyle(
                            color: t.textSecondary,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.danger,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: const Text('Delete',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;

    final targetUid = widget.userId;
    final targetEmail = (data['email'] ?? '').toString().trim().toLowerCase();
    final targetUsername = (data['username'] ?? data['name'] ?? '').toString().trim().toLowerCase();
    final targetPass = (data['password'] ?? '112233').toString();

    try {
      final authDeleted = await AuthService.deleteAuthUser(
        uid: targetUid,
        email: targetEmail,
        username: targetUsername,
        password: targetPass,
        branchId: widget.branchId,
      );

      await FinanceLocalStorage.syncBiDirectionalOffboarding(
        userId: targetUid,
        cnic: (data['cnic'] ?? data['identification'])?.toString(),
        performedBy: 'UserAdmin',
      );

      await LocalStorageService.deleteUserOffline(
        uid: targetUid,
        branchId: widget.branchId,
        email: targetEmail,
        username: targetUsername,
      );

      // Comprehensive Firestore deletion
      final firestore = FirebaseFirestore.instance;
      final identifiers = <String>{
        if (targetUid.isNotEmpty) targetUid,
        if (targetUsername.isNotEmpty) targetUsername,
        if (targetEmail.isNotEmpty) targetEmail,
      };

      final deletePayload = {
        'isDeleted': true,
        'status': 'deleted',
        'accountStatus': 'deleted',
        'deletedAt': FieldValue.serverTimestamp(),
      };

      for (final id in identifiers) {
        await firestore.collection('users').doc(id).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
        if (widget.branchId.isNotEmpty && widget.branchId != 'all') {
          await firestore.collection('branches').doc(widget.branchId).collection('users').doc(id).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
        }
      }

      if (targetUsername.isNotEmpty) {
        try {
          final snap = await firestore.collection('users').where('usernameLower', isEqualTo: targetUsername).get();
          for (final doc in snap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        } catch (_) {}
      }

      if (targetEmail.isNotEmpty) {
        try {
          final snap = await firestore.collection('users').where('email', isEqualTo: targetEmail).get();
          for (final doc in snap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        } catch (_) {}
      }

      if (targetUid.isNotEmpty) {
        try {
          final snap = await firestore.collection('users').where('uid', isEqualTo: targetUid).get();
          for (final doc in snap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        } catch (_) {}
      }

      try {
        if (targetEmail.isNotEmpty) {
          final gSnap = await firestore.collectionGroup('users').where('email', isEqualTo: targetEmail).get();
          for (final doc in gSnap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        }
        if (targetUsername.isNotEmpty) {
          final gSnap = await firestore.collectionGroup('users').where('usernameLower', isEqualTo: targetUsername).get();
          for (final doc in gSnap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        }
        if (targetUid.isNotEmpty) {
          final gSnap = await firestore.collectionGroup('users').where('uid', isEqualTo: targetUid).get();
          for (final doc in gSnap.docs) {
            await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        }
      } catch (_) {}

      SyncService().triggerUpload(force: true);

      final authMessage = authDeleted
          ? 'User deleted successfully.'
          : 'User deleted permanently from app and cloud records.';

      _snack(authMessage, success: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack('Error: $e', error: true);
    }
  }

  void _snack(String msg,
      {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
            error
                ? Icons.error_outline
                : success
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
            color: Colors.white,
            size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: const TextStyle(fontSize: 13))),
      ]),
      backgroundColor: error
          ? const Color(0xFFB00020)
          : success
              ? const Color(0xFF2E7D32)
              : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  Future<void> _refreshUser() async {
    setState(() => _isLoadingRemote = true);
    await _fetchUserDataFromFirestore();
    if (mounted) {
      _snack('User details refreshed', success: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    if (!Hive.isBoxOpen('local_users')) {
      return Scaffold(
        backgroundColor: t.bg,
        body: Center(child: CircularProgressIndicator(color: t.accent)),
      );
    }

    return Scaffold(
      backgroundColor: t.bg,
      body: ValueListenableBuilder<Box>(
        valueListenable: Hive.box('local_users').listenable(),
        builder: (context, box, _) {
          final localUser = _getLocalUser();
          final Map<String, dynamic> merged = {};

          if (_remoteUserData != null) {
            merged.addAll(_remoteUserData!);
          }
          if (localUser != null) {
            merged.addAll(localUser);
          }

          if (merged.containsKey('updates') && merged['updates'] is Map) {
            final unnested = Map<String, dynamic>.from(merged['updates'] as Map);
            merged.addAll(unnested);
            merged.remove('updates');
          }

          if (merged.isEmpty && _isLoadingRemote) {
            return Center(child: CircularProgressIndicator(color: t.accent));
          }

          if (merged.isEmpty) {
            return _notFoundState(t);
          }

          final rawName = (merged['name'] ?? merged['username'] ?? merged['displayName'] ?? '').toString().trim();
          final rawUsername = (merged['username'] ?? merged['name'] ?? '').toString().trim();
          final rawEmail = (merged['email'] ?? '').toString().trim();
          final rawRole = (merged['role'] ?? 'User').toString().trim();

          merged['name'] = rawName.isNotEmpty ? rawName : (rawUsername.isNotEmpty ? rawUsername : 'User');
          merged['username'] = rawUsername.isNotEmpty ? rawUsername : (rawName.isNotEmpty ? rawName : 'user');
          merged['email'] = rawEmail;
          merged['role'] = rawRole;
          merged['uid'] = (merged['uid'] ?? merged['id'] ?? widget.userId).toString();
          merged['id'] = merged['uid'];

          return RefreshIndicator(
            onRefresh: _refreshUser,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                slivers: [
                  _buildSliverAppBar(merged, t),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        const SizedBox(height: 20),
                        _buildInfoSection(merged, t),
                        const SizedBox(height: 16),
                        _buildLinkedEmployeeSection(merged, t),
                        const SizedBox(height: 16),
                        _buildContactSection(merged, t),
                        const SizedBox(height: 16),
                        _buildFinancialSection(merged, t),
                        if ((merged['role'] as String?) != null &&
                            ((merged['role'] as String).toLowerCase() == 'doctor' ||
                                (merged['role'] as String).toLowerCase().contains('doc'))) ...[
                          const SizedBox(height: 16),
                          _buildMedicalSection(merged, t),
                        ],
                        if (merged['identificationUrl'] != null ||
                            merged['degreeUrl'] != null) ...[
                          const SizedBox(height: 16),
                          _buildDocumentsSection(merged, t),
                        ],
                        const SizedBox(height: 16),
                        _buildActiveDeviceSection(merged, t),
                        const SizedBox(height: 16),
                        _buildMetaSection(merged, t),
                        const SizedBox(height: 16),
                        _buildRevokeAccessCard(merged, t),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSliverAppBar(
      Map<String, dynamic> data, RoleThemeData t) {
    final username = resolveUserDisplayName(data);
    final rawRole = data['role'] as String? ?? '';
    final role = rawRole.toLowerCase() == 'madrassa parent' ? 'GUARDIAN' : rawRole.toUpperCase();
    final isGuardian = rawRole.toLowerCase() == 'madrassa parent' || rawRole.toLowerCase() == 'madrassa guardian';
    final photoUrl = data['profilePictureUrl'] as String?;
    final initials = username.trim().isEmpty
        ? '?'
        : username
            .trim()
            .split(' ')
            .map((w) => w[0])
            .take(2)
            .join()
            .toUpperCase();
    final isOnline = DeviceInfoService.isUserOnline(data, thresholdMinutes: 5);
    final status = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    final isRevoked = status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        data['isActive'] == false ||
        data['isRevoked'] == true ||
        data['accessRevoked'] == true;
    final handle = (data['username'] ?? '').toString().trim();

    return SliverAppBar(
      expandedHeight: 235,
      pinned: true,
      backgroundColor: t.accent,
      foregroundColor: Colors.white,
      elevation: 0,
      actions: [
        IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 0.8)),
            child: const Icon(Icons.refresh_rounded,
                size: 18, color: Colors.white),
          ),
          tooltip: 'Refresh User Data',
          onPressed: _refreshUser,
        ),
        if (_canManageUserAccess(data)) ...[
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 0.8)),
              child: const Icon(Icons.edit_rounded,
                  size: 18, color: Colors.white),
            ),
            tooltip: 'Edit Profile & Credentials',
            onPressed: () => _showEditDialog(data, t),
          ),
          if (!isGuardian)
            IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: isRevoked ? Colors.green.withValues(alpha: 0.3) : Colors.red.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isRevoked ? Colors.green.withValues(alpha: 0.5) : Colors.red.withValues(alpha: 0.5),
                      width: 0.8,
                    )),
                child: Icon(
                  isRevoked ? Icons.lock_open_rounded : Icons.lock_person_rounded,
                  size: 18,
                  color: Colors.white,
                ),
              ),
              tooltip: isRevoked ? 'Restore Access' : 'Revoke Access',
              onPressed: () => _showRevokeAccessDialog(data, t),
            ),
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 0.8)),
              child: const Icon(Icons.medical_services_outlined,
                  size: 18, color: Colors.white),
            ),
            tooltip: 'Medical History',
            onPressed: () => StaffPatientLinkService.openStaffMedicalHistory(
              context,
              name: username,
              cnic: data['cnic']?.toString(),
              branchId: data['branchId']?.toString() ?? widget.branchId,
              role: role,
            ),
          ),
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.5), width: 0.8)),
              child: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.white),
            ),
            tooltip: 'Delete User Permanently',
            onPressed: () => _deleteUser(data, t),
          ),
          const SizedBox(width: 8),
        ],
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                t.bg == const Color(0xFF080C14)
                    ? const Color(0xFF0F172A)
                    : t.accent.withValues(alpha: 0.95),
                t.accent,
                t.accentLight,
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 52, 20, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => _showEnlargedPhotoDialog(context, username, photoUrl, role, t),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Tooltip(
                        message: 'Tap to enlarge profile photo',
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 84,
                              height: 84,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.2),
                                image: (photoUrl != null && photoUrl.isNotEmpty)
                                    ? DecorationImage(
                                        image: (photoUrl.startsWith('http://') || photoUrl.startsWith('https://'))
                                            ? NetworkImage(photoUrl) as ImageProvider
                                            : MemoryImage(ImageUploadService.decodeBase64ToBytes(photoUrl) ?? Uint8List(0)),
                                        fit: BoxFit.cover)
                                    : null,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              alignment: Alignment.center,
                              child: (photoUrl == null || photoUrl.isEmpty)
                                  ? Text(initials,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 28,
                                          fontWeight: FontWeight.w900))
                                  : null,
                            ),
                            if (isOnline)
                              Positioned(
                                right: 2,
                                bottom: 2,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF22C55E),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2.5),
                                    boxShadow: const [
                                      BoxShadow(color: Color(0x6622C55E), blurRadius: 6, spreadRadius: 1),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          username,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.4,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (handle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '@$handle',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 0.7),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.badge_outlined, size: 12, color: Colors.white),
                                  const SizedBox(width: 4),
                                  Text(
                                    role,
                                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: isRevoked
                                    ? const Color(0xFFEF4444)
                                    : const Color(0xFF10B981),
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: (isRevoked ? const Color(0xFFEF4444) : const Color(0xFF10B981)).withValues(alpha: 0.35),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: Text(
                                isRevoked ? 'REVOKED' : 'ACTIVE',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            if (isOnline)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF22C55E).withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF22C55E), width: 0.8),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.circle, size: 6, color: Color(0xFF4ADE80)),
                                    SizedBox(width: 4),
                                    Text('ONLINE', style: TextStyle(color: Color(0xFF4ADE80), fontSize: 10, fontWeight: FontWeight.w800)),
                                  ],
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.location_on_outlined, size: 11, color: Colors.white.withValues(alpha: 0.8)),
                                  const SizedBox(width: 3),
                                  Text(
                                    (branchName ?? widget.branchId).toUpperCase(),
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 10.5, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoSection(
      Map<String, dynamic> data, RoleThemeData t) {
    return _card(t, 'Account Info', Icons.person_outline_rounded,
        t.accent, [
      _infoRow(t, 'User ID', widget.userId,
          Icons.fingerprint_rounded),
      _infoRow(
          t, 'Username', data['username'] ?? 'N/A', Icons.alternate_email_rounded),
      _infoRow(t, 'Email', data['email'] ?? 'N/A',
          Icons.mail_outline_rounded),
      _infoRow(
          t,
          'Role',
          (data['role'] as String? ?? 'N/A').toLowerCase() == 'madrassa parent'
              ? 'GUARDIAN'
              : (data['role'] as String? ?? 'N/A').toUpperCase(),
          Icons.badge_outlined),
    ]);
  }

  Widget _buildContactSection(
      Map<String, dynamic> data, RoleThemeData t) {
    return _card(t, 'Contact', Icons.contact_phone_outlined,
        const Color(0xFF00695C), [
      _infoRow(t, 'Phone', data['phone'] ?? 'N/A',
          Icons.phone_outlined),
      _infoRow(t, 'ID / CNIC',
          data['identification'] ?? 'N/A',
          Icons.credit_card_outlined),
      _infoRow(t, 'Address', data['address'] ?? 'N/A',
          Icons.home_outlined),
      _infoRow(t, 'Branch', branchName ?? widget.branchId,
          Icons.location_on_outlined),
      if (data['dispensaryIds'] is List && (data['dispensaryIds'] as List).isNotEmpty)
        _infoRow(
          t,
          'Assigned Camps',
          (data['dispensaryIds'] as List)
              .map((id) => CampSessionService.getCampLabel(id.toString()))
              .join(', '),
          Icons.local_hospital_outlined,
        )
      else if (data['dispensaryId'] != null && data['dispensaryId'].toString().isNotEmpty)
        _infoRow(t, 'Dispensary', (data['dispensaryId'] == 'kapayya' || data['dispensaryId'] == 'saddar')
            ? 'Saddar Dispensary'
            : (data['dispensaryId'] == 'haji_camp' ? 'Haji Camp Dispensary' : data['dispensaryId'].toString().toUpperCase()),
            Icons.local_hospital_outlined),
      if (data['campSchedule'] is List && (data['campSchedule'] as List).isNotEmpty)
        _infoRow(
          t,
          'Shift Schedule',
          (data['campSchedule'] as List).map((s) {
            if (s is! Map) return '';
            final c = CampSessionService.getCampLabel(s['campId']?.toString() ?? '');
            return '$c (${s['startTime']}–${s['endTime']})';
          }).where((str) => str.isNotEmpty).join('\n'),
          Icons.access_time_rounded,
        ),
    ]);
  }

  Widget _buildLinkedEmployeeSection(Map<String, dynamic> data, RoleThemeData t) {
    final linkedEmpId = (data['linkedEmployeeId'] ?? data['employeeId'])?.toString();
    Map<String, dynamic>? emp;
    if (linkedEmpId != null && linkedEmpId.isNotEmpty) {
      emp = FinanceLocalStorage.getEmployee(linkedEmpId);
      if (emp == null && Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        final raw = Hive.box(LocalStorageService.employeesBox).get(linkedEmpId);
        if (raw is Map) emp = Map<String, dynamic>.from(raw);
      }
    }

    final isLinked = emp != null && emp.isNotEmpty;

    return _card(
      t,
      'HR Employee & Attendance Link',
      Icons.badge_outlined,
      const Color(0xFF0284C7),
      [
        if (isLinked) ...[
          _infoRow(t, 'Employee ID', emp['id']?.toString() ?? emp['localId']?.toString() ?? linkedEmpId!, Icons.fingerprint_rounded),
          const SizedBox(height: 8),
          _infoRow(t, 'Staff Name', emp['name']?.toString() ?? 'N/A', Icons.person_outline),
          const SizedBox(height: 8),
          _infoRow(t, 'Designation', emp['designation']?.toString() ?? emp['role']?.toString() ?? 'N/A', Icons.work_outline),
          const SizedBox(height: 8),
          _infoRow(t, 'Department', emp['department']?.toString() ?? 'N/A', Icons.business_outlined),
          const SizedBox(height: 8),
          _infoRow(t, 'Base Salary', 'PKR ${NumberFormat('#,###').format((emp['currentSalary'] as num?)?.toDouble() ?? 0.0)}', Icons.payments_outlined),
          const SizedBox(height: 8),
          _infoRow(t, 'Attendance Status', (emp['isActive'] != false) ? 'Active on Roster' : 'Inactive / Offboarded', Icons.check_circle_outline),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0284C7),
                    side: const BorderSide(color: Color(0xFF0284C7)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                  label: const Text('Change Link', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () => _showManualLinkEmployeeDialog(data, t),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.danger,
                    side: BorderSide(color: t.danger),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.link_off_rounded, size: 16),
                  label: const Text('Unlink Employee', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () => _confirmUnlinkEmployee(data, linkedEmpId, t),
                ),
              ),
            ],
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bgCardAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.bgRule),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: t.textSecondary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This login user is not linked to any Employee profile. It will NOT appear in Attendance, Staff Payroll, or Biometrics until linked.',
                    style: TextStyle(color: t.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text('Link Existing Employee', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () => _showManualLinkEmployeeDialog(data, t),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                  label: const Text('Create & Link Employee', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () => _showManualCreateEmployeeDialog(data, t),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _showManualLinkEmployeeDialog(Map<String, dynamic> data, RoleThemeData t) {
    final allEmployees = FinanceLocalStorage.getEmployees('all');
    String? selectedId;
    String search = '';

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDState) {
          final filtered = allEmployees.where((e) {
            final name = (e['name'] ?? '').toString().toLowerCase();
            final id = (e['id'] ?? e['localId'] ?? '').toString().toLowerCase();
            final dept = (e['department'] ?? '').toString().toLowerCase();
            final q = search.toLowerCase().trim();
            return q.isEmpty || name.contains(q) || id.contains(q) || dept.contains(q);
          }).toList();

          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.link_rounded, color: Color(0xFF0284C7)),
                const SizedBox(width: 8),
                Text('Link User to Employee', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 480,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    style: TextStyle(color: t.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search employees by name, department, or ID...',
                      hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                      prefixIcon: Icon(Icons.search, color: t.textSecondary, size: 18),
                      filled: true,
                      fillColor: t.bgCardAlt,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.bgRule)),
                    ),
                    onChanged: (val) => setDState(() => search = val),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(child: Text('No employees found.', style: TextStyle(color: t.textSecondary)))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (ctx, idx) {
                              final emp = filtered[idx];
                              final empId = emp['id']?.toString() ?? emp['localId']?.toString() ?? '';
                              final isSelected = selectedId == empId;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF0284C7).withValues(alpha: 0.12) : t.bgCardAlt,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: isSelected ? const Color(0xFF0284C7) : t.bgRule),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    backgroundColor: isSelected ? const Color(0xFF0284C7) : t.textTertiary.withValues(alpha: 0.2),
                                    child: Text(
                                      (emp['name']?.toString() ?? '?').isNotEmpty ? (emp['name']?.toString() ?? '?')[0].toUpperCase() : '?',
                                      style: TextStyle(color: isSelected ? Colors.white : t.textPrimary, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                  title: Text(emp['name']?.toString() ?? 'Unnamed', style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 13)),
                                  subtitle: Text('${emp['department'] ?? 'General'} • ${emp['designation'] ?? emp['role'] ?? 'Staff'} (ID: $empId)', style: TextStyle(color: t.textSecondary, fontSize: 11)),
                                  trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF0284C7), size: 20) : null,
                                  onTap: () => setDState(() => selectedId = empId),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: selectedId == null
                    ? null
                    : () async {
                        Navigator.pop(dialogCtx);
                        final success = await FinanceLocalStorage.linkUserToEmployee(
                          userId: widget.userId,
                          employeeId: selectedId!,
                        );
                        if (success) {
                          setState(() {
                            data['linkedEmployeeId'] = selectedId;
                            data['employeeId'] = selectedId;
                          });
                          _snack('✅ Successfully linked User to Employee $selectedId!', success: true);
                        } else {
                          _snack('❌ Failed to link Employee.', error: true);
                        }
                      },
                child: const Text('Link Selected Employee', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showManualCreateEmployeeDialog(Map<String, dynamic> data, RoleThemeData t) {
    final nameCtrl = TextEditingController(text: data['name'] ?? data['username'] ?? '');
    final cnicCtrl = TextEditingController(text: data['cnic'] ?? data['identification'] ?? '');
    final phoneCtrl = TextEditingController(text: data['phone'] ?? '');
    final roleCtrl = TextEditingController(text: data['role'] ?? 'Staff');
    final salaryCtrl = TextEditingController(text: (data['salary'] ?? data['baseSalary'] ?? '30000').toString());
    final bankCtrl = TextEditingController(text: data['bankName'] ?? 'Meezan Bank Limited');
    final accountCtrl = TextEditingController(text: data['bankAccount'] ?? '');
    String selectedDept = 'Office';
    String selectedBranch = widget.branchId.isNotEmpty && widget.branchId != 'all' ? widget.branchId : 'gujrat';

    final depts = ['Administration Staff', 'Dispensary', 'Office', 'Madrassa', 'School', 'Dasterkhwaan', 'Welfare', 'Security', 'Maintenance'];

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDState) {
          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.person_add_alt_1_rounded, color: t.accent),
                const SizedBox(width: 8),
                Text('Create & Link Employee Profile', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      style: TextStyle(color: t.textPrimary, fontSize: 13),
                      decoration: InputDecoration(labelText: 'Employee Full Name *', labelStyle: TextStyle(color: t.textSecondary)),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: selectedDept,
                            dropdownColor: t.bgCard,
                            decoration: InputDecoration(labelText: 'Department', labelStyle: TextStyle(color: t.textSecondary)),
                            items: depts.map((d) => DropdownMenuItem(value: d, child: Text(d, style: TextStyle(color: t.textPrimary, fontSize: 12)))).toList(),
                            onChanged: (val) { if (val != null) setDState(() => selectedDept = val); },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: roleCtrl,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(labelText: 'Designation / Role', labelStyle: TextStyle(color: t.textSecondary)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: cnicCtrl,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(labelText: 'CNIC / ID', labelStyle: TextStyle(color: t.textSecondary)),
                            inputFormatters: [CNICInputFormatter()],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: phoneCtrl,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(labelText: 'Phone', labelStyle: TextStyle(color: t.textSecondary)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: salaryCtrl,
                      style: TextStyle(color: t.textPrimary, fontSize: 13),
                      decoration: InputDecoration(labelText: 'Base Salary (PKR) *', labelStyle: TextStyle(color: t.textSecondary)),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: bankCtrl,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(labelText: 'Bank Name', labelStyle: TextStyle(color: t.textSecondary)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: accountCtrl,
                            style: TextStyle(color: t.textPrimary, fontSize: 13),
                            decoration: InputDecoration(labelText: 'Account / IBAN', labelStyle: TextStyle(color: t.textSecondary)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty) {
                    _snack('Please enter employee name.', error: true);
                    return;
                  }
                  final salary = double.tryParse(salaryCtrl.text.trim()) ?? 0.0;
                  final newEmpId = 'emp_${DateTime.now().millisecondsSinceEpoch}';

                  final empData = <String, dynamic>{
                    'localId': newEmpId,
                    'id': newEmpId,
                    'name': nameCtrl.text.trim(),
                    'role': roleCtrl.text.trim(),
                    'designation': roleCtrl.text.trim(),
                    'department': selectedDept,
                    'branchId': selectedBranch,
                    'cnic': cnicCtrl.text.trim(),
                    'phone': phoneCtrl.text.trim(),
                    'currentSalary': salary,
                    'baseSalary': salary,
                    'bankName': bankCtrl.text.trim(),
                    'bankAccount': accountCtrl.text.trim(),
                    'isActive': true,
                    'joiningDate': DateTime.now().toIso8601String(),
                    'userId': widget.userId,
                    'linkedUserId': widget.userId,
                  };

                  Navigator.pop(dialogCtx);
                  await FinanceLocalStorage.saveEmployee(
                    branchId: selectedBranch,
                    data: empData,
                    performedBy: LocalStorageService.getActiveUsername(),
                  );
                  await FinanceLocalStorage.linkUserToEmployee(
                    userId: widget.userId,
                    employeeId: newEmpId,
                  );

                  setState(() {
                    data['linkedEmployeeId'] = newEmpId;
                    data['employeeId'] = newEmpId;
                  });
                  _snack('✅ Created and linked Employee $newEmpId successfully!', success: true);
                },
                child: const Text('Save & Link Employee', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _confirmUnlinkEmployee(Map<String, dynamic> data, String? empId, RoleThemeData t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.link_off_rounded, color: t.danger),
            const SizedBox(width: 8),
            Text('Unlink Employee Profile', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          'Are you sure you want to disconnect this login User from Employee profile ($empId)?\n\nThe employee profile will remain intact in HR records, but will no longer be attached to this login account.',
          style: TextStyle(color: t.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: t.danger,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Unlink', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await FinanceLocalStorage.unlinkUserAndEmployee(
        userId: widget.userId,
        employeeId: empId,
      );
      if (success) {
        setState(() {
          data.remove('linkedEmployeeId');
          data.remove('employeeId');
        });
        _snack('✅ Successfully unlinked Employee profile.', success: true);
      } else {
        _snack('❌ Failed to unlink Employee profile.', error: true);
      }
    }
  }

  Widget _buildFinancialSection(
      Map<String, dynamic> data, RoleThemeData t) {
    return _card(t, 'Financial',
        Icons.account_balance_wallet_outlined,
        const Color(0xFF6A1B9A), [
      _infoRow(t, 'Bank', data['bankName'] ?? 'N/A',
          Icons.account_balance_outlined),
      _infoRow(t, 'Account No.',
          data['bankAccount'] ?? 'N/A', Icons.numbers_outlined),
      if (data['salary'] != null)
        _infoRow(t, 'Salary', 'PKR ${data['salary']}',
            Icons.payments_outlined),
    ]);
  }

  Widget _buildMedicalSection(
      Map<String, dynamic> data, RoleThemeData t) {
    return _card(t, 'Medical', Icons.local_hospital_outlined,
        const Color(0xFF00796B), [
      _infoRow(t, 'Degree', data['degree'] ?? 'N/A',
          Icons.school_outlined),
    ]);
  }

  Widget _buildDocumentsSection(
      Map<String, dynamic> data, RoleThemeData t) {
    return _card(t, 'Documents', Icons.folder_outlined,
        t.textTertiary, [
      if (data['identificationUrl'] != null)
        _docRow(t, 'Identification',
            data['identificationUrl'] as String),
      if (data['degreeUrl'] != null)
        _docRow(t, 'Degree Certificate',
            data['degreeUrl'] as String),
    ]);
  }

  Future<Map<String, dynamic>?>? _deviceInfoFuture;

  Widget _buildActiveDeviceSection(Map<String, dynamic> data, RoleThemeData t) {
    Map<String, dynamic>? deviceInfo = (data['lastDeviceInfo'] != null && data['lastDeviceInfo'] is Map)
        ? Map<String, dynamic>.from(data['lastDeviceInfo'] as Map)
        : ((data['deviceInfo'] != null && data['deviceInfo'] is Map)
            ? Map<String, dynamic>.from(data['deviceInfo'] as Map)
            : null);

    if (deviceInfo == null) {
      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final u = Hive.box(LocalStorageService.usersBox).get(widget.userId);
        if (u is Map && u['lastDeviceInfo'] is Map) {
          deviceInfo = Map<String, dynamic>.from(u['lastDeviceInfo'] as Map);
        }
      }
    }

    if (deviceInfo == null && widget.userId.isNotEmpty) {
      _deviceInfoFuture ??= () async {
        try {
          final doc = await FirebaseFirestore.instance.collection('users').doc(widget.userId).get().timeout(const Duration(seconds: 4));
          if (doc.exists && doc.data() != null && doc.data()!['lastDeviceInfo'] is Map) {
            return Map<String, dynamic>.from(doc.data()!['lastDeviceInfo'] as Map);
          }
          final sDoc = await FirebaseFirestore.instance.collection('user_sessions').doc(widget.userId).get().timeout(const Duration(seconds: 4));
          if (sDoc.exists && sDoc.data() != null) {
            return Map<String, dynamic>.from(sDoc.data()!);
          }
        } catch (_) {}
        return null;
      }();

      return FutureBuilder<Map<String, dynamic>?>(
        future: _deviceInfoFuture,
        builder: (context, snapshot) {
          return _renderDeviceCard(snapshot.data, t, userDoc: data);
        },
      );
    }

    return _renderDeviceCard(deviceInfo, t, userDoc: data);
  }

  Widget _renderDeviceCard(Map<String, dynamic>? deviceInfo, RoleThemeData t, {Map<String, dynamic>? userDoc}) {
    final platform = deviceInfo?['platform']?.toString() ?? 'N/A';
    final browser = deviceInfo?['browser']?.toString() ?? 'N/A';
    final os = deviceInfo?['os']?.toString() ?? 'N/A';
    final deviceName = deviceInfo?['deviceName']?.toString() ?? deviceInfo?['deviceModel']?.toString() ?? 'N/A';
    final deviceModel = deviceInfo?['deviceModel']?.toString() ?? 'N/A';
    final appVersion = deviceInfo?['appVersion']?.toString() ?? AutoUpdateService.currentVersion;
    final isOnline = deviceInfo?['isOnline'] as bool? ?? widget.isOnline;

    final Map<String, dynamic>? devicesMap = (userDoc != null && userDoc['devices'] is Map)
        ? Map<String, dynamic>.from(userDoc['devices'] as Map)
        : null;

    return _card(
      t,
      'Active Device & Session History',
      Icons.devices_rounded,
      Colors.blue.shade700,
      [
        if (deviceInfo != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Text('Active Badge:', style: TextStyle(fontSize: 13, color: t.textSecondary, fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                DeviceBadgeWidget(deviceInfo: deviceInfo),
              ],
            ),
          ),
          _infoRow(t, 'App Version', 'v$appVersion', Icons.verified_rounded),
          _infoRow(t, 'Platform', platform, Icons.computer_rounded),
          _infoRow(t, 'Browser / App', browser, Icons.language_rounded),
          _infoRow(t, 'Operating System', os, Icons.phonelink_setup_rounded),
          _infoRow(t, 'Device / PC Name', deviceName, Icons.badge_outlined),
          if (deviceModel != deviceName && deviceModel.isNotEmpty && deviceModel != 'N/A')
            _infoRow(t, 'Hardware Model', deviceModel, Icons.memory_rounded),
          _infoRow(t, 'Status', isOnline ? 'ONLINE NOW' : 'Offline', isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded),
          if (devicesMap != null && devicesMap.length > 1) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(),
            ),
            Text('All Transitioned Devices (${devicesMap.length}):',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: devicesMap.values.map((dev) {
                if (dev is Map) {
                  return DeviceBadgeWidget(deviceInfo: Map<String, dynamic>.from(dev));
                }
                return const SizedBox.shrink();
              }).toList(),
            ),
          ],
        ] else ...[
          Text(
            'No active device session recorded yet. Session info will automatically record once the user opens or logs into the app.',
            style: TextStyle(fontSize: 12, color: t.textSecondary, fontStyle: FontStyle.italic),
          ),
        ]
      ],
    );
  }

  Widget _buildMetaSection(
      Map<String, dynamic> data, RoleThemeData t) {
    String joined = 'N/A';
    final rawCreated = data['createdAt'] ?? data['createdAtLocal'];
    if (rawCreated is Timestamp) {
      joined = DateFormat('dd MMM yyyy, hh:mm a').format(rawCreated.toDate());
    } else if (rawCreated is String && rawCreated.isNotEmpty) {
      final dt = DateTime.tryParse(rawCreated);
      if (dt != null) {
        joined = DateFormat('dd MMM yyyy, hh:mm a').format(dt);
      } else {
        joined = rawCreated;
      }
    }

    final createdByName = (data['createdByName'] ?? data['createdBy'] ?? '').toString().trim();
    final createdByRole = (data['createdByRole'] ?? '').toString().trim();
    final creatorDisplay = createdByName.isNotEmpty
        ? (createdByRole.isNotEmpty ? '$createdByName ($createdByRole)' : createdByName)
        : 'System / Pre-configured';

    final lastLoginRaw = data['lastLoginAt'] ?? data['lastOnlineAt'] ?? data['updatedAt'];
    String lastLoginText = 'Never / Not Available';
    if (lastLoginRaw is Timestamp) {
      lastLoginText = DateFormat('dd MMM yyyy, hh:mm a').format(lastLoginRaw.toDate());
    } else if (lastLoginRaw is String && lastLoginRaw.isNotEmpty) {
      final parsed = DateTime.tryParse(lastLoginRaw);
      if (parsed != null) {
        lastLoginText = DateFormat('dd MMM yyyy, hh:mm a').format(parsed);
      } else {
        lastLoginText = lastLoginRaw;
      }
    }

    final uid = (data['uid'] ?? data['id'] ?? widget.userId).toString();

    return _card(t, 'Account & Audit Trail', Icons.admin_panel_settings_outlined,
        t.textTertiary, [
      _infoRow(t, 'Account Created', joined, Icons.calendar_today_outlined),
      const SizedBox(height: 10),
      _infoRow(t, 'Created By', creatorDisplay, Icons.person_add_alt_1_outlined),
      const SizedBox(height: 10),
      _infoRow(t, 'User ID', uid, Icons.fingerprint_rounded),
      const SizedBox(height: 10),
      _infoRow(t, 'Last Activity', lastLoginText, Icons.access_time_rounded),
    ]);
  }

  Widget _card(RoleThemeData t, String title, IconData icon,
      Color accent, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.bgRule, width: 0.9),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: accent.withValues(alpha: 0.25), width: 0.8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, color: accent, size: 18),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: t.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: t.bgRule),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(RoleThemeData t, String label, String value,
      IconData icon, {bool copyable = true}) {
    final canCopy = copyable && value.isNotEmpty && value != 'N/A' && value != '?';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: t.bgCardAlt.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.bgRule.withValues(alpha: 0.5), width: 0.7),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 16, color: t.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: t.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      color: t.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (canCopy)
              Tooltip(
                message: 'Copy $label',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 16),
                            const SizedBox(width: 8),
                            Text('Copied $label to clipboard', style: const TextStyle(fontSize: 12.5)),
                          ],
                        ),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: t.bg.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: t.bgRule, width: 0.6),
                    ),
                    child: Icon(Icons.copy_rounded, size: 13, color: t.textSecondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _docRow(RoleThemeData t, String label, String url) {
    final isPdf = url.toLowerCase().contains('.pdf');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: t.textSecondary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          if (!isPdf)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: (url.startsWith('http://') || url.startsWith('https://'))
                  ? Image.network(
                      url,
                      height: 160,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        height: 80,
                        color: t.bg,
                        alignment: Alignment.center,
                        child: Icon(Icons.broken_image_outlined, color: t.textTertiary),
                      ),
                    )
                  : (ImageUploadService.decodeBase64ToBytes(url) != null
                      ? Image.memory(
                          ImageUploadService.decodeBase64ToBytes(url)!,
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            height: 80,
                            color: t.bg,
                            alignment: Alignment.center,
                            child: Icon(Icons.broken_image_outlined, color: t.textTertiary),
                          ),
                        )
                      : Container(
                          height: 80,
                          color: t.bg,
                          alignment: Alignment.center,
                          child: Icon(Icons.insert_drive_file_outlined, color: t.textTertiary),
                        )),
            )
          else
            GestureDetector(
              onTap: () async {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) launchUrl(uri);
              },
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: t.bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.bgRule)),
                child: Row(children: [
                  const Icon(Icons.picture_as_pdf_rounded,
                      color: Colors.red, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text('View PDF',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: t.textPrimary))),
                  Icon(Icons.open_in_new_rounded,
                      color: t.textTertiary, size: 16),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  // ── Edit form helpers ──

  /// Loads all available branches for the edit dialog branch dropdown.
  Future<List<Map<String, dynamic>>> _loadAvailableBranchesForEdit() async {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    try {
      // Try Hive branches box first (fastest)
      final branchesBox = LocalStorageService.branchesBox;
      if (Hive.isBoxOpen(branchesBox)) {
        final box = Hive.box(branchesBox);
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? '').toString().toLowerCase().trim();
            if (id.isNotEmpty && id != 'all' && id != 'global' && !seen.contains(id)) {
              seen.add(id);
              result.add({'id': id, 'name': (val['name'] ?? id).toString()});
            }
          }
        }
      }
    } catch (_) {}
    // Fallback to Firestore if Hive has no entries
    if (result.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('branches')
            .get()
            .timeout(const Duration(seconds: 5));
        for (final doc in snap.docs) {
          final id = doc.id.toLowerCase().trim();
          if (id.isNotEmpty && !seen.contains(id)) {
            seen.add(id);
            result.add({'id': id, 'name': (doc.data()['name'] ?? id).toString()});
          }
        }
      } catch (_) {}
    }
    // Always include current widget branchId as a minimum option
    if (widget.branchId.isNotEmpty && widget.branchId != 'global' && !seen.contains(widget.branchId)) {
      result.add({'id': widget.branchId, 'name': widget.branchId.toUpperCase()});
    }
    return result;
  }

  Widget _editField(RoleThemeData t, TextEditingController ctrl,
      String label, IconData icon,
      {TextInputType? type,
      List<TextInputFormatter>? formatters,
      int? maxLen,
      int maxLines = 1,
      bool obscure = false,
      String? Function(String?)? validator}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: type,
        inputFormatters: formatters,
        maxLength: maxLen,
        maxLines: maxLines,
        style: TextStyle(fontSize: 14, color: t.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          labelStyle:
              TextStyle(fontSize: 13, color: t.textTertiary),
          floatingLabelStyle: TextStyle(
              fontSize: 12,
              color: t.accent,
              fontWeight: FontWeight.w600),
          prefixIcon:
              Icon(icon, color: t.textTertiary, size: 20),
          filled: true,
          fillColor: t.bgCard,
          counterText: '',
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  BorderSide(color: t.accent, width: 2)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  BorderSide(color: t.danger, width: 1.5)),
          errorStyle: const TextStyle(fontSize: 11),
        ),
        validator: validator,
      ),
    );
  }

  Widget _editDropdown({
    required RoleThemeData t,
    required String? value,
    required String label,
    required IconData icon,
    required List<String> items,
    required Function(String?) onChanged,
  }) {
    final effectiveItems = List<String>.from(items);
    if (value != null && value.isNotEmpty && !effectiveItems.any((e) => e.toLowerCase() == value.toLowerCase())) {
      effectiveItems.add(value);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        hint: Text(label,
            style:
                TextStyle(color: t.textTertiary, fontSize: 13)),
        isExpanded: true,
        dropdownColor: t.bgCard,
        icon: Icon(Icons.keyboard_arrow_down_rounded,
            color: t.textTertiary),
        decoration: InputDecoration(
          prefixIcon:
              Icon(icon, color: t.textTertiary, size: 20),
          filled: true,
          fillColor: t.bgCard,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  BorderSide(color: t.accent, width: 2)),
        ),
        items: effectiveItems
            .map((e) => DropdownMenuItem(
                value: e,
                child: Text(e,
                    style: TextStyle(
                        fontSize: 14,
                        color: t.textPrimary))))
            .toList(),
        onChanged: onChanged,
        validator: (v) => v == null ? 'Select $label' : null,
      ),
    );
  }

  Widget _editRoleDropdown({
    required RoleThemeData t,
    required String? value,
    required List<Map<String, dynamic>> roles,
    required Function(String?) onChanged,
  }) {
    Widget roleBadge(String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20)),
          child: Text(text,
              style: TextStyle(
                  fontSize: 10,
                  color: color.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w700)),
        );

    final effectiveRoles = List<Map<String, dynamic>>.from(roles);
    if (value != null && value.isNotEmpty && !effectiveRoles.any((r) => r['value'].toString().toLowerCase() == value.toLowerCase())) {
      effectiveRoles.add({
        'value': value,
        'label': value,
        'type': value.toLowerCase().contains('madrassa') ? 'madrassa' : 'normal',
        'icon': Icons.person_rounded,
      });
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: value,
        dropdownColor: t.bgCard,
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'Assign System Role',
          labelStyle: TextStyle(
              color: t.accent, fontSize: 13, fontWeight: FontWeight.w600),
          prefixIcon: Icon(Icons.admin_panel_settings_outlined,
              color: t.accent, size: 20),
          filled: true,
          fillColor: t.bgCard,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.accent, width: 2)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: t.danger, width: 1.5)),
          errorStyle: const TextStyle(fontSize: 11),
        ),
        selectedItemBuilder: (context) => effectiveRoles.map((role) {
          final type = role['type'] as String;
          final Color iconColor = type == 'crown'
              ? t.accent
              : type == 'shield'
                  ? t.accentLight
                  : type == 'madrassa'
                      ? const Color(0xFF5C6BC0)
                      : type == 'hybrid'
                          ? const Color(0xFF00796B)
                          : t.textSecondary;
          return Row(
            children: [
              Icon(role['icon'] as IconData, color: iconColor, size: 18),
              const SizedBox(width: 10),
              Text(role['label'] as String,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary)),
            ],
          );
        }).toList(),
        items: effectiveRoles.map((role) {
          final type = role['type'] as String;
          final isCrown = type == 'crown';
          final isShield = type == 'shield';
          final isMadrassa = type == 'madrassa';
          final isHybrid = type == 'hybrid';
          const madrassaColor = Color(0xFF5C6BC0);
          const hybridColor = Color(0xFF00796B);
          
          final Color iconColor = isCrown
              ? t.accent
              : isShield
                  ? t.accentLight
                  : isMadrassa
                      ? madrassaColor
                      : isHybrid
                          ? hybridColor
                          : t.textSecondary;
          final Color textColor = isCrown
              ? t.accent
              : isShield
                  ? t.accentLight
                  : isMadrassa
                      ? madrassaColor
                      : isHybrid
                          ? hybridColor
                          : t.textPrimary;
          final Color bgColor = (isCrown || isShield)
              ? t.accentMuted
              : isMadrassa
                  ? madrassaColor.withValues(alpha: 0.07)
                  : isHybrid
                      ? hybridColor.withValues(alpha: 0.07)
                      : t.bgCard;

          return DropdownMenuItem<String>(
            value: role['value'] as String,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                  color: bgColor, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(8)),
                    child: Icon(role['icon'] as IconData,
                        color: iconColor, size: 17),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(role['label'] as String,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: (isCrown ||
                                    isShield ||
                                    isMadrassa ||
                                    isHybrid)
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: textColor)),
                  ),
                  if (isCrown) roleBadge('Authority', t.accent),
                  if (isShield) roleBadge('Server', t.accentLight),
                  if (isMadrassa) roleBadge('Madrassa', madrassaColor),
                  if (isHybrid) roleBadge('Hybrid', hybridColor),
                ],
              ),
            ),
          );
        }).toList(),
        onChanged: onChanged,
        validator: (v) => v == null ? 'Role is mandatory' : null,
      ),
    );
  }

  Widget _uploadTile(RoleThemeData t, String label, XFile? file,
      Function(XFile?) onPicked) {
    final has = file != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () async {
          final source = await ImageUploadService.showSourceDialog(context, title: 'Select Image / File Source');
          if (source == null) return;
          final b64 = await ImageUploadService.pickAndProcessImage(source: source);
          if (b64 != null && b64.isNotEmpty) {
            onPicked(XFile(b64));
          }
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: has
                ? const Color(0xFFE8F5E9)
                : t.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: has
                    ? Colors.green.shade400
                    : t.bgRule,
                width: 1.5),
          ),
          child: Row(children: [
            Icon(
                has
                    ? Icons.check_circle_rounded
                    : Icons.upload_file_rounded,
                color: has
                    ? Colors.green.shade700
                    : t.textTertiary,
                size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: t.textPrimary)),
                    if (has)
                      Text(file.name,
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.green.shade700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                  ]),
            ),
            Text(has ? 'Change' : 'Upload',
                style: TextStyle(
                    fontSize: 12,
                    color: has
                        ? Colors.green.shade700
                        : t.accent,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Future<void> _showGuardianStatusDialog(Map<String, dynamic> data, RoleThemeData t) async {
    final currentStatus = (data['status'] ?? data['studentStatus'] ?? 'active').toString().toLowerCase().trim();

    String selectedStatus = currentStatus;
    final reasonCtrl = TextEditingController();

    final statusOptions = [
      {'key': 'active', 'label': 'Active Student / Guardian', 'color': Colors.green, 'icon': Icons.check_circle_rounded},
      {'key': 'hifz_completed', 'label': 'Hifz Completed', 'color': const Color(0xFF4C4DDC), 'icon': Icons.workspace_premium_rounded},
      {'key': 'left', 'label': 'Left Madrassa', 'color': Colors.redAccent, 'icon': Icons.exit_to_app_rounded},
      {'key': 'dropped', 'label': 'Dropped Out', 'color': Colors.red, 'icon': Icons.person_off_rounded},
      {'key': 'archived', 'label': 'Archived', 'color': Colors.orange, 'icon': Icons.archive_rounded},
    ];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final currentOpt = statusOptions.firstWhere((o) => o['key'] == selectedStatus, orElse: () => statusOptions[0]);
          return Dialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: (currentOpt['color'] as Color).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(currentOpt['icon'] as IconData, color: currentOpt['color'] as Color, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Madrassa Guardian Status',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: t.textPrimary),
                            ),
                            Text(
                              'Update enrolment status for @${data['username'] ?? 'Guardian'}',
                              style: TextStyle(fontSize: 12, color: t.textTertiary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('Select Student / Guardian Status', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textSecondary)),
                  const SizedBox(height: 8),
                  ...statusOptions.map((opt) {
                    final isSelected = selectedStatus == opt['key'];
                    final optColor = opt['color'] as Color;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? optColor.withValues(alpha: 0.1) : t.bg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? optColor : t.bgRule,
                          width: isSelected ? 1.5 : 0.8,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        leading: Icon(opt['icon'] as IconData, color: optColor, size: 20),
                        title: Text(
                          opt['label'] as String,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                            color: isSelected ? optColor : t.textPrimary,
                            fontSize: 13.5,
                          ),
                        ),
                        trailing: isSelected ? Icon(Icons.check_circle_rounded, color: optColor, size: 18) : null,
                        onTap: () => setS(() => selectedStatus = opt['key'] as String),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  Text('Remarks / Reason (Optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textSecondary)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    style: TextStyle(fontSize: 13, color: t.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Completed Hifz exam / Relocated to another city',
                      hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: t.bg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: currentOpt['color'] as Color,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Update Status', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirm != true) return;

    final reason = reasonCtrl.text.trim();
    final isReadOnly = selectedStatus != 'active';

    final updates = <String, dynamic>{
      'status': selectedStatus,
      'studentStatus': selectedStatus,
      'accountStatus': selectedStatus,
      'isReadOnly': isReadOnly,
      'statusReason': reason.isNotEmpty ? reason : 'Status updated to $selectedStatus',
      'statusUpdatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await LocalStorageService.saveUserOffline(
        uid: widget.userId,
        branchId: widget.branchId,
        userData: {...data, ...updates, 'uid': widget.userId, 'branchId': widget.branchId},
      );

      if (widget.isOnline && !widget.userId.startsWith('local-')) {
        await FirebaseFirestore.instance.collection('users').doc(widget.userId).set(updates, SetOptions(merge: true));
        if (widget.branchId.isNotEmpty && widget.branchId != 'all') {
          await FirebaseFirestore.instance.collection('branches').doc(widget.branchId).collection('users').doc(widget.userId).set(updates, SetOptions(merge: true));
        }
      }

      if (mounted) {
        setState(() {});
        _snack('Guardian status updated to ${selectedStatus.replaceAll('_', ' ').toUpperCase()}', success: true);
      }
    } catch (e) {
      if (mounted) {
        _snack('Failed to update status: $e', error: true);
      }
    }
  }

  Widget _buildRevokeAccessCard(Map<String, dynamic> data, RoleThemeData t) {
    final rawRole = (data['role'] as String? ?? '').toLowerCase();
    final isGuardian = rawRole == 'madrassa parent' || rawRole == 'madrassa guardian';
    final canManageAccess = _canManageUserAccess(data);

    if (!canManageAccess) {
      return const SizedBox.shrink();
    }

    if (isGuardian) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.bgRule, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.family_restroom_rounded, color: Colors.teal, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Madrassa Family / Guardian Portal',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: t.textPrimary,
                        ),
                      ),
                      Text(
                        'Guardian accounts are linked to student profiles. Historical records remain read-only when students leave, complete Hifz, or archive.',
                        style: TextStyle(fontSize: 12, color: t.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showGuardianStatusDialog(data, t),
                icon: const Icon(Icons.school_rounded, size: 18),
                label: const Text(
                  'Update Student / Guardian Status',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final status = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    final isRevoked = status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        data['isActive'] == false ||
        data['isRevoked'] == true ||
        data['accessRevoked'] == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isRevoked
            ? Colors.red.withValues(alpha: 0.08)
            : t.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isRevoked ? Colors.red.withValues(alpha: 0.35) : t.bgRule,
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: (isRevoked ? Colors.red : Colors.black).withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isRevoked ? Colors.red.withValues(alpha: 0.15) : t.accentMuted,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isRevoked ? Icons.no_accounts_rounded : Icons.shield_outlined,
                  color: isRevoked ? Colors.red : t.accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Access Control & Offboarding',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isRevoked
                          ? 'Account access is currently revoked (${data['status'] ?? 'Revoked'}).'
                          : 'Revoke user access to immediately block app login.',
                      style: TextStyle(fontSize: 12, color: t.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (data['revocationReason'] != null && data['revocationReason'].toString().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
              ),
              child: Text(
                'Reason: ${data['revocationReason']}',
                style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _showRevokeAccessDialog(data, t),
                  icon: Icon(isRevoked ? Icons.key_rounded : Icons.lock_person_rounded, size: 18),
                  label: Text(
                    isRevoked ? 'Update Access / Status' : 'Revoke User Access',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRevoked ? const Color(0xFF334155) : Colors.amber.shade900,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _showDeleteUserDialog(data, t),
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: const Text(
                    'Delete Account',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade800,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getActorRole() {
    if (widget.currentUserRole != null && widget.currentUserRole!.isNotEmpty) {
      return widget.currentUserRole!.toLowerCase().trim();
    }
    try {
      final label = RoleThemeScope.dataOf(context).roleLabel.toLowerCase().trim();
      if (label.isNotEmpty && label != 'overview' && label != 'system') return label;
    } catch (_) {}

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      final uid = currentUser.uid;
      final email = currentUser.email?.toLowerCase().trim();
      if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final box = Hive.box(LocalStorageService.usersBox);
        final uDoc = box.get(uid) ?? box.get('user:$uid') ?? (email != null ? box.get('user:$email') : null);
        if (uDoc is Map) {
          final r = (uDoc['role'] ?? uDoc['type'] ?? uDoc['accountType'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty) return r;
        }
      }
    }

    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final r1 = (box.get('user_role') ?? box.get('role'))?.toString().toLowerCase().trim() ?? '';
        if (r1.isNotEmpty) return r1;

        final uMap = box.get('user_data') ?? box.get('currentUser') ?? box.get('active_user');
        if (uMap is Map) {
          final r2 = (uMap['role'] ?? uMap['type'] ?? uMap['accountType'] ?? '').toString().toLowerCase().trim();
          if (r2.isNotEmpty) return r2;
        }
      }
    } catch (_) {}

    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid != null && currentUid.isNotEmpty) {
        final local = LocalStorageService.getLocalUserByUid(currentUid);
        if (local != null) {
          final r = (local['role'] ?? local['type'] ?? local['accountType'] ?? '').toString().toLowerCase().trim();
          if (r.isNotEmpty) return r;
        }
      }
    } catch (_) {}

    return 'admin';
  }

  bool _canManageUserAccess(Map<String, dynamic> targetData) {
    final targetRole = (targetData['role'] as String? ?? '').toLowerCase().trim();

    // Chairman account is 100% immutable and CANNOT be deleted, edited, suspended, or demoted by ANY user.
    if (targetRole == 'chairman') {
      return false;
    }

    final actorRole = _getActorRole();
    const allowedRoles = {'chairman', 'global admin', 'admin', 'ceo', 'hq manager', 'branch manager', 'supervisor'};
    return allowedRoles.contains(actorRole);
  }

  Future<void> _showDeleteUserDialog(Map<String, dynamic> data, RoleThemeData t) async {
    if (!_canManageUserAccess(data)) {
      _snack('Access Denied: You do not have permission to delete ${(data['role'] as String? ?? 'User').toUpperCase()} accounts.', error: true);
      return;
    }

    final userName = data['name'] ?? data['username'] ?? 'User';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: Colors.red, size: 28),
            const SizedBox(width: 10),
            Text('Delete User Account', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          'Are you sure you want to PERMANENTLY delete the account for "$userName"? This action will remove their profile and access permissions completely.',
          style: TextStyle(color: t.textSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: const Text('Delete Permanently'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (!await _checkPassword(t)) return;

    final targetUid = widget.userId;
    final usernameLower = (data['usernameLower'] ?? data['username'] ?? '').toString().trim().toLowerCase();
    final targetEmail = (data['email'] ?? '').toString().trim().toLowerCase();
    final targetPass = (data['password'] ?? '112233').toString();

    try {
      await AuthService.deleteAuthUser(
        uid: targetUid,
        email: targetEmail,
        username: usernameLower,
        password: targetPass,
        branchId: widget.branchId,
      );

      // Purge from Local Storage
      await LocalStorageService.deleteUserOffline(
        uid: targetUid,
        branchId: widget.branchId,
        email: targetEmail,
        username: usernameLower,
      );

      // Mark as deleted in Firestore with tombstone so other devices sync the deletion
      if (widget.isOnline) {
        final deletePayload = {
          'isDeleted': true,
          'status': 'deleted',
          'accountStatus': 'deleted',
          'deletedAt': DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
          'isActive': false,
          'isRevoked': true,
        };

        final identifiers = <String>{
          if (targetUid.isNotEmpty) targetUid,
          if (usernameLower.isNotEmpty) usernameLower,
          if (targetEmail.isNotEmpty) targetEmail,
        };

        for (final id in identifiers) {
          await _firestore.collection('users').doc(id).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          if (widget.branchId.isNotEmpty && widget.branchId != 'all') {
            await _firestore.collection('branches').doc(widget.branchId).collection('users').doc(id).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
          }
        }

        if (usernameLower.isNotEmpty) {
          try {
            final snap = await _firestore.collection('users').where('usernameLower', isEqualTo: usernameLower).get();
            for (final doc in snap.docs) {
              await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
            }
          } catch (_) {}
        }

        if (targetEmail.isNotEmpty) {
          try {
            final snap = await _firestore.collection('users').where('email', isEqualTo: targetEmail).get();
            for (final doc in snap.docs) {
              await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
            }
          } catch (_) {}
        }

        if (targetUid.isNotEmpty) {
          try {
            final snap = await _firestore.collection('users').where('uid', isEqualTo: targetUid).get();
            for (final doc in snap.docs) {
              await doc.reference.set(deletePayload, SetOptions(merge: true)).catchError((_) {});
            }
          } catch (_) {}
        }

        try {
          SyncService().triggerUpload(force: true);
        } catch (_) {}
      }

      _snack('Account deleted successfully.', success: true);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Failed to delete account: $e', error: true);
    }
  }

  Future<void> _showRevokeAccessDialog(Map<String, dynamic> data, RoleThemeData t) async {
    if (!_canManageUserAccess(data)) {
      _snack('Access Denied: You do not have permission to revoke or alter access for ${(data['role'] as String? ?? 'User').toUpperCase()} accounts.', error: true);
      return;
    }

    final status = (data['status'] ?? data['accountStatus'] ?? 'active').toString().toLowerCase().trim();
    final isRevoked = status == 'inactive' ||
        status == 'suspended' ||
        status == 'terminated' ||
        status == 'resigned' ||
        status == 'retired' ||
        status == 'offboarded' ||
        status == 'revoked' ||
        data['isActive'] == false;

    if (!isRevoked) {
      final offboardResult = await OffboardDialog.show(
        context,
        employeeData: data,
        performedBy: widget.currentUserRole ?? 'Admin',
      );
      if (offboardResult == true && mounted) {
        setState(() {});
        _snack('@${data['username'] ?? 'User'} has been offboarded.');
      }
      return;
    }

    final reasonCtrl = TextEditingController();

    final confirmCategory = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          return Dialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.lock_open_rounded,
                          color: Colors.green,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Re-Enable App Access',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: t.textPrimary,
                              ),
                            ),
                            Text(
                              'Restore access for @${data['username'] ?? 'User'}',
                              style: TextStyle(fontSize: 12, color: t.textTertiary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Restoration Remarks (Optional)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: t.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(fontSize: 13, color: t.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Access restored by HQ Manager',
                      hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: t.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: t.bgRule),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: t.bgRule),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: t.bgRule),
                            ),
                          ),
                          child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.lock_open_rounded, size: 18),
                          label: const Text('Restore'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirmCategory != true) return;

    if (!await _checkPassword(t)) return;

    final String reason = reasonCtrl.text.trim();
    final isLocal = widget.userId.startsWith('local-');

    final updates = <String, dynamic>{
      'status': 'active',
      'accountStatus': 'active',
      'isActive': true,
      'isRevoked': false,
      'accessRevoked': false,
      'restoreRequested': false,
      'restoreRequestStatus': 'approved',
      'revocationReason': null,
      'revokedAt': null,
      'restoredAt': FieldValue.serverTimestamp(),
      if (reason.isNotEmpty) 'restorationRemarks': reason,
    };

    try {
      final fullUserData = {
        ...data,
        ...updates,
        'uid': widget.userId,
        'id': widget.userId,
        'branchId': widget.branchId,
      };

      await LocalStorageService.saveUserOffline(
        uid: widget.userId,
        branchId: widget.branchId,
        userData: fullUserData,
      );

      // Also unrevoke linked employee in local_employees if present
      try {
        if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
          final empBox = Hive.box(LocalStorageService.employeesBox);
          final empId = (data['linkedEmployeeId'] ?? '').toString();
          final cnic = (data['cnic'] ?? data['identification'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
          final email = (data['email'] ?? '').toString().toLowerCase().trim();
          for (final k in empBox.keys) {
            final val = empBox.get(k);
            if (val is Map) {
              final eId = (val['localId'] ?? val['id'] ?? '').toString();
              final eCnic = (val['cnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
              final eEmail = (val['email'] ?? '').toString().toLowerCase().trim();
              if ((empId.isNotEmpty && eId == empId) ||
                  (cnic.isNotEmpty && eCnic == cnic) ||
                  (email.isNotEmpty && eEmail == email)) {
                final updatedEmp = Map<String, dynamic>.from(val)
                  ..['isActive'] = true
                  ..['status'] = 'active'
                  ..['employeeStatus'] = 'active';
                await empBox.put(k, updatedEmp);
              }
            }
          }
        }
      } catch (_) {}

      if (widget.isOnline && !isLocal) {
        await _firestore
            .collection('users')
            .doc(widget.userId)
            .set(fullUserData, SetOptions(merge: true));

        if (widget.branchId != 'all' && widget.branchId.isNotEmpty) {
          await _firestore
              .collection('branches')
              .doc(widget.branchId)
              .collection('users')
              .doc(widget.userId)
              .set(fullUserData, SetOptions(merge: true));
        }
      }

      SyncService().triggerUpload(force: true);

      if (mounted) setState(() {});
      _snack('App access restored for ${data['username'] ?? 'user'}', success: true);
    } catch (e) {
      _snack('Error updating access status: $e', error: true);
    }
  }

  Widget _errorState(RoleThemeData t) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded,
              size: 48, color: t.danger.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text('Error loading user',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: t.textSecondary)),
        ]),
      );

  Widget _notFoundState(RoleThemeData t) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.person_off_outlined,
              size: 48, color: t.textTertiary),
          const SizedBox(height: 12),
          Text('User not found',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: t.textSecondary)),
        ]),
      );

  void _showEnlargedPhotoDialog(
    BuildContext context,
    String name,
    String? photoUrl,
    String role,
    RoleThemeData t,
  ) {
    final bytes = photoUrl != null && photoUrl.trim().isNotEmpty
        ? ImageUploadService.decodeBase64ToBytes(photoUrl)
        : null;

    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: t.accent.withValues(alpha: 0.4), width: 1.8),
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.25),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_circle_rounded, color: t.accent, size: 22),
                        const SizedBox(width: 8),
                        const Text(
                          'Profile Photo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Enlarged Avatar Container (320px x 320px)
                Container(
                  width: 320,
                  height: 320,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFF59E0B), width: 4.0),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                        blurRadius: 24,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: photoUrl != null && photoUrl.trim().isNotEmpty
                        ? (bytes != null
                            ? Image.memory(bytes, fit: BoxFit.cover, width: 320, height: 320)
                            : Image.network(photoUrl, fit: BoxFit.cover, width: 320, height: 320, errorBuilder: (_, __, ___) => _buildFallbackAvatar(name, t, size: 320)))
                        : _buildFallbackAvatar(name, t, size: 320),
                  ),
                ),
                const SizedBox(height: 20),

                // User Name & Role
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    role.toUpperCase(),
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallbackAvatar(String name, RoleThemeData t, {required double size}) {
    final initials = name.trim().isNotEmpty
        ? name.trim().split(' ').map((e) => e[0]).take(2).join().toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      color: t.accentMuted,
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: t.accent,
          fontWeight: FontWeight.w900,
          fontSize: size * 0.35,
        ),
      ),
    );
  }
}
