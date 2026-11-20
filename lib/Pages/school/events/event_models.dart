// lib/pages/school/events/event_models.dart
//
// Bimonthly compulsory events (School ERP plan §1 item 9, §3.4, Phase 5):
//   Bazm-e-Adab, speech gala, training, field trip — participation compulsory,
//   absences flagged on the parent report card. Report-only: NEVER affects fees.

import '../models/school_student.dart';
import '../students/student_rules.dart';

enum SchoolEventType {
  bazmEAdab('bazmEAdab', 'Bazm-e-Adab', 'بزمِ ادب'),
  speechGala('speechGala', 'Speech gala', 'تقریری مقابلہ'),
  training('training', 'Training workshop', 'تربیتی نشست'),
  fieldTrip('fieldTrip', 'Field trip', 'تعلیمی سیر'),
  other('other', 'School event', 'سکول تقریب');

  const SchoolEventType(this.value, this.label, this.urdu);
  final String value;
  final String label;
  final String urdu;

  static SchoolEventType parse(Object? raw) {
    final s = (raw ?? '').toString().trim();
    return SchoolEventType.values.firstWhere((e) => e.value == s || e.name == s, orElse: () => SchoolEventType.bazmEAdab);
  }
}

enum SchoolEventStatus {
  scheduled('scheduled', 'Scheduled'),
  held('held', 'Held'),
  cancelled('cancelled', 'Cancelled');

  const SchoolEventStatus(this.value, this.label);
  final String value;
  final String label;

  static SchoolEventStatus parse(Object? raw) {
    final s = (raw ?? '').toString().trim();
    return SchoolEventStatus.values.firstWhere((e) => e.value == s || e.name == s, orElse: () => SchoolEventStatus.scheduled);
  }
}

enum EventAttendanceStatus {
  present('present', 'Present', 'P'),
  absent('absent', 'Absent', 'A'),
  excused('excused', 'Excused', 'E');

  const EventAttendanceStatus(this.value, this.label, this.short);
  final String value;
  final String label;
  final String short;

  static EventAttendanceStatus? parse(Object? raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    for (final v in EventAttendanceStatus.values) {
      if (v.value == s || v.short.toLowerCase() == s) return v;
    }
    return null;
  }
}

class SchoolEvent {
  final String id;
  final String title;
  final SchoolEventType type;
  final String date; // yyyy-MM-dd
  final String academicYear;
  final String description;

  /// Classes invited; empty = whole school.
  final List<String> targetGrades;
  final SchoolEventStatus status;

  /// studentId → present / absent / excused.
  final Map<String, EventAttendanceStatus> attendance;
  final String createdBy;
  final String lastModified;

  const SchoolEvent({
    required this.id,
    required this.title,
    required this.type,
    required this.date,
    this.academicYear = '',
    this.description = '',
    this.targetGrades = const [],
    this.status = SchoolEventStatus.scheduled,
    this.attendance = const {},
    this.createdBy = '',
    this.lastModified = '',
  });

  bool appliesTo(SchoolStudent s) {
    if (s.isVoid) return false;
    final d = DateTime.tryParse(date);
    if (d != null && !StudentRules.isActiveOn(s, d)) return false;
    if (targetGrades.isEmpty) return true;
    return targetGrades.contains(s.grade);
  }

  int get presentCount => attendance.values.where((v) => v == EventAttendanceStatus.present).length;
  int get absentCount => attendance.values.where((v) => v == EventAttendanceStatus.absent).length;
  int get excusedCount => attendance.values.where((v) => v == EventAttendanceStatus.excused).length;

  factory SchoolEvent.fromMap(String id, Map m) {
    final rawAtt = m['attendance'];
    final att = <String, EventAttendanceStatus>{};
    if (rawAtt is Map) {
      for (final e in rawAtt.entries) {
        final st = EventAttendanceStatus.parse(e.value);
        if (st != null) att[e.key.toString()] = st;
      }
    }
    final grades = (m['targetGrades'] is List)
        ? (m['targetGrades'] as List).map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    final date = (m['date'] ?? '').toString();
    final d = DateTime.tryParse(date);
    return SchoolEvent(
      id: id,
      title: (m['title'] ?? '').toString(),
      type: SchoolEventType.parse(m['type']),
      date: date,
      academicYear: (m['academicYear'] ?? '').toString().isNotEmpty
          ? m['academicYear'].toString()
          : (d != null ? StudentRules.academicYearOf(d) : ''),
      description: (m['description'] ?? '').toString(),
      targetGrades: grades,
      status: SchoolEventStatus.parse(m['status']),
      attendance: att,
      createdBy: (m['createdBy'] ?? '').toString(),
      lastModified: (m['lastModified'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'type': type.value,
        'date': date,
        'academicYear': academicYear,
        'description': description,
        'targetGrades': targetGrades,
        'status': status.value,
        'attendance': {for (final e in attendance.entries) e.key: e.value.value},
        if (createdBy.isNotEmpty) 'createdBy': createdBy,
      };
}

/// One student's participation summary across compulsory bimonthly events
/// (shown on Report Cards; absences are flagged, no fee impact).
class StudentEventSummary {
  final int totalHeld;
  final int attended;
  final int absent;
  final int excused;
  final List<SchoolEvent> missedEvents;

  const StudentEventSummary({
    required this.totalHeld,
    required this.attended,
    required this.absent,
    required this.excused,
    required this.missedEvents,
  });

  bool get hasAbsences => absent > 0;

  static StudentEventSummary forStudent(
    SchoolStudent student,
    Iterable<SchoolEvent> events, {
    String? academicYear,
  }) {
    var total = 0;
    var present = 0;
    var absent = 0;
    var excused = 0;
    final missed = <SchoolEvent>[];

    for (final ev in events) {
      if (ev.status != SchoolEventStatus.held) continue;
      if (academicYear != null && academicYear.isNotEmpty && ev.academicYear.isNotEmpty && ev.academicYear != academicYear) {
        continue;
      }
      if (!ev.appliesTo(student)) continue;
      final mark = ev.attendance[student.id];
      if (mark == null) continue;
      total++;
      switch (mark) {
        case EventAttendanceStatus.present:
          present++;
        case EventAttendanceStatus.absent:
          absent++;
          missed.add(ev);
        case EventAttendanceStatus.excused:
          excused++;
      }
    }
    missed.sort((a, b) => b.date.compareTo(a.date));
    return StudentEventSummary(
      totalHeld: total,
      attended: present,
      absent: absent,
      excused: excused,
      missedEvents: missed,
    );
  }
}
