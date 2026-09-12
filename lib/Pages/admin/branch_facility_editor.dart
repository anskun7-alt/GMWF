// lib/pages/admin/branch_facility_editor.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/local_storage_service.dart';
import '../../services/camp_session_service.dart';

class BranchFacilityEditorDialog extends StatefulWidget {
  final String branchId;
  final String currentBranchName;
  final List<Map<String, dynamic>> initialDispensaries;
  final List<Map<String, dynamic>> initialDasterkhwaans;
  final List<Map<String, dynamic>> initialMadrassas;
  final List<Map<String, dynamic>> initialSchools;
  final List<Map<String, dynamic>> initialCamps;
  final Map<String, dynamic>? initialSessionsConfig;

  const BranchFacilityEditorDialog({
    super.key,
    required this.branchId,
    required this.currentBranchName,
    this.initialDispensaries = const [],
    this.initialDasterkhwaans = const [],
    this.initialMadrassas = const [],
    this.initialSchools = const [],
    this.initialCamps = const [],
    this.initialSessionsConfig,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String branchId,
    required String currentBranchName,
    List<Map<String, dynamic>> initialDispensaries = const [],
    List<Map<String, dynamic>> initialDasterkhwaans = const [],
    List<Map<String, dynamic>> initialMadrassas = const [],
    List<Map<String, dynamic>> initialSchools = const [],
    List<Map<String, dynamic>> initialCamps = const [],
    Map<String, dynamic>? initialSessionsConfig,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BranchFacilityEditorDialog(
        branchId: branchId,
        currentBranchName: currentBranchName,
        initialDispensaries: initialDispensaries,
        initialDasterkhwaans: initialDasterkhwaans,
        initialMadrassas: initialMadrassas,
        initialSchools: initialSchools,
        initialCamps: initialCamps,
        initialSessionsConfig: initialSessionsConfig,
      ),
    );
  }

  @override
  State<BranchFacilityEditorDialog> createState() =>
      _BranchFacilityEditorDialogState();
}

class _BranchFacilityEditorDialogState
    extends State<BranchFacilityEditorDialog> {
  late TextEditingController _nameController;
  late TextEditingController _campInputCtrl;
  late TextEditingController _dispensaryInputCtrl;
  late TextEditingController _dasterkhwaanInputCtrl;
  late TextEditingController _madrassaInputCtrl;
  late TextEditingController _schoolInputCtrl;

  late List<Map<String, dynamic>> _camps;
  late List<Map<String, dynamic>> _dispensaries;
  late List<Map<String, dynamic>> _dasterkhwaans;
  late List<Map<String, dynamic>> _madrassas;
  late List<Map<String, dynamic>> _schools;
  late Map<String, dynamic> _sessionsConfig;
  late bool _madrassaFeeEnabled;
  late bool _allowVitalsToken;
  late bool _allowDoctorInventoryApproval;
  final List<String> _newCampDepts = ['dispensary'];
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentBranchName);
    _campInputCtrl = TextEditingController();
    _dispensaryInputCtrl = TextEditingController();
    _dasterkhwaanInputCtrl = TextEditingController();
    _madrassaInputCtrl = TextEditingController();
    _schoolInputCtrl = TextEditingController();

    final defaults = LocalStorageService.getDefaultBranchFacilities(widget.branchId);

    // Initialize Sessions Config with Department-Level Separation
    final initSess = widget.initialSessionsConfig ?? {};
    final defaultDisp = CampSessionService.getDefaultSessionConfig(widget.branchId, 'dispensary');
    final defaultDast = CampSessionService.getDefaultSessionConfig(widget.branchId, 'dasterkhwaan');
    final defaultMad  = CampSessionService.getDefaultSessionConfig(widget.branchId, 'madrassa');
    final defaultSch  = CampSessionService.getDefaultSessionConfig(widget.branchId, 'school');

    // Dispensary Config
    final rawDisp = initSess['dispensary'] is Map ? initSess['dispensary'] as Map : initSess;
    _allowVitalsToken = rawDisp['allowVitalsToken'] ?? initSess['allowVitalsToken'] ?? widget.initialSessionsConfig?['allowVitalsToken'] ?? LocalStorageService.isVitalsTokenAllowed(widget.branchId);
    _allowDoctorInventoryApproval = rawDisp['allowDoctorInventoryApproval'] ?? initSess['allowDoctorInventoryApproval'] ?? widget.initialSessionsConfig?['allowDoctorInventoryApproval'] ?? LocalStorageService.isDoctorInventoryApprovalAllowed(widget.branchId);

    final dispConfig = {
      'morning': Map<String, dynamic>.from(rawDisp['morning'] ?? defaultDisp['morning'] ?? {'enabled': true, 'openTime': '08:00', 'closeTime': '14:00'}),
      'evening': Map<String, dynamic>.from(rawDisp['evening'] ?? defaultDisp['evening'] ?? {'enabled': true, 'openTime': '16:00', 'closeTime': '22:00'}),
      'night':   Map<String, dynamic>.from(rawDisp['night']   ?? defaultDisp['night']   ?? {'enabled': false, 'openTime': '22:00', 'closeTime': '04:00'}),
      'allowVitalsToken': _allowVitalsToken,
      'allowDoctorInventoryApproval': _allowDoctorInventoryApproval,
    };

    // Dasterkhwaan Config (Evening, Night, Morning, Lunch)
    final rawDast = initSess['dasterkhwaan'] is Map ? initSess['dasterkhwaan'] as Map : {};
    final eveSource = rawDast['evening'] ?? rawDast['dinner'] ?? defaultDast['evening'] ?? defaultDast['dinner'];
    final dastConfig = {
      'evening': Map<String, dynamic>.from(eveSource ?? {'enabled': true, 'openTime': '16:00', 'closeTime': '20:00'}),
      'dinner':  Map<String, dynamic>.from(eveSource ?? {'enabled': true, 'openTime': '16:00', 'closeTime': '20:00'}),
      'night':   Map<String, dynamic>.from(rawDast['night']   ?? defaultDast['night']   ?? {'enabled': true, 'openTime': '20:00', 'closeTime': '02:00'}),
      'morning': Map<String, dynamic>.from(rawDast['morning'] ?? defaultDast['morning'] ?? {'enabled': false, 'openTime': '06:00', 'closeTime': '10:00'}),
      'lunch':   Map<String, dynamic>.from(rawDast['lunch']   ?? defaultDast['lunch']   ?? {'enabled': false, 'openTime': '12:00', 'closeTime': '16:00'}),
    };

    // Madrassa Config & Fee Factor
    final rawMad = initSess['madrassa'] is Map ? initSess['madrassa'] as Map : {};
    _madrassaFeeEnabled = rawMad['enableFees'] ?? initSess['madrassaFeeEnabled'] ?? LocalStorageService.isMadrassaFeeEnabled(widget.branchId);

    final madConfig = {
      'morning': Map<String, dynamic>.from(rawMad['morning'] ?? defaultMad['morning'] ?? {'enabled': true, 'openTime': '06:00', 'closeTime': '12:00'}),
      'evening': Map<String, dynamic>.from(rawMad['evening'] ?? defaultMad['evening'] ?? {'enabled': true, 'openTime': '14:00', 'closeTime': '18:00'}),
      'night':   Map<String, dynamic>.from(rawMad['night']   ?? defaultMad['night']   ?? {'enabled': false, 'openTime': '19:00', 'closeTime': '22:00'}),
      'enableFees': _madrassaFeeEnabled,
    };

    // School Config
    final rawSch = initSess['school'] is Map ? initSess['school'] as Map : {};
    final schConfig = {
      'morning': Map<String, dynamic>.from(rawSch['morning'] ?? defaultSch['morning'] ?? {'enabled': true, 'openTime': '07:30', 'closeTime': '13:30'}),
      'evening': Map<String, dynamic>.from(rawSch['evening'] ?? defaultSch['evening'] ?? {'enabled': false, 'openTime': '14:00', 'closeTime': '18:00'}),
      'night':   Map<String, dynamic>.from(rawSch['night']   ?? defaultSch['night']   ?? {'enabled': false, 'openTime': '18:30', 'closeTime': '21:30'}),
    };

    _sessionsConfig = {
      'dispensary': dispConfig,
      'dasterkhwaan': dastConfig,
      'madrassa': madConfig,
      'school': schConfig,
      'madrassaFeeEnabled': _madrassaFeeEnabled,
      'allowVitalsToken': _allowVitalsToken,
      'allowDoctorInventoryApproval': _allowDoctorInventoryApproval,
      // Backward-compatible top-level keys
      'morning': dispConfig['morning']!,
      'evening': dispConfig['evening']!,
      'night': dispConfig['night']!,
    };

    _dispensaries = widget.initialDispensaries.isNotEmpty
        ? widget.initialDispensaries.map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList()
        : (defaults['dispensaries'] ?? []).map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList();

    _dasterkhwaans = widget.initialDasterkhwaans.isNotEmpty
        ? widget.initialDasterkhwaans.map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'lunch', 'dinner'])).toList()
        : (defaults['dasterkhwaans'] ?? []).map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'lunch', 'dinner'])).toList();

    _madrassas = widget.initialMadrassas.isNotEmpty
        ? widget.initialMadrassas.map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList()
        : (defaults['madrassas'] ?? []).map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList();

    _schools = widget.initialSchools.isNotEmpty
        ? widget.initialSchools.map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList()
        : (defaults['schools'] ?? []).map((d) => _normalizeFacility(d, defaultSessions: ['morning', 'evening'])).toList();

    _camps = widget.initialCamps.isNotEmpty
        ? widget.initialCamps.map((c) => _normalizeCamp(c)).toList()
        : CampSessionService.getCampsForBranch(widget.branchId, includeClosed: true).map((c) => _normalizeCamp(c)).toList();
  }

  Map<String, dynamic> _normalizeCamp(Map c) {
    final m = Map<String, dynamic>.from(c);
    final rawDepts = m['departments'];
    List<String> depts = [];
    if (rawDepts is List) {
      depts = rawDepts.map((e) => e.toString().toLowerCase().trim()).where((e) => e.isNotEmpty).toList();
    }
    if (depts.isEmpty) {
      depts = ['dispensary'];
    }
    final rawSessions = m['sessions'];
    List<String> sessions = [];
    if (rawSessions is List) {
      sessions = rawSessions.map((e) => e.toString().toLowerCase().trim()).where((e) => e.isNotEmpty).toList();
    }
    if (sessions.isEmpty) {
      sessions = ['morning', 'evening'];
    }
    final rawTimings = m['sessionTimings'];
    Map<String, dynamic> sessionTimings = {};
    if (rawTimings is Map) {
      sessionTimings = Map<String, dynamic>.from(rawTimings);
    }
    final isClosed = m['isClosed'] == true || m['status'] == 'closed' || m['status'] == 'offboarded';

    return {
      'id': (m['id'] ?? '').toString().trim().toLowerCase(),
      'name': (m['name'] ?? m['id'] ?? 'Camp').toString().trim(),
      'departments': depts,
      'sessions': sessions,
      'sessionTimings': sessionTimings,
      'status': isClosed ? 'closed' : 'active',
      'isClosed': isClosed,
      'closedAt': m['closedAt'],
      'closureReason': m['closureReason'] ?? '',
    };
  }

  Map<String, dynamic> _normalizeFacility(Map d, {required List<String> defaultSessions}) {
    final m = Map<String, dynamic>.from(d);
    final rawSessions = m['sessions'];
    List<String> sessions = [];
    if (rawSessions is List) {
      sessions = rawSessions.map((e) => e.toString().toLowerCase().trim()).where((e) => e.isNotEmpty).toList();
    }
    if (sessions.isEmpty) {
      sessions = List<String>.from(defaultSessions);
    }
    final rawTimings = m['sessionTimings'];
    Map<String, dynamic> sessionTimings = {};
    if (rawTimings is Map) {
      sessionTimings = Map<String, dynamic>.from(rawTimings);
    }

    return {
      'id': (m['id'] ?? '').toString(),
      'name': (m['name'] ?? m['id'] ?? '').toString(),
      'sessions': sessions,
      'sessionTimings': sessionTimings,
    };
  }

  @override
  void dispose() {
    _nameController.dispose();
    _campInputCtrl.dispose();
    _dispensaryInputCtrl.dispose();
    _dasterkhwaanInputCtrl.dispose();
    _madrassaInputCtrl.dispose();
    _schoolInputCtrl.dispose();
    super.dispose();
  }

  void _addCamp() {
    final text = _campInputCtrl.text.trim();
    if (text.isEmpty) return;
    final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (_camps.any((c) => c['id'] == id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camp with ID "$id" already exists')),
      );
      return;
    }
    setState(() {
      _camps.add({
        'id': id,
        'name': text,
        'departments': _newCampDepts.isNotEmpty ? List<String>.from(_newCampDepts) : ['dispensary'],
        'sessions': ['morning', 'evening'],
        'sessionTimings': <String, dynamic>{},
        'status': 'active',
        'isClosed': false,
      });
      _campInputCtrl.clear();
    });
  }

  void _toggleCampDept(Map<String, dynamic> camp, String deptKey) {
    setState(() {
      final depts = List<String>.from(camp['departments'] as List? ?? []);
      if (depts.contains(deptKey)) {
        if (depts.length > 1) {
          depts.remove(deptKey);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camp must have at least one active department.')),
          );
        }
      } else {
        depts.add(deptKey);
      }
      camp['departments'] = depts;
    });
  }

  void _toggleCampClose(Map<String, dynamic> camp) {
    setState(() {
      final currentlyClosed = camp['isClosed'] == true;
      camp['isClosed'] = !currentlyClosed;
      camp['status'] = !currentlyClosed ? 'closed' : 'active';
      if (!currentlyClosed) {
        camp['closedAt'] = DateTime.now().toIso8601String();
      } else {
        camp['closedAt'] = null;
        camp['reactivatedAt'] = DateTime.now().toIso8601String();
      }
    });
  }

  void _addDispensary() {
    final text = _dispensaryInputCtrl.text.trim();
    if (text.isEmpty) return;
    final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (_dispensaries.any((d) => d['id'] == id)) return;
    setState(() {
      _dispensaries.add({
        'id': id,
        'name': text,
        'sessions': ['morning', 'evening'],
        'sessionTimings': <String, dynamic>{},
      });
      _dispensaryInputCtrl.clear();
    });
  }

  void _addDasterkhwaan() {
    final text = _dasterkhwaanInputCtrl.text.trim();
    if (text.isEmpty) return;
    final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (_dasterkhwaans.any((d) => d['id'] == id)) return;
    setState(() {
      _dasterkhwaans.add({
        'id': id,
        'name': text,
        'sessions': ['morning', 'lunch', 'dinner'],
        'sessionTimings': <String, dynamic>{},
      });
      _dasterkhwaanInputCtrl.clear();
    });
  }

  void _addMadrassa() {
    final text = _madrassaInputCtrl.text.trim();
    if (text.isEmpty) return;
    final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (_madrassas.any((d) => d['id'] == id)) return;
    setState(() {
      _madrassas.add({
        'id': id,
        'name': text,
        'sessions': ['morning', 'evening'],
        'sessionTimings': <String, dynamic>{},
      });
      _madrassaInputCtrl.clear();
    });
  }

  void _addSchool() {
    final text = _schoolInputCtrl.text.trim();
    if (text.isEmpty) return;
    final id = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (_schools.any((d) => d['id'] == id)) return;
    setState(() {
      _schools.add({
        'id': id,
        'name': text,
        'sessions': ['morning'],
        'sessionTimings': <String, dynamic>{},
      });
      _schoolInputCtrl.clear();
    });
  }

  void _toggleSession(Map<String, dynamic> facility, String sessionKey) {
    setState(() {
      final sessions = List<String>.from(facility['sessions'] as List);
      if (sessions.contains(sessionKey)) {
        if (sessions.length > 1) {
          sessions.remove(sessionKey);
        }
      } else {
        sessions.add(sessionKey);
      }
      facility['sessions'] = sessions;
    });
  }

  String _formatTimeStr(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return '--:--';
    final parts = timeStr.split(':');
    if (parts.length >= 2) {
      int h = int.tryParse(parts[0]) ?? 0;
      int m = int.tryParse(parts[1]) ?? 0;
      final period = h >= 12 ? 'PM' : 'AM';
      final displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
      final displayM = m.toString().padLeft(2, '0');
      return '$displayH:$displayM $period';
    }
    return timeStr;
  }

  Future<void> _pickDeptTime(BuildContext context, String deptKey, String sessionKey, String timeKey) async {
    final deptMap = _sessionsConfig[deptKey] as Map<String, dynamic>? ?? {};
    final sessMap = deptMap[sessionKey] as Map<String, dynamic>? ?? {};
    final currentStr = sessMap[timeKey]?.toString() ?? (timeKey == 'openTime' ? '08:00' : '14:00');
    final parts = currentStr.split(':');
    final initial = TimeOfDay(
      hour: parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 8) : 8,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );

    if (picked != null) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      setState(() {
        if (_sessionsConfig[deptKey] is Map) {
          final sMap = (_sessionsConfig[deptKey] as Map)[sessionKey];
          if (sMap is Map) {
            sMap[timeKey] = '$hh:$mm';
          }
          if (deptKey == 'dasterkhwaan' && (sessionKey == 'evening' || sessionKey == 'dinner')) {
            final otherKey = sessionKey == 'evening' ? 'dinner' : 'evening';
            final otherMap = (_sessionsConfig['dasterkhwaan'] as Map)[otherKey];
            if (otherMap is Map) {
              otherMap[timeKey] = '$hh:$mm';
            }
          }
        }
        // Mirror to top-level if dispensary
        if (deptKey == 'dispensary') {
          if (_sessionsConfig[sessionKey] is Map) {
            (_sessionsConfig[sessionKey] as Map)[timeKey] = '$hh:$mm';
          }
        }
      });
    }
  }

  Future<void> _pickFacilityCustomTime(
    BuildContext context,
    Map<String, dynamic> facility,
    String sessionKey,
    String timeKey,
    String fallbackTime,
  ) async {
    final timings = facility['sessionTimings'] as Map<String, dynamic>? ?? {};
    final sessTiming = timings[sessionKey] as Map<String, dynamic>? ?? {};
    final currentStr = sessTiming[timeKey]?.toString() ?? fallbackTime;
    final parts = currentStr.split(':');
    final initial = TimeOfDay(
      hour: parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 8) : 8,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );

    if (picked != null) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      setState(() {
        if (facility['sessionTimings'] is! Map) {
          facility['sessionTimings'] = <String, dynamic>{};
        }
        final fTimings = facility['sessionTimings'] as Map<String, dynamic>;
        if (fTimings[sessionKey] is! Map) {
          fTimings[sessionKey] = <String, dynamic>{};
        }
        (fTimings[sessionKey] as Map<String, dynamic>)[timeKey] = '$hh:$mm';
      });
    }
  }

  Future<void> _saveBranchData() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Branch Name cannot be empty')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      if (_sessionsConfig['dispensary'] is Map) {
        (_sessionsConfig['dispensary'] as Map)['allowVitalsToken'] = _allowVitalsToken;
      }
      _sessionsConfig['allowVitalsToken'] = _allowVitalsToken;

      if (_sessionsConfig['madrassa'] is Map) {
        (_sessionsConfig['madrassa'] as Map)['enableFees'] = _madrassaFeeEnabled;
      }
      _sessionsConfig['madrassaFeeEnabled'] = _madrassaFeeEnabled;

      final docData = <String, dynamic>{
        'name': newName,
        'sessionsConfig': _sessionsConfig,
        'madrassaFeeEnabled': _madrassaFeeEnabled,
        'allowVitalsToken': _allowVitalsToken,
        'dispensaries': _dispensaries,
        'dasterkhwaans': _dasterkhwaans,
        'madrassas': _madrassas,
        'schools': _schools,
        'camps': _camps,
        'campsCount': _camps.length,
        'dispensariesCount': _dispensaries.length,
        'dasterkhwaansCount': _dasterkhwaans.length,
        'madrassasCount': _madrassas.length,
        'schoolsCount': _schools.length,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // 1. Firestore Update
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .set(docData, SetOptions(merge: true));

      // Sync to Madrassa Config in Firestore
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('madrassa_config')
          .doc('current')
          .set({'enableFees': _madrassaFeeEnabled}, SetOptions(merge: true));

      // 2. Local Hive Box Update
      if (Hive.isBoxOpen('local_branches')) {
        final box = Hive.box('local_branches');
        await box.put('branch:${widget.branchId}', {
          'id': widget.branchId,
          'name': newName,
          'sessionsConfig': _sessionsConfig,
          'madrassaFeeEnabled': _madrassaFeeEnabled,
          'allowVitalsToken': _allowVitalsToken,
          'dispensaries': _dispensaries,
          'dasterkhwaans': _dasterkhwaans,
          'madrassas': _madrassas,
          'schools': _schools,
          'camps': _camps,
          'campsCount': _camps.length,
          'dispensariesCount': _dispensaries.length,
          'dasterkhwaansCount': _dasterkhwaans.length,
          'madrassasCount': _madrassas.length,
          'schoolsCount': _schools.length,
        });
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update branch: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgDialog = isDark ? const Color(0xFF1E293B) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final inputBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    const teal = Color(0xFF00695C);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: bgDialog,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 920),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 18),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: teal.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.hub_rounded, color: teal, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Branch Facilities & Operational Schedules',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Configure separate operational timings, shift windows & facilities for ${widget.currentBranchName} (${widget.branchId})',
                          style: TextStyle(
                            fontSize: 12,
                            color: subtextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: subtextColor),
                  ),
                ],
              ),
            ),

            // Form Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Branch Name
                    Text(
                      'Branch Name',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameController,
                      style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.store_rounded, color: subtextColor, size: 20),
                        filled: true,
                        fillColor: inputBg,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Section 0: Camps & Field Sub-Locations ──
                    _buildCampsCard(
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      borderColor: borderColor,
                      inputBg: inputBg,
                    ),
                    const SizedBox(height: 24),

                    // ── Section 1: Dispensary Camps & Separate Shift Timings ──
                    _buildFacilityCard(
                      deptKey: 'dispensary',
                      title: 'Dispensary Camps / Desks (${_dispensaries.length})',
                      subtitle: 'Medical clinical consultations, patient registration & medicine dispensing',
                      icon: Icons.local_hospital_rounded,
                      color: const Color(0xFF0D9488),
                      ctrl: _dispensaryInputCtrl,
                      hint: 'e.g. Saddar Dispensary, Haji Camp',
                      onAdd: _addDispensary,
                      items: _dispensaries,
                      sessionOptions: const [
                        {'key': 'morning', 'label': '☀️ Morning', 'icon': Icons.wb_sunny_rounded, 'color': Color(0xFFF59E0B)},
                        {'key': 'evening', 'label': '🌅 Evening', 'icon': Icons.nights_stay_rounded, 'color': Color(0xFF3B82F6)},
                        {'key': 'night',   'label': '🌙 Night',   'icon': Icons.dark_mode_rounded,   'color': Color(0xFF8B5CF6)},
                      ],
                      onDelete: (id) => setState(() => _dispensaries.removeWhere((i) => i['id'] == id)),
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      borderColor: borderColor,
                      inputBg: inputBg,
                    ),
                    const SizedBox(height: 24),

                    // ── Section 2: Dasterkhwaan Meal Desks & Separate Shift Timings ──
                    _buildFacilityCard(
                      deptKey: 'dasterkhwaan',
                      title: 'Dasterkhwaan Meal Units & Desks (${_dasterkhwaans.length})',
                      subtitle: 'Kitchen food distribution, breakfast, lunch, dinner & special meal shifts',
                      icon: Icons.restaurant_rounded,
                      color: const Color(0xFFEA580C),
                      ctrl: _dasterkhwaanInputCtrl,
                      hint: 'e.g. Unit 1 - Main Dasterkhwaan, Camp 2 Desks',
                      onAdd: _addDasterkhwaan,
                      items: _dasterkhwaans,
                      sessionOptions: const [
                        {'key': 'evening', 'label': '🌅 Evening / Dinner (شام)', 'icon': Icons.wb_sunny_rounded,    'color': Color(0xFFEA580C)},
                        {'key': 'night',   'label': '🌙 Night / Sehri (رات)',     'icon': Icons.dark_mode_rounded,   'color': Color(0xFF8B5CF6)},
                        {'key': 'morning', 'label': '☀️ Morning / Breakfast',     'icon': Icons.free_breakfast_rounded, 'color': Color(0xFFF59E0B)},
                        {'key': 'lunch',   'label': '🍲 Lunch / Afternoon',       'icon': Icons.lunch_dining_rounded,   'color': Color(0xFF10B981)},
                      ],
                      onDelete: (id) => setState(() => _dasterkhwaans.removeWhere((i) => i['id'] == id)),
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      borderColor: borderColor,
                      inputBg: inputBg,
                    ),
                    const SizedBox(height: 24),

                    // ── Section 3: Madrassa Campuses & Separate Shift Timings ──
                    _buildFacilityCard(
                      deptKey: 'madrassa',
                      title: 'Madrassa Campuses (${_madrassas.length})',
                      subtitle: 'Quranic education, student attendance, Hifz & Nazra classes',
                      icon: Icons.menu_book_rounded,
                      color: const Color(0xFF059669),
                      ctrl: _madrassaInputCtrl,
                      hint: 'e.g. Main Madrassa, Hifz Section',
                      onAdd: _addMadrassa,
                      items: _madrassas,
                      sessionOptions: const [
                        {'key': 'morning', 'label': '☀️ Morning / Day', 'icon': Icons.wb_sunny_rounded, 'color': Color(0xFFF59E0B)},
                        {'key': 'evening', 'label': '🌅 Evening',       'icon': Icons.nights_stay_rounded, 'color': Color(0xFF3B82F6)},
                        {'key': 'night',   'label': '🌙 Night',         'icon': Icons.dark_mode_rounded,   'color': Color(0xFF8B5CF6)},
                      ],
                      onDelete: (id) => setState(() => _madrassas.removeWhere((i) => i['id'] == id)),
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      borderColor: borderColor,
                      inputBg: inputBg,
                    ),
                    const SizedBox(height: 24),

                    // ── Section 4: School Wings & Separate Shift Timings ──
                    _buildFacilityCard(
                      deptKey: 'school',
                      title: 'School Wings / Campus (${_schools.length})',
                      subtitle: 'Taleem-wa-Tarbiyat academic classes, faculty & student schedules',
                      icon: Icons.school_rounded,
                      color: const Color(0xFF4F46E5),
                      ctrl: _schoolInputCtrl,
                      hint: 'e.g. Primary Wing, Girls Section',
                      onAdd: _addSchool,
                      items: _schools,
                      sessionOptions: const [
                        {'key': 'morning', 'label': '☀️ Morning / Day Shift',        'icon': Icons.wb_sunny_rounded, 'color': Color(0xFFF59E0B)},
                        {'key': 'evening', 'label': '🌅 Evening / Afternoon Shift',  'icon': Icons.nights_stay_rounded, 'color': Color(0xFF3B82F6)},
                        {'key': 'night',   'label': '🌙 Night Shift',                'icon': Icons.dark_mode_rounded,   'color': Color(0xFF8B5CF6)},
                      ],
                      onDelete: (id) => setState(() => _schools.removeWhere((i) => i['id'] == id)),
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      borderColor: borderColor,
                      inputBg: inputBg,
                    ),
                  ],
                ),
              ),
            ),

            // Footer Actions
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: borderColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: subtextColor, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    onPressed: _isSaving ? null : _saveBranchData,
                    icon: _isSaving
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_circle_rounded, size: 18),
                    label: Text(_isSaving ? 'Saving Configurations...' : 'Save & Sync All Schedules'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFacilityCard({
    required String deptKey,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required TextEditingController ctrl,
    required String hint,
    required VoidCallback onAdd,
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> sessionOptions,
    required Function(String id) onDelete,
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
    required Color borderColor,
    required Color inputBg,
  }) {
    final deptConf = _sessionsConfig[deptKey] as Map<String, dynamic>? ?? {};

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Department Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF1E293B),
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: subtextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Department Dedicated Shift Timings & Allowance Panel ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 16, color: color),
                    const SizedBox(width: 6),
                    Text(
                      'Operational Hours & Shift Timings',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        letterSpacing: 0.3,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Department Specific',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                ...sessionOptions.map((opt) {
                  final sKey = opt['key'] as String;
                  final sLabel = opt['label'] as String;
                  final sIcon = opt['icon'] as IconData? ?? Icons.schedule_rounded;
                  final sColor = opt['color'] as Color? ?? color;

                  final sConf = deptConf[sKey] as Map<String, dynamic>? ?? {
                    'enabled': sKey != 'night',
                    'openTime': '08:00',
                    'closeTime': '14:00',
                  };
                  final isEnabled = sConf['enabled'] == true;
                  final openTime = sConf['openTime']?.toString() ?? '08:00';
                  final closeTime = sConf['closeTime']?.toString() ?? '14:00';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isEnabled ? sColor.withValues(alpha: 0.35) : borderColor,
                        width: isEnabled ? 1.0 : 0.6,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(sIcon, size: 16, color: sColor),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: Text(
                            sLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : textColor,
                            ),
                          ),
                        ),

                        // Allowed Switch
                        Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: isEnabled,
                            activeTrackColor: sColor.withValues(alpha: 0.5),
                            activeThumbColor: sColor,
                            onChanged: (val) {
                              setState(() {
                                if (deptConf[sKey] is! Map) {
                                  deptConf[sKey] = <String, dynamic>{};
                                }
                                (deptConf[sKey] as Map)['enabled'] = val;
                                if (deptKey == 'dispensary') {
                                  if (_sessionsConfig[sKey] is Map) {
                                    (_sessionsConfig[sKey] as Map)['enabled'] = val;
                                  }
                                }
                              });
                            },
                          ),
                        ),

                        if (isEnabled) ...[
                          const SizedBox(width: 8),
                          // Open Time Picker
                          InkWell(
                            onTap: () => _pickDeptTime(context, deptKey, sKey, 'openTime'),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: borderColor),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    'Open: ${_formatTimeStr(openTime)}',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textColor),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.edit_calendar_rounded, size: 12, color: sColor),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('-', style: TextStyle(color: subtextColor, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),

                          // Close Time Picker
                          InkWell(
                            onTap: () => _pickDeptTime(context, deptKey, sKey, 'closeTime'),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: borderColor),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    'Close: ${_formatTimeStr(closeTime)}',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textColor),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.edit_calendar_rounded, size: 12, color: sColor),
                                ],
                              ),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'DISALLOWED / CLOSED',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.redAccent),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),

          if (deptKey == 'dispensary') ...[
            const SizedBox(height: 14),
            _buildVitalsTokenToggle(
              isDark: isDark,
              borderColor: borderColor,
              subtextColor: subtextColor,
            ),
            const SizedBox(height: 14),
            _buildDoctorInventoryApprovalToggle(
              isDark: isDark,
              borderColor: borderColor,
              subtextColor: subtextColor,
            ),
          ],

          if (deptKey == 'madrassa') ...[
            const SizedBox(height: 14),
            _buildMadrassaMoneyFactorToggle(
              isDark: isDark,
              borderColor: borderColor,
              subtextColor: subtextColor,
            ),
          ],

          const SizedBox(height: 16),

          // ── Registered Facility Desks & Individual Schedule Overrides ──
          Text(
            'Registered Units & Sub-Facility Desks',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor),
          ),
          const SizedBox(height: 8),

          // Input Row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  style: TextStyle(color: textColor, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: subtextColor, fontSize: 12),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                  ),
                  onSubmitted: (_) => onAdd(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add Desk/Unit'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Facility Items List
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'No units or desks registered for this department yet.',
                style: TextStyle(fontSize: 12, color: subtextColor, fontStyle: FontStyle.italic),
              ),
            )
          else
            ...items.map((facility) {
              final id = facility['id']?.toString() ?? '';
              final name = facility['name']?.toString() ?? id;
              final activeSessions = (facility['sessions'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
              final customTimings = facility['sessionTimings'] as Map<String, dynamic>? ?? {};

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: color.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'ID: $id',
                          style: TextStyle(fontSize: 11, color: subtextColor),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                          tooltip: 'Remove unit',
                          onPressed: () => onDelete(id),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Active Sessions: ',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtextColor),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: sessionOptions.map((opt) {
                              final sKey = opt['key'] as String;
                              final sLabel = opt['label'] as String;
                              final isSelected = activeSessions.contains(sKey);

                              // Effective timing for this session
                              final deptSessConf = deptConf[sKey] as Map<String, dynamic>? ?? {};
                              final defaultOpen = deptSessConf['openTime']?.toString() ?? '08:00';
                              final defaultClose = deptSessConf['closeTime']?.toString() ?? '14:00';

                              final customSess = customTimings[sKey] as Map<String, dynamic>? ?? {};
                              final effOpen = customSess['openTime']?.toString() ?? defaultOpen;
                              final effClose = customSess['closeTime']?.toString() ?? defaultClose;

                              return FilterChip(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(sLabel),
                                    if (isSelected) ...[
                                      const SizedBox(width: 6),
                                      InkWell(
                                        onTap: () async {
                                          await _pickFacilityCustomTime(context, facility, sKey, 'openTime', defaultOpen);
                                          if (mounted) {
                                            await _pickFacilityCustomTime(context, facility, sKey, 'closeTime', defaultClose);
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: color.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                '${_formatTimeStr(effOpen)} - ${_formatTimeStr(effClose)}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDark ? Colors.white70 : color,
                                                ),
                                              ),
                                              const SizedBox(width: 3),
                                              Icon(Icons.edit_rounded, size: 10, color: isDark ? Colors.white70 : color),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                selected: isSelected,
                                selectedColor: color.withValues(alpha: 0.25),
                                checkmarkColor: isDark ? Colors.white : color,
                                labelStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected
                                      ? (isDark ? Colors.white : color)
                                      : subtextColor,
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(
                                  color: isSelected ? color : borderColor,
                                  width: isSelected ? 1.2 : 0.8,
                                ),
                                backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                                onSelected: (_) => _toggleSession(facility, sKey),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildVitalsTokenToggle({
    required bool isDark,
    required Color borderColor,
    required Color subtextColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _allowVitalsToken
            ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.35) : const Color(0xFFECFDF5))
            : (isDark ? const Color(0xFF450A0A).withValues(alpha: 0.35) : const Color(0xFFFEF2F2)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _allowVitalsToken ? const Color(0xFF10B981) : const Color(0xFFEF4444),
          width: 1.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _allowVitalsToken ? const Color(0xFF10B981) : const Color(0xFFEF4444),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _allowVitalsToken ? Icons.monitor_heart : Icons.heart_broken_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Dual Token Feasibility (Vitals + Doctor)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _allowVitalsToken
                            ? const Color(0xFF10B981).withValues(alpha: 0.15)
                            : const Color(0xFFEF4444).withValues(alpha: 0.15),
                      ),
                      child: Text(
                        _allowVitalsToken ? 'DUAL TOKEN ALLOWED 🟢' : 'SINGLE TOKEN ONLY 🔴',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _allowVitalsToken ? const Color(0xFF059669) : const Color(0xFFDC2626),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _allowVitalsToken
                      ? 'Dual Token Allowed: Receptionist can issue both Vitals-Only and Regular Consultation tokens for the same patient in one day.'
                      : 'Single Token Only: Strict limit of 1 token per patient per day. Once any token is issued today, no further tokens can be issued without Doctor approval.',
                  style: TextStyle(fontSize: 11, color: subtextColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: _allowVitalsToken,
            activeColor: const Color(0xFF10B981),
            inactiveThumbColor: Colors.red.shade400,
            inactiveTrackColor: Colors.red.shade100,
            onChanged: (val) {
              setState(() {
                _allowVitalsToken = val;
                if (_sessionsConfig['dispensary'] is Map) {
                  (_sessionsConfig['dispensary'] as Map)['allowVitalsToken'] = val;
                }
                _sessionsConfig['allowVitalsToken'] = val;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDoctorInventoryApprovalToggle({
    required bool isDark,
    required Color borderColor,
    required Color subtextColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _allowDoctorInventoryApproval
              ? const Color(0xFF0F766E).withValues(alpha: 0.5)
              : borderColor,
          width: _allowDoctorInventoryApproval ? 1.2 : 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _allowDoctorInventoryApproval ? const Color(0xFF0F766E) : const Color(0xFF64748B),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _allowDoctorInventoryApproval ? Icons.approval_rounded : Icons.lock_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Doctor Medicine & Request Approvals',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _allowDoctorInventoryApproval
                            ? const Color(0xFF10B981).withValues(alpha: 0.15)
                            : const Color(0xFF64748B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _allowDoctorInventoryApproval ? 'ENABLED 🟢' : 'DISABLED ⚪',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _allowDoctorInventoryApproval ? const Color(0xFF059669) : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _allowDoctorInventoryApproval
                      ? 'Doctor panel includes full medicine inventory access and supervisor-level request approval powers (medicine restock, proforma, stock edits).'
                      : 'Doctor panel is restricted to clinical consultation and prescriptions only.',
                  style: TextStyle(fontSize: 11, color: subtextColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: _allowDoctorInventoryApproval,
            activeColor: const Color(0xFF0F766E),
            inactiveThumbColor: Colors.grey.shade400,
            inactiveTrackColor: Colors.grey.shade200,
            onChanged: (val) {
              setState(() {
                _allowDoctorInventoryApproval = val;
                if (_sessionsConfig['dispensary'] is Map) {
                  (_sessionsConfig['dispensary'] as Map)['allowDoctorInventoryApproval'] = val;
                }
                _sessionsConfig['allowDoctorInventoryApproval'] = val;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMadrassaMoneyFactorToggle({
    required bool isDark,
    required Color borderColor,
    required Color subtextColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _madrassaFeeEnabled
            ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.35) : const Color(0xFFECFDF5))
            : (isDark ? const Color(0xFF451A03).withValues(alpha: 0.35) : const Color(0xFFFFFBEB)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _madrassaFeeEnabled ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
          width: 1.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _madrassaFeeEnabled ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _madrassaFeeEnabled ? Icons.payments_rounded : Icons.money_off_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Madrassa Financial System & Fees (Money Factor)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _madrassaFeeEnabled ? const Color(0xFF10B981).withValues(alpha: 0.15) : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _madrassaFeeEnabled ? 'FEES ACTIVE' : 'FREE / NO FEES',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _madrassaFeeEnabled ? const Color(0xFF059669) : const Color(0xFFD97706),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _madrassaFeeEnabled
                      ? 'Keep money factor active: Student monthly dues, base tuition, fee deduction rewards, and payment cards operate as standard across Parent, Teacher, and Principal screens.'
                      : 'Remove money factor: All student fees, monthly dues, discounts, and payment records are completely stopped and hidden across Parent, Teacher, and Principal screens (100% Free / Non-Fee Facility).',
                  style: TextStyle(fontSize: 11, color: subtextColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: _madrassaFeeEnabled,
            activeColor: const Color(0xFF10B981),
            onChanged: (val) {
              setState(() {
                _madrassaFeeEnabled = val;
                if (_sessionsConfig['madrassa'] is Map) {
                  (_sessionsConfig['madrassa'] as Map)['enableFees'] = val;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCampsCard({
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
    required Color borderColor,
    required Color inputBg,
  }) {
    const color = Color(0xFF0284C7); // Sky blue / Cyan

    const deptDefinitions = [
      {'key': 'dispensary',   'label': '🏥 Dispensary',   'color': Color(0xFF0D9488)},
      {'key': 'dasterkhwaan', 'label': '🍽️ Dasterkhwaan', 'color': Color(0xFFEA580C)},
      {'key': 'madrassa',     'label': '📖 Madrassa',     'color': Color(0xFF059669)},
      {'key': 'school',       'label': '🏫 School',       'color': Color(0xFF4F46E5)},
    ];

    const sessionOptions = [
      {'key': 'morning', 'label': '☀️ Morning', 'color': Color(0xFFF59E0B)},
      {'key': 'evening', 'label': '🌅 Evening', 'color': Color(0xFF3B82F6)},
      {'key': 'night',   'label': '🌙 Night',   'color': Color(0xFF8B5CF6)},
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF0F9FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? color.withValues(alpha: 0.3) : const Color(0xFFBAE6FD), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.holiday_village_rounded, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Camps & Field Sub-Locations (${_camps.length})',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF0369A1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: color.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            '${_camps.where((c) => c['isClosed'] != true).length} Active',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Manage branch camps, assign operational departments (Dispensary, Dasterkhwaan, Madrassa, School), configure timings, and close/reopen camps just like branches.',
                      style: TextStyle(fontSize: 11, color: subtextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Add New Camp Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Register New Camp / Sub-Facility',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _campInputCtrl,
                        style: TextStyle(color: textColor, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'e.g. Model Town Camp, DHA Medical Center, Kapayya Desk',
                          hintStyle: TextStyle(color: subtextColor, fontSize: 12),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
                        ),
                        onSubmitted: (_) => _addCamp(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _addCamp,
                      icon: const Icon(Icons.add_location_alt_rounded, size: 16),
                      label: const Text('Add Camp'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('Initial Departments: ', style: TextStyle(fontSize: 11, color: subtextColor, fontWeight: FontWeight.w600)),
                    ...deptDefinitions.map((d) {
                      final key = d['key'] as String;
                      final label = d['label'] as String;
                      final isSelected = _newCampDepts.contains(key);
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(label, style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                          selected: isSelected,
                          selectedColor: (d['color'] as Color).withValues(alpha: 0.2),
                          checkmarkColor: d['color'] as Color,
                          onSelected: (val) {
                            setState(() {
                              if (val) {
                                _newCampDepts.add(key);
                              } else if (_newCampDepts.length > 1) {
                                _newCampDepts.remove(key);
                              }
                            });
                          },
                        ),
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Camps List
          if (_camps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No camps registered for this branch yet. Add camps above to enable multi-location operations.',
                style: TextStyle(fontSize: 12, color: subtextColor, fontStyle: FontStyle.italic),
              ),
            )
          else
            ..._camps.map((camp) {
              final id = (camp['id'] ?? '').toString();
              final name = (camp['name'] ?? id).toString();
              final isClosed = camp['isClosed'] == true;
              final depts = List<String>.from(camp['departments'] as List? ?? ['dispensary']);
              final activeSessions = List<String>.from(camp['sessions'] as List? ?? ['morning', 'evening']);
              final customTimings = camp['sessionTimings'] as Map<String, dynamic>? ?? {};

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isClosed
                      ? (isDark ? const Color(0xFF451A03).withValues(alpha: 0.25) : const Color(0xFFFEF2F2))
                      : (isDark ? const Color(0xFF1E293B) : Colors.white),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isClosed ? Colors.red.withValues(alpha: 0.35) : borderColor,
                    width: isClosed ? 1.2 : 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Camp Header Row
                    Row(
                      children: [
                        Icon(
                          isClosed ? Icons.location_off_rounded : Icons.location_on_rounded,
                          color: isClosed ? Colors.redAccent : color,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isClosed ? (isDark ? Colors.white60 : Colors.black54) : textColor,
                            decoration: isClosed ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isClosed ? Colors.red.withValues(alpha: 0.12) : Colors.green.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isClosed ? Colors.red.withValues(alpha: 0.3) : Colors.green.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            isClosed ? '🔴 CLOSED / ARCHIVED' : '🟢 ACTIVE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isClosed ? Colors.redAccent : Colors.green,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('ID: $id', style: TextStyle(fontSize: 11, color: subtextColor)),
                        const Spacer(),

                        // Close / Reopen Toggle Button
                        OutlinedButton.icon(
                          onPressed: () => _toggleCampClose(camp),
                          icon: Icon(
                            isClosed ? Icons.published_with_changes_rounded : Icons.archive_rounded,
                            size: 14,
                            color: isClosed ? Colors.green : Colors.orange.shade800,
                          ),
                          label: Text(
                            isClosed ? 'Reopen Camp' : 'Close Camp',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isClosed ? Colors.green : Colors.orange.shade800,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            side: BorderSide(color: isClosed ? Colors.green : Colors.orange.shade800),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(width: 6),

                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                          tooltip: 'Remove Camp',
                          onPressed: () {
                            setState(() {
                              _camps.removeWhere((c) => c['id'] == id);
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Included Departments Row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Active Departments: ',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtextColor),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: deptDefinitions.map((d) {
                              final dKey = d['key'] as String;
                              final dLabel = d['label'] as String;
                              final dColor = d['color'] as Color;
                              final isSelected = depts.contains(dKey);

                              return FilterChip(
                                label: Text(dLabel),
                                selected: isSelected,
                                selectedColor: dColor.withValues(alpha: 0.22),
                                checkmarkColor: isDark ? Colors.white : dColor,
                                labelStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? (isDark ? Colors.white : dColor) : subtextColor,
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(
                                  color: isSelected ? dColor : borderColor,
                                  width: isSelected ? 1.2 : 0.8,
                                ),
                                onSelected: (_) => _toggleCampDept(camp, dKey),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Active Sessions Row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Active Shifts: ',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtextColor),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: sessionOptions.map((opt) {
                              final sKey = opt['key'] as String;
                              final sLabel = opt['label'] as String;
                              final sColor = opt['color'] as Color;
                              final isSelected = activeSessions.contains(sKey);

                              final customSess = customTimings[sKey] as Map<String, dynamic>? ?? {};
                              final effOpen = customSess['openTime']?.toString() ?? (sKey == 'morning' ? '08:00' : (sKey == 'evening' ? '16:00' : '22:00'));
                              final effClose = customSess['closeTime']?.toString() ?? (sKey == 'morning' ? '14:00' : (sKey == 'evening' ? '22:00' : '04:00'));

                              return FilterChip(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(sLabel),
                                    if (isSelected) ...[
                                      const SizedBox(width: 5),
                                      InkWell(
                                        onTap: () async {
                                          await _pickFacilityCustomTime(context, camp, sKey, 'openTime', effOpen);
                                          if (mounted) {
                                            await _pickFacilityCustomTime(context, camp, sKey, 'closeTime', effClose);
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: sColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                '${_formatTimeStr(effOpen)} - ${_formatTimeStr(effClose)}',
                                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : sColor),
                                              ),
                                              const SizedBox(width: 2),
                                              Icon(Icons.edit_rounded, size: 9, color: isDark ? Colors.white70 : sColor),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                selected: isSelected,
                                selectedColor: sColor.withValues(alpha: 0.22),
                                checkmarkColor: isDark ? Colors.white : sColor,
                                labelStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? (isDark ? Colors.white : sColor) : subtextColor,
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(
                                  color: isSelected ? sColor : borderColor,
                                  width: isSelected ? 1.2 : 0.8,
                                ),
                                onSelected: (_) => _toggleSession(camp, sKey),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

