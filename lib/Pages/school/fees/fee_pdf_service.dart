// lib/pages/school/fees/fee_pdf_service.dart
//
// Printable monthly fee slip and payment receipt (Phase 4). The slip shows the
// six rules earned / not earned with rupees, which is the point of the
// حلف نامہ form: parents see exactly how the fee came down.

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../daily/daily_models.dart';
import '../models/school_student.dart';
import 'fee_models.dart';
import 'fee_rules.dart';

abstract final class SchoolFeePdf {
  static pw.Font? _urdu;

  static Future<pw.ThemeData> _theme() async {
    if (_urdu == null) {
      try {
        _urdu = pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
      } catch (_) {}
    }
    return pw.ThemeData.withFont(base: pw.Font.helvetica(), bold: pw.Font.helveticaBold(), fontFallback: [?_urdu]);
  }

  static String rs(int v) {
    final neg = v < 0;
    final s = v.abs().toString();
    // Pakistani grouping: 1,23,456
    String out;
    if (s.length <= 3) {
      out = s;
    } else {
      final last3 = s.substring(s.length - 3);
      var rest = s.substring(0, s.length - 3);
      final parts = <String>[];
      while (rest.length > 2) {
        parts.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) parts.insert(0, rest);
      out = '${parts.join(',')},$last3';
    }
    return '${neg ? '-' : ''}Rs $out';
  }

  static pw.Widget _header(String title, String branchName) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Text('Taleem o Tarbiyat School System', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Text('Gulzar Madina Welfare Foundation · $branchName', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 6),
        pw.Container(
          color: PdfColor.fromInt(0xFF2E3A8C),
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Text(title, textAlign: pw.TextAlign.center, style: pw.TextStyle(color: PdfColors.white, fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ),
        pw.SizedBox(height: 8),
      ]);

  static pw.Widget _kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(children: [
          pw.SizedBox(width: 90, child: pw.Text(k, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700))),
          pw.Expanded(child: pw.Text(v, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold))),
        ]),
      );

  // ── Fee slip ──────────────────────────────────────────────────────────────

  static Future<Uint8List> feeSlip({
    required SchoolStudent student,
    required SchoolFeeMonth month,
    required SchoolFeeAccount account,
    required String branchName,
  }) async {
    final doc = pw.Document(theme: await _theme());
    final s = month.sheet;
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          for (final h in ['Rule', 'Days earned', 'Full amount', 'Credit (fee reduced)'])
            pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        ],
      ),
      for (final l in s.lines)
        pw.TableRow(children: [
          pw.Padding(
            padding: const pw.EdgeInsets.all(4),
            child: pw.Row(children: [
              pw.Text(l.full ? '[x] ' : (l.none ? '[ ] ' : '[~] '), style: const pw.TextStyle(fontSize: 9)),
              pw.Text('${l.rule.label}  ', style: const pw.TextStyle(fontSize: 9)),
              pw.Text(l.rule.urdu, textDirection: pw.TextDirection.rtl, style: const pw.TextStyle(fontSize: 9)),
            ]),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.all(4),
            child: pw.Text(
              l.rule == SchoolFeeRule.ptm ? (l.met == null ? 'Pending' : (l.met! ? 'Attended' : 'Not attended')) : '${l.qualifying} / ${l.outOf}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
          pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(rs(l.amount), style: const pw.TextStyle(fontSize: 9))),
          pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(rs(l.credit), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        ]),
    ];

    pw.Widget sum(String k, int v, {bool bold = false}) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(k, style: pw.TextStyle(fontSize: bold ? 11 : 9.5, fontWeight: bold ? pw.FontWeight.bold : null)),
          pw.Text(rs(v), style: pw.TextStyle(fontSize: bold ? 11 : 9.5, fontWeight: bold ? pw.FontWeight.bold : null)),
        ]);

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(22),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        _header('MONTHLY FEE SLIP · ${SchoolFeeRules.monthName(s.month).toUpperCase()}${s.closed ? '' : ' (PROVISIONAL)'}', branchName),
        _kv('Student', student.name),
        _kv('Father', student.guardianName),
        _kv('Admission no.', student.admissionNo),
        _kv('Class', '${student.grade}-${student.section}${student.rollNo.isEmpty ? '' : '  ·  Roll ${student.rollNo}'}'),
        _kv('School days', '${s.activeDays} of ${s.workingDays} working days (${s.recordedDays} marked)'),
        pw.SizedBox(height: 8),
        pw.Table(border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5), columnWidths: const {
          0: pw.FlexColumnWidth(3),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(2),
          3: pw.FlexColumnWidth(2),
        }, children: rows),
        pw.SizedBox(height: 8),
        sum('Monthly fee${s.activeDays < s.workingDays ? ' (for days enrolled)' : ''}', s.base),
        sum('Less: credits earned', -s.credits),
        if (s.concession > 0) sum('Less: concession', -s.concession),
        if (s.admissionFee > 0) sum('Add: admission fee', s.admissionFee),
        if (month.adjustments != 0) sum('Adjustment', month.adjustments),
        pw.Divider(),
        sum('Fee for the month', month.owed, bold: true),
        sum('Paid toward this month', -month.paid),
        if (account.arrears - (month.sheet.closed ? month.outstanding : 0) > 0)
          sum('Earlier months still owed', account.arrears - (month.sheet.closed ? month.outstanding : 0)),
        pw.Divider(),
        sum('Total to pay now', account.balance > 0 ? account.balance : 0, bold: true),
        if (account.credit > 0) sum('Advance held', account.credit),
        pw.Spacer(),
        pw.Text(
          'Each rule reduces the fee by its amount for the days the child earned it. Approved leave counts as present. '
          'Message reply = diary read and signed by a parent.',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
        ),
      ]),
    ));
    return doc.save();
  }

  // ── Receipt ───────────────────────────────────────────────────────────────

  static Future<Uint8List> receipt({
    required SchoolStudent student,
    required SchoolFeePayment payment,
    required SchoolFeeAccount account,
    required String branchName,
  }) async {
    final doc = pw.Document(theme: await _theme());
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a6.landscape,
      margin: const pw.EdgeInsets.all(16),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        _header(payment.isReversal ? 'PAYMENT REVERSAL' : 'FEE RECEIPT', branchName),
        _kv('Receipt no.', payment.receiptNo),
        _kv('Date', payment.date),
        _kv('Student', '${student.name}  (${student.admissionNo})'),
        _kv('Class', '${student.grade}-${student.section}'),
        _kv('Amount', rs(payment.amount)),
        _kv('Method', payment.method.label + (payment.note.isEmpty ? '' : '  ·  ${payment.note}')),
        _kv('Balance now', account.balance > 0 ? rs(account.balance) : (account.credit > 0 ? 'Advance ${rs(account.credit)}' : 'Nothing owed')),
        pw.Spacer(),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Received by: ${payment.by}', style: const pw.TextStyle(fontSize: 8)),
          pw.Text('Signature ____________', style: const pw.TextStyle(fontSize: 8)),
        ]),
      ]),
    ));
    return doc.save();
  }

  static Future<void> printBytes(String name, Uint8List bytes) => Printing.layoutPdf(name: name, onLayout: (_) async => bytes);
}
