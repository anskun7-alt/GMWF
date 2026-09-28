// lib/pages/school/views/school_teacher_attendance_view.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';

class SchoolTeacherAttendanceView extends StatefulWidget {
  final String branchId;
  final String editorName;
  final String userRole;

  const SchoolTeacherAttendanceView({
    super.key,
    required this.branchId,
    this.editorName = 'School Admin',
    this.userRole = 'School Admin',
  });

  @override
  State<SchoolTeacherAttendanceView> createState() => _SchoolTeacherAttendanceViewState();
}

class _SchoolTeacherAttendanceViewState extends State<SchoolTeacherAttendanceView> {
  DateTime _selectedDate = DateTime.now();
  String _selectedDeptFilter = 'All';
  bool _isSaving = false;
  final Map<String, Map<String, dynamic>> _localChanges = {};

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);

  final List<String> _departments = [
    'All',
    'Science & IT',
    'Mathematics',
    'Languages & English',
    'Social Studies & Humanities',
    'Arts & Commerce',
    'Primary Education',
    'Administration',
  ];

  Future<bool> _confirmDiscardChanges() async {
    if (_localChanges.isEmpty) return true;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B)),
            SizedBox(width: 10),
            Text('Unsaved Faculty Attendance Edits'),
          ],
        ),
        content: const Text(
          'You have unsaved faculty attendance edits for this date. If you leave now, these changes will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay & Edit'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE11D48),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard Changes'),
          ),
        ],
      ),
    );
    return confirm ?? false;
  }

  void _markAllPresent(List<Map<String, dynamic>> teachers) {
    for (final t in teachers) {
      final tId = t['id']?.toString() ?? '';
      if (tId.isNotEmpty) {
        _localChanges[tId] = {
          'status': 'present',
          'checkIn': DateFormat('hh:mm a').format(DateTime.now()),
          'remarks': _localChanges[tId]?['remarks'] ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        };
      }
    }
    setState(() {});
  }

  Future<void> _saveAttendance(Map<String, dynamic> currentEntries) async {
    if (_localChanges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No changes to save.'), duration: Duration(seconds: 1)),
      );
      return;
    }

    setState(() => _isSaving = true);
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);

    final mergedEntries = Map<String, dynamic>.from(currentEntries);
    _localChanges.forEach((k, v) {
      mergedEntries[k] = v;
    });

    try {
      await SchoolLocalStorage.saveTeacherDailyLog(
        branchId: widget.branchId,
        dateKey: dateKey,
        logEntries: mergedEntries,
        editorName: widget.editorName,
      );

      _localChanges.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: SchoolTheme.statusPresent,
            content: Text('Faculty attendance saved for $dateKey!'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: SchoolTheme.statusAbsent,
            content: Text('Error saving faculty attendance: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);

    return PopScope(
      canPop: _localChanges.isEmpty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscardChanges();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: SchoolTheme.bgLight,
        body: Column(
          children: [
            // Filter & Date Toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: SchoolTheme.borderLight)),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 10,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Left filters
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Date selector
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now().add(const Duration(days: 14)),
                          );
                          if (picked != null && picked != _selectedDate) {
                            if (await _confirmDiscardChanges()) {
                              setState(() {
                                _selectedDate = picked;
                                _localChanges.clear();
                              });
                            }
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: SchoolTheme.primaryLight,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: SchoolTheme.primary.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.calendar_today_rounded, color: SchoolTheme.primary, size: 16),
                              const SizedBox(width: 8),
                              Text(
                                DateFormat('EEEE, dd MMM yyyy').format(_selectedDate),
                                style: const TextStyle(
                                  color: SchoolTheme.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Department Filter (Admins/Principals only)
                      if (!_isTeacher)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: SchoolTheme.borderLight),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedDeptFilter,
                              icon: const Icon(Icons.arrow_drop_down_rounded, color: SchoolTheme.textMid),
                              items: _departments.map((d) {
                                return DropdownMenuItem(value: d, child: Text('Dept: $d', style: const TextStyle(fontSize: 12.5)));
                              }).toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _selectedDeptFilter = v);
                              },
                            ),
                          ),
                        )
                      else
                        const SchoolBadge(
                          label: 'My Attendance Record',
                          color: SchoolTheme.primary,
                        ),
                    ],
                  ),

                  // Right actions
                  StreamBuilder<List<Map<String, dynamic>>>(
                    stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
                    builder: (context, snapshot) {
                      final teachers = snapshot.data ?? [];
                      return StreamBuilder<Map<String, dynamic>?>(
                        stream: SchoolLocalStorage.streamTeacherLogCached(widget.branchId, dateKey),
                        builder: (context, logSnap) {
                          final currentEntries = (logSnap.data?['entries'] as Map?) ?? {};
                          final hasChanges = _localChanges.isNotEmpty;

                          return Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (!_isTeacher)
                                OutlinedButton.icon(
                                  onPressed: teachers.isEmpty ? null : () => _markAllPresent(teachers),
                                  icon: const Icon(Icons.done_all_rounded, size: 15),
                                  label: const Text('Mark All Present', style: TextStyle(fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: SchoolTheme.primary,
                                    side: const BorderSide(color: SchoolTheme.primary),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ElevatedButton.icon(
                                onPressed: (_isSaving || !hasChanges)
                                    ? null
                                    : () => _saveAttendance(Map<String, dynamic>.from(currentEntries)),
                                icon: _isSaving
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                      )
                                    : const Icon(Icons.save_rounded, size: 15),
                                label: Text(
                                  hasChanges ? 'Save Changes (${_localChanges.length})' : 'Saved',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: SchoolTheme.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  elevation: 0,
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),

            // Teachers List Stream
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: SchoolLocalStorage.streamTeachersCached(widget.branchId),
                builder: (context, snapshot) {
                  final allTeachers = snapshot.data ?? [];

                  // Strict Teacher Isolation:
                  // A teacher CANNOT see other teachers' attendance!
                  List<Map<String, dynamic>> visibleTeachers;
                  if (_isTeacher) {
                    final myRecord = SchoolAuthHelper.findTeacherRecord(widget.branchId, widget.editorName);
                    if (myRecord != null) {
                      visibleTeachers = [myRecord];
                    } else {
                      visibleTeachers = allTeachers.where((t) {
                        final n = (t['name'] ?? '').toString().toLowerCase().trim();
                        final e = (t['email'] ?? '').toString().toLowerCase().trim();
                        return n == widget.editorName.toLowerCase().trim() ||
                            e == widget.editorName.toLowerCase().trim();
                      }).toList();
                    }
                  } else {
                    visibleTeachers = _selectedDeptFilter == 'All'
                        ? allTeachers
                        : allTeachers.where((t) => t['department'] == _selectedDeptFilter).toList();
                  }

                  if (visibleTeachers.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_off_rounded, size: 56, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text(
                            _isTeacher
                                ? 'No faculty record found matching username @${widget.editorName}.'
                                : 'No faculty records found for department: $_selectedDeptFilter',
                            style: const TextStyle(color: SchoolTheme.textMid, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    );
                  }

                  return StreamBuilder<Map<String, dynamic>?>(
                    stream: SchoolLocalStorage.streamTeacherLogCached(widget.branchId, dateKey),
                    builder: (context, logSnap) {
                      final currentEntries = (logSnap.data?['entries'] as Map?) ?? {};

                      return ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleTeachers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final teacher = visibleTeachers[index];
                          final tId = teacher['id']?.toString() ?? '';
                          final name = teacher['name']?.toString() ?? 'Faculty Member';
                          final designation = teacher['designation']?.toString() ?? 'Teacher';
                          final department = teacher['department']?.toString() ?? 'Academics';

                          final savedEntry = currentEntries[tId] as Map?;
                          final localEntry = _localChanges[tId];

                          final status = (localEntry?['status'] ?? savedEntry?['status'] ?? 'unmarked')
                              .toString()
                              .toLowerCase();
                          final checkIn = (localEntry?['checkIn'] ?? savedEntry?['checkIn'] ?? '').toString();

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: SchoolTheme.radius14,
                              border: Border.all(
                                color: _localChanges.containsKey(tId)
                                    ? SchoolTheme.primary.withValues(alpha: 0.5)
                                    : SchoolTheme.borderLight,
                                width: _localChanges.containsKey(tId) ? 1.5 : 1.0,
                              ),
                              boxShadow: SchoolTheme.cardShadow,
                            ),
                            child: Row(
                              children: [
                                // Faculty Avatar
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: SchoolTheme.primaryLight,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: SchoolTheme.primary.withValues(alpha: 0.2)),
                                  ),
                                  child: const Icon(Icons.person_rounded, color: SchoolTheme.primary, size: 22),
                                ),
                                const SizedBox(width: 14),

                                // Details
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: SchoolTheme.textDark,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text(
                                            '$designation • $department',
                                            style: const TextStyle(color: SchoolTheme.textMuted, fontSize: 11.5),
                                          ),
                                          if (checkIn.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              '• In: $checkIn',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: SchoolTheme.statusPresent,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),

                                // Status Chips (P, A, L)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildStatusButton(
                                      label: 'P',
                                      tooltip: 'Present',
                                      isSelected: status == 'present',
                                      activeColor: SchoolTheme.statusPresent,
                                      onTap: () => setState(() {
                                        _localChanges[tId] = {
                                          'status': 'present',
                                          'checkIn': checkIn.isNotEmpty ? checkIn : DateFormat('hh:mm a').format(DateTime.now()),
                                          'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                          'timestamp': DateTime.now().toIso8601String(),
                                        };
                                      }),
                                    ),
                                    const SizedBox(width: 6),
                                    _buildStatusButton(
                                      label: 'A',
                                      tooltip: 'Absent',
                                      isSelected: status == 'absent',
                                      activeColor: SchoolTheme.statusAbsent,
                                      onTap: () => setState(() {
                                        _localChanges[tId] = {
                                          'status': 'absent',
                                          'checkIn': '',
                                          'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                          'timestamp': DateTime.now().toIso8601String(),
                                        };
                                      }),
                                    ),
                                    const SizedBox(width: 6),
                                    _buildStatusButton(
                                      label: 'L',
                                      tooltip: 'On Leave',
                                      isSelected: status == 'leave',
                                      activeColor: SchoolTheme.statusLeave,
                                      onTap: () => setState(() {
                                        _localChanges[tId] = {
                                          'status': 'leave',
                                          'checkIn': '',
                                          'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                          'timestamp': DateTime.now().toIso8601String(),
                                        };
                                      }),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusButton({
    required String label,
    required String tooltip,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? activeColor : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? activeColor : SchoolTheme.borderLight,
              width: 1.2,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : SchoolTheme.textMid,
            ),
          ),
        ),
      ),
    );
  }
}
