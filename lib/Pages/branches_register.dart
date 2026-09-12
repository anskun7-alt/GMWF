// lib/pages/branches_register.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../theme/app_theme.dart';
import '../theme/role_theme_provider.dart';
import '../services/local_storage_service.dart';
import '../services/finance_local_storage.dart';
import '../services/cloud_messaging_service.dart';
import 'admin/branch_facility_editor.dart';
import 'users.dart';

class BranchesRegister extends StatefulWidget {
  const BranchesRegister({super.key});

  @override
  State<BranchesRegister> createState() => _BranchesRegisterState();
}

class _DepartmentItem {
  final String id;
  final String name;
  final String description;
  final String tag;
  final IconData icon;
  final Color color;
  final bool isCore;
  final bool isCustom;

  const _DepartmentItem({
    required this.id,
    required this.name,
    required this.description,
    required this.tag,
    required this.icon,
    required this.color,
    this.isCore = false,
    this.isCustom = false,
  });
}

class _BranchesRegisterState extends State<BranchesRegister>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _branchController = TextEditingController();
  final TextEditingController _customDeptController = TextEditingController();

  bool _loading = false;
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  // Standard predefined departments - Office is the core department
  static const List<_DepartmentItem> _defaultDepartments = [
    _DepartmentItem(
      id: 'office',
      name: 'Office & Administration',
      description: 'Branch coordination, staff payroll, biometric attendance, finance & operational management.',
      tag: 'CORE DEPARTMENT • MANDATORY',
      icon: Icons.business_rounded,
      color: Color(0xFF475569), // Slate
      isCore: true,
    ),
    _DepartmentItem(
      id: 'dispensary',
      name: 'Dispensary',
      description: 'Outpatient clinic, doctor consultations, vitals, OPD queue, patient history & medicine inventory.',
      tag: 'HEALTHCARE & PHARMACY',
      icon: Icons.local_hospital_rounded,
      color: Color(0xFF0D9488), // Teal
    ),
    _DepartmentItem(
      id: 'dasterkhwaan',
      name: 'Dasterkhwaan',
      description: 'Community kitchen, daily meal distribution, ration inventory & food log tracking.',
      tag: 'COMMUNITY KITCHEN & MEALS',
      icon: Icons.restaurant_rounded,
      color: Color(0xFFEA580C), // Orange
    ),
    _DepartmentItem(
      id: 'madrassa',
      name: 'Madrassa',
      description: 'Islamic education, Quran Nazra & Hifz programs, student registers, teacher attendance & fee records.',
      tag: 'ISLAMIC EDUCATION',
      icon: Icons.menu_book_rounded,
      color: Color(0xFF7C3AED), // Deep Purple
    ),
    _DepartmentItem(
      id: 'school',
      name: 'School',
      description: 'Formal academic education, multi-grade student enrollment, class curricula & teacher coordination.',
      tag: 'ACADEMIC SCHOOLING',
      icon: Icons.school_rounded,
      color: Color(0xFF2563EB), // Blue
    ),
  ];

  // Selected department IDs: Office is ALWAYS included and selected by default
  final Set<String> _selectedDepartmentIds = {'office', 'dispensary', 'dasterkhwaan'};

  // Dynamic list of all departments (default + custom)
  final List<_DepartmentItem> _allDepartments = [];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();

    _loadDepartments();
    _branchController.addListener(() {
      setState(() {});
    });
  }

  void _loadDepartments() {
    _allDepartments.clear();
    _allDepartments.addAll(_defaultDepartments);

    // Load any custom departments from storage
    try {
      final customDepts = FinanceLocalStorage.getCustomDepartments();
      for (final cd in customDepts) {
        final clean = cd.trim();
        final id = clean.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
        if (clean.isNotEmpty && !_allDepartments.any((d) => d.id == id)) {
          _allDepartments.add(
            _DepartmentItem(
              id: id,
              name: clean,
              description: 'Custom branch operational department.',
              tag: 'CUSTOM DEPARTMENT',
              icon: Icons.category_rounded,
              color: const Color(0xFF0891B2),
              isCustom: true,
            ),
          );
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _animController.dispose();
    _branchController.dispose();
    _customDeptController.dispose();
    super.dispose();
  }

  String _sanitizeBranchId(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
  }

  // Toggle department: Office is locked as core and cannot be deselected
  void _toggleDepartment(_DepartmentItem dept) {
    if (dept.isCore || dept.id == 'office') {
      _snack(
        'Office & Administration is the core department and is always active for every branch.',
        info: true,
      );
      return;
    }

    setState(() {
      if (_selectedDepartmentIds.contains(dept.id)) {
        _selectedDepartmentIds.remove(dept.id);
      } else {
        _selectedDepartmentIds.add(dept.id);
      }
    });
  }

  // Check whether all optional departments are currently selected
  bool get _areAllOptionalSelected {
    final optionalDepts = _allDepartments.where((d) => !d.isCore && d.id != 'office');
    if (optionalDepts.isEmpty) return true;
    return optionalDepts.every((d) => _selectedDepartmentIds.contains(d.id));
  }

  // Toggle between "Select All" and "Deselect All" (preserving Office)
  void _toggleSelectAll() {
    setState(() {
      if (_areAllOptionalSelected) {
        // Deselect all optional departments, keep Office
        _selectedDepartmentIds.clear();
        _selectedDepartmentIds.add('office');
      } else {
        // Select all departments
        _selectedDepartmentIds.addAll(_allDepartments.map((d) => d.id));
      }
    });
  }

  void _selectPresetDispensaryDasterkhwaan() {
    setState(() {
      _selectedDepartmentIds.clear();
      _selectedDepartmentIds.addAll(['office', 'dispensary', 'dasterkhwaan']);
    });
  }

  void _showAddCustomDepartmentDialog() {
    _customDeptController.clear();
    final t = RoleThemeScope.dataOf(context);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: t.bgCard,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.add_circle_outline_rounded, color: t.accent, size: 20),
              ),
              const SizedBox(width: 10),
              Text(
                'Add Custom Department',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.textPrimary),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _customDeptController,
                autofocus: true,
                style: TextStyle(color: t.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'e.g. Vocational Center, Ambulance Fleet',
                  hintStyle: TextStyle(color: t.textTertiary, fontSize: 13),
                  filled: true,
                  fillColor: t.bgCardAlt,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: t.textTertiary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final text = _customDeptController.text.trim();
                if (text.isEmpty) return;
                final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

                if (_allDepartments.any((d) => d.id == id)) {
                  _snack('Department "$text" already exists.');
                  Navigator.pop(ctx);
                  return;
                }

                await FinanceLocalStorage.addCustomDepartment(text);

                setState(() {
                  _allDepartments.add(
                    _DepartmentItem(
                      id: id,
                      name: text,
                      description: 'Custom branch operational department.',
                      tag: 'CUSTOM DEPARTMENT',
                      icon: Icons.category_rounded,
                      color: const Color(0xFF0891B2),
                      isCustom: true,
                    ),
                  );
                  _selectedDepartmentIds.add(id);
                });

                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add & Include'),
            ),
          ],
        );
      },
    );
  }

  // ── Register Branch & Notify HQ Manager ──────────────────────────────────
  Future<void> _registerBranch() async {
    if (!_formKey.currentState!.validate()) {
      _snack('Please provide a valid branch name.', error: true);
      return;
    }

    final branchName = _branchController.text.trim();
    final branchId = _sanitizeBranchId(branchName);

    if (branchId.isEmpty) {
      _snack('Invalid branch name. Please use alphanumeric characters.', error: true);
      return;
    }

    // Ensure Office is always part of the selected list
    _selectedDepartmentIds.add('office');

    setState(() => _loading = true);

    try {
      // 1. Check if branch document already exists in Firestore or local cache
      final branchDoc = await FirebaseFirestore.instance.collection('branches').doc(branchId).get();
      if (branchDoc.exists) {
        final data = branchDoc.data() ?? {};
        final isOffboarded = data['isOffboarded'] == true || data['status'] == 'offboarded';
        if (isOffboarded) {
          _snack('Branch "$branchName" is currently offboarded. You can reactivate it from Branch Management.', error: true);
        } else {
          _snack('Branch "$branchName" already exists and is active.', error: true);
        }
        setState(() => _loading = false);
        return;
      }

      // 2. Prepare department-specific facility entries
      final hasDispensary = _selectedDepartmentIds.contains('dispensary');
      final hasDasterkhwaan = _selectedDepartmentIds.contains('dasterkhwaan');
      final hasMadrassa = _selectedDepartmentIds.contains('madrassa');
      final hasSchool = _selectedDepartmentIds.contains('school');

      final List<Map<String, dynamic>> dispensaries = hasDispensary
          ? [{'id': 'main_dispensary', 'name': 'Dispensary'}]
          : [];
      final List<Map<String, dynamic>> dasterkhwaans = hasDasterkhwaan
          ? [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}]
          : [];
      final List<Map<String, dynamic>> madrassas = hasMadrassa
          ? [{'id': 'main_madrassa', 'name': 'Madrassa'}]
          : [];
      final List<Map<String, dynamic>> schools = hasSchool
          ? [{'id': 'main_school', 'name': 'School'}]
          : [];

      // 3. Assemble document payload
      final selectedList = _selectedDepartmentIds.toList();
      final now = FieldValue.serverTimestamp();
      final nowIso = DateTime.now().toIso8601String();

      final docData = <String, dynamic>{
        'id': branchId,
        'name': branchName,
        'departments': selectedList,
        'dispensaries': dispensaries,
        'dasterkhwaans': dasterkhwaans,
        'madrassas': madrassas,
        'schools': schools,
        'camps': <Map<String, dynamic>>[],
        'dispensariesCount': dispensaries.length,
        'dasterkhwaansCount': dasterkhwaans.length,
        'madrassasCount': madrassas.length,
        'schoolsCount': schools.length,
        'campsCount': 0,
        'status': 'active',
        'isOffboarded': false,
        'allowDonationBox': true,
        'allowVitalsToken': true,
        'madrassaFeeEnabled': false,
        'sessionsConfig': {
          'dispensary': {
            'morning': {'enabled': true, 'openTime': '08:00', 'closeTime': '14:00'},
            'evening': {'enabled': true, 'openTime': '16:00', 'closeTime': '22:00'},
            'night': {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'},
            'allowVitalsToken': true,
          },
          'dasterkhwaan': {
            'morning': {'enabled': false, 'openTime': '06:00', 'closeTime': '10:00'},
            'lunch': {'enabled': false, 'openTime': '12:00', 'closeTime': '16:00'},
            'evening': {'enabled': true, 'openTime': '16:00', 'closeTime': '20:00'},
            'dinner': {'enabled': true, 'openTime': '16:00', 'closeTime': '20:00'},
            'night': {'enabled': true, 'openTime': '20:00', 'closeTime': '02:00'},
          },
          'madrassa': {
            'morning': {'enabled': true, 'openTime': '06:00', 'closeTime': '12:00'},
            'evening': {'enabled': true, 'openTime': '14:00', 'closeTime': '18:00'},
            'night': {'enabled': false, 'openTime': '19:00', 'closeTime': '22:00'},
            'enableFees': false,
          },
          'school': {
            'morning': {'enabled': true, 'openTime': '07:30', 'closeTime': '13:30'},
            'evening': {'enabled': false, 'openTime': '14:00', 'closeTime': '18:00'},
            'night': {'enabled': false, 'openTime': '18:30', 'closeTime': '21:30'},
          },
        },
        'createdAt': now,
        'updatedAt': now,
      };

      // 4. Save to Firestore branches collection
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .set(docData, SetOptions(merge: true));

      // 5. Save immediately to Local Hive 'local_branches' (BOTH with prefix and raw id for maximum compatibility)
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        final localData = Map<String, dynamic>.from(docData);
        localData['createdAt'] = nowIso;
        localData['updatedAt'] = nowIso;
        await box.put('branch:$branchId', localData);
        await box.put(branchId, localData);
        await box.flush(); // Immediate disk commit and stream notification
      }

      // 6. Save immediately to Finance Local Storage custom branches & branchesBox
      await FinanceLocalStorage.addCustomBranch(branchId, branchName);
      if (Hive.isBoxOpen(LocalStorageService.branchesBox)) {
        final box = Hive.box(LocalStorageService.branchesBox);
        await box.put(branchId, {
          'id': branchId,
          'name': branchName,
          'departments': selectedList,
          'status': 'active',
          'isOffboarded': false,
        });
        await box.flush();
      }

      // 7. Dispatch High-Priority Notification to HQ Manager & Executives
      final notifId = 'branch_created_${branchId}_${DateTime.now().millisecondsSinceEpoch}';
      final notifDoc = {
        'id': notifId,
        'notificationId': notifId,
        'title': '🏢 New Branch Created: $branchName',
        'title_en': '🏢 New Branch Created: $branchName',
        'title_ur': '🏢 نئی برانچ کا قیام: $branchName',
        'message': 'Branch "$branchName" ($branchId) has been registered. HQ Manager action required: Please assign branch personnel and configure operating facilities.',
        'body_en': 'Branch "$branchName" ($branchId) has been registered. HQ Manager action required: Please assign branch personnel and configure operating facilities.',
        'body_ur': 'برانچ "$branchName" رجسٹر ہو گئی ہے۔ ہیڈ کوارٹر مینیجر برائے مہربانی عملہ اور سہولیات مقرر کریں۔',
        'category': 'Branch Onboarding',
        'type': 'branch_management',
        'targetScreen': 'branches_management',
        'targetRoles': ['hq manager', 'hq_manager', 'admin', 'ceo', 'chairman', 'global admin'],
        'branchId': branchId,
        'seen': false,
        'timestamp': now,
        'createdAt': nowIso,
        'meta': {
          'branchId': branchId,
          'branchName': branchName,
          'departments': selectedList,
          'action': 'assign_users',
        },
      };

      try {
        // Save strictly to branch-level notifications subcollection
        final cleanB = LocalStorageService.sanitizeBranchId(branchId);
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(cleanB)
            .collection('notifications')
            .doc(notifId)
            .set(notifDoc, SetOptions(merge: true));

        // Trigger local notification stream
        await CloudMessagingService().showLocalOrDesktopNotification(
          id: notifId,
          title: '🏢 New Branch Created: $branchName',
          message: 'Branch "$branchName" ($branchId) registered. HQ Manager action required: assign branch staff.',
          category: 'Branch Onboarding',
          targetScreen: 'branches_management',
          branchId: branchId,
          targetRoles: ['hq manager', 'hq_manager', 'admin', 'ceo', 'chairman', 'global admin'],
          meta: notifDoc['meta'] as Map<String, dynamic>?,
        );
      } catch (ne) {
        debugPrint('[BranchesRegister] Notification dispatch warning: $ne');
      }

      setState(() => _loading = false);

      // 8. Show Post-Creation Success & Onboarding Action Dialog
      if (mounted) {
        await _showPostCreationSuccessDialog(branchId, branchName, selectedList);
      }
    } catch (e) {
      _snack('Error registering branch: $e', error: true);
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Post-Registration Onboarding Action Dialog ───────────────────────────
  Future<void> _showPostCreationSuccessDialog(
    String branchId,
    String branchName,
    List<String> departments,
  ) async {
    final t = RoleThemeScope.dataOf(context);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: t.bgCard,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Branch Registered!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.textPrimary),
                    ),
                    Text(
                      'Saved locally & synced to cloud instantly',
                      style: TextStyle(fontSize: 12, color: Colors.green.shade700, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                          Icon(Icons.store_rounded, size: 18, color: t.accent),
                          const SizedBox(width: 8),
                          Text(
                            branchName,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: t.textPrimary),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              branchId,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent, fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Active Departments: ${departments.map((d) => d[0].toUpperCase() + d.substring(1)).join(', ')}',
                        style: TextStyle(fontSize: 12, color: t.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Notice: HQ Manager Notified
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.notifications_active_rounded, color: Color(0xFF0284C7), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'An alert has been dispatched to the HQ Manager & Administrators to assign staff members and configure operational facility timing.',
                          style: TextStyle(fontSize: 12, color: t.textPrimary, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('Configure Facilities'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.accent,
                    side: BorderSide(color: t.accent.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx); // Close dialog
                    Navigator.pop(context, true); // Pop registration screen
                    BranchFacilityEditorDialog.show(
                      context,
                      branchId: branchId,
                      currentBranchName: branchName,
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_add_rounded, size: 16),
                  label: const Text('Assign Users & Staff'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0284C7),
                    side: BorderSide(color: const Color(0xFF0284C7).withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pop(context, true);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => UsersScreen(branchId: branchId)),
                    );
                  },
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pop(context, true);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _snack(String msg, {bool error = false, bool success = false, bool info = false}) {
    if (!mounted) return;
    final t = RoleThemeScope.dataOf(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          error
              ? Icons.error_outline
              : success
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
          color: Colors.white,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
      ]),
      backgroundColor: error
          ? t.danger
          : success
              ? Colors.green.shade700
              : info
                  ? const Color(0xFF0284C7)
                  : const Color(0xFF37474F),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final isDesktop = MediaQuery.of(context).size.width >= 860;
    final branchName = _branchController.text.trim();
    final branchId = _sanitizeBranchId(branchName);

    return Scaffold(
      backgroundColor: t.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // ── Integrated Clean Page Header (No duplicate app bar banner) ──
                _buildHeaderBar(t),

                // ── Responsive Form Area ──────────────────────────────────────
                Expanded(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: isDesktop ? 32 : 16,
                        vertical: 16,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1240),
                          child: Form(
                            key: _formKey,
                            child: isDesktop
                                ? _buildDesktopTwoColumnLayout(t, branchName, branchId)
                                : _buildMobileSingleColumnLayout(t, branchName, branchId),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Loading Overlay
          if (_loading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 36),
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 30, offset: Offset(0, 10))
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 50,
                        height: 50,
                        child: CircularProgressIndicator(
                          color: t.accent,
                          strokeWidth: 4,
                          backgroundColor: t.accentMuted,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Creating Branch',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Updating local storage & dispatching HQ alerts...',
                        style: TextStyle(fontSize: 13, color: t.textTertiary),
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

  // ── Integrated Header Bar (Replaces the clunky blue banner) ────────────────
  Widget _buildHeaderBar(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(bottom: BorderSide(color: t.bgRule)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: t.bgCardAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.bgRule),
              ),
              child: Icon(Icons.arrow_back_rounded, color: t.textPrimary, size: 20),
            ),
          ),
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.add_business_rounded, color: t.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Register New Branch',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                      ),
                      child: const Text(
                        'INSTANT LOCAL CACHE',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Set branch name and included operational departments • HQ Manager will be auto-notified',
                  style: TextStyle(fontSize: 12, color: t.textTertiary),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Desktop Two-Column Layout ─────────────────────────────────────────────
  Widget _buildDesktopTwoColumnLayout(RoleThemeData t, String branchName, String branchId) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left Column: Identity, HQ Notification notice & Overview (width: 380px)
        SizedBox(
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBranchDetailsCard(t, branchId),
              const SizedBox(height: 16),
              _buildHqDispatchCard(t),
              const SizedBox(height: 16),
              _buildSummaryCard(t, branchName, branchId),
              const SizedBox(height: 20),
              _buildSubmitButton(t),
            ],
          ),
        ),

        const SizedBox(width: 24),

        // Right Column: Operational Departments Configuration (Expanded)
        Expanded(
          child: _buildDepartmentsCard(t),
        ),
      ],
    );
  }

  // ── Mobile / Narrow Single-Column Layout ──────────────────────────────────
  Widget _buildMobileSingleColumnLayout(RoleThemeData t, String branchName, String branchId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBranchDetailsCard(t, branchId),
        const SizedBox(height: 16),
        _buildDepartmentsCard(t),
        const SizedBox(height: 16),
        _buildHqDispatchCard(t),
        const SizedBox(height: 16),
        _buildSummaryCard(t, branchName, branchId),
        const SizedBox(height: 24),
        _buildSubmitButton(t),
      ],
    );
  }

  // ── Card 1: Branch Details ────────────────────────────────────────────────
  Widget _buildBranchDetailsCard(RoleThemeData t, String branchId) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.bgRule))),
            child: Row(
              children: [
                Icon(Icons.storefront_rounded, color: t.accent, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Branch Identity',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _branchController,
                  style: TextStyle(
                    fontSize: 15,
                    color: t.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Branch Name *',
                    labelStyle: TextStyle(fontSize: 13, color: t.textTertiary),
                    floatingLabelStyle: TextStyle(
                      fontSize: 12,
                      color: t.accent,
                      fontWeight: FontWeight.w700,
                    ),
                    hintText: 'e.g. Lahore Center, Gujrat City',
                    hintStyle: TextStyle(fontSize: 13, color: t.textTertiary.withValues(alpha: 0.6)),
                    prefixIcon: Icon(Icons.apartment_rounded, color: t.textTertiary, size: 20),
                    filled: true,
                    fillColor: t.bgCardAlt,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.bgRule)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.accent, width: 2)),
                    errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger)),
                    focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: t.danger, width: 2)),
                  ),
                  validator: (val) {
                    final clean = val?.trim() ?? '';
                    if (clean.isEmpty) return 'Branch name is required';
                    if (clean.length < 2) return 'At least 2 characters required';
                    return null;
                  },
                ),
                const SizedBox(height: 10),

                // Identifier Preview Chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.bgCardAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.bgRule),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.tag_rounded, size: 16, color: t.textTertiary),
                      const SizedBox(width: 8),
                      Text(
                        'Branch ID: ',
                        style: TextStyle(fontSize: 11, color: t.textTertiary, fontWeight: FontWeight.w500),
                      ),
                      Expanded(
                        child: Text(
                          branchId.isEmpty ? '—' : branchId,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: branchId.isEmpty ? t.textTertiary : t.accent,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Card 2: HQ Dispatch Card ──────────────────────────────────────────────
  Widget _buildHqDispatchCard(RoleThemeData t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0284C7).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.manage_accounts_rounded, color: Color(0xFF0284C7), size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'HQ Manager Assignment',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: t.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'AUTO-DISPATCH',
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Upon creation, HQ Managers and Executive Administrators will be automatically notified to assign staff, link user accounts, and review facility schedules for this branch.',
            style: TextStyle(fontSize: 12, color: t.textSecondary, height: 1.35),
          ),
        ],
      ),
    );
  }

  // ── Card 3: Summary Preview ───────────────────────────────────────────────
  Widget _buildSummaryCard(RoleThemeData t, String branchName, String branchId) {
    final selectedNames = _allDepartments
        .where((d) => _selectedDepartmentIds.contains(d.id))
        .map((d) => d.name)
        .toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, color: t.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                'Registration Summary',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('Name:', style: TextStyle(fontSize: 12, color: t.textTertiary)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  branchName.isEmpty ? '—' : branchName,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Departments:', style: TextStyle(fontSize: 12, color: t.textTertiary)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selectedNames.isEmpty ? 'Office (Core Only)' : selectedNames.join(', '),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.accent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Card 4: Operational Departments Configuration ─────────────────────────
  Widget _buildDepartmentsCard(RoleThemeData t) {
    final allSelected = _areAllOptionalSelected;

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with Selected count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.bgRule))),
            child: Row(
              children: [
                Icon(Icons.hub_rounded, color: const Color(0xFF0284C7), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Operational Departments',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: t.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_selectedDepartmentIds.length} Included',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: t.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Office is mandatory; select additional facilities to include in this branch',
                        style: TextStyle(fontSize: 12, color: t.textTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Toolbar with Select All / Deselect All toggle & Presets
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Dynamic Toggle: "Select All" <-> "Deselect All"
                    ActionChip(
                      avatar: Icon(
                        allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
                        size: 16,
                        color: allSelected ? t.danger : t.accent,
                      ),
                      label: Text(
                        allSelected ? 'Deselect All' : 'Select All',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: allSelected ? t.danger : t.accent,
                        ),
                      ),
                      onPressed: _toggleSelectAll,
                      backgroundColor: allSelected
                          ? t.danger.withValues(alpha: 0.1)
                          : t.accent.withValues(alpha: 0.1),
                      side: BorderSide(
                        color: allSelected
                            ? t.danger.withValues(alpha: 0.3)
                            : t.accent.withValues(alpha: 0.3),
                      ),
                    ),

                    ActionChip(
                      avatar: const Icon(Icons.medical_services_outlined, size: 16),
                      label: const Text('Dispensary + Kitchen', style: TextStyle(fontSize: 12)),
                      onPressed: _selectPresetDispensaryDasterkhwaan,
                      backgroundColor: t.bgCardAlt,
                      side: BorderSide(color: t.bgRule),
                    ),

                    ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('Custom Department', style: TextStyle(fontSize: 12)),
                      onPressed: _showAddCustomDepartmentDialog,
                      backgroundColor: Colors.cyan.withValues(alpha: 0.08),
                      side: BorderSide(color: Colors.cyan.withValues(alpha: 0.3)),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Department Cards List
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _allDepartments.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final dept = _allDepartments[index];
                    final isSelected = _selectedDepartmentIds.contains(dept.id);
                    final isLocked = dept.isCore || dept.id == 'office';

                    return InkWell(
                      onTap: () => _toggleDepartment(dept),
                      borderRadius: BorderRadius.circular(14),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? dept.color.withValues(alpha: 0.08)
                              : t.bgCardAlt,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected
                                ? dept.color.withValues(alpha: 0.7)
                                : t.bgRule,
                            width: isSelected ? 1.8 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            // Department Icon
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: dept.color.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(dept.icon, color: dept.color, size: 22),
                            ),
                            const SizedBox(width: 14),

                            // Name & Description
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        dept.name,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? t.textPrimary : t.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isLocked
                                              ? const Color(0xFF475569).withValues(alpha: 0.18)
                                              : dept.color.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          dept.tag,
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: isLocked ? const Color(0xFF475569) : dept.color,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    dept.description,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: t.textTertiary,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 10),

                            // Switch / Check indicator
                            if (isLocked)
                              Tooltip(
                                message: 'Office & Admin is required for every branch and cannot be deselected.',
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.lock_rounded, size: 16, color: Colors.grey),
                                ),
                              )
                            else
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: isSelected ? dept.color : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected ? dept.color : t.textTertiary.withValues(alpha: 0.4),
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Submit Button ────────────────────────────────────────────────────────
  Widget _buildSubmitButton(RoleThemeData t) {
    return GestureDetector(
      onTap: _loading ? null : _registerBranch,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [t.accent, t.accentLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: t.accent.withValues(alpha: 0.32),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_business_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 10),
                  Text(
                    'Register Branch & Dispatch HQ Alert',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
