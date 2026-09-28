// lib/pages/school/views/school_grading_view.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../services/image_upload_service.dart';
import '../models/school_grade.dart';
import '../models/school_student.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../constants/school_constants.dart';
import '../../../design/design_system.dart';

class SchoolGradingView extends StatefulWidget {
  final String branchId;
  final String userRole;
  final String userName;

  const SchoolGradingView({
    super.key,
    required this.branchId,
    required this.userRole,
    required this.userName,
  });

  @override
  State<SchoolGradingView> createState() => _SchoolGradingViewState();
}

class _SchoolGradingViewState extends State<SchoolGradingView> {
  String _selectedGrade = '9th';
  String _selectedSection = 'A';
  String _selectedSubject = 'Mathematics';
  String _selectedExamType = 'Midterm';
  String _selectedTerm = 'Term 1';
  double _defaultTotalMarks = 100.0;

  String? _attachmentUrl;
  String? _attachmentName;
  String? _attachmentType;

  final Map<String, TextEditingController> _marksCtrls = {};
  final Map<String, TextEditingController> _remarksCtrls = {};
  bool _isSaving = false;

  List<String> _grades = SchoolConstants.grades;
  final List<String> _sections = ['A', 'B', 'C'];
  List<String> _subjects = [
    'Mathematics',
    'English',
    'Urdu',
    'Islamiyat',
    'Pakistan Studies',
    'General Science',
    'Physics',
    'Chemistry',
    'Biology',
    'Computer Science',
    'Computer Studies & Graphics',
    'Fine Arts',
    'Civics & Economics',
    'General Mathematics',
    'Social Studies',
    'Nazra Quran',
  ];
  final List<String> _examTypes = ['Quiz', 'Assignment', 'Midterm', 'Final'];
  final List<String> _terms = ['Term 1', 'Term 2', 'Final Term'];

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);

  @override
  void initState() {
    super.initState();
    _initTeacherFilters();
  }

  @override
  void didUpdateWidget(covariant SchoolGradingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userRole != widget.userRole ||
        oldWidget.userName != widget.userName ||
        oldWidget.branchId != widget.branchId) {
      _initTeacherFilters();
    }
  }

  void _initTeacherFilters() {
    if (_isTeacher) {
      final assignedGrades = SchoolAuthHelper.getTeacherAssignedGrades(
        widget.branchId,
        widget.userRole,
        widget.userName,
      );
      final assignedSubjects = SchoolAuthHelper.getTeacherAssignedSubjects(
        widget.branchId,
        widget.userRole,
        widget.userName,
      );

      if (assignedGrades.isNotEmpty) {
        _grades = assignedGrades;
        if (!_grades.contains(_selectedGrade)) {
          _selectedGrade = _grades.first;
        }
      }
      if (assignedSubjects.isNotEmpty) {
        _subjects = assignedSubjects;
        if (!_subjects.contains(_selectedSubject)) {
          _selectedSubject = _subjects.first;
        }
      }
    } else {
      _grades = SchoolConstants.grades;
    }
  }

  @override
  void dispose() {
    for (final c in _marksCtrls.values) {
      c.dispose();
    }
    for (final c in _remarksCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isTeacher && _grades.isEmpty) {
      return const SchoolAccessDenied(
        title: 'Grading Access Restricted',
        message: 'You have not been assigned any classes for grade entry. Teachers can only enter and view grades for their assigned classes and subjects. Please contact your Principal or Admin.',
      );
    }
    final isAdmin = !widget.userRole.toLowerCase().contains('teacher') ||
        widget.userRole.toLowerCase().contains('admin') ||
        widget.userRole.toLowerCase().contains('principal');

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
      builder: (context, studentSnapshot) {
        final rawStudents = studentSnapshot.data ?? [];
        final enrolledStudents = rawStudents
            .map((m) => SchoolStudent.fromMap(m['id'] ?? '', m))
            .where((s) => s.grade == _selectedGrade && (s.section == _selectedSection || _selectedSection == 'All'))
            .toList();

        return Column(
          children: [
            // Filter & Controls Bar with Attach Excel/PDF button
            _buildFilterBar(enrolledStudents),

            // Dynamic Main View Content
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: SchoolLocalStorage.streamGradesCached(widget.branchId),
                builder: (context, gradeSnapshot) {
                  final rawGrades = gradeSnapshot.data ?? [];
                  final allGrades = rawGrades.map((m) => SchoolGrade.fromMap(m['id'] ?? '', m)).toList();

                  // Filter grades matching current class, subject, exam type, term
                  final currentExamGrades = allGrades.where((g) =>
                      g.grade == _selectedGrade &&
                      g.subject == _selectedSubject &&
                      g.examType == _selectedExamType &&
                      g.term == _selectedTerm).toList();

                  final gradeMap = {for (var g in currentExamGrades) g.studentId: g};

                  // KPI Summary Data
                  double classTotalPercentage = 0;
                  int gradedCount = 0;
                  double highestScore = 0;
                  double lowestScore = 100;
                  int passCount = 0;

                  for (final g in currentExamGrades) {
                    if (g.totalMarks > 0) {
                      final pct = g.percentage;
                      classTotalPercentage += pct;
                      gradedCount++;
                      if (pct > highestScore) highestScore = pct;
                      if (pct < lowestScore) lowestScore = pct;
                      if (pct >= 50) passCount++;
                    }
                  }
                  final classAvg = gradedCount > 0 ? classTotalPercentage / gradedCount : 0.0;
                  final passRate = gradedCount > 0 ? (passCount / gradedCount) * 100 : 0.0;

                  return Column(
                    children: [
                      // Overview KPI Header Bar
                      _buildKPIHeader(
                        classAvg: classAvg,
                        gradedCount: gradedCount,
                        totalStudents: enrolledStudents.length,
                        highestScore: gradedCount > 0 ? highestScore : 0,
                        passRate: passRate,
                      ),

                      // Tabular Student Marks List
                      Expanded(
                        child: enrolledStudents.isEmpty
                            ? _buildEmptyState()
                            : ListView.separated(
                                padding: const EdgeInsets.all(16),
                                itemCount: enrolledStudents.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final student = enrolledStudents[index];
                                  final existingGrade = gradeMap[student.id];

                                  return _buildStudentGradeRow(
                                    student: student,
                                    existingGrade: existingGrade,
                                    isAdmin: isAdmin,
                                    allGrades: allGrades,
                                  );
                                },
                              ),
                      ),

                      // Batch Save Footer Action Bar
                      if (enrolledStudents.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                          ),
                          child: Row(
                            children: [
                              Text(
                                'Subject: $_selectedSubject • Exam: $_selectedExamType ($_selectedTerm)',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                              ),
                              const Spacer(),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: SchoolTheme.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: SchoolTheme.radius12),
                                ),
                                icon: _isSaving
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.save_rounded, size: 18),
                                label: Text(_isSaving ? 'Saving Marks…' : 'Save Class Marks'),
                                onPressed: _isSaving ? null : () => _saveAllMarks(enrolledStudents, gradeMap),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndProcessAttachment(List<SchoolStudent> enrolledStudents) async {
    try {
      final fileResult = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls', 'csv', 'pdf', 'png', 'jpg', 'jpeg'],
        withData: true,
      );

      if (fileResult == null || fileResult.files.isEmpty) return;

      final file = fileResult.files.first;
      final fileName = file.name;
      final ext = file.extension?.toLowerCase() ?? '';

      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) return;

      final b64 = base64Encode(bytes);
      final mime = ext == 'pdf'
          ? 'application/pdf'
          : (['xlsx', 'xls', 'csv'].contains(ext)
              ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
              : 'image/jpeg');
      final dataUri = 'data:$mime;base64,$b64';

      int autoFilledCount = 0;

      if (['xlsx', 'xls'].contains(ext)) {
        try {
          final excel = xl.Excel.decodeBytes(bytes);
          for (final table in excel.tables.keys) {
            final sheet = excel.tables[table];
            if (sheet == null) continue;
            for (final row in sheet.rows) {
              if (row.isEmpty) continue;
              final rowVals = row.map((cell) => cell?.value?.toString().trim() ?? '').toList();
              for (final student in enrolledStudents) {
                final rollMatch = rowVals.any((v) => v.isNotEmpty && (v == student.rollNo || v == 'Roll: ${student.rollNo}'));
                final nameMatch = rowVals.any((v) => v.isNotEmpty && v.toLowerCase() == student.name.toLowerCase());
                if (rollMatch || nameMatch) {
                  for (final val in rowVals) {
                    final d = double.tryParse(val);
                    if (d != null && d >= 0 && d <= 1000) {
                      _marksCtrls[student.id] ??= TextEditingController();
                      _marksCtrls[student.id]!.text = d.toStringAsFixed(d.truncateToDouble() == d ? 0 : 1);
                      autoFilledCount++;
                      break;
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          debugPrint('[SchoolGradingView] Excel parse error: $e');
        }
      }

      setState(() {
        _attachmentUrl = dataUri;
        _attachmentName = fileName;
        _attachmentType = ['xlsx', 'xls', 'csv'].contains(ext) ? 'excel' : (ext == 'pdf' ? 'pdf' : 'image');
      });

      if (mounted) {
        final msg = autoFilledCount > 0
            ? '✓ Excel parsed: Auto-filled $autoFilledCount student grades & attached $fileName'
            : '✓ Document attached: $fileName';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to attach document: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  Widget _buildFilterBar(List<SchoolStudent> enrolledStudents) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Class Dropdown
          DropdownButton<String>(
            value: _selectedGrade,
            underline: const SizedBox.shrink(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: SchoolTheme.primary),
            items: _grades.map((g) => DropdownMenuItem(value: g, child: Text('Class: $g'))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedGrade = val);
            },
          ),

          // Section Dropdown
          DropdownButton<String>(
            value: _selectedSection,
            underline: const SizedBox.shrink(),
            items: _sections.map((s) => DropdownMenuItem(value: s, child: Text('Section: $s'))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedSection = val);
            },
          ),

          // Subject Dropdown
          DropdownButton<String>(
            value: _selectedSubject,
            underline: const SizedBox.shrink(),
            items: _subjects.map((sub) => DropdownMenuItem(value: sub, child: Text(sub))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedSubject = val);
            },
          ),

          // Exam Type Dropdown
          DropdownButton<String>(
            value: _selectedExamType,
            underline: const SizedBox.shrink(),
            items: _examTypes.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedExamType = val);
            },
          ),

          // Term Dropdown
          DropdownButton<String>(
            value: _selectedTerm,
            underline: const SizedBox.shrink(),
            items: _terms.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedTerm = val);
            },
          ),

          // Max Total Marks Input
          SizedBox(
            width: 130,
            child: TextField(
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Total Marks',
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                isDense: true,
              ),
              controller: TextEditingController(text: _defaultTotalMarks.toStringAsFixed(0)),
              onChanged: (val) {
                final d = double.tryParse(val);
                if (d != null && d > 0) _defaultTotalMarks = d;
              },
            ),
          ),

          // Attach Excel / PDF Action Button
          if (_attachmentName == null)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: SchoolTheme.primary,
                side: const BorderSide(color: SchoolTheme.primary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              icon: const Icon(Icons.attach_file_rounded, size: 16),
              label: const Text('Attach Excel / PDF', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: () => _pickAndProcessAttachment(enrolledStudents),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: SchoolTheme.primaryLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: SchoolTheme.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _attachmentType == 'excel'
                        ? Icons.table_chart_rounded
                        : (_attachmentType == 'pdf' ? Icons.picture_as_pdf_rounded : Icons.insert_drive_file_rounded),
                    size: 16,
                    color: SchoolTheme.primary,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      _attachmentName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: SchoolTheme.primary),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => setState(() {
                      _attachmentUrl = null;
                      _attachmentName = null;
                      _attachmentType = null;
                    }),
                    child: const Icon(Icons.close_rounded, size: 16, color: Colors.redAccent),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKPIHeader({
    required double classAvg,
    required int gradedCount,
    required int totalStudents,
    required double highestScore,
    required double passRate,
  }) {
    final isMobile = GBreakpoint.isMobile(context);
    final avgColor = SchoolTheme.getLetterGradeColor(
      classAvg >= 90 ? 'A+' : (classAvg >= 80 ? 'A' : (classAvg >= 70 ? 'B' : (classAvg >= 60 ? 'C' : 'F'))),
    );

    final tiles = [
      _buildKPITileContent(
        label: 'Class Average',
        value: '${classAvg.toStringAsFixed(1)}%',
        valueColor: avgColor,
        icon: Icons.insights_rounded,
      ),
      _buildKPITileContent(
        label: 'Graded',
        value: '$gradedCount / $totalStudents',
        valueColor: SchoolTheme.primary,
        icon: Icons.how_to_reg_rounded,
      ),
      _buildKPITileContent(
        label: 'Highest Score',
        value: '${highestScore.toStringAsFixed(1)}%',
        valueColor: SchoolTheme.accent,
        icon: Icons.emoji_events_rounded,
      ),
      _buildKPITileContent(
        label: 'Pass Rate',
        value: '${passRate.toStringAsFixed(1)}%',
        valueColor: passRate >= 70 ? SchoolTheme.accent : SchoolTheme.statusLeave,
        icon: Icons.grade_rounded,
      ),
    ];

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: const Color(0xFFF8FAFC),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: tiles.map((t) => SizedBox(width: cardWidth, child: t)).toList(),
            );
          },
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFFF8FAFC),
      child: Row(
        children: tiles.map((t) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: t))).toList(),
      ),
    );
  }

  Widget _buildKPITileContent({
    required String label,
    required String value,
    required Color valueColor,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: SchoolTheme.radius12,
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: valueColor.withValues(alpha: 0.1),
              borderRadius: SchoolTheme.radius8,
            ),
            child: Icon(icon, color: valueColor, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: valueColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentGradeRow({
    required SchoolStudent student,
    required SchoolGrade? existingGrade,
    required bool isAdmin,
    required List<SchoolGrade> allGrades,
  }) {
    _marksCtrls.putIfAbsent(
      student.id,
      () => TextEditingController(text: existingGrade != null ? existingGrade.marksObtained.toStringAsFixed(1) : ''),
    );
    _remarksCtrls.putIfAbsent(
      student.id,
      () => TextEditingController(text: existingGrade?.remarks ?? ''),
    );

    final marksText = _marksCtrls[student.id]!.text;
    final marksNum = double.tryParse(marksText) ?? (existingGrade?.marksObtained ?? 0.0);
    final totalMarks = existingGrade?.totalMarks ?? _defaultTotalMarks;
    final pct = totalMarks > 0 ? (marksNum / totalMarks) * 100 : 0.0;

    String tempLetter = 'F';
    if (pct >= 90) {
      tempLetter = 'A+';
    } else if (pct >= 80) {
      tempLetter = 'A';
    } else if (pct >= 70) {
      tempLetter = 'B';
    } else if (pct >= 60) {
      tempLetter = 'C';
    } else if (pct >= 50) {
      tempLetter = 'D';
    }

    final letterColor = SchoolTheme.getLetterGradeColor(tempLetter);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: SchoolTheme.radius14,
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          // Student Photo Avatar
          Builder(
            builder: (context) {
              final bytes = ImageUploadService.decodeBase64ToBytes(student.photoUrl);
              if (bytes != null && bytes.isNotEmpty) {
                return CircleAvatar(
                  radius: 20,
                  backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
                  backgroundImage: MemoryImage(bytes),
                );
              } else if (student.photoUrl.startsWith('http')) {
                return CircleAvatar(
                  radius: 20,
                  backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
                  backgroundImage: NetworkImage(student.photoUrl),
                );
              }
              return CircleAvatar(
                radius: 20,
                backgroundColor: SchoolTheme.primary.withValues(alpha: 0.1),
                child: Text(
                  student.rollNo.isNotEmpty ? student.rollNo : '0',
                  style: const TextStyle(color: SchoolTheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              );
            },
          ),
          const SizedBox(width: 14),

          // Student Name & Roll
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  student.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0F172A)),
                ),
                Text(
                  'Guardian: ${student.guardianName}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),

          // Marks Input Box
          SizedBox(
            width: 110,
            child: TextField(
              controller: _marksCtrls[student.id],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Marks / $totalMarks',
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),

          // Calculated Percentage & Letter Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: letterColor.withValues(alpha: 0.12),
              borderRadius: SchoolTheme.radius8,
              border: Border.all(color: letterColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: TextStyle(color: letterColor, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: letterColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tempLetter,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Remarks Input
          Expanded(
            flex: 2,
            child: TextField(
              controller: _remarksCtrls[student.id],
              decoration: const InputDecoration(
                hintText: 'Optional remarks…',
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Report Card Icon Action
          IconButton(
            tooltip: 'Generate Report Card',
            icon: const Icon(Icons.assignment_ind_rounded, color: SchoolTheme.primary),
            onPressed: () => _openReportCardDialog(student, allGrades),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.school_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            'No students enrolled in Class $_selectedGrade (Section $_selectedSection)',
            style: const TextStyle(color: Colors.grey, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Select another grade/section or enroll new students first.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAllMarks(
    List<SchoolStudent> students,
    Map<String, SchoolGrade> existingGradesMap,
  ) async {
    setState(() => _isSaving = true);
    int savedCount = 0;

    for (final s in students) {
      final text = _marksCtrls[s.id]?.text.trim() ?? '';
      if (text.isEmpty) continue;

      final marksObtained = double.tryParse(text) ?? 0.0;
      final remarks = _remarksCtrls[s.id]?.text.trim() ?? '';
      final gradeId = existingGradesMap[s.id]?.id ??
          'GRD-${s.id}-${_selectedSubject.replaceAll(' ', '')}-$_selectedExamType-${DateTime.now().millisecondsSinceEpoch}';

      final gradeObj = SchoolGrade(
        id: gradeId,
        studentId: s.id,
        studentName: s.name,
        rollNo: s.rollNo,
        grade: s.grade,
        section: s.section,
        subject: _selectedSubject,
        examType: _selectedExamType,
        term: _selectedTerm,
        marksObtained: marksObtained,
        totalMarks: _defaultTotalMarks,
        date: DateFormat('yyyy-MM-dd').format(DateTime.now()),
        enteredBy: widget.userName,
        remarks: remarks,
        attachmentUrl: _attachmentUrl ?? existingGradesMap[s.id]?.attachmentUrl ?? '',
        attachmentName: _attachmentName ?? existingGradesMap[s.id]?.attachmentName ?? '',
        attachmentType: _attachmentType ?? existingGradesMap[s.id]?.attachmentType ?? '',
        branchId: widget.branchId,
      );

      await SchoolLocalStorage.saveGrade(
        branchId: widget.branchId,
        gradeId: gradeId,
        gradeData: gradeObj.toMap(),
      );
      savedCount++;
    }

    // Log Audit Event
    await SchoolLocalStorage.logAudit(
      branchId: widget.branchId,
      action: 'GRADE_ENTRY_BATCH',
      user: widget.userName,
      details: 'Recorded $savedCount marks for Class $_selectedGrade ($_selectedSubject • $_selectedExamType)',
    );

    setState(() => _isSaving = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Successfully saved marks for $savedCount students in Class $_selectedGrade!'),
          backgroundColor: SchoolTheme.accent,
        ),
      );
    }
  }

  void _openReportCardDialog(SchoolStudent student, List<SchoolGrade> allGrades) {
    final studentGrades = allGrades.where((g) => g.studentId == student.id && g.term == _selectedTerm).toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: SchoolTheme.radius16),
        title: Row(
          children: [
            const Icon(Icons.school_rounded, color: SchoolTheme.primary),
            const SizedBox(width: 10),
            Text('Academic Report Card — ${student.name}'),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Summary Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: SchoolTheme.primaryLight,
                  borderRadius: SchoolTheme.radius12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Roll No: ${student.rollNo} • Grade: ${student.grade} (${student.section})',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: SchoolTheme.primaryDark)),
                        Text('Guardian: ${student.guardianName} • Term: $_selectedTerm',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: SchoolTheme.primaryDark,
                        borderRadius: SchoolTheme.radius8,
                      ),
                      child: const Text('OFFICIAL EXAM REPORT',
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Subject Grades Table
              studentGrades.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: Text('No exam grades recorded yet for this term.', style: TextStyle(color: Colors.grey))),
                    )
                  : Table(
                      border: TableBorder.all(color: Colors.grey.shade300, borderRadius: SchoolTheme.radius8),
                      columnWidths: const {
                        0: FlexColumnWidth(3),
                        1: FlexColumnWidth(2),
                        2: FlexColumnWidth(2),
                        3: FlexColumnWidth(2),
                        4: FlexColumnWidth(2),
                      },
                      children: [
                        TableRow(
                          decoration: BoxDecoration(color: Colors.grey.shade100),
                          children: const [
                            Padding(padding: EdgeInsets.all(8), child: Text('Subject', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8), child: Text('Marks', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8), child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8), child: Text('Grade', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8), child: Text('GPA', style: TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        ),
                        ...studentGrades.map((g) => TableRow(
                              children: [
                                Padding(padding: const EdgeInsets.all(8), child: Text(g.subject)),
                                Padding(padding: const EdgeInsets.all(8), child: Text(g.marksObtained.toStringAsFixed(1))),
                                Padding(padding: const EdgeInsets.all(8), child: Text(g.totalMarks.toStringAsFixed(0))),
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    g.letterGrade,
                                    style: TextStyle(
                                      color: SchoolTheme.getLetterGradeColor(g.letterGrade),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Padding(padding: const EdgeInsets.all(8), child: Text(g.gpaPoint.toStringAsFixed(1))),
                              ],
                            )),
                      ],
                    ),

              // Attached Marksheet / Exam Document
              if (studentGrades.any((g) => g.attachmentName.isNotEmpty)) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: SchoolTheme.primaryLight,
                    borderRadius: SchoolTheme.radius8,
                    border: Border.all(color: SchoolTheme.primary.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.attach_file_rounded, color: SchoolTheme.primary, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Attached Marksheet / Exam File: ${studentGrades.firstWhere((g) => g.attachmentName.isNotEmpty).attachmentName}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: SchoolTheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: SchoolTheme.primary, foregroundColor: Colors.white),
            icon: const Icon(Icons.print_rounded, size: 16),
            label: const Text('Print Report Card'),
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Preparing printable report card PDF…')),
              );
            },
          ),
        ],
      ),
    );
  }
}
