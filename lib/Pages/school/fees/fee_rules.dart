// lib/pages/school/fees/fee_rules.dart
//
// Pure fee maths (School ERP plan §3.5, Phase 4). No storage, so the screen,
// the month close and the tests all use the same numbers.
//
// Per student per month:
//   share   = active working days ÷ working days     (joined / left / suspended)
//   base    = baseFee × share
//   credit  = amount × share × qualifying days ÷ recorded days   (each daily rule)
//   PTM     = amount × share   if attended, joined after it, or it was cancelled
//   due     = max(0, base − credits − concession) + admission fee (admission month)
// Holidays and days off are out of both sides (daily_rules.dart). An unmarked
// day is "not recorded", never "absent"; the month cannot be closed while any
// working day is unrecorded, so a closed sheet never rests on missing marks.

import '../daily/daily_models.dart';
import '../daily/daily_rules.dart';
import '../models/school_student.dart';
import '../students/student_rules.dart';
import 'fee_models.dart';

enum SchoolMonthPayState { paid, partial, unpaid, nothingDue }

/// One month in a student's account.
class SchoolFeeMonth {
  final SchoolFeeSheet sheet;

  /// Adjustments entered for this month after it closed.
  final int adjustments;

  /// Paid toward this month (payments are applied oldest month first).
  final int paid;

  const SchoolFeeMonth({required this.sheet, required this.adjustments, required this.paid});

  int get owed => sheet.due + adjustments;
  int get outstanding => owed - paid;

  SchoolMonthPayState get state => owed <= 0
      ? SchoolMonthPayState.nothingDue
      : paid >= owed
          ? SchoolMonthPayState.paid
          : paid > 0
              ? SchoolMonthPayState.partial
              : SchoolMonthPayState.unpaid;
}

/// A student's fee account across months.
class SchoolFeeAccount {
  final String studentId;

  /// Oldest first. Closed months, then the live (provisional) current month.
  final List<SchoolFeeMonth> months;
  final List<SchoolFeePayment> payments;

  /// Payments not needed for any month yet (advance / overpayment). Kept, never dropped.
  final int credit;

  const SchoolFeeAccount({required this.studentId, required this.months, required this.payments, required this.credit});

  int get totalOwed => months.fold(0, (a, m) => a + m.owed);
  int get totalPaid => payments.fold(0, (a, p) => a + p.amount);

  /// What the parent still owes (negative = money in hand).
  int get balance => totalOwed - totalPaid;

  /// Owed for closed months only (arrears; the live month is still changing).
  int get arrears => months.where((m) => m.sheet.closed).fold(0, (a, m) => a + m.outstanding);

  SchoolFeeMonth? month(String ym) {
    for (final m in months) {
      if (m.sheet.month == ym) return m;
    }
    return null;
  }
}

abstract final class SchoolFeeRules {
  // ── Settings ──────────────────────────────────────────────────────────────

  /// The settings that apply to [ym]: that month's own, else the latest earlier one, else the defaults.
  static SchoolFeeConfig configFor(String ym, Iterable<SchoolFeeConfig> configs) {
    SchoolFeeConfig? best;
    for (final c in configs) {
      if (c.month.compareTo(ym) <= 0 && (best == null || c.month.compareTo(best.month) > 0)) best = c;
    }
    return (best ?? SchoolFeeConfig(month: ym)).copyWith(month: ym);
  }

  static String? validateConfig(SchoolFeeConfig c) {
    if (c.baseFee <= 0) return 'The monthly fee must be more than 0.';
    if (c.amounts.values.any((a) => a < 0)) return 'Rule amounts cannot be negative.';
    if (c.admissionFee < 0) return 'The admission fee cannot be negative.';
    if (c.rulesTotal != c.baseFee) {
      return 'The six rule amounts add up to Rs ${c.rulesTotal}, but the monthly fee is Rs ${c.baseFee}. They must be equal, '
          'so a child who earns every rule pays 0.';
    }
    return null;
  }

  // ── One month ─────────────────────────────────────────────────────────────

  static int _round(num v) => v.round();

  /// The concession for a month: fixed rupees, or a percent of the (pro-rated) base.
  static (int, String) concessionFor(String ym, int base, Iterable<SchoolFeeAdjustment> adjustments) {
    var total = 0;
    final notes = <String>[];
    for (final a in adjustments) {
      if (!a.appliesTo(ym)) continue;
      total += a.percent ? _round(base * a.amount / 100) : a.amount;
      notes.add(a.percent ? '${a.amount}% ${a.reason}' : 'Rs ${a.amount} ${a.reason}');
    }
    return (total.clamp(0, base), notes.join('; '));
  }

  static SchoolFeeSheet computeSheet({
    required SchoolStudent student,
    required String month,
    required SchoolFeeConfig config,
    required SchoolMonthSummary summary,
    Iterable<SchoolFeeAdjustment> adjustments = const [],
  }) {
    final share = summary.workingDays == 0 ? 0.0 : summary.activeDays / summary.workingDays;
    final admitted = DateTime.tryParse(student.admissionDate);
    final admissionFee = config.enabled && admitted != null && SchoolDailyRules.ym(admitted) == month ? config.admissionFee : 0;
    if (!config.enabled) {
      return SchoolFeeSheet(
        studentId: student.id,
        month: month,
        workingDays: summary.workingDays,
        activeDays: summary.activeDays,
        recordedDays: summary.recordedDays,
        base: 0,
        lines: const [],
        due: 0,
      );
    }
    final base = _round(config.baseFee * share);
    final lines = <SchoolFeeLine>[
      for (final r in SchoolFeeRule.values)
        if (r == SchoolFeeRule.ptm)
          SchoolFeeLine(
            rule: r,
            amount: config.amountOf(r),
            credit: summary.ptm == true ? _round(config.amountOf(r) * share) : 0,
            qualifying: summary.ptm == true ? 1 : 0,
            outOf: 1,
            met: summary.ptm,
          )
        else
          SchoolFeeLine(
            rule: r,
            amount: config.amountOf(r),
            credit: summary.recordedDays == 0 ? 0 : _round(config.amountOf(r) * share * summary.qualifying[r]! / summary.recordedDays),
            qualifying: summary.qualifying[r] ?? 0,
            outOf: summary.recordedDays,
          ),
    ];
    final credits = lines.fold(0, (a, l) => a + l.credit);
    final (concession, note) = concessionFor(month, (base - credits).clamp(0, base), adjustments.where((a) => a.studentId == student.id));
    final due = (base - credits - concession).clamp(0, base) + admissionFee;
    return SchoolFeeSheet(
      studentId: student.id,
      month: month,
      workingDays: summary.workingDays,
      activeDays: summary.activeDays,
      recordedDays: summary.recordedDays,
      base: base,
      lines: lines,
      concession: concession,
      concessionNote: note,
      admissionFee: admissionFee,
      due: due,
    );
  }

  // ── Account ───────────────────────────────────────────────────────────────

  /// Builds a student's account. Payments (including reversals) are summed and
  /// applied to months oldest first; whatever is left is credit.
  static SchoolFeeAccount account({
    required String studentId,
    required List<SchoolFeeSheet> sheets,
    required Iterable<SchoolFeeAdjustment> adjustments,
    required Iterable<SchoolFeePayment> payments,
  }) {
    final ordered = [...sheets]..sort((a, b) => a.month.compareTo(b.month));
    final pays = payments.where((p) => p.studentId == studentId).toList()..sort((a, b) => a.at.compareTo(b.at));
    var pool = pays.fold(0, (a, p) => a + p.amount);
    final months = <SchoolFeeMonth>[];
    for (final s in ordered) {
      final adj = adjustments
          .where((a) => a.studentId == studentId && a.active && a.kind == SchoolAdjustmentKind.adjustment && a.month == s.month)
          .fold(0, (a, x) => a + x.amount);
      final owed = s.due + adj;
      final paid = owed <= 0 ? 0 : (pool >= owed ? owed : (pool > 0 ? pool : 0));
      pool -= paid;
      months.add(SchoolFeeMonth(sheet: s, adjustments: adj, paid: paid));
    }
    return SchoolFeeAccount(studentId: studentId, months: months, payments: pays, credit: pool > 0 ? pool : 0);
  }

  // ── Month close ───────────────────────────────────────────────────────────

  /// Reasons the month cannot be closed yet (empty = it can).
  static List<String> closeBlockers({
    required int year,
    required int month,
    required SchoolCalendar cal,
    required List<SchoolStudent> students,
    required Map<String, Map<String, SchoolDayEntry>> logs,
    required SchoolFeeConfig config,
    required DateTime now,
  }) {
    final out = <String>[];
    final ym = SchoolDailyRules.ym(DateTime(year, month));
    final lastDay = DateTime(year, month + 1, 0);
    if (cal.closedMonths.contains(ym)) out.add('This month is already closed.');
    if (!SchoolDailyRules.day(now).isAfter(lastDay)) out.add('The month has not ended yet (it can be closed from ${SchoolDailyRules.ymd(lastDay.add(const Duration(days: 1)))}).');
    final validation = validateConfig(config);
    if (validation != null) out.add(validation);
    final enrolled = students.where((s) => SchoolDailyRules.daysOfMonth(year, month).any((d) => StudentRules.isActiveOn(s, d))).toList();
    final missing = SchoolDailyRules.unrecordedDays(students: enrolled, year: year, month: month, cal: cal, logs: logs, now: lastDay);
    if (missing.isNotEmpty) {
      out.add('${missing.length} working ${missing.length == 1 ? 'day has' : 'days have'} students not marked '
          '(${missing.take(5).map((d) => d.day).join(', ')}${missing.length > 5 ? '…' : ''}). Mark them in the Daily log first.');
    }
    final ptm = cal.ptmFor(year, month);
    if (enrolled.isNotEmpty && ptm.status == SchoolPtmStatus.scheduled) {
      out.add('The PTM (${ptm.date}) is not recorded. Record who came, or cancel it, in Daily log › Calendar.');
    }
    // An earlier open month must be closed first, so arrears build in order.
    final prev = DateTime(year, month - 1);
    final prevYm = SchoolDailyRules.ym(prev);
    final anyEarlierActivity = students.any((s) {
      final a = DateTime.tryParse(s.admissionDate);
      return a != null && SchoolDailyRules.ym(a).compareTo(prevYm) <= 0;
    });
    if (anyEarlierActivity && !cal.closedMonths.contains(prevYm) && cal.closedMonths.isNotEmpty) {
      out.add('Close ${_monthName(prev)} first.');
    }
    return out;
  }

  // ── Receipt numbers ───────────────────────────────────────────────────────

  /// Next receipt number for the branch and year: `GRT-R-2026-00001`, …
  static String nextReceiptNo(String branchId, DateTime date, Iterable<SchoolFeePayment> payments) {
    final prefix = '${StudentRules.branchCode(branchId)}-R-${date.year}-';
    var max = 0;
    for (final p in payments) {
      if (!p.receiptNo.startsWith(prefix)) continue;
      final n = int.tryParse(p.receiptNo.substring(prefix.length)) ?? 0;
      if (n > max) max = n;
    }
    return '$prefix${(max + 1).toString().padLeft(5, '0')}';
  }

  /// Receipt numbers used twice (possible when two PCs take money offline).
  static Map<String, List<SchoolFeePayment>> receiptConflicts(Iterable<SchoolFeePayment> payments) {
    final by = <String, List<SchoolFeePayment>>{};
    for (final p in payments) {
      if (p.receiptNo.isEmpty) continue;
      (by[p.receiptNo] ??= []).add(p);
    }
    by.removeWhere((_, v) => v.length < 2);
    return by;
  }

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  static String _monthName(DateTime d) => '${_months[d.month - 1]} ${d.year}';
  static String monthName(String ym) {
    final d = DateTime.tryParse('$ym-01');
    return d == null ? ym : _monthName(d);
  }
}
