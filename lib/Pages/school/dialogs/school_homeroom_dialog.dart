// lib/pages/school/dialogs/school_homeroom_dialog.dart

import 'package:flutter/material.dart';
import '../models/school_teacher.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../constants/school_constants.dart';
import '../../../widgets/app_feedback.dart';

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
  SchoolTeacher? _selectedTeacher;
  bool _isSaving = false;

  final List<String> _grades = SchoolConstants.grades;
  final List<String> _sections = ['A', 'B', 'C'];

  @override
  void initState() {
    super.initState();
    _selectedGrade = widget.initialGrade;
    _selectedSection = widget.initialSection;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
          builder: (context, snapshot) {
            final rawTeachers = snapshot.data ?? [];
            final activeTeachers = rawTeachers
                .map((m) => SchoolTeacher.fromMap(m['id'] ?? '', m))
                .where((t) => t.status == 'active')
                .toList();

            final currentAssignment = SchoolLocalStorage.getHomeroomAssignmentCached(
              widget.branchId,
              _selectedGrade,
              _selectedSection,
            );
            final currentTeacherId = currentAssignment?['teacherId']?.toString() ?? '';
            final currentTeacherName = currentAssignment?['teacherName']?.toString() ?? 'Unassigned';

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4965).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.supervisor_account_rounded, color: Color(0xFF1B4965), size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'Assign / Transfer Homeroom Teacher',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                          Text(
                            'Manage Class Incharge responsibility & attendance permissions',
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.grey),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                  ],
                ),

                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 16),

                // Select Class & Section
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Target Grade / Class:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedGrade,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            ),
                            items: _grades.map((g) => DropdownMenuItem(value: g, child: Text('Grade $g'))).toList(),
                            onChanged: (v) {
                              if (v != null) setState(() { _selectedGrade = v; _selectedTeacher = null; });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Section:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedSection,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            ),
                            items: _sections.map((s) => DropdownMenuItem(value: s, child: Text('Section $s'))).toList(),
                            onChanged: (v) {
                              if (v != null) setState(() { _selectedSection = v; _selectedTeacher = null; });
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Current Homeroom Teacher Status Banner
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: currentTeacherId.isNotEmpty ? SchoolTheme.primaryLight : SchoolTheme.statusLeaveBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: currentTeacherId.isNotEmpty ? SchoolTheme.primary.withValues(alpha: 0.3) : SchoolTheme.statusLeave.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        currentTeacherId.isNotEmpty ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                        color: currentTeacherId.isNotEmpty ? SchoolTheme.primary : SchoolTheme.statusLeave,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          currentTeacherId.isNotEmpty
                              ? 'Currently Assigned: $currentTeacherName'
                              : 'No Homeroom Teacher assigned for $_selectedGrade - Section $_selectedSection',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: currentTeacherId.isNotEmpty ? SchoolTheme.primary : SchoolTheme.statusLeave,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Teacher Selector Dropdown
                const Text('Assign / Transfer To Teacher:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                const SizedBox(height: 6),
                DropdownButtonFormField<SchoolTeacher>(
                  value: _selectedTeacher,
                  hint: const Text('Select a faculty member...'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  items: activeTeachers.map((t) {
                    final homeroomInfo = t.isHomeroom ? ' (Currently: ${t.homeroomClass})' : '';
                    return DropdownMenuItem<SchoolTeacher>(
                      value: t,
                      child: Text('${t.name} — ${t.employeeId} $homeroomInfo', overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() => _selectedTeacher = val);
                  },
                ),

                const SizedBox(height: 24),

                // Action Buttons
                Row(
                  children: [
                    if (currentTeacherId.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFDC4A4A),
                          side: const BorderSide(color: Color(0xFFDC4A4A)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.person_remove_rounded, size: 18),
                        label: const Text('Remove Assignment'),
                        onPressed: _isSaving ? null : () => _saveAssignment(remove: true),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SchoolTheme.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: _isSaving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.check_rounded, size: 18),
                      label: Text(_isSaving ? 'Saving...' : 'Confirm Assignment'),
                      onPressed: (_isSaving || _selectedTeacher == null) ? null : () => _saveAssignment(remove: false),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _saveAssignment({bool remove = false}) async {
    setState(() => _isSaving = true);
    try {
      if (remove) {
        await SchoolLocalStorage.assignHomeroomTeacher(
          branchId: widget.branchId,
          grade: _selectedGrade,
          section: _selectedSection,
          teacherId: null,
          teacherName: null,
          editorName: widget.editorName,
        );
      } else if (_selectedTeacher != null) {
        await SchoolLocalStorage.assignHomeroomTeacher(
          branchId: widget.branchId,
          grade: _selectedGrade,
          section: _selectedSection,
          teacherId: _selectedTeacher!.id,
          teacherName: _selectedTeacher!.name,
          editorName: widget.editorName,
        );
      }

      if (mounted) {
        Navigator.pop(context, true);
        AppFeedback.showSuccess(
          context,
          remove
              ? 'Homeroom teacher assignment removed for $_selectedGrade - Section $_selectedSection.'
              : 'Successfully assigned ${_selectedTeacher?.name} as Homeroom Teacher for $_selectedGrade - Section $_selectedSection.',
          subtitle: 'Saved locally • Syncing to cloud',
        );
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, 'Error saving homeroom assignment: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
