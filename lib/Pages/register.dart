// lib/pages/register.dart


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

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
import 'package:hive/hive.dart';

class Register extends StatefulWidget {
  const Register({super.key});

  @override
  State<Register> createState() => _RegisterState();
}

class _RegisterState extends State<Register>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final AuthService _authService = AuthService();

  String? _selectedDepartment;
  String? _selectedRole;
  String? _selectedBranch;
  String? _selectedDispensary; // Legacy single dispensary selection ('saddar', 'haji_camp')
  final Set<String> _selectedDispensaries = {}; // Multi-camp assignment
  final Map<String, String> _campSessions = {}; // Camp to mandatory session mapping
  String? _selectedDegree;

  final TextEditingController _usernameController       = TextEditingController();
  final TextEditingController _emailController          = TextEditingController();
  final TextEditingController _passwordController       = TextEditingController();
  final TextEditingController _phoneController          = TextEditingController();
  final TextEditingController _identificationController = TextEditingController();
  final TextEditingController _addressController        = TextEditingController();
  final TextEditingController _bankNameController       = TextEditingController();
  final TextEditingController _bankAccountController    = TextEditingController();
  final TextEditingController _biometricPinController   = TextEditingController();
  final TextEditingController _customDegreeController   = TextEditingController();
  final TextEditingController _salaryController         = TextEditingController();

  String? _selectedStudentId;
  List<Map<String, dynamic>> _branchStudents = [];

  String? _selectedLinkedEmployeeId;
  String? _matchedReasonText;

  void _autoDetectEmployeeMatch() {
    final cnic = _identificationController.text.trim();
    final email = _emailController.text.trim();
    final name = _usernameController.text.trim();
    final branchId = _getBranchId();

    final match = FinanceLocalStorage.findMatchingEmployeeForUser(
      branchId: branchId,
      cnic: cnic,
      email: email,
      username: name,
      department: _selectedDepartment,
      role: _selectedRole,
    );

    if (match != null) {
      setState(() {
        _selectedLinkedEmployeeId = match['id']?.toString() ?? match['localId']?.toString();
        _matchedReasonText = match['matchReason']?.toString();
      });
      _snack('✨ Auto-linked to Employee: ${match['name']} (${_matchedReasonText ?? ""})', success: true);
    } else {
      _snack('No automatic employee match found by CNIC, Email, or Name+Role', error: false);
    }
  }

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
      'roles': [
        {'label': 'Branch Manager',   'icon': Icons.manage_accounts_rounded,      'type': 'normal',   'value': 'Branch Manager'},
        {'label': 'Office Boy',       'icon': Icons.confirmation_number_outlined, 'type': 'normal',   'value': 'Office Boy'},
        {'label': 'Server',           'icon': Icons.shield_rounded,               'type': 'shield',   'value': 'Server'},
      ],
    },
    {
      'name': 'Dispensary',
      'icon': Icons.local_hospital_rounded,
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
      'roles': [
        {'label': 'Kitchen',          'icon': Icons.restaurant_outlined,          'type': 'normal',   'value': 'Kitchen'},
      ],
    },
    {
      'name': 'Madrassa',
      'icon': Icons.menu_book_rounded,
      'roles': [
        {'label': 'Madrassa Principal / Admin', 'icon': Icons.menu_book_rounded, 'type': 'madrassa', 'value': 'Madrassa Admin'},
        {'label': 'Madrassa Teacher',           'icon': Icons.school_rounded,    'type': 'madrassa', 'value': 'Madrassa Teacher'},
      ],
    },
    {
      'name': 'School',
      'icon': Icons.school_rounded,
      'roles': [
        {'label': 'School Principal',           'icon': Icons.stars_rounded,      'type': 'crown',    'value': 'School Principal'},
        {'label': 'School Admin',               'icon': Icons.school_rounded,     'type': 'school',   'value': 'School Admin'},
        {'label': 'School Teacher',             'icon': Icons.co_present_rounded, 'type': 'school',   'value': 'School Teacher'},
      ],
    },
  ];

  final List<String> _degrees = ['MBBS', 'MD', 'DO', 'BDS', 'DPT (Physiotherapist)', 'Other'];
  List<Map<String, dynamic>> _branches = [];
  String? _usernameError;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _loadBranches();
  }

  @override
  void dispose() {
    _animController.dispose();
    for (final c in [
      _usernameController, _emailController, _passwordController,
      _phoneController, _identificationController, _addressController,
      _bankNameController, _bankAccountController, _customDegreeController,
      _salaryController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBranches() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      var list = snap.docs.map((d) {
        final data = d.data();
        return {'id': d.id, 'name': data['name'] as String? ?? d.id};
      }).toList();

      final role = _getCurrentUserRole();
      final scopedBranchId = _getCurrentUserBranchId();
      final isGlobalExec = ['chairman', 'ceo', 'admin', 'administrator', 'super admin', 'global admin', 'hq manager', 'president', 'founder'].contains(role);
      
      if (!isGlobalExec && scopedBranchId.isNotEmpty && scopedBranchId != 'all' && scopedBranchId != 'global') {
        list = list.where((b) => b['id'].toString().toLowerCase().trim() == scopedBranchId).toList();
      }

      setState(() {
        _branches = list..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
        if (_branches.isNotEmpty && !isGlobalExec) {
          _selectedBranch = _branches.first['name'];
        }
      });
    } catch (e) {
      _snack('Failed to load branches: $e', error: true);
    }
  }

  Future<void> _loadStudentsForBranch(String bId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(bId)
          .collection('madrassa_students')
          .where('isActive', isEqualTo: true)
          .get();
      setState(() {
        _branchStudents = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _branchStudents.sort((a, b) => (a['rollNumber'] ?? '').compareTo(b['rollNumber'] ?? ''));
      });
    } catch (e) {
      _snack('Failed to load students: $e', error: true);
    }
  }

  Future<bool> _usernameExists(String username) async {
    final lower = username.trim().toLowerCase();
    try {
      final box = Hive.box('local_users');
      for (final val in box.values) {
        if (val is Map) {
          final uName = (val['username']?.toString() ?? '').toLowerCase();
          final uNameLower = (val['usernameLower']?.toString() ?? '').toLowerCase();
          if (uName == lower || uNameLower == lower) {
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
          .timeout(const Duration(seconds: 5));
      if (res.docs.isNotEmpty) return true;
    } catch (_) {}

    return false;
  }

  bool _requiresBranch() {
    final r = _selectedRole?.toLowerCase();
    // Global executive roles — no branch scoping needed.
    return r != 'ceo' && r != 'chairman' && r != 'admin' && r != 'hq manager';
  }

  String _getBranchId() {
    if (!_requiresBranch()) return 'all';
    if (_selectedBranch == null) throw Exception('Please select a branch for this role');
    final match = _branches.where((b) => b['name'] == _selectedBranch).toList();
    if (match.isEmpty) throw Exception('Selected branch not found — please re-select');
    return match.first['id'] as String;
  }

  String _getBranchName() =>
      _requiresBranch() ? (_selectedBranch ?? 'Unknown') : 'All Branches';

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

  Future<void> _registerUser() async {
    if (!_formKey.currentState!.validate()) {
      _snack('Please fill all required fields', error: true);
      return;
    }
    if (_selectedRole == null) {
      _snack('Please select a role', error: true);
      return;
    }
    if (_requiresBranch() && _selectedBranch == null) {
      _snack('Please select a branch for this role', error: true);
      return;
    }
    if (_selectedRole == 'Madrassa Parent' && _selectedStudentId == null) {
      _snack('Please select a student for this parent', error: true);
      return;
    }

    setState(() { _usernameError = null; _loading = true; });

    final email    = _emailController.text.trim().toLowerCase();
    final username = _usernameController.text.trim(); // preserve original casing

    try {
      if (await _usernameExists(username)) {
        setState(() => _usernameError = 'Username already taken');
        _snack('Username already exists', error: true);
        return;
      }

      final degree = _selectedDegree == 'Other'
          ? _customDegreeController.text.trim()
          : (_selectedDegree ?? '');

      double? salary;
      final salaryText = _salaryController.text.trim();
      if (salaryText.isNotEmpty) {
        salary = double.tryParse(salaryText);
        if (salary == null) {
          _snack('Invalid salary format', error: true);
          return;
        }
      }

      final enteredPin = _biometricPinController.text.trim();
      if (enteredPin.isNotEmpty) {
        final conflict = ZkTecoNetworkService.findPinConflict(enteredPin);
        if (conflict != null) {
          _snack('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please choose a unique PIN.', error: true);
          return;
        }
      }

      final branchId = _getBranchId();

      final registeredUid = await _authService.signUp(
        email:              email,
        password:           _passwordController.text.trim(),
        username:           username,
        role:               _selectedRole!,
        branchId:           branchId,
        branchName:         _getBranchName(),
        phone:              _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null,
        identification:     _identificationController.text.trim().isNotEmpty ? _identificationController.text.trim() : null,
        address:            _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
        bankName:           _bankNameController.text.trim().isNotEmpty ? _bankNameController.text.trim() : null,
        bankAccount:        _bankAccountController.text.trim().isNotEmpty ? _bankAccountController.text.trim() : null,
        degree:             degree.isNotEmpty ? degree : null,
        salary:             salary,
        biometricPin:       enteredPin.isNotEmpty ? enteredPin : null,
        linkedEmployeeId:   _selectedLinkedEmployeeId,
        studentId:          _selectedStudentId, // Pass the student ID
        dispensaryId:       _selectedDispensary, // Pass dispensary sub-location ('kapayya', 'haji_camp')
        dispensaryIds:      _selectedDispensaries.toList(), // Pass multi-camp assignments
        campSchedule:       _selectedDispensaries.map((id) => {
                              'campId': id,
                              'session': _campSessions[id] ?? 'morning',
                            }).toList(),
        profileImageXFile:  _profileImageXFile,
        profileImageBytes:  _profileImageBytes,
        degreeFile:         _degreeFile,
        profilePictureBase64: _profilePictureBase64,
        degreeBase64:         _degreeBase64,
      );

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
      // Reset the form so the admin can register another user without leaving the page.
      _formKey.currentState!.reset();
      _biometricPinController.clear();
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
        _usernameError        = null;
      });
      for (final c in [
        _usernameController, _emailController, _passwordController,
        _phoneController, _identificationController, _addressController,
        _bankNameController, _bankAccountController,
        _customDegreeController, _salaryController,
      ]) { c.clear(); }
      _snack('$registeredName registered successfully!', success: true);
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
            error ? Icons.error_outline : success ? Icons.check_circle_outline : Icons.info_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
      ]),
      backgroundColor: error ? t.danger : success ? t.accent : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final requiresBranch = _requiresBranch();
    final isDoctor = _selectedRole != null &&
        (_selectedRole!.toLowerCase() == 'doctor' || _selectedRole!.toLowerCase().contains('doc'));

    return Scaffold(
      backgroundColor: t.bg,
      body: Stack(
        children: [
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 210,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [t.accent.withValues(alpha: 0.9), t.accentLight],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // ── Header ──────────────────────────────────────────────
                if (!GlobalModuleWrapper.isWrapped(context)) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 16, 0),
                    child: Row(
                      children: [
                        const AppBackButton(color: Colors.white),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Register New User',
                            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.2),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ] else
                  const SizedBox(height: 16),
                Expanded(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 48),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildAvatarCard(t),
                            const SizedBox(height: 16),

                            _buildCard(t,
                              title: 'Role & Assignment',
                              icon: Icons.badge_outlined,
                              accent: const Color(0xFF6A1B9A),
                              child: Column(children: [
                                _buildDepartmentDropdown(t),
                                const SizedBox(height: 14),
                                _buildRoleDropdown(t),
                                const SizedBox(height: 14),
                                _buildBranchDropdown(t),
                                _buildDispensaryDropdown(t),
                                if (_selectedRole == 'Madrassa Parent') ...[
                                  const SizedBox(height: 14),
                                  _buildChildDropdown(t),
                                ],
                                if (_selectedRole != null && !requiresBranch) ...[
                                  const SizedBox(height: 14),
                                  _buildGlobalBadge(t),
                                ],
                              ]),
                            ),
                            const SizedBox(height: 16),

                            _buildCard(t,
                              title: 'Basic Information',
                              icon: Icons.person_outline_rounded,
                              accent: t.accentLight,
                              child: Column(children: [
                                _buildRow([
                                  _buildField(t,
                                      controller: _usernameController,
                                      label: 'Username',
                                      icon: Icons.alternate_email_rounded,
                                      required: true,
                                      validator: (v) => v?.trim().isEmpty ?? true ? 'Required' : null),
                                  _buildField(t,
                                      controller: _emailController,
                                      label: 'Email',
                                      icon: Icons.mail_outline_rounded,
                                      required: true,
                                      keyboardType: TextInputType.emailAddress,
                                      validator: (v) => v?.trim().isEmpty ?? true ? 'Required' : null),
                                ]),
                                const SizedBox(height: 14),
                                _buildRow([
                                  _buildField(t,
                                      controller: _passwordController,
                                      label: 'Password',
                                      icon: Icons.lock_outline_rounded,
                                      isPassword: true,
                                      required: true,
                                      validator: (v) => (v?.length ?? 0) < 6 ? 'Min 6 chars' : null),
                                  _buildField(t,
                                      controller: _phoneController,
                                      label: 'Phone (11 digits)',
                                      icon: Icons.phone_outlined,
                                      keyboardType: TextInputType.phone,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                        LengthLimitingTextInputFormatter(11),
                                      ]),
                                ]),
                              ]),
                            ),
                            const SizedBox(height: 16),

                            _buildCard(t,
                              title: 'Contact & Address',
                              icon: Icons.contact_mail_outlined,
                              accent: const Color(0xFFE65100),
                              child: Column(children: [
                                _buildField(t,
                                    controller: _identificationController,
                                    label: 'CNIC / ID Number',
                                    icon: Icons.credit_card_outlined),
                                const SizedBox(height: 14),
                                _buildField(t,
                                    controller: _addressController,
                                    label: 'Address',
                                    icon: Icons.home_outlined,
                                    maxLines: 3),
                              ]),
                            ),
                            const SizedBox(height: 16),

                            _buildLinkedEmployeeCard(t),
                            const SizedBox(height: 16),

                            _buildCard(t,
                              title: 'Financial Details',
                              icon: Icons.account_balance_wallet_outlined,
                              accent: t.accent,
                              child: Column(children: [
                                _buildRow([
                                  _buildField(t,
                                      controller: _bankNameController,
                                      label: 'Bank Name',
                                      icon: Icons.account_balance_outlined),
                                  _buildField(t,
                                      controller: _bankAccountController,
                                      label: 'Account No.',
                                      icon: Icons.numbers_outlined,
                                      keyboardType: TextInputType.number),
                                ]),
                                const SizedBox(height: 14),
                                _buildField(t,
                                    controller: _salaryController,
                                    label: 'Base Salary (PKR)',
                                    icon: Icons.payments_outlined,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}'))]),
                                const SizedBox(height: 14),
                                _buildField(t,
                                    controller: _biometricPinController,
                                    label: 'Biometric Scanner PIN (Optional)',
                                    icon: Icons.fingerprint_rounded,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
                              ]),
                            ),

                            if (isDoctor) ...[
                              const SizedBox(height: 16),
                              _buildCard(t,
                                title: 'Medical Qualifications',
                                icon: Icons.local_hospital_outlined,
                                accent: const Color(0xFF00695C),
                                child: Column(children: [
                                  _buildSimpleDropdown(t,
                                    value: _selectedDegree,
                                    items: _degrees,
                                    hint: 'Select Degree *',
                                    icon: Icons.school_outlined,
                                    onChanged: (v) => setState(() {
                                      _selectedDegree = v;
                                      if (v != 'Other') _customDegreeController.clear();
                                    }),
                                    validator: (v) => v == null ? 'Required' : null,
                                  ),
                                  if (_selectedDegree == 'Other') ...[
                                    const SizedBox(height: 14),
                                    _buildField(t,
                                        controller: _customDegreeController,
                                        label: 'Specify Degree',
                                        icon: Icons.edit_outlined,
                                        required: true,
                                        validator: (v) => v?.trim().isEmpty ?? true ? 'Required' : null),
                                  ],
                                ]),
                              ),
                            ],

                            const SizedBox(height: 16),

                            if (isDoctor)
                              _buildCard(t,
                                title: 'Degree & Qualifications',
                                icon: Icons.school_outlined,
                                accent: const Color(0xFF37474F),
                                child: MediaUploadTile(
                                  label: 'Degree Certificate / PMDC',
                                  icon: Icons.school_outlined,
                                  initialValue: _degreeBase64,
                                  isDocument: true,
                                  onChanged: (val) => setState(() => _degreeBase64 = val),
                                ),
                              ),

                            const SizedBox(height: 32),
                            _buildSubmitButton(t),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (_loading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 36),
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 30, offset: Offset(0, 10))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 52, height: 52,
                        child: CircularProgressIndicator(
                            color: t.accent, strokeWidth: 4, backgroundColor: t.accentMuted),
                      ),
                      const SizedBox(height: 20),
                      Text('Creating Account', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.textPrimary)),
                      const SizedBox(height: 6),
                      Text('Please wait...', style: TextStyle(fontSize: 13, color: t.textTertiary)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Widgets ───────────────────────────────────────────────────────────────

  Widget _buildAvatarCard(RoleThemeData t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.bgRule),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 18, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      child: Column(children: [
        GestureDetector(
          onTap: _pickProfileImage,
          child: Stack(children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _profileImageBytes != null ? t.accent : t.bgRule, width: 3),
                boxShadow: [BoxShadow(color: t.accent.withValues(alpha: 0.15), blurRadius: 18, offset: const Offset(0, 6))],
              ),
              child: Builder(
                builder: (context) {
                  final displayBytes = _profileImageBytes ?? ImageUploadService.decodeBase64ToBytes(_profilePictureBase64);
                  return CircleAvatar(
                    radius: 54,
                    backgroundColor: t.accentMuted,
                    backgroundImage: displayBytes != null ? MemoryImage(displayBytes) : null,
                    child: displayBytes == null
                        ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(Icons.person_outline_rounded, size: 38, color: t.accent.withValues(alpha: 0.4)),
                            const SizedBox(height: 4),
                            Text('Add Photo', style: TextStyle(fontSize: 11, color: t.textTertiary, fontWeight: FontWeight.w500)),
                          ])
                        : null,
                  );
                },
              ),
            ),
            Positioned(
              right: 2, bottom: 2,
              child: GestureDetector(
                onTap: _profileImageBytes != null ? _removeProfileImage : _pickProfileImage,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _profileImageBytes != null ? t.danger : t.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: t.bgCard, width: 2.5),
                  ),
                  child: Icon(
                    _profileImageBytes != null ? Icons.close_rounded : Icons.camera_alt_rounded,
                    color: Colors.white, size: 14,
                  ),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text('Profile Picture', style: TextStyle(fontSize: 13, color: t.textTertiary, fontWeight: FontWeight.w500)),
        const SizedBox(height: 3),
        Text('Optional', style: TextStyle(fontSize: 11, color: t.textTertiary)),
      ]),
    );
  }

  Widget _buildDepartmentDropdown(RoleThemeData t) {
    return DropdownButtonFormField<String>(
      value: _selectedDepartment,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      hint: Row(children: [
        Icon(Icons.category_outlined, color: t.textTertiary, size: 20),
        const SizedBox(width: 10),
        Text('Select Department / Category *', style: TextStyle(color: t.textTertiary, fontSize: 13)),
      ]),
      decoration: InputDecoration(
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      items: _departments.map((dept) {
        return DropdownMenuItem<String>(
          value: dept['name'] as String,
          child: Row(children: [
            Icon(dept['icon'] as IconData, color: t.accent, size: 18),
            const SizedBox(width: 10),
            Text(dept['name'] as String,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
          ]),
        );
      }).toList(),
      onChanged: (val) => setState(() {
        _selectedDepartment = val;
        _selectedRole = null;
        _selectedDegree = null;
        _customDegreeController.clear();
        _degreeFile = null;
        if (!_requiresBranch()) _selectedBranch = null;
      }),
      validator: (val) => val == null ? 'Please select a department' : null,
    );
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

  Widget _buildRoleDropdown(RoleThemeData t) {
    List<Map<String, dynamic>> roles = _selectedDepartment == null
        ? []
        : List<Map<String, dynamic>>.from(_departments.firstWhere((d) => d['name'] == _selectedDepartment)['roles'] as List);

    if (_getCurrentUserRole() != 'chairman') {
      roles = roles.where((r) => (r['value'] as String).toLowerCase().trim() != 'chairman').toList();
    }

    return DropdownButtonFormField<String>(
      key: ValueKey(_selectedDepartment),
      value: _selectedRole,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      hint: Row(children: [
        Icon(Icons.badge_outlined, color: t.textTertiary, size: 20),
        const SizedBox(width: 10),
        Text(
          _selectedDepartment == null ? 'Select Department first *' : 'Select Role *',
          style: TextStyle(color: t.textTertiary, fontSize: 13),
        ),
      ]),
      decoration: InputDecoration(
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      selectedItemBuilder: (context) => roles.map((role) {
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
        return Row(children: [
          Icon(role['icon'] as IconData, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Text(role['label'] as String,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
        ]);
      }).toList(),
      items: roles.map((role) {
        final type = role['type'] as String;
        final isCrown    = type == 'crown';
        final isShield   = type == 'shield';
        final isMadrassa = type == 'madrassa';
        final isHybrid   = type == 'hybrid';
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
                    : t.bgCardAlt;

        return DropdownMenuItem<String>(
          value: role['value'] as String,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(8)),
                child: Icon(role['icon'] as IconData, color: iconColor, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(role['label'] as String,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: (isCrown || isShield || isMadrassa || isHybrid) ? FontWeight.w700 : FontWeight.w500,
                        color: textColor)),
              ),
              if (isCrown)    _roleBadge('Authority', t.accent),
              if (isShield)   _roleBadge('Server', t.accentLight),
              if (isMadrassa) _roleBadge('Madrassa', madrassaColor),
              if (isHybrid)   _roleBadge('Hybrid', hybridColor),
            ]),
          ),
        );
      }).toList(),
      onChanged: roles.isEmpty
          ? null
          : (val) => setState(() {
                _selectedRole = val;
                if (val != 'Doctor' && val != 'doc+rec' && val != 'doc+dis' && val != 'doc+rec+dis') {
                  _selectedDegree = null;
                  _customDegreeController.clear();
                  _degreeFile = null;
                }
                if (!_requiresBranch()) _selectedBranch = null;
              }),
      validator: (val) => val == null ? 'Role is mandatory' : null,
    );
  }

  Widget _roleBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.9), fontWeight: FontWeight.w700)),
      );

  Widget _buildBranchDropdown(RoleThemeData t) {
    final requiresBranch = _requiresBranch();
    final isBranchLoading = _branches.isEmpty;
    final hintText = !requiresBranch
        ? 'Global Access (No branch required)'
        : (isBranchLoading ? 'Loading branches...' : 'Select Branch *');

    return DropdownButtonFormField<String>(
      key: ValueKey('branch_${requiresBranch}_${_selectedBranch}'),
      value: _selectedBranch,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.location_city_rounded, color: t.textTertiary, size: 20),
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
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
                child: Text(name, style: TextStyle(fontSize: 14, color: t.textPrimary)),
              );
            }).toList(),
      onChanged: !requiresBranch
          ? null
          : (v) {
              setState(() {
                _selectedBranch = v;
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

    return Padding(
      padding: const EdgeInsets.only(top: 14.0),
      child: Container(
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
                  'Assigned Camp Facilities & Mandatory Shift Schedule',
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
                  selected: isAllSelected,
                  selectedColor: t.accent.withValues(alpha: 0.2),
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
                    selectedColor: t.accent.withValues(alpha: 0.2),
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
              const SizedBox(height: 14),
              const Text(
                'Mandatory Session per Selected Facility:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal),
              ),
              const SizedBox(height: 8),
              ..._selectedDispensaries.map((campId) {
                final campLabel = rawDispensaries.firstWhere(
                  (d) => d['id']?.toString().toLowerCase().trim() == campId,
                  orElse: () => {'name': campId},
                )['name'];
                final currentSession = _campSessions[campId] ?? 'morning';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.teal.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Colors.teal.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          campLabel,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.teal.shade900),
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
      ),
    );
  }

  Widget _buildChildDropdown(RoleThemeData t) {
    final hasBranch = _selectedBranch != null;
    final hintText = !hasBranch
        ? 'Select Branch first *'
        : (_branchStudents.isEmpty ? 'No students found' : 'Select Child (Student) *');

    final studentExists = _branchStudents.any((s) => s['id'] == _selectedStudentId);
    final selectedId = studentExists ? _selectedStudentId : null;

    return DropdownButtonFormField<String>(
      key: ValueKey('child_${_selectedBranch}_${selectedId}'),
      value: selectedId,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.child_care_rounded, color: t.textTertiary, size: 20),
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
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
                child: Text('$name (Roll: $roll)', style: TextStyle(fontSize: 14, color: t.textPrimary)),
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
        gradient: LinearGradient(colors: [t.accent.withValues(alpha: 0.10), t.accent.withValues(alpha: 0.04)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.accent.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.workspace_premium_rounded, color: t.accent, size: 22),
        ),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Global Access Granted', style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 2),
          Text('Full access to all branches', style: TextStyle(color: t.textSecondary, fontSize: 12)),
        ]),
      ]),
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
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.bgRule),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.bgRule))),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: accent, size: 18),
            ),
            const SizedBox(width: 12),
            Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary, letterSpacing: 0.1)),
          ]),
        ),
        Padding(padding: const EdgeInsets.all(18), child: child),
      ]),
    );
  }

  Widget _buildRow(List<Widget> children) {
    return Row(
      children: children
          .expand((w) => [Expanded(child: w), const SizedBox(width: 12)])
          .toList()
        ..removeLast(),
    );
  }

  Widget _buildField(RoleThemeData t, {
    required TextEditingController controller,
    required String label,
    required IconData icon,
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
      style: TextStyle(fontSize: 14, color: t.textPrimary, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        labelStyle: TextStyle(fontSize: 13, color: t.textTertiary),
        floatingLabelStyle: TextStyle(fontSize: 12, color: t.accent, fontWeight: FontWeight.w600),
        prefixIcon: Icon(icon, color: t.textTertiary, size: 20),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                    _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: t.textTertiary, size: 20),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword))
            : null,
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: maxLines > 1 ? 14 : 0),
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
    required String? value,
    required List<String> items,
    required String hint,
    required IconData icon,
    required Function(String?)? onChanged,
    String? Function(String?)? validator,
    String Function(String)? itemLabel,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      hint: Text(hint, style: TextStyle(color: t.textTertiary, fontSize: 13)),
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
      dropdownColor: t.bgCard,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: t.textTertiary, size: 20),
        filled: true,
        fillColor: t.bgCardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      items: items.map((e) => DropdownMenuItem(
          value: e,
          child: Text(
            itemLabel != null ? itemLabel(e) : e,
            style: TextStyle(fontSize: 14, color: t.textPrimary),
          ))).toList(),
      onChanged: onChanged,
      validator: validator,
    );
  }

  Widget _buildSubmitButton(RoleThemeData t) {
    return GestureDetector(
      onTap: _loading ? null : _registerUser,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [t.accent, t.accentLight],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: t.accent.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: _loading
            ? const Center(child: SizedBox(width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)))
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 22),
                  SizedBox(width: 12),
                  Text('Create Account', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                ],
              ),
      ),
    );
  }

  Widget _buildLinkedEmployeeCard(RoleThemeData t) {
    if (!Hive.isBoxOpen(LocalStorageService.employeesBox)) return const SizedBox.shrink();
    final empBox = Hive.box(LocalStorageService.employeesBox);
    final employees = empBox.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return _buildCard(t,
      title: 'Linked Employee Profile',
      icon: Icons.badge_outlined,
      accent: const Color(0xFF6366F1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _selectedLinkedEmployeeId,
                  decoration: roleInputDecoration(
                    context,
                    label: 'Select Employee Profile',
                    icon: Icons.person_search_rounded,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No Employee Linked (Standalone Account)'),
                    ),
                    ...employees.map((emp) {
                      final empId = emp['id']?.toString() ?? emp['localId']?.toString() ?? '';
                      final empName = emp['name']?.toString() ?? 'Employee';
                      final empDept = emp['department']?.toString() ?? '';
                      final empCnic = emp['cnic']?.toString() ?? '';
                      return DropdownMenuItem<String?>(
                        value: empId,
                        child: Text('$empName ${empDept.isNotEmpty ? "($empDept)" : ""} ${empCnic.isNotEmpty ? "- $empCnic" : ""}'),
                      );
                    }),
                  ],
                  onChanged: (val) {
                    setState(() {
                      _selectedLinkedEmployeeId = val;
                      _matchedReasonText = 'Manually Linked by Admin';
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Auto-Match by CNIC, Email, Name & Role',
                child: ElevatedButton.icon(
                  onPressed: _autoDetectEmployeeMatch,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('Auto-Match'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
          if (_matchedReasonText != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Color(0xFF4F46E5), size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Status: $_matchedReasonText',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF3730A3)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
