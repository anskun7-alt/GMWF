import 'package:cloud_firestore/cloud_firestore.dart';
import 'madrassa_config.dart';

class MadrassaFeeLogic {
  /// Safely converts whatever Map-ish value comes back from Firestore /
  /// Hive / local-storage into a proper `Map<String, dynamic>`. Both
  /// Firestore and Hive can hand back a raw `Map<dynamic, dynamic>` for
  /// nested maps (Hive in particular doesn't reliably preserve generic
  /// type parameters on round-trip even when the data was sanitized to
  /// `Map<String, dynamic>` before being stored), and a direct
  /// `as Map<String, dynamic>` cast on that throws:
  ///   "type '_Map<dynamic, dynamic>' is not a subtype of type
  ///    'Map<String, dynamic>?' in type cast"
  /// `Map<String, dynamic>.from(...)` re-keys everything as Strings
  /// instead of doing an unsafe runtime cast, so this never throws for a
  /// Map of any shape.
  static Map<String, dynamic>? _asStringMap(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static DateTime? parseStudentJoinDate(Map<String, dynamic> studentData) {
    final raw = studentData['joinDate'] ??
        studentData['admissionDate'] ??
        studentData['enrollmentDate'] ??
        studentData['createdDate'] ??
        studentData['createdAt'] ??
        studentData['dateOfAdmission'];
    if (raw == null) return null;
    return _parseDateTime(raw);
  }

  static DateTime _parseDateTime(dynamic val) {
    if (val == null) return DateTime.now();
    if (val is Timestamp) return val.toDate();
    if (val is String) {
      return DateTime.tryParse(val) ?? DateTime.now();
    }
    if (val is DateTime) return val;
    return DateTime.now();
  }

  static Map<String, dynamic> calculateStudentFee({
    required String studentId,
    required Map<String, dynamic> studentData,
    required List<dynamic> logs,
    required MadrassaConfig config,
    required int totalWorkingDays,
    List<DateTime> holidays = const [],
  }) {
    int presentDays = 0;
    int leaveDays = 0;
    int uniformDays = 0;
    int messageDays = 0;
    bool ptmAttended = false;

    for (var doc in logs) {
      Map<String, dynamic>? data;
      if (doc is DocumentSnapshot) {
        data = _asStringMap(doc.data());
      } else if (doc is Map) {
        data = Map<String, dynamic>.from(doc);
      }
      if (data != null) {
        final sLog = _asStringMap(data[studentId]);
        if (sLog != null) {
          final att = sLog['attendance']?.toString();
          final uni = sLog['uniform'];
          if (att == 'present') presentDays++;
          if (att == 'leave') leaveDays++;
          // When a student is on leave, uniform is marked as leave/waived as well,
          // so they are not fined and receive the uniform fee deduction reward.
          if (uni == true || uni == 'leave' || att == 'leave') uniformDays++;
          if (sLog['parentReplied'] == true) messageDays++;
          if (sLog['ptm'] == true) ptmAttended = true;
        }
      }
    }

    // IMPORTANT: `totalWorkingDays` must be computed with the SAME
    // holidays list passed here, i.e. call
    // `getWorkingDaysCount(config.year, config.month, holidays)` at the
    // call site. Both the numerator (`activeWorkingDays`, below) and the
    // denominator (`totalWorkingDays`) now exclude Sundays AND holidays,
    // so a student active on every real working day gets the full
    // `baseFee` (e.g. 23/23 × 3000 = 3000), not a partial amount.
    final activeWorkingDays = _calculateActiveWorkingDays(
      studentData: studentData,
      year: config.year,
      month: config.month,
      holidays: holidays,
    );

    final bool isFeeEnabled = config.enableFees && activeWorkingDays > 0;

    double proRatedBaseFee = (isFeeEnabled && totalWorkingDays > 0)
        ? (activeWorkingDays / totalWorkingDays) * config.baseFee
        : 0;

    double attSavings = (isFeeEnabled && totalWorkingDays > 0)
        ? ((presentDays + leaveDays) / totalWorkingDays) *
            config.attendanceMaxDeduction
        : 0;
    double uniSavings = (isFeeEnabled && totalWorkingDays > 0)
        ? (uniformDays / totalWorkingDays) * config.uniformMaxDeduction
        : 0;
    double msgSavings = (isFeeEnabled && totalWorkingDays > 0)
        ? (messageDays / totalWorkingDays) * config.messageTotalDeduction
        : 0;

    // Check if student joined after the current month's PTM date
    final joinDateVal = parseStudentJoinDate(studentData) ?? DateTime(config.year, config.month, 1);
    final ptmDate = config.getPtmDate();
    final joinDateOnly = DateTime(joinDateVal.year, joinDateVal.month, joinDateVal.day);
    final ptmDateOnly = DateTime(ptmDate.year, ptmDate.month, ptmDate.day);
    final joinAfterPtm = joinDateOnly.isAfter(ptmDateOnly);

    double ptmSavings = (isFeeEnabled && (ptmAttended || joinAfterPtm)) ? config.ptmDeduction : 0;

    double totalSavings = isFeeEnabled ? (attSavings + uniSavings + msgSavings + ptmSavings) : 0.0;
    double amountDue = isFeeEnabled ? (proRatedBaseFee - totalSavings).clamp(0, double.infinity) : 0.0;

    return {
      'present': presentDays,
      'leave': leaveDays,
      'absent': activeWorkingDays > 0 ? (activeWorkingDays - (presentDays + leaveDays)).clamp(0, 9999) : 0,
      'uniform': uniformDays,
      'message': messageDays,
      'ptm': ptmAttended,
      'attSavings': attSavings,
      'uniSavings': uniSavings,
      'msgSavings': msgSavings,
      'ptmSavings': ptmSavings,
      'totalSavings': totalSavings,
      'amountDue': amountDue,
      'activeWorkingDays': activeWorkingDays,
      'proRatedBaseFee': proRatedBaseFee,
      'enableFees': isFeeEnabled,
    };
  }

  static int _calculateActiveWorkingDays({
    required Map<String, dynamic> studentData,
    required int year,
    required int month,
    required List<DateTime> holidays,
  }) {
    final parsedJoin = parseStudentJoinDate(studentData);
    if (parsedJoin == null) {
      // If student has no join date, check if they have any logs or default
      return 0;
    }
    final joinDate = parsedJoin;
    final auditLog = (studentData['auditLog'] as List? ?? [])
        .map((e) => _asStringMap(e) ?? <String, dynamic>{})
        .toList();

    final monthStart = DateTime(year, month, 1);
    final monthEnd = DateTime(year, month + 1, 0);

    // If entire month is before student join date, active working days is 0
    if (monthEnd.isBefore(DateTime(joinDate.year, joinDate.month, joinDate.day))) {
      return 0;
    }

    int activeCount = 0;
    DateTime date = monthStart;
    while (date.isBefore(monthEnd) || date.isAtSameMomentAs(monthEnd)) {
      if (date.weekday != DateTime.sunday) {
        // Exclude holidays
        bool isHoliday = holidays.any((h) => h.year == date.year && h.month == date.month && h.day == date.day);
        if (!isHoliday && _isStudentActiveOnDate(date, joinDate, auditLog)) {
          activeCount++;
        }
      }
      date = date.add(const Duration(days: 1));
    }
    return activeCount;
  }

  static bool _isStudentActiveOnDate(
    DateTime date,
    DateTime joinDate,
    List<Map<String, dynamic>> auditLog,
  ) {
    if (date.isBefore(DateTime(joinDate.year, joinDate.month, joinDate.day))) {
      return false;
    }
    final sortedLog = [...auditLog]..sort((a, b) {
      final dateB = _parseDateTime(b['date']);
      final dateA = _parseDateTime(a['date']);
      return dateB.compareTo(dateA);
    });

    for (var entry in sortedLog) {
      final entryDate = _parseDateTime(entry['date']);
      if (date.isAfter(entryDate) ||
          (date.year == entryDate.year &&
              date.month == entryDate.month &&
              date.day == entryDate.day)) {
        return entry['status'] == 'active';
      }
    }
    return true;
  }

  /// Total working days in the month, excluding BOTH Sundays and the
  /// given holidays. This MUST be called with the same `holidays` list
  /// you pass into `calculateStudentFee`, so the denominator
  /// (`totalWorkingDays`) matches what the numerator
  /// (`activeWorkingDays`) is actually counted against. Example: 30-day
  /// month, 4 Sundays, 3 holidays → returns 23.
  static int getWorkingDaysCount(int year, int month, [List<DateTime> holidays = const []]) {
    int count = 0;
    DateTime date = DateTime(year, month, 1);
    while (date.month == month) {
      if (date.weekday != DateTime.sunday) {
        bool isHoliday = holidays.any((h) => h.year == date.year && h.month == date.month && h.day == date.day);
        if (!isHoliday) count++;
      }
      date = date.add(const Duration(days: 1));
    }
    return count;
  }
}