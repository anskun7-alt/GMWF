// lib/pages/dispensary/receptionist/patient_register.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'dart:async';
import 'package:gmwf/services/firestore_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/utils/formatters.dart';

class PatientRegisterPage extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String? initialCnic;
  final void Function(String patientId)? onPatientRegistered;

  const PatientRegisterPage({
    super.key,
    required this.branchId,
    required this.receptionistId,
    this.initialCnic,
    this.onPatientRegistered,
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

  String? _selectedGender;
  String? _selectedBloodGroup;
  String  _visitType     = 'Zakat';
  int     _calculatedAge = 0;
  bool    _isSaving      = false;
  bool    _isChild       = false;

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  final _nameNode        = FocusNode();
  final _cnicNode        = FocusNode();
  final _phoneNode       = FocusNode();
  final _dobNode         = FocusNode();
  final _genderNode      = FocusNode();
  final _bloodGroupNode  = FocusNode();
  final _visitNode       = FocusNode();
  final _registerButtonNode = FocusNode();

  final _nameKey       = GlobalKey();
  final _cnicKey       = GlobalKey();
  final _phoneKey      = GlobalKey();
  final _dobKey        = GlobalKey();
  final _genderKey     = GlobalKey();
  final _bloodGroupKey = GlobalKey();
  final _visitKey      = GlobalKey();

  final _scrollController = ScrollController();

  List<FocusNode> get activeFocusNodes {
    return [
      _cnicNode,
      _phoneNode,
      _nameNode,
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
    if (_isKarachi && _visitType == 'Non-Zakat') {
      _visitType = 'Zakat';
    }
    _addFocusListeners();
    _cnicController.addListener(() {
      _checkIfAdultExistsForCnic(_cnicController.text);
    });
    if (widget.initialCnic != null && widget.initialCnic!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        prefillCnic(widget.initialCnic!);
      });
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
    _dobNode.addListener(()        { if (_dobNode.hasFocus)        scrollTo(_dobKey.currentContext); });
    _genderNode.addListener(()     { if (_genderNode.hasFocus)     scrollTo(_genderKey.currentContext); });
    _bloodGroupNode.addListener(() { if (_bloodGroupNode.hasFocus) scrollTo(_bloodGroupKey.currentContext); });
    _visitNode.addListener(()      { if (_visitNode.hasFocus)      scrollTo(_visitKey.currentContext); });
  }

  @override
  void dispose() {
    _formScopeNode.dispose();
    _scrollController.dispose();
    for (var c in [_nameController, _cnicController, _phoneController, _dobController]) {
      c.dispose();
    }
    for (var n in [
      _nameNode, _cnicNode, _phoneNode, _dobNode,
      _genderNode, _bloodGroupNode, _visitNode, _registerButtonNode,
    ]) {
      n.dispose();
    }
    super.dispose();
  }

  void prefillCnic(String cnic) {
    setState(() => _cnicController.text = _formatCnic(cnic));
    _nameNode.requestFocus();
  }

  String _formatCnic(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 5)  return digits;
    if (digits.length <= 12) return '${digits.substring(0, 5)}-${digits.substring(5)}';
    return '${digits.substring(0, 5)}-${digits.substring(5, 12)}-${digits.substring(12)}';
  }

  void _calculateAge(String dob) {
    if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(dob)) {
      setState(() => _calculatedAge = 0);
      return;
    }
    final birth = parseDobDateTime(dob);
    if (birth == null) {
      setState(() => _calculatedAge = 0);
      return;
    }
    final today = DateTime.now();
    int age     = today.year - birth.year;
    if (today.month < birth.month ||
        (today.month == birth.month && today.day < birth.day)) {
      age--;
    }
    setState(() => _calculatedAge = age);
  }

  Future<void> _savePatient() async {
    if (!_formKey.currentState!.validate()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Registration'),
        content: const Text('Are you sure you want to register this patient?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true) return;

    final formattedCnic = _cnicController.text.trim();

    setState(() => _isSaving = true);

    try {
      final dob = parseDobDateTime(_dobController.text);
      if (dob == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter a valid date of birth')),
          );
        }
        return;
      }

      if (_isChild && _calculatedAge >= 20) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Patient is $_calculatedAge years old. In this age, the person is considered an adult (child limit is under 20). Please bring/register with their own CNIC.'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final isMinor = _calculatedAge > 0 && _calculatedAge < 20;
      final effectiveIsChild = _isChild || isMinor;

      if (effectiveIsChild) {
        if (formattedCnic.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Guardian CNIC is required for child registration!'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }

        // Limitation: Do not allow registering a child if an adult is not already registered on the CNIC
        final existingPatients = LocalStorageService.searchPatientsByCnicOrGuardian(
          formattedCnic,
          branchId: widget.branchId,
        );

        // An adult record must be POSITIVELY identified — never inferred from
        // the absence of guardianCnic, since that's exactly the ambiguous
        // state Bug 3's legacy/corrupted records are in.
        final adultExists = existingPatients.any((p) {
          final pid = (p['patientId'] ?? p['id'] ?? '').toString();
          final isFlaggedAdult = p['isAdult'] == true;
          final looksLikeChildRecord = pid.contains('_child_');
          return isFlaggedAdult && !looksLikeChildRecord;
        });

        if (!adultExists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Cannot register child: No adult (guardian) is registered under this CNIC. Please register the adult first.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }

      final patientMap = <String, dynamic>{
        'branchId':    widget.branchId,
        'name':        _nameController.text.trim(),
        'isAdult':     !effectiveIsChild,
        'guardianCnic': effectiveIsChild ? formattedCnic : null,
        'cnic':        effectiveIsChild ? null : formattedCnic,
        'dob':         dob,
        'gender':      _selectedGender,
        'bloodGroup':  _selectedBloodGroup ?? 'N/A',
        'status':      (_isKarachi && _visitType == 'Non-Zakat') ? 'Zakat' : _visitType,
        'phone':       _phoneController.text.trim().isNotEmpty
            ? _phoneController.text.trim()
            : null,
        'age':         _calculatedAge,
        'createdBy':   widget.receptionistId,
        'createdAt':   DateTime.now().toIso8601String(),
      };

      final patientId = LocalStorageService.getPatientKey(patientMap);
      patientMap['patientId'] = patientId;

      // Check for duplicate in local Hive before doing anything
      if (Hive.box(LocalStorageService.patientsBox).containsKey(patientId)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Patient with this identifier already exists!"),
            backgroundColor: Colors.orange,
          ));
        }
        return;
      }

      // STEP 1 — Hive first (offline-safe, instant).
      await LocalStorageService.saveLocalPatient(patientMap, recordAudit: true);
      debugPrint('[PatientRegister] ✅ Hive write: $patientId');

      // STEP 2 — LAN broadcast
      try {
        RealtimeManager().sendMessage({
          ...RealtimeEvents.payload(
            type: RealtimeEvents.savePatient,
            branchId: widget.branchId,
            data: patientMap,
          ),
          'patientId': patientId,
        });
      } catch (e) {
        debugPrint('[PatientRegister] LAN broadcast error: $e');
      }

      // STEP 3 — Durable background queue & unawaited upload
      LocalStorageService.enqueueSync({
        'type': 'save_patient',
        'branchId': widget.branchId,
        'patientId': patientId,
        'data': patientMap,
        'createdAt': DateTime.now().toIso8601String(),
      });

      unawaited(
        FirestoreService().savePatient(
          branchId:    widget.branchId,
          patientId:   patientId,
          patientData: patientMap,
        ).timeout(const Duration(seconds: 4), onTimeout: () {}).catchError((e) {
          debugPrint('[PatientRegister] Background Firestore upload notice: $e');
        }),
      );

      final message = _isChild
          ? 'Child patient registered successfully!'
          : 'Adult patient registered successfully!';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), backgroundColor: const Color(0xFF00695C)));
      }

      final searchKey = _isChild
          ? (_cnicController.text.trim().isNotEmpty ? _cnicController.text.trim() : patientId)
          : (_cnicController.text.trim().isNotEmpty ? _cnicController.text.trim() : patientId);
      widget.onPatientRegistered?.call(searchKey);

      _nameController.clear();
      _cnicController.clear();
      _phoneController.clear();
      _dobController.clear();
      setState(() {
        _selectedGender     = null;
        _selectedBloodGroup = null;
        _visitType          = 'Zakat';
        _isChild            = false;
        _calculatedAge      = 0;
      });
    } catch (e, stack) {
      debugPrint('Patient registration failed: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  void _checkIfAdultExistsForCnic(String cnic) {
    final clean = cnic.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length < 13) return;
    final formatted = _formatCnic(clean);

    try {
      final list = LocalStorageService.searchPatientsByCnicOrGuardian(
          formatted, branchId: widget.branchId);
      final hasAdult = list.any((p) {
        final pid = (p['patientId'] ?? p['id'] ?? '').toString();
        final isFlaggedAdult = p['isAdult'] == true;
        final looksLikeChildRecord = pid.contains('_child_');
        return isFlaggedAdult && !looksLikeChildRecord;
      });
      if (hasAdult && !_isChild) {
        setState(() {
          _isChild = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('ℹ️ Adult patient already exists on this CNIC. Switched to Child registration.'),
            backgroundColor: Color(0xFF00695C),
            duration: Duration(seconds: 2),
          ));
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isMobile  = MediaQuery.of(context).size.width < 600;
    final formWidth = isMobile ? double.infinity : 480.0;
    final fontSize  = isMobile ? 14.0 : 16.0;

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
              margin: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 0),
              padding: EdgeInsets.all(isMobile ? 16 : 20),
              decoration: BoxDecoration(
                color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _isDark ? const Color(0xFF334155) : const Color(0xFF80CBC4), width: 1.5),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset('assets/logo/gmwf-1.webp',
                        height: isMobile ? 80 : 100),
                    const SizedBox(height: 16),
                    Text(
                      'Patient Registration',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize:   isMobile ? 20 : 24,
                          fontWeight: FontWeight.bold,
                          color:      _isDark ? Colors.white : const Color(0xFF004D40)),
                    ),
                    const SizedBox(height: 24),

                    // Registration type toggle (Stacked bar container)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: _isDark ? const Color(0xFF0F172A) : const Color(0xFFE0F2F1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _isDark ? const Color(0xFF334155) : const Color(0xFF80CBC4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.person_add,
                                color: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF004D40),
                                size: isMobile ? 18 : 20),
                            SizedBox(width: isMobile ? 4 : 8),
                            Text('Registration Type',
                                style: TextStyle(
                                    color:    _isDark ? const Color(0xFF94A3B8) : const Color(0xFF00796B),
                                    fontSize: isMobile ? 12 : 14)),
                          ]),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(child: RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('Adult',
                                  style: TextStyle(
                                      color:    _isDark ? Colors.white : const Color(0xFF004D40),
                                      fontSize: fontSize)),
                              value:      false,
                              groupValue: _isChild,
                              activeColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C),
                              onChanged: (v) => setState(() => _isChild = v!),
                            )),
                            Expanded(child: RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('Child',
                                  style: TextStyle(
                                      color:    _isDark ? Colors.white : const Color(0xFF004D40),
                                      fontSize: fontSize)),
                              value:      true,
                              groupValue: _isChild,
                              activeColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C),
                              onChanged: (v) {
                                setState(() {
                                  if (!_isChild && v == true) {
                                    _nameController.clear();
                                    _dobController.clear();
                                  }
                                  _isChild = v!;
                                });
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
                        final r = RegExp(r'^\d{5}-\d{7}-\d{1}$');
                        if (v?.isEmpty ?? true) {
                          return 'Enter ${_isChild ? 'Guardian ' : ''}CNIC';
                        }
                        if (!r.hasMatch(v!)) return 'Format: 12345-1234567-1';
                        return null;
                      },
                    ),
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

                    // DOB field
                    TextFormField(
                      key:        _dobKey,
                      controller: _dobController,
                      focusNode:  _dobNode,
                      cursorColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF004D40),
                      style: TextStyle(
                          color: _isDark ? Colors.white : const Color(0xFF004D40), fontSize: fontSize - 2),
                      decoration: _inputDecoration(
                          '${_isChild ? 'Child ' : ''}Date of Birth (dd-MM-yyyy)',
                          Icons.cake),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                        LengthLimitingTextInputFormatter(10),
                        _DobFormatter(),
                      ],
                      keyboardType: TextInputType.datetime,
                      validator: (v) {
                        if (v!.isEmpty) return 'Enter DOB';
                        if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(v)) {
                          return 'Use dd-MM-yyyy';
                        }
                        final p   = v.split('-');
                        final day   = int.tryParse(p[0]) ?? 0;
                        final month = int.tryParse(p[1]) ?? 0;
                        final year  = int.tryParse(p[2]) ?? 0;
                        if (day < 1 || day > 31)   return 'Day must be 01-31';
                        if (month < 1 || month > 12) return 'Month must be 01-12';
                        if (year < 1900 || year > DateTime.now().year + 1) {
                          return 'Year must be between 1900 and ${DateTime.now().year + 1}';
                        }
                        try {
                          final date = DateTime(year, month, day);
                          if (date.day != day || date.month != month) {
                            return 'Invalid date (e.g., Feb 30 does not exist)';
                          }
                          _calculateAge(v);
                          return null;
                        } catch (_) {
                          return 'Invalid date';
                        }
                      },
                      onChanged: _calculateAge,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) =>
                          _formScopeNode.requestFocus(_genderNode),
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
                          color: _isDark ? const Color(0xFF0F172A) : const Color(0xFFE0F2F1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _isDark ? const Color(0xFF334155) : const Color(0xFF80CBC4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.mosque,
                                  color: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF004D40),
                                  size: isMobile ? 18 : 20),
                              SizedBox(width: isMobile ? 4 : 8),
                              Text('Visit Type',
                                  style: TextStyle(
                                      color:    _isDark ? const Color(0xFF94A3B8) : const Color(0xFF00796B),
                                      fontSize: isMobile ? 12 : 14)),
                            ]),
                            const SizedBox(height: 8),
                            Row(children: [
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(_isKarachi ? 'PKR 20 Token' : 'Zakat',
                                    style: TextStyle(
                                        color: _isDark ? Colors.white : const Color(0xFF004D40),
                                        fontSize: fontSize)),
                                value:       'Zakat',
                                groupValue:  _visitType,
                                activeColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C),
                                onChanged:   (v) => setState(() => _visitType = v!),
                              )),
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(_isKarachi ? 'PKR 100 (Disabled)' : 'Non-Zakat',
                                    style: TextStyle(
                                        color: _isKarachi ? Colors.grey : (_isDark ? Colors.white : const Color(0xFF004D40)),
                                        fontSize: fontSize)),
                                value:       'Non-Zakat',
                                groupValue:  _visitType,
                                activeColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C),
                                onChanged:   _isKarachi ? null : (v) => setState(() => _visitType = v!),
                              )),
                              Expanded(child: RadioListTile<String>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text('GMWF',
                                    style: TextStyle(
                                        color: _isDark ? Colors.white : const Color(0xFF004D40),
                                        fontSize: fontSize)),
                                value:       'GMWF',
                                groupValue:  _visitType,
                                activeColor: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C),
                                onChanged:   (v) => setState(() => _visitType = v!),
                              )),
                            ]),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    Focus(
                      focusNode: _registerButtonNode,
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          gradient: _isSaving
                              ? null
                              : const LinearGradient(
                                  colors: [Color(0xFF00A86B), Color(0xFF00875A)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                          color: _isSaving
                              ? (_isDark ? const Color(0xFF334155) : Colors.grey[400])
                              : null,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: _isSaving
                              ? null
                              : [
                                  BoxShadow(
                                    color: const Color(0xFF00A86B).withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _isSaving ? null : _savePatient,
                          icon: _isSaving
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Icon(Icons.person_add_alt_1_rounded, size: 20),
                          label: Text(
                            _isSaving ? 'Saving...' : 'Register Patient',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
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
    final isMobile = MediaQuery.of(context).size.width < 600;
    final isDark = _isDark;
    return TextFormField(
      key:            key,
      controller:     controller,
      focusNode:      focusNode,
      cursorColor:    isDark ? const Color(0xFF38BDF8) : const Color(0xFF004D40),
      style: TextStyle(color: isDark ? Colors.white : const Color(0xFF004D40), fontSize: isMobile ? 14 : 16),
      decoration:     _inputDecoration(label, icon),
      validator:      validator,
      inputFormatters: inputFormatters,
      maxLength:      maxLength,
      buildCounter:   (_, {required currentLength, required isFocused, maxLength}) =>
          null,
      keyboardType:   keyboardType,
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
  }) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final isDark = _isDark;
    return DropdownButtonFormField2<String>(
      key:        key,
      focusNode:  focusNode,
      isExpanded: true,
      value:      value,
      dropdownStyleData: DropdownStyleData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      items: items
          .map((e) => DropdownMenuItem<String>(
              value: e,
              child: Text(e,
                  style: TextStyle(color: isDark ? Colors.white : const Color(0xFF004D40)))))
          .toList(),
      onChanged:  onChanged,
      decoration: _inputDecoration(label, icon),
      validator:  (val) => val == null ? 'Select $label' : null,
      style: TextStyle(color: isDark ? Colors.white : const Color(0xFF004D40), fontSize: isMobile ? 14 : 16),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    final isDark = _isDark;
    return InputDecoration(
      labelText:  label,
      labelStyle: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF00695C)),
      prefixIcon: Icon(icon, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF004D40)),
      filled:     true,
      fillColor:  isDark ? const Color(0xFF334155) : const Color(0xFFE0F2F1),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: isDark ? const Color(0xFF475569) : const Color(0xFF00695C))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF00695C), width: 1.8)),
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
    for (int i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if (i == 4 || i == 11) {
        if (i != digits.length - 1) buffer.write('-');
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
