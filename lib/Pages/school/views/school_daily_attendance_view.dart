// lib/pages/school/views/school_daily_attendance_view.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../constants/school_constants.dart';
import '../../../design/design_system.dart';

class SchoolDailyAttendanceView extends StatefulWidget {
  final String branchId;
  final String editorName;
  final String userRole;

  const SchoolDailyAttendanceView({
    super.key,
    required this.branchId,
    this.editorName = 'School Admin',
    this.userRole = 'School Admin',
  });

  @override
  State<SchoolDailyAttendanceView> createState() => _SchoolDailyAttendanceViewState();
}

class _SchoolDailyAttendanceViewState extends State<SchoolDailyAttendanceView> {
  DateTime _selectedDate = DateTime.now();
  String _selectedGradeFilter = 'All';
  bool _isSaving = false;
  final Map<String, Map<String, dynamic>> _localChanges = {};
  bool? _localAllowStudentLeave;

  List<String> _gradeOptions = [];

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);
  bool get _isHighestAuthority => SchoolAuthHelper.isHighestAuthority(widget.userRole);

  @override
  void initState() {
    super.initState();
    _initGradeFilters();
  }

  @override
  void didUpdateWidget(covariant SchoolDailyAttendanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userRole != widget.userRole ||
        oldWidget.editorName != widget.editorName ||
        oldWidget.branchId != widget.branchId) {
      _initGradeFilters();
    }
  }

  void _initGradeFilters() {
    if (_isTeacher) {
      // Teacher can ONLY access their assigned grades / homeroom
      final assigned = SchoolAuthHelper.getTeacherAssignedGrades(
        widget.branchId,
        widget.userRole,
        widget.editorName,
      );
      if (assigned.isNotEmpty) {
        _gradeOptions = assigned;
        if (!_gradeOptions.contains(_selectedGradeFilter)) {
          _selectedGradeFilter = _gradeOptions.first;
        }
      } else {
        _gradeOptions = [];
        _selectedGradeFilter = 'Unassigned';
      }
    } else {
      // Admins, Principals, HQ Manager, Chairman can select any grade
      _gradeOptions = SchoolConstants.filterGrades;
      if (_selectedGradeFilter == 'Unassigned') {
        _selectedGradeFilter = 'All';
      }
    }
  }

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
            Text('Unsaved Attendance Edits'),
          ],
        ),
        content: const Text(
          'You have unsaved attendance edits for this date. If you leave now, these changes will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay & Continue Editing'),
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

  void _markAll(String status, List<Map<String, dynamic>> students) {
    for (final s in students) {
      final sId = s['id']?.toString() ?? '';
      if (sId.isNotEmpty) {
        _localChanges[sId] = {
          'status': status,
          'uniform': _localChanges[sId]?['uniform'] ?? true,
          'remarks': _localChanges[sId]?['remarks'] ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        };
      }
    }
    setState(() {});
  }

  Future<void> _saveAttendance(Map<String, dynamic> currentEntries) async {
    if (_localChanges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No new attendance changes to save.'),
          duration: Duration(seconds: 1),
        ),
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
      await SchoolLocalStorage.saveDailyLog(
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
            content: Text('Attendance successfully saved for $dateKey!'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: SchoolTheme.statusAbsent,
            content: Text('Error saving attendance: $e'),
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
    final isMobile = GBreakpoint.isMobile(context);

    // If teacher has no assigned class
    if (_isTeacher && _gradeOptions.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: SchoolTheme.radius20,
            border: Border.all(color: SchoolTheme.borderLight),
            boxShadow: SchoolTheme.cardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF3C7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.assignment_ind_rounded, size: 40, color: Color(0xFFD97706)),
              ),
              const SizedBox(height: 20),
              const Text(
                'Homeroom Class Required',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: SchoolTheme.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Logged in as @${widget.editorName}. You are not currently assigned to a homeroom class. Teachers can only view and mark attendance for their assigned class. Please contact your School Principal or Admin to assign your homeroom class.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: SchoolTheme.textMid, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    final bool effectiveAllowLeave = _localAllowStudentLeave ?? true;

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
            // Executive Leave Toggle Banner (Highest Authority only)
            if (_isHighestAuthority) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: effectiveAllowLeave ? const Color(0xFFFEF3C7) : const Color(0xFFEEF2FF),
                child: Row(
                  children: [
                    Icon(
                      effectiveAllowLeave ? Icons.event_available_rounded : Icons.event_busy_rounded,
                      color: effectiveAllowLeave ? const Color(0xFFD97706) : SchoolTheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        effectiveAllowLeave
                            ? '👑 Executive Control: Student Leave Option is Active for all staff.'
                            : '👑 Executive Control: Student Leave Option is Disabled for all staff.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: effectiveAllowLeave ? const Color(0xFF92400E) : SchoolTheme.primaryDark,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final newAllow = !effectiveAllowLeave;
                        setState(() => _localAllowStudentLeave = newAllow);
                        await FirebaseFirestore.instance
                            .collection('branches')
                            .doc(widget.branchId)
                            .collection('school_config')
                            .doc('current')
                            .set({'allowStudentLeave': newAllow}, SetOptions(merge: true));
                      },
                      icon: Icon(effectiveAllowLeave ? Icons.block_rounded : Icons.check_circle_rounded, size: 14),
                      label: Text(effectiveAllowLeave ? 'Disable Leave' : 'Enable Leave', style: const TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
                        foregroundColor: effectiveAllowLeave ? const Color(0xFFE11D48) : SchoolTheme.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Action & Filter Bar
            Container(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 12),
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
                  // Date Picker & Class Filter
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Date Selector
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now().add(const Duration(days: 30)),
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
                              const Icon(Icons.calendar_month_rounded, color: SchoolTheme.primary, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                DateFormat('dd MMM yyyy').format(_selectedDate),
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

                      // Grade / Class Filter
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: SchoolTheme.borderLight),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedGradeFilter,
                            icon: const Icon(Icons.arrow_drop_down_rounded, color: SchoolTheme.textMid),
                            items: _gradeOptions.map((g) {
                              return DropdownMenuItem(
                                value: g,
                                child: Text(
                                  g == 'All' ? 'All Classes' : 'Grade: $g',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                ),
                              );
                            }).toList(),
                            onChanged: (v) {
                              if (v != null && v != _selectedGradeFilter) {
                                setState(() {
                                  _selectedGradeFilter = v;
                                  _localChanges.clear();
                                });
                              }
                            },
                          ),
                        ),
                      ),

                      if (_isTeacher)
                        SchoolBadge(
                          label: 'Assigned Class: $_selectedGradeFilter',
                          color: SchoolTheme.primary,
                          fontSize: 11,
                        ),
                    ],
                  ),

                  // Actions: Mark All Present & Save Log
                  StreamBuilder<List<Map<String, dynamic>>>(
                    stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
                    builder: (context, snapshot) {
                      final allStudents = (snapshot.data ?? [])
                          .where((s) => (s['status'] ?? 'active') == 'active')
                          .toList();

                      final filteredStudents = _selectedGradeFilter == 'All'
                          ? allStudents
                          : allStudents.where((s) => s['grade'] == _selectedGradeFilter).toList();

                      return StreamBuilder<Map<String, dynamic>?>(
                        stream: SchoolLocalStorage.streamLogCached(widget.branchId, dateKey),
                        builder: (context, logSnap) {
                          final currentEntries = (logSnap.data?['entries'] as Map?) ?? {};
                          final hasChanges = _localChanges.isNotEmpty;

                          return Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: filteredStudents.isEmpty
                                    ? null
                                    : () => _markAll('present', filteredStudents),
                                icon: const Icon(Icons.done_all_rounded, size: 15),
                                label: const Text('Mark All Present', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: SchoolTheme.statusPresent,
                                  side: const BorderSide(color: SchoolTheme.statusPresent),
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

            // Attendance List
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
                builder: (context, snapshot) {
                  final allStudents = (snapshot.data ?? [])
                      .where((s) => (s['status'] ?? 'active') == 'active')
                      .toList();

                  // Teacher Data Isolation:
                  // A teacher can ONLY see students belonging to their assigned class(es)!
                  List<Map<String, dynamic>> visibleStudents;
                  if (_isTeacher) {
                    visibleStudents = allStudents.where((s) {
                      final g = (s['grade'] ?? '').toString().trim();
                      return _gradeOptions.contains(g) &&
                          (_selectedGradeFilter == 'All' || g == _selectedGradeFilter);
                    }).toList();
                  } else {
                    visibleStudents = _selectedGradeFilter == 'All'
                        ? allStudents
                        : allStudents.where((s) => s['grade'] == _selectedGradeFilter).toList();
                  }

                  // Sort by roll number or name
                  visibleStudents.sort((a, b) {
                    final rA = int.tryParse((a['rollNo'] ?? '').toString()) ?? 999999;
                    final rB = int.tryParse((b['rollNo'] ?? '').toString()) ?? 999999;
                    return rA.compareTo(rB);
                  });

                  if (visibleStudents.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_off_rounded, size: 56, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text(
                            _isTeacher
                                ? 'No students enrolled in your assigned class ($_selectedGradeFilter).'
                                : 'No students found for class filter: $_selectedGradeFilter',
                            style: const TextStyle(color: SchoolTheme.textMid, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    );
                  }

                  return StreamBuilder<Map<String, dynamic>?>(
                    stream: SchoolLocalStorage.streamLogCached(widget.branchId, dateKey),
                    builder: (context, logSnap) {
                      final currentEntries = (logSnap.data?['entries'] as Map?) ?? {};

                      return ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleStudents.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final student = visibleStudents[index];
                          final sId = student['id']?.toString() ?? '';
                          final name = student['name']?.toString() ?? 'Student';
                          final rollNo = student['rollNo']?.toString() ?? '-';
                          final grade = student['grade']?.toString() ?? '-';
                          final section = student['section']?.toString() ?? 'A';

                          final savedEntry = currentEntries[sId] as Map?;
                          final localEntry = _localChanges[sId];

                          final status = (localEntry?['status'] ?? savedEntry?['status'] ?? 'unmarked')
                              .toString()
                              .toLowerCase();
                          final bool uniform = localEntry?['uniform'] ?? savedEntry?['uniform'] ?? true;

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: SchoolTheme.radius14,
                              border: Border.all(
                                color: _localChanges.containsKey(sId)
                                    ? SchoolTheme.primary.withValues(alpha: 0.5)
                                    : SchoolTheme.borderLight,
                                width: _localChanges.containsKey(sId) ? 1.5 : 1.0,
                              ),
                              boxShadow: SchoolTheme.cardShadow,
                            ),
                            child: Row(
                              children: [
                                // Roll Number Badge
                                Container(
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: SchoolTheme.getGradeColor(grade).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    rollNo,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: SchoolTheme.getGradeColor(grade),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),

                                // Student Name & Grade
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
                                            'Grade $grade - Sec $section',
                                            style: const TextStyle(color: SchoolTheme.textMuted, fontSize: 11.5),
                                          ),
                                          const SizedBox(width: 8),
                                          InkWell(
                                            onTap: () {
                                              setState(() {
                                                _localChanges[sId] = {
                                                  'status': status == 'unmarked' ? 'present' : status,
                                                  'uniform': !uniform,
                                                  'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                                  'timestamp': DateTime.now().toIso8601String(),
                                                };
                                              });
                                            },
                                            child: Text(
                                              uniform ? '• Uniform OK' : '• Uniform Viol.',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: uniform ? SchoolTheme.statusPresent : SchoolTheme.statusAbsent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),

                                // Attendance Selection Chips (Present, Absent, Leave)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildStatusButton(
                                      label: 'P',
                                      tooltip: 'Present',
                                      isSelected: status == 'present',
                                      activeColor: SchoolTheme.statusPresent,
                                      onTap: () => setState(() {
                                        _localChanges[sId] = {
                                          'status': 'present',
                                          'uniform': uniform,
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
                                        _localChanges[sId] = {
                                          'status': 'absent',
                                          'uniform': uniform,
                                          'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                          'timestamp': DateTime.now().toIso8601String(),
                                        };
                                      }),
                                    ),
                                    if (effectiveAllowLeave) ...[
                                      const SizedBox(width: 6),
                                      _buildStatusButton(
                                        label: 'L',
                                        tooltip: 'Leave',
                                        isSelected: status == 'leave',
                                        activeColor: SchoolTheme.statusLeave,
                                        onTap: () => setState(() {
                                          _localChanges[sId] = {
                                            'status': 'leave',
                                            'uniform': uniform,
                                            'remarks': localEntry?['remarks'] ?? savedEntry?['remarks'] ?? '',
                                            'timestamp': DateTime.now().toIso8601String(),
                                          };
                                        }),
                                      ),
                                    ],
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
