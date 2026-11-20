// lib/pages/school/daily/daily_models.dart
//
// School daily log and calendar records (School ERP plan §3.4, Phase 3,
// 2026-11-17).
//
// The daily log keeps the existing storage: one document per branch per day
// (`<branch>__log__<yyyy-MM-dd>`, Firestore `school_attendance/<date>`) with
// one entry per student. Entries merge one by one on `updatedAt`, so two PCs
// marking different students on the same day both keep their marks, and the
// biometric machine's "present + time" punches land in the same entry.
//
// Each entry now holds the six things the monthly fee depends on (§1, the
// حلف نامہ form): attendance, on time, uniform, behaviour, message reply
// (diary read + parent signed), plus PTM, which lives on the month's PTM record.

/// The six fee rules (each Rs 2,000 of the Rs 12,000 base; amounts come in Phase 4).
enum SchoolFeeRule {
  attendance('attendance', 'Attendance', 'حاضری'),
  onTime('onTime', 'On time', 'وقت کی پابندی'),
  messageReply('messageReply', 'Message reply', 'پیغام کا جواب'),
  behaviour('behaviour', 'Behaviour', 'رویہ'),
  ptm('ptm', 'PTM', 'والدین اساتذہ میٹنگ'),
  uniform('uniform', 'Uniform', 'یونیفارم');

  const SchoolFeeRule(this.key, this.label, this.urdu);
  final String key;
  final String label;
  final String urdu;

  /// Rules decided from the daily log (PTM comes from the PTM record).
  static const daily = [attendance, onTime, messageReply, behaviour, uniform];
}

enum SchoolAttendance {
  present('present', 'Present', 'P'),
  absent('absent', 'Absent', 'A'),
  leave('leave', 'Leave (approved)', 'L'),
  leaveRequested('leaveRequested', 'Leave requested', 'LR');

  const SchoolAttendance(this.value, this.label, this.short);
  final String value;
  final String label;
  final String short;

  /// Reads old and biometric values too: "P", "A", "L", "late" (= present, not on time).
  static SchoolAttendance? parse(Object? raw) {
    final v = (raw ?? '').toString().trim().toLowerCase();
    switch (v) {
      case 'present':
      case 'p':
      case 'late':
        return SchoolAttendance.present;
      case 'absent':
      case 'a':
        return SchoolAttendance.absent;
      case 'leave':
      case 'l':
      case 'approved_leave':
        return SchoolAttendance.leave;
      case 'leaverequested':
      case 'leave_requested':
      case 'lr':
        return SchoolAttendance.leaveRequested;
    }
    return null;
  }
}

enum SchoolBehaviour { good, needsImprovement }

/// One student's day.
class SchoolDayEntry {
  final String studentId;

  /// Null = not marked yet.
  final SchoolAttendance? attendance;

  /// Null = not set (counts as on time when present, unless a late punch says otherwise).
  final bool? onTime;
  final bool? uniform;
  final SchoolBehaviour? behaviour;
  final String behaviourNote;

  /// Diary read and signed / message answered by the parent.
  final bool parentReplied;
  final String remarks;

  /// Biometric punch time ("08:05 AM"), if any.
  final String time;
  final String source;

  /// Class the student was in that day (class changes mid-month keep their history).
  final String grade;
  final String section;
  final String updatedAt;
  final String updatedBy;

  const SchoolDayEntry({
    required this.studentId,
    this.attendance,
    this.onTime,
    this.uniform,
    this.behaviour,
    this.behaviourNote = '',
    this.parentReplied = false,
    this.remarks = '',
    this.time = '',
    this.source = '',
    this.grade = '',
    this.section = '',
    this.updatedAt = '',
    this.updatedBy = '',
  });

  bool get isMarked => attendance != null;

  factory SchoolDayEntry.fromMap(String studentId, Map m) {
    final status = m['attendance'] ?? m['status'];
    final late = (m['status'] ?? '').toString().toLowerCase() == 'late';
    bool? b(Object? v) => v is bool ? v : (v == null ? null : v.toString() == 'true');
    final beh = (m['behaviour'] ?? '').toString();
    return SchoolDayEntry(
      studentId: studentId,
      attendance: SchoolAttendance.parse(status),
      onTime: late ? false : b(m['onTime']),
      uniform: b(m['uniform']),
      behaviour: beh == 'good'
          ? SchoolBehaviour.good
          : (beh == 'needsImprovement' || beh == 'poor')
              ? SchoolBehaviour.needsImprovement
              : null,
      behaviourNote: (m['behaviourNote'] ?? '').toString(),
      parentReplied: b(m['parentReplied']) ?? false,
      remarks: (m['remarks'] ?? '').toString(),
      time: (m['time'] ?? '').toString(),
      source: (m['source'] ?? '').toString(),
      grade: (m['grade'] ?? '').toString(),
      section: (m['section'] ?? '').toString(),
      updatedAt: (m['updatedAt'] ?? m['timestamp'] ?? '').toString(),
      updatedBy: (m['updatedBy'] ?? '').toString(),
    );
  }

  /// Stored shape. `status` keeps its old name so older screens and the
  /// overview counters still read it.
  Map<String, dynamic> toMap() => {
        if (attendance != null) 'status': attendance!.value,
        if (onTime != null) 'onTime': onTime,
        if (uniform != null) 'uniform': uniform,
        if (behaviour != null) 'behaviour': behaviour!.name,
        if (behaviourNote.isNotEmpty) 'behaviourNote': behaviourNote,
        'parentReplied': parentReplied,
        if (remarks.isNotEmpty) 'remarks': remarks,
        if (time.isNotEmpty) 'time': time,
        if (source.isNotEmpty) 'source': source,
        if (grade.isNotEmpty) 'grade': grade,
        if (section.isNotEmpty) 'section': section,
        'updatedAt': updatedAt,
        if (updatedBy.isNotEmpty) 'updatedBy': updatedBy,
      };

  SchoolDayEntry copyWith({
    SchoolAttendance? attendance,
    bool? onTime,
    bool? uniform,
    SchoolBehaviour? behaviour,
    String? behaviourNote,
    bool? parentReplied,
    String? remarks,
    String? grade,
    String? section,
    String? updatedAt,
    String? updatedBy,
  }) =>
      SchoolDayEntry(
        studentId: studentId,
        attendance: attendance ?? this.attendance,
        onTime: onTime ?? this.onTime,
        uniform: uniform ?? this.uniform,
        behaviour: behaviour ?? this.behaviour,
        behaviourNote: behaviourNote ?? this.behaviourNote,
        parentReplied: parentReplied ?? this.parentReplied,
        remarks: remarks ?? this.remarks,
        time: time,
        source: source,
        grade: grade ?? this.grade,
        section: section ?? this.section,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedBy: updatedBy ?? this.updatedBy,
      );

  /// Same marks (ignores who/when).
  bool sameMarks(SchoolDayEntry o) =>
      attendance == o.attendance &&
      onTime == o.onTime &&
      uniform == o.uniform &&
      behaviour == o.behaviour &&
      behaviourNote == o.behaviourNote &&
      parentReplied == o.parentReplied &&
      remarks == o.remarks;
}

/// Calendar settings for a branch (`school_calendar/settings`).
class SchoolCalendarSettings {
  /// Weekly days off, `DateTime.weekday` numbers (7 = Sunday).
  final Set<int> weeklyOff;

  /// School start ("08:00", 24 h) and grace minutes, used to read late
  /// biometric punches.
  final String startTime;
  final int graceMinutes;

  /// Days back (besides today) a teacher may still edit.
  final int teacherEditDays;

  /// Whether "Leave" can be marked (replaces the old executive toggle that
  /// wrote straight to Firestore).
  final bool allowLeave;

  const SchoolCalendarSettings({
    this.weeklyOff = const {DateTime.sunday},
    this.startTime = '08:00',
    this.graceMinutes = 10,
    this.teacherEditDays = 3,
    this.allowLeave = true,
  });

  factory SchoolCalendarSettings.fromMap(Map? m) {
    if (m == null) return const SchoolCalendarSettings();
    final off = (m['weeklyOff'] is List)
        ? (m['weeklyOff'] as List).map((e) => int.tryParse(e.toString())).whereType<int>().where((d) => d >= 1 && d <= 7).toSet()
        : {DateTime.sunday};
    return SchoolCalendarSettings(
      weeklyOff: off,
      startTime: (m['startTime'] ?? '08:00').toString(),
      graceMinutes: int.tryParse('${m['graceMinutes']}') ?? 10,
      teacherEditDays: (int.tryParse('${m['teacherEditDays']}') ?? 3).clamp(0, 31),
      allowLeave: m['allowLeave'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
        'weeklyOff': (weeklyOff.toList()..sort()),
        'startTime': startTime,
        'graceMinutes': graceMinutes,
        'teacherEditDays': teacherEditDays,
        'allowLeave': allowLeave,
      };

  SchoolCalendarSettings copyWith({Set<int>? weeklyOff, String? startTime, int? graceMinutes, int? teacherEditDays, bool? allowLeave}) =>
      SchoolCalendarSettings(
        weeklyOff: weeklyOff ?? this.weeklyOff,
        startTime: startTime ?? this.startTime,
        graceMinutes: graceMinutes ?? this.graceMinutes,
        teacherEditDays: teacherEditDays ?? this.teacherEditDays,
        allowLeave: allowLeave ?? this.allowLeave,
      );
}

/// A holiday (`school_calendar/hol-<yyyy-MM-dd>`). Removing one sets
/// `active: false`; nothing is deleted.
class SchoolHoliday {
  final String date; // yyyy-MM-dd
  final String name;
  final bool active;
  final String addedBy;

  const SchoolHoliday({required this.date, required this.name, this.active = true, this.addedBy = ''});

  factory SchoolHoliday.fromMap(Map m) => SchoolHoliday(
        date: (m['date'] ?? '').toString(),
        name: (m['name'] ?? 'Holiday').toString(),
        active: m['active'] != false,
        addedBy: (m['addedBy'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {'kind': 'holiday', 'date': date, 'name': name, 'active': active, 'addedBy': addedBy};
}

enum SchoolPtmStatus { scheduled, held, cancelled }

/// The month's parent-teacher meeting (`school_calendar/ptm-<yyyy-MM>`).
class SchoolPtm {
  final String month; // yyyy-MM
  final String date; // yyyy-MM-dd
  final SchoolPtmStatus status;

  /// studentId → attended (a parent / guardian came).
  final Map<String, bool> attended;

  /// Earlier dates, newest last ("2026-11-28 → 2026-11-29 by X: reason").
  final List<String> history;
  final String note;

  const SchoolPtm({
    required this.month,
    required this.date,
    this.status = SchoolPtmStatus.scheduled,
    this.attended = const {},
    this.history = const [],
    this.note = '',
  });

  factory SchoolPtm.fromMap(Map m) => SchoolPtm(
        month: (m['month'] ?? '').toString(),
        date: (m['date'] ?? '').toString(),
        status: SchoolPtmStatus.values.firstWhere((s) => s.name == m['status'], orElse: () => SchoolPtmStatus.scheduled),
        attended: (m['attended'] is Map)
            ? {for (final e in (m['attended'] as Map).entries) e.key.toString(): e.value == true}
            : const {},
        history: (m['history'] is List) ? (m['history'] as List).map((e) => e.toString()).toList() : const [],
        note: (m['note'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'kind': 'ptm',
        'month': month,
        'date': date,
        'status': status.name,
        'attended': attended,
        'history': history,
        'note': note,
      };
}
