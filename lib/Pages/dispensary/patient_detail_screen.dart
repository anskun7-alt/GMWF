// lib/pages/patient_detail_screen.dart — Role-Theme Aware + Full Mobile Responsive

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:gmwf/pages/dispensary/doctor/patient_history.dart';
import 'dart:async';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/theme/role_theme_provider.dart';
import 'package:gmwf/theme/app_theme.dart';
import 'package:gmwf/widgets/app_back_button.dart';
import 'package:gmwf/widgets/app_skeleton.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';

class PatientDetailScreen extends StatefulWidget {
  final String patientId;
  final bool isOnline;
  final Box localBox;
  final String branchId;
  final String doctorId;
  final bool isAdmin;

  const PatientDetailScreen({
    super.key,
    required this.patientId,
    required this.isOnline,
    required this.localBox,
    required this.branchId,
    required this.doctorId,
    this.isAdmin = false,
  });

  @override
  State<PatientDetailScreen> createState() => _PatientDetailScreenState();
}

class _PatientDetailScreenState extends State<PatientDetailScreen>
    with SingleTickerProviderStateMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController _noteController       = TextEditingController();
  final TextEditingController _medicineController   = TextEditingController();
  final TextEditingController _nameController       = TextEditingController();
  final TextEditingController _cnicController       = TextEditingController();
  final TextEditingController _guardianCnicController = TextEditingController();
  final TextEditingController _phoneController      = TextEditingController();
  final TextEditingController _dobController        = TextEditingController();
  final TextEditingController _ageController        = TextEditingController();

  String? _selectedGender;
  String? _selectedBloodGroup;
  String? _selectedStatus;
  String? branchName;

  late String _currentPatientId;
  Map<String, dynamic>? _currentPatientData;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  static const Map<String, Color> _statusColors = {
    'Zakat': Color(0xFF1565C0),
    'Non-Zakat': Color(0xFF6A1B9A),
    'GMWF': Color(0xFF2E7D32),
  };

  @override
  void initState() {
    super.initState();
    _currentPatientId = widget.patientId;
    _loadLocalPatientData();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _fetchBranchName();
  }

  void _loadLocalPatientData() {
    final local = LocalStorageService.getLocalPatient(_currentPatientId) ??
        LocalStorageService.getLocalPatientByCnic(_currentPatientId);
    if (local != null) {
      _currentPatientData = local;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _noteController.dispose(); _medicineController.dispose(); _nameController.dispose();
    _cnicController.dispose(); _guardianCnicController.dispose(); _phoneController.dispose();
    _dobController.dispose(); _ageController.dispose();
    super.dispose();
  }

  Future<void> _fetchBranchName() async {
    try {
      final doc = await _firestore.collection('branches').doc(widget.branchId.toLowerCase()).get();
      if (doc.exists) setState(() => branchName = doc.data()!['name'] as String? ?? widget.branchId);
    } catch (_) {}
  }

  List<Map<String, dynamic>> _getLocalChildren(String? cnic) {
    if (cnic == null || cnic.isEmpty) return [];
    final clean = cnic.replaceAll(RegExp(r'\D'), '');
    if (clean.isEmpty) return [];
    final all = LocalStorageService.getAllLocalPatients();
    return all.where((p) {
      if (p['isAdult'] == true) return false;
      final g = (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
      return g == clean;
    }).toList();
  }

  Map<String, dynamic>? _getLocalGuardian(String? guardianCnic) {
    if (guardianCnic == null || guardianCnic.trim().isEmpty || guardianCnic == 'Unknown') return null;
    return LocalStorageService.getLocalPatientByCnic(guardianCnic);
  }

  Stream<DocumentSnapshot>? _patientStream() {
    if (_currentPatientData != null || LocalStorageService.getLocalPatient(_currentPatientId) != null) {
      return null;
    }
    return _firestore
        .collection('branches').doc(widget.branchId.toLowerCase()).collection('patients').doc(_currentPatientId).get().asStream();
  }

  Stream<QuerySnapshot> _childrenStream(String? cnic) => _firestore
      .collection('branches').doc(widget.branchId.toLowerCase()).collection('patients')
      .where('guardianCnic', isEqualTo: cnic).where('isAdult', isEqualTo: false).limit(10).get().asStream();

  Future<DocumentSnapshot?> _getGuardian(String? guardianCnic) async {
    if (guardianCnic == null || guardianCnic.trim().isEmpty || guardianCnic == 'Unknown') return null;
    final qs = await _firestore.collection('branches').doc(widget.branchId.toLowerCase())
        .collection('patients').where('cnic', isEqualTo: guardianCnic.trim()).limit(1).get();
    return qs.docs.isNotEmpty ? qs.docs[0] : null;
  }

  Future<bool> _checkPassword(RoleThemeData t) async {
    final ctrl = TextEditingController();
    bool verified = false;
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.lock_outline_rounded, color: t.accent, size: 22)),
              const SizedBox(width: 12),
              Text('Admin Verification', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: t.textPrimary)),
            ]),
            const SizedBox(height: 20),
            TextField(
              controller: ctrl, obscureText: true, autofocus: true,
              style: TextStyle(fontSize: 14, color: t.textPrimary),
              decoration: InputDecoration(
                hintText: 'Enter admin password',
                hintStyle: TextStyle(color: t.textTertiary),
                prefixIcon: Icon(Icons.password_rounded, color: t.textTertiary, size: 20),
                filled: true, fillColor: t.bg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.bgRule))),
                child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600)),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(
                onPressed: () {
                  if (ctrl.text.trim() == 'admin1122') {
                    verified = true;
                    Navigator.pop(ctx);
                  } else {
                    _snack('Wrong password', error: true);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
                child: const Text('Verify', style: TextStyle(fontWeight: FontWeight.w700)),
              )),
            ]),
          ]),
        ),
      ),
    );
    return verified;
  }

  void _showEditDialog(Map<String, dynamic> data, RoleThemeData t) async {
    final ok = await _checkPassword(t);
    if (!ok || !mounted) return;
    final editKey = GlobalKey<FormState>();
    final isAdult = data['isAdult'] == true;
    _nameController.text = data['name'] ?? '';
    _cnicController.text = data['cnic'] ?? '';
    _guardianCnicController.text = data['guardianCnic'] ?? '';
    _phoneController.text = data['phone'] ?? '';
    _ageController.text = data['age']?.toString() ?? '';
    _selectedGender = data['gender'];
    _selectedBloodGroup = data['bloodGroup'] ?? 'N/A';
    _selectedStatus = data['status'] ?? 'Zakat';
    final dobTs = data['dob'] as Timestamp?;
    _dobController.text = dobTs != null ? DateFormat('dd-MM-yyyy').format(dobTs.toDate()) : '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: t.bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
              decoration: BoxDecoration(color: t.accent, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
              child: Row(children: [
                const Icon(Icons.edit_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                const Expanded(child: Text('Edit Patient', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800))),
                IconButton(onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20), padding: EdgeInsets.zero),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Form(key: editKey, child: Column(children: [
                  _editField(t, _nameController, 'Full Name', Icons.person_outline_rounded,
                      validator: (v) => v?.isEmpty ?? true ? 'Required' : null),
                  _editField(t, _cnicController, 'CNIC (XXXXX-XXXXXXX-X)', Icons.credit_card_outlined,
                      maxLen: 15, formatters: [CNICInputFormatter()], validator: (v) {
                        final r = RegExp(r'^\d{5}-\d{7}-\d{1}$');
                        if (!isAdult && (v?.isEmpty ?? true)) return null;
                        if (v?.isEmpty ?? true) return 'Required';
                        if (!r.hasMatch(v!)) return 'Format: 12345-1234567-1';
                        return null;
                      }),
                  if (!isAdult)
                    _editField(t, _guardianCnicController, 'Guardian CNIC', Icons.credit_card_outlined,
                        maxLen: 15, formatters: [CNICInputFormatter()], validator: (v) {
                          final r = RegExp(r'^\d{5}-\d{7}-\d{1}$');
                          if (v?.isEmpty ?? true) return 'Required';
                          if (!r.hasMatch(v!)) return 'Format: 12345-1234567-1';
                          return null;
                        }),
                  _editField(t, _phoneController, 'Phone (11 digits)', Icons.phone_outlined,
                      type: TextInputType.phone, maxLen: 11,
                      formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)], validator: (v) {
                        if (v != null && v.isNotEmpty && v.length != 11) return '11 digits required';
                        return null;
                      }),
                  _editField(t, _dobController, 'Date of Birth (dd-MM-yyyy)', Icons.cake_outlined,
                      type: TextInputType.datetime,
                      formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                        LengthLimitingTextInputFormatter(10), _DobFormatter()],
                      onChanged: (v) {
                        final parsed = parseDobDateTime(v);
                        if (parsed != null) {
                          final today = DateTime.now();
                          int age = today.year - parsed.year;
                          if (today.month < parsed.month || (today.month == parsed.month && today.day < parsed.day)) age--;
                          _ageController.text = age.toString();
                        }
                      },
                      validator: (v) {
                        if (v!.isEmpty) return 'Required';
                        if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(v)) return 'Use dd-MM-yyyy';
                        return null;
                      }),
                  _editField(t, _ageController, 'Age', Icons.calendar_today_outlined,
                      type: TextInputType.number,
                      validator: (v) => int.tryParse(v ?? '') == null ? 'Invalid age' : null),
                  const SizedBox(height: 4),
                  _editDropdown(t: t, value: _selectedGender, label: 'Gender', icon: Icons.wc_rounded,
                      items: const ['Male', 'Female', 'Other'], onChanged: (v) => setS(() => _selectedGender = v)),
                  _editDropdown(t: t, value: _selectedBloodGroup, label: 'Blood Group', icon: Icons.bloodtype_outlined,
                      items: const ['N/A', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'],
                      onChanged: (v) => setS(() => _selectedBloodGroup = v)),
                  _editDropdown(t: t, value: _selectedStatus, label: 'Status', icon: Icons.mosque_rounded,
                      items: const ['Zakat', 'Non-Zakat', 'GMWF'], onChanged: (v) => setS(() => _selectedStatus = v)),
                ])),
              ),
            ),
            Divider(height: 1, thickness: 1, color: t.bgRule),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
              ),
              child: Row(children: [
                Expanded(child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.bgRule))),
                  child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600)),
                )),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: ElevatedButton.icon(
                  icon: const Icon(Icons.save_rounded, size: 17),
                  label: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w700)),
                  onPressed: () async => _savePatient(ctx, editKey, isAdult),
                  style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
                )),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _savePatient(BuildContext ctx, GlobalKey<FormState> key, bool isAdult) async {
    if (!key.currentState!.validate()) return;
    final updates = <String, dynamic>{
      'name': _nameController.text.trim(),
      'patientName': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _selectedGender,
      'bloodGroup': _selectedBloodGroup ?? 'N/A',
      'status': _selectedStatus ?? 'Zakat',
      'age': int.tryParse(_ageController.text) ?? 0,
      'isAdult': (int.tryParse(_ageController.text) ?? 0) >= 18,
    };
    final newCnic = _cnicController.text.trim();
    final newGuardianCnic = _guardianCnicController.text.trim();
    if (updates['isAdult'] == true) {
      updates['cnic'] = newCnic;
      updates['patientCnic'] = newCnic;
      updates['guardianCnic'] = null;
    } else {
      updates['guardianCnic'] = newGuardianCnic;
      updates['cnic'] = null;
    }
    if (_dobController.text.isNotEmpty) {
      final parsedDob = parseDobDateTime(_dobController.text);
      if (parsedDob != null) {
        updates['dob'] = Timestamp.fromDate(parsedDob);
      }
    }
    updates['branchId'] = widget.branchId.toLowerCase();

    // 1. Save & migrate CNIC atomically across local storage and active entries
    String updatedKey = _currentPatientId;
    try {
      updatedKey = await LocalStorageService.updatePatientWithCnicMigration(
        oldPatientId: _currentPatientId,
        updatedPatient: updates,
        oldCnic: _currentPatientData?['cnic']?.toString() ?? _currentPatientData?['guardianCnic']?.toString(),
      );
    } catch (e) {
      debugPrint('[PatientDetail] Local save error: $e');
    }

    if (mounted) {
      setState(() {
        _currentPatientId = updatedKey;
        _currentPatientData = updates;
      });
    }

    _snack('Patient details & CNIC updated instantly!', success: true);
    if (ctx.mounted) Navigator.pop(ctx);
  }

  Future<void> _addPrescription() async {
    final note = _noteController.text.trim();
    final medicine = _medicineController.text.trim();
    if (note.isEmpty && medicine.isEmpty) { _snack('Enter note or medicine', error: true); return; }
    final data = {
      'timestamp': FieldValue.serverTimestamp(), 'doctorId': widget.doctorId,
      'note': note, 'medicines': medicine.isNotEmpty ? [{'name': medicine, 'quantity': 1}] : [],
    };
    try {
      if (widget.isOnline) {
        await _firestore.collection('branches').doc(widget.branchId.toLowerCase())
            .collection('prescriptions').doc(widget.patientId).collection('prescriptions').add(data);
        _snack('Prescription added', success: true);
      } else {
        final pending = widget.localBox.get('pendingPrescriptions', defaultValue: []) as List;
        pending.add({'branchId': widget.branchId.toLowerCase(), 'patientId': widget.patientId, 'data': data});
        await widget.localBox.put('pendingPrescriptions', pending);
        _snack('Saved offline');
      }
    } catch (e) { _snack('Error: $e', error: true); }
    finally { _noteController.clear(); _medicineController.clear(); }
  }

  void _deletePatient(RoleThemeData t) async {
    if (!await _checkPassword(t)) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: t.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: t.danger.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(Icons.delete_forever_rounded, color: t.danger, size: 32)),
          const SizedBox(height: 16),
          Text('Delete Patient?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: t.textPrimary)),
          const SizedBox(height: 8),
          Text('This action cannot be undone.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.textSecondary)),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.bgRule))),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600)),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
              child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w700)),
            )),
          ]),
        ])),
      ),
    );
    if (confirmed != true) return;
    try {
      await _firestore.collection('branches').doc(widget.branchId.toLowerCase())
          .collection('patients').doc(widget.patientId).delete();
      _snack('Patient deleted', success: true);
      if (mounted) Navigator.pop(context);
    } catch (e) { _snack('Error: $e', error: true); }
  }

  void _snack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error ? Icons.error_outline : success ? Icons.check_circle_outline : Icons.info_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
      ]),
      backgroundColor: error ? const Color(0xFFB00020) : success ? const Color(0xFF2E7D32) : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final localData = _currentPatientData ?? LocalStorageService.getLocalPatient(_currentPatientId);
    if (localData != null) {
      return Scaffold(
        backgroundColor: t.bg,
        body: FadeTransition(
          opacity: _fadeAnim,
          child: LayoutBuilder(builder: (context, constraints) {
            return constraints.maxWidth > 700
                ? _wideLayout(localData, t)
                : _narrowLayout(localData, t);
          }),
        ),
      );
    }

    return Scaffold(
      backgroundColor: t.bg,
      body: StreamBuilder<DocumentSnapshot>(
        stream: _patientStream(),
        builder: (context, snapshot) {
          final localData = _currentPatientData ?? LocalStorageService.getLocalPatient(_currentPatientId);
          Map<String, dynamic>? data;

          if (snapshot.hasData && snapshot.data!.exists) {
            data = snapshot.data!.data() as Map<String, dynamic>;
            _currentPatientData = data;
          } else if (localData != null) {
            data = localData;
          }

          if (data == null) {
            if (snapshot.hasError) {
              return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline_rounded, size: 48, color: t.danger.withValues(alpha: 0.6)),
                const SizedBox(height: 12),
                Text('Error loading patient', style: TextStyle(fontWeight: FontWeight.w600, color: t.textSecondary)),
              ]));
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const PatientDetailSkeleton();
            }
            return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.person_off_outlined, size: 48, color: t.textTertiary),
              const SizedBox(height: 12),
              Text('Patient not found', style: TextStyle(fontWeight: FontWeight.w600, color: t.textSecondary)),
            ]));
          }

          return FadeTransition(
            opacity: _fadeAnim,
            child: LayoutBuilder(builder: (context, constraints) {
              return constraints.maxWidth > 700
                  ? _wideLayout(data!, t)
                  : _narrowLayout(data!, t);
            }),
          );
        },
      ),
    );
  }

  Widget _wideLayout(Map<String, dynamic> data, RoleThemeData t) {
    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildTopBar(data, t),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left Column: Patient Profile & Details (Scrollable)
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _buildInfoWidgets(data, t),
              ),
            ),
          ),
          VerticalDivider(width: 1, color: t.bgRule),
          // Right Column: Visit History & Prescriptions
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 16),
              child: _buildHistoryPanel(data, t),
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrowLayout(Map<String, dynamic> data, RoleThemeData t) {
    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildTopBar(data, t),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ..._buildInfoWidgets(data, t),
            const SizedBox(height: 12),
            SizedBox(
              height: 600,
              child: _buildHistoryPanel(data, t),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopBar(Map<String, dynamic> data, RoleThemeData t) {
    final name = data['name'] ?? 'Patient';
    final age = data['age']?.toString() ?? '?';
    final gender = data['gender'] ?? 'N/A';
    final status = data['status'] as String? ?? 'Zakat';
    final statusColor = _statusColors[status] ?? t.accent;

    return AppBar(
      elevation: 0,
      backgroundColor: t.bgCard,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      leading: Navigator.canPop(context)
          ? AppBackButton(color: t.textPrimary)
          : null,
      titleSpacing: Navigator.canPop(context) ? 0 : 16,
      title: Row(
        children: [
          // Avatar
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [t.accent, t.accentLight],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              name.trim().isEmpty ? '?' : name.trim().split(' ').map((w) => w[0]).take(2).join().toUpperCase(),
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 12),
          // Name & Badges
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: t.textPrimary,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        status,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: statusColor,
                        ),
                      ),
                    ),
                    Builder(builder: (context) {
                      final staffInfo = StaffPatientLinkService.getStaffInfoForPatient(
                        cnic: data['cnic'] ?? data['guardianCnic'],
                        name: data['name'],
                      );
                      if (staffInfo != null) {
                        return Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: StaffPatientLinkService.buildStaffBadge(
                            staffInfo,
                            isDark: Theme.of(context).brightness == Brightness.dark,
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '$gender • $age yrs',
                      style: TextStyle(fontSize: 11.5, color: t.textSecondary, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.location_on_outlined, size: 12, color: t.textTertiary),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        branchName ?? widget.branchId,
                        style: TextStyle(fontSize: 11, color: t.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: widget.isAdmin
          ? [
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: t.accentMuted,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.edit_outlined, size: 18, color: t.accent),
                ),
                tooltip: 'Edit Patient',
                onPressed: () => _showEditDialog(data, t),
              ),
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: t.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.delete_outline_rounded, size: 18, color: t.danger),
                ),
                tooltip: 'Delete Patient',
                onPressed: () => _deletePatient(t),
              ),
              const SizedBox(width: 12),
            ]
          : null,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, color: t.bgRule),
      ),
    );
  }

  Widget _buildHistoryPanel(Map<String, dynamic> data, RoleThemeData t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.bgRule)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: t.accentMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.history_rounded, color: t.accent, size: 16),
                ),
                const SizedBox(width: 8),
                Text(
                  'Visit History',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: t.textPrimary),
                ),
              ],
            ),
          ),
          if (!widget.isAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: _buildPrescriptionForm(t),
            ),
          Expanded(
            child: PatientHistory(
              branchId: widget.branchId,
              patientData: data,
              patientCnic: widget.patientId,
              onRepeatLast: (visit) {},
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrescriptionForm(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.accentMuted.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.note_add_rounded, color: t.accent, size: 15),
              const SizedBox(width: 6),
              Text(
                'Quick Prescription Note',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: t.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _prescField(t, _noteController, 'Note / Diagnosis', Icons.description_outlined),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _prescField(t, _medicineController, 'Medicine (e.g. Paracetamol)', Icons.medication_outlined),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.save_rounded, size: 14),
                label: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                onPressed: _addPrescription,
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _prescField(RoleThemeData t, TextEditingController ctrl, String hint, IconData icon) {
    return TextField(
      controller: ctrl,
      style: TextStyle(fontSize: 13, color: t.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: t.textTertiary, fontSize: 12),
        prefixIcon: Icon(icon, color: t.textTertiary, size: 16),
        filled: true,
        fillColor: t.bgCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.accent, width: 1.5)),
      ),
    );
  }

  List<Widget> _buildInfoWidgets(Map<String, dynamic> data, RoleThemeData t) {
    final isAdult = data['isAdult'] == true;
    final dobString = data['dob'] is Timestamp
        ? DateFormat('dd MMM yyyy').format((data['dob'] as Timestamp).toDate())
        : 'N/A';
    final joined = _parseDate(data['createdAt']);

    return [
      _card(
        t,
        'Patient Information',
        Icons.badge_outlined,
        t.accent,
        [
          _infoRowWithCopy(t, 'Patient ID', _currentPatientId, Icons.fingerprint_rounded),
          _infoRow(t, 'Date of Birth', dobString, Icons.cake_outlined),
          _infoRow(t, 'Blood Group', data['bloodGroup'] ?? 'N/A', Icons.bloodtype_outlined),
          _infoRow(t, 'Status', data['status'] ?? 'N/A', Icons.mosque_rounded),
          _infoRow(t, 'Phone', data['phone'] ?? 'N/A', Icons.phone_outlined),
          if (isAdult)
            _infoRowWithEdit(t, 'CNIC', data['cnic'] ?? 'N/A', Icons.credit_card_outlined, onEdit: () => _showEditDialog(data, t))
          else
            _infoRowWithEdit(t, 'Guardian CNIC', data['guardianCnic'] ?? 'N/A', Icons.credit_card_outlined, onEdit: () => _showEditDialog(data, t)),
          _infoRow(t, 'Branch', branchName ?? widget.branchId, Icons.location_on_outlined),
          _infoRow(t, 'Registered', joined, Icons.calendar_today_outlined),
        ],
        trailing: widget.isAdmin
            ? InkWell(
                onTap: () => _showEditDialog(data, t),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_rounded, size: 12, color: t.accent),
                      const SizedBox(width: 4),
                      Text('Edit Card', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent)),
                    ],
                  ),
                ),
              )
            : null,
      ),
      const SizedBox(height: 12),
      _buildFamilySection(data, t),
    ];
  }

  Widget _buildFamilySection(Map<String, dynamic> data, RoleThemeData t) {
    final isAdult = data['isAdult'] == true;
    if (isAdult) {
      final cnic = data['cnic']?.toString();
      final localChildren = _getLocalChildren(cnic);
      if (localChildren.isNotEmpty) {
        return _card(t, 'Family Members', Icons.family_restroom_rounded, const Color(0xFF1565C0),
            localChildren.map((d) {
              return _infoRow(t, '${d['name'] ?? 'N/A'} (${d['age'] ?? '?'} yrs)', '${d['gender'] ?? 'N/A'}',
                  Icons.person_outline_rounded);
            }).toList());
      }

      return StreamBuilder<QuerySnapshot>(
        stream: _childrenStream(cnic),
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data!.docs.isEmpty) return const SizedBox.shrink();
          return _card(t, 'Family Members', Icons.family_restroom_rounded, const Color(0xFF1565C0),
              snap.data!.docs.map((doc) {
                final d = doc.data() as Map<String, dynamic>;
                return _infoRow(t, '${d['name'] ?? 'N/A'} (${d['age'] ?? '?'} yrs)', '${d['gender'] ?? 'N/A'}',
                    Icons.person_outline_rounded);
              }).toList());
        },
      );
    } else {
      final guardianCnic = data['guardianCnic']?.toString();
      final localGuardian = _getLocalGuardian(guardianCnic);
      if (localGuardian != null) {
        return _card(t, 'Guardian Details', Icons.shield_outlined, const Color(0xFF6A1B9A), [
          _infoRow(t, 'Guardian Name', localGuardian['name'] ?? 'N/A', Icons.person_outline_rounded),
          _infoRow(t, 'Age', '${localGuardian['age'] ?? '?'} yrs', Icons.calendar_today_outlined),
          _infoRow(t, 'Gender', localGuardian['gender'] ?? 'N/A', Icons.wc_rounded),
          _infoRow(t, 'CNIC', data['guardianCnic'] ?? 'N/A', Icons.credit_card_outlined),
        ]);
      }

      return FutureBuilder<DocumentSnapshot?>(
        future: _getGuardian(guardianCnic),
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data == null) {
            return _card(t, 'Guardian Details', Icons.shield_outlined, const Color(0xFF6A1B9A), [
              _infoRow(t, 'Status', 'Ungrouped Child', Icons.info_outline_rounded),
            ]);
          }
          final gd = snap.data!.data() as Map<String, dynamic>;
          return _card(t, 'Guardian Details', Icons.shield_outlined, const Color(0xFF6A1B9A), [
            _infoRow(t, 'Guardian Name', gd['name'] ?? 'N/A', Icons.person_outline_rounded),
            _infoRow(t, 'Age', '${gd['age'] ?? '?'} yrs', Icons.calendar_today_outlined),
            _infoRow(t, 'Gender', gd['gender'] ?? 'N/A', Icons.wc_rounded),
            _infoRow(t, 'CNIC', data['guardianCnic'] ?? 'N/A', Icons.credit_card_outlined),
          ]);
        },
      );
    }
  }

  Widget _card(RoleThemeData t, String title, IconData icon, Color accent, List<Widget> children, {Widget? trailing}) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.bgRule, width: 1),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: accent, size: 15),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: t.textPrimary),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          Divider(height: 1, color: t.bgRule),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _infoRowWithEdit(RoleThemeData t, String label, String value, IconData icon, {VoidCallback? onEdit}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: t.textTertiary),
          const SizedBox(width: 8),
          SizedBox(
            width: 95,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: t.textSecondary, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.isAdmin && onEdit != null)
            InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_rounded, size: 12, color: t.accent),
                    const SizedBox(width: 3),
                    Text('Edit', style: TextStyle(fontSize: 11, color: t.accent, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infoRow(RoleThemeData t, String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: t.textTertiary),
          const SizedBox(width: 8),
          SizedBox(
            width: 95,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: t.textSecondary, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: t.textPrimary, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRowWithCopy(RoleThemeData t, String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: t.textTertiary),
          const SizedBox(width: 8),
          SizedBox(
            width: 95,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: t.textSecondary, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                      color: t.accent,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    _snack('ID copied to clipboard', success: true);
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.copy_rounded, size: 13, color: t.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Parses a date from either a Firestore [Timestamp] or an ISO 8601 [String].
  String _parseDate(dynamic raw, {String fmt = 'dd MMM yyyy'}) {
    if (raw == null) return 'N/A';
    try {
      if (raw is Timestamp) return DateFormat(fmt).format(raw.toDate());
      if (raw is String && raw.isNotEmpty) {
        return DateFormat(fmt).format(DateTime.parse(raw));
      }
    } catch (_) {}
    return 'N/A';
  }

  // ── Edit helpers ──

  Widget _editField(RoleThemeData t, TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, List<TextInputFormatter>? formatters, int? maxLen,
        int maxLines = 1, String? Function(String?)? validator, ValueChanged<String>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: ctrl, keyboardType: type, inputFormatters: formatters,
        maxLength: maxLen, maxLines: maxLines, onChanged: onChanged,
        style: TextStyle(fontSize: 14, color: t.textPrimary),
        decoration: InputDecoration(
          labelText: label, labelStyle: TextStyle(fontSize: 13, color: t.textTertiary),
          floatingLabelStyle: TextStyle(fontSize: 12, color: t.accent, fontWeight: FontWeight.w600),
          prefixIcon: Icon(icon, color: t.textTertiary, size: 20),
          filled: true, fillColor: t.bgCard, counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
          errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
          errorStyle: const TextStyle(fontSize: 11),
        ),
        validator: validator,
      ),
    );
  }

  Widget _editDropdown({required RoleThemeData t, required String? value, required String label,
      required IconData icon, required List<String> items, required Function(String?) onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        hint: Text(label, style: TextStyle(color: t.textTertiary, fontSize: 13)),
        isExpanded: true, dropdownColor: t.bgCard,
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: t.textTertiary),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: t.textTertiary, size: 20),
          filled: true, fillColor: t.bgCard,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
        ),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 14, color: t.textPrimary)))).toList(),
        onChanged: onChanged,
        validator: (v) => v == null ? 'Select $label' : null,
      ),
    );
  }
}

// ─── Formatters ───────────────────────────────────────────────────────────────
class CNICInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if ((i == 4 || i == 11) && i != digits.length - 1) buffer.write('-');
    }
    return TextEditingValue(text: buffer.toString(), selection: TextSelection.collapsed(offset: buffer.length));
  }
}

class _DobFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue newVal) {
    var t = newVal.text.replaceAll(RegExp(r'\D'), '');
    if (t.length > 8) t = t.substring(0, 8);
    final b = StringBuffer();
    for (int i = 0; i < t.length; i++) { if (i == 2 || i == 4) b.write('-'); b.write(t[i]); }
    return TextEditingValue(text: b.toString(), selection: TextSelection.collapsed(offset: b.length));
  }
}
