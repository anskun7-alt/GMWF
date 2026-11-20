// lib/pages/school/views/school_grading_view.dart
//
// School Grading & Report Cards (School ERP plan §3.6, Phase 5).
// Rebuilt on the desktop ERP kit (gmwf_ui + SchoolErp):
//   • Marks entry  — class/section (A–D)/subject/exam/term grid, live % & grade,
//                    strict marks <= total validation, Excel auto-fill, single
//                    exam-level attachment (stored once, never copied per student).
//   • Report cards — ranked term results table + detail panel with subject
//                    breakdown, bimonthly compulsory event flags, and real
//                    printable PDF report cards (single or whole class).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../services/local_storage_service.dart';
import '../../../utils/debounced_box_listenable.dart';
import '../constants/school_constants.dart';
import '../events/school_event_service.dart';
import '../grades/grade_report_pdf.dart';
import '../grades/grade_rules.dart';
import '../grades/school_grade_service.dart';
import '../models/school_grade.dart';
import '../models/school_student.dart';
import '../students/school_student_service.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';
import 'school_student_management_view.dart' show StudentAvatar;

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

enum _GradingTab { marks, reports }

class _SchoolGradingViewState extends State<SchoolGradingView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();

  _GradingTab _tab = _GradingTab.marks;
  String _selectedGrade = SchoolConstants.grades.first;
  String _selectedSection = SchoolConstants.sections.first;
  String _reportSection = 'All';
  String _selectedSubject = 'Mathematics';
  String _selectedExamType = GradeRules.examTypes[2]; // Midterm
  String _selectedTerm = GradeRules.terms.first;
  String _reportExamFilter = 'All';
  double _totalMarks = 100.0;
  bool _isSaving = false;
  bool _isPrinting = false;
  String? _selectedReportStudentId;

  late final TextEditingController _totalMarksCtrl = TextEditingController(text: '100');
  final TextEditingController _reportSearchCtrl = TextEditingController();
  final Map<String, TextEditingController> _marksCtrls = {};
  final Map<String, TextEditingController> _remarksCtrls = {};
  Map<String, String> _rowErrors = const {};

  List<String> _grades = SchoolConstants.grades;
  List<String> _subjects = const [
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

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);
  bool get _canEnter => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole) || _isTeacher;

  String _ck(String studentId) => '$studentId|$_selectedGrade|$_selectedSection|$_selectedSubject|$_selectedExamType|$_selectedTerm';

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
      _selectedReportStudentId = null;
      _rowErrors = const {};
      _initTeacherFilters();
    }
  }

  void _initTeacherFilters() {
    if (_isTeacher) {
      final assignedGrades = SchoolAuthHelper.getTeacherAssignedGrades(widget.branchId, widget.userRole, widget.userName);
      final assignedSubjects = SchoolAuthHelper.getTeacherAssignedSubjects(widget.branchId, widget.userRole, widget.userName);
      _grades = assignedGrades;
      if (_grades.isNotEmpty && !_grades.contains(_selectedGrade)) {
        _selectedGrade = _grades.first;
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
    _totalMarksCtrl.dispose();
    _reportSearchCtrl.dispose();
    for (final c in _marksCtrls.values) {
      c.dispose();
    }
    for (final c in _remarksCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Color _letterColor(BuildContext context, String letter) {
    final c = context.comfort;
    return switch (letter) {
      'A+' || 'A' => c.success,
      'B' => c.info,
      'C' || 'D' => c.warning,
      'F' => c.danger,
      _ => c.textMuted,
    };
  }

  Future<void> _pickAttachment(List<SchoolStudent> students) async {
    try {
      final fileResult = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls', 'csv', 'pdf', 'png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (fileResult == null || fileResult.files.isEmpty) return;
      final file = fileResult.files.first;
      final ext = (file.extension ?? '').toLowerCase();
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) return;

      final mime = ext == 'pdf'
          ? 'application/pdf'
          : (['xlsx', 'xls', 'csv'].contains(ext)
              ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
              : 'image/jpeg');
      final dataUri = 'data:$mime;base64,${base64Encode(bytes)}';
      final fileType = ['xlsx', 'xls', 'csv'].contains(ext) ? 'excel' : (ext == 'pdf' ? 'pdf' : 'image');

      var autoFilled = 0;
      if (ext == 'xlsx' || ext == 'xls') {
        try {
          final excel = xl.Excel.decodeBytes(bytes);
          for (final table in excel.tables.keys) {
            final sheet = excel.tables[table];
            if (sheet == null) continue;
            for (final row in sheet.rows) {
              if (row.isEmpty) continue;
              final vals = row.map((cell) => cell?.value?.toString().trim() ?? '').toList();
              for (final s in students) {
                final match = vals.any((v) =>
                    v.isNotEmpty &&
                    (v == s.rollNo ||
                        v.toLowerCase() == s.admissionNo.toLowerCase() ||
                        v.toLowerCase() == s.name.toLowerCase()));
                if (!match) continue;
                for (final v in vals.reversed) {
                  final d = double.tryParse(v);
                  if (d != null && d >= 0 && d <= _totalMarks) {
                    final ctrl = _marksCtrls.putIfAbsent(_ck(s.id), TextEditingController.new);
                    ctrl.text = GradeRules.formatMark(d);
                    autoFilled++;
                    break;
                  }
                }
              }
            }
          }
        } catch (e) {
          debugPrint('[SchoolGradingView] Excel parse error: $e');
        }
      }

      // Store ONCE in `school_grade_attachments` (never copied onto every student row).
      await SchoolGradeService.saveAttachment(
        branchId: widget.branchId,
        grade: _selectedGrade,
        section: _selectedSection,
        subject: _selectedSubject,
        examType: _selectedExamType,
        term: _selectedTerm,
        fileName: file.name,
        fileType: fileType,
        dataUri: dataUri,
        editorName: widget.userName,
        userRole: widget.userRole,
      );

      if (!mounted) return;
      setState(() {});
      AppFeedback.success(
        context,
        autoFilled > 0
            ? 'Attached ${file.name} and auto-filled $autoFilled student marks. Review and save.'
            : 'Attached ${file.name} once for this exam.',
      );
    } catch (e) {
      if (mounted) AppFeedback.error(context, e is SchoolGradeException ? e.message : 'Could not attach file: $e');
    }
  }

  Future<void> _removeAttachment(SchoolGradeAttachment att) async {
    try {
      await SchoolGradeService.removeAttachment(
        branchId: widget.branchId,
        attachmentId: att.id,
        grade: _selectedGrade,
        subject: _selectedSubject,
        editorName: widget.userName,
        userRole: widget.userRole,
      );
      if (mounted) {
        setState(() {});
        AppFeedback.success(context, 'Attachment removed');
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e is SchoolGradeException ? e.message : '$e');
    }
  }

  Future<void> _saveAllMarks(List<SchoolStudent> students, SchoolGradeAttachment? attachment) async {
    final total = double.tryParse(_totalMarksCtrl.text.trim()) ?? _totalMarks;
    if (total <= 0) {
      AppFeedback.error(context, 'Total marks must be greater than 0.');
      return;
    }

    final parseErrors = <String, String>{};
    final entries = <GradeEntryInput>[];
    for (final s in students) {
      final text = _marksCtrls[_ck(s.id)]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      final m = double.tryParse(text);
      final err = GradeRules.validateMark(obtained: m, totalMarks: total);
      if (err != null) {
        parseErrors[s.id] = err;
      } else {
        entries.add(GradeEntryInput(
          student: s,
          marksObtained: m!,
          remarks: _remarksCtrls[_ck(s.id)]?.text.trim() ?? '',
        ));
      }
    }

    if (parseErrors.isNotEmpty) {
      setState(() => _rowErrors = parseErrors);
      AppFeedback.error(context, 'Fix ${parseErrors.length} invalid mark${parseErrors.length == 1 ? '' : 's'} (0 to ${GradeRules.formatMark(total)}).');
      return;
    }
    if (entries.isEmpty) {
      AppFeedback.error(context, 'Enter marks for at least one student before saving.');
      return;
    }

    setState(() {
      _isSaving = true;
      _rowErrors = const {};
    });
    try {
      final count = await SchoolGradeService.saveBatch(
        branchId: widget.branchId,
        grade: _selectedGrade,
        section: _selectedSection,
        subject: _selectedSubject,
        examType: _selectedExamType,
        term: _selectedTerm,
        totalMarks: total,
        entries: entries,
        editorName: widget.userName,
        userRole: widget.userRole,
        attachment: attachment,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppFeedback.success(context, 'Saved marks for $count ${count == 1 ? 'student' : 'students'} ($_selectedSubject · $_selectedExamType)');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        if (e is SchoolGradeException) _rowErrors = e.studentErrors;
      });
      AppFeedback.error(context, e is SchoolGradeException ? e.message : 'Save failed: $e');
    }
  }

  Future<void> _printSingleReport(StudentTermReport report) async {
    setState(() => _isPrinting = true);
    try {
      final branchName = LocalStorageService.getBranchName(widget.branchId);
      await SchoolReportCardPdf.printSingle(report: report, branchName: branchName);
    } catch (e) {
      if (mounted) AppFeedback.error(context, 'Could not print report card: $e');
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  Future<void> _printClassReports(List<StudentTermReport> reports) async {
    final withGrades = reports.where((r) => r.hasGrades).toList();
    if (withGrades.isEmpty) {
      AppFeedback.error(context, 'No graded students in this view to print.');
      return;
    }
    setState(() => _isPrinting = true);
    try {
      final branchName = LocalStorageService.getBranchName(widget.branchId);
      await SchoolReportCardPdf.printBatch(
        reports: withGrades,
        branchName: branchName,
        title: 'ReportCards-Class-$_selectedGrade-${_reportSection == 'All' ? 'All' : _reportSection}-${GradeRules.slug(_selectedTerm)}',
      );
    } catch (e) {
      if (mounted) AppFeedback.error(context, 'Could not print class reports: $e');
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canEnter || (_isTeacher && _grades.isEmpty)) {
      return const SchoolErpPage(
        breadcrumbs: ['School', 'Academics'],
        title: 'Grades & reports',
        icon: GIcons.exam,
        child: AppEmptyState(
          icon: GIcons.lock,
          title: 'No classes assigned for grading',
          subtitle: 'Teachers can enter and view grades only for their assigned classes and subjects. Ask the Principal to assign your classes.',
        ),
      );
    }

    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final boxes = SchoolGradeService.watchedBoxes
            .where(Hive.isBoxOpen)
            .map((b) => DebouncedBoxListenable.shared(Hive.box(b)))
            .toList();
        return ListenableBuilder(listenable: Listenable.merge(boxes), builder: (context, _) => _build(context));
      },
    );
  }

  Widget _build(BuildContext context) {
    final roster = SchoolStudentService.roster(widget.branchId);
    final allGrades = SchoolGradeService.allGrades(widget.branchId);
    final allEvents = SchoolEventService.all(widget.branchId);

    final activeStudents = roster.students.where((s) => s.isActive).toList();
    final marksStudents = activeStudents
        .where((s) => s.grade == _selectedGrade && s.section == _selectedSection)
        .toList()
      ..sort((a, b) {
        final ra = int.tryParse(a.rollNo) ?? 99999;
        final rb = int.tryParse(b.rollNo) ?? 99999;
        return ra != rb ? ra.compareTo(rb) : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final examGrades = allGrades
        .where((g) =>
            g.grade == _selectedGrade &&
            g.section == _selectedSection &&
            g.subject == _selectedSubject &&
            g.examType == _selectedExamType &&
            g.term == _selectedTerm)
        .toList();
    final gradeByStudent = {for (final g in examGrades) g.studentId: g};

    final attachment = SchoolGradeService.attachmentFor(
      branchId: widget.branchId,
      grade: _selectedGrade,
      section: _selectedSection,
      subject: _selectedSubject,
      examType: _selectedExamType,
      term: _selectedTerm,
    );

    final reportStudents = activeStudents
        .where((s) => s.grade == _selectedGrade && (_reportSection == 'All' || s.section == _reportSection))
        .toList();
    final reports = GradeRules.buildTermReports(
      students: reportStudents,
      allGrades: allGrades,
      allEvents: allEvents,
      term: _selectedTerm,
      examTypeFilter: _reportExamFilter,
    );

    final body = switch (_tab) {
      _GradingTab.marks => _buildMarksTab(context, marksStudents, examGrades, gradeByStudent, attachment),
      _GradingTab.reports => _buildReportsTab(context, reports),
    };

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Academics'],
      title: 'Grades & reports',
      subtitle: 'Class marks entry, exam attachments and printable report cards',
      icon: GIcons.exam,
      actions: [
        if (_tab == _GradingTab.marks) ...[
          OutlinedButton.icon(
            onPressed: _isSaving ? null : () => _pickAttachment(marksStudents),
            icon: const Icon(GIcons.upload, size: 16),
            label: Text(attachment == null ? 'Attach Excel / PDF' : 'Replace file'),
          ),
          FilledButton.icon(
            onPressed: _isSaving || marksStudents.isEmpty ? null : () => _saveAllMarks(marksStudents, attachment),
            icon: _isSaving
                ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: context.comfort.onBrand))
                : const Icon(GIcons.save, size: 16),
            label: Text(_isSaving ? 'Saving…' : 'Save class marks'),
          ),
        ] else
          FilledButton.icon(
            onPressed: _isPrinting ? null : () => _printClassReports(reports),
            icon: const Icon(GIcons.print, size: 16),
            label: Text(_isPrinting ? 'Preparing PDF…' : 'Print class reports'),
          ),
      ],
      tabs: SchoolErpTabs(
        labels: const ['Marks entry', 'Report cards'],
        icons: const [GIcons.edit, GIcons.report],
        counts: [marksStudents.length, reports.where((r) => r.hasGrades).length],
        selected: _tab.index,
        onChanged: (i) => setState(() => _tab = _GradingTab.values[i]),
      ),
      child: body,
    );
  }

  Widget _buildMarksTab(
    BuildContext context,
    List<SchoolStudent> students,
    List<SchoolGrade> examGrades,
    Map<String, SchoolGrade> gradeByStudent,
    SchoolGradeAttachment? attachment,
  ) {
    final c = context.comfort;
    final stats = GradeRules.summarizeExam(totalStudents: students.length, examGrades: examGrades);

    final toolbar = SchoolErpToolbar(
      filters: [
        SchoolErpFilter<String>(
          label: 'Class',
          value: _selectedGrade,
          width: 125,
          options: {for (final g in _grades) g: 'Class $g'},
          onChanged: (v) => setState(() {
            _selectedGrade = v;
            _rowErrors = const {};
          }),
        ),
        SchoolErpFilter<String>(
          label: 'Section',
          value: _selectedSection,
          width: 112,
          options: {for (final s in SchoolConstants.sections) s: 'Sec $s'},
          onChanged: (v) => setState(() {
            _selectedSection = v;
            _rowErrors = const {};
          }),
        ),
        SchoolErpFilter<String>(
          label: 'Subject',
          value: _selectedSubject,
          width: 175,
          options: {for (final sub in _subjects) sub: sub},
          onChanged: (v) => setState(() {
            _selectedSubject = v;
            _rowErrors = const {};
          }),
        ),
        SchoolErpFilter<String>(
          label: 'Exam',
          value: _selectedExamType,
          width: 130,
          options: {for (final e in GradeRules.examTypes) e: e},
          onChanged: (v) => setState(() {
            _selectedExamType = v;
            _rowErrors = const {};
          }),
        ),
        SchoolErpFilter<String>(
          label: 'Term',
          value: _selectedTerm,
          width: 125,
          options: {for (final t in GradeRules.terms) t: t},
          onChanged: (v) => setState(() {
            _selectedTerm = v;
            _rowErrors = const {};
          }),
        ),
        SizedBox(
          width: 112,
          height: 38,
          child: TextField(
            controller: _totalMarksCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: GText.body2(c.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Total marks',
              contentPadding: EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: 8),
            ),
            onChanged: (v) {
              final d = double.tryParse(v);
              if (d != null && d > 0) setState(() => _totalMarks = d);
            },
          ),
        ),
      ],
      trailing: [
        if (attachment != null)
          AppChip(
            label: attachment.fileName,
            icon: GIcons.layers,
            state: AppChipState.info,
            onTap: () => _removeAttachment(attachment),
          ),
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SchoolErpStatStrip([
        SchoolErpStat(
          label: 'Class average',
          value: stats.gradedCount == 0 ? '—' : '${stats.averagePct.toStringAsFixed(1)}%',
          color: stats.gradedCount == 0 ? c.textMuted : _letterColor(context, GradeRules.letterOf(stats.averagePct)),
          icon: GIcons.chart,
        ),
        SchoolErpStat(
          label: 'Graded',
          value: '${stats.gradedCount} / ${stats.totalStudents}',
          color: c.brand,
          icon: GIcons.checklist,
        ),
        SchoolErpStat(
          label: 'Highest',
          value: stats.gradedCount == 0 ? '—' : '${stats.highestPct.toStringAsFixed(1)}%',
          color: c.success,
          icon: GIcons.star,
        ),
        SchoolErpStat(
          label: 'Pass rate (≥50%)',
          value: stats.gradedCount == 0 ? '—' : '${stats.passRate.toStringAsFixed(1)}%',
          color: stats.gradedCount == 0 ? c.textMuted : (stats.passRate >= 70 ? c.success : c.warning),
          icon: GIcons.checkCircle,
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      Expanded(
        child: SchoolErpCard(
          toolbar: toolbar,
          footer: students.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp2 + 2),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        'Class $_selectedGrade-$_selectedSection · $_selectedSubject · $_selectedExamType ($_selectedTerm)'
                        '${attachment != null ? ' · File: ${attachment.fileName} (click chip to remove)' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GText.caption(c.textMuted),
                      ),
                    ),
                    const SizedBox(width: Gsp.sp3),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : () => _saveAllMarks(students, attachment),
                      icon: const Icon(GIcons.save, size: 16),
                      label: Text(_isSaving ? 'Saving…' : 'Save class marks'),
                    ),
                  ]),
                ),
          child: students.isEmpty
              ? AppEmptyState(
                  icon: GIcons.student,
                  title: 'No active students in Class $_selectedGrade-$_selectedSection',
                  subtitle: 'Pick another class or section, or admit students first.',
                  compact: true,
                )
              : Column(children: [
                  // Table header
                  Container(
                    height: SchoolErp.headerHeight,
                    color: c.surfaceSunken,
                    padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3),
                    child: Row(children: [
                      SizedBox(width: 56, child: Text('ROLL', style: GText.overline(c.textMuted))),
                      const SizedBox(width: Gsp.sp3),
                      Expanded(flex: 4, child: Text('STUDENT', style: GText.overline(c.textMuted))),
                      const SizedBox(width: Gsp.sp3),
                      SizedBox(width: 132, child: Text('MARKS / ${GradeRules.formatMark(_totalMarks)}', style: GText.overline(c.textMuted))),
                      const SizedBox(width: Gsp.sp3),
                      SizedBox(width: 108, child: Text('RESULT', style: GText.overline(c.textMuted))),
                      const SizedBox(width: Gsp.sp3),
                      Expanded(flex: 3, child: Text('REMARKS', style: GText.overline(c.textMuted))),
                      const SizedBox(width: Gsp.sp2),
                      SizedBox(width: 40, child: Text('CARD', textAlign: TextAlign.center, style: GText.overline(c.textMuted))),
                    ]),
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: students.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                      itemBuilder: (context, i) {
                        final s = students[i];
                        final existing = gradeByStudent[s.id];
                        final key = _ck(s.id);
                        final marksCtrl = _marksCtrls.putIfAbsent(
                          key,
                          () => TextEditingController(text: existing != null ? GradeRules.formatMark(existing.marksObtained) : ''),
                        );
                        final remarksCtrl = _remarksCtrls.putIfAbsent(
                          key,
                          () => TextEditingController(text: existing?.remarks ?? ''),
                        );
                        final rawText = marksCtrl.text.trim();
                        final parsed = double.tryParse(rawText);
                        final total = existing?.totalMarks ?? _totalMarks;
                        final hasVal = rawText.isNotEmpty && parsed != null;
                        final pct = hasVal ? GradeRules.percentageOf(parsed, total) : 0.0;
                        final letter = hasVal ? GradeRules.letterOf(pct) : '—';
                        final rowErr = _rowErrors[s.id] ?? (rawText.isNotEmpty ? GradeRules.validateMark(obtained: parsed, totalMarks: _totalMarks) : null);
                        final lc = _letterColor(context, letter);

                        return Container(
                          color: rowErr != null
                              ? c.dangerBg.withValues(alpha: 0.4)
                              : (i.isOdd ? c.surfaceSunken.withValues(alpha: 0.35) : c.surface),
                          padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                          child: Row(children: [
                            SizedBox(width: 56, child: SchoolErpCell.mono(context, s.rollNo)),
                            const SizedBox(width: Gsp.sp3),
                            Expanded(
                              flex: 4,
                              child: SchoolErpCell.primary(
                                context,
                                s.name,
                                sub: '${s.admissionNo} · ${s.guardianName}',
                                leading: StudentAvatar(student: s, size: 28),
                              ),
                            ),
                            const SizedBox(width: Gsp.sp3),
                            SizedBox(
                              width: 132,
                              child: TextField(
                                controller: marksCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                style: GText.body2Bold(c.textPrimary),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: '0–${GradeRules.formatMark(_totalMarks)}',
                                  errorText: rowErr,
                                  errorMaxLines: 1,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: Gsp.sp2 + 2, vertical: 8),
                                ),
                                onChanged: (_) => setState(() {
                                  if (_rowErrors.containsKey(s.id)) {
                                    _rowErrors = Map<String, String>.from(_rowErrors)..remove(s.id);
                                  }
                                }),
                              ),
                            ),
                            const SizedBox(width: Gsp.sp3),
                            SizedBox(
                              width: 108,
                              child: hasVal
                                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                                      Text('${pct.toStringAsFixed(0)}%', style: GText.label(lc)),
                                      const SizedBox(width: Gsp.sp1 + 2),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: lc.withValues(alpha: 0.14), borderRadius: Gr.chip),
                                        child: Text(letter, style: GText.caption(lc).copyWith(fontWeight: FontWeight.w700)),
                                      ),
                                    ])
                                  : Text('—', style: GText.caption(c.textMuted)),
                            ),
                            const SizedBox(width: Gsp.sp3),
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: remarksCtrl,
                                style: GText.body2(c.textPrimary),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: 'Remarks (optional)',
                                  contentPadding: EdgeInsets.symmetric(horizontal: Gsp.sp2 + 2, vertical: 8),
                                ),
                              ),
                            ),
                            const SizedBox(width: Gsp.sp2),
                            SizedBox(
                              width: 40,
                              child: IconButton(
                                tooltip: 'Open report card',
                                icon: Icon(GIcons.report, size: 18, color: c.brand),
                                onPressed: () => setState(() {
                                  _reportSection = _selectedSection;
                                  _selectedReportStudentId = s.id;
                                  _tab = _GradingTab.reports;
                                }),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                ]),
        ),
      ),
    ]);
  }

  Widget _buildReportsTab(BuildContext context, List<StudentTermReport> reports) {
    final c = context.comfort;
    final q = _reportSearchCtrl.text.trim().toLowerCase();
    final filtered = reports.where((r) {
      if (q.isEmpty) return true;
      return r.student.name.toLowerCase().contains(q) ||
          r.student.admissionNo.toLowerCase().contains(q) ||
          r.student.rollNo.toLowerCase() == q;
    }).toList();

    final graded = reports.where((r) => r.hasGrades).toList();
    final passed = graded.where((r) => r.passed).length;
    final avgPct = graded.isEmpty ? 0.0 : graded.fold<double>(0, (a, r) => a + r.percentage) / graded.length;
    final flaggedEvents = reports.where((r) => r.events.hasAbsences).length;

    StudentTermReport? selected;
    for (final r in reports) {
      if (r.student.id == _selectedReportStudentId) selected = r;
    }

    final table = SchoolErpTable<StudentTermReport>(
      rows: filtered,
      rowKey: (r) => r.student.id,
      selectedKey: _selectedReportStudentId,
      onRowTap: (r) {
        if (SchoolErp.wide(context)) {
          setState(() => _selectedReportStudentId = r.student.id);
        } else {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.88,
              child: _ReportCardPanel(
                report: r,
                printing: _isPrinting,
                onPrint: () => _printSingleReport(r),
              ),
            ),
          );
        }
      },
      minWidth: 780,
      empty: AppEmptyState(
        icon: GIcons.report,
        title: 'No students in Class $_selectedGrade${_reportSection == 'All' ? '' : '-$_reportSection'}',
        subtitle: 'Select another class or enter marks in the Marks entry tab.',
        compact: true,
      ),
      columns: [
        SchoolErpColumn(
          label: 'Rank',
          width: 62,
          numeric: true,
          sortValue: (r) => r.rank ?? 99999,
          cell: (r) => SchoolErpCell.mono(context, r.rank == null ? '—' : '#${r.rank}'),
        ),
        SchoolErpColumn(
          label: 'Roll',
          width: 58,
          numeric: true,
          sortValue: (r) => int.tryParse(r.student.rollNo) ?? 99999,
          cell: (r) => SchoolErpCell.mono(context, r.student.rollNo),
        ),
        SchoolErpColumn(
          label: 'Student',
          flex: 4,
          sortValue: (r) => r.student.name.toLowerCase(),
          cell: (r) => SchoolErpCell.primary(
            context,
            r.student.name,
            sub: '${r.student.grade}-${r.student.section} · ${r.student.admissionNo}',
            leading: StudentAvatar(student: r.student, size: 28),
          ),
        ),
        SchoolErpColumn(
          label: 'Subjects',
          width: 82,
          numeric: true,
          sortValue: (r) => r.grades.length,
          cell: (r) => SchoolErpCell.mono(context, '${r.grades.length}'),
        ),
        SchoolErpColumn(
          label: 'Score',
          width: 112,
          numeric: true,
          sortValue: (r) => r.percentage,
          cell: (r) => SchoolErpCell.mono(
            context,
            r.hasGrades ? '${GradeRules.formatMark(r.totalObtained)} / ${GradeRules.formatMark(r.totalPossible)}' : '—',
          ),
        ),
        SchoolErpColumn(
          label: '% / Grade',
          width: 110,
          sortValue: (r) => r.percentage,
          cell: (r) => r.hasGrades
              ? AppChip(
                  label: '${r.percentage.toStringAsFixed(1)}% · ${r.letterGrade}',
                  state: r.passed ? AppChipState.active : AppChipState.danger,
                )
              : SchoolErpCell.text(context, 'Not graded', muted: true),
        ),
        SchoolErpColumn(
          label: 'Events',
          width: 108,
          sortValue: (r) => r.events.absent,
          cell: (r) => r.events.totalHeld == 0
              ? SchoolErpCell.text(context, '—', muted: true)
              : r.events.hasAbsences
                  ? AppChip(label: '${r.events.absent} missed', state: AppChipState.danger, icon: GIcons.warning)
                  : AppChip(label: '${r.events.attended}/${r.events.totalHeld} ok', state: AppChipState.active),
        ),
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SchoolErpStatStrip([
        SchoolErpStat(label: 'Graded students', value: '${graded.length} / ${reports.length}', icon: GIcons.student),
        SchoolErpStat(
          label: 'Term average',
          value: graded.isEmpty ? '—' : '${avgPct.toStringAsFixed(1)}%',
          color: graded.isEmpty ? c.textMuted : _letterColor(context, GradeRules.letterOf(avgPct)),
          icon: GIcons.chart,
        ),
        SchoolErpStat(
          label: 'Passing',
          value: graded.isEmpty ? '—' : '$passed / ${graded.length}',
          color: c.success,
          icon: GIcons.checkCircle,
        ),
        SchoolErpStat(
          label: 'Event absences',
          value: GFormat.count(flaggedEvents),
          color: flaggedEvents > 0 ? c.danger : c.success,
          icon: GIcons.event,
          caption: 'Flagged on reports',
        ),
      ]),
      const SizedBox(height: Gsp.sp3),
      Expanded(
        child: SchoolErpMasterDetail(
          master: SchoolErpCard(
            toolbar: SchoolErpToolbar(
              search: _reportSearchCtrl,
              searchHint: 'Search student, roll or adm. no',
              onSearch: (_) => setState(() {}),
              filters: [
                SchoolErpFilter<String>(
                  label: 'Class',
                  value: _selectedGrade,
                  width: 125,
                  options: {for (final g in _grades) g: 'Class $g'},
                  onChanged: (v) => setState(() {
                    _selectedGrade = v;
                    _selectedReportStudentId = null;
                  }),
                ),
                SchoolErpFilter<String>(
                  label: 'Section',
                  value: _reportSection,
                  width: 112,
                  options: {'All': 'All', for (final s in SchoolConstants.sections) s: 'Sec $s'},
                  onChanged: (v) => setState(() => _reportSection = v),
                ),
                SchoolErpFilter<String>(
                  label: 'Term',
                  value: _selectedTerm,
                  width: 125,
                  options: {for (final t in GradeRules.terms) t: t},
                  onChanged: (v) => setState(() => _selectedTerm = v),
                ),
                SchoolErpFilter<String>(
                  label: 'Exam',
                  value: _reportExamFilter,
                  width: 125,
                  options: {'All': 'All exams', for (final e in GradeRules.examTypes) e: e},
                  onChanged: (v) => setState(() => _reportExamFilter = v),
                ),
              ],
            ),
            child: table,
          ),
          detail: selected == null
              ? null
              : _ReportCardPanel(
                  report: selected,
                  printing: _isPrinting,
                  onPrint: () => _printSingleReport(selected!),
                  onClose: () => setState(() => _selectedReportStudentId = null),
                ),
        ),
      ),
    ]);
  }
}

class _ReportCardPanel extends StatelessWidget {
  const _ReportCardPanel({
    required this.report,
    required this.printing,
    required this.onPrint,
    this.onClose,
  });

  final StudentTermReport report;
  final bool printing;
  final VoidCallback onPrint;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final s = report.student;
    final ev = report.events;

    return SchoolErpDetailPanel(
      onClose: onClose,
      leading: StudentAvatar(student: s, size: 52),
      title: s.name,
      subtitle: '${s.admissionNo} · Class ${s.grade}-${s.section} · Roll ${s.rollNo}',
      chips: [
        AppChip(label: report.term, state: AppChipState.info, icon: GIcons.exam),
        if (report.hasGrades)
          AppChip(
            label: '${report.percentage.toStringAsFixed(1)}% (${report.letterGrade})',
            state: report.passed ? AppChipState.active : AppChipState.danger,
          ),
        if (report.rank != null) AppChip(label: 'Rank #${report.rank} of ${report.classSize}', state: AppChipState.neutral),
      ],
      actions: [
        FilledButton.icon(
          onPressed: printing ? null : onPrint,
          icon: const Icon(GIcons.print, size: 16),
          label: Text(printing ? 'Preparing PDF…' : 'Print report card'),
        ),
      ],
      children: [
        SchoolErpFacts(title: 'Summary', facts: [
          ('Father', s.guardianName),
          ('Session', s.academicYear.isEmpty ? '—' : s.academicYear),
          ('Total marks', report.hasGrades ? '${GradeRules.formatMark(report.totalObtained)} / ${GradeRules.formatMark(report.totalPossible)}' : 'No marks yet'),
          ('GPA', report.hasGrades ? report.gpa.toStringAsFixed(2) : '—'),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('SUBJECTS (${report.grades.length})', style: GText.overline(c.textMuted)),
        ),
        if (report.grades.isEmpty)
          Text('No grades recorded for ${report.term} yet.', style: GText.body2(c.textMuted))
        else
          Container(
            decoration: BoxDecoration(borderRadius: SchoolErp.radius, border: Border.all(color: c.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Container(
                color: c.surfaceSunken,
                padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                child: Row(children: [
                  Expanded(flex: 4, child: Text('SUBJECT', style: GText.overline(c.textMuted))),
                  SizedBox(width: 68, child: Text('MARKS', textAlign: TextAlign.end, style: GText.overline(c.textMuted))),
                  SizedBox(width: 52, child: Text('GRADE', textAlign: TextAlign.end, style: GText.overline(c.textMuted))),
                ]),
              ),
              for (final g in report.grades)
                Container(
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp3, vertical: Gsp.sp2),
                  child: Row(children: [
                    Expanded(
                      flex: 4,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(g.subject, style: GText.body2Bold(c.textPrimary)),
                        Text(
                          '${g.examType}${g.remarks.isEmpty ? '' : ' · ${g.remarks}'}',
                          style: GText.caption(c.textMuted),
                        ),
                      ]),
                    ),
                    SizedBox(
                      width: 68,
                      child: Text(
                        '${GradeRules.formatMark(g.marksObtained)}/${GradeRules.formatMark(g.totalMarks)}',
                        textAlign: TextAlign.end,
                        style: GText.caption(c.textPrimary),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        g.letterGrade,
                        textAlign: TextAlign.end,
                        style: GText.label(g.percentage >= GradeRules.passPercent ? c.success : c.danger),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('BIMONTHLY EVENTS (REPORT ONLY)', style: GText.overline(c.textMuted)),
        ),
        if (ev.totalHeld == 0)
          Text('No compulsory events recorded yet.', style: GText.body2(c.textMuted))
        else
          Container(
            padding: const EdgeInsets.all(Gsp.sp3),
            decoration: BoxDecoration(
              color: ev.hasAbsences ? c.dangerBg : c.successBg,
              borderRadius: SchoolErp.radius,
              border: Border.all(color: (ev.hasAbsences ? c.danger : c.success).withValues(alpha: 0.35)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Attended ${ev.attended} of ${ev.totalHeld} events${ev.excused > 0 ? ' (${ev.excused} excused)' : ''}',
                style: GText.body2Bold(ev.hasAbsences ? c.danger : c.success),
              ),
              if (ev.missedEvents.isNotEmpty) ...[
                const SizedBox(height: Gsp.sp1),
                for (final m in ev.missedEvents)
                  Text('• Missed: ${m.title} (${m.date})', style: GText.caption(c.danger)),
              ],
            ]),
          ),
      ],
    );
  }
}
