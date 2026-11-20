// lib/pages/school/fees/fee_models.dart
//
// School fee engine records (School ERP plan §3.5, Phase 4, 2026-11-17).
//
// The structure follows the madrassa deduction fee (a base fee that reaches
// 0 as the child earns credits), but not its faults:
//   • settings are per month, so changing them never rewrites past months;
//   • a month is closed once, which freezes a fee sheet per student;
//   • payments are append-only (installments add up, a mistake is reversed by
//     a negative entry with a reason), so two PCs taking money offline both keep it;
//   • whole rupees everywhere, one rounding rule.
//
// User's rules (2026-11-14): Rs 12,000 base; six Rs 2,000 credits (attendance,
// on time, message reply = diary signed, behaviour, PTM, uniform); credits are
// pro-rated per qualifying day; approved leave = present.

import '../daily/daily_models.dart';

/// Fee settings for one month (`school_fee_configs/<yyyy-MM>`).
class SchoolFeeConfig {
  final String month; // yyyy-MM this config starts applying from
  final int baseFee;

  /// Credit per rule (whole rupees). Must add up to [baseFee].
  final Map<SchoolFeeRule, int> amounts;

  /// One-time charge in the month a student is admitted (0 = none; to be confirmed by the school).
  final int admissionFee;
  final bool enabled;
  final String updatedBy;

  const SchoolFeeConfig({
    required this.month,
    this.baseFee = 12000,
    this.amounts = defaultAmounts,
    this.admissionFee = 0,
    this.enabled = true,
    this.updatedBy = '',
  });

  static const Map<SchoolFeeRule, int> defaultAmounts = {
    SchoolFeeRule.attendance: 2000,
    SchoolFeeRule.onTime: 2000,
    SchoolFeeRule.messageReply: 2000,
    SchoolFeeRule.behaviour: 2000,
    SchoolFeeRule.ptm: 2000,
    SchoolFeeRule.uniform: 2000,
  };

  int amountOf(SchoolFeeRule r) => amounts[r] ?? 0;
  int get rulesTotal => SchoolFeeRule.values.fold(0, (a, r) => a + amountOf(r));

  factory SchoolFeeConfig.fromMap(Map m) {
    final raw = m['amounts'] is Map ? m['amounts'] as Map : const {};
    return SchoolFeeConfig(
      month: (m['month'] ?? '').toString(),
      baseFee: _int(m['baseFee'], 12000),
      amounts: {for (final r in SchoolFeeRule.values) r: _int(raw[r.key], defaultAmounts[r]!)},
      admissionFee: _int(m['admissionFee'], 0),
      enabled: m['enabled'] != false,
      updatedBy: (m['updatedBy'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'month': month,
        'baseFee': baseFee,
        'amounts': {for (final r in SchoolFeeRule.values) r.key: amountOf(r)},
        'admissionFee': admissionFee,
        'enabled': enabled,
      };

  SchoolFeeConfig copyWith({String? month, int? baseFee, Map<SchoolFeeRule, int>? amounts, int? admissionFee, bool? enabled}) => SchoolFeeConfig(
        month: month ?? this.month,
        baseFee: baseFee ?? this.baseFee,
        amounts: amounts ?? this.amounts,
        admissionFee: admissionFee ?? this.admissionFee,
        enabled: enabled ?? this.enabled,
        updatedBy: updatedBy,
      );
}

/// One rule's line on a fee sheet.
class SchoolFeeLine {
  final SchoolFeeRule rule;
  final int amount; // the rule's full amount from the config
  final int credit; // rupees earned (pro-rated)
  final int qualifying; // days (or 1/0 for PTM)
  final int outOf; // recorded days (or 1 for PTM)

  /// For PTM: null = the meeting has not happened yet.
  final bool? met;

  const SchoolFeeLine({required this.rule, required this.amount, required this.credit, required this.qualifying, required this.outOf, this.met});

  bool get full => credit >= amount && amount > 0;
  bool get none => credit == 0;

  factory SchoolFeeLine.fromMap(Map m) => SchoolFeeLine(
        rule: SchoolFeeRule.values.firstWhere((r) => r.key == m['rule'], orElse: () => SchoolFeeRule.attendance),
        amount: _int(m['amount'], 0),
        credit: _int(m['credit'], 0),
        qualifying: _int(m['qualifying'], 0),
        outOf: _int(m['outOf'], 0),
        met: m['met'] is bool ? m['met'] as bool : null,
      );

  Map<String, dynamic> toMap() => {
        'rule': rule.key,
        'amount': amount,
        'credit': credit,
        'qualifying': qualifying,
        'outOf': outOf,
        if (met != null) 'met': met,
      };
}

/// A student's fee for one month. Live ("provisional") until the month is
/// closed; frozen as `school_fee_sheets/<yyyy-MM>_<studentId>` at close.
class SchoolFeeSheet {
  final String studentId;
  final String month; // yyyy-MM
  final int workingDays;
  final int activeDays;
  final int recordedDays;

  /// Base fee after pro-rating for joining / leaving / suspension.
  final int base;
  final List<SchoolFeeLine> lines;
  final int concession;
  final String concessionNote;
  final int admissionFee;

  /// What the parent owes for the month: base − credits − concession + admission fee, never below 0.
  final int due;
  final bool closed;
  final String closedAt;
  final String closedBy;

  const SchoolFeeSheet({
    required this.studentId,
    required this.month,
    required this.workingDays,
    required this.activeDays,
    required this.recordedDays,
    required this.base,
    required this.lines,
    required this.due,
    this.concession = 0,
    this.concessionNote = '',
    this.admissionFee = 0,
    this.closed = false,
    this.closedAt = '',
    this.closedBy = '',
  });

  int get credits => lines.fold(0, (a, l) => a + l.credit);
  String get id => '${month}_$studentId';
  SchoolFeeLine line(SchoolFeeRule r) => lines.firstWhere((l) => l.rule == r);

  factory SchoolFeeSheet.fromMap(Map m) => SchoolFeeSheet(
        studentId: (m['studentId'] ?? '').toString(),
        month: (m['month'] ?? '').toString(),
        workingDays: _int(m['workingDays'], 0),
        activeDays: _int(m['activeDays'], 0),
        recordedDays: _int(m['recordedDays'], 0),
        base: _int(m['base'], 0),
        lines: m['lines'] is List ? (m['lines'] as List).whereType<Map>().map(SchoolFeeLine.fromMap).toList() : const [],
        concession: _int(m['concession'], 0),
        concessionNote: (m['concessionNote'] ?? '').toString(),
        admissionFee: _int(m['admissionFee'], 0),
        due: _int(m['due'], 0),
        closed: m['closed'] == true,
        closedAt: (m['closedAt'] ?? '').toString(),
        closedBy: (m['closedBy'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'studentId': studentId,
        'month': month,
        'workingDays': workingDays,
        'activeDays': activeDays,
        'recordedDays': recordedDays,
        'base': base,
        'lines': lines.map((l) => l.toMap()).toList(),
        'concession': concession,
        'concessionNote': concessionNote,
        'admissionFee': admissionFee,
        'due': due,
        'closed': closed,
        'closedAt': closedAt,
        'closedBy': closedBy,
      };
}

enum SchoolPaymentMethod {
  cash('Cash'),
  bank('Bank transfer'),
  easypaisa('EasyPaisa'),
  jazzcash('JazzCash'),
  cheque('Cheque');

  const SchoolPaymentMethod(this.label);
  final String label;
}

/// A payment or a reversal (negative amount). Never edited or deleted.
class SchoolFeePayment {
  final String id;
  final String studentId;
  final int amount;
  final SchoolPaymentMethod method;
  final String receiptNo;
  final String date; // yyyy-MM-dd the money was received
  final String note;
  final String by;
  final String at; // ISO time recorded

  /// Set on a reversal: the payment it cancels.
  final String reversalOf;

  const SchoolFeePayment({
    required this.id,
    required this.studentId,
    required this.amount,
    required this.receiptNo,
    required this.date,
    this.method = SchoolPaymentMethod.cash,
    this.note = '',
    this.by = '',
    this.at = '',
    this.reversalOf = '',
  });

  bool get isReversal => reversalOf.isNotEmpty;

  factory SchoolFeePayment.fromMap(Map m) => SchoolFeePayment(
        id: (m['id'] ?? '').toString(),
        studentId: (m['studentId'] ?? '').toString(),
        amount: _int(m['amount'], 0),
        method: SchoolPaymentMethod.values.firstWhere((x) => x.name == m['method'], orElse: () => SchoolPaymentMethod.cash),
        receiptNo: (m['receiptNo'] ?? '').toString(),
        date: (m['date'] ?? '').toString(),
        note: (m['note'] ?? '').toString(),
        by: (m['by'] ?? '').toString(),
        at: (m['at'] ?? '').toString(),
        reversalOf: (m['reversalOf'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'studentId': studentId,
        'amount': amount,
        'method': method.name,
        'receiptNo': receiptNo,
        'date': date,
        'note': note,
        'by': by,
        'at': at,
        if (reversalOf.isNotEmpty) 'reversalOf': reversalOf,
      };
}

enum SchoolAdjustmentKind {
  /// One-off correction after a month is closed (+ charge, − credit).
  adjustment,

  /// Welfare concession: a fixed amount or percent off each month from a date.
  concession,
}

class SchoolFeeAdjustment {
  final String id;
  final String studentId;
  final SchoolAdjustmentKind kind;

  /// Adjustment: the month it belongs to. Concession: first month it applies.
  final String month;

  /// Adjustment: rupees (+ adds to what is owed, − reduces it).
  /// Concession: rupees off per month when [percent] is false, else percent of the base.
  final int amount;
  final bool percent;

  /// Concession: last month it applies (empty = open-ended).
  final String untilMonth;
  final String reason;
  final String approvedBy;
  final String at;
  final bool active;

  const SchoolFeeAdjustment({
    required this.id,
    required this.studentId,
    required this.kind,
    required this.month,
    required this.amount,
    required this.reason,
    this.percent = false,
    this.untilMonth = '',
    this.approvedBy = '',
    this.at = '',
    this.active = true,
  });

  bool appliesTo(String ym) =>
      active && kind == SchoolAdjustmentKind.concession && month.compareTo(ym) <= 0 && (untilMonth.isEmpty || untilMonth.compareTo(ym) >= 0);

  factory SchoolFeeAdjustment.fromMap(Map m) => SchoolFeeAdjustment(
        id: (m['id'] ?? '').toString(),
        studentId: (m['studentId'] ?? '').toString(),
        kind: m['kind'] == 'concession' ? SchoolAdjustmentKind.concession : SchoolAdjustmentKind.adjustment,
        month: (m['month'] ?? '').toString(),
        amount: _int(m['amount'], 0),
        percent: m['percent'] == true,
        untilMonth: (m['untilMonth'] ?? '').toString(),
        reason: (m['reason'] ?? '').toString(),
        approvedBy: (m['approvedBy'] ?? '').toString(),
        at: (m['at'] ?? '').toString(),
        active: m['active'] != false,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'studentId': studentId,
        'kind': kind.name,
        'month': month,
        'amount': amount,
        'percent': percent,
        'untilMonth': untilMonth,
        'reason': reason,
        'approvedBy': approvedBy,
        'at': at,
        'active': active,
      };
}

int _int(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('${v ?? ''}') ?? double.tryParse('${v ?? ''}')?.round() ?? fallback;
}
