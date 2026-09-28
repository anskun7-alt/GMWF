// lib/pages/register.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hive/hive.dart';

import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../services/auth_service.dart';
import '../services/camp_session_service.dart';
import '../services/finance_local_storage.dart';
import '../services/local_storage_service.dart';
import '../services/image_upload_service.dart';
import '../services/zkteco_network_service.dart';
import '../widgets/media_upload_tile.dart';
import '../widgets/global_module_wrapper.dart';
import '../widgets/app_back_button.dart';
import '../services/sync_service.dart';

class Register extends StatefulWidget {
  const Register({super.key});

  @override
  State<Register> createState() => _RegisterState();
}

class _RegisterState extends State<Register>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final AuthService _authService = AuthService();
  final PageController _pageController = PageController();

  int _currentStep = 0;
  static const int _totalSteps = 3;

  String? _selectedDepartment;
  String? _selectedRole;
  String? _selectedBranch;
  bool _branchManuallySelected = false; // true once user or code has made an intentional selection
  String? _selectedDispensary;
  final Set<String> _selectedDispensaries = {};
  final Map<String, String> _campSessions = {};
  String _selectedMadrassaSession = 'morning';
  String _selectedMadrassaTeachingType = 'hifz'; // 'nazra', 'hifz', 'both'
  final Set<String> _selectedMadrassaSessions = {'morning'};
  String? _selectedDegree;

  final TextEditingController _usernameController     = TextEditingController();
  final TextEditingController _emailController        = TextEditingController();
  final TextEditingController _passwordController     = TextEditingController();
  final TextEditingController _phoneController        = TextEditingController();
  final TextEditingController _biometricPinController = TextEditingController();
  final TextEditingController _customDegreeController = TextEditingController();

  String? _selectedStudentId;
  List<Map<String, dynamic>> _branchStudents = [];

  XFile?        _profileImageXFile;
  Uint8List?    _profileImageBytes;
  PlatformFile? _degreeFile;
  String?       _profilePictureBase64;
  String?       _degreeBase64;

  bool _loading         = false;
  bool _obscurePassword = true;

  late AnimationController _animController;
  late Animation<double>   _fadeAnim;

  // ── Departments and Roles ────────────────────────────────────────────────
  static const List<Map<String, dynamic>> _departments = [
    {
      'name': 'Administration',
      'icon': Icons.admin_panel_settings_rounded,
      'color': Color(0xFF6366F1),
      'description': 'Executive leadership & central organization',
      'roles': [
        {'label': 'CEO',              'icon': Icons.workspace_premium_rounded,    'type': 'crown',    'value': 'CEO'},
        {'label': 'Admin',            'icon': Icons.workspace_premium_rounded,    'type': 'crown',    'value': 'Admin'},
        {'label': 'Chairman',         'icon': Icons.workspace_premium_rounded,    'type': 'crown',    'value': 'Chairman'},
        {'label': 'HQ Manager',       'icon': Icons.business_center_rounded,      'type': 'crown',    'value': 'HQ Manager'},
      ],
    },
    {
      'name': 'Office',
      'icon': Icons.business_rounded,
      'color': Color(0xFF0EA5E9),
      'description': 'Branch management, logistics & operations',
      'roles': [
        {'label': 'Branch Manager',   'icon': Icons.manage_accounts_rounded,      'type': 'normal',   'value': 'Branch Manager'},
        {'label': 'Office Boy',       'icon': Icons.confirmation_number_outlined, 'type': 'normal',   'value': 'Office Boy'},
        {'label': 'Server',           'icon': Icons.shield_rounded,               'type': 'shield',   'value': 'Server'},
      ],
    },
    {
      'name': 'Dispensary',
      'icon': Icons.local_hospital_rounded,
      'color': Color(0xFF10B981),
      'description': 'Healthcare, medical staff & clinic reception',
      'roles': [
        {'label': 'Supervisor',       'icon': Icons.manage_accounts_outlined,     'type': 'normal',   'value': 'Supervisor'},
        {'label': 'Doctor',           'icon': Icons.medical_services_outlined,    'type': 'normal',   'value': 'Doctor'},
        {'label': 'Receptionist',     'icon': Icons.support_agent_rounded,        'type': 'normal',   'value': 'Receptionist'},
        {'label': 'Dispenser',        'icon': Icons.medication_outlined,          'type': 'normal',   'value': 'Dispenser'},
        {'label': 'Rec + Dispenser',       'icon': Icons.swap_horiz_rounded, 'type': 'hybrid', 'value': 'rec+dis'},
        {'label': 'Doc + Receptionist',    'icon': Icons.swap_horiz_rounded, 'type': 'hybrid', 'value': 'doc+rec'},
        {'label': 'Doc + Dispenser',       'icon': Icons.swap_horiz_rounded, 'type': 'hybrid', 'value': 'doc+dis'},
        {'label': 'Doc + Rec + Dispenser', 'icon': Icons.swap_horiz_rounded, 'type': 'hybrid', 'value': 'doc+rec+dis'},
      ],
    },
    {
      'name': 'Dasterkhwaan',
      'icon': Icons.restaurant_rounded,
      'color': Color(0xFFF59E0B),
      'description': 'Food distribution & kitchen operations',
      'roles': [
        {'label': 'Kitchen',          'icon': Icons.restaurant_outlined,          'type': 'normal',   'value': 'Kitchen'},
      ],
    },
    {
      'name': 'Madrassa',
      'icon': Icons.menu_book_rounded,
      'color': Color(0xFF8B5CF6),
      'description': 'Religious education, teachers & administration',
      'roles': [
        {'label': 'Madrassa Principal / Admin', 'icon': Icons.menu_book_rounded, 'type': 'madrassa', 'value': 'Madrassa Admin'},
        {'label': 'Madrassa Teacher',           'icon': Icons.school_rounded,    'type': 'madrassa', 'value': 'Madrassa Teacher'},
        {'label': 'Madrassa Parent',            'icon': Icons.family_restroom_rounded, 'type': 'madrassa', 'value': 'Madrassa Parent'},
      ],
    },
    {
      'name': 'School',
      'icon': Icons.school_rounded,
      'color': Color(0xFFEC4899),
      'description': 'Academic education, teachers & principals',
      'roles': [
        {'label': 'School Principal',           'icon': Icons.stars_rounded,      'type': 'school',   'value': 'School Principal'},
        {'label': 'School Admin',               'icon': Icons.school_rounded,     'type': 'school',   'value': 'School Admin'},
        {'label': 'School Teacher',             'icon': Icons.co_present_rounded, 'type': 'school',   'value': 'School Teacher'},
      ],
    },
  ];

  final List<String> _degrees = ['MBBS', 'MD', 'DO', 'BDS', 'DPT (Physiotherapist)', 'Other'];
  List<Map<String, dynamic>> _branches = [];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _loadBranches();
  }

  @override
  void dispose() {
    _animController.dispose();
    _pageController.dispose();
    for (final c in [
      _usernameController, _emailController, _passwordController,
      _phoneController, _biometricPinController, _customDegreeController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBranches() async {
    final List<Map<String, dynamic>> localList = [];

    void addBranchIfNew(String rawId, String rawName) {
      final id = rawId.replaceAll('branch:', '').trim();
      final name = rawName.trim();
      if (id.isEmpty || id.toLowerCase() == 'all' || id.toLowerCase() == 'global') return;
      if (!localList.any((b) => b['id'].toString().toLowerCase().trim() == id.toLowerCase())) {
        localList.add({'id': id, 'name': name.isNotEmpty ? name : id});
      }
    }

    try {
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        for (final val in box.values) {
          if (val is Map) {
            final isOffboarded = val['isOffboarded'] == true || val['status'] == 'offboarded';
            if (!isOffboarded) {
              addBranchIfNew(val['id']?.toString() ?? '', val['name']?.toString() ?? '');
            }
          }
        }
      }
    } catch (_) {}

    try {
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        for (final val in box.values) {
          if (val is Map) {
            final isOffboarded = val['isOffboarded'] == true || val['status'] == 'offboarded';
            if (!isOffboarded) {
              addBranchIfNew(val['id']?.toString() ?? '', val['name']?.toString() ?? '');
            }
          }
        }
      }
    } catch (_) {}

    try {
      final custom = FinanceLocalStorage.getAllBranches([]);
      for (final b in custom) {
        addBranchIfNew(b['id']?.toString() ?? '', b['name']?.toString() ?? '');
      }
    } catch (_) {}

    if (localList.isEmpty) {
      for (final def in [
        {'id': 'main', 'name': 'Main Branch'},
        {'id': 'karachi', 'name': 'Karachi Branch'},
        {'id': 'gujrat', 'name': 'Gujrat Branch'},
        {'id': 'sialkot', 'name': 'Sialkot Branch'},
        {'id': 'rawalpindi', 'name': 'Rawalpindi Branch'},
      ]) {
        addBranchIfNew(def['id']!, def['name']!);
      }
    }

    final role = _getCurrentUserRole();
    final scopedBranchId = _getCurrentUserBranchId();
    final isGlobalExec = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(role);

    List<Map<String, dynamic>> applyFilter(List<Map<String, dynamic>> inputList) {
      var filtered = List<Map<String, dynamic>>.from(inputList);
      if (!isGlobalExec && scopedBranchId.isNotEmpty && scopedBranchId != 'all' && scopedBranchId != 'global') {
        final cleanScoped = scopedBranchId.replaceAll('branch:', '').trim().toLowerCase();
        final matched = filtered.where((b) {
          final bId = b['id'].toString().replaceAll('branch:', '').trim().toLowerCase();
          final bName = b['name'].toString().trim().toLowerCase();
          return bId == cleanScoped || bName == cleanScoped || bId.contains(cleanScoped) || cleanScoped.contains(bId);
        }).toList();

        if (matched.isNotEmpty) {
          filtered = matched;
        } else {
          final fallbackName = cleanScoped.length > 1
              ? cleanScoped[0].toUpperCase() + cleanScoped.substring(1)
              : cleanScoped.toUpperCase();
          filtered = [{'id': cleanScoped, 'name': fallbackName}];
        }
      }
      filtered.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      return filtered;
    }

    final immediateBranches = applyFilter(localList);
    if (mounted) {
      setState(() {
        _branches = immediateBranches;
        // Only auto-select if the user hasn't already made an intentional choice
        if (_branches.isNotEmpty && !_branchManuallySelected) {
          if (_selectedBranch == null || !_branches.any((b) => b['name'] == _selectedBranch)) {
            if (!isGlobalExec || _branches.length == 1) {
              _selectedBranch = _branches.first['name'];
            }
          }
        }
      });
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .get()
          .timeout(const Duration(seconds: 4));

      if (snap.docs.isNotEmpty) {
        final remoteList = <Map<String, dynamic>>[];
        for (final d in snap.docs) {
          final data = d.data();
          final isOffboarded = data['isOffboarded'] == true || data['status'] == 'offboarded';
          if (!isOffboarded) {
            final id = d.id.replaceAll('branch:', '').trim();
            final name = (data['name'] as String? ?? id).trim();
            if (id.isNotEmpty && id.toLowerCase() != 'all' && id.toLowerCase() != 'global') {
              if (!remoteList.any((b) => b['id'].toString().toLowerCase().trim() == id.toLowerCase())) {
                remoteList.add({'id': id, 'name': name.isNotEmpty ? name : id});
              }
            }
          }
        }

        if (remoteList.isNotEmpty) {
          try {
            if (Hive.isBoxOpen('local_branches')) {
              final box = Hive.box('local_branches');
              for (final b in remoteList) {
                await box.put(b['id'], b);
              }
            }
          } catch (_) {}

          final updatedBranches = applyFilter(remoteList);
          if (mounted) {
            setState(() {
              _branches = updatedBranches;
              // Only auto-select if the user hasn't already explicitly chosen
              if (_branches.isNotEmpty && !_branchManuallySelected) {
                if (_selectedBranch == null || !_branches.any((b) => b['name'] == _selectedBranch)) {
                  if (!isGlobalExec || _branches.length == 1) {
                    _selectedBranch = _branches.first['name'];
                  }
                }
              }
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _loadStudentsForBranch(String bId) async {
    try {
      final cleanBId = bId.toLowerCase().trim();
      List<Map<String, dynamic>> students = [];
      if (Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
        final box = Hive.box(LocalStorageService.madrassaStudentsBox);
        for (final val in box.values) {
          if (val is Map) {
            final sBranch = (val['branchId'] ?? val['branch'] ?? '').toString().toLowerCase().trim();
            final isDel = val['isDeleted'] == true || val['status'] == 'deleted' || val['status'] == 'inactive';
            if (!isDel && (sBranch == cleanBId || sBranch.isEmpty || cleanBId.isEmpty)) {
              students.add(Map<String, dynamic>.from(val));
            }
          }
        }
      }

      if (mounted && students.isNotEmpty) {
        setState(() {
          _branchStudents = students;
          _branchStudents.sort((a, b) => (a['rollNumber'] ?? '').compareTo(b['rollNumber'] ?? ''));
        });
      }

      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(cleanBId)
          .collection('madrassa_students')
          .get()
          .timeout(const Duration(seconds: 4));

      final remoteStudents = snap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .where((s) => s['isDeleted'] != true && s['status'] != 'inactive')
          .toList();

      if (mounted && remoteStudents.isNotEmpty) {
        setState(() {
          _branchStudents = remoteStudents;
          _branchStudents.sort((a, b) => (a['rollNumber'] ?? '').compareTo(b['rollNumber'] ?? ''));
        });
      }
    } catch (e) {
      if (_branchStudents.isEmpty) {
        _snack('Failed to load students: $e', error: true);
      }
    }
  }

  Future<bool> _usernameExists(String username) async {
    final lower = username.trim().toLowerCase();
    try {
      if (!Hive.isBoxOpen('local_users')) {
        await LocalStorageService.openBoxSafe('local_users');
      }
      final box = Hive.box('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final uName = (val['username']?.toString() ?? '').toLowerCase().trim();
          final uNameLower = (val['usernameLower']?.toString() ?? '').toLowerCase().trim();
          final isDeleted = val['isDeleted'] == true || val['status'] == 'deleted' || val['accountStatus'] == 'deleted';
          if (!isDeleted && (uName == lower || uNameLower == lower)) {
            return true;
          }
        }
      }
    } catch (_) {}

    try {
      final res = await FirebaseFirestore.instance
          .collection('users')
          .where('usernameLower', isEqualTo: lower)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 4));
      if (res.docs.isNotEmpty) {
        final docData = res.docs.first.data();
        final status = (docData['status'] ?? docData['accountStatus'] ?? '').toString().toLowerCase();
        if (docData['isDeleted'] != true && status != 'deleted') {
          return true;
        }
      }
    } catch (_) {}

    return false;
  }

  bool _requiresBranch() {
    final r = _selectedRole?.toLowerCase();
    return r != 'ceo' && r != 'chairman' && r != 'admin' && r != 'hq manager';
  }

  String _getBranchId() {
    if (!_requiresBranch()) return 'all';
    if (_selectedBranch == null || _selectedBranch!.trim().isEmpty) return 'all';
    final match = _branches.where((b) => b['name'] == _selectedBranch).toList();
    if (match.isNotEmpty) return match.first['id'] as String;
    return (_selectedBranch ?? 'all').toLowerCase().replaceAll(' ', '_');
  }

  String _getBranchName() =>
      _requiresBranch() ? (_selectedBranch ?? 'All Branches') : 'All Branches';

  Future<void> _pickProfileImage() async {
    try {
      final source = await ImageUploadService.showSourceDialog(context, title: 'Choose Profile Photo Source');
      if (source == null) return;
      final b64 = await ImageUploadService.pickAndProcessImage(source: source, quality: 85);
      if (b64 == null || b64.isEmpty) return;
      final bytes = ImageUploadService.decodeBase64ToBytes(b64);
      if (bytes == null || !mounted) return;
      setState(() {
        _profileImageBytes = bytes;
        _profilePictureBase64 = b64;
      });
    } catch (e) {
      _snack('Failed to pick image: $e', error: true);
    }
  }

  void _removeProfileImage() =>
      setState(() { _profileImageXFile = null; _profileImageBytes = null; _profilePictureBase64 = null; });

  bool _validateStep(int step) {
    if (step == 0) {
      if (_selectedDepartment == null) {
        _snack('Please select a Department to continue', error: true);
        return false;
      }
      if (_selectedRole == null) {
        _snack('Please select a Role to continue', error: true);
        return false;
      }
      return true;
    }
    if (step == 1) {
      if (_usernameController.text.trim().isEmpty) {
        _snack('Please enter a username', error: true);
        return false;
      }
      if (_emailController.text.trim().isEmpty) {
        _snack('Please enter an email address', error: true);
        return false;
      }
      if (_passwordController.text.trim().length < 6) {
        _snack('Password must be at least 6 characters', error: true);
        return false;
      }
      return true;
    }
    if (step == 2) {
      if (_requiresBranch() && _selectedBranch == null) {
        _snack('Please select a Branch for this role', error: true);
        return false;
      }
      if (_selectedRole == 'Madrassa Parent' && _selectedStudentId == null) {
        _snack('Please select the associated student for this parent', error: true);
        return false;
      }
      if (_selectedRole == 'Madrassa Teacher') {
        if (_selectedMadrassaTeachingType.isEmpty) {
          _snack('Please select teaching specialization (Nazra / Hifz / Both)', error: true);
          return false;
        }
        if (_selectedMadrassaSession.isEmpty && _selectedMadrassaSessions.isEmpty) {
          _snack('Please select a teaching shift for Madrassa Teacher', error: true);
          return false;
        }
      }
      final isDoctor = (_selectedRole ?? '').toLowerCase().contains('doc');
      if (isDoctor && _selectedDegree == null) {
        _snack('Please select medical degree for Doctor role', error: true);
        return false;
      }
      return true;
    }
    return true;
  }

  void _goToStep(int targetStep) {
    if (targetStep > _currentStep) {
      for (int s = _currentStep; s < targetStep; s++) {
        if (!_validateStep(s)) return;
      }
    }
    setState(() => _currentStep = targetStep);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        targetStep,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  Future<void> _registerUser() async {
    for (int s = 0; s < _totalSteps; s++) {
      if (!_validateStep(s)) {
        _goToStep(s);
        return;
      }
    }

    if (_formKey.currentState != null && !_formKey.currentState!.validate()) {
      _snack('Please correct the highlighted errors in the form', error: true);
      return;
    }

    setState(() { _loading = true; });

    final email    = _emailController.text.trim().toLowerCase();
    final username = _usernameController.text.trim();
    if (_selectedRole == null || _selectedRole!.trim().isEmpty) {
      _snack('Please select a valid role before proceeding', error: true);
      _goToStep(0);
      return;
    }

    final roleToAssign = _selectedRole!.trim();

    try {
      if (await _usernameExists(username)) {
        _snack('Username "$username" already exists. Please choose another.', error: true);
        _goToStep(1);
        return;
      }

      final degree = _selectedDegree == 'Other'
          ? _customDegreeController.text.trim()
          : (_selectedDegree ?? '');

      final enteredPin = _biometricPinController.text.trim();
      if (enteredPin.isNotEmpty) {
        final conflict = ZkTecoNetworkService.findPinConflict(enteredPin);
        if (conflict != null) {
          _snack('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()}). Please choose a unique PIN.', error: true);
          _goToStep(2);
          return;
        }
      }

      String branchId = _getBranchId();
      final curRole = _getCurrentUserRole();
      final curBranch = _getCurrentUserBranchId();
      if ((curRole.contains('teacher') || curRole.contains('principal') || curRole.contains('admin')) &&
          curBranch.isNotEmpty && curBranch != 'all' && curBranch != 'global' &&
          (branchId.isEmpty || branchId == 'all')) {
        branchId = curBranch;
      } else if (roleToAssign == 'Madrassa Parent' && _selectedStudentId != null) {
        final match = _branchStudents.where((s) => s['id'] == _selectedStudentId).firstOrNull;
        final studentBranch = (match?['branchId'] ?? match?['branch'] ?? '').toString().trim().toLowerCase();
        if (studentBranch.isNotEmpty && studentBranch != 'all' && studentBranch != 'global') {
          branchId = studentBranch;
        }
      }

      String branchName = _getBranchName();
      if (branchId.isNotEmpty && branchId != 'all') {
        final bMatch = _branches.where((b) => b['id'].toString().toLowerCase().trim() == branchId).firstOrNull;
        if (bMatch != null && bMatch['name'] != null) {
          branchName = bMatch['name'].toString();
        }
      }

      final registeredUid = await _authService.signUp(
        email:              email,
        password:           _passwordController.text.trim(),
        username:           username,
        name:               username,
        role:               roleToAssign,
        branchId:           branchId,
        branchName:         branchName,
        phone:              _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null,
        degree:             degree.isNotEmpty ? degree : null,
        biometricPin:       enteredPin.isNotEmpty ? enteredPin : null,
        studentId:          _selectedStudentId,
        dispensaryId:       _selectedDispensary,
        dispensaryIds:      _selectedDispensaries.toList(),
        campSchedule:       _selectedDispensaries.map((id) {
                              final sess = _campSessions[id] ?? 'morning';
                              String startTime = '08:00';
                              String endTime = '14:00';
                              if (sess == 'evening') {
                                startTime = '14:00';
                                endTime = '20:00';
                              } else if (sess == 'night') {
                                startTime = '20:00';
                                endTime = '08:00';
                              } else if (sess == 'both') {
                                startTime = '08:00';
                                endTime = '20:00';
                              }
                              return {
                                'campId': id,
                                'session': sess,
                                'startTime': startTime,
                                'endTime': endTime,
                              };
                            }).toList(),
        profileImageXFile:  _profileImageXFile,
        profileImageBytes:  _profileImageBytes,
        degreeFile:         _degreeFile,
        profilePictureBase64: _profilePictureBase64,
        degreeBase64:         _degreeBase64,
        specialization:     roleToAssign == 'Madrassa Teacher' ? _selectedMadrassaTeachingType : null,
        teachingType:       roleToAssign == 'Madrassa Teacher' ? _selectedMadrassaTeachingType : null,
        session:            roleToAssign == 'Madrassa Teacher' ? (_selectedMadrassaSession.isNotEmpty ? _selectedMadrassaSession : 'morning') : null,
        sessions:           roleToAssign == 'Madrassa Teacher'
                                ? (_selectedMadrassaSession == 'all'
                                    ? ['morning', 'evening', 'night']
                                    : (_selectedMadrassaSessions.isNotEmpty
                                        ? _selectedMadrassaSessions.toList()
                                        : [if (_selectedMadrassaSession.isNotEmpty) _selectedMadrassaSession else 'morning']))
                                : const [],
      );

      // Cache specialization, teachingType and sessions in local_users
      if (roleToAssign == 'Madrassa Teacher') {
        try {
          if (Hive.isBoxOpen('local_users')) {
            final box = Hive.box('local_users');
            final effectiveSessions = _selectedMadrassaSession == 'all'
                ? ['morning', 'evening', 'night']
                : (_selectedMadrassaSessions.isNotEmpty
                    ? _selectedMadrassaSessions.toList()
                    : [if (_selectedMadrassaSession.isNotEmpty) _selectedMadrassaSession else 'morning']);
            final keys = <String>{
              username,
              username.toLowerCase(),
              if (registeredUid.isNotEmpty) registeredUid,
              'user:$username',
              'user:${username.toLowerCase()}',
              if (registeredUid.isNotEmpty) 'user:$registeredUid',
              email,
              'user:$email',
            };
            for (final k in keys) {
              final raw = box.get(k);
              if (raw is Map) {
                final updated = Map<String, dynamic>.from(raw);
                updated['specialization'] = _selectedMadrassaTeachingType;
                updated['teachingType'] = _selectedMadrassaTeachingType;
                updated['session'] = _selectedMadrassaSession;
                updated['sessions'] = effectiveSessions;
                await box.put(k, updated);
              }
            }
          }
        } catch (_) {}
      }

      try {
        unawaited(LocalStorageService.pushLocalUsersToFirestore());
        SyncService().triggerUpload(force: true);
      } catch (_) {}

      if (enteredPin.isNotEmpty && registeredUid.isNotEmpty) {
        await ZkTecoNetworkService.assignPinToEntity(
          entityId: registeredUid,
          entityName: username,
          entityType: 'user',
          branchId: branchId,
          customPin: enteredPin,
        );
      }

      final registeredName = _usernameController.text.trim();
      _formKey.currentState?.reset();
      _biometricPinController.clear();
      setState(() {
        _selectedDepartment       = null;
        _selectedRole             = null;
        _profileImageBytes        = null;
        _profileImageXFile        = null;
        _degreeFile               = null;
        _profilePictureBase64     = null;
        _degreeBase64             = null;
        _selectedBranch           = null;
        _branchManuallySelected   = false;
        _selectedDispensary       = null;
        _selectedDispensaries.clear();
        _campSessions.clear();
        _selectedMadrassaSession  = 'morning';
        _selectedMadrassaTeachingType = 'hifz';
        _selectedMadrassaSessions.clear();
        _selectedMadrassaSessions.add('morning');
        _selectedDegree           = null;
        _selectedStudentId        = null;
        _currentStep              = 0;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      for (final c in [
        _usernameController, _emailController, _passwordController,
        _phoneController, _customDegreeController, _biometricPinController,
      ]) { c.clear(); }

      _snack('🎉 $registeredName registered successfully as $roleToAssign!', success: true);
    } on Exception catch (e) {
      _snack(e.toString().replaceAll('Exception: ', ''), error: true);
    } catch (e) {
      _snack('Unexpected error: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    final t = RoleThemeScope.dataOf(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          error ? Icons.error_outline_rounded : success ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
          color: Colors.white, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      ]),
      backgroundColor: error ? t.danger : success ? const Color(0xFF10B981) : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      duration: const Duration(seconds: 4),
    ));
  }

  String _getCurrentUserRole() {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final curUid = currentUser?.uid ?? '';
      if (curUid.isNotEmpty && Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final curMap = Hive.box(LocalStorageService.usersBox).get(curUid);
        if (curMap is Map && curMap['role'] != null) {
          return (curMap['role'] as String).toLowerCase().trim();
        }
      }
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final currentMap = box.get('user_data') ?? box.get('currentUser');
        if (currentMap is Map && currentMap['role'] != null) {
          return (currentMap['role'] as String).toLowerCase().trim();
        }
      }
      return RoleThemeScope.dataOf(context).roleLabel.toLowerCase().trim();
    } catch (_) {
      return '';
    }
  }

  String _getCurrentUserBranchId() {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final curUid = currentUser?.uid ?? '';
      if (curUid.isNotEmpty && Hive.isBoxOpen(LocalStorageService.usersBox)) {
        final curMap = Hive.box(LocalStorageService.usersBox).get(curUid);
        if (curMap is Map) {
          final b = (curMap['branchId'] ?? curMap['branch'] ?? '').toString().toLowerCase().trim();
          if (b.isNotEmpty) return b;
        }
      }
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final currentMap = box.get('user_data') ?? box.get('currentUser');
        if (currentMap is Map) {
          final b = (currentMap['branchId'] ?? currentMap['branch'] ?? '').toString().toLowerCase().trim();
          if (b.isNotEmpty) return b;
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);

    return Scaffold(
      backgroundColor: t.bg,
      body: Stack(
        children: [
          // Background ambient gradient
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 220,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    t.accent.withValues(alpha: 0.88),
                    t.accentLight.withValues(alpha: 0.95),
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  // Top Navigation Bar
                  _buildTopBar(t),

                  // Interactive Stepper (3-step wizard)
                  _buildStepperHeader(t),

                  // Main Page Flow
                  Expanded(
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: PageView(
                        controller: _pageController,
                        physics: const NeverScrollableScrollPhysics(),
                        onPageChanged: (page) => setState(() => _currentStep = page),
                        children: [
                          _buildStepWrapper(t, _buildStep0DepartmentAndRole(t)),
                          _buildStepWrapper(t, _buildStep1PersonalAndAccount(t)),
                          _buildStepWrapper(t, _buildStep2StationAndBiometrics(t)),
                        ],
                      ),
                    ),
                  ),

                  // Sticky Bottom Action Bar
                  _buildBottomActionBar(t),
                ],
              ),
            ),
          ),

          // Loading overlay
          if (_loading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 30, offset: Offset(0, 10))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 50, height: 50,
                        child: CircularProgressIndicator(
                          color: t.accent,
                          strokeWidth: 4,
                          backgroundColor: t.accentMuted,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Creating User Account...',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textPrimary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Securing credentials & configuring station access',
                        style: TextStyle(fontSize: 12, color: t.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Top Bar ────────────────────────────────────────────────────────────────
  Widget _buildTopBar(RoleThemeData t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          if (!GlobalModuleWrapper.isWrapped(context)) ...[
            const AppBackButton(color: Colors.white),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'USER REGISTRATION',
                        style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Step ${_currentStep + 1} of $_totalSteps',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                  'Register Staff User',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.2),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Clear / Reset Form',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 22),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: t.bgCard,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text('Reset Form?', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold)),
                  content: Text('All entered registration fields will be cleared.', style: TextStyle(color: t.textSecondary)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _formKey.currentState?.reset();
                        setState(() {
                          _selectedDepartment   = null;
                          _selectedRole         = null;
                          _profileImageBytes    = null;
                          _profileImageXFile    = null;
                          _degreeFile           = null;
                          _profilePictureBase64 = null;
                          _degreeBase64         = null;
                          _selectedBranch       = null;
                          _selectedDispensary   = null;
                          _selectedDispensaries.clear();
                          _selectedDegree       = null;
                          _selectedStudentId    = null;
                          _currentStep          = 0;
                        });
                        _pageController.jumpToPage(0);
                        for (final c in [
                          _usernameController, _emailController, _passwordController,
                          _phoneController, _customDegreeController, _biometricPinController,
                        ]) { c.clear(); }
                      },
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Stepper Header ────────────────────────────────────────────────────────
  Widget _buildStepperHeader(RoleThemeData t) {
    final steps = [
      {'title': 'Role & Dept', 'icon': Icons.category_rounded},
      {'title': 'Credentials', 'icon': Icons.person_rounded},
      {'title': 'Station & Biometrics', 'icon': Icons.location_city_rounded},
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.bgCard.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: List.generate(steps.length, (index) {
          final isCompleted = _currentStep > index;
          final isActive = _currentStep == index;
          final step = steps[index];

          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _goToStep(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                decoration: BoxDecoration(
                  color: isActive
                      ? t.accent.withValues(alpha: 0.12)
                      : isCompleted
                          ? const Color(0xFF10B981).withValues(alpha: 0.08)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isActive
                        ? t.accent
                        : isCompleted
                            ? const Color(0xFF10B981).withValues(alpha: 0.4)
                            : Colors.transparent,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 24, height: 24,
                      decoration: BoxDecoration(
                        color: isCompleted
                            ? const Color(0xFF10B981)
                            : isActive
                                ? t.accent
                                : t.bgRule,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: isCompleted
                            ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                            : Icon(step['icon'] as IconData, color: isActive ? Colors.white : t.textTertiary, size: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        step['title'] as String,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive
                              ? t.accent
                              : isCompleted
                                  ? const Color(0xFF10B981)
                                  : t.textTertiary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Step Wrapper with Responsive Scroll ──────────────────────────────────
  Widget _buildStepWrapper(RoleThemeData t, Widget content) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: content,
        ),
      ),
    );
  }

  // ── Available Roles Helper ───────────────────────────────────────────────
  List<Map<String, dynamic>> _getAvailableRolesForDept(Map<String, dynamic> dept) {
    var roles = List<Map<String, dynamic>>.from(dept['roles'] as List);
    if (_getCurrentUserRole() != 'chairman') {
      roles = roles.where((r) => (r['value'] as String).toLowerCase().trim() != 'chairman').toList();
    }
    return roles;
  }

  // ── Step 0: Department & Role ─────────────────────────────────────────────
  Widget _buildStep0DepartmentAndRole(RoleThemeData t) {
    final selectedDeptData = _selectedDepartment != null
        ? _departments.firstWhere((d) => d['name'] == _selectedDepartment, orElse: () => _departments.first)
        : null;

    final List<Map<String, dynamic>> roles = selectedDeptData != null
        ? _getAvailableRolesForDept(selectedDeptData)
        : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(
          t,
          title: 'Department & Operational Role',
          subtitle: 'Select the operational department to choose the staff role and system permissions.',
          icon: Icons.hub_rounded,
        ),
        const SizedBox(height: 16),

        // Department Selection Cards
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 600;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: isWide ? 3 : 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                mainAxisExtent: 96,
              ),
              itemCount: _departments.length,
              itemBuilder: (context, index) {
                final dept = _departments[index];
                final isSelected = _selectedDepartment == dept['name'];
                final deptColor = dept['color'] as Color;
                final availableRoles = _getAvailableRolesForDept(dept);
                final roleCount = availableRoles.length;

                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    setState(() {
                      _selectedDepartment = dept['name'] as String;
                      _selectedRole = null;
                      _selectedDegree = null;
                      _customDegreeController.clear();
                      _degreeFile = null;
                      if (!_requiresBranch()) _selectedBranch = null;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isSelected ? deptColor.withValues(alpha: 0.12) : t.bgCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? deptColor : t.bgRule,
                        width: isSelected ? 2 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isSelected ? deptColor.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.04),
                          blurRadius: isSelected ? 12 : 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: isSelected ? deptColor : deptColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            dept['icon'] as IconData,
                            color: isSelected ? Colors.white : deptColor,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                dept['name'] as String,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: isSelected ? deptColor : t.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                roleCount == 1 ? '1 Role' : '$roleCount Roles',
                                style: TextStyle(fontSize: 11, color: t.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          Icon(Icons.check_circle_rounded, color: deptColor, size: 18),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),

        const SizedBox(height: 24),

        // Roles Section
        if (_selectedDepartment == null)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: t.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.bgRule),
            ),
            child: Column(
              children: [
                Icon(Icons.touch_app_rounded, size: 40, color: t.textTertiary.withValues(alpha: 0.6)),
                const SizedBox(height: 10),
                Text(
                  'Select a Department Above',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Available roles for that department will appear here.',
                  style: TextStyle(fontSize: 12, color: t.textTertiary),
                ),
              ],
            ),
          )
        else ...[
          Row(
            children: [
              Icon(Icons.badge_rounded, color: t.accent, size: 20),
              const SizedBox(width: 8),
              Text(
                'Available Roles for ${_selectedDepartment!}',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary),
              ),
              const Spacer(),
              if (_selectedRole != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Selected: $_selectedRole',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isWide ? 2 : 1,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: 70,
                ),
                itemCount: roles.length,
                itemBuilder: (context, index) {
                  final role = roles[index];
                  final isRoleSelected = _selectedRole == role['value'];
                  final type = role['type'] as String;

                  Color badgeColor = t.textSecondary;
                  String badgeLabel = 'Staff';
                  if (type == 'crown') {
                    badgeColor = const Color(0xFFEAB308);
                    badgeLabel = 'Executive';
                  } else if (type == 'shield') {
                    badgeColor = const Color(0xFF0EA5E9);
                    badgeLabel = 'System';
                  } else if (type == 'hybrid') {
                    badgeColor = const Color(0xFF10B981);
                    badgeLabel = 'Hybrid Multi-Duty';
                  } else if (type == 'madrassa') {
                    badgeColor = const Color(0xFF8B5CF6);
                    badgeLabel = 'Faculty';
                  } else if (type == 'school') {
                    badgeColor = const Color(0xFFEC4899);
                    badgeLabel = 'Faculty';
                  }

                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      setState(() {
                        _selectedRole = role['value'] as String;
                        if (_selectedRole != 'Doctor' && _selectedRole != 'doc+rec' && _selectedRole != 'doc+dis' && _selectedRole != 'doc+rec+dis') {
                          _selectedDegree = null;
                          _customDegreeController.clear();
                          _degreeFile = null;
                        }
                        if (!_requiresBranch()) _selectedBranch = null;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isRoleSelected ? t.accent.withValues(alpha: 0.12) : t.bgCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isRoleSelected ? t.accent : t.bgRule,
                          width: isRoleSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isRoleSelected ? t.accent : badgeColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              role['icon'] as IconData,
                              color: isRoleSelected ? Colors.white : badgeColor,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  role['label'] as String,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: isRoleSelected ? FontWeight.w700 : FontWeight.w600,
                                    color: isRoleSelected ? t.accent : t.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  badgeLabel,
                                  style: TextStyle(fontSize: 10, color: badgeColor, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                          if (isRoleSelected)
                            Icon(Icons.check_circle_rounded, color: t.accent, size: 20)
                          else
                            Icon(Icons.radio_button_unchecked_rounded, color: t.bgRule, size: 18),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ],
    );
  }

  // ── Step 1: User Account & Credentials ────────────────────────────────────
  Widget _buildStep1PersonalAndAccount(RoleThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(
          t,
          title: 'User Identity & Login Credentials',
          subtitle: 'Set up login username, authentication password, and contact telephone number.',
          icon: Icons.person_outline_rounded,
        ),
        const SizedBox(height: 16),

        // Profile Avatar Card
        _buildAvatarUploader(t),
        const SizedBox(height: 16),

        // Credential Details Card
        _buildCard(
          t,
          title: 'Account Credentials',
          icon: Icons.lock_outline_rounded,
          accent: t.accent,
          child: Column(
            children: [
              _buildResponsiveFieldPair([
                _buildField(
                  t,
                  controller: _usernameController,
                  label: 'Username / Display Name',
                  hint: 'e.g. dr_tariq or ahmad_khan',
                  icon: Icons.alternate_email_rounded,
                  required: true,
                  validator: (v) => v?.trim().isEmpty ?? true ? 'Username is required' : null,
                ),
                _buildField(
                  t,
                  controller: _emailController,
                  label: 'Official Email Address',
                  hint: 'staff@gmwf.org',
                  icon: Icons.mail_outline_rounded,
                  required: true,
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Email is required';
                    if (!v.contains('@') || !v.contains('.')) return 'Enter a valid email address';
                    return null;
                  },
                ),
              ]),
              const SizedBox(height: 14),
              _buildResponsiveFieldPair([
                _buildField(
                  t,
                  controller: _passwordController,
                  label: 'Initial Password',
                  hint: 'Minimum 6 characters',
                  icon: Icons.lock_outline_rounded,
                  isPassword: true,
                  required: true,
                  validator: (v) => (v?.length ?? 0) < 6 ? 'Password must be at least 6 characters' : null,
                ),
                _buildField(
                  t,
                  controller: _phoneController,
                  label: 'Contact Phone Number (Optional)',
                  hint: '03001234567',
                  icon: Icons.phone_android_rounded,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  // ── Step 2: Station, Facilities & Biometrics ──────────────────────────────
  Widget _buildStep2StationAndBiometrics(RoleThemeData t) {
    final requiresBranch = _requiresBranch();
    final isDoctor = _selectedRole != null &&
        (_selectedRole!.toLowerCase() == 'doctor' || _selectedRole!.toLowerCase().contains('doc'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(
          t,
          title: 'Station Assignment & Access Control',
          subtitle: 'Assign branch location, facility shift schedule, and biometric clock-in PIN.',
          icon: Icons.location_on_outlined,
        ),
        const SizedBox(height: 16),

        // Branch Card
        _buildCard(
          t,
          title: 'Branch Station Assignment',
          icon: Icons.business_outlined,
          accent: const Color(0xFF6366F1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!requiresBranch) ...[
                _buildGlobalBadge(t),
              ] else ...[
                Text(
                  'Select the primary operating branch station for this staff user:',
                  style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                ),
                const SizedBox(height: 10),
                _buildBranchDropdown(t),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Dispensary Multi-Camp & Shifts
        _buildDispensaryDropdown(t),

        // Madrassa Teacher Specialization (Nazra, Hifz, Both) & Shifts
        if (_selectedRole == 'Madrassa Teacher') ...[
          const SizedBox(height: 16),
          _buildMadrassaTeachingTypeSelector(t),
          const SizedBox(height: 16),
          _buildMadrassaTeacherSessionSelector(t),
        ],

        // Madrassa Parent Child Selector
        if (_selectedRole == 'Madrassa Parent') ...[
          const SizedBox(height: 16),
          _buildCard(
            t,
            title: 'Associated Student Profile',
            icon: Icons.child_care_rounded,
            accent: const Color(0xFF8B5CF6),
            child: _buildChildDropdown(t),
          ),
        ],

        const SizedBox(height: 16),

        // Biometric Clock-in PIN
        _buildCard(
          t,
          title: 'ZKTeco Biometric Terminal Attendance',
          icon: Icons.fingerprint_rounded,
          accent: const Color(0xFF10B981),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Assign an optional numerical PIN for biometric terminal attendance punch-in:',
                style: TextStyle(fontSize: 12.5, color: t.textSecondary),
              ),
              const SizedBox(height: 12),
              _buildField(
                t,
                controller: _biometricPinController,
                label: 'Biometric Clock-in PIN (Optional)',
                hint: 'e.g. 1045',
                icon: Icons.pin_outlined,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ],
          ),
        ),

        // Doctor Qualifications Card
        if (isDoctor) ...[
          const SizedBox(height: 16),
          _buildCard(
            t,
            title: 'Medical Degree & Licensing',
            icon: Icons.medical_services_outlined,
            accent: const Color(0xFF00897B),
            child: Column(
              children: [
                _buildSimpleDropdown(
                  t,
                  initialValue: _selectedDegree,
                  items: _degrees,
                  hint: 'Select Medical Degree *',
                  icon: Icons.school_outlined,
                  onChanged: (v) => setState(() {
                    _selectedDegree = v;
                    if (v != 'Other') _customDegreeController.clear();
                  }),
                  validator: (v) => isDoctor && v == null ? 'Medical degree is required' : null,
                ),
                if (_selectedDegree == 'Other') ...[
                  const SizedBox(height: 14),
                  _buildField(
                    t,
                    controller: _customDegreeController,
                    label: 'Specify Degree Name',
                    hint: 'e.g. FCPS Surgery',
                    icon: Icons.edit_note_rounded,
                    required: true,
                    validator: (v) => v?.trim().isEmpty ?? true ? 'Degree name is required' : null,
                  ),
                ],
                const SizedBox(height: 16),
                MediaUploadTile(
                  label: 'PMDC License / Degree Certificate (PDF or Image)',
                  icon: Icons.verified_user_outlined,
                  initialValue: _degreeBase64,
                  isDocument: true,
                  onChanged: (val) => setState(() => _degreeBase64 = val),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 20),

        // Summary Preview Card
        _buildSummaryCard(t),
      ],
    );
  }

  // ── Summary Card ──────────────────────────────────────────────────────────
  Widget _buildSummaryCard(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_rounded, color: t.accent, size: 20),
              const SizedBox(width: 8),
              Text(
                'User Registration Summary Preview',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.accent),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _summaryRow('Department:', _selectedDepartment ?? 'Not chosen'),
          _summaryRow('Role:', _selectedRole ?? 'Not chosen'),
          _summaryRow('Branch / Station:', _requiresBranch() ? (_selectedBranch ?? 'Not assigned') : 'Global Executive (All)'),
          _summaryRow('Account Username:', _usernameController.text.trim().isNotEmpty ? _usernameController.text.trim() : 'None'),
          _summaryRow('Email:', _emailController.text.trim().isNotEmpty ? _emailController.text.trim() : 'None'),
          if (_phoneController.text.trim().isNotEmpty)
            _summaryRow('Phone:', _phoneController.text.trim()),
          if (_biometricPinController.text.trim().isNotEmpty)
            _summaryRow('Biometric PIN:', _biometricPinController.text.trim()),
          if (_selectedRole == 'Madrassa Teacher') ...[
            _summaryRow(
              'Teaching Focus:',
              _selectedMadrassaTeachingType == 'nazra'
                  ? '📖 Nazra (Reading & Recitation)'
                  : _selectedMadrassaTeachingType == 'both'
                      ? '✨ Hifz & Nazra (Combined)'
                      : '🕋 Hifz (Memorization)',
            ),
            _summaryRow(
              'Teaching Shift:',
              _selectedMadrassaSession == 'all'
                  ? '📑 All Shifts (Full-Day Coverage)'
                  : _selectedMadrassaSessions.length > 1
                      ? '🕒 ${_selectedMadrassaSessions.map((s) => s[0].toUpperCase() + s.substring(1)).join(', ')}'
                      : _selectedMadrassaSession == 'morning'
                          ? '☀️ Morning (8:00 AM – 2:00 PM)'
                          : _selectedMadrassaSession == 'evening'
                              ? '🌅 Evening (2:00 PM – 8:00 PM)'
                              : _selectedMadrassaSession == 'night'
                                  ? '🌙 Night (8:00 PM – 8:00 AM)'
                                  : _selectedMadrassaSession,
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    final t = RoleThemeScope.dataOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: TextStyle(fontSize: 12, color: t.textSecondary, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── Bottom Action Bar ─────────────────────────────────────────────────────
  Widget _buildBottomActionBar(RoleThemeData t) {
    final isLastStep = _currentStep == _totalSteps - 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(top: BorderSide(color: t.bgRule)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -3)),
        ],
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Row(
            children: [
              // Back Button (hidden on first step)
              if (_currentStep > 0)
                OutlinedButton.icon(
                  onPressed: _loading ? null : () => _goToStep(_currentStep - 1),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Back'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.textPrimary,
                    side: BorderSide(color: t.bgRule),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                )
              else
                const SizedBox.shrink(),

              const Spacer(),

              // Next or Register Button
              if (!isLastStep)
                ElevatedButton.icon(
                  onPressed: () => _goToStep(_currentStep + 1),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('Next Step'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    elevation: 3,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: _loading ? null : _registerUser,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
                  label: const Text('Create User Account'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    elevation: 4,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Avatar Uploader ───────────────────────────────────────────────────────
  Widget _buildAvatarUploader(RoleThemeData t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.bgRule),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 3))],
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      child: Row(
        children: [
          GestureDetector(
            onTap: _pickProfileImage,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _profileImageBytes != null ? t.accent : t.bgRule, width: 3),
                    boxShadow: [
                      BoxShadow(color: t.accent.withValues(alpha: 0.15), blurRadius: 16, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Builder(
                    builder: (context) {
                      final displayBytes = _profileImageBytes ?? ImageUploadService.decodeBase64ToBytes(_profilePictureBase64);
                      return CircleAvatar(
                        radius: 44,
                        backgroundColor: t.accentMuted,
                        backgroundImage: displayBytes != null ? MemoryImage(displayBytes) : null,
                        child: displayBytes == null
                            ? Icon(Icons.person_outline_rounded, size: 36, color: t.accent.withValues(alpha: 0.5))
                            : null,
                      );
                    },
                  ),
                ),
                Positioned(
                  right: 0, bottom: 0,
                  child: GestureDetector(
                    onTap: _profileImageBytes != null ? _removeProfileImage : _pickProfileImage,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _profileImageBytes != null ? t.danger : t.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: t.bgCard, width: 2),
                      ),
                      child: Icon(
                        _profileImageBytes != null ? Icons.close_rounded : Icons.camera_alt_rounded,
                        color: Colors.white, size: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile Photo (Optional)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Upload a clear passport-style staff photo for badge printing and ID verification.',
                  style: TextStyle(fontSize: 11.5, color: t.textTertiary),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _pickProfileImage,
                      icon: const Icon(Icons.upload_rounded, size: 16),
                      label: Text(_profileImageBytes == null ? 'Upload Photo' : 'Change Photo'),
                      style: TextButton.styleFrom(
                        foregroundColor: t.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    if (_profileImageBytes != null) ...[
                      const SizedBox(width: 12),
                      TextButton.icon(
                        onPressed: _removeProfileImage,
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: const Text('Remove'),
                        style: TextButton.styleFrom(
                          foregroundColor: t.danger,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper UI Components ─────────────────────────────────────────────────
  Widget _buildSectionTitle(RoleThemeData t, {
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: t.accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, color: t.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(RoleThemeData t, {
    required String title,
    required IconData icon,
    required Color accent,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.bgRule),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.bgRule))),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(color: accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(9)),
                  child: Icon(icon, color: accent, size: 17),
                ),
                const SizedBox(width: 10),
                Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: t.textPrimary)),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }

  Widget _buildResponsiveFieldPair(List<Widget> children) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 600) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children
                .expand((w) => [Expanded(child: w), const SizedBox(width: 14)])
                .toList()
              ..removeLast(),
          );
        } else {
          return Column(
            children: children
                .expand((w) => [w, const SizedBox(height: 14)])
                .toList()
              ..removeLast(),
          );
        }
      },
    );
  }

  Widget _buildField(RoleThemeData t, {
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool isPassword = false,
    bool required   = false,
    int maxLines    = 1,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: isPassword && _obscurePassword,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      style: TextStyle(fontSize: 13.5, color: t.textPrimary, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 12, color: t.textTertiary.withValues(alpha: 0.7)),
        labelStyle: TextStyle(fontSize: 13, color: t.textTertiary),
        floatingLabelStyle: TextStyle(fontSize: 12, color: t.accent, fontWeight: FontWeight.w600),
        prefixIcon: Icon(icon, color: t.textTertiary, size: 19),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: t.textTertiary, size: 19,
                ),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              )
            : null,
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: maxLines > 1 ? 14 : 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      validator: validator,
    );
  }

  Widget _buildSimpleDropdown(RoleThemeData t, {
    required String? initialValue,
    required List<String> items,
    required String hint,
    required IconData icon,
    required Function(String?)? onChanged,
    String? Function(String?)? validator,
    String Function(String)? itemLabel,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: initialValue,
      hint: Text(hint, style: TextStyle(color: t.textTertiary, fontSize: 13)),
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: t.textTertiary, size: 19),
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      items: items.map((e) => DropdownMenuItem(
        value: e,
        child: Text(itemLabel != null ? itemLabel(e) : e, style: TextStyle(fontSize: 13.5, color: t.textPrimary)),
      )).toList(),
      onChanged: onChanged,
      validator: validator,
    );
  }

  Widget _buildBranchDropdown(RoleThemeData t) {
    final requiresBranch = _requiresBranch();
    final isBranchLoading = _branches.isEmpty;
    final hintText = !requiresBranch
        ? 'Global Access (No branch required)'
        : (isBranchLoading ? 'Loading branches...' : 'Select Station Branch *');

    final bool branchExists = _selectedBranch != null && _branches.any((b) => b['name'] == _selectedBranch);
    final String? effectiveValue = branchExists ? _selectedBranch : null;

    return DropdownButtonFormField<String>(
      key: ValueKey('branch_${requiresBranch}_${effectiveValue}_${_branches.length}'),
      initialValue: effectiveValue,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.location_city_rounded, color: t.textTertiary, size: 20),
        suffixIcon: isBranchLoading && requiresBranch
            ? SizedBox(
                width: 24, height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: 'Reload branches',
                  onPressed: _loadBranches,
                ),
              )
            : null,
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      hint: Text(hintText, style: TextStyle(color: t.textTertiary, fontSize: 13)),
      items: !requiresBranch
          ? []
          : _branches.map((b) {
              final name = b['name'] as String;
              return DropdownMenuItem(
                value: name,
                child: Text(name, style: TextStyle(fontSize: 13.5, color: t.textPrimary)),
              );
            }).toList(),
      onChanged: !requiresBranch
          ? null
          : (v) {
              setState(() {
                _selectedBranch = v;
                _branchManuallySelected = true; // Mark user as having explicitly chosen
                _selectedStudentId = null;
                if (_selectedRole == 'Madrassa Parent') {
                  final bId = _getBranchId();
                  _loadStudentsForBranch(bId);
                }
              });
            },
      validator: (v) {
        if (requiresBranch && v == null) {
          return 'Branch is mandatory';
        }
        return null;
      },
    );
  }

  Widget _buildDispensaryDropdown(RoleThemeData t) {
    final bool isDispensaryRelated = (_selectedDepartment?.toLowerCase() == 'dispensary') ||
        ['doctor', 'receptionist', 'dispenser', 'rec+dis', 'doc+rec', 'doc+dis', 'doc+rec+dis', 'supervisor', 'branch manager']
            .contains(_selectedRole?.toLowerCase().trim());
    if (!isDispensaryRelated || _selectedBranch == null) return const SizedBox.shrink();

    String bId = '';
    try { bId = _getBranchId().toLowerCase().trim(); } catch (_) {}

    List<Map<String, dynamic>> rawDispensaries = CampSessionService.getCampsForBranch(bId, includeClosed: false);
    if (rawDispensaries.isEmpty) return const SizedBox.shrink();

    final isAllSelected = _selectedDispensaries.isEmpty;

    return _buildCard(
      t,
      title: 'Dispensary Camps & Operating Shift Schedule',
      icon: Icons.local_hospital_rounded,
      accent: const Color(0xFF10B981),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select which facility camp(s) this healthcare staff user operates at:',
            style: TextStyle(fontSize: 12.5, color: t.textSecondary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('All Dispensaries (Central)'),
                selected: isAllSelected,
                selectedColor: t.accent.withValues(alpha: 0.18),
                checkmarkColor: t.accent,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: isAllSelected ? FontWeight.bold : FontWeight.normal,
                  color: isAllSelected ? t.accent : t.textSecondary,
                ),
                onSelected: (selected) {
                  setState(() {
                    _selectedDispensaries.clear();
                    _selectedDispensary = null;
                    _campSessions.clear();
                  });
                },
              ),
              ...rawDispensaries.map((d) {
                final id = (d['id'] ?? '').toString().toLowerCase().trim();
                final label = (d['name'] ?? d['id'] ?? '').toString();
                final isSelected = _selectedDispensaries.contains(id);

                return FilterChip(
                  label: Text(label),
                  selected: isSelected,
                  selectedColor: t.accent.withValues(alpha: 0.18),
                  checkmarkColor: t.accent,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? t.accent : t.textSecondary,
                  ),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _selectedDispensaries.add(id);
                        _campSessions[id] ??= 'morning';
                      } else {
                        _selectedDispensaries.remove(id);
                        _campSessions.remove(id);
                      }
                      _selectedDispensary = _selectedDispensaries.isNotEmpty ? _selectedDispensaries.first : null;
                    });
                  },
                );
              }),
            ],
          ),
          if (_selectedDispensaries.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Mandatory Shift per Facility:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0D9488)),
            ),
            const SizedBox(height: 8),
            ..._selectedDispensaries.map((campId) {
              final match = rawDispensaries.where((d) => (d['id'] ?? '').toString().toLowerCase().trim() == campId);
              final campLabel = (match.isNotEmpty ? match.first['name'] : campId)?.toString() ?? campId;
              final currentSession = _campSessions[campId] ?? 'morning';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDFA),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFCCFBF1)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, size: 16, color: Color(0xFF0F766E)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        campLabel,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF134E4A)),
                      ),
                    ),
                    const Text('Shift: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    DropdownButton<String>(
                      value: currentSession,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: const [
                        DropdownMenuItem(value: 'morning', child: Text('☀️ Morning')),
                        DropdownMenuItem(value: 'evening', child: Text('🌅 Evening')),
                        DropdownMenuItem(value: 'night', child: Text('🌙 Night')),
                        DropdownMenuItem(value: 'all', child: Text('📑 All Sessions')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _campSessions[campId] = val);
                        }
                      },
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildMadrassaTeachingTypeSelector(RoleThemeData t) {
    if (_selectedRole != 'Madrassa Teacher') return const SizedBox.shrink();

    const types = [
      {
        'value': 'nazra',
        'label': 'Nazra',
        'arabic': 'نَظْرَة',
        'sub': 'Quran Reading, Qaida & Recitation',
        'icon': Icons.menu_book_rounded,
        'badge': 'Reading & Recitation',
        'color': Color(0xFF10B981),
      },
      {
        'value': 'hifz',
        'label': 'Hifz',
        'arabic': 'حِفْظ',
        'sub': 'Quran Memorization & Revision',
        'icon': Icons.auto_stories_rounded,
        'badge': 'Memorization Focus',
        'color': Color(0xFF7C3AED),
      },
      {
        'value': 'both',
        'label': 'Both',
        'arabic': 'حِفْظ + نَظْرَة',
        'sub': 'Combined Hifz & Nazra classes',
        'icon': Icons.import_contacts_rounded,
        'badge': 'Full Quranic Spectrum',
        'color': Color(0xFF0284C7),
      },
    ];

    return _buildCard(
      t,
      title: 'Teaching Specialization & Focus (تخصص / تدریسی شعبہ) *',
      icon: Icons.menu_book_rounded,
      accent: const Color(0xFF7C3AED),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select whether this teacher specializes in Nazra (Reading/Qaida), Hifz (Memorization), or both:',
            style: TextStyle(fontSize: 12.5, color: t.textSecondary),
          ),
          const SizedBox(height: 14),
          Column(
            children: types.map((item) {
              final isSelected = _selectedMadrassaTeachingType == item['value'];
              final Color typeColor = item['color'] as Color;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedMadrassaTeachingType = item['value'] as String;
                    });
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? typeColor.withValues(alpha: 0.08)
                          : t.bgCardAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? typeColor : t.bgRule,
                        width: isSelected ? 2 : 1,
                      ),
                      boxShadow: isSelected
                          ? [BoxShadow(color: typeColor.withValues(alpha: 0.14), blurRadius: 8, offset: const Offset(0, 2))]
                          : null,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isSelected ? typeColor.withValues(alpha: 0.18) : t.textTertiary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            item['icon'] as IconData,
                            size: 22,
                            color: isSelected ? typeColor : t.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    item['label'] as String,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: isSelected ? typeColor : t.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    item['arabic'] as String,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: isSelected ? typeColor : t.textTertiary,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                                    decoration: BoxDecoration(
                                      color: typeColor.withValues(alpha: isSelected ? 0.15 : 0.08),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      item['badge'] as String,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                        color: typeColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item['sub'] as String,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isSelected ? t.textPrimary : t.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected ? typeColor : Colors.transparent,
                            border: Border.all(
                              color: isSelected ? typeColor : t.bgRule,
                              width: 2,
                            ),
                          ),
                          child: isSelected
                              ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildMadrassaTeacherSessionSelector(RoleThemeData t) {
    if (_selectedRole != 'Madrassa Teacher') return const SizedBox.shrink();

    String bId = '';
    try { bId = _getBranchId().toLowerCase().trim(); } catch (_) {}
    final List<String> availableSessions = CampSessionService.getMadrassaSessions(bId);

    const shiftOptions = [
      {
        'value': 'morning',
        'label': 'Morning Shift',
        'arabic': 'صبح کا سیشن',
        'time': '8:00 AM – 2:00 PM',
        'icon': Icons.wb_sunny_rounded,
        'color': Color(0xFFF59E0B),
      },
      {
        'value': 'evening',
        'label': 'Evening Shift',
        'arabic': 'شام کا سیشن',
        'time': '2:00 PM – 8:00 PM',
        'icon': Icons.wb_twilight_rounded,
        'color': Color(0xFF0284C7),
      },
      {
        'value': 'night',
        'label': 'Night Shift',
        'arabic': 'رات کا سیشن',
        'time': '8:00 PM – 8:00 AM',
        'icon': Icons.nights_stay_rounded,
        'color': Color(0xFF6366F1),
      },
      {
        'value': 'all',
        'label': 'All Shifts',
        'arabic': 'تمام سیشنز / مکمل دن',
        'time': 'Full-Day Coverage',
        'icon': Icons.all_inclusive_rounded,
        'color': Color(0xFF8B5CF6),
      },
    ];

    final filteredShifts = shiftOptions.where((s) {
      final val = s['value'] as String;
      if (val == 'all') return true;
      if (availableSessions.isEmpty) return true;
      return availableSessions.contains(val);
    }).toList();

    return _buildCard(
      t,
      title: 'Madrassa Teaching Shift / Session (تدریسی اوقات و سیشن) *',
      icon: Icons.schedule_rounded,
      accent: const Color(0xFF8B5CF6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select the operational teaching shift(s) this instructor is assigned to:',
            style: TextStyle(fontSize: 12, color: t.textSecondary),
          ),
          const SizedBox(height: 12),
          // Interactive Shift Tiles
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 540;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: filteredShifts.map((s) {
                  final val = s['value'] as String;
                  final isAll = val == 'all';
                  final isSelected = isAll
                      ? _selectedMadrassaSession == 'all'
                      : (_selectedMadrassaSession == val || _selectedMadrassaSessions.contains(val));
                  final Color shiftColor = s['color'] as Color;

                  return InkWell(
                    onTap: () {
                      setState(() {
                        if (isAll) {
                          _selectedMadrassaSession = 'all';
                          _selectedMadrassaSessions.clear();
                          _selectedMadrassaSessions.addAll(['morning', 'evening', 'night']);
                        } else {
                          if (_selectedMadrassaSession == 'all') {
                            _selectedMadrassaSessions.clear();
                          }
                          if (_selectedMadrassaSessions.contains(val)) {
                            if (_selectedMadrassaSessions.length > 1) {
                              _selectedMadrassaSessions.remove(val);
                              _selectedMadrassaSession = _selectedMadrassaSessions.first;
                            }
                          } else {
                            _selectedMadrassaSessions.add(val);
                            _selectedMadrassaSession = val;
                          }
                          if (_selectedMadrassaSessions.length == 3) {
                            _selectedMadrassaSession = 'all';
                          }
                        }
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: isWide ? (constraints.maxWidth - 10) / 2 : double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? shiftColor.withValues(alpha: 0.08)
                            : t.bgCardAlt,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? shiftColor : t.bgRule,
                          width: isSelected ? 1.8 : 1,
                        ),
                        boxShadow: isSelected
                            ? [BoxShadow(color: shiftColor.withValues(alpha: 0.12), blurRadius: 6)]
                            : null,
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: isSelected ? shiftColor.withValues(alpha: 0.18) : t.textTertiary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(s['icon'] as IconData, size: 18, color: isSelected ? shiftColor : t.textSecondary),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      s['label'] as String,
                                      style: TextStyle(
                                        color: isSelected ? shiftColor : t.textPrimary,
                                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      s['arabic'] as String,
                                      style: TextStyle(
                                        color: isSelected ? shiftColor.withValues(alpha: 0.9) : t.textTertiary,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  s['time'] as String,
                                  style: TextStyle(color: isSelected ? t.textPrimary : t.textTertiary, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                            color: isSelected ? shiftColor : t.bgRule,
                            size: 19,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 12),
          // Dropdown selector backup
          DropdownButtonFormField<String>(
            initialValue: filteredShifts.any((s) => s['value'] == _selectedMadrassaSession)
                ? _selectedMadrassaSession
                : (filteredShifts.isNotEmpty ? filteredShifts.first['value'] as String : 'morning'),
            isExpanded: true,
            dropdownColor: t.bgCard,
            decoration: InputDecoration(
              filled: true,
              fillColor: t.bgCardAlt,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 2)),
            ),
            items: filteredShifts.map((s) => DropdownMenuItem(
              value: s['value'] as String,
              child: Text('${s['label']} (${s['arabic']}) • ${s['time']}'),
            )).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedMadrassaSession = val;
                  if (val == 'all') {
                    _selectedMadrassaSessions.clear();
                    _selectedMadrassaSessions.addAll(['morning', 'evening', 'night']);
                  } else {
                    _selectedMadrassaSessions.clear();
                    _selectedMadrassaSessions.add(val);
                  }
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChildDropdown(RoleThemeData t) {
    final hasBranch = _selectedBranch != null;
    final hintText = !hasBranch
        ? 'Select Branch first *'
        : (_branchStudents.isEmpty ? 'No students found' : 'Select Associated Child (Student) *');

    final studentExists = _branchStudents.any((s) => s['id'] == _selectedStudentId);
    final selectedId = studentExists ? _selectedStudentId : null;

    return DropdownButtonFormField<String>(
      key: ValueKey('child_${_selectedBranch}_$selectedId'),
      initialValue: selectedId,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.child_care_rounded, color: t.textTertiary, size: 20),
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      hint: Text(hintText, style: TextStyle(color: t.textTertiary, fontSize: 13)),
      items: !hasBranch
          ? []
          : _branchStudents.map((s) {
              final id = s['id'] as String;
              final name = s['name'] as String? ?? 'Unknown';
              final roll = s['rollNumber'] as String? ?? '';
              return DropdownMenuItem(
                value: id,
                child: Text('$name (Roll: $roll)', style: TextStyle(fontSize: 13.5, color: t.textPrimary)),
              );
            }).toList(),
      onChanged: !hasBranch
          ? null
          : (v) => setState(() => _selectedStudentId = v),
      validator: (v) => v == null ? 'Child selection is mandatory' : null,
    );
  }

  Widget _buildGlobalBadge(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [t.accent.withValues(alpha: 0.12), t.accent.withValues(alpha: 0.04)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.accent.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.workspace_premium_rounded, color: t.accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Global Access Granted', style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text('This executive role has cross-branch access privileges across all operations.', style: TextStyle(color: t.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
