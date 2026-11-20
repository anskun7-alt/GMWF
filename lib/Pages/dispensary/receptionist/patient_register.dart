// lib/pages/dispensary/receptionist/patient_register.dart

import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/services.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf/services/firestore_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/utils/branch_labels.dart';

class PatientRegisterPage extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String? initialCnic;
  final void Function(String patientIdOrCnic)? onPatientRegistered;
  final bool isCompactHybrid;

  const PatientRegisterPage({
    super.key,
    required this.branchId,
    required this.receptionistId,
    this.initialCnic,
    this.onPatientRegistered,
    this.isCompactHybrid = false,
  });

  @override
  State<PatientRegisterPage> createState() => PatientRegisterPageState();
}

class PatientRegisterPageState extends State<PatientRegisterPage> {
  final _formKey       = GlobalKey<FormState>();
  final _formScopeNode = FocusScopeNode();

  final _nameController  = TextEditingController();
  final _cnicController  = TextEditingController();
  final _phoneController = TextEditingController();
  final _dobController   = TextEditingController();
  final _ageController   = TextEditingController();

  String? _selectedGender = 'Male';
  String? _selectedBloodGroup = 'N/A';
  String? _guardianName;
  String? _guardianPhone;
  String  _visitType     = 'Zakat';
  int     _calculatedAge = 0;
  bool    _isSaving      = false;
  bool    _isChild       = false;
  // Child mode was forced because the CNIC belongs to a registered adult (shown inline).
  bool    _autoSwitchedToChild = false;
  // Bumped to replay the guardian notice's attention shake.
  int     _guardianNoticePulse = 0;

  bool get _isKarachi => BranchLabels.isKarachiBranch(widget.branchId);

  final _nameNode        = FocusNode();
  final _cnicNode        = FocusNode();
  final _phoneNode       = FocusNode();
  final _ageNode         = FocusNode();
  final _dobNode         = FocusNode();
  final _genderNode      = FocusNode();
  final _bloodGroupNode  = FocusNode();
  final _visitNode       = FocusNode();
  final _registerButtonNode = FocusNode();

  final _nameKey       = GlobalKey();
  final _cnicKey       = GlobalKey();
  final _phoneKey      = GlobalKey();
  final _ageKey        = GlobalKey();
  final _dobKey        = GlobalKey();
  final _genderKey     = GlobalKey();
  final _bloodGroupKey = GlobalKey();
  final _visitKey      = GlobalKey();

  final _scrollController = ScrollController();
  Timer? _cnicDebounceTimer;

  List<FocusNode> get activeFocusNodes {
    return [
      _cnicNode,
      _phoneNode,
      _nameNode,
      _ageNode,
      _dobNode,
      _genderNode,
      _bloodGroupNode,
      _visitNode,
      _registerButtonNode,
    ];
  }

  @override
  void initState() {
    super.initState();
    _selectedGender = 'Male';
    _selectedBloodGroup ??= 'N/A';
    if (_isKarachi && _visitType == 'Non-Zakat') {
      _visitType = 'Zakat';
    }
    _addFocusListeners();
    _cnicController.addListener(_handleCnicChanged);
    if (widget.initialCnic != null && widget.initialCnic!.isNotEmpty) {
      _cnicController.text = _formatCnic(widget.initialCnic!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleCnicChanged(widget.initialCnic!);
        _nameNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant PatientRegisterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCnic != null &&
        widget.initialCnic!.isNotEmpty &&
        widget.initialCnic != oldWidget.initialCnic) {
      prefillCnic(widget.initialCnic!);
    }
  }

  void _addFocusListeners() {
    void scrollTo(BuildContext? ctx) {
      if (ctx != null && _scrollController.hasClients) {
        final renderObject = ctx.findRenderObject();
        if (renderObject != null) {
          _scrollController.position.ensureVisible(
            renderObject,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      }
    }

    _nameNode.addListener(()       { if (_nameNode.hasFocus)       scrollTo(_nameKey.currentContext); });
    _cnicNode.addListener(()       { if (_cnicNode.hasFocus)       scrollTo(_cnicKey.currentContext); });
    _phoneNode.addListener(()      { if (_phoneNode.hasFocus)      scrollTo(_phoneKey.currentContext); });
    _ageNode.addListener(()        { if (_ageNode.hasFocus)        scrollTo(_ageKey.currentContext); });
    _dobNode.addListener(()        { if (_dobNode.hasFocus)        scrollTo(_dobKey.currentContext); });
    _genderNode.addListener(()     { if (_genderNode.hasFocus)     scrollTo(_genderKey.currentContext); });
    _bloodGroupNode.addListener(() { if (_bloodGroupNode.hasFocus) scrollTo(_bloodGroupKey.currentContext); });
    _visitNode.addListener(()      { if (_visitNode.hasFocus)      scrollTo(_visitKey.currentContext); });
  }

  @override
  void dispose() {
    _cnicDebounceTimer?.cancel();
    _formScopeNode.dispose();
    _scrollController.dispose();
    for (var c in [_nameController, _cnicController, _phoneController, _dobController, _ageController]) {
      c.dispose();
    }
    for (var n in [
      _nameNode, _cnicNode, _phoneNode, _ageNode, _dobNode,
      _genderNode, _bloodGroupNode, _visitNode, _registerButtonNode,
    ]) {
      n.dispose();
    }
    super.dispose();
  }

  void prefillCnic(String cnic) {
    final formatted = _formatCnic(cnic);
    if (_cnicController.text != formatted) {
      _cnicController.text = formatted;
    }
    _handleCnicChanged(cnic);
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nameNode.requestFocus();
      });
    }
  }

  String _formatCnic(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 5)  return digits;
    if (digits.length <= 12) return '${digits.substring(0, 5)}-${digits.substring(5)}';
    return '${digits.substring(0, 5)}-${digits.substring(5, 12)}-${digits.substring(12, digits.length > 13 ? 13 : digits.length)}';
  }

  void _calculateAge(String dob) {
    if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(dob)) {
      return;
    }
    final birth = parseDobDateTime(dob);
    if (birth == null) {
      return;
    }
    final today = DateTime.now();
    int age     = today.year - birth.year;
    if (today.month < birth.month ||
        (today.month == birth.month && today.day < birth.day)) {
      age--;
    }
    final newAge = age >= 0 ? age : 0;
    if (_calculatedAge != newAge) {
      setState(() => _calculatedAge = newAge);
    }
    if (_ageController.text != newAge.toString()) {
      _ageController.text = newAge.toString();
    }
  }

  void _onAgeChanged(String val) {
    final age = int.tryParse(val.trim());
    if (age != null && age >= 0 && age <= 130) {
      if (_calculatedAge != age) {
        setState(() => _calculatedAge = age);
      }
      final approxYear = DateTime.now().year - age;
      final approxDob = '01-01-$approxYear';
      if (_dobController.text != approxDob) {
        _dobController.text = approxDob;
      }
    } else if (val.trim().isEmpty) {
      if (_calculatedAge != 0) {
        setState(() => _calculatedAge = 0);
      }
    }
  }

  Future<void> _pickDobDate() async {
    final now = DateTime.now();
    final initialDate = _calculatedAge > 0
        ? now.subtract(Duration(days: 365 * _calculatedAge))
        : (_isChild ? now.subtract(const Duration(days: 365 * 5)) : now.subtract(const Duration(days: 365 * 25)));
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(now) ? now : (initialDate.year < 1900 ? DateTime(1900) : initialDate),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) {
      final formatted = '${picked.day.toString().padLeft(2, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.year}';
      _dobController.text = formatted;
      _calculateAge(formatted);
      if (_calculatedAge >= 0) {
        _ageController.text = _calculatedAge.toString();
      }
    }
  }

  DateTime? _resolveDob() {
    if (_dobController.text.trim().isNotEmpty) {
      final parsed = parseDobDateTime(_dobController.text.trim());
      if (parsed != null) return parsed;
    }
    final ageFromCtrl = int.tryParse(_ageController.text.trim()) ?? _calculatedAge;
    if (ageFromCtrl > 0) {
      return DateTime(DateTime.now().year - ageFromCtrl, 1, 1);
    }
    return null;
  }

  void _cleanupFormFields() {
    _nameController.clear();
    _cnicController.clear();
    _phoneController.clear();
    _dobController.clear();
    _ageController.clear();
    if (mounted) {
      setState(() {
        _guardianName       = null;
        _guardianPhone      = null;
        _selectedGender     = 'Male';
        _selectedBloodGroup = 'N/A';
        _visitType          = 'Zakat';
        _isChild            = false;
        _autoSwitchedToChild = false;
        _calculatedAge      = 0;
      });
    }
  }

  Future<void> _savePatient() async {
    if (!_formKey.currentState!.validate()) {
      if (mounted) {
        AppFeedback.showWarning(
          context,
          'Please complete all required fields',
          subtitle: 'Ensure CNIC/Phone, Full Name, and Date of Birth or Age are entered.',
        );
      }
      return;
    }

    final formattedCnic = _cnicController.text.trim();

    setState(() => _isSaving = true);

    try {
      final ageFromCtrl = int.tryParse(_ageController.text.trim());
      if (ageFromCtrl != null && ageFromCtrl >= 0) {
        _calculatedAge = ageFromCtrl;
      }

      DateTime? dob = _resolveDob();
      if (dob == null) {
        if (mounted) {
          AppFeedback.showWarning(context, 'Please enter a valid date of birth or age');
        }
        return;
      }

      final enteredName = _nameController.text.trim();
      final normEntered = enteredName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final rawClean = formattedCnic.replaceAll('-', '').trim();
      final cleanBranch = LocalStorageService.sanitizeBranchId(widget.branchId);

      Map<String, dynamic>? localAdult = LocalStorageService.getLocalPatientByCnic(formattedCnic) ??
          LocalStorageService.getLocalPatientByCnic(rawClean);

      // Verify Firestore in case adult was registered on another terminal in the branch
      if (localAdult == null && rawClean.length == 13) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(cleanBranch)
              .collection('patients')
              .doc(rawClean)
              .get()
              .timeout(const Duration(milliseconds: 600));
          if (doc.exists && doc.data() != null) {
            final data = doc.data()!;
            final isAdult = data['isAdult'] != false && !(data['patientId']?.toString().contains('_child_') ?? false);
            if (isAdult) {
              await LocalStorageService.saveLocalPatient(data);
              localAdult = data;
            }
          }
        } catch (_) {}
      }

      bool isRegisteringAsChildOfAdult = false;
      String? adultGuardianName;

      if (localAdult != null) {
        final isAdult = localAdult['isAdult'] != false &&
            !(localAdult['patientId']?.toString().contains('_child_') ?? false);
        if (isAdult) {
          adultGuardianName = (localAdult['name'] ?? localAdult['patientName'] ?? 'Adult').toString().trim();
          final normAdult = adultGuardianName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

          if (normEntered.isNotEmpty && normAdult.isNotEmpty && normEntered != normAdult) {
            // Patient B is a different patient entering the same CNIC as Patient A!
            // Never overwrite Patient A. Automatically register Patient B as the child of Patient A!
            isRegisteringAsChildOfAdult = true;
          }
        }
      }

      final effectiveIsChild = _isChild || isRegisteringAsChildOfAdult;

      if (!isRegisteringAsChildOfAdult && effectiveIsChild && _calculatedAge >= 20 && localAdult == null && formattedCnic.isEmpty) {
        if (mounted) {
          AppFeedback.showWarning(
            context,
            'Patient is $_calculatedAge years old',
            subtitle: 'Considered adult (child limit is under 20). Register with their own CNIC.',
          );
        }
        return;
      }

      if (effectiveIsChild && formattedCnic.isEmpty) {
        if (mounted) {
          AppFeedback.showWarning(
            context,
            'Guardian CNIC required',
            subtitle: 'A valid guardian CNIC is required for child registration.',
          );
        }
        return;
      }

      if (isRegisteringAsChildOfAdult && !_isChild) {
        setState(() {
          _isChild = true;
          _guardianName = adultGuardianName;
          _guardianPhone = (localAdult!['phone'] ?? localAdult['contactPhone'])?.toString();
          if (_guardianPhone != null && _phoneController.text.trim().isEmpty) {
            _phoneController.text = _guardianPhone!;
          }
        });
      }

      final guardianPhone = (localAdult?['phone'] ?? localAdult?['contactPhone'])?.toString().trim();

      final patientMap = <String, dynamic>{
        'branchId':    cleanBranch,
        'name':        enteredName,
        'isAdult':     !effectiveIsChild,
        'guardianCnic': effectiveIsChild ? formattedCnic : null,
        'guardianName': effectiveIsChild ? (_guardianName ?? adultGuardianName) : null,
        'cnic':        effectiveIsChild ? null : formattedCnic,
        'dob':         dob.toIso8601String(),
        'gender':      _selectedGender ?? 'Male',
        'bloodGroup':  _selectedBloodGroup ?? 'N/A',
        'status':      (_isKarachi && _visitType == 'Non-Zakat') ? 'Zakat' : _visitType,
        'phone':       _phoneController.text.trim().isNotEmpty
            ? _phoneController.text.trim()
            : (effectiveIsChild && guardianPhone != null && guardianPhone.isNotEmpty
                ? guardianPhone
                : null),
        'age':         _calculatedAge,
        'createdBy':   widget.receptionistId,
        'createdAt':   DateTime.now().toIso8601String(),
      };

      final patientId = LocalStorageService.getPatientKey(patientMap);
      patientMap['patientId'] = patientId;

      final pBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
      if (pBox.containsKey(patientId)) {
        final existingRaw = pBox.get(patientId);
        final existingName = (existingRaw is Map ? (existingRaw['name'] ?? existingRaw['patientName']) : '')?.toString().trim() ?? '';
        final normExisting = existingName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

        // SAFETY LOCK: If an existing adult has a DIFFERENT name, NEVER overwrite! Register as child!
        if (normExisting.isNotEmpty && normEntered.isNotEmpty && normExisting != normEntered) {
          final childKey = '${rawClean}_child_${normEntered}';
          final childMap = Map<String, dynamic>.from(patientMap)
            ..['isAdult'] = false
            ..['guardianCnic'] = formattedCnic
            ..['guardianName'] = existingName
            ..['cnic'] = null
            ..['patientId'] = childKey;

          await LocalStorageService.saveLocalPatient(childMap, recordAudit: true);
          try {
            await FirestoreService().savePatient(
              branchId: cleanBranch,
              patientId: childKey,
              patientData: childMap,
            );
          } catch (_) {}
          SyncService().triggerUpload();

          if (mounted) {
            AppFeedback.showSuccess(
              context,
              'Registered "$enteredName" as Child of $existingName',
              subtitle: 'Adult record for $existingName was preserved and not overwritten.',
            );
          }
          _cleanupFormFields();
          widget.onPatientRegistered?.call(childKey);
          return;
        }

        // Same person coming back for a visit
        final merged = (existingRaw is Map)
            ? (Map<String, dynamic>.from(existingRaw)..addAll(patientMap))
            : patientMap;
        await LocalStorageService.saveLocalPatient(merged, recordAudit: true);
        try {
          await FirestoreService().savePatient(
            branchId: cleanBranch,
            patientId: patientId,
            patientData: merged,
          );
        } catch (e) {
          debugPrint('[PatientRegister] Firestore update notice: $e');
        }
        SyncService().triggerUpload();

        if (mounted) {
          AppFeedback.showInfo(
            context,
            'Patient already registered',
            subtitle: 'Navigating to token screen to issue token.',
          );
        }
        _cleanupFormFields();
        widget.onPatientRegistered?.call(patientId);
        return;
      }

      // STEP 1 — Hive first (offline-safe, instant, with audit trail)
      await LocalStorageService.saveLocalPatient(patientMap, recordAudit: true);
      debugPrint('[PatientRegister] ✅ Hive write: $patientId');

      // STEP 2 — Firestore Service handles LAN broadcast, durable queue, and direct cloud push
      try {
        await FirestoreService().savePatient(
          branchId:    cleanBranch,
          patientId:   patientId,
          patientData: patientMap,
        );
      } catch (e) {
        debugPrint('[PatientRegister] Firestore save notice (offline-safe): $e');
      }
      SyncService().triggerUpload();

      final message = isRegisteringAsChildOfAdult
          ? '$enteredName registered as child under Guardian $adultGuardianName!'
          : (effectiveIsChild
              ? 'Child patient registered successfully!'
              : 'Adult patient registered successfully!');
      if (mounted) {
        AppFeedback.showSuccess(
          context,
          message,
          subtitle: isRegisteringAsChildOfAdult
              ? 'Adult record for $adultGuardianName was preserved without being overwritten.'
              : 'Patient record saved locally and queued for sync.',
        );
      }

      _cleanupFormFields();
      widget.onPatientRegistered?.call(patientId);
    } catch (e, stack) {
      debugPrint('Patient registration failed: $e\n$stack');
      if (mounted) {
        AppFeedback.showError(
          context,
          'Registration failed',
          subtitle: e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  void _handleCnicChanged([String? overrideCnic]) {
    _cnicDebounceTimer?.cancel();
    final input = (overrideCnic ?? _cnicController.text).trim();
    final clean = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length < 13) {
      if (_guardianName != null || _guardianPhone != null || _autoSwitchedToChild) {
        setState(() {
          _guardianName = null;
          _guardianPhone = null;
          // CNIC changed: undo a Child switch that was forced by the old CNIC.
          if (_autoSwitchedToChild) {
            _isChild = false;
            _autoSwitchedToChild = false;
          }
        });
      }
      return;
    }

    // Debounce fast O(1) check by 150ms to eliminate UI stutter/lag during typing
    _cnicDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _executeCnicCheck(clean);
    });
  }

  void _executeCnicCheck(String clean) {
    final formatted = _formatCnic(clean);

    // Fast O(1) direct key lookup first before any box scan
    Map<String, dynamic>? adultRecord;
    try {
      if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        final box = Hive.box(LocalStorageService.patientsBox);
        dynamic direct = box.get(clean) ?? box.get(formatted);
        if (direct is Map) {
          final isAdult = direct['isAdult'] != false && !(direct['patientId']?.toString().contains('_child_') ?? false);
          if (isAdult) adultRecord = Map<String, dynamic>.from(direct);
        }
      }
      adultRecord ??= LocalStorageService.getLocalPatientByCnic(formatted) ??
          LocalStorageService.getLocalPatientByCnic(clean);
    } catch (_) {}

    if (adultRecord != null) {
      final isAdult = adultRecord['isAdult'] != false &&
          !(adultRecord['patientId']?.toString().contains('_child_') ?? false);
      if (isAdult) {
        final gName = (adultRecord['name'] ?? adultRecord['patientName'] ?? adultRecord['fullName'])?.toString().trim();
        final gPhone = (adultRecord['phone'] ?? adultRecord['contactPhone'])?.toString().trim();
        final effectiveName = (gName != null && gName.isNotEmpty) ? gName : 'Registered Adult';

        final wasAdultMode = !_isChild;
        setState(() {
          // Automatically switch to Child mode because this CNIC already belongs to an adult!
          // Explained by the inline notice under the CNIC field (a top toast was ignored).
          if (wasAdultMode) {
            _autoSwitchedToChild = true;
            _guardianNoticePulse++;
          }
          _isChild = true;
          _guardianName = effectiveName;
          _guardianPhone = (gPhone != null && gPhone.isNotEmpty) ? gPhone : null;
          if (_guardianPhone != null && _guardianPhone!.isNotEmpty && _phoneController.text.trim().isEmpty) {
            _phoneController.text = _guardianPhone!;
          }
        });
        return;
      }
    }

    // If local record not found, check Firestore in background in case registered on another terminal
    if (adultRecord == null && clean.length == 13) {
      final cleanBranch = LocalStorageService.sanitizeBranchId(widget.branchId);
      FirebaseFirestore.instance
          .collection('branches')
          .doc(cleanBranch)
          .collection('patients')
          .doc(clean)
          .get()
          .then((doc) {
        if (!mounted) return;
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final isAdult = data['isAdult'] != false && !(data['patientId']?.toString().contains('_child_') ?? false);
          if (isAdult) {
            LocalStorageService.saveLocalPatient(data);
            if (mounted) {
              _executeCnicCheck(clean);
            }
          }
        }
      }).catchError((_) {});
    }

    // If in Child mode and no guardian found
    if (_isChild && adultRecord == null) {
      if (_guardianName != null || _guardianPhone != null) {
        setState(() {
          _guardianName = null;
          _guardianPhone = null;
        });
      }
    }
  }

  /// Inline notice under the CNIC field. When Child mode was forced by an existing adult it
  /// is an amber "attention" card (with a shake), so the receptionist actually reads it;
  /// otherwise it is a calm green guardian confirmation.
  Widget _buildGuardianNotice(bool isMobile) {
    final forced = _autoSwitchedToChild;
    final accent = forced
        ? (_isDark ? SoftPalette.amber300 : SoftPalette.orange400)
        : (_isDark ? SoftPalette.emerald300 : SoftPalette.green550);
    final bg = forced
        ? (_isDark ? SoftPalette.orange800.withValues(alpha: 0.55) : SoftPalette.amber100m)
        : (_isDark ? SoftPalette.emerald700.withValues(alpha: 0.45) : SoftPalette.green100m);
    final titleColor = _isDark ? SoftPalette.gray50 : (forced ? SoftPalette.orange750 : SoftPalette.teal700);
    final bodyColor = _isDark ? SoftPalette.slate150 : (forced ? SoftPalette.orange600m : SoftPalette.green550);

    final card = Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: accent, width: 5),
          top: BorderSide(color: accent.withValues(alpha: 0.5)),
          right: BorderSide(color: accent.withValues(alpha: 0.5)),
          bottom: BorderSide(color: accent.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(forced ? Icons.family_restroom_rounded : Icons.verified_user_rounded, color: accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  forced ? 'Registering a CHILD of $_guardianName' : 'Guardian: $_guardianName',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: isMobile ? 13.5 : 15, color: titleColor),
                ),
                if (forced) ...[
                  const SizedBox(height: 4),
                  Text(
                    'This CNIC already belongs to adult patient $_guardianName, so only children can be '
                    'added under it. To register a different adult, use their own CNIC.',
                    style: TextStyle(fontSize: isMobile ? 12 : 13, height: 1.35, color: bodyColor),
                  ),
                ],
                if (_guardianPhone != null && _guardianPhone!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Parent contact $_guardianPhone auto-filled',
                    style: TextStyle(fontSize: isMobile ? 11 : 12, color: bodyColor),
                  ),
                ],
              ],
            ),
          ),
          if (forced)
            TextButton(
              onPressed: () {
                _cnicController.clear();
                _handleCnicChanged('');
                _cnicNode.requestFocus();
              },
              style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
              child: const Text('Change CNIC', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );

    // Short horizontal shake each time the pulse counter changes.
    return TweenAnimationBuilder<double>(
      key: ValueKey(_guardianNoticePulse),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      builder: (context, t, child) => Transform.translate(
        offset: Offset(math.sin(t * math.pi * 6) * (1 - t) * 8, 0),
        child: child,
      ),
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile  = GBreakpoint.isMobile(context);
    final formWidth = isMobile ? double.infinity : 560.0;
    final fontSize  = isMobile ? 14.0 : 16.0;
    final c         = context.comfort;
    final isDark    = Theme.of(context).brightness == Brightness.dark;

    return FocusScope(
      node: _formScopeNode,
      onKey: (node, event) {
        if (event is RawKeyDownEvent) {
          if (_genderNode.hasFocus) {
            String? newValue;
            if (event.logicalKey == LogicalKeyboardKey.keyM) {
              newValue = 'Male';
            } else if (event.logicalKey == LogicalKeyboardKey.keyF) newValue = 'Female';
            else if (event.logicalKey == LogicalKeyboardKey.keyO) newValue = 'Other';
            if (newValue != null) {
              setState(() => _selectedGender = newValue);
              _formScopeNode.requestFocus(_bloodGroupNode);
              return KeyEventResult.handled;
            }
          }
          if (_bloodGroupNode.hasFocus) {
            String? bg;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.keyN || key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
              bg = 'N/A';
            } else if (key == LogicalKeyboardKey.keyA || key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
              bg = 'A+';
            } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
              bg = 'A-';
            } else if (key == LogicalKeyboardKey.keyB || key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
              bg = 'B+';
            } else if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
              bg = 'B-';
            } else if (key == LogicalKeyboardKey.keyO || key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
              bg = 'O+';
            } else if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
              bg = 'O-';
            } else if (key == LogicalKeyboardKey.keyX || key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
              bg = 'AB+';
            } else if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
              bg = 'AB-';
            }
            if (bg != null) {
              setState(() => _selectedBloodGroup = bg);
              _formScopeNode.requestFocus(_visitNode);
              return KeyEventResult.handled;
            }
          }
          if (_visitNode.hasFocus) {
            if (event.logicalKey == LogicalKeyboardKey.keyZ) {
              setState(() => _visitType = 'Zakat');
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.keyN) {
              if (!_isKarachi) {
                setState(() => _visitType = 'Non-Zakat');
              }
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
              setState(() => _visitType = 'GMWF');
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: Colors.transparent,
        child: Center(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Container(
              width: formWidth,
              margin: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 0),
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 4 : 8, vertical: 8),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 1.5,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  c.brand.withValues(alpha: 0.04),
                                  c.brand.withValues(alpha: isDark ? 0.65 : 0.45),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Transform.rotate(
                          angle: 0.785398,
                          child: Container(
                            width: 5.5,
                            height: 5.5,
                            color: c.brand.withValues(alpha: isDark ? 0.75 : 0.55),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Image.asset(
                            'assets/logo/gmwf-1.webp',
                            height: isMobile ? 68 : (widget.isCompactHybrid ? 96 : 120),
                          ),
                        ),
                        Transform.rotate(
                          angle: 0.785398,
                          child: Container(
                            width: 5.5,
                            height: 5.5,
                            color: c.brand.withValues(alpha: isDark ? 0.75 : 0.55),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            height: 1.5,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  c.brand.withValues(alpha: isDark ? 0.65 : 0.45),
                                  c.brand.withValues(alpha: 0.04),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Patient Registration',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: isMobile ? 16 : 18,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Registration type toggle (Stacked bar container)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surfaceSunken,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: c.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.person_add,
                                color: c.brand,
                                size: isMobile ? 18 : 20),
                            SizedBox(width: isMobile ? 6 : 8),
                            Text('Registration Type',
                                style: TextStyle(
                                    color:    c.textSecondary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: isMobile ? 12 : 13.5)),
                          ]),
                          const SizedBox(height: 4),
                          Row(children: [
                            Expanded(child: RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('Adult',
                                  style: TextStyle(
                                      color:    c.textPrimary,
                                      fontSize: fontSize)),
                              value:      false,
                              groupValue: _isChild,
                              activeColor: c.brand,
                              onChanged: (v) {
                                final clean = _cnicController.text.replaceAll(RegExp(r'[^0-9]'), '');
                                if (clean.length == 13) {
                                  final existingAdult = LocalStorageService.getLocalPatientByCnic(clean) ??
                                      LocalStorageService.getLocalPatientByCnic(_formatCnic(clean));
                                  if (existingAdult != null &&
                                      existingAdult['isAdult'] != false &&
                                      !(existingAdult['patientId']?.toString().contains('_child_') ?? false)) {
                                    // The inline notice under the CNIC field explains why; shake it.
                                    setState(() => _guardianNoticePulse++);
                                    return;
                                  }
                                }
                                setState(() {
                                  _isChild = false;
                                  _guardianName = null;
                                  _guardianPhone = null;
                                });
                              },
                            )),
                            Expanded(child: RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('Child',
                                  style: TextStyle(
                                      color:    c.textPrimary,
                                      fontSize: fontSize)),
                              value:      true,
                              groupValue: _isChild,
                              activeColor: c.brand,
                              onChanged: (v) {
                                setState(() => _isChild = v!);
                                _handleCnicChanged();
                              },
                            )),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    _buildTextField(
                      controller: _cnicController,
                      label: _isChild
                          ? 'Guardian CNIC (XXXXX-XXXXXXX-X)'
                          : 'CNIC (XXXXX-XXXXXXX-X)',
                      icon:      Icons.credit_card,
                      focusNode: _cnicNode,
                      key:       _cnicKey,
                      maxLength: 15,
                      inputFormatters: [CNICInputFormatter()],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Enter ${_isChild ? 'Guardian ' : ''}CNIC';
                        }
                        final clean = v.replaceAll(RegExp(r'[^0-9]'), '');
                        if (clean.length != 13) {
                          return 'CNIC must be 13 digits (XXXXX-XXXXXXX-X)';
                        }
                        return null;
                      },
                    ),

                    if (_isChild && _guardianName != null && _guardianName!.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _buildGuardianNotice(isMobile),
                    ],
                    const SizedBox(height: 12),

                    _buildTextField(
                      controller: _phoneController,
                      label:     'Phone Number (optional)',
                      icon:      Icons.phone,
                      focusNode: _phoneNode,
                      key:       _phoneKey,
                      maxLength: 11,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                      validator: (v) {
                        if (v != null && v.isNotEmpty && v.length != 11) {
                          return 'Phone must be 11 digits';
                        }
                        return null;
                      },
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),

                    _buildTextField(
                      controller: _nameController,
                      label:     'Full Name${_isChild ? ' (Child)' : ''}',
                      icon:      Icons.person,
                      focusNode: _nameNode,
                      key:       _nameKey,
                      validator: (v) =>
                          v?.isEmpty ?? true ? 'Enter name' : null,
                    ),
                    const SizedBox(height: 12),

                    // Age & DOB row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: isMobile ? 110 : 135,
                          child: TextFormField(
                            key: _ageKey,
                            controller: _ageController,
                            focusNode: _ageNode,
                            cursorColor: c.brand,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: fontSize - 2,
                              fontWeight: FontWeight.bold,
                            ),
                            decoration: _inputDecoration(
                              'Age (Yrs)',
                              Icons.hourglass_bottom_rounded,
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            onChanged: _onAgeChanged,
                            textInputAction: TextInputAction.next,
                            onFieldSubmitted: (_) => _formScopeNode.requestFocus(_dobNode),
                            validator: (v) {
                              final ageVal = int.tryParse(v?.trim() ?? '');
                              final dobVal = _dobController.text.trim();
                              if ((ageVal == null || ageVal <= 0) && dobVal.isEmpty) {
                                return 'Enter age';
                              }
                              if (ageVal != null && ageVal > 130) {
                                return 'Max 130';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            key: _dobKey,
                            controller: _dobController,
                            focusNode: _dobNode,
                            cursorColor: c.brand,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: fontSize - 2,
                            ),
                            decoration: _inputDecoration(
                              '${_isChild ? 'Child ' : ''}Date of Birth (dd-MM-yyyy)',
                              Icons.cake,
                              suffixIcon: IconButton(
                                tooltip: 'Pick Date of Birth from Calendar',
                                icon: Icon(
                                  Icons.calendar_month_rounded,
                                  color: c.brand,
                                  size: 22,
                                ),
                                onPressed: _pickDobDate,
                              ),
                            ),
                            autocorrect: false,
                            enableSuggestions: false,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                              LengthLimitingTextInputFormatter(10),
                              _DobFormatter(),
                            ],
                            keyboardType: TextInputType.datetime,
                            validator: (v) {
                              final ageVal = int.tryParse(_ageController.text.trim()) ?? _calculatedAge;
                              if ((v == null || v.trim().isEmpty) && ageVal > 0) {
                                return null;
                              }
                              if (v == null || v.trim().isEmpty) {
                                return 'Enter DOB or Age';
                              }
                              if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(v.trim())) {
                                return 'Use dd-MM-yyyy';
                              }
                              final p = v.trim().split('-');
                              final day = int.tryParse(p[0]) ?? 0;
                              final month = int.tryParse(p[1]) ?? 0;
                              final year = int.tryParse(p[2]) ?? 0;
                              if (day < 1 || day > 31) return 'Day: 01-31';
                              if (month < 1 || month > 12) return 'Month: 01-12';
                              if (year < 1900 || year > DateTime.now().year) {
                                return 'Year: 1900-${DateTime.now().year}';
                              }
                              try {
                                final date = DateTime(year, month, day);
                                if (date.day != day || date.month != month) {
                                  return 'Invalid date';
                                }
                                if (date.isAfter(DateTime.now())) {
                                  return 'DOB cannot be in future';
                                }
                                return null;
                              } catch (_) {
                                return 'Invalid date';
                              }
                            },
                            onChanged: _calculateAge,
                            textInputAction: TextInputAction.next,
                            onFieldSubmitted: (_) => _formScopeNode.requestFocus(_genderNode),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    _buildDropdown(
                      focusNode: _genderNode,
                      value:     _selectedGender,
                      label:     '${_isChild ? 'Child ' : ''}Gender',
                      icon:      Icons.person_outline,
                      key:       _genderKey,
                      items:     const ['Male', 'Female', 'Other'],
                      onChanged: (val) {
                        setState(() => _selectedGender = val);
                        _formScopeNode.requestFocus(_bloodGroupNode);
                      },
                    ),
                    const SizedBox(height: 12),

                    _buildDropdown(
                      focusNode: _bloodGroupNode,
                      value:     _selectedBloodGroup,
                      label:     '${_isChild ? 'Child ' : ''}Blood Group',
                      icon:      Icons.bloodtype_outlined,
                      key:       _bloodGroupKey,
                      items: const [
                        'N/A', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'
                      ],
                      validator: (val) => null,
                      onChanged: (val) {
                        setState(() => _selectedBloodGroup = val);
                        _formScopeNode.requestFocus(_visitNode);
                      },
                    ),
                    const SizedBox(height: 12),

                    // Visit type (Stacked bar container)
                    Focus(
                      focusNode: _visitNode,
                      child: Container(
                        key: _visitKey,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: c.surfaceSunken,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.mosque,
                                  color: c.brand,
                                  size: isMobile ? 18 : 20),
                              SizedBox(width: isMobile ? 6 : 8),
                              Text('Visit Type',
                                  style: TextStyle(
                                      color:    c.textSecondary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: isMobile ? 12 : 13.5)),
                            ]),
                            const SizedBox(height: 4),
                            Row(children: [
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(_isKarachi ? '${BranchLabels.karachiZakatLabel} Token' : 'Zakat',
                                    style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: fontSize)),
                                value:       'Zakat',
                                groupValue:  _visitType,
                                activeColor: c.brand,
                                onChanged:   (v) => setState(() => _visitType = v!),
                              )),
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(_isKarachi ? '${BranchLabels.karachiNonZakatLabel} (Disabled)' : 'Non-Zakat',
                                    style: TextStyle(
                                        color: _isKarachi ? c.textMuted : c.textPrimary,
                                        fontSize: fontSize)),
                                value:       'Non-Zakat',
                                groupValue:  _visitType,
                                activeColor: c.brand,
                                onChanged:   _isKarachi ? null : (v) => setState(() => _visitType = v!),
                              )),
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text('GMWF',
                                    style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: fontSize)),
                                value:       'GMWF',
                                groupValue:  _visitType,
                                activeColor: c.brand,
                                onChanged:   (v) => setState(() => _visitType = v!),
                              )),
                            ]),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    Focus(
                      focusNode: _registerButtonNode,
                      child: SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: _isSaving ? null : _savePatient,
                          icon: _isSaving
                              ? SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      color: c.textMuted, strokeWidth: 2))
                              : const Icon(Icons.person_add_alt_1_rounded, size: 19),
                          label: Text(
                            _isSaving ? 'Saving...' : 'Register Patient',
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.brand,
                            disabledBackgroundColor: c.surfaceSunken,
                            foregroundColor: c.onBrand,
                            disabledForegroundColor: c.textMuted,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required FocusNode focusNode,
    GlobalKey? key,
    String? Function(String?)? validator,
    List<TextInputFormatter>? inputFormatters,
    int? maxLength,
    TextInputType? keyboardType,
  }) {
    final isMobile = GBreakpoint.isMobile(context);
    final c = context.comfort;
    return TextFormField(
      key:            key,
      controller:     controller,
      focusNode:      focusNode,
      cursorColor:    c.brand,
      style: TextStyle(color: c.textPrimary, fontSize: isMobile ? 14 : 15),
      decoration:     _inputDecoration(label, icon),
      validator:      validator,
      inputFormatters: inputFormatters,
      maxLength:      maxLength,
      buildCounter:   (_, {required currentLength, required isFocused, maxLength}) =>
          null,
      keyboardType:   keyboardType,
      autocorrect:    false,
      enableSuggestions: false,
      textInputAction: TextInputAction.next,
      onFieldSubmitted: (_) {
        final idx = activeFocusNodes.indexOf(focusNode);
        if (idx < activeFocusNodes.length - 1) {
          _formScopeNode.requestFocus(activeFocusNodes[idx + 1]);
        }
      },
    );
  }

  Widget _buildDropdown({
    required FocusNode focusNode,
    required String? value,
    required String label,
    required IconData icon,
    required GlobalKey? key,
    required List<String> items,
    required void Function(String?) onChanged,
    String? Function(String?)? validator,
  }) {
    final isMobile = GBreakpoint.isMobile(context);
    final c = context.comfort;
    return DropdownButtonFormField2<String>(
      key:        key,
      focusNode:  focusNode,
      isExpanded: true,
      value:      value,
      dropdownStyleData: DropdownStyleData(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
      ),
      items: items
          .map((e) => DropdownMenuItem<String>(
              value: e,
              child: Text(e,
                  style: TextStyle(color: c.textPrimary))))
          .toList(),
      onChanged:  onChanged,
      decoration: _inputDecoration(label, icon),
      validator:  validator ?? ((val) => val == null ? 'Select $label' : null),
      style: TextStyle(color: c.textPrimary, fontSize: isMobile ? 14 : 15),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, {Widget? suffixIcon}) {
    final c = context.comfort;
    return InputDecoration(
      labelText:  label,
      labelStyle: TextStyle(color: c.textSecondary),
      prefixIcon: Icon(icon, color: c.brand),
      suffixIcon: suffixIcon,
      filled:     true,
      fillColor:  c.surfaceSunken,
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.borderStrong)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.brand, width: 1.8)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }
}

// ── Formatters ────────────────────────────────────────────────────────────────

class CNICInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final buffer = StringBuffer();
    final clean = digits.length > 13 ? digits.substring(0, 13) : digits;
    for (int i = 0; i < clean.length; i++) {
      buffer.write(clean[i]);
      if (i == 4 || i == 11) {
        if (i != clean.length - 1) buffer.write('-');
      }
    }
    return TextEditingValue(
        text:      buffer.toString(),
        selection: TextSelection.collapsed(offset: buffer.length));
  }
}

class _DobFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue old, TextEditingValue newVal) {
    var t = newVal.text.replaceAll(RegExp(r'\D'), '');
    if (t.length > 8) t = t.substring(0, 8);

    final b = StringBuffer();

    if (t.isNotEmpty) {
      var day = t.substring(0, t.length.clamp(0, 2));
      if (day.length == 2) {
        final d = int.tryParse(day) ?? 0;
        if (d > 31 || d == 0) day = day[0];
      }
      b.write(day);
    }

    if (t.length > 2) {
      b.write('-');
      var month = t.substring(2, t.length.clamp(2, 4));
      if (month.length == 2) {
        final m = int.tryParse(month) ?? 0;
        if (m > 12 || m == 0) month = month[0];
      }
      b.write(month);
    }

    if (t.length > 4) {
      b.write('-');
      b.write(t.substring(4));
    }

    final formatted = b.toString();
    return TextEditingValue(
        text:      formatted,
        selection: TextSelection.collapsed(offset: formatted.length));
  }
}
