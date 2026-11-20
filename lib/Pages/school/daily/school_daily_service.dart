// lib/pages/school/daily/school_daily_service.dart
//
// Daily log and calendar reads/writes over the School store (Phase 3).
// Screens call this; the rules are in daily_rules.dart.

import '../core/school_store.dart';
import 'daily_models.dart';
import 'daily_rules.dart';

class SchoolDailyException implements Exception {
  final String message;
  const SchoolDailyException(this.message);
  @override
  String toString() => message;
}

abstract final class SchoolDailyService {
  static const String _settingsId = 'settings';
  static String _holidayId(String date) => 'hol-$date';
  static String _ptmId(String month) => 'ptm-$month';

  /// Hive boxes the daily screens listen to.
  static List<String> get watchedBoxes => [SchoolCollection.attendance.box, SchoolCollection.students.box];

  // ── Read ──────────────────────────────────────────────────────────────────

  static SchoolCalendar calendar(String branchId) {
    final rows = SchoolStore.all(SchoolCollection.calendar, branchId);
    var settings = const SchoolCalendarSettings();
    final holidays = <String, SchoolHoliday>{};
    final ptms = <String, SchoolPtm>{};
    final closed = <String>{};
    for (final r in rows) {
      final id = (r['id'] ?? '').toString();
      if (id == _settingsId) {
        settings = SchoolCalendarSettings.fromMap(r);
      } else if (id.startsWith('hol-')) {
        final h = SchoolHoliday.fromMap(r);
        if (h.active && h.date.isNotEmpty) holidays[h.date] = h;
      } else if (id.startsWith('ptm-')) {
        final p = SchoolPtm.fromMap(r);
        if (p.month.isNotEmpty) ptms[p.month] = p;
      } else if (id.startsWith('month-') && r['closed'] == true) {
        closed.add(id.substring(6));
      }
    }
    return SchoolCalendar(settings: settings, holidays: holidays, ptms: ptms, closedMonths: closed);
  }

  /// One day's entries by student id.
  static Map<String, SchoolDayEntry> day(String branchId, DateTime date) {
    final doc = SchoolStore.get(SchoolCollection.attendance, branchId, SchoolDailyRules.ymd(date));
    final raw = doc?['entries'];
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is Map) e.key.toString(): SchoolDayEntry.fromMap(e.key.toString(), e.value as Map),
    };
  }

  /// Every day of a month: yyyy-MM-dd → entries.
  static Map<String, Map<String, SchoolDayEntry>> month(String branchId, int year, int month) => {
        for (final d in SchoolDailyRules.daysOfMonth(year, month)) SchoolDailyRules.ymd(d): day(branchId, d),
      };

  // ── Daily log ─────────────────────────────────────────────────────────────

  /// Saves the changed entries of one day. Only [changes] are written (each
  /// stamped with `updatedAt` / `updatedBy`), so marks another PC saved for
  /// other students that day are kept.
  static Future<int> saveDay({
    required String branchId,
    required DateTime date,
    required Map<String, SchoolDayEntry> changes,
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final cal = calendar(branchId);
    final block = SchoolDailyRules.editBlock(date: date, now: at, cal: cal, isPrincipal: isPrincipal);
    if (block != null) throw SchoolDailyException(SchoolDailyRules.explainBlock(block, cal, date));
    if (changes.isEmpty) return 0;

    final key = SchoolDailyRules.ymd(date);
    final existingDoc = SchoolStore.get(SchoolCollection.attendance, branchId, key);
    final entries = <String, dynamic>{
      if (existingDoc?['entries'] is Map) ...Map<String, dynamic>.from(existingDoc!['entries'] as Map),
    };
    final stamp = at.toIso8601String();
    var changed = 0;
    for (final c in changes.entries) {
      final before = entries[c.key] is Map ? SchoolDayEntry.fromMap(c.key, entries[c.key] as Map) : null;
      if (before != null && before.sameMarks(c.value)) continue;
      // Keep fields this screen does not edit (biometric time/source, …).
      final old = entries[c.key] is Map ? Map<String, dynamic>.from(entries[c.key] as Map) : <String, dynamic>{};
      old.remove('attendance');
      entries[c.key] = {...old, ...c.value.copyWith(updatedAt: stamp, updatedBy: editorName).toMap()};
      changed++;
    }
    if (changed == 0) return 0;

    await SchoolStore.put(
      SchoolCollection.attendance,
      branchId: branchId,
      id: key,
      updatedBy: editorName,
      now: at,
      data: {'date': key, 'lastUpdated': stamp, 'entries': entries},
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'DAILY_LOG_SAVED',
      user: editorName,
      details: 'Daily log $key: $changed ${changed == 1 ? 'student' : 'students'} marked',
      entity: 'daily_log',
      entityId: key,
    );
    return changed;
  }

  // ── Calendar ──────────────────────────────────────────────────────────────

  static Future<void> saveSettings({required String branchId, required SchoolCalendarSettings settings, required String editorName}) async {
    if (settings.weeklyOff.length > 2) throw const SchoolDailyException('At most two weekly days off.');
    if (SchoolDailyRules.minutesOf(settings.startTime) == null) throw const SchoolDailyException('Start time must look like 08:00.');
    await SchoolStore.put(SchoolCollection.calendar, branchId: branchId, id: _settingsId, updatedBy: editorName, data: settings.toMap());
    await SchoolStore.audit(branchId: branchId, action: 'CALENDAR_SETTINGS', user: editorName, details: 'Calendar settings updated', after: settings.toMap());
  }

  /// Adds (or re-activates) a holiday. Refused for a closed month or a day
  /// that already has marks (the marks would silently stop counting).
  static Future<void> addHoliday({
    required String branchId,
    required DateTime date,
    required String name,
    required String editorName,
  }) async {
    final cal = calendar(branchId);
    if (cal.isClosed(date)) throw const SchoolDailyException('That month is closed.');
    if (name.trim().isEmpty) throw const SchoolDailyException('Please name the holiday.');
    final marked = day(branchId, date).values.where((e) => e.isMarked).length;
    if (marked > 0) {
      throw SchoolDailyException('$marked ${marked == 1 ? 'student is' : 'students are'} already marked on this day. '
          'A holiday would make those marks stop counting; clear the day first or pick another date.');
    }
    final d = SchoolDailyRules.ymd(date);
    await SchoolStore.put(SchoolCollection.calendar,
        branchId: branchId,
        id: _holidayId(d),
        updatedBy: editorName,
        data: SchoolHoliday(date: d, name: name.trim(), addedBy: editorName).toMap());
    await SchoolStore.audit(branchId: branchId, action: 'HOLIDAY_ADDED', user: editorName, details: 'Holiday $d: ${name.trim()}');
  }

  static Future<void> removeHoliday({required String branchId, required String date, required String editorName}) async {
    final d = DateTime.tryParse(date);
    if (d != null && calendar(branchId).isClosed(d)) throw const SchoolDailyException('That month is closed.');
    await SchoolStore.put(SchoolCollection.calendar, branchId: branchId, id: _holidayId(date), updatedBy: editorName, data: {'active': false});
    await SchoolStore.audit(branchId: branchId, action: 'HOLIDAY_REMOVED', user: editorName, details: 'Holiday $date removed');
  }

  /// Schedules or moves the month's PTM. Moving keeps the earlier date in the
  /// history. The new date must be a working day in the same month.
  static Future<void> schedulePtm({
    required String branchId,
    required DateTime date,
    required String editorName,
    String reason = '',
  }) async {
    final cal = calendar(branchId);
    if (cal.isClosed(date)) throw const SchoolDailyException('That month is closed.');
    if (!cal.isWorkingDay(date)) throw const SchoolDailyException('PTM must be on a working day (not a holiday or day off).');
    final current = cal.ptmFor(date.year, date.month);
    final saved = cal.ptms.containsKey(current.month);
    final newDate = SchoolDailyRules.ymd(date);
    final history = [
      ...current.history,
      if (saved && current.date != newDate)
        '${current.date} → $newDate by $editorName${reason.trim().isEmpty ? '' : ': ${reason.trim()}'}',
    ];
    await SchoolStore.put(SchoolCollection.calendar,
        branchId: branchId,
        id: _ptmId(current.month),
        updatedBy: editorName,
        data: SchoolPtm(
          month: current.month,
          date: newDate,
          status: current.status == SchoolPtmStatus.cancelled ? SchoolPtmStatus.scheduled : current.status,
          attended: current.attended,
          history: history,
          note: current.note,
        ).toMap());
    await SchoolStore.audit(
        branchId: branchId, action: 'PTM_SCHEDULED', user: editorName, details: 'PTM for ${current.month} on $newDate${saved ? ' (moved)' : ''}');
  }

  static Future<void> setPtmStatus({
    required String branchId,
    required int year,
    required int month,
    required SchoolPtmStatus status,
    required String editorName,
    String note = '',
    DateTime? now,
  }) async {
    final cal = calendar(branchId);
    final ptm = cal.ptmFor(year, month);
    if (cal.closedMonths.contains(ptm.month)) throw const SchoolDailyException('That month is closed.');
    final date = DateTime.tryParse(ptm.date);
    if (status == SchoolPtmStatus.held && date != null && SchoolDailyRules.day(date).isAfter(SchoolDailyRules.day(now ?? DateTime.now()))) {
      throw const SchoolDailyException('The PTM date has not come yet.');
    }
    await SchoolStore.put(SchoolCollection.calendar,
        branchId: branchId,
        id: _ptmId(ptm.month),
        updatedBy: editorName,
        data: {...ptm.toMap(), 'status': status.name, if (note.trim().isNotEmpty) 'note': note.trim()});
    await SchoolStore.audit(branchId: branchId, action: 'PTM_${status.name.toUpperCase()}', user: editorName, details: 'PTM ${ptm.month}: ${status.name}');
  }

  /// Records which parents came. Marks the PTM as held.
  static Future<void> savePtmAttendance({
    required String branchId,
    required int year,
    required int month,
    required Map<String, bool> attended,
    required String editorName,
    DateTime? now,
  }) async {
    final cal = calendar(branchId);
    final ptm = cal.ptmFor(year, month);
    if (cal.closedMonths.contains(ptm.month)) throw const SchoolDailyException('That month is closed.');
    if (ptm.status == SchoolPtmStatus.cancelled) throw const SchoolDailyException('This PTM was cancelled.');
    final date = DateTime.tryParse(ptm.date);
    if (date != null && SchoolDailyRules.day(date).isAfter(SchoolDailyRules.day(now ?? DateTime.now()))) {
      throw const SchoolDailyException('The PTM date has not come yet.');
    }
    await SchoolStore.put(SchoolCollection.calendar,
        branchId: branchId,
        id: _ptmId(ptm.month),
        updatedBy: editorName,
        data: {...ptm.toMap(), 'status': SchoolPtmStatus.held.name, 'attended': {...ptm.attended, ...attended}});
    await SchoolStore.audit(
      branchId: branchId,
      action: 'PTM_ATTENDANCE',
      user: editorName,
      details: 'PTM ${ptm.month}: ${attended.values.where((v) => v).length} of ${attended.length} parents came',
    );
  }
}
