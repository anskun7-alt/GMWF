// lib/pages/school/dialogs/school_homeroom_dialog.dart
//
// Assign or transfer a homeroom (Class Incharge) teacher (Phase 6: gmwf_ui
// tokens and all configured sections A–D).

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';

import '../constants/school_constants.dart';
import '../models/school_teacher.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolHomeroomDialog extends StatefulWidget {
  final String branchId;
  final String editorName;
  final String initialGrade;
  final String initialSection;

  const SchoolHomeroomDialog({
    super.key,
    required this.branchId,
    this.editorName = 'School Admin',
    this.initialGrade = '9th',
    this.initialSection = 'A',
  });

  @override
  State<SchoolHomeroomDialog> createState() => _SchoolHomeroomDialogState();
}

class _SchoolHomeroomDialogState extends State<SchoolHomeroomDialog> {
  late String _selectedGrade;
  late String _selectedSection;
  String? _selectedTeacherId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedGrade = SchoolConstants.grades.contains(widget.initialGrade)
        ? widget.initialGrade
        : SchoolConstants.grades.first;
    _selectedSection = SchoolConstants.sections.contains(widget.initialSection)
        ? widget.initialSection
        : SchoolConstants.sections.first;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: Gr.modal),
      backgroundColor: c.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(Gsp.sp5),
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
            builder: (context, snapshot) {
              final rawTeachers = snapshot.data ?? const [];
              final activeTeachers = rawTeachers
                  .map((m) => SchoolTeacher.fromMap((m['id'] ?? '').toString(), m))
                  .where((t) => t.status.toLowerCase() == 'active')
                  .toList()
                ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

              final currentAssignment = SchoolLocalStorage.getHomeroomAssignmentCached(
                widget.branchId,
                _selectedGrade,
                _selectedSection,
              );
              final currentTeacherId = currentAssignment?['teacherId']?.toString() ?? '';
              final currentTeacherName = currentAssignment?['teacherName']?.toString() ?? 'Unassigned';

              SchoolTeacher? selectedTeacher;
              for (final t in activeTeachers) {
                if (t.id == _selectedTeacherId) selectedTeacher = t;
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(children: [
                    const GModuleTile(icon: GIcons.classroom, size: 36),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Assign / transfer homeroom teacher', style: GText.h3(c.textPrimary)),
                        Text('Manage class in-charge and attendance access', style: GText.caption(c.textMuted)),
                      ]),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(GIcons.close),
                      onPressed: _isSaving ? null : () => Navigator.pop(context, false),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp3),
                  Divider(height: 1, color: c.border),
                  const SizedBox(height: Gsp.sp4),

                  // Class & Section
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('hr-grade-$_selectedGrade'),
                        initialValue: _selectedGrade,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Class / grade', isDense: true),
                        items: [
                          for (final g in SchoolConstants.grades) DropdownMenuItem(value: g, child: Text('Class $g')),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedGrade = v;
                              _selectedTeacherId = null;
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('hr-sec-$_selectedSection'),
                        initialValue: _selectedSection,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Section', isDense: true),
                        items: [
                          for (final s in SchoolConstants.sections) DropdownMenuItem(value: s, child: Text('Section $s')),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedSection = v;
                              _selectedTeacherId = null;
                            });
                          }
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: Gsp.sp4),

                  // Current status banner
                  Container(
                    padding: const EdgeInsets.all(Gsp.sp3),
                    decoration: BoxDecoration(
                      color: currentTeacherId.isNotEmpty ? c.brandSoft : c.warningBg,
                      borderRadius: SchoolErp.radius,
                      border: Border.all(
                        color: (currentTeacherId.isNotEmpty ? c.brand : c.warning).withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(children: [
                      Icon(
                        currentTeacherId.isNotEmpty ? GIcons.checkCircle : GIcons.info,
                        color: currentTeacherId.isNotEmpty ? c.brand : c.warning,
                        size: GIconSize.sm,
                      ),
                      const SizedBox(width: Gsp.sp2),
                      Expanded(
                        child: Text(
                          currentTeacherId.isNotEmpty
                              ? 'Currently assigned: $currentTeacherName'
                              : 'No homeroom teacher assigned for Class $_selectedGrade-$_selectedSection',
                          style: GText.body2Bold(currentTeacherId.isNotEmpty ? c.brand : c.warning),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: Gsp.sp4),

                  // Teacher picker
                  DropdownButtonFormField<String>(
                    key: ValueKey('hr-tch-$_selectedGrade-$_selectedSection-$_selectedTeacherId'),
                    initialValue: selectedTeacher?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Assign / transfer to teacher',
                      hintText: 'Select a faculty member…',
                      isDense: true,
                    ),
                    items: [
                      for (final t in activeTeachers)
                        DropdownMenuItem(
                          value: t.id,
                          child: Text(
                            '${t.name}${t.employeeId.isEmpty ? '' : ' (${t.employeeId})'}${t.isHomeroom ? ' · Currently ${t.homeroomClass}' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (val) => setState(() => _selectedTeacherId = val),
                  ),
                  const SizedBox(height: Gsp.sp5),

                  // Footer actions
                  Row(children: [
                    if (currentTeacherId.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(color: c.danger),
                        ),
                        icon: const Icon(GIcons.cancel, size: 16),
                        label: const Text('Remove'),
                        onPressed: _isSaving ? null : () => _saveAssignment(remove: true),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: _isSaving ? null : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: Gsp.sp2),
                    FilledButton.icon(
                      icon: _isSaving
                          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2))
                          : const Icon(GIcons.check, size: 16),
                      label: Text(_isSaving ? 'Saving…' : 'Confirm assignment'),
                      onPressed: (_isSaving || selectedTeacher == null)
                          ? null
                          : () => _saveAssignment(remove: false, teacher: selectedTeacher),
                    ),
                  ]),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _saveAssignment({required bool remove, SchoolTeacher? teacher}) async {
    setState(() => _isSaving = true);
    try {
      await SchoolLocalStorage.assignHomeroomTeacher(
        branchId: widget.branchId,
        grade: _selectedGrade,
        section: _selectedSection,
        teacherId: remove ? null : teacher?.id,
        teacherName: remove ? null : teacher?.name,
        editorName: widget.editorName,
      );

      if (!mounted) return;
      final nav = Navigator.of(context);
      final parentCtx = nav.context;
      nav.pop(true);
      if (parentCtx.mounted) {
        AppFeedback.success(
          parentCtx,
          remove
              ? 'Homeroom teacher removed for Class $_selectedGrade-$_selectedSection.'
              : 'Assigned ${teacher?.name} as homeroom teacher for Class $_selectedGrade-$_selectedSection.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        AppFeedback.error(context, 'Error saving homeroom assignment: $e');
      }
    }
  }
}
