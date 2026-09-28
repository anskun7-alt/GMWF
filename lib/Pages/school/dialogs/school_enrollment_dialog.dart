// lib/pages/school/dialogs/school_enrollment_dialog.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../widgets/media_upload_tile.dart';
import '../../../services/zkteco_network_service.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/image_upload_service.dart';
import '../../../utils/formatters.dart';
import '../../madrassa/utils/madrassa_local_storage.dart';
import '../models/school_student.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_admission_pdf_service.dart';
import '../constants/school_constants.dart';
import '../theme/school_theme.dart';
import '../../../widgets/app_feedback.dart';

class SchoolEnrollmentDialog extends StatefulWidget {
  final String branchId;
  final SchoolStudent? studentToEdit;

  const SchoolEnrollmentDialog({
    super.key,
    required this.branchId,
    this.studentToEdit,
  });

  @override
  State<SchoolEnrollmentDialog> createState() => _SchoolEnrollmentDialogState();
}

class _SchoolEnrollmentDialogState extends State<SchoolEnrollmentDialog> {
  final _formKey = GlobalKey<FormState>();

  // Text Controllers matching the physical Admission Form
  late TextEditingController _rollNoCtrl;
  late TextEditingController _nameCtrl;
  late TextEditingController _guardianNameCtrl;
  late TextEditingController _bformNoCtrl;
  late TextEditingController _guardianCnicCtrl;
  late TextEditingController _fatherProfessionCtrl;
  late TextEditingController _guardianPhoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _previousSchoolCtrl;
  late TextEditingController _biometricPinCtrl;

  // Dropdowns & Dates
  String _selectedGrade = 'Pre-9th';
  String _selectedSection = 'A';
  String _selectedAcademicGroup = 'General';
  String _selectedGender = 'Male';
  String _status = 'active';
  DateTime _admissionDate = DateTime.now();
  DateTime? _dob;
  bool _parentSignatureConfirmed = true;

  // Media & Documents
  String? _photoUrl;
  String? _guardianCnicUrl;
  String? _bformUrl;
  List<Map<String, String>> _additionalDocuments = [];

  // Madrassa Transfer Tracking
  String? _transferredMadrassaStudentId;
  String? _transferredMadrassaInfo;

  bool _isSaving = false;

  final List<String> _grades = SchoolConstants.grades;
  final List<String> _sections = SchoolConstants.sections;

  @override
  void initState() {
    super.initState();
    final st = widget.studentToEdit;

    _rollNoCtrl = TextEditingController(text: st?.rollNo ?? '');
    _nameCtrl = TextEditingController(text: st?.name ?? '');
    _guardianNameCtrl = TextEditingController(text: st?.guardianName ?? '');
    _bformNoCtrl = TextEditingController(text: st?.bformNo ?? '');
    _guardianCnicCtrl = TextEditingController(text: st?.guardianCnic ?? '');
    _fatherProfessionCtrl = TextEditingController(text: st?.fatherProfession ?? '');
    _guardianPhoneCtrl = TextEditingController(text: _formatPhoneDigits(st?.guardianPhone ?? ''));
    _addressCtrl = TextEditingController(text: st?.address ?? '');
    _previousSchoolCtrl = TextEditingController(text: st?.previousSchool ?? '');

    final initialPin = st != null
        ? (ZkTecoNetworkService.getCredentialByEntityId(st.id)?.biometricPin ?? st.biometricPin)
        : '';
    _biometricPinCtrl = TextEditingController(text: initialPin);

    if (st != null) {
      _selectedGrade = _grades.contains(st.grade) ? st.grade : _grades.first;
      _selectedSection = _sections.contains(st.section) ? st.section : _sections.first;
      final availGroups = SchoolConstants.getAcademicGroupsForGrade(_selectedGrade);
      _selectedAcademicGroup = availGroups.contains(st.academicGroup) ? st.academicGroup : availGroups.first;
      _selectedGender = st.gender;
      _status = st.status;
      _photoUrl = st.photoUrl;
      _guardianCnicUrl = st.guardianCnicUrl;
      _bformUrl = st.bformUrl;
      _additionalDocuments = st.additionalDocuments.map((d) => Map<String, String>.from(d)).toList();

      if (st.admissionDate.isNotEmpty) {
        _admissionDate = DateTime.tryParse(st.admissionDate) ?? DateTime.now();
      }
      if (st.dob.isNotEmpty) {
        _dob = DateTime.tryParse(st.dob);
      }
    } else {
      _selectedGrade = '1';
      _selectedAcademicGroup = 'General';
    }
  }

  String _formatPhoneDigits(String raw) {
    String digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 11) {
      digits = digits.substring(0, 11);
    }
    return digits;
  }

  @override
  void dispose() {
    _rollNoCtrl.dispose();
    _nameCtrl.dispose();
    _guardianNameCtrl.dispose();
    _bformNoCtrl.dispose();
    _guardianCnicCtrl.dispose();
    _fatherProfessionCtrl.dispose();
    _guardianPhoneCtrl.dispose();
    _addressCtrl.dispose();
    _previousSchoolCtrl.dispose();
    _biometricPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _openMadrassaTransferPicker() async {
    List<Map<String, dynamic>> madrassaStudents = [];
    try {
      madrassaStudents = MadrassaLocalStorage.getAllStudentsCached(widget.branchId);
      if (madrassaStudents.isEmpty) {
        if (Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
          final box = Hive.box(LocalStorageService.madrassaStudentsBox);
          for (final key in box.keys) {
            final val = box.get(key);
            if (val is Map) {
              final map = Map<String, dynamic>.from(val);
              map['id'] = map['id'] ?? key.toString().split('__std__').last;
              madrassaStudents.add(map);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SchoolEnrollmentDialog] Fetch madrassa students error: $e');
    }

    if (madrassaStudents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No Madrassa students found in local storage to transfer.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        String filter = '';
        return StatefulBuilder(
          builder: (context, setPickerState) {
            final filtered = madrassaStudents.where((s) {
              final q = filter.trim().toLowerCase();
              if (q.isEmpty) return true;
              final name = (s['name'] ?? '').toString().toLowerCase();
              final guardian = (s['guardianName'] ?? s['fatherName'] ?? '').toString().toLowerCase();
              final cnic = (s['studentCnic'] ?? s['bFormNo'] ?? s['bformNo'] ?? '').toString().toLowerCase();
              final roll = (s['rollNo'] ?? '').toString().toLowerCase();
              final pin = (s['biometricPin'] ?? '').toString();
              return name.contains(q) || guardian.contains(q) || cnic.contains(q) || roll.contains(q) || pin.contains(q);
            }).toList();

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.sync_alt_rounded, color: SchoolTheme.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Transfer / Import Madrassa Student\nمدرسہ کے طالب علم سے ٹرانسفر',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 580,
                height: 440,
                child: Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search by Student Name, Father, CNIC or PIN...',
                        prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF0F766E)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        isDense: true,
                      ),
                      onChanged: (v) => setPickerState(() => filter = v),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching Madrassa students found', style: TextStyle(color: Colors.grey)))
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (context, idx) {
                                final std = filtered[idx];
                                final stdId = std['id']?.toString() ?? '';
                                final cred = ZkTecoNetworkService.getCredentialByEntityId(stdId);
                                final pin = cred?.biometricPin ?? std['biometricPin']?.toString() ?? '';
                                final photo = std['photoUrl']?.toString() ?? '';
                                final photoBytes = ImageUploadService.decodeBase64ToBytes(photo);

                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
                                    backgroundImage: photoBytes != null && photoBytes.isNotEmpty ? MemoryImage(photoBytes) : null,
                                    child: photoBytes == null || photoBytes.isEmpty
                                        ? const Icon(Icons.person_rounded, color: Color(0xFF0F766E))
                                        : null,
                                  ),
                                  title: Row(
                                    children: [
                                      Text(std['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold)),
                                      if (pin.isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: SchoolTheme.primary.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text('PIN: $pin', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F766E))),
                                        ),
                                      ],
                                    ],
                                  ),
                                  subtitle: Text(
                                    'Father: ${std['guardianName'] ?? std['fatherName'] ?? '—'} • CNIC: ${std['studentCnic'] ?? std['bFormNo'] ?? '—'}\nClass: ${std['classLevel'] ?? std['hifzStatus'] ?? 'Madrassa'}',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                  ),
                                  trailing: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: SchoolTheme.primary,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    ),
                                    onPressed: () => Navigator.pop(ctx, std),
                                    child: const Text('Transfer Data'),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
              ],
            );
          },
        );
      },
    );

    if (selected != null) {
      final stdId = selected['id']?.toString() ?? '';
      final cred = ZkTecoNetworkService.getCredentialByEntityId(stdId);
      final pin = cred?.biometricPin ?? selected['biometricPin']?.toString() ?? '';

      setState(() {
        _transferredMadrassaStudentId = stdId;
        _transferredMadrassaInfo = '${selected['name']} (Madrassa Student)';
        _nameCtrl.text = selected['name'] ?? '';
        _guardianNameCtrl.text = selected['guardianName'] ?? selected['fatherName'] ?? '';
        _bformNoCtrl.text = selected['studentCnic'] ?? selected['bFormNo'] ?? selected['bformNo'] ?? '';
        _guardianCnicCtrl.text = selected['guardianCnic'] ?? selected['fatherCnic'] ?? '';
        _guardianPhoneCtrl.text = _formatPhoneDigits(selected['contactPhone'] ?? selected['guardianPhone'] ?? selected['phone'] ?? '');
        _addressCtrl.text = selected['address'] ?? '';
        _fatherProfessionCtrl.text = selected['fatherProfession'] ?? '';
        _previousSchoolCtrl.text = 'مدرسہ گلزار مدینہ (Madrassa Gulzar-e-Madina Hifz)';
        _photoUrl = selected['photoUrl'] ?? _photoUrl;
        _guardianCnicUrl = selected['guardianCnicUrl'] ?? _guardianCnicUrl;
        _bformUrl = selected['bFormUrl'] ?? selected['bformUrl'] ?? _bformUrl;
        if (pin.isNotEmpty) {
          _biometricPinCtrl.text = pin;
        }
        if (selected['dob'] != null && selected['dob'].toString().isNotEmpty) {
          _dob = DateTime.tryParse(selected['dob'].toString());
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Successfully transferred details for "${selected['name']}". Biometric PIN ($pin) preserved.'),
          backgroundColor: SchoolTheme.primary,
        ),
      );
    }
  }

  Future<void> _saveStudent() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final studentId = widget.studentToEdit?.id ?? 'SCH-${DateTime.now().millisecondsSinceEpoch}';

    final enteredPin = _biometricPinCtrl.text.trim();
    if (enteredPin.isNotEmpty) {
      final conflict = ZkTecoNetworkService.findPinConflict(enteredPin, excludeEntityId: studentId);
      final isTransferredStudent = conflict != null && (
        conflict.entityId == _transferredMadrassaStudentId ||
        conflict.entityName.toLowerCase().trim() == _nameCtrl.text.toLowerCase().trim()
      );

      if (conflict != null && !isTransferredStudent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please choose a unique PIN.'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isSaving = false);
        return;
      }
    }

    final studentData = {
      'rollNo': _rollNoCtrl.text.trim(),
      'admissionNo': _rollNoCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'guardianName': _guardianNameCtrl.text.trim(),
      'fatherName': _guardianNameCtrl.text.trim(),
      'bformNo': _bformNoCtrl.text.trim(),
      'guardianCnic': _guardianCnicCtrl.text.trim(),
      'fatherCnic': _guardianCnicCtrl.text.trim(),
      'dob': _dob != null ? DateFormat('yyyy-MM-dd').format(_dob!) : '',
      'grade': _selectedGrade,
      'section': _selectedSection,
      'academicGroup': _selectedAcademicGroup,
      'fatherProfession': _fatherProfessionCtrl.text.trim(),
      'guardianPhone': _guardianPhoneCtrl.text.trim(),
      'phone': _guardianPhoneCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'previousSchool': _previousSchoolCtrl.text.trim(),
      'biometricPin': enteredPin,
      'gender': _selectedGender,
      'status': _status,
      'photoUrl': _photoUrl ?? '',
      'guardianCnicUrl': _guardianCnicUrl ?? '',
      'bformUrl': _bformUrl ?? '',
      'additionalDocuments': _additionalDocuments,
      'branchId': widget.branchId,
      'admissionDate': DateFormat('yyyy-MM-dd').format(_admissionDate),
      'parentSignatureConfirmed': _parentSignatureConfirmed,
      'transferredFromMadrassaId': _transferredMadrassaStudentId ?? '',
    };

    await SchoolLocalStorage.saveStudent(
      branchId: widget.branchId,
      studentId: studentId,
      studentData: studentData,
    );

    if (enteredPin.isNotEmpty) {
      await ZkTecoNetworkService.assignPinToEntity(
        entityId: studentId,
        entityName: _nameCtrl.text.trim(),
        entityType: 'school_student',
        branchId: widget.branchId,
        customPin: enteredPin,
      );
    }

    if (mounted) {
      setState(() => _isSaving = false);
      Navigator.of(context).pop(true);
      AppFeedback.showSuccess(
        context,
        widget.studentToEdit != null ? 'Student profile updated successfully!' : 'Student enrolled successfully!',
        subtitle: 'Saved locally • Syncing to cloud',
      );
    }
  }

  Future<void> _saveAndPrintStudent() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final enteredPin = _biometricPinCtrl.text.trim();
    final studentId = widget.studentToEdit?.id ?? 'SCH-${DateTime.now().millisecondsSinceEpoch}';

    // Unique Biometric PIN Validation
    if (enteredPin.isNotEmpty) {
      final conflict = ZkTecoNetworkService.findPinConflict(enteredPin, excludeEntityId: studentId);
      final isTransferredStudent = conflict != null && (
        conflict.entityId == _transferredMadrassaStudentId ||
        conflict.entityName.toLowerCase().trim() == _nameCtrl.text.toLowerCase().trim()
      );

      if (conflict != null && !isTransferredStudent) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ PIN $enteredPin is already assigned to "${conflict.entityName}" (${conflict.branchId.toUpperCase()} • ${conflict.entityType.toUpperCase()}). Please choose a unique PIN.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isSaving = false);
        return;
      }
    }

    final studentData = {
      'rollNo': _rollNoCtrl.text.trim(),
      'admissionNo': _rollNoCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'guardianName': _guardianNameCtrl.text.trim(),
      'fatherName': _guardianNameCtrl.text.trim(),
      'bformNo': _bformNoCtrl.text.trim(),
      'guardianCnic': _guardianCnicCtrl.text.trim(),
      'fatherCnic': _guardianCnicCtrl.text.trim(),
      'dob': _dob != null ? DateFormat('yyyy-MM-dd').format(_dob!) : '',
      'grade': _selectedGrade,
      'section': _selectedSection,
      'academicGroup': _selectedAcademicGroup,
      'fatherProfession': _fatherProfessionCtrl.text.trim(),
      'guardianPhone': _guardianPhoneCtrl.text.trim(),
      'phone': _guardianPhoneCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'previousSchool': _previousSchoolCtrl.text.trim(),
      'biometricPin': enteredPin,
      'gender': _selectedGender,
      'status': _status,
      'photoUrl': _photoUrl ?? '',
      'guardianCnicUrl': _guardianCnicUrl ?? '',
      'bformUrl': _bformUrl ?? '',
      'additionalDocuments': _additionalDocuments,
      'branchId': widget.branchId,
      'admissionDate': DateFormat('yyyy-MM-dd').format(_admissionDate),
      'parentSignatureConfirmed': _parentSignatureConfirmed,
      'transferredFromMadrassaId': _transferredMadrassaStudentId ?? '',
    };

    await SchoolLocalStorage.saveStudent(
      branchId: widget.branchId,
      studentId: studentId,
      studentData: studentData,
    );

    if (enteredPin.isNotEmpty) {
      await ZkTecoNetworkService.assignPinToEntity(
        entityId: studentId,
        entityName: _nameCtrl.text.trim(),
        entityType: 'school_student',
        branchId: widget.branchId,
        customPin: enteredPin,
      );
    }

    final savedStudent = SchoolStudent.fromMap(studentId, studentData);

    if (mounted) {
      setState(() => _isSaving = false);
      Navigator.of(context).pop(true);
      AppFeedback.showSuccess(
        context,
        widget.studentToEdit != null ? 'Student profile updated successfully!' : 'Student enrolled successfully!',
        subtitle: 'Saved locally • Admission slip ready to print',
      );
    }

    // Trigger PDF Print & Download Layout
    await SchoolAdmissionPdfService.printAdmissionSlip(savedStudent);
  }

  Future<void> _addCustomDocumentDialog() async {
    final titleCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.note_add_rounded, color: Color(0xFF0F766E)),
            SizedBox(width: 10),
            Text('دیگر دستاویزات / Add Custom Document', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter document title (e.g., Previous School Certificate, Medical Certificate, Character Letter):',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: 'Document Name / نام دستاویز *',
                hintText: 'e.g. Previous School Leaving Certificate (SLC)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: SchoolTheme.primary, foregroundColor: Colors.white),
            onPressed: () {
              final text = titleCtrl.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            child: const Text('Add & Attach File'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        _additionalDocuments.add({'name': result, 'url': ''});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.studentToEdit != null;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      backgroundColor: const Color(0xFFF8FAFC),
      child: Container(
        width: 780,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.94),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Official Authentic Admission Form Card ───────────────────
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF0F172A), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Container(
                    margin: const EdgeInsets.all(6),
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF334155), width: 1.2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Madrassa Student Transfer Top Bar
                        if (!isEditing) _buildMadrassaTransferTopBar(),

                        // 1. Header with Urdu Titles & Crest
                        _buildFormHeader(),

                        const SizedBox(height: 16),
                        const Divider(color: Color(0xFF0F172A), thickness: 1.5, height: 1),
                        const SizedBox(height: 16),

                        // 2. Admission No & Date Row
                        _buildAdmissionNoAndDateRow(),

                        const SizedBox(height: 16),

                        // 3. Form Input Fields (All 11 Fields from Physical Form)
                        _buildFormFieldsSection(),

                        const SizedBox(height: 20),
                        const Divider(color: Color(0xFFCBD5E1), thickness: 1),
                        const SizedBox(height: 14),

                        // 4. Documents & Photos Section
                        _buildDocumentsAndPhotosSection(),

                        const SizedBox(height: 20),
                        const Divider(color: Color(0xFFCBD5E1), thickness: 1),
                        const SizedBox(height: 14),

                        // 5. Parent Signature & Declaration
                        _buildParentSignatureRow(),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Bottom Action Buttons ────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      child: const Text('Cancel / منسوخ', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _isSaving ? null : _saveAndPrintStudent,
                      icon: const Icon(Icons.print_rounded, size: 18),
                      label: const Text('Save & Print PDF / محفوظ و پرنٹ کریں', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SchoolTheme.primary,
                        side: const BorderSide(color: SchoolTheme.primary, width: 1.2),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveStudent,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_rounded, size: 20),
                      label: Text(
                        _isSaving
                            ? 'Saving...'
                            : (isEditing ? 'Save Changes / محفوظ کریں' : 'Enroll Student / داخلہ مکمل کریں'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SchoolTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMadrassaTransferTopBar() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF86EFAC)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.school_outlined, size: 20, color: Color(0xFF16A34A)),
              const SizedBox(width: 8),
              Text(
                _transferredMadrassaInfo != null
                    ? 'Transferred from: $_transferredMadrassaInfo'
                    : 'Transfer student from Madrassa (Hifz / Nazra)?',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: _transferredMadrassaInfo != null ? const Color(0xFF15803D) : const Color(0xFF334155),
                ),
              ),
            ],
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF15803D),
              side: const BorderSide(color: Color(0xFF16A34A)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.sync_alt_rounded, size: 16),
            label: Text(
              _transferredMadrassaInfo != null ? 'Change Madrassa Student' : 'Transfer from Madrassa / مدرسہ سے درآمد',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
            ),
            onPressed: _openMadrassaTransferPicker,
          ),
        ],
      ),
    );
  }

  // ── Header Widget ──────────────────────────────────────────────────────────
  Widget _buildFormHeader() {
    return Column(
      children: [
        // Main Urdu School Name
        Text(
          'تعلیم و تربیت سکول سسٹم',
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          style: GoogleFonts.notoSansArabic(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF0F172A),
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),

        // Welfare Foundation & Contact
        Text(
          'گلزار مدینہ ویلفیئر فاؤنڈیشن گلزار مدینہ روڈ گجرات 0334-4687928',
          textAlign: TextAlign.center,
          textDirection: TextDirection.rtl,
          style: GoogleFonts.notoSansArabic(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF334155),
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),

        // School Crest Emblem & Title Badge
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/logo/twt.webp',
                height: 48,
                width: 48,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.school_rounded, size: 40, color: Color(0xFF0F766E)),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'داخلہ فارم',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.notoSansArabic(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0F172A),
                    height: 1.1,
                  ),
                ),
                Text(
                  'STUDENT ADMISSION FORM',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  // ── Admission No & Date Row ────────────────────────────────────────────────
  Widget _buildAdmissionNoAndDateRow() {
    return Row(
      children: [
        // Admission / Roll No (داخلہ نمبر)
        Expanded(
          child: Row(
            children: [
              Text(
                'داخلہ نمبر / Roll No:',
                style: GoogleFonts.notoSansArabic(fontSize: 13.5, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _rollNoCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. 101',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0F172A), width: 1.5)),
                  ),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Required / ضروری ہے' : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),

        // Admission Date (تاریخ)
        Expanded(
          child: InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _admissionDate,
                firstDate: DateTime(2015),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) setState(() => _admissionDate = picked);
            },
            child: Row(
              children: [
                Text(
                  'تاریخ / Date:',
                  style: GoogleFonts.notoSansArabic(fontSize: 13.5, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFF0F172A), width: 1.5)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          DateFormat('dd-MM-yyyy').format(_admissionDate),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
                        ),
                        const Icon(Icons.calendar_today_rounded, size: 16, color: Color(0xFF0F766E)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Form Input Fields Section (11 Form Items) ──────────────────────────────
  Widget _buildFormFieldsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. نام طالب علم (Student Name)
        _buildBilingualInputRow(
          urduLabel: 'نام طالب علم',
          englishLabel: 'Student Full Name',
          controller: _nameCtrl,
          isRequired: true,
          hint: 'Enter student full name in Urdu or English',
        ),
        const SizedBox(height: 12),

        // 2. والد کا نام (Father's Name)
        _buildBilingualInputRow(
          urduLabel: 'والد کا نام',
          englishLabel: "Father's / Guardian Name",
          controller: _guardianNameCtrl,
          isRequired: true,
          hint: "Enter father's full name",
        ),
        const SizedBox(height: 12),

        // 3. بچے کا ب فارم نمبر (Child's B-Form Number)
        _buildBilingualInputRow(
          urduLabel: 'بچے کا ب فارم نمبر',
          englishLabel: "Child's B-Form / Birth Cert No",
          controller: _bformNoCtrl,
          hint: 'XXXXX-XXXXXXX-X',
          keyboardType: TextInputType.number,
          inputFormatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
        ),
        const SizedBox(height: 12),

        // 4. والد کا شناختی کارڈ نمبر (Father's CNIC Number)
        _buildBilingualInputRow(
          urduLabel: 'والد کا شناختی کارڈ نمبر',
          englishLabel: "Father's CNIC Number",
          controller: _guardianCnicCtrl,
          hint: 'XXXXX-XXXXXXX-X',
          keyboardType: TextInputType.number,
          inputFormatters: [CNICInputFormatter(), LengthLimitingTextInputFormatter(15)],
        ),
        const SizedBox(height: 12),

        // 5. تاریخ پیدائش (Date of Birth)
        _buildDateOfBirthRow(),
        const SizedBox(height: 12),

        // 6. کلاس اور سیکشن (Class & Section) + Academic Stream
        _buildClassSectionAndStreamRow(),
        const SizedBox(height: 12),

        // 7. پیشہ (Father's Profession)
        _buildBilingualInputRow(
          urduLabel: 'پیشہ',
          englishLabel: "Father's Profession / Occupation",
          controller: _fatherProfessionCtrl,
          hint: 'e.g. Business / Government Employee / Private Job',
        ),
        const SizedBox(height: 12),

        // 8. فون نمبر (Phone Number - strictly 11 digits)
        _buildBilingualInputRow(
          urduLabel: 'فون نمبر',
          englishLabel: 'Contact Phone Number (11 digits)',
          controller: _guardianPhoneCtrl,
          isRequired: true,
          hint: 'e.g. 03001234567 (11 digits)',
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
          customValidator: (v) {
            if (v == null || v.trim().isEmpty) return 'Contact phone is required';
            if (v.trim().length != 11) return 'Phone number must be exactly 11 digits';
            return null;
          },
        ),
        const SizedBox(height: 12),

        // 9. گھر کا پتہ (Home Address)
        _buildBilingualInputRow(
          urduLabel: 'گھر کا پتہ',
          englishLabel: 'Residential Home Address',
          controller: _addressCtrl,
          hint: 'Full residential street address / Mohallah',
        ),
        const SizedBox(height: 12),

        // 10. سابقہ مدرسہ / سکول کا نام (Previous School / Madrassa Name)
        _buildBilingualInputRow(
          urduLabel: 'سابقہ مدرسہ / سکول کا نام',
          englishLabel: 'Previous School / Madrassa Name',
          controller: _previousSchoolCtrl,
          hint: 'Name of previous school, academy or madrassa if any',
        ),
        const SizedBox(height: 12),

        // 11. بائیو میٹرک اسکینر پن (Biometric Scanner PIN)
        _buildBilingualInputRow(
          urduLabel: 'بائیو میٹرک اسکینر پن',
          englishLabel: 'Biometric Scanner Device PIN',
          controller: _biometricPinCtrl,
          hint: 'e.g. 5012 (Unique PIN for physical biometric attendance machines)',
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          prefixIcon: Icons.fingerprint_rounded,
        ),
      ],
    );
  }

  // ── Helper: Bilingual Input Row ────────────────────────────────────────────
  Widget _buildBilingualInputRow({
    required String urduLabel,
    required String englishLabel,
    required TextEditingController controller,
    bool isRequired = false,
    String? hint,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    IconData? prefixIcon,
    String? Function(String?)? customValidator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                if (prefixIcon != null) ...[
                  Icon(prefixIcon, size: 16, color: SchoolTheme.primary),
                  const SizedBox(width: 6),
                ],
                Text(
                  '$englishLabel ${isRequired ? '*' : ''}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                ),
              ],
            ),
            Text(
              urduLabel,
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoSansArabic(fontSize: 13.5, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.5),
            ),
          ),
          validator: customValidator ?? (isRequired ? (v) => v == null || v.trim().isEmpty ? '$englishLabel is required' : null : null),
        ),
      ],
    );
  }

  // ── Helper: Date of Birth Row ──────────────────────────────────────────────
  Widget _buildDateOfBirthRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Date of Birth (DOB)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
            ),
            Text(
              'تاریخ پیدائش',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoSansArabic(fontSize: 13.5, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _dob ?? DateTime(2015, 1, 1),
              firstDate: DateTime(2000),
              lastDate: DateTime.now(),
            );
            if (picked != null) setState(() => _dob = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _dob != null ? DateFormat('dd-MM-yyyy').format(_dob!) : 'Select Date of Birth (تاریخ پیدائش منتخب کریں)',
                  style: TextStyle(
                    fontSize: 13,
                    color: _dob != null ? const Color(0xFF0F172A) : Colors.grey.shade500,
                    fontWeight: _dob != null ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const Icon(Icons.cake_outlined, size: 18, color: Color(0xFF0F766E)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Helper: Class, Section & Stream Dropdowns ──────────────────────────────
  Widget _buildClassSectionAndStreamRow() {
    final groupOptions = SchoolConstants.getAcademicGroupsForGrade(_selectedGrade);
    final isHigh = SchoolConstants.isHighSchool(_selectedGrade);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Class, Section & Academic Stream',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
            ),
            Text(
              'کلاس اور تعلیمی گروپ',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoSansArabic(fontSize: 13.5, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            // Class / Grade
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                value: _selectedGrade,
                decoration: InputDecoration(
                  labelText: 'Class / کلاس',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: _grades.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _selectedGrade = v;
                      final avail = SchoolConstants.getAcademicGroupsForGrade(v);
                      if (!avail.contains(_selectedAcademicGroup)) {
                        _selectedAcademicGroup = avail.first;
                      }
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 8),

            // Section
            Expanded(
              flex: 1,
              child: DropdownButtonFormField<String>(
                value: _selectedSection,
                decoration: InputDecoration(
                  labelText: 'Section / سیکشن',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: _sections.map((s) => DropdownMenuItem(value: s, child: Text('Sec $s'))).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedSection = v);
                },
              ),
            ),
            const SizedBox(width: 8),

            // Academic Stream (High school)
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                value: groupOptions.contains(_selectedAcademicGroup) ? _selectedAcademicGroup : groupOptions.first,
                decoration: InputDecoration(
                  labelText: isHigh ? 'Stream / گروپ' : 'General / جنرل',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: groupOptions.map((g) => DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(fontSize: 12)))).toList(),
                onChanged: isHigh
                    ? (v) {
                        if (v != null) setState(() => _selectedAcademicGroup = v);
                      }
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Documents & Photos Section ─────────────────────────────────────────────
  Widget _buildDocumentsAndPhotosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.perm_media_outlined, size: 18, color: Color(0xFF0F766E)),
                SizedBox(width: 8),
                Text(
                  'Official Documents & Student Photo',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
              ],
            ),
            Text(
              'دستاویزات اور تصویر',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoSansArabic(fontSize: 14, fontWeight: FontWeight.bold, color: SchoolTheme.primary),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 3 Upload Tiles: Student Photo, Father CNIC, B-Form
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Student Photo (Profile Avatar)
            Expanded(
              child: MediaUploadTile(
                label: 'طالب علم کی تصویر\nStudent Photo (Avatar)',
                icon: Icons.add_a_photo_outlined,
                initialValue: _photoUrl,
                onChanged: (val) => setState(() => _photoUrl = val),
              ),
            ),
            const SizedBox(width: 10),

            // Father CNIC Document
            Expanded(
              child: MediaUploadTile(
                label: 'والد کا شناختی کارڈ\nFather CNIC Document',
                icon: Icons.badge_outlined,
                isDocument: true,
                initialValue: _guardianCnicUrl,
                onChanged: (val) => setState(() => _guardianCnicUrl = val),
              ),
            ),
            const SizedBox(width: 10),

            // B-Form / Birth Certificate
            Expanded(
              child: MediaUploadTile(
                label: 'ب فارم / برتھ سرٹیفکیٹ\nB-Form / Birth Certificate',
                icon: Icons.description_outlined,
                isDocument: true,
                initialValue: _bformUrl,
                onChanged: (val) => setState(() => _bformUrl = val),
              ),
            ),
          ],
        ),

        // Custom Additional Documents
        if (_additionalDocuments.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Custom Attached Documents / دیگر دستاویزات:',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 6),
          ..._additionalDocuments.asMap().entries.map((entry) {
            final index = entry.key;
            final doc = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: MediaUploadTile(
                      label: doc['name'] ?? 'Custom Document',
                      icon: Icons.file_present_rounded,
                      isDocument: true,
                      initialValue: doc['url'],
                      onChanged: (val) {
                        setState(() {
                          _additionalDocuments[index]['url'] = val ?? '';
                        });
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                    onPressed: () {
                      setState(() {
                        _additionalDocuments.removeAt(index);
                      });
                    },
                  ),
                ],
              ),
            );
          }),
        ],

        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: SchoolTheme.primary,
              side: const BorderSide(color: Color(0xFF0F766E)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
            label: const Text(
              '+ Add Custom Document (e.g. SLC, Medical, Degree) / دیگر دستاویز منسلک کریں',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            onPressed: _addCustomDocumentDialog,
          ),
        ),
      ],
    );
  }

  // ── Parent Signature & Declaration Row ─────────────────────────────────────
  Widget _buildParentSignatureRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Checkbox(
              value: _parentSignatureConfirmed,
              activeColor: SchoolTheme.primary,
              onChanged: (v) => setState(() => _parentSignatureConfirmed = v ?? true),
            ),
            const Text(
              'Parent / Guardian Verified & Declared\n(تصدیق شدہ برائے والدین / سرپرست)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'دستخط والدین',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.notoSansArabic(fontSize: 15, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
            ),
            const SizedBox(
              width: 140,
              child: Divider(color: Color(0xFF0F172A), thickness: 1.5),
            ),
          ],
        ),
      ],
    );
  }
}
