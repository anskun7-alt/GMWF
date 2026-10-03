// lib/pages/school/dialogs/school_teacher_dialog.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../widgets/media_upload_tile.dart';
import '../models/school_teacher.dart';
import '../utils/school_local_storage.dart';
import '../constants/school_constants.dart';
import '../../../widgets/app_feedback.dart';

class SchoolTeacherDialog extends StatefulWidget {
  final String branchId;
  final SchoolTeacher? teacherToEdit;

  const SchoolTeacherDialog({
    super.key,
    required this.branchId,
    this.teacherToEdit,
  });

  @override
  State<SchoolTeacherDialog> createState() => _SchoolTeacherDialogState();
}

class _SchoolTeacherDialogState extends State<SchoolTeacherDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _employeeIdCtrl;
  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _cnicCtrl;
  late TextEditingController _degreeCtrl;
  late TextEditingController _qualificationCtrl;
  late TextEditingController _designationCtrl;
  late TextEditingController _subjectsCtrl;
  late TextEditingController _salaryGradeCtrl;

  String _selectedDepartment = 'Science & IT';
  String _status = 'active';
  String? _photoUrl;
  String? _cnicUrl;
  String? _experienceLetterUrl;
  String? _joiningLetterUrl;
  String? _degreesUrl;
  List<Map<String, String>> _additionalDocuments = [];
  bool _isSaving = false;

  final List<String> _departments = [
    'Science & IT',
    'Mathematics',
    'Languages & English',
    'Social Studies & Humanities',
    'Arts & Commerce',
    'Primary Education',
    'Administration',
  ];

  final List<String> _allGrades = SchoolConstants.grades;

  List<String> _selectedGrades = [];

  @override
  void initState() {
    super.initState();
    final t = widget.teacherToEdit;
    _employeeIdCtrl = TextEditingController(text: t?.employeeId ?? '');
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _emailCtrl = TextEditingController(text: t?.email ?? '');
    _phoneCtrl = TextEditingController(text: t?.phone ?? '');
    _cnicCtrl = TextEditingController(text: t?.cnic ?? '');
    _degreeCtrl = TextEditingController(text: t?.degree ?? '');
    _qualificationCtrl = TextEditingController(text: t?.qualification ?? '');
    _designationCtrl = TextEditingController(text: t?.designation ?? 'Subject Teacher');
    _subjectsCtrl = TextEditingController(text: t?.subjects.join(', ') ?? '');
    _salaryGradeCtrl = TextEditingController(text: t?.salaryGrade ?? '');

    if (t != null) {
      _selectedGrades = List.from(t.assignedGrades);
      _selectedDepartment = _departments.contains(t.department) ? t.department : _departments.first;
      _status = t.status;
      _photoUrl = t.photoUrl;
      _cnicUrl = t.cnicUrl;
      _experienceLetterUrl = t.experienceLetterUrl;
      _joiningLetterUrl = t.joiningLetterUrl;
      _degreesUrl = t.degreesUrl;
      _additionalDocuments = t.additionalDocuments.map((d) => Map<String, String>.from(d)).toList();
    }
  }

  @override
  void dispose() {
    _employeeIdCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _cnicCtrl.dispose();
    _degreeCtrl.dispose();
    _qualificationCtrl.dispose();
    _designationCtrl.dispose();
    _subjectsCtrl.dispose();
    _salaryGradeCtrl.dispose();
    super.dispose();
  }

  Future<void> _addCustomDocumentDialog() async {
    final titleCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.note_add_rounded, color: Color(0xFF1B4965)),
            SizedBox(width: 10),
            Text('Add Faculty Document', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the document name (e.g., Degree Certificate, Appointment Letter, Experience Certificate):',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: 'Document Name *',
                hintText: 'e.g. Master Degree Certificate',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1B4965), foregroundColor: Colors.white),
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

  Future<void> _saveTeacher() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final teacherId = widget.teacherToEdit?.id ?? 'TCH-${DateTime.now().millisecondsSinceEpoch}';
    final subjectsList = _subjectsCtrl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final teacherData = {
      'employeeId': _employeeIdCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'email': _emailCtrl.text.trim().toLowerCase(),
      'phone': _phoneCtrl.text.trim(),
      'cnic': _cnicCtrl.text.trim(),
      'degree': _degreeCtrl.text.trim(),
      'qualification': _qualificationCtrl.text.trim(),
      'designation': _designationCtrl.text.trim(),
      'department': _selectedDepartment,
      'assignedGrades': _selectedGrades,
      'subjects': subjectsList,
      'salaryGrade': _salaryGradeCtrl.text.trim(),
      'status': _status,
      'photoUrl': _photoUrl ?? '',
      'cnicUrl': _cnicUrl ?? '',
      'experienceLetterUrl': _experienceLetterUrl ?? '',
      'joiningLetterUrl': _joiningLetterUrl ?? '',
      'degreesUrl': _degreesUrl ?? '',
      'additionalDocuments': _additionalDocuments,
      'branchId': widget.branchId,
    };

    await SchoolLocalStorage.saveTeacher(
      branchId: widget.branchId,
      teacherId: teacherId,
      teacherData: teacherData,
    );

    if (mounted) {
      setState(() => _isSaving = false);
      Navigator.of(context).pop(true);
      AppFeedback.showSuccess(
        context,
        widget.teacherToEdit != null ? 'Teacher profile updated successfully!' : 'Teacher profile created successfully!',
        subtitle: 'Saved locally • Syncing to cloud',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.teacherToEdit != null;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2D9B83).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.person_add_alt_1_rounded, color: Color(0xFF2D9B83)),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        isEditing ? 'Edit Faculty Profile & Documents' : 'Register New Faculty Member',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),

                  // SECTION: Faculty Documents
                  const Text(
                    'Faculty Profile & Official Credentials',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                  ),
                  const SizedBox(height: 10),

                  // Row 1: Profile Photo & CNIC
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Profile Photo
                      Expanded(
                        child: MediaUploadTile(
                          label: 'Faculty Photo',
                          icon: Icons.account_box_outlined,
                          initialValue: _photoUrl,
                          onChanged: (val) => setState(() => _photoUrl = val),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // CNIC Document
                      Expanded(
                        child: MediaUploadTile(
                          label: 'CNIC / ID Card',
                          icon: Icons.badge_outlined,
                          isDocument: true,
                          initialValue: _cnicUrl,
                          onChanged: (val) => setState(() => _cnicUrl = val),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Row 2: Experience Letter & Job Joining Letter
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Experience Letter (Optional)
                      Expanded(
                        child: MediaUploadTile(
                          label: 'Experience Letter (تجربہ سرٹیفکیٹ)',
                          icon: Icons.history_edu_outlined,
                          isDocument: true,
                          initialValue: _experienceLetterUrl,
                          onChanged: (val) => setState(() => _experienceLetterUrl = val),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Joining / Job Appointment Letter (Optional)
                      Expanded(
                        child: MediaUploadTile(
                          label: 'Job Joining Letter (تقرری نامہ)',
                          icon: Icons.assignment_turned_in_outlined,
                          isDocument: true,
                          initialValue: _joiningLetterUrl,
                          onChanged: (val) => setState(() => _joiningLetterUrl = val),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Row 3: Degrees & Educational Transcripts (Optional)
                  MediaUploadTile(
                    label: 'Degrees & Certificates (تعلیمی اسناد و ڈگریاں)',
                    icon: Icons.school_outlined,
                    isDocument: true,
                    initialValue: _degreesUrl,
                    onChanged: (val) => setState(() => _degreesUrl = val),
                  ),

                  // Additional Custom Documents List
                  if (_additionalDocuments.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Custom Documents:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
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

                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2D9B83),
                        side: const BorderSide(color: Color(0xFF2D9B83)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                      label: const Text('+ Add Custom Document (e.g. Degree, Experience Letter)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: _addCustomDocumentDialog,
                    ),
                  ),

                  const Divider(height: 32),

                  // Employee ID & Full Name
                  Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: TextFormField(
                          controller: _employeeIdCtrl,
                          decoration: InputDecoration(
                            labelText: 'Employee ID *',
                            hintText: 'EMP-101',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _nameCtrl,
                          decoration: InputDecoration(
                            labelText: 'Teacher Full Name *',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty ? 'Enter teacher name' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Email & Phone
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: 'Email Address',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _phoneCtrl,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                          decoration: InputDecoration(
                            labelText: 'Phone Number (11 digits) *',
                            hintText: 'e.g. 03001234567',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Enter phone';
                            if (v.trim().length != 11) return 'Phone must be exactly 11 digits';
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // CNIC & Degree
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _cnicCtrl,
                          decoration: InputDecoration(
                            labelText: 'CNIC / National ID',
                            hintText: '35201-xxxxxxx-x',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _degreeCtrl,
                          decoration: InputDecoration(
                            labelText: 'Degree (e.g. M.Sc, B.Ed, M.A)',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Department & Designation
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _selectedDepartment,
                          decoration: InputDecoration(
                            labelText: 'Department',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          items: _departments.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedDepartment = v);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _designationCtrl,
                          decoration: InputDecoration(
                            labelText: 'Designation',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Subjects Taught & Salary Grade
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _subjectsCtrl,
                          decoration: InputDecoration(
                            labelText: 'Main Teaching Subjects (comma separated)',
                            hintText: 'Physics, Computer Science, Mathematics',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: TextFormField(
                          controller: _salaryGradeCtrl,
                          decoration: InputDecoration(
                            labelText: 'Salary Grade',
                            hintText: 'e.g. BPS-16',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Status
                  DropdownButtonFormField<String>(
                    value: _status,
                    decoration: InputDecoration(
                      labelText: 'Account Status',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Active')),
                      DropdownMenuItem(value: 'on leave', child: Text('On Leave')),
                      DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
                      DropdownMenuItem(value: 'revoked', child: Text('Access Revoked')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _status = v);
                    },
                  ),
                  const SizedBox(height: 16),

                  // Assigned Grades Checklist
                  const Text(
                    'Assigned Classes / Grades',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _allGrades.map((grade) {
                      final isSelected = _selectedGrades.contains(grade);
                      return FilterChip(
                        label: Text(grade),
                        selected: isSelected,
                        selectedColor: const Color(0xFF2D9B83).withValues(alpha: 0.2),
                        checkmarkColor: const Color(0xFF2D9B83),
                        labelStyle: TextStyle(
                          color: isSelected ? const Color(0xFF047857) : const Color(0xFF475569),
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedGrades.add(grade);
                            } else {
                              _selectedGrades.remove(grade);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  // Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: _isSaving ? null : _saveTeacher,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2D9B83),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : Text(isEditing ? 'Save Changes' : 'Register Teacher'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
