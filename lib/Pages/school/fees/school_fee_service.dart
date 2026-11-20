// lib/pages/school/fees/school_fee_service.dart
//
// Fee reads and writes over the School store (Phase 4). Screens call this;
// the maths is in fee_rules.dart.

import '../core/school_ids.dart';
import '../core/school_store.dart';
import '../daily/daily_models.dart';
import '../daily/daily_rules.dart';
import '../daily/school_daily_service.dart';
import '../models/school_student.dart';
import '../students/school_student_service.dart';
import '../students/student_rules.dart';
import 'fee_models.dart';
import 'fee_rules.dart';

class SchoolFeeException implements Exception {
  final String message;
  const SchoolFeeException(this.message);
  @override
  String toString() => message;
}

/// Everything the fee screen needs for one month, read once per rebuild.
class SchoolFeeSnapshot {
  SchoolFeeSnapshot({
    required this.branchId,
    required this.year,
    required this.month,
    required this.config,
    required this.closed,
    required this.students,
    required this.sheets,
    required this.accounts,
    required this.payments,
    required this.adjustments,
    required this.configs,
  });

  final String branchId;
  final int year;
  final int month;
  final SchoolFeeConfig config;
  final bool closed;

  /// Students with any enrolled day in the month (sorted by class, roll).
  final List<SchoolStudent> students;

  /// studentId → that month's sheet (frozen if closed, live otherwise).
  final Map<String, SchoolFeeSheet> sheets;

  /// studentId → whole account (every month, every payment).
  final Map<String, SchoolFeeAccount> accounts;
  final List<SchoolFeePayment> payments;
  final List<SchoolFeeAdjustment> adjustments;
  final List<SchoolFeeConfig> configs;

  String get ym => SchoolDailyRules.ym(DateTime(year, month));

  SchoolFeeMonth? monthOf(String studentId) => accounts[studentId]?.month(ym);
  Map<String, List<SchoolFeePayment>> get receiptConflicts => SchoolFeeRules.receiptConflicts(payments);
}

abstract final class SchoolFeeService {
  static List<String> get watchedBoxes => [SchoolCollection.feePayments.box, SchoolCollection.students.box, SchoolCollection.attendance.box];

  static List<SchoolFeeConfig> configs(String branchId) =>
      SchoolStore.all(SchoolCollection.feeConfigs, branchId).map(SchoolFeeConfig.fromMap).where((c) => c.month.isNotEmpty).toList();
  static List<SchoolFeePayment> payments(String branchId) =>
      SchoolStore.all(SchoolCollection.feePayments, branchId).map(SchoolFeePayment.fromMap).where((p) => p.id.isNotEmpty).toList();
  static List<SchoolFeeAdjustment> adjustments(String branchId) =>
      SchoolStore.all(SchoolCollection.feeAdjustments, branchId).map(SchoolFeeAdjustment.fromMap).where((a) => a.id.isNotEmpty).toList();
  static List<SchoolFeeSheet> frozenSheets(String branchId) =>
      SchoolStore.all(SchoolCollection.feeSheets, branchId).map(SchoolFeeSheet.fromMap).where((s) => s.studentId.isNotEmpty).toList();

  // ── Read ──────────────────────────────────────────────────────────────────

  static SchoolFeeSnapshot snapshot(String branchId, int year, int month, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final cal = SchoolDailyService.calendar(branchId);
    final roster = SchoolStudentService.roster(branchId).students.where((s) => !s.isVoid).toList();
    final cfgs = configs(branchId);
    final pays = payments(branchId);
    final adjs = adjustments(branchId);
    final frozen = frozenSheets(branchId);
    final ym = SchoolDailyRules.ym(DateTime(year, month));

    // Live sheets for open months: from the month after the last close (or the
    // student's admission) up to the viewed month or this month, whichever is later.
    final lastClosed = cal.closedMonths.isEmpty ? null : (cal.closedMonths.toList()..sort()).last;
    final currentYm = SchoolDailyRules.ym(at);
    final endYm = ym.compareTo(currentYm) > 0 ? ym : currentYm;
    final logCache = <String, Map<String, Map<String, SchoolDayEntry>>>{};
    Map<String, Map<String, SchoolDayEntry>> logsOf(DateTime m) =>
        logCache.putIfAbsent(SchoolDailyRules.ym(m), () => SchoolDailyService.month(branchId, m.year, m.month));

    SchoolFeeSheet live(SchoolStudent s, DateTime m) {
      final summary = SchoolDailyRules.summarize(student: s, year: m.year, month: m.month, cal: cal, logs: logsOf(m), now: at);
      return SchoolFeeRules.computeSheet(
        student: s,
        month: SchoolDailyRules.ym(m),
        config: SchoolFeeRules.configFor(SchoolDailyRules.ym(m), cfgs),
        summary: summary,
        adjustments: adjs,
      );
    }

    bool enrolledIn(SchoolStudent s, DateTime m) =>
        SchoolDailyRules.daysOfMonth(m.year, m.month).any((d) => !d.isAfter(at) && StudentRules.isActiveOn(s, d));

    final accounts = <String, SchoolFeeAccount>{};
    final sheets = <String, SchoolFeeSheet>{};
    final involved = <SchoolStudent>[];
    final viewed = DateTime(year, month);
    for (final s in roster) {
      final own = frozen.where((f) => f.studentId == s.id).toList();
      final admitted = DateTime.tryParse(s.admissionDate);
      var start = lastClosed == null ? DateTime(admitted?.year ?? at.year, admitted?.month ?? at.month) : _next(lastClosed);
      if (admitted != null && DateTime(admitted.year, admitted.month).isAfter(start)) start = DateTime(admitted.year, admitted.month);
      final all = [...own];
      for (var m = start; SchoolDailyRules.ym(m).compareTo(endYm) <= 0; m = DateTime(m.year, m.month + 1)) {
        if (cal.closedMonths.contains(SchoolDailyRules.ym(m))) continue;
        if (m.isAfter(DateTime(at.year, at.month)) || !enrolledIn(s, m)) continue;
        all.add(live(s, m));
      }
      accounts[s.id] = SchoolFeeRules.account(studentId: s.id, sheets: all, adjustments: adjs, payments: pays);
      SchoolFeeSheet? sheet;
      for (final x in all) {
        if (x.month == ym) sheet = x;
      }
      if (sheet == null && !cal.closedMonths.contains(ym) && !viewed.isAfter(DateTime(at.year, at.month)) && enrolledIn(s, viewed)) {
        sheet = live(s, viewed);
      }
      if (sheet != null) {
        sheets[s.id] = sheet;
        involved.add(s);
      }
    }
    return SchoolFeeSnapshot(
      branchId: branchId,
      year: year,
      month: month,
      config: SchoolFeeRules.configFor(ym, cfgs),
      closed: cal.closedMonths.contains(ym),
      students: involved,
      sheets: sheets,
      accounts: accounts,
      payments: pays,
      adjustments: adjs,
      configs: cfgs,
    );
  }

  static DateTime _next(String ym) {
    final d = DateTime.parse('$ym-01');
    return DateTime(d.year, d.month + 1);
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  /// Saves the settings for [config.month] onward. Closed months keep theirs.
  static Future<void> saveConfig({required String branchId, required SchoolFeeConfig config, required String editorName}) async {
    final problem = SchoolFeeRules.validateConfig(config);
    if (problem != null) throw SchoolFeeException(problem);
    final cal = SchoolDailyService.calendar(branchId);
    if (cal.closedMonths.contains(config.month)) throw const SchoolFeeException('That month is closed; its fee can no longer change.');
    await SchoolStore.put(SchoolCollection.feeConfigs, branchId: branchId, id: config.month, updatedBy: editorName, data: config.toMap());
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_SETTINGS',
      user: editorName,
      details: 'Fee settings from ${SchoolFeeRules.monthName(config.month)}: base Rs ${config.baseFee}, admission fee Rs ${config.admissionFee}',
      after: config.toMap(),
    );
  }

  // ── Month close ───────────────────────────────────────────────────────────

  /// Freezes every student's sheet for the month and locks the month's daily
  /// log, calendar and settings. Returns the number of sheets written.
  static Future<int> closeMonth({
    required String branchId,
    required int year,
    required int month,
    required String editorName,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final cal = SchoolDailyService.calendar(branchId);
    final ym = SchoolDailyRules.ym(DateTime(year, month));
    final roster = SchoolStudentService.roster(branchId).students.where((s) => !s.isVoid).toList();
    final logs = SchoolDailyService.month(branchId, year, month);
    final config = SchoolFeeRules.configFor(ym, configs(branchId));
    final blockers = SchoolFeeRules.closeBlockers(year: year, month: month, cal: cal, students: roster, logs: logs, config: config, now: at);
    if (blockers.isNotEmpty) throw SchoolFeeException(blockers.join('\n'));

    final adjs = adjustments(branchId);
    var n = 0;
    var total = 0;
    for (final s in roster) {
      final summary = SchoolDailyRules.summarize(student: s, year: year, month: month, cal: cal, logs: logs, now: at);
      if (summary.activeDays == 0) continue;
      final sheet = SchoolFeeRules.computeSheet(student: s, month: ym, config: config, summary: summary, adjustments: adjs);
      await SchoolStore.put(
        SchoolCollection.feeSheets,
        branchId: branchId,
        id: sheet.id,
        merge: false,
        updatedBy: editorName,
        data: {...sheet.toMap(), 'closed': true, 'closedAt': at.toIso8601String(), 'closedBy': editorName, 'config': config.toMap()},
      );
      n++;
      total += sheet.due;
    }
    await SchoolStore.put(
      SchoolCollection.calendar,
      branchId: branchId,
      id: 'month-$ym',
      updatedBy: editorName,
      data: {'kind': 'month', 'month': ym, 'closed': true, 'closedAt': at.toIso8601String(), 'closedBy': editorName},
    );
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_MONTH_CLOSED',
      user: editorName,
      details: '${SchoolFeeRules.monthName(ym)} closed: $n fee sheets, Rs $total due in total',
    );
    return n;
  }

  // ── Payments ──────────────────────────────────────────────────────────────

  /// Records money received. Never edits an earlier payment. Returns it (with
  /// its receipt number).
  static Future<SchoolFeePayment> takePayment({
    required String branchId,
    required String studentId,
    required int amount,
    required SchoolPaymentMethod method,
    required DateTime date,
    required String editorName,
    String note = '',
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if (amount <= 0) throw const SchoolFeeException('Enter an amount above 0.');
    if (amount > 500000) throw const SchoolFeeException('That amount looks wrong (over Rs 5,00,000).');
    if (SchoolDailyRules.day(date).isAfter(SchoolDailyRules.day(at))) throw const SchoolFeeException('The payment date cannot be in the future.');
    if (method != SchoolPaymentMethod.cash && note.trim().isEmpty) {
      throw SchoolFeeException('Write the ${method.label} reference (transaction id or cheque no.) in the note.');
    }
    final student = SchoolStudentService.roster(branchId).byId(studentId);
    if (student == null || student.isVoid) throw const SchoolFeeException('Student not found.');
    final payment = SchoolFeePayment(
      id: SchoolIds.newId('PAY', branchId),
      studentId: studentId,
      amount: amount,
      method: method,
      receiptNo: SchoolFeeRules.nextReceiptNo(branchId, date, payments(branchId)),
      date: SchoolDailyRules.ymd(date),
      note: note.trim(),
      by: editorName,
      at: at.toIso8601String(),
    );
    await SchoolStore.put(SchoolCollection.feePayments, branchId: branchId, id: payment.id, merge: false, updatedBy: editorName, data: payment.toMap());
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_PAYMENT',
      user: editorName,
      details: 'Receipt ${payment.receiptNo}: Rs $amount from ${student.name} (${method.label})',
      entity: 'fee_payment',
      entityId: payment.id,
    );
    return payment;
  }

  /// Cancels a payment with a negative entry (Principal / School Admin only).
  static Future<SchoolFeePayment> reversePayment({
    required String branchId,
    required String paymentId,
    required String reason,
    required String editorName,
    required bool isPrincipal,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if (!isPrincipal) throw const SchoolFeeException('Only the Principal or School Admin can reverse a payment.');
    if (reason.trim().isEmpty) throw const SchoolFeeException('Write why the payment is being reversed.');
    final all = payments(branchId);
    final original = all.where((p) => p.id == paymentId).firstOrNull;
    if (original == null) throw const SchoolFeeException('Payment not found.');
    if (original.isReversal) throw const SchoolFeeException('A reversal cannot be reversed.');
    if (all.any((p) => p.reversalOf == paymentId)) throw const SchoolFeeException('This payment is already reversed.');
    final rev = SchoolFeePayment(
      id: SchoolIds.newId('PAY', branchId),
      studentId: original.studentId,
      amount: -original.amount,
      method: original.method,
      receiptNo: 'REV-${original.receiptNo}',
      date: SchoolDailyRules.ymd(at),
      note: reason.trim(),
      by: editorName,
      at: at.toIso8601String(),
      reversalOf: original.id,
    );
    await SchoolStore.put(SchoolCollection.feePayments, branchId: branchId, id: rev.id, merge: false, updatedBy: editorName, data: rev.toMap());
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_PAYMENT_REVERSED',
      user: editorName,
      details: 'Receipt ${original.receiptNo} (Rs ${original.amount}) reversed: ${reason.trim()}',
      entity: 'fee_payment',
      entityId: original.id,
    );
    return rev;
  }

  // ── Adjustments & concessions ─────────────────────────────────────────────

  /// A correction for a closed month (the sheet itself never changes).
  static Future<void> addAdjustment({
    required String branchId,
    required String studentId,
    required String month,
    required int amount,
    required String reason,
    required String editorName,
    required bool isPrincipal,
  }) async {
    if (!isPrincipal) throw const SchoolFeeException('Only the Principal or School Admin can adjust a closed month.');
    if (amount == 0) throw const SchoolFeeException('Enter a non-zero amount (+ to charge more, − to reduce).');
    if (reason.trim().isEmpty) throw const SchoolFeeException('Write the reason for the adjustment.');
    if (!SchoolDailyService.calendar(branchId).closedMonths.contains(month)) {
      throw const SchoolFeeException('Only closed months need adjustments; an open month updates from the daily log.');
    }
    final a = SchoolFeeAdjustment(
      id: SchoolIds.newId('ADJ', branchId),
      studentId: studentId,
      kind: SchoolAdjustmentKind.adjustment,
      month: month,
      amount: amount,
      reason: reason.trim(),
      approvedBy: editorName,
      at: DateTime.now().toIso8601String(),
    );
    await SchoolStore.put(SchoolCollection.feeAdjustments, branchId: branchId, id: a.id, merge: false, updatedBy: editorName, data: a.toMap());
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_ADJUSTMENT',
      user: editorName,
      details: '${SchoolFeeRules.monthName(month)}: ${amount > 0 ? '+' : ''}Rs $amount for student $studentId (${reason.trim()})',
    );
  }

  /// A welfare concession from [fromMonth] (fixed rupees or percent off what
  /// is owed after credits). Ends by setting an end month, never by deleting.
  static Future<void> saveConcession({
    required String branchId,
    required String studentId,
    required String fromMonth,
    required int amount,
    required bool percent,
    required String reason,
    required String editorName,
    required bool isPrincipal,
    String untilMonth = '',
    String? id,
  }) async {
    if (!isPrincipal) throw const SchoolFeeException('Only the Principal or School Admin can give a concession.');
    if (amount <= 0) throw const SchoolFeeException('Enter an amount above 0.');
    if (percent && amount > 100) throw const SchoolFeeException('A percent concession cannot be over 100%.');
    if (reason.trim().isEmpty) throw const SchoolFeeException('Write the reason for the concession.');
    final cal = SchoolDailyService.calendar(branchId);
    if (id == null && cal.closedMonths.contains(fromMonth)) throw const SchoolFeeException('That month is closed; start the concession from an open month.');
    if (untilMonth.isNotEmpty && untilMonth.compareTo(fromMonth) < 0) throw const SchoolFeeException('The end month is before the start month.');
    final c = SchoolFeeAdjustment(
      id: id ?? SchoolIds.newId('CON', branchId),
      studentId: studentId,
      kind: SchoolAdjustmentKind.concession,
      month: fromMonth,
      amount: amount,
      percent: percent,
      untilMonth: untilMonth,
      reason: reason.trim(),
      approvedBy: editorName,
      at: DateTime.now().toIso8601String(),
    );
    await SchoolStore.put(SchoolCollection.feeAdjustments, branchId: branchId, id: c.id, updatedBy: editorName, data: c.toMap());
    await SchoolStore.audit(
      branchId: branchId,
      action: 'FEE_CONCESSION',
      user: editorName,
      details: 'Concession ${percent ? '$amount%' : 'Rs $amount'} from ${SchoolFeeRules.monthName(fromMonth)}'
          '${untilMonth.isEmpty ? '' : ' to ${SchoolFeeRules.monthName(untilMonth)}'} for student $studentId (${reason.trim()})',
    );
  }
}
