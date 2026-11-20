// lib/pages/school/views/school_student_management_view.dart
//
// Students (School ERP plan §3.3). ERP layout (2026-11-17):
//   header: School › Academics › Students, New admission
//   status tabs (Active · Suspended · Left · Graduated · All · Entered by mistake)
//   stat strip · toolbar (search, class, section) · paged, sortable grid
//   record panel on the right (bottom sheet on narrow screens)
// Students are never deleted: status changes are dated, and a record saved by
// mistake is marked "Entered by mistake" (void) and can be restored.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../utils/debounced_box_listenable.dart';
import '../../../services/image_upload_service.dart';
import '../constants/school_constants.dart';
import '../dialogs/school_enrollment_dialog.dart';
import '../models/school_student.dart';
import '../students/school_student_service.dart';
import '../students/student_rules.dart';
import '../students/widgets/student_dialogs.dart';
import '../students/widgets/student_promotion_dialog.dart';
import '../students/widgets/student_slip_dialogs.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolStudentManagementView extends StatefulWidget {
  final String branchId;
  final String userRole;
  final String userName;

  const SchoolStudentManagementView({
    super.key,
    required this.branchId,
    this.userRole = 'School Admin',
    this.userName = 'User',
  });

  @override
  State<SchoolStudentManagementView> createState() => _SchoolStudentManagementViewState();
}

enum _StatusFilter { active, suspended, left, graduated, all, voided }

const _filterLabels = {
  _StatusFilter.active: 'Active',
  _StatusFilter.suspended: 'Suspended',
  _StatusFilter.left: 'Left',
  _StatusFilter.graduated: 'Graduated',
  _StatusFilter.all: 'All',
  _StatusFilter.voided: 'Entered by mistake',
};

class _SchoolStudentManagementViewState extends State<SchoolStudentManagementView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();
  final _search = TextEditingController();
  String _grade = 'All';
  String _section = 'All';
  _StatusFilter _status = _StatusFilter.active;
  String? _selectedId;

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);
  /// Admissions and status changes: managers only (Principal, School admin, head office).
  bool get _canManage => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);

  /// A teacher sees only their own classes (none when no teacher record matches the login).
  StudentRoster _scoped(StudentRoster roster) {
    if (!_isTeacher) return roster;
    final mine = SchoolAuthHelper.getTeacherAssignedGrades(widget.branchId, widget.userRole, widget.userName).toSet();
    return StudentRoster(roster.students.where((s) => mine.contains(s.grade)).toList());
  }
  bool get _isPrincipal => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);

  List<_StatusFilter> get _tabs => [
        for (final f in _StatusFilter.values)
          if (f != _StatusFilter.voided || _canManage) f,
      ];

  @override
  void initState() {
    super.initState();
    _initTeacherGrade();
  }

  @override
  void didUpdateWidget(covariant SchoolStudentManagementView old) {
    super.didUpdateWidget(old);
    if (old.branchId != widget.branchId || old.userRole != widget.userRole || old.userName != widget.userName) {
      _selectedId = null;
      _initTeacherGrade();
    }
  }

  /// Teachers open on their own class.
  void _initTeacherGrade() {
    if (!_isTeacher) return;
    final assigned = SchoolAuthHelper.getTeacherAssignedGrades(widget.branchId, widget.userRole, widget.userName);
    if (assigned.isNotEmpty && SchoolConstants.grades.contains(assigned.first)) _grade = assigned.first;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _statusMatches(SchoolStudent s, _StatusFilter f) => switch (f) {
        _StatusFilter.active => s.status == 'active',
        _StatusFilter.suspended => s.status == 'suspended',
        _StatusFilter.left => s.status == 'left',
        _StatusFilter.graduated => s.status == 'graduated',
        _StatusFilter.voided => s.isVoid,
        _StatusFilter.all => !s.isVoid,
      };

  List<SchoolStudent> _visible(StudentRoster roster) {
    final q = _search.text.trim().toLowerCase();
    final qDigits = StudentRules.digits(q);
    return roster.students.where((s) {
      if (!_statusMatches(s, _status)) return false;
      if (_grade != 'All' && s.grade != _grade) return false;
      if (_section != 'All' && s.section != _section) return false;
      if (q.isEmpty) return true;
      return s.name.toLowerCase().contains(q) ||
          s.guardianName.toLowerCase().contains(q) ||
          s.admissionNo.toLowerCase().contains(q) ||
          s.rollNo.toLowerCase() == q ||
          (qDigits.length >= 4 &&
              (StudentRules.digits(s.bformNo).contains(qDigits) ||
                  StudentRules.digits(s.guardianCnic).contains(qDigits) ||
                  StudentRules.digits(s.guardianPhone).contains(qDigits)));
    }).toList()
      ..sort((a, b) {
        final g = SchoolConstants.grades.indexOf(a.grade).compareTo(SchoolConstants.grades.indexOf(b.grade));
        if (g != 0) return g;
        final sec = a.section.compareTo(b.section);
        if (sec != 0) return sec;
        final ra = int.tryParse(a.rollNo), rb = int.tryParse(b.rollNo);
        if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  Future<void> _openForm([SchoolStudent? student]) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SchoolEnrollmentDialog(
        branchId: widget.branchId,
        studentToEdit: student,
        editorName: widget.userName,
        canEditAdmissionNo: _isPrincipal,
      ),
    );
    if (ok == true && mounted) setState(() {});
  }

  void _open(SchoolStudent s) {
    if (SchoolErp.wide(context)) {
      setState(() => _selectedId = s.id);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => _StudentPanel(
          branchId: widget.branchId,
          studentId: s.id,
          canManage: _canManage,
          isPrincipal: _isPrincipal,
          editorName: widget.userName,
          onEdit: (st) async {
            Navigator.of(ctx).pop();
            await _openForm(st);
          },
          scrollController: scroll,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final box = Hive.isBoxOpen(SchoolLocalStorage.studentsBox) ? Hive.box(SchoolLocalStorage.studentsBox) : null;
        if (box == null) return _build(context, _scoped(SchoolStudentService.roster(widget.branchId)));
        return ValueListenableBuilder(
          valueListenable: DebouncedBoxListenable.shared(box),
          builder: (context, _, _) => _build(context, _scoped(SchoolStudentService.roster(widget.branchId))),
        );
      },
    );
  }

  Widget _build(BuildContext context, StudentRoster roster) {
    final c = context.comfort;
    final now = DateTime.now();
    final active = roster.count(StudentStatus.active);
    final suspended = roster.count(StudentStatus.suspended);
    final gone = roster.count(StudentStatus.left) + roster.count(StudentStatus.graduated);
    final girls = roster.students.where((s) => s.isActive && s.gender == 'Female').length;
    final newThisMonth = roster.students.where((s) {
      final d = DateTime.tryParse(s.admissionDate);
      return !s.isVoid && d != null && d.year == now.year && d.month == now.month;
    }).length;
    final conflicts = roster.admissionConflicts;
    final students = _visible(roster);
    final selected = _selectedId == null ? null : roster.byId(_selectedId!);

    final stats = SchoolErpStatStrip([
      SchoolErpStat(label: 'Active students', value: GFormat.count(active), caption: '$girls girls · ${active - girls} boys', icon: GIcons.student),
      SchoolErpStat(label: 'New this month', value: GFormat.count(newThisMonth), caption: DateFormat('MMMM yyyy').format(now), color: c.chart2, icon: GIcons.add),
      SchoolErpStat(
        label: 'Suspended',
        value: GFormat.count(suspended),
        caption: suspended > 0 ? 'Review' : 'None',
        color: suspended > 0 ? c.warning : c.success,
        icon: GIcons.block,
        onTap: () => setState(() => _status = _StatusFilter.suspended),
      ),
      SchoolErpStat(label: 'Left & graduated', value: GFormat.count(gone), caption: 'Records kept', color: c.info, icon: GIcons.history,
          onTap: () => setState(() => _status = _StatusFilter.left)),
      SchoolErpStat(
        label: 'Session',
        value: StudentRules.academicYearOf(now),
        caption: 'April to March',
        color: c.accentStrong,
        icon: GIcons.calendar,
      ),
    ]);

    final toolbar = SchoolErpToolbar(
      search: _search,
      searchHint: 'Name, father, admission no., CNIC, B-Form, phone',
      onSearch: (_) => setState(() {}),
      filters: [
        SchoolErpFilter<String>(
          label: 'Class',
          value: _grade,
          options: {'All': 'All classes', for (final g in SchoolConstants.grades) g: g},
          onChanged: (v) => setState(() => _grade = v),
        ),
        SchoolErpFilter<String>(
          label: 'Section',
          value: _section,
          width: 120,
          options: {'All': 'All', for (final s in SchoolConstants.sections) s: 'Section $s'},
          onChanged: (v) => setState(() => _section = v),
        ),
      ],
      trailing: [
        Center(
          child: Text('${students.length} of ${roster.students.where((s) => !s.isVoid).length}', style: GText.caption(c.textMuted)),
        ),
      ],
    );

    final table = SchoolErpTable<SchoolStudent>(
      rows: students,
      rowKey: (s) => s.id,
      selectedKey: _selectedId,
      onRowTap: _open,
      minWidth: 820,
      empty: AppEmptyState(
        icon: roster.students.isEmpty ? GIcons.student : GIcons.searchOff,
        title: roster.students.isEmpty ? 'No students yet' : 'No students match',
        subtitle: roster.students.isEmpty
            ? (_canManage ? 'Add the first admission to start the roster.' : 'Students appear here once admitted.')
            : 'Try another search, class or status.',
        action: roster.students.isEmpty && _canManage
            ? FilledButton.icon(icon: const Icon(GIcons.add), label: const Text('New admission'), onPressed: () => _openForm())
            : null,
      ),
      columns: [
        SchoolErpColumn(
          label: 'Adm. no',
          width: 110,
          sortValue: (s) => s.admissionNo,
          cell: (s) {
            final clash = conflicts.containsKey(s.admissionNo.trim().toLowerCase());
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: SchoolErpCell.mono(context, s.admissionNo, color: clash ? c.warning : null)),
              if (clash) ...[const SizedBox(width: 4), Tooltip(message: 'Used by two students', child: Icon(GIcons.warning, size: 14, color: c.warning))],
            ]);
          },
        ),
        SchoolErpColumn(
          label: 'Student',
          flex: 5,
          sortValue: (s) => s.name.toLowerCase(),
          cell: (s) => SchoolErpCell.primary(context, s.name, sub: 'Father: ${s.guardianName}', leading: StudentAvatar(student: s, size: 28)),
        ),
        SchoolErpColumn(
          label: 'Class',
          flex: 2,
          sortValue: (s) => SchoolConstants.grades.indexOf(s.grade) * 10 + s.section.codeUnitAt(0),
          cell: (s) => SchoolErpCell.text(context, '${s.grade}-${s.section}'),
        ),
        SchoolErpColumn(
          label: 'Roll',
          width: 56,
          numeric: true,
          sortValue: (s) => int.tryParse(s.rollNo) ?? 99999,
          cell: (s) => SchoolErpCell.mono(context, s.rollNo),
        ),
        SchoolErpColumn(label: 'Gender', width: 70, hideBelow: 1000, sortValue: (s) => s.gender, cell: (s) => SchoolErpCell.text(context, s.gender == 'Female' ? 'Girl' : 'Boy')),
        SchoolErpColumn(label: 'Phone', flex: 3, hideBelow: 900, cell: (s) => SchoolErpCell.mono(context, s.guardianPhone)),
        SchoolErpColumn(
          label: 'Admitted',
          flex: 2,
          hideBelow: 1150,
          sortValue: (s) => s.admissionDate,
          cell: (s) => SchoolErpCell.text(context, _date(s.admissionDate)),
        ),
        SchoolErpColumn(label: 'Status', flex: 3, sortValue: (s) => s.status, cell: (s) => StudentStatusChip(s.status)),
      ],
    );

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Academics'],
      title: _isTeacher ? 'My class' : 'Students',
      subtitle: 'Admissions, class lists, guardians and status',
      icon: GIcons.student,
      actions: [
        if (_isPrincipal)
          OutlinedButton.icon(
            icon: const Icon(GIcons.trendUp),
            label: const Text('Promote class'),
            onPressed: () async {
              final res = await showStudentPromotionDialog(
                context,
                branchId: widget.branchId,
                editorName: widget.userName,
                isPrincipal: _isPrincipal,
                initialGrade: _grade == 'All' ? null : _grade,
              );
              if (res != null && context.mounted) {
                AppFeedback.success(
                  context,
                  'Promotion saved for ${res.targetYear}: ${res.promoted} promoted, ${res.heldBack} held back, ${res.graduated} graduated.',
                );
              }
            },
          ),
        if (_canManage) FilledButton.icon(icon: const Icon(GIcons.add), label: const Text('New admission'), onPressed: () => _openForm()),
      ],
      tabs: SchoolErpTabs(
        labels: [for (final t in _tabs) _filterLabels[t]!],
        counts: [for (final t in _tabs) roster.students.where((s) => _statusMatches(s, t)).length],
        selected: _tabs.indexOf(_status),
        onChanged: (i) => setState(() => _status = _tabs[i]),
      ),
      banner: conflicts.isNotEmpty && _canManage
          ? _Banner(
              text: '${conflicts.length} admission ${conflicts.length == 1 ? 'number is' : 'numbers are'} used twice '
                  '(${conflicts.keys.take(3).map((k) => k.toUpperCase()).join(', ')}), which can happen when two computers admit offline. '
                  '${_isPrincipal ? 'Open one of the students and edit the number.' : 'Ask the Principal to correct one.'}',
            )
          : null,
      stats: stats,
      child: SchoolErpMasterDetail(
        master: SchoolErpCard(toolbar: toolbar, child: table),
        detail: selected == null
            ? null
            : _StudentPanel(
                branchId: widget.branchId,
                studentId: selected.id,
                roster: roster,
                canManage: _canManage,
                isPrincipal: _isPrincipal,
                editorName: widget.userName,
                onEdit: _openForm,
                onSelect: (id) => setState(() => _selectedId = id),
                onClose: () => setState(() => _selectedId = null),
              ),
      ),
    );
  }
}

// ── Small pieces ────────────────────────────────────────────────────────────

class StudentStatusChip extends StatelessWidget {
  const StudentStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = StudentStatus.parse(status);
    return AppChip(
      label: s.label,
      state: switch (s) {
        StudentStatus.active => AppChipState.active,
        StudentStatus.suspended => AppChipState.warning,
        StudentStatus.left => AppChipState.neutral,
        StudentStatus.graduated => AppChipState.info,
        StudentStatus.voided => AppChipState.danger,
      },
      icon: switch (s) {
        StudentStatus.active => GIcons.checkCircle,
        StudentStatus.suspended => GIcons.block,
        StudentStatus.left => GIcons.logout,
        StudentStatus.graduated => GIcons.student,
        StudentStatus.voided => GIcons.cancel,
      },
    );
  }
}

class StudentAvatar extends StatelessWidget {
  const StudentAvatar({super.key, required this.student, this.size = 36});
  final SchoolStudent student;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final bytes = student.photoUrl.isEmpty ? null : ImageUploadService.decodeBase64ToBytes(student.photoUrl);
    final initials = student.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => String.fromCharCode(w.runes.first))
        .join();
    final tint = student.gender == 'Female' ? c.accentStrong : c.brand;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.14)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: bytes != null && bytes.isNotEmpty
          ? Image.memory(bytes, fit: BoxFit.cover, width: size, height: size, gaplessPlayback: true)
          : student.photoUrl.startsWith('http')
              ? Image.network(student.photoUrl, fit: BoxFit.cover, width: size, height: size,
                  errorBuilder: (_, _, _) => Icon(GIcons.profile, color: tint, size: size * 0.5))
              : Text(initials.isEmpty ? '?' : initials.toUpperCase(), style: GText.label(tint).copyWith(fontSize: size * 0.36)),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.all(Gsp.sp3),
      decoration: BoxDecoration(color: c.warningBg, borderRadius: SchoolErp.radius, border: Border.all(color: c.warning.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(GIcons.warning, size: GIconSize.sm, color: c.warning),
        const SizedBox(width: Gsp.sp2),
        Expanded(child: Text(text, style: GText.body2(c.warning))),
      ]),
    );
  }
}

String _date(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? (ymd.isEmpty ? '—' : ymd) : DateFormat('d MMM yyyy').format(d);
}

// ── Record panel ────────────────────────────────────────────────────────────

class _StudentPanel extends StatelessWidget {
  const _StudentPanel({
    required this.branchId,
    required this.studentId,
    required this.canManage,
    required this.isPrincipal,
    required this.editorName,
    required this.onEdit,
    this.roster,
    this.onSelect,
    this.onClose,
    this.scrollController,
  });

  final String branchId;
  final String studentId;
  final StudentRoster? roster;
  final bool canManage;
  final bool isPrincipal;
  final String editorName;
  final Future<void> Function(SchoolStudent) onEdit;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    // In a bottom sheet the roster passed in goes stale after an action, so re-read.
    final r = roster ?? SchoolStudentService.roster(branchId);
    final s = r.byId(studentId);
    final c = context.comfort;
    if (s == null) {
      return const AppEmptyState(icon: GIcons.searchOff, title: 'Student not found', compact: true);
    }
    final siblings = r.siblingsOf(s);
    final sheet = scrollController != null;

    Future<void> afterAction(String message) async {
      if (!context.mounted) return;
      AppFeedback.success(context, message);
      if (sheet) Navigator.of(context).pop();
    }

    return SchoolErpDetailPanel(
      scrollController: scrollController,
      onClose: onClose,
      leading: StudentAvatar(student: s, size: 56),
      title: s.name,
      subtitle: '${s.admissionNo} · Class ${s.grade}-${s.section}${s.rollNo.isEmpty ? '' : ' · Roll ${s.rollNo}'}',
      chips: [
        StudentStatusChip(s.status),
        AppChip(label: s.gender == 'Female' ? 'Girl' : 'Boy', state: AppChipState.neutral),
        if (s.academicYear.isNotEmpty) AppChip(label: s.academicYear, state: AppChipState.neutral, icon: GIcons.calendar),
        if (s.syncStatus == 'pending') const AppChip(label: 'Waiting to upload', state: AppChipState.warning, icon: GIcons.cloudOff),
      ],
      actions: [
        if (canManage && !s.isVoid)
          FilledButton.icon(onPressed: () => onEdit(s), icon: const Icon(GIcons.edit, size: 16), label: const Text('Edit')),
        if (canManage && StudentRules.nextStatuses(StudentStatus.parse(s.status), isPrincipal: isPrincipal).isNotEmpty)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await showStudentStatusDialog(context, branchId: branchId, student: s, editorName: editorName, isPrincipal: isPrincipal);
              if (ok) await afterAction('Status updated for ${s.name}');
            },
            icon: const Icon(GIcons.history, size: 16),
            label: const Text('Status'),
          ),
        OutlinedButton.icon(
          onPressed: () => showStudentAdmissionSlip(context, s, onEdit: canManage && !s.isVoid ? () => onEdit(s) : null),
          icon: const Icon(GIcons.receipt, size: 16),
          label: const Text('Slip'),
        ),
        OutlinedButton.icon(
          onPressed: () => showStudentDocumentsDialog(context, s),
          icon: const Icon(GIcons.layers, size: 16),
          label: Text('Documents (${s.documentCount})'),
        ),
      ],
      children: [
        if (s.status != 'active' && (s.statusReason.isNotEmpty || s.statusDate.isNotEmpty))
          Container(
            margin: const EdgeInsets.only(top: Gsp.sp3),
            padding: const EdgeInsets.all(Gsp.sp3),
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: SchoolErp.radius),
            child: Text(
              '${StudentStatus.parse(s.status).label} from ${_date(s.statusDate)}${s.statusReason.isEmpty ? '' : '\n${s.statusReason}'}',
              style: GText.body2(c.textSecondary),
            ),
          ),
        SchoolErpFacts(title: 'Student', facts: [
          ('Admitted', _date(s.admissionDate)),
          ('Date of birth', _date(s.dob)),
          ('B-Form', s.bformNo),
          if (s.academicGroup != 'General') ('Group', s.academicGroup),
          if (s.bloodGroup.isNotEmpty) ('Blood group', s.bloodGroup),
          if (s.previousSchool.isNotEmpty) ('Previous school', s.previousSchool),
          if (s.biometricPin.isNotEmpty) ('Biometric PIN', s.biometricPin),
          if (s.transferredFromMadrassaId.isNotEmpty)
            ('From madrassa', 'Record ${s.transferredFromMadrassaId}${s.transferredAt.isEmpty ? '' : ' · ${_date(s.transferredAt)}'}'),
        ]),
        SchoolErpFacts(title: 'Guardian', facts: [
          ('Father', s.guardianName),
          ('CNIC', s.guardianCnic),
          ('Phone', s.guardianPhone),
          if (s.emergencyContact.isNotEmpty) ('Emergency', s.emergencyContact),
          if (s.fatherProfession.isNotEmpty) ('Profession', s.fatherProfession),
          ('Address', s.address),
          ('Form signed', s.parentSignatureConfirmed ? 'Yes, parent signed' : 'Not confirmed yet'),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
          child: Text('BROTHERS & SISTERS (${siblings.length})', style: GText.overline(c.textMuted)),
        ),
        if (siblings.isEmpty)
          Text(s.guardianCnic.isEmpty ? "Add the father's CNIC to find siblings." : 'No other children with this CNIC.',
              style: GText.body2(c.textMuted)),
        for (final sib in siblings)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: StudentAvatar(student: sib, size: 30),
            title: Text(sib.name, style: GText.body2Bold(c.textPrimary)),
            subtitle: Text('${sib.admissionNo} · Class ${sib.grade}-${sib.section}', style: GText.caption(c.textMuted)),
            trailing: StudentStatusChip(sib.status),
            onTap: onSelect == null ? null : () => onSelect!(sib.id),
          ),
        if (s.statusHistory.isNotEmpty)
          _History(title: 'Status history', lines: [
            for (final h in s.statusHistory.reversed)
              (
                '${StudentStatus.parse(h.from).label} → ${StudentStatus.parse(h.to).label}',
                ['from ${_date(h.effectiveDate)}', if (h.by.isNotEmpty) 'by ${h.by}', if (h.reason.isNotEmpty) h.reason].join(' · '),
              ),
          ]),
        if (s.classHistory.isNotEmpty)
          _History(title: 'Class changes', lines: [
            for (final h in s.classHistory.reversed)
              ('${h.fromGrade}-${h.fromSection} → ${h.toGrade}-${h.toSection}', ['on ${_date(h.effectiveDate)}', if (h.by.isNotEmpty) 'by ${h.by}'].join(' · ')),
          ]),
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.title, required this.lines});
  final String title;
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: Gsp.sp4, bottom: Gsp.sp2),
        child: Text(title.toUpperCase(), style: GText.overline(c.textMuted)),
      ),
      for (final (t, sub) in lines)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gsp.sp1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle)),
            ),
            const SizedBox(width: Gsp.sp3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: GText.body2Bold(c.textPrimary)),
                Text(sub, style: GText.caption(c.textMuted)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}
