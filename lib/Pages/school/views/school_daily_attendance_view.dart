// lib/pages/school/views/school_daily_attendance_view.dart
//
// School daily log (School ERP plan §3.4, Phase 3, 2026-11-17).
//   Day      — mark a class: attendance, on time, uniform, behaviour, message reply
//   Month    — each student's counts for the six fee rules, unmarked days
//   Calendar — holidays, the month's PTM, school-day settings
// Edit window: teachers today + the past N days (setting, default 3) and only
// their own class; Principal / School Admin any day of an open month. Nobody
// marks future days, holidays, days off or closed months.
// Replaces the old attendance list, whose leave toggle wrote straight to
// Firestore and whose unmarked days counted as absent.

import 'package:flutter/material.dart';
import 'package:gmwf_ui/gmwf_ui.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../utils/debounced_box_listenable.dart';
import '../daily/school_daily_service.dart';
import '../daily/views/daily_calendar_tab.dart';
import '../daily/views/daily_common.dart';
import '../daily/views/daily_events_tab.dart';
import '../daily/views/daily_log_tab.dart';
import '../daily/views/daily_month_tab.dart';
import '../core/school_store.dart';
import '../students/school_student_service.dart';
import '../utils/school_auth_helper.dart';
import '../utils/school_local_storage.dart';
import '../widgets/erp/school_erp.dart';

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

enum _Tab { day, month, calendar, events }

class _SchoolDailyAttendanceViewState extends State<SchoolDailyAttendanceView> {
  late final Future<void> _ready = SchoolLocalStorage.ensureBoxesOpen();
  final _dayKey = GlobalKey<DailyLogTabState>();
  _Tab _tab = _Tab.day;
  DateTime _date = DateTime.now();
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  bool get _isTeacher => SchoolAuthHelper.isTeacher(widget.userRole);
  bool get _isPrincipal => SchoolAuthHelper.isAdminOrPrincipal(widget.userRole);

  Future<void> _switchTab(_Tab t) async {
    if (t == _tab) return;
    if (_tab == _Tab.day && !(await (_dayKey.currentState?.confirmDiscard() ?? Future.value(true)))) return;
    setState(() => _tab = t);
  }

  void _openDay(DateTime d) => setState(() {
        _date = d;
        _tab = _Tab.day;
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final boxes = {...SchoolDailyService.watchedBoxes, SchoolCollection.calendar.box}
            .where(Hive.isBoxOpen)
            .map((b) => DebouncedBoxListenable.shared(Hive.box(b)))
            .toList();
        return ListenableBuilder(listenable: Listenable.merge(boxes), builder: (context, _) => _build(context));
      },
    );
  }

  Widget _build(BuildContext context) {
    final c = context.comfort;
    final teacherGrades = _isTeacher
        ? SchoolAuthHelper.getTeacherAssignedGrades(widget.branchId, widget.userRole, widget.editorName)
        : const <String>[];

    if (_isTeacher && teacherGrades.isEmpty) {
      return ColoredBox(
        color: c.background,
        child: const Center(
          child: AppEmptyState(
            icon: GIcons.classroom,
            title: 'No class assigned yet',
            subtitle: 'Teachers mark only their own class. Ask the Principal to assign your homeroom class.',
          ),
        ),
      );
    }

    final ctx = DailyContext(
      branchId: widget.branchId,
      editorName: widget.editorName,
      isPrincipal: _isPrincipal,
      isTeacher: _isTeacher,
      teacherGrades: teacherGrades,
      roster: SchoolStudentService.roster(widget.branchId),
      calendar: SchoolDailyService.calendar(widget.branchId),
    );

    const labels = {_Tab.day: 'Day', _Tab.month: 'Month', _Tab.calendar: 'Calendar', _Tab.events: 'Events'};

    final body = switch (_tab) {
      _Tab.day => DailyLogTab(key: _dayKey, ctx: ctx, date: _date, onDateChanged: (d) => setState(() => _date = d)),
      _Tab.month => DailyMonthTab(ctx: ctx, month: _month, onMonthChanged: (m) => setState(() => _month = m), onOpenDay: _openDay),
      _Tab.calendar => DailyCalendarTab(ctx: ctx, month: _month, onMonthChanged: (m) => setState(() => _month = m), onOpenDay: _openDay),
      _Tab.events => DailyEventsTab(ctx: ctx),
    };

    return PopScope(
      canPop: !(_dayKey.currentState?.hasChanges ?? false),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await (_dayKey.currentState?.confirmDiscard() ?? Future.value(true));
        if (ok && context.mounted) Navigator.of(context).maybePop();
      },
      child: SchoolErpPage(
        breadcrumbs: const ['School', 'Academics'],
        title: 'Daily log',
        subtitle: 'Attendance, on time, uniform, behaviour, diary reply, PTM and events',
        icon: GIcons.attendance,
        tabs: SchoolErpTabs(
          labels: [for (final t in _Tab.values) labels[t]!],
          icons: const [GIcons.checklist, GIcons.chart, GIcons.calendar, GIcons.event],
          selected: _tab.index,
          onChanged: (i) => _switchTab(_Tab.values[i]),
        ),
        child: body,
      ),
    );
  }
}