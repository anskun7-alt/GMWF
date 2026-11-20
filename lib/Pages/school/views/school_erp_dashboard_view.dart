// lib/pages/school/views/school_erp_dashboard_view.dart
//
// School dashboard (ERP layout, 2026-11-17). Replaces the old Overview and
// Principal dashboard screens with one page for Principal, School Admin and
// executives:
//   stat strip for today · today by class · attention needed · recent activity

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../utils/debounced_box_listenable.dart';
import '../constants/school_constants.dart';
import '../core/school_store.dart';
import '../daily/daily_models.dart';
import '../daily/daily_rules.dart';
import '../daily/school_daily_service.dart';
import '../library/school_library_service.dart';
import '../students/school_student_service.dart';
import '../students/student_rules.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

class SchoolErpDashboardView extends StatefulWidget {
  const SchoolErpDashboardView({super.key, required this.branchId, this.userName = 'User', this.userRole = 'School Admin'});
  final String branchId;
  final String userName;
  final String userRole;

  @override
  State<SchoolErpDashboardView> createState() => _SchoolErpDashboardViewState();
}

class _ClassRow {
  _ClassRow(this.grade, this.section);
  final String grade;
  final String section;
  int students = 0, present = 0, absent = 0, leave = 0, unmarked = 0;
  String get name => '$grade-$section';
  double get marked => students == 0 ? 0 : (students - unmarked) / students;
}

class _SchoolErpDashboardViewState extends State<SchoolErpDashboardView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final boxes = {
          SchoolCollection.students.box,
          SchoolCollection.attendance.box,
          SchoolCollection.teachers.box,
          SchoolCollection.bookLoans.box,
          SchoolCollection.auditLogs.box,
        }.where(Hive.isBoxOpen).map((b) => DebouncedBoxListenable.shared(Hive.box(b))).toList();
        return ListenableBuilder(listenable: Listenable.merge(boxes), builder: (context, _) => _build(context));
      },
    );
  }

  Widget _build(BuildContext context) {
    final c = context.comfort;
    final now = DateTime.now();
    final today = SchoolDailyRules.day(now);
    final roster = SchoolStudentService.roster(widget.branchId);
    final cal = SchoolDailyService.calendar(widget.branchId);
    final enrolled = roster.students.where((s) => StudentRules.isActiveOn(s, today)).toList();
    final day = SchoolDailyService.day(widget.branchId, today);
    final working = cal.isWorkingDay(today);

    // Today by class.
    final classes = <String, _ClassRow>{};
    for (final s in enrolled) {
      final row = classes.putIfAbsent('${s.grade}|${s.section}', () => _ClassRow(s.grade, s.section));
      row.students++;
      switch (day[s.id]?.attendance) {
        case SchoolAttendance.present:
          row.present++;
        case SchoolAttendance.absent:
        case SchoolAttendance.leaveRequested:
          row.absent++;
        case SchoolAttendance.leave:
          row.leave++;
        case null:
          row.unmarked++;
      }
    }
    final classRows = classes.values.toList()
      ..sort((a, b) {
        final g = SchoolConstants.grades.indexOf(a.grade).compareTo(SchoolConstants.grades.indexOf(b.grade));
        return g != 0 ? g : a.section.compareTo(b.section);
      });
    final present = classRows.fold<int>(0, (a, r) => a + r.present);
    final leave = classRows.fold<int>(0, (a, r) => a + r.leave);
    final unmarked = classRows.fold<int>(0, (a, r) => a + r.unmarked);
    final rate = enrolled.isEmpty ? 0.0 : (present + leave) / enrolled.length;

    // Staff today.
    final teacherLog = SchoolLocalStorage.getTeacherLogCached(widget.branchId, SchoolDailyRules.ymd(today));
    final teacherEntries = teacherLog?['entries'] is Map ? (teacherLog!['entries'] as Map).values : const [];
    final staffPresent = teacherEntries.where((e) => e is Map && (e['status'] ?? '').toString().toLowerCase() == 'present').length;
    final staff = SchoolLocalStorage.getAllTeachersCached(widget.branchId).where((t) => (t['status'] ?? 'active').toString() == 'active').length;

    // Library and admissions.
    final lib = SchoolLibraryService.snapshot(widget.branchId);
    final out = lib.loans.where((l) => l.isOut).length;
    final overdue = lib.loans.where((l) => l.isOverdue(now)).length;
    final newThisMonth = roster.students.where((s) {
      final d = DateTime.tryParse(s.admissionDate);
      return !s.isVoid && d != null && d.year == now.year && d.month == now.month;
    }).length;

    // Attention needed.
    final logs = SchoolDailyService.month(widget.branchId, now.year, now.month);
    final unrecorded = SchoolDailyRules.unrecordedDays(students: enrolled, year: now.year, month: now.month, cal: cal, logs: logs, now: now)
        .where((d) => d.isBefore(today))
        .toList();
    final ptm = cal.ptmFor(now.year, now.month);
    final suspended = roster.count(StudentStatus.suspended);
    final clashes = roster.admissionConflicts.length;
    final attention = <(IconData, Color, String, String)>[
      if (working && unmarked > 0)
        (GIcons.attendance, c.warning, '$unmarked ${unmarked == 1 ? 'student' : 'students'} not marked today', 'Daily log'),
      if (unrecorded.isNotEmpty)
        (GIcons.calendar, c.warning, '${unrecorded.length} earlier working ${unrecorded.length == 1 ? 'day has' : 'days have'} unmarked students this month',
            'Needed before the fee month can close'),
      if (overdue > 0) (GIcons.overdue, c.danger, '$overdue overdue library ${overdue == 1 ? 'book' : 'books'}', 'Library › Loans'),
      if (suspended > 0) (GIcons.block, c.warning, '$suspended suspended ${suspended == 1 ? 'student' : 'students'}', 'Students › Suspended'),
      if (clashes > 0) (GIcons.warning, c.danger, '$clashes admission ${clashes == 1 ? 'number is' : 'numbers are'} used twice', 'Students'),
      if (ptm.status == SchoolPtmStatus.scheduled)
        (GIcons.team, c.info, 'PTM on ${dailyDateLabel(ptm.date)}', today.isAfter(DateTime.parse(ptm.date)) ? 'Record which parents came' : 'Scheduled'),
    ];

    // Recent activity.
    final activity = SchoolLocalStorage.getAuditLogsCached(widget.branchId).take(8).toList();

    final stats = SchoolErpStatStrip([
      SchoolErpStat(label: 'Students', value: GFormat.count(enrolled.length), icon: GIcons.student, caption: '$newThisMonth new this month'),
      SchoolErpStat(
        label: 'Attendance today',
        value: working ? GFormat.percent(rate) : '—',
        icon: GIcons.attendance,
        color: !working ? c.textMuted : rate >= 0.9 ? c.success : rate >= 0.75 ? c.warning : c.danger,
        caption: working ? '$present present · $leave on leave' : (cal.kindOf(today) == SchoolDayKind.holiday ? 'Holiday' : 'Day off'),
      ),
      SchoolErpStat(
        label: 'Not marked',
        value: working ? GFormat.count(unmarked) : '—',
        icon: GIcons.warning,
        color: working && unmarked > 0 ? c.warning : c.success,
        caption: working ? (unmarked == 0 ? 'All classes done' : 'Today') : 'No school today',
      ),
      SchoolErpStat(label: 'Staff present', value: '$staffPresent / $staff', icon: GIcons.teacher, color: c.info),
      SchoolErpStat(label: 'Books out', value: GFormat.count(out), icon: GIcons.bookIssue, color: overdue > 0 ? c.danger : c.chart2, caption: '$overdue overdue'),
    ]);

    final classTable = SchoolErpCard(
      title: 'Today by class',
      subtitle: DateFormat('EEEE d MMMM yyyy').format(now),
      child: SchoolErpTable<_ClassRow>(
        rows: classRows,
        rowKey: (r) => r.name,
        pageSizes: const [50, 100],
        empty: const AppEmptyState(icon: GIcons.classroom, title: 'No students yet', compact: true),
        columns: [
          SchoolErpColumn(label: 'Class', flex: 2, sortValue: (r) => SchoolConstants.grades.indexOf(r.grade) * 10 + r.section.codeUnitAt(0),
              cell: (r) => SchoolErpCell.primary(context, r.name)),
          SchoolErpColumn(label: 'Students', flex: 2, numeric: true, sortValue: (r) => r.students, cell: (r) => SchoolErpCell.mono(context, '${r.students}')),
          SchoolErpColumn(label: 'Present', flex: 2, numeric: true, sortValue: (r) => r.present, cell: (r) => SchoolErpCell.mono(context, '${r.present}', color: c.success)),
          SchoolErpColumn(label: 'Absent', flex: 2, numeric: true, sortValue: (r) => r.absent,
              cell: (r) => SchoolErpCell.mono(context, '${r.absent}', color: r.absent > 0 ? c.danger : c.textMuted)),
          SchoolErpColumn(label: 'Leave', flex: 2, numeric: true, hideBelow: 520, sortValue: (r) => r.leave, cell: (r) => SchoolErpCell.mono(context, '${r.leave}')),
          SchoolErpColumn(
            label: 'Marked',
            flex: 4,
            sortValue: (r) => r.marked,
            cell: (r) => GProgressBar(
              value: r.marked,
              color: r.unmarked == 0 ? c.success : c.warning,
              label: r.unmarked == 0 ? 'Done' : '${r.unmarked} left',
              trailing: '${(r.marked * 100).round()}%',
            ),
          ),
        ],
      ),
    );

    final attentionCard = SchoolErpCard(
      title: 'Attention needed',
      expand: false,
      child: attention.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Gsp.sp4),
              child: Row(children: [
                Icon(GIcons.checkCircle, color: c.success),
                const SizedBox(width: Gsp.sp2),
                Expanded(child: Text('Nothing needs attention right now.', style: GText.body2(c.textSecondary))),
              ]),
            )
          : Column(children: [
              for (final (i, a) in attention.indexed)
                Container(
                  decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: c.border))),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp3),
                  child: Row(children: [
                    Icon(a.$1, size: GIconSize.md, color: a.$2),
                    const SizedBox(width: Gsp.sp3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(a.$3, style: GText.body2Bold(c.textPrimary)),
                        Text(a.$4, style: GText.caption(c.textMuted)),
                      ]),
                    ),
                  ]),
                ),
            ]),
    );

    final activityCard = SchoolErpCard(
      title: 'Recent activity',
      expand: false,
      child: activity.isEmpty
          ? Padding(padding: const EdgeInsets.all(Gsp.sp4), child: Text('No activity yet.', style: GText.body2(c.textMuted)))
          : Column(children: [
              for (final (i, a) in activity.indexed)
                Container(
                  decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: c.border))),
                  padding: const EdgeInsets.symmetric(horizontal: Gsp.sp4, vertical: Gsp.sp2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text((a['details'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: GText.body2(c.textPrimary)),
                        Text('${a['user'] ?? 'System'} · ${_ago(DateTime.tryParse((a['timestamp'] ?? '').toString()), now)}',
                            style: GText.caption(c.textMuted)),
                      ]),
                    ),
                  ]),
                ),
            ]),
    );

    return SchoolErpPage(
      breadcrumbs: const ['School', 'Overview'],
      title: 'Dashboard',
      subtitle: 'Today at a glance · ${StudentRules.academicYearOf(now)} session',
      icon: GIcons.dashboard,
      stats: stats,
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < 1000) {
          return ListView(children: [
            SizedBox(height: 420, child: classTable),
            const SizedBox(height: Gsp.sp4),
            attentionCard,
            const SizedBox(height: Gsp.sp4),
            activityCard,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 3, child: classTable),
          const SizedBox(width: Gsp.sp4),
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                attentionCard,
                const SizedBox(height: Gsp.sp4),
                activityCard,
              ]),
            ),
          ),
        ]);
      }),
    );
  }

  static String _ago(DateTime? at, DateTime now) {
    if (at == null) return '';
    final d = now.difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return DateFormat('d MMM, h:mm a').format(at);
  }
}

String dailyDateLabel(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : DateFormat('EEE d MMM').format(d);
}
