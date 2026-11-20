// lib/pages/school/daily/daily_rules.dart
//
// Pure daily-log rules (School ERP plan §3.4, Phase 3). No storage, so the
// fee engine (Phase 4) and the tests use exactly the same logic as the screen.
//
// Decided by the user (2026-11-14):
//   • approved leave counts as present (attendance, on time, uniform, behaviour);
//     message reply still needs an actual reply;
//   • pending leave ("leave requested") counts as absent;
//   • an absent day earns no credit except message reply;
//   • credits are pro-rated over the days that were actually recorded;
//   • events (Bazm-e-Adab, speech gala, training, field trip) do not touch fees.
// Not copied from madrassa: an unmarked day is "not recorded", never "absent",
// and holidays are excluded on both sides.

import '../models/school_student.dart';
import '../students/student_rules.dart';
import 'daily_models.dart';

/// What the calendar says about one day.
enum SchoolDayKind { working, weeklyOff, holiday }

/// Why a day cannot be edited (null = it can).
enum SchoolEditBlock { future, notWorkingDay, monthClosed, tooOld, notYourClass }

class SchoolCalendar {
  final SchoolCalendarSettings settings;

  /// Active holidays by date (yyyy-MM-dd).
  final Map<String, SchoolHoliday> holidays;

  /// PTM by month (yyyy-MM).
  final Map<String, SchoolPtm> ptms;

  /// Closed months (yyyy-MM). Phase 4 closes months; until then this is empty.
  final Set<String> closedMonths;

  const SchoolCalendar({
    this.settings = const SchoolCalendarSettings(),
    this.holidays = const {},
    this.ptms = const {},
    this.closedMonths = const {},
  });

  SchoolDayKind kindOf(DateTime day) {
    if (holidays.containsKey(SchoolDailyRules.ymd(day))) return SchoolDayKind.holiday;
    if (settings.weeklyOff.contains(day.weekday)) return SchoolDayKind.weeklyOff;
    return SchoolDayKind.working;
  }

  bool isWorkingDay(DateTime day) => kindOf(day) == SchoolDayKind.working;
  bool isClosed(DateTime day) => closedMonths.contains(SchoolDailyRules.ym(day));

  /// The month's PTM: the saved one, or the default date if none is saved yet.
  SchoolPtm ptmFor(int year, int month) =>
      ptms[SchoolDailyRules.ym(DateTime(year, month))] ??
      SchoolPtm(month: SchoolDailyRules.ym(DateTime(year, month)), date: SchoolDailyRules.ymd(SchoolDailyRules.defaultPtmDate(year, month, this)));
}

/// Counts for one student in one month (input to the Phase 4 fee engine).
class SchoolMonthSummary {
  final String studentId;
  final int workingDays;

  /// Working days the student was enrolled (admission and status history).
  final int activeDays;

  /// Active working days with a saved mark.
  final int recordedDays;

  /// Qualifying days per daily rule.
  final Map<SchoolFeeRule, int> qualifying;
  final int present;
  final int absent;
  final int leave;
  final int late;

  /// PTM credit (attended, joined after the PTM, PTM cancelled), or null while
  /// the month's PTM has not happened yet.
  final bool? ptm;

  const SchoolMonthSummary({
    required this.studentId,
    required this.workingDays,
    required this.activeDays,
    required this.recordedDays,
    required this.qualifying,
    required this.present,
    required this.absent,
    required this.leave,
    required this.late,
    required this.ptm,
  });

  int get unrecorded => activeDays - recordedDays;
}

abstract final class SchoolDailyRules {
  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String ym(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  static DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

  // ── Calendar ──────────────────────────────────────────────────────────────

  static List<DateTime> daysOfMonth(int year, int month) {
    final n = DateTime(year, month + 1, 0).day;
    return [for (var i = 1; i <= n; i++) DateTime(year, month, i)];
  }

  static List<DateTime> workingDays(int year, int month, SchoolCalendar cal) =>
      daysOfMonth(year, month).where(cal.isWorkingDay).toList();

  /// Default PTM: the last Saturday of the month (the form says "month end");
  /// if that is not a working day, the working day before it.
  static DateTime defaultPtmDate(int year, int month, SchoolCalendar cal) {
    var d = DateTime(year, month + 1, 0);
    while (d.weekday != DateTime.saturday) {
      d = d.subtract(const Duration(days: 1));
    }
    var guard = 0;
    while (!cal.isWorkingDay(d) && d.month == month && guard++ < 31) {
      d = d.subtract(const Duration(days: 1));
    }
    return d.month == month ? d : DateTime(year, month + 1, 0);
  }

  // ── Edit window ───────────────────────────────────────────────────────────

  /// Teachers: today and the past [SchoolCalendarSettings.teacherEditDays]
  /// days. Principal / School Admin: any day of an open month. Nobody: future
  /// days, non-working days, closed months.
  static SchoolEditBlock? editBlock({
    required DateTime date,
    required DateTime now,
    required SchoolCalendar cal,
    required bool isPrincipal,
  }) {
    final d = day(date);
    final today = day(now);
    if (d.isAfter(today)) return SchoolEditBlock.future;
    if (cal.isClosed(d)) return SchoolEditBlock.monthClosed;
    if (!cal.isWorkingDay(d)) return SchoolEditBlock.notWorkingDay;
    if (!isPrincipal && today.difference(d).inDays > cal.settings.teacherEditDays) return SchoolEditBlock.tooOld;
    return null;
  }

  static String explainBlock(SchoolEditBlock b, SchoolCalendar cal, DateTime date) => switch (b) {
        SchoolEditBlock.future => 'This day has not come yet.',
        SchoolEditBlock.monthClosed => 'This month is closed for fees. Ask the Principal for an adjustment.',
        SchoolEditBlock.notWorkingDay => cal.kindOf(date) == SchoolDayKind.holiday
            ? 'Holiday: ${cal.holidays[ymd(date)]?.name ?? ''}. Nothing to mark.'
            : 'Weekly day off. Nothing to mark.',
        SchoolEditBlock.tooOld =>
          'Teachers can edit today and the past ${cal.settings.teacherEditDays} days. Ask the Principal to correct older days.',
        SchoolEditBlock.notYourClass => 'You can only mark your own class.',
      };

  // ── Late from a biometric punch ───────────────────────────────────────────

  /// Minutes after midnight for "08:05 AM", "8:05", "20:05". Null if unreadable.
  static int? minutesOf(String time) {
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s*$').firstMatch(time);
    if (m == null) return null;
    var h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    final ap = m.group(3)?.toLowerCase();
    if (ap == 'pm' && h < 12) h += 12;
    if (ap == 'am' && h == 12) h = 0;
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  }

  /// Whether the student counts as on time that day.
  static bool isOnTime(SchoolDayEntry e, SchoolCalendarSettings s) {
    if (e.onTime != null) return e.onTime!;
    final punch = minutesOf(e.time);
    final start = minutesOf(s.startTime);
    if (punch == null || start == null) return true;
    return punch <= start + s.graceMinutes;
  }

  // ── Credits ───────────────────────────────────────────────────────────────

  /// Whether one day earns [rule]. Unmarked days earn nothing and are not
  /// counted as recorded either.
  static bool qualifies(SchoolFeeRule rule, SchoolDayEntry e, SchoolCalendarSettings s) {
    final a = e.attendance;
    if (a == null) return false;
    if (rule == SchoolFeeRule.messageReply) return e.parentReplied;
    if (a == SchoolAttendance.leave) return true; // approved leave = present (decided)
    if (a != SchoolAttendance.present) return false; // absent / leave requested
    return switch (rule) {
      SchoolFeeRule.attendance => true,
      SchoolFeeRule.onTime => isOnTime(e, s),
      SchoolFeeRule.uniform => e.uniform != false,
      SchoolFeeRule.behaviour => e.behaviour != SchoolBehaviour.needsImprovement,
      SchoolFeeRule.messageReply || SchoolFeeRule.ptm => false,
    };
  }

  /// PTM credit: attended, joined after the PTM, or the PTM was cancelled.
  /// Null while the PTM is still ahead (or today and not marked held).
  static bool? ptmCredit(SchoolStudent s, SchoolPtm ptm, DateTime now) {
    final date = DateTime.tryParse(ptm.date);
    if (ptm.status == SchoolPtmStatus.cancelled) return true;
    if (date == null) return null;
    final admitted = DateTime.tryParse(s.admissionDate);
    if (admitted != null && day(admitted).isAfter(day(date))) return true;
    if (ptm.status != SchoolPtmStatus.held && !day(now).isAfter(day(date))) return null;
    return ptm.attended[s.id] == true;
  }

  /// One student's month. [logs] maps yyyy-MM-dd → that day's entries.
  static SchoolMonthSummary summarize({
    required SchoolStudent student,
    required int year,
    required int month,
    required SchoolCalendar cal,
    required Map<String, Map<String, SchoolDayEntry>> logs,
    required DateTime now,
  }) {
    final working = workingDays(year, month, cal);
    var active = 0, recorded = 0, present = 0, absent = 0, leave = 0, late = 0;
    final q = {for (final r in SchoolFeeRule.daily) r: 0};
    final today = day(now);
    for (final d in working) {
      if (d.isAfter(today)) continue;
      if (!StudentRules.isActiveOn(student, d)) continue;
      active++;
      final e = logs[ymd(d)]?[student.id];
      if (e == null || !e.isMarked) continue;
      recorded++;
      switch (e.attendance!) {
        case SchoolAttendance.present:
          present++;
          if (!isOnTime(e, cal.settings)) late++;
        case SchoolAttendance.leave:
          leave++;
        case SchoolAttendance.absent:
        case SchoolAttendance.leaveRequested:
          absent++;
      }
      for (final r in SchoolFeeRule.daily) {
        if (qualifies(r, e, cal.settings)) q[r] = q[r]! + 1;
      }
    }
    return SchoolMonthSummary(
      studentId: student.id,
      workingDays: working.length,
      activeDays: active,
      recordedDays: recorded,
      qualifying: q,
      present: present,
      absent: absent,
      leave: leave,
      late: late,
      ptm: ptmCredit(student, cal.ptmFor(year, month), now),
    );
  }

  /// Working days up to today that have no marks at all for [students]
  /// (the month cannot be closed while any remain — Phase 4).
  static List<DateTime> unrecordedDays({
    required List<SchoolStudent> students,
    required int year,
    required int month,
    required SchoolCalendar cal,
    required Map<String, Map<String, SchoolDayEntry>> logs,
    required DateTime now,
  }) {
    final out = <DateTime>[];
    for (final d in workingDays(year, month, cal)) {
      if (d.isAfter(day(now))) break;
      final enrolled = students.where((s) => StudentRules.isActiveOn(s, d));
      if (enrolled.isEmpty) continue;
      final dayLog = logs[ymd(d)] ?? const {};
      if (enrolled.any((s) => !(dayLog[s.id]?.isMarked ?? false))) out.add(d);
    }
    return out;
  }
}
