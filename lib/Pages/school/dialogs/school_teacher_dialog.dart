// lib/pages/school/dialogs/school_teacher_dialog.dart
//
// Add / edit faculty member profile and credentials (Phase 6: gmwf_ui tokens,
// consistent typography/spacing, try/catch save, collision-free IDs).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../../../widgets/media_upload_tile.dart';
import '../constants/school_constants.dart';
import '../models/school_teacher.dart';
import '../utils/school_local_storage.dart';

class SchoolTeacherDialog extends StatefulWidget {
  final String branchId;
  final SchoolTeacher? teacherToEdit;
  final String editorName;

  const SchoolTeacherDialog({
    super.key,
    required this.branchId,
    this.teacherToEdit,
    this.editorName = 'School Admin',
  });

  @override
  State<SchoolTeacherDialog> createState() => _SchoolTeacherDialogState();
}

class _SchoolTeacherDialogState extends State<SchoolTeacherDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _employeeIdCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _cnicCtrl;
  late final TextEditingController _degreeCtrl;
  late final TextEditingController _qualificationCtrl;
  late final TextEditingController _designationCtrl;
  late final TextEditingController _subjectsCtrl;
  late final TextEditingController _salaryGradeCtrl;

  String _selectedDepartment = 'Science & IT';
  String _status = 'active';
  String? _photoUrl;
  String? _cnicUrl;
  String? _experienceLetterUrl;
  String? _joiningLetterUrl;
  String? _degreesUrl;
  List<Map<String, String>> _additionalDocuments = [];
  bool _isSaving = false;

  static const List<String> _departments = [
    'Science & IT',
    'Mathematics',
    'Languages & English',
    'Social Studies & Humanities',
    'Arts & Commerce',
    'Primary Education',
    'Administration',
  ];

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
      builder: (ctx) {
        final c = ctx.comfort;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: Gr.modal),
          title: Row(children: [
            Icon(GIcons.layers, color: c.brand),
            const SizedBox(width: Gsp.sp2),
            Expanded(child: Text('Add faculty document', style: GText.h3(c.textPrimary))),
          ]),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Enter the document name (e.g. Degree Certificate, Appointment Letter, Experience Certificate):',
                style: GText.body2(c.textSecondary),
              ),
              const SizedBox(height: Gsp.sp3),
              TextField(
                controller: titleCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Document name *',
                  hintText: 'e.g. Master Degree Certificate',
                  isDense: true,
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final text = titleCtrl.text.trim();
                if (text.isNotEmpty) Navigator.pop(ctx, text);
              },
              child: const Text('Add document'),
            ),
          ],
        );
      },
    );
    titleCtrl.dispose();

    if (result != null && result.isNotEmpty) {
      setState(() => _additionalDocuments.add({'name': result, 'url': ''}));
    }
  }

  Future<void> _saveTeacher() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final teacherId = widget.teacherToEdit?.id ?? SchoolLocalStorage.newId('TCH', widget.branchId);
      final subjectsList = _subjectsCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      final teacherData = <String, dynamic>{
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
        editorName: widget.editorName,
      );

      if (!mounted) return;
      final nav = Navigator.of(context);
      final parentCtx = nav.context;
      nav.pop(true);
      if (parentCtx.mounted) {
        AppFeedback.success(
          parentCtx,
          widget.teacherToEdit != null ? 'Teacher profile updated' : 'Teacher profile created',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        AppFeedback.error(context, 'Could not save teacher: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final isEditing = widget.teacherToEdit != null;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: Gr.modal),
      backgroundColor: c.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Padding(
          padding: const EdgeInsets.all(Gsp.sp5),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(children: [
                    const GModuleTile(icon: GIcons.teacher, size: 36),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(isEditing ? 'Edit faculty profile' : 'Register faculty member', style: GText.h3(c.textPrimary)),
                        Text('Profile details, class assignments and credentials', style: GText.caption(c.textMuted)),
                      ]),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
                      icon: const Icon(GIcons.close),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  Divider(height: 1, color: c.border),
                  const SizedBox(height: Gsp.sp4),

                  // Identity & Contact
                  Text('IDENTITY & CONTACT', style: GText.overline(c.textMuted)),
                  const SizedBox(height: Gsp.sp2),
                  Row(children: [
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _employeeIdCtrl,
                        decoration: const InputDecoration(labelText: 'Employee ID *', hintText: 'EMP-101', isDense: true),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(labelText: 'Teacher full name *', isDense: true),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter teacher name' : null,
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email address', isDense: true),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: TextFormField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                        decoration: const InputDecoration(labelText: 'Phone (11 digits) *', hintText: '03001234567', isDense: true),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Enter phone';
                          if (v.trim().length != 11) return 'Must be 11 digits';
                          return null;
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _cnicCtrl,
                        decoration: const InputDecoration(labelText: 'CNIC', hintText: '35201-xxxxxxx-x', isDense: true),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: TextFormField(
                        controller: _degreeCtrl,
                        decoration: const InputDecoration(labelText: 'Degree (e.g. M.Sc, B.Ed)', isDense: true),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp4),

                  // Role & Classes
                  Text('ROLE & ASSIGNMENTS', style: GText.overline(c.textMuted)),
                  const SizedBox(height: Gsp.sp2),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedDepartment,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Department', isDense: true),
                        items: [for (final d in _departments) DropdownMenuItem(value: d, child: Text(d))],
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedDepartment = v);
                        },
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: TextFormField(
                        controller: _designationCtrl,
                        decoration: const InputDecoration(labelText: 'Designation', isDense: true),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  Row(children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _subjectsCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Teaching subjects (comma separated)',
                          hintText: 'Physics, Mathematics',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _salaryGradeCtrl,
                        decoration: const InputDecoration(labelText: 'Pay grade', hintText: 'BPS-16', isDense: true),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  DropdownButtonFormField<String>(
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: 'Status', isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Active')),
                      DropdownMenuItem(value: 'on leave', child: Text('On leave')),
                      DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
                      DropdownMenuItem(value: 'revoked', child: Text('Access revoked')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _status = v);
                    },
                  ),
                  const SizedBox(height: Gsp.sp3),
                  Text('Assigned classes', style: GText.label(c.textSecondary)),
                  const SizedBox(height: Gsp.sp2),
                  Wrap(
                    spacing: Gsp.sp1 + 2,
                    runSpacing: Gsp.sp1,
                    children: [
                      for (final grade in SchoolConstants.grades)
                        FilterChip(
                          label: Text(grade),
                          selected: _selectedGrades.contains(grade),
                          onSelected: (sel) => setState(() {
                            sel ? _selectedGrades.add(grade) : _selectedGrades.remove(grade);
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: Gsp.sp4),
                  Divider(height: 1, color: c.border),
                  const SizedBox(height: Gsp.sp4),

                  // Credentials & documents
                  Text('CREDENTIALS & DOCUMENTS', style: GText.overline(c.textMuted)),
                  const SizedBox(height: Gsp.sp2),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: MediaUploadTile(
                        label: 'Faculty photo',
                        icon: GIcons.profile,
                        initialValue: _photoUrl,
                        onChanged: (val) => setState(() => _photoUrl = val),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp2 + 2),
                    Expanded(
                      child: MediaUploadTile(
                        label: 'CNIC / ID card',
                        icon: GIcons.employee,
                        isDocument: true,
                        initialValue: _cnicUrl,
                        onChanged: (val) => setState(() => _cnicUrl = val),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp2 + 2),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: MediaUploadTile(
                        label: 'Experience letter (تجربہ سرٹیفکیٹ)',
                        icon: GIcons.history,
                        isDocument: true,
                        initialValue: _experienceLetterUrl,
                        onChanged: (val) => setState(() => _experienceLetterUrl = val),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp2 + 2),
                    Expanded(
                      child: MediaUploadTile(
                        label: 'Joining letter (تقرری نامہ)',
                        icon: GIcons.checklist,
                        isDocument: true,
                        initialValue: _joiningLetterUrl,
                        onChanged: (val) => setState(() => _joiningLetterUrl = val),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp2 + 2),
                  MediaUploadTile(
                    label: 'Degrees & certificates (تعلیمی اسناد و ڈگریاں)',
                    icon: GIcons.student,
                    isDocument: true,
                    initialValue: _degreesUrl,
                    onChanged: (val) => setState(() => _degreesUrl = val),
                  ),
                  if (_additionalDocuments.isNotEmpty) ...[
                    const SizedBox(height: Gsp.sp3),
                    Text('Additional documents', style: GText.caption(c.textMuted)),
                    const SizedBox(height: Gsp.sp2),
                    for (final (index, doc) in _additionalDocuments.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gsp.sp2),
                        child: Row(children: [
                          Expanded(
                            child: MediaUploadTile(
                              label: doc['name'] ?? 'Custom document',
                              icon: GIcons.layers,
                              isDocument: true,
                              initialValue: doc['url'],
                              onChanged: (val) => setState(() => _additionalDocuments[index]['url'] = val ?? ''),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove document',
                            icon: Icon(GIcons.delete, color: c.danger, size: GIconSize.sm),
                            onPressed: () => setState(() => _additionalDocuments.removeAt(index)),
                          ),
                        ]),
                      ),
                  ],
                  const SizedBox(height: Gsp.sp2),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      icon: const Icon(GIcons.add, size: 16),
                      label: const Text('Add custom document'),
                      onPressed: _addCustomDocumentDialog,
                    ),
                  ),
                  const SizedBox(height: Gsp.sp5),

                  // Actions
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: Gsp.sp2),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _saveTeacher,
                      icon: _isSaving
                          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2))
                          : const Icon(GIcons.save, size: 16),
                      label: Text(_isSaving ? 'Saving…' : (isEditing ? 'Save changes' : 'Register teacher')),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
