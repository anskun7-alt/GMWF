// lib/pages/school/events/school_event_service.dart
//
// Bimonthly compulsory events storage over SchoolStore (Phase 5).
// Nothing is deleted — events are cancelled/reopened via status, and every
// change is audited. Strictly report-only (never touches fees).

import '../core/school_store.dart';
import '../students/student_rules.dart';
import '../utils/school_local_storage.dart';
import 'event_models.dart';

class SchoolEventException implements Exception {
  final String message;
  const SchoolEventException(this.message);
  @override
  String toString() => message;
}

abstract final class SchoolEventService {
  static List<String> get watchedBoxes => [SchoolCollection.events.box, SchoolCollection.students.box];

  static List<SchoolEvent> all(String branchId) {
    final list = SchoolStore.all(SchoolCollection.events, branchId)
        .map((m) => SchoolEvent.fromMap((m['id'] ?? '').toString(), m))
        .where((e) => e.id.isNotEmpty)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  static SchoolEvent? byId(String branchId, String id) {
    final raw = SchoolStore.get(SchoolCollection.events, branchId, id);
    return raw == null ? null : SchoolEvent.fromMap(id, raw);
  }

  /// Creates or edits an event (Principal / School Admin only).
  static Future<String> save({
    required String branchId,
    String? existingId,
    required String title,
    required SchoolEventType type,
    required DateTime date,
    String description = '',
    List<String> targetGrades = const [],
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    if (!isPrincipal) {
      throw const SchoolEventException('Only Principal or School Admin can create or edit school events.');
    }
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw const SchoolEventException('Please enter a title for the event.');
    }
    final before = existingId == null ? null : byId(branchId, existingId);
    final id = existingId ?? SchoolLocalStorage.newId('EVT', branchId);
    final ymd = _ymd(date);
    final ev = SchoolEvent(
      id: id,
      title: cleanTitle,
      type: type,
      date: ymd,
      academicYear: StudentRules.academicYearOf(date),
      description: description.trim(),
      targetGrades: targetGrades,
      status: before?.status ?? SchoolEventStatus.scheduled,
      attendance: before?.attendance ?? const {},
      createdBy: before?.createdBy.isNotEmpty == true ? before!.createdBy : editorName,
    );

    await SchoolStore.put(
      SchoolCollection.events,
      branchId: branchId,
      id: id,
      updatedBy: editorName,
      now: now,
      data: ev.toMap(),
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: before == null ? 'EVENT_CREATED' : 'EVENT_UPDATED',
      user: editorName,
      details: '${before == null ? 'Scheduled' : 'Updated'} ${type.label}: "$cleanTitle" on $ymd',
      entity: 'event',
      entityId: id,
      before: before == null ? null : {'title': before.title, 'date': before.date, 'type': before.type.value},
      after: {'title': cleanTitle, 'date': ymd, 'type': type.value},
    );
    return id;
  }

  /// Cancels or reopens an event (no hard delete). Principal / School Admin only.
  static Future<void> setStatus({
    required String branchId,
    required String eventId,
    required SchoolEventStatus status,
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    if (!isPrincipal) {
      throw const SchoolEventException('Only Principal or School Admin can change an event status.');
    }
    final ev = byId(branchId, eventId);
    if (ev == null) throw const SchoolEventException('Event not found.');
    await SchoolStore.put(
      SchoolCollection.events,
      branchId: branchId,
      id: eventId,
      updatedBy: editorName,
      now: now,
      data: {'status': status.value},
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'EVENT_STATUS',
      user: editorName,
      details: '${ev.title}: ${ev.status.label} → ${status.label}',
      entity: 'event',
      entityId: eventId,
      before: {'status': ev.status.value},
      after: {'status': status.value},
    );
  }

  /// Records participation for students (merges with existing marks so class
  /// teachers can each mark their own class without overwriting other classes).
  static Future<void> saveAttendance({
    required String branchId,
    required String eventId,
    required Map<String, EventAttendanceStatus> marks,
    required String editorName,
    DateTime? now,
  }) async {
    final ev = byId(branchId, eventId);
    if (ev == null) throw const SchoolEventException('Event not found.');
    if (ev.status == SchoolEventStatus.cancelled) {
      throw const SchoolEventException('Cannot mark attendance on a cancelled event.');
    }
    final merged = <String, String>{
      for (final e in ev.attendance.entries) e.key: e.value.value,
      for (final e in marks.entries) e.key: e.value.value,
    };
    await SchoolStore.put(
      SchoolCollection.events,
      branchId: branchId,
      id: eventId,
      updatedBy: editorName,
      now: now,
      data: {
        'status': SchoolEventStatus.held.value,
        'attendance': merged,
      },
    );
    final present = marks.values.where((v) => v == EventAttendanceStatus.present).length;
    final absent = marks.values.where((v) => v == EventAttendanceStatus.absent).length;
    await SchoolStore.audit(
      branchId: branchId,
      action: 'EVENT_ATTENDANCE',
      user: editorName,
      details: '${ev.title} (${ev.date}): $present present, $absent absent (${marks.length} marked)',
      entity: 'event',
      entityId: eventId,
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
